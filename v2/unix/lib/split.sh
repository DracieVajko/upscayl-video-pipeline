# Upscayl Video Pipeline V2 - split module.
# Input resolution and frame extraction.
# Sourced by upscayl-video.sh; not meant to be run directly.
# shellcheck shell=bash

# ---------------------------------------------------------------------------
# Input resolution and split
# ---------------------------------------------------------------------------

is_video_file() {
    case "$(lower "${1##*.}")" in
        mp4|mkv|mov|avi|webm|m4v|ts|m2ts|wmv|flv|mpg|mpeg|ogv) return 0 ;;
    esac
    return 1
}

skip_input_path() {
    local path="$1" name stem
    name=$(basename "$path")
    case "$name" in .*) return 0 ;; esac
    stem="${name%.*}"
    case "$(lower "$stem")" in *_upscaled) return 0 ;; esac
    within_path "$path" "$CFG_WORK_DIR" && return 0
    return 1
}

INPUT_PATHS=()

resolve_inputs() {
    INPUT_PATHS=()
    local recursive="$1"
    shift
    local items
    items=("$@")
    local raw path candidates candidate dir pattern found
    if [ "${#items[@]}" -eq 0 ]; then
        local default_input="$CFG_TOOL_DIR/input"
        if [ -d "$default_input" ]; then
            items=("$default_input")
        else
            die 2 "No input videos given." "Pass files/folders, or create an input/ folder next to the tool."
        fi
    fi

    local all_paths
    all_paths=$(new_temp_file)
    for raw in "${items[@]}"; do
        path=$(expand_home "$raw")
        candidates=$(new_temp_file)
        if [ -f "$path" ]; then
            printf '%s\n' "$path" > "$candidates"
        elif [ -d "$path" ]; then
            if [ "$recursive" -eq 1 ]; then
                find "$path" -maxdepth 2 -type f 2>/dev/null > "$candidates"
            else
                find "$path" -maxdepth 1 -type f 2>/dev/null > "$candidates"
            fi
        else
            case "$path" in
                *'*'*|*'?'*|*'['*)
                    dir=$(dirname "$path")
                    pattern=$(basename "$path")
                    [ -d "$dir" ] || dir="."
                    if [ "$recursive" -eq 1 ]; then
                        find "$dir" -maxdepth 2 -type f -name "$pattern" 2>/dev/null > "$candidates"
                    else
                        find "$dir" -maxdepth 1 -type f -name "$pattern" 2>/dev/null > "$candidates"
                    fi
                    ;;
            esac
        fi
        while IFS= read -r candidate; do
            [ -n "$candidate" ] || continue
            [ -f "$candidate" ] || continue
            is_video_file "$candidate" || continue
            skip_input_path "$candidate" && continue
            abspath "$candidate" >> "$all_paths"
        done < "$candidates"
        rm -f "$candidates"
    done

    if [ ! -s "$all_paths" ]; then
        rm -f "$all_paths"
        die 2 "No supported video files found." "Supported: .mp4 .mkv .mov .avi .webm .m4v .ts .m2ts .wmv .flv .mpg .mpeg .ogv"
    fi

    local sorted unique
    sorted=$(sort -u "$all_paths")
    rm -f "$all_paths"
    unique=$(printf '%s\n' "$sorted" | awk -F/ '{print tolower($NF) "\t" $0}' | sort -f -k1,1 | cut -f2-)
    while IFS= read -r candidate; do
        [ -n "$candidate" ] && INPUT_PATHS[${#INPUT_PATHS[@]}]="$candidate"
    done <<EOF
$unique
EOF
}

test_has_frames() {
    local dir="$JOB_DIR/frames" found
    [ -d "$dir" ] || return 1
    found=$(find "$dir" -maxdepth 1 -type f -name 'frame_*' -size +0c 2>/dev/null | head -n 1)
    [ -n "$found" ]
}

clear_split_outputs() {
    rm -rf "$JOB_DIR/frames" "$JOB_DIR/upscaled" "$JOB_DIR/sequence"
    local marker
    for marker in "$JOB_DIR"/.done_*; do
        [ -e "$marker" ] && rm -f "$marker"
    done
    job_set frame_count 0
    job_set upscaled_count 0
    job_save
}

settings_differences() {
    local media_fps="$1" start="$2" end="$3"
    local expected_range_end="" differences="" key existing value same
    if [ -n "$SP_END" ]; then expected_range_end=$(fcalc "$end" '+' 0 '%.3f'); fi
    local expected_keys="frame_format fps range_start range_end denoise tonemap png_compression jpeg_quality"
    local expected_values
    expected_values="$SP_FORMAT|$media_fps|$(fcalc "$start" '+' 0 '%.3f')|$expected_range_end|$SP_DENOISE|$SP_TONEMAP|$SP_PNG|$SP_JPEG"
    local i=1
    local oldIFS="$IFS"
    IFS='|'
    # shellcheck disable=SC2086  # the expected values are a pipe separated list
    set -- $expected_values
    IFS="$oldIFS"
    for key in $expected_keys; do
        value="$1"
        shift
        job_has "$key" || continue
        existing=$(job_get "$key" '')
        same=0
        case "$key" in
            range_start|range_end)
                if awk -v a="$existing" -v b="$value" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d < 0.001) }'; then same=1; fi
                ;;
            *)
                [ "$existing" = "$value" ] && same=1
                ;;
        esac
        if [ "$same" -eq 0 ]; then
            differences="$differences; $key: $existing -> $value"
        fi
        i=$((i + 1))
    done
    printf '%s' "${differences#; }"
}

SCALE_CHOSEN=""
TARGET_CHOSEN=""

resolve_scale() {
    local target="$SP_TARGET" scale="$SP_SCALE" candidate
    if [ -z "$target" ] && [ -n "$(job_get target_height '')" ]; then
        target=$(job_get target_height '')
    fi
    if [ -n "$target" ] && [ $((target % 2)) -ne 0 ]; then
        target=$((target + 1))
    fi
    if [ -z "$scale" ] && [ -n "$(job_get scale '')" ]; then
        scale=$(job_get scale '')
    fi
    if [ -n "$target" ] && [ "$target" -le "$M_HEIGHT" ]; then
        die 4 "--target-height ($target) must be greater than the source height ($M_HEIGHT)"
    fi
    if [ -z "$target" ]; then
        SCALE_CHOSEN="${scale:-$CFG_DEFAULT_SCALE}"
        TARGET_CHOSEN=""
        return 0
    fi
    if [ -n "$scale" ]; then
        if [ $((M_HEIGHT * scale)) -lt "$target" ]; then
            die 4 "Scale ${scale}x gives $((M_HEIGHT * scale))px, below --target-height $target"
        fi
        SCALE_CHOSEN="$scale"
        TARGET_CHOSEN="$target"
        return 0
    fi
    for candidate in 2 3 4; do
        if [ $((M_HEIGHT * candidate)) -ge "$target" ]; then
            SCALE_CHOSEN="$candidate"
            TARGET_CHOSEN="$target"
            return 0
        fi
    done
    die 4 "--target-height $target requires more than 4x from $M_HEIGHT px"
}

HW_ARGS=()

hwaccel_args() {
    local decode="$1"
    HW_ARGS=()
    [ "$decode" = "gpu" ] || return 0
    case "$(uname -s)" in
        Darwin)
            HW_ARGS=(-hwaccel videotoolbox)
            ;;
        Linux)
            if [ -e /dev/dri/renderD128 ]; then
                HW_ARGS=(-hwaccel vaapi -hwaccel_device /dev/dri/renderD128)
            fi
            ;;
    esac
}

CMD=()

split_command() {
    local source="$1" start="$2" duration="$3" first_frame="$4" fmt="$5" jpeg="$6" png="$7"
    local denoise="$8" tonemap="$9" decode="${10}" output_dir="${11}" frame_limit="${12}"
    local filters="" denoise_filter="" pad="" format_filter=""
    local pattern
    fmt=$(lower "$fmt")
    case "$fmt" in
        png) pattern='frame_%08d.png'; format_filter='format=rgb24' ;;
        jpg|jpeg) fmt=jpg; pattern='frame_%08d.jpg'; format_filter='format=yuvj420p' ;;
        *) die 4 "Unsupported frame format: $fmt" ;;
    esac
    case "$denoise" in
        none) denoise_filter="" ;;
        light) denoise_filter='hqdn3d=1.5:1.5:6:6' ;;
        medium) denoise_filter='hqdn3d=2:2:8:8' ;;
        strong) denoise_filter='hqdn3d=3:3:10:10' ;;
        *) die 4 "Unsupported denoise mode: $denoise" ;;
    esac
    if [ $((M_WIDTH % 2)) -ne 0 ] || [ $((M_HEIGHT % 2)) -ne 0 ]; then
        pad='pad=ceil(iw/2)*2:ceil(ih/2)*2'
    fi
    if [ "$tonemap" = "1" ]; then
        filters='zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p'
    fi
    [ -n "$denoise_filter" ] && filters="${filters:+$filters,}$denoise_filter"
    [ -n "$pad" ] && filters="${filters:+$filters,}$pad"
    filters="${filters:+$filters,}$format_filter"

    hwaccel_args "$decode"
    CMD=("ffmpeg" -hide_banner -nostdin -y -benchmark)
    local arg
    for arg in "${HW_ARGS[@]}"; do CMD[${#CMD[@]}]="$arg"; done
    if num_cmp "$start" gt 0; then
        CMD[${#CMD[@]}]=-ss
        CMD[${#CMD[@]}]=$(fcalc "$start" '+' 0 '%.6f')
    fi
    CMD[${#CMD[@]}]=-i
    CMD[${#CMD[@]}]="$source"
    if [ -n "$duration" ]; then
        CMD[${#CMD[@]}]=-t
        CMD[${#CMD[@]}]=$(fcalc "$duration" '+' 0 '%.6f')
    fi
    CMD=("${CMD[@]}" -map 0:v:0 -an -sn -dn -fps_mode cfr -r "$FPS_RATIONAL" -start_number "$first_frame")
    if [ -n "$frame_limit" ]; then
        CMD[${#CMD[@]}]=-frames:v
        CMD[${#CMD[@]}]="$frame_limit"
    fi
    CMD[${#CMD[@]}]=-vf
    CMD[${#CMD[@]}]="$filters"
    if [ "$fmt" = "png" ]; then
        CMD[${#CMD[@]}]=-compression_level
        CMD[${#CMD[@]}]="$png"
    else
        CMD[${#CMD[@]}]=-q:v
        CMD[${#CMD[@]}]="$jpeg"
    fi
    CMD[${#CMD[@]}]="$output_dir/$pattern"
}

benchmark_decode() {
    local source="$1" decode="$2" temp_dir rtime
    temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/upscayl-bench.XXXXXX") || return 1
    hwaccel_args "$decode"
    local args=("$CFG_FFMPEG" -hide_banner -nostdin -y -benchmark)
    local arg
    for arg in "${HW_ARGS[@]}"; do args[${#args[@]}]="$arg"; done
    args=("${args[@]}" -i "$source" -map 0:v:0 -an -sn -dn -fps_mode cfr -r "$FPS_RATIONAL" -frames:v 30 -compression_level 3 "$temp_dir/frame_%08d.png")
    run_child "${args[@]}"
    if [ "$LAST_RC" -ne 0 ]; then
        rm -rf "$temp_dir"; cleanup_temp_files
        return 1
    fi
    rtime=$(grep -o 'rtime=[0-9.]*' "$LAST_ERR" 2>/dev/null | tail -n 1 | cut -d= -f2)
    rm -rf "$temp_dir"; cleanup_temp_files
    [ -n "$rtime" ] || return 1
    printf '%s' "$rtime"
}

CHOSEN_DECODE=""

choose_decode() {
    local source="$1" cpu_time gpu_time
    if [ "$FPS_DEN" -eq 0 ] || [ "${#HW_ARGS[@]}" -eq 0 ]; then
        hwaccel_args gpu
        if [ "${#HW_ARGS[@]}" -eq 0 ]; then CHOSEN_DECODE="cpu"; return 0; fi
    fi
    log_debug "Benchmarking CPU and GPU frame extraction"
    cpu_time=$(benchmark_decode "$source" cpu || true)
    gpu_time=$(benchmark_decode "$source" gpu || true)
    if [ -z "$cpu_time" ] && [ -z "$gpu_time" ]; then
        log_warn "Decode benchmark failed; using CPU"
        CHOSEN_DECODE="cpu"
        return 0
    fi
    if [ -n "$gpu_time" ] && { [ -z "$cpu_time" ] || num_cmp "$gpu_time" lt "$cpu_time"; }; then
        log_info "Decode benchmark: GPU $(fcalc "$gpu_time" '+' 0 '%.2f')s vs CPU $(fcalc "${cpu_time:-0}" '+' 0 '%.2f')s; using GPU"
        CHOSEN_DECODE="gpu"
    else
        log_info "Decode benchmark: CPU $(fcalc "${cpu_time:-0}" '+' 0 '%.2f')s vs GPU $(fcalc "${gpu_time:-0}" '+' 0 '%.2f')s; using CPU"
        CHOSEN_DECODE="cpu"
    fi
}

EXTRACTED_COUNT=0

extract_frames() {
    local fmt="$1" jpeg="$2" png="$3" denoise="$4" tonemap="$5" decode="$6" start="$7" end="$8" verify="$9"
    local total_duration expected existing total_files first_frame adjusted_start remaining
    case "$decode" in cpu|gpu|auto) ;; *) die 4 "Unsupported decode mode: $decode" ;; esac
    if [ -z "$end" ]; then end="$M_DURATION"; fi
    total_duration=$(fcalc "$end" '-' "$start" '%.6f')
    if num_cmp "$total_duration" lt 0; then total_duration=0; fi
    expected=$(round_even "$(fcalc "$total_duration" '*' "$FPS_DECIMAL" '%.9f')")
    if [ "$expected" -le 0 ]; then EXTRACTED_COUNT=0; return 0; fi
    if [ "$M_HDR" -eq 1 ] && [ "$tonemap" != "1" ]; then
        die 4 "HDR source detected. Upscayl models are 8-bit SDR." "Re-run with --tonemap to convert HDR to SDR BT.709."
    fi
    if [ "$tonemap" = "1" ] && [ "$M_HDR" -ne 1 ]; then
        log_warn "--tonemap was requested for a non-HDR source; applying the SDR conversion anyway"
    fi

    if [ "$decode" = "auto" ]; then
        choose_decode "$(job_source_path)"
        decode="$CHOSEN_DECODE"
        job_set decode "$decode"
        log_info "Frame decode path: $decode"
    else
        job_set decode "$decode"
    fi

    local tmp
    tmp=$(new_temp_file)
    scan_frames "$JOB_DIR/frames" 0 > "$tmp"
    total_files=$(wc -l < "$tmp" | tr -d ' ')
    rm -f "$tmp"
    existing=$(count_contiguous_frames "$JOB_DIR/frames" "$( [ "$fmt" = "jpg" ] && printf jpg || printf png )")
    if [ "$total_files" -gt "$existing" ]; then
        die 4 "Existing frame set is not contiguous: $JOB_DIR/frames" "Use --force to start the split over."
    fi
    if [ "$existing" -gt "$expected" ]; then
        die 4 "More frames exist than expected ($existing > $expected)" "Use --force to start the split over."
    fi
    if [ "$existing" -eq "$expected" ]; then EXTRACTED_COUNT="$existing"; return 0; fi

    first_frame=$((existing + 1))
    adjusted_start=$(fcalc "$start" '+' "$(fcalc "$existing" '/' "$FPS_DECIMAL" '%.9f')" '%.6f')
    remaining=$((expected - existing))
    split_command "$(job_source_path)" "$adjusted_start" "$(fcalc "$remaining" '/' "$FPS_DECIMAL" '%.9f')" "$first_frame" "$fmt" "$jpeg" "$png" "$denoise" "$tonemap" "$decode" "$JOB_DIR/frames" "$remaining"
    CMD[0]="$CFG_FFMPEG"
    mkdir -p "$JOB_DIR/frames" || die 1 "Could not create $JOB_DIR/frames"
    log_debug "\$ $(display_command "${CMD[@]}")"
    run_child "${CMD[@]}"
    if [ "$LAST_RC" -ne 0 ]; then
        if [ "$decode" = "gpu" ]; then
            log_warn "GPU frame extraction failed; retrying with CPU"
            job_set decode cpu
            split_command "$(job_source_path)" "$adjusted_start" "$(fcalc "$remaining" '/' "$FPS_DECIMAL" '%.9f')" "$first_frame" "$fmt" "$jpeg" "$png" "$denoise" "$tonemap" cpu "$JOB_DIR/frames" "$remaining"
            CMD[0]="$CFG_FFMPEG"
            log_debug "\$ $(display_command "${CMD[@]}")"
            run_child "${CMD[@]}"
            if [ "$LAST_RC" -ne 0 ]; then
                local detail
                detail=$(child_tail 50)
                cleanup_temp_files
                die 7 "Frame extraction failed: $(job_source_path)" "$detail"
            fi
        else
            local detail
            detail=$(child_tail 50)
            cleanup_temp_files
            die 7 "Frame extraction failed: $(job_source_path)" "$detail"
        fi
    fi
    cleanup_temp_files
    validate_frame_set "$JOB_DIR/frames" "$expected" error "$verify"
    EXTRACTED_COUNT="$FS_COUNT"
}

SP_FPS=""; SP_START=""; SP_END=""; SP_FORMAT="png"; SP_JPEG=1; SP_PNG=3
SP_DENOISE="none"; SP_TONEMAP=0; SP_DECODE="auto"; SP_SCALE=""; SP_TARGET=""
SP_MODEL=""; SP_VERIFY=0; SP_RECURSIVE=0; SP_FORCE=0

JOB_PATHS=()

run_split() {
    local recursive="$1"; shift
    local assume_yes="$1"; shift
    local dry_run="$1"; shift
    local inputs=("$@")
    JOB_PATHS=()
    local input source start end processed_duration expected_frames sample_bytes free scale target
    for input in "${inputs[@]}"; do
        JOB_DIR=""
        source=$(abspath "$input")
        probe_media "$source"
        if num_cmp "$M_DURATION" le 0; then
            die 4 "Could not determine a positive video duration: $source"
        fi
        if [ -n "$SP_FPS" ]; then
            fps_override "$SP_FPS"
            M_FPS_NUM="$FPS_NUM"; M_FPS_DEN="$FPS_DEN"
            M_FPS_RATIONAL="$FPS_RATIONAL"; M_FPS_DECIMAL="$FPS_DECIMAL"; M_FPS_TEXT="$FPS_TEXT"
        fi

        start=0
        if [ -n "$SP_START" ]; then start=$(parse_time_value "$SP_START") || exit $?; fi
        if [ -n "$SP_END" ]; then end=$(parse_time_value "$SP_END") || exit $?; else end="$M_DURATION"; fi
        if num_cmp "$end" gt "$(fcalc "$M_DURATION" '+' 0.001 '%.6f')"; then
            log_warn "--end $(fcalc "$end" '+' 0 '%.3f')s exceeds source duration; clamping to $(fcalc "$M_DURATION" '+' 0 '%.3f')s"
            end="$M_DURATION"
        fi
        if num_cmp "$start" ge "$end"; then
            die 4 "--start ($(fcalc "$start" '+' 0 '%.3f')s) must be before --end ($(fcalc "$end" '+' 0 '%.3f')s)"
        fi
        processed_duration=$(fcalc "$end" '-' "$start" '%.6f')

        local create=1
        [ "$dry_run" -eq 1 ] && create=0
        find_or_create_job "$CFG_WORK_DIR" "$source" "$create"
        if job_has_chunks; then
            die 4 "Job is chunked: $(basename "$JOB_DIR")" "Resume it with the run command, not split."
        fi
        if [ "$dry_run" -eq 0 ]; then set_log_file "$JOB_DIR/logs/split.log"; fi

        local has_frames=0
        test_has_frames && has_frames=1
        if [ "$has_frames" -eq 1 ] && job_source_changed && [ "$SP_FORCE" -eq 0 ]; then
            die 4 "Source changed since the job was created: $source" "Use --force to rebuild the job."
        fi
        if [ "$has_frames" -eq 1 ] && [ "$SP_FORCE" -eq 0 ]; then
            local differences
            differences=$(settings_differences "$M_FPS_RATIONAL" "$start" "$end")
            if [ -n "$differences" ]; then
                die 4 "Existing job was split with different settings." "Use --force to re-split. Differences: $differences"
            fi
        fi
        if [ "$has_frames" -eq 1 ] && [ "$SP_FORCE" -eq 1 ] && [ "$dry_run" -eq 0 ]; then
            if [ "$assume_yes" -eq 0 ]; then
                local answer
                printf 'Clear existing frames for %s? [y/N] ' "$(basename "$JOB_DIR")" >&2
                IFS= read -r answer || answer=""
                answer=$(lower "$(trim "$answer")")
                case "$answer" in y|yes) ;; *) die 4 "Aborted by user." ;; esac
            fi
            clear_split_outputs
        fi

        if [ -n "$SP_TARGET" ] && [ $((SP_TARGET % 2)) -ne 0 ]; then
            log_warn "--target-height $SP_TARGET is odd; rounding up to $((SP_TARGET + 1))"
            SP_TARGET=$((SP_TARGET + 1))
        fi
        resolve_scale
        scale="$SCALE_CHOSEN"
        target="$TARGET_CHOSEN"

        if [ "$M_HDR" -eq 1 ] && [ "$SP_TONEMAP" -ne 1 ]; then
            die 4 "HDR source detected. Upscayl models are 8-bit SDR." "Re-run with --tonemap to convert HDR to SDR BT.709."
        fi
        if [ "$M_HDR" -ne 1 ]; then
            case "$(lower "$M_PIX_FMT")" in
                *10*|*12*|*16*) log_warn "10-bit SDR source: frames will be converted to 8-bit RGB for Upscayl." ;;
            esac
        fi
        case "$M_SAR" in
            ''|0:1|1:1) ;;
            *) log_warn "Anamorphic source detected (SAR $M_SAR); the output uses square pixels and may not preserve display aspect ratio." ;;
        esac

        job_update_media
        if [ "$SP_TONEMAP" -eq 1 ]; then
            job_set color_primaries bt709
            job_set color_trc bt709
            job_set colorspace bt709
            job_set color_range tv
            job_set hdr 0
        fi
        job_set duration "$(fcalc "$processed_duration" '+' 0 '%.3f')"
        job_set range_start "$(fcalc "$start" '+' 0 '%.3f')"
        if [ -n "$SP_END" ]; then job_set range_end "$(fcalc "$end" '+' 0 '%.3f')"; else job_set range_end ""; fi
        job_set scale "$scale"
        job_set target_height "$target"
        job_set model "$SP_MODEL"
        job_set frame_format "$(lower "$SP_FORMAT")"
        job_set frame_pattern "$(frame_pattern "$SP_FORMAT")"
        job_set chunk_seconds 0
        job_set chunk_frames 0
        job_set denoise "$SP_DENOISE"
        job_set decode "$SP_DECODE"
        job_set tonemap "$SP_TONEMAP"
        job_set png_compression "$SP_PNG"
        job_set jpeg_quality "$SP_JPEG"
        [ "$dry_run" -eq 1 ] || job_save

        expected_frames=$(round_even "$(fcalc "$processed_duration" '*' "$M_FPS_DECIMAL" '%.9f')")
        sample_bytes=$(sample_frame_bytes "$(job_source_path)" "$start" "$processed_duration" "$SP_FORMAT" "$SP_DENOISE" "$SP_TONEMAP" "$SP_DECODE") || exit $?
        disk_estimate "$sample_bytes" "$expected_frames" "$scale"
        free=$(free_bytes "$CFG_WORK_DIR")
        log_info "Job $(basename "$JOB_DIR"): $(format_duration "$processed_duration"), $expected_frames frames, sample $(format_bytes "$sample_bytes"), estimated $(format_bytes "$EST_TOTAL_BYTES"), free $(format_bytes "$free")"
        check_disk_estimate "$free"
        [ "$dry_run" -eq 1 ] && continue

        extract_frames "$SP_FORMAT" "$SP_JPEG" "$SP_PNG" "$SP_DENOISE" "$SP_TONEMAP" "$SP_DECODE" "$start" "$end" "$SP_VERIFY"
        job_set frame_count "$EXTRACTED_COUNT"
        job_set upscaled_count 0
        job_set last_error ""
        job_save
        job_mark split
        JOB_PATHS[${#JOB_PATHS[@]}]="$JOB_DIR"
    done
}
