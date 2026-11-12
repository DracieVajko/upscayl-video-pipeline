# Upscayl Video Pipeline V2 - assemble module.
# Output path resolution, publishing and frame reconstruction.
# Sourced by upscayl-video.sh; not meant to be run directly.
# shellcheck shell=bash

OUTPUT_PATH=""

default_output_path() {
    local ext="$1" stem
    stem=$(basename "$(job_source_path)")
    stem="${stem%.*}"
    printf '%s' "$JOB_DIR/output/${stem}_upscaled.$ext"
}

collision_path() {
    local path="$1" dir stem ext i candidate
    [ -e "$path" ] || { printf '%s' "$path"; return 0; }
    dir=$(dirname "$path")
    stem=$(basename "$path")
    ext=""
    case "$stem" in
        *.*) ext=".${stem##*.}"; stem="${stem%.*}" ;;
    esac
    i=1
    while [ "$i" -lt 10000 ]; do
        candidate="$dir/${stem}_$i$ext"
        [ -e "$candidate" ] || { printf '%s' "$candidate"; return 0; }
        i=$((i + 1))
    done
    die 4 "Could not find a free output name for: $path"
}

test_output_path() {
    local path="$1" ext="$2" name expected_suffix actual_suffix
    [ "$(abspath "$path")" = "$(job_source_path)" ] && die 4 "Output path is the source video; refusing to overwrite it." "Choose a different --output path."
    for name in frames upscaled sequence chunks; do
        if within_path "$path" "$JOB_DIR/$name"; then
            die 4 "Output must not be inside the job's intermediate folder: $JOB_DIR/$name"
        fi
    done
    expected_suffix=".$ext"
    actual_suffix=""
    case "$(basename "$path")" in
        *.*) actual_suffix=".${path##*.}" ;;
    esac
    if [ "$(lower "$actual_suffix")" != "$expected_suffix" ]; then
        die 4 "Output extension ${actual_suffix:-(none)} does not match preset extension $expected_suffix"
    fi
    printf '%s' "$path"
}

resolve_output_path() {
    local ext="$1" multiple="$2" requested default_name path is_dir stem
    stem=$(basename "$(job_source_path)")
    stem="${stem%.*}"
    default_name="${stem}_upscaled.$ext"
    if [ -z "$EN_OUTPUT" ]; then
        path=$(default_output_path "$ext")
        if [ -e "$path" ] && [ "$EN_FORCE" -ne 1 ]; then path=$(collision_path "$path"); fi
        test_output_path "$path" "$ext"
        return 0
    fi
    requested=$(abspath "$EN_OUTPUT")
    is_dir=0
    [ -d "$requested" ] && is_dir=1
    case "$(basename "$requested")" in
        *.*) ;;
        *) is_dir=1 ;;
    esac
    if [ "$multiple" -eq 1 ] && [ "$is_dir" -eq 0 ]; then
        die 2 "With multiple jobs, --output must be a directory." "Pass a directory (or omit --output)."
    fi
    if [ "$is_dir" -eq 1 ]; then
        path="$requested/$default_name"
        if [ -e "$path" ] && [ "$EN_FORCE" -ne 1 ]; then path=$(collision_path "$path"); fi
        test_output_path "$path" "$ext"
        return 0
    fi
    if [ -e "$requested" ] && [ "$EN_FORCE" -ne 1 ]; then
        die 4 "Output already exists: $requested" "Use --force to overwrite it."
    fi
    test_output_path "$requested" "$ext"
}

PUBLISHED_OUTPUT=""

publish_and_purge() {
    local job_dir="$1" output="$2"
    local job_root output_root target name index work_root
    [ -n "$job_dir" ] || die 4 "No job folder to purge."
    job_root=$(abspath "$job_dir")
    work_root=$(abspath "$CFG_WORK_DIR")
    case "$job_root" in
        "$work_root"/*) ;;
        *) die 4 "Refusing to purge a folder outside the work directory: $job_dir" ;;
    esac

    target="$output"
    case "$(abspath "$output")" in
        "$job_root"|"$job_root"/*)
            output_root=$(abspath "$CFG_OUTPUT_DIR")
            case "$output_root" in
                "$job_root"|"$job_root"/*)
                    die 4 "output_dir must be outside the job folder: $output_root" "Point output_dir at a separate folder, for example output."
                    ;;
            esac
            mkdir -p "$CFG_OUTPUT_DIR"
            name=$(basename "$output")
            target="$CFG_OUTPUT_DIR/$name"
            index=1
            while [ -e "$target" ]; do
                target="$CFG_OUTPUT_DIR/${name%.*}_$index.${name##*.}"
                index=$((index + 1))
            done
            mv "$output" "$target" || die 7 "Could not move the output to $target" "The job folder was kept."
            log_info "Output moved: $target"
            ;;
    esac

    PUBLISHED_OUTPUT="$target"
    UVP_LOG_FILE=""
    rm -rf "$job_dir"
    log_info "Removed work folder: $job_dir"
}

job_frames_dir() {
    local value
    value=$(job_get frames_dir '')
    if [ -n "$value" ]; then
        case "$value" in
            /*) printf '%s\n' "$value" ;;
            *) printf '%s\n' "$JOB_DIR/$value" ;;
        esac
    else
        printf '%s\n' "$JOB_DIR/frames"
    fi
}

job_upscaled_dir() {
    local value
    value=$(job_get upscaled_dir '')
    if [ -n "$value" ]; then
        case "$value" in
            /*) printf '%s\n' "$value" ;;
            *) printf '%s\n' "$JOB_DIR/$value" ;;
        esac
    else
        printf '%s\n' "$JOB_DIR/upscaled"
    fi
}

clear_intermediates() {
    rm -rf "$JOB_DIR/frames" "$JOB_DIR/upscaled" "$JOB_DIR/sequence" "$JOB_DIR/chunks"
    local batch
    for batch in "$JOB_DIR"/batch_*; do
        [ -d "$batch" ] && rm -rf "$batch"
    done
}

OUTPUTS=()

CHUNK_ASSEMBLE_OUTPUT=""

assemble_chunked_job() {
    local job_path="$1" multiple="$2" dry="$3"
    local media duration fps chunk_seconds segments=() c idx cstart cend cframes candidate marker suffix
    local segment expected_w expected_h audio_mode subs_mode range_start i has_copy
    local final_output concat_name concat_path temp_output job_preset saved_name saved_container saved_ext saved_codec saved_audio saved_subs

    job_load "$job_path"
    probe_media "$(job_source_path)"
    save_media_state
    media="$M_SOURCE"
    duration=$(job_get duration "$M_DURATION")
    fps=$(job_get fps_decimal "$M_FPS_DECIMAL")
    chunk_seconds=$(job_get chunk_seconds 0)
    [ "$chunk_seconds" -gt 0 ] || die 4 "Chunked job has no chunk length: $(basename "$JOB_DIR")" "Resume it with the run command."
    plan_chunks "$duration" "$fps" "$chunk_seconds"
    [ "${#CH_INDEX[@]}" -gt 0 ] || die 4 "Chunk plan is empty: $(basename "$JOB_DIR")"

    for c in "${!CH_INDEX[@]}"; do
        idx="${CH_INDEX[$c]}"
        candidate=""
        for suffix in ts mov; do
            segment="$JOB_DIR/chunks/$(printf 'chunk_%04d' "$idx").$suffix"
            if [ -s "$segment" ]; then candidate="$segment"; break; fi
        done
        marker="$JOB_DIR/.done_chunk_$(printf '%04d' "$idx")"
        if [ -z "$candidate" ] || [ ! -f "$marker" ]; then
            die 4 "Chunk $idx is incomplete: $(basename "$JOB_DIR")" "Resume the job with the run command."
        fi
        segments[${#segments[@]}]="$candidate"
    done
    [ "${#segments[@]}" -gt 0 ] || die 4 "No chunk segments found: $JOB_DIR/chunks" "Resume the job with the run command."

    saved_name="$PRESET_NAME"; saved_container="$PRESET_CONTAINER"; saved_ext="$PRESET_EXT"
    saved_codec="$PRESET_CODEC"; saved_audio="$PRESET_AUDIO"; saved_subs="$PRESET_SUBS"
    job_preset=$(job_get preset "$PRESET_NAME")
    preset_resolve "$job_preset"
    if [ "$PRESET_CODEC" != "$saved_codec" ]; then
        die 4 "Chunked job was encoded as $PRESET_CODEC; use a matching preset instead of $saved_name."
    fi
    PRESET_NAME="$saved_name"; PRESET_CONTAINER="$saved_container"; PRESET_EXT="$saved_ext"
    PRESET_CODEC="$saved_codec"; PRESET_AUDIO="$saved_audio"; PRESET_SUBS="$saved_subs"

    probe_media "${segments[0]}"
    expected_w="$M_WIDTH"; expected_h="$M_HEIGHT"
    num_cmp "$M_DURATION" gt 0 || die 4 "Invalid chunk segment: ${segments[0]}"
    restore_media_state

    if [ -n "$EN_AUDIO" ]; then audio_mode="$EN_AUDIO"; elif [ "$CFG_DEFAULT_AUDIO" != "auto" ]; then audio_mode="$CFG_DEFAULT_AUDIO"; else audio_mode="$PRESET_AUDIO"; fi
    if [ -n "$EN_SUBS" ]; then subs_mode="$EN_SUBS"; elif [ "$CFG_DEFAULT_SUBS" != "auto" ]; then subs_mode="$CFG_DEFAULT_SUBS"; else subs_mode="$PRESET_SUBS"; fi
    audio_plan "$audio_mode" "$EN_AUDIO_BITRATE" "$EN_ALL_AUDIO"
    range_start=$(job_get range_start 0)
    if num_cmp "$range_start" gt 0; then
        has_copy=0
        i=0
        while [ "$i" -lt "${#AUD_MODE[@]}" ]; do [ "${AUD_MODE[$i]}" = "copy" ] && has_copy=1; i=$((i + 1)); done
        if [ "$has_copy" -eq 1 ]; then
            log_warn "Trimming active: copied audio is re-encoded as AAC for a sample-accurate start."
            i=0
            while [ "$i" -lt "${#AUD_MODE[@]}" ]; do [ "${AUD_MODE[$i]}" = "copy" ] && AUD_MODE[$i]=aac; i=$((i + 1)); done
        fi
        [ "$M_CHAPTERS" -gt 0 ] && log_warn "Chapters come from the source and may not be shifted for the trimmed range."
    fi
    subtitle_plan "$subs_mode"
    final_output=$(resolve_output_path "$PRESET_EXT" "$multiple") || exit $?
    if [ "$dry" -eq 1 ]; then
        log_info "Would assemble chunked $(basename "$JOB_DIR") (${#segments[@]} segment(s)) -> $final_output"
        CHUNK_ASSEMBLE_OUTPUT="$final_output"
        return 0
    fi
    [ -n "$EN_UPSCALED_DIR" ] && log_warn "--upscaled-dir is ignored for a chunked job."

    temp_output="$(dirname "$final_output")/$(basename "$final_output" | sed 's/\.[^.]*$//').partial.${final_output##*.}"
    PARTIAL_PATH="$temp_output"
    mkdir -p "$(dirname "$final_output")" || die 1 "Could not create $(dirname "$final_output")"
    job_clear_stage assemble
    if [ "${segments[0]##*.}" = "mov" ]; then concat_name="concat.mov"; else concat_name="concat.ts"; fi
    concat_path="$JOB_DIR/chunks/$concat_name"
    concat_segments "$concat_path" "${segments[@]}"
    build_mux_command "$CONCAT_OUTPUT" "$temp_output" "$duration"
    CMD[0]="$CFG_FFMPEG"
    log_debug "\$ $(display_command "${CMD[@]}")"
    run_child "${CMD[@]}"
    if [ "$LAST_RC" -ne 0 ]; then
        local detail
        detail=$(child_tail 50)
        cleanup_temp_files
        die 7 "Could not mux the final output" "$detail"
    fi
    cleanup_temp_files
    repair_color_tags "$temp_output" "$PRESET_CONTAINER"
    validate_output "$temp_output" "$expected_w" "$expected_h" "$AUD_ENABLED" "${#SUB_MODE[@]}"
    mv -f "$temp_output" "$final_output" || die 1 "Could not write $final_output"
    PARTIAL_PATH=""
    [ "$EN_KEEP_CHUNKS" -eq 1 ] || rm -rf "$JOB_DIR/chunks"
    job_set preset "$PRESET_NAME"
    job_set encoder "$EN_ENCODER"
    job_set audio "$audio_mode"
    job_set subs "$subs_mode"
    job_set last_error ""
    job_save
    job_mark assemble
    if [ "$EN_CLEANUP" -eq 1 ]; then
        publish_and_purge "$JOB_DIR" "$final_output"
        final_output="$PUBLISHED_OUTPUT"
        UVP_LOG_FILE=""
    fi
    CHUNK_ASSEMBLE_OUTPUT="$final_output"
    return 0
}

run_assemble() {
    local dry_run="$1"; shift
    local jobs
    jobs=("$@")
    local job_path job_count multiple=0 cli_target
    job_count=${#jobs[@]}
    [ "$job_count" -gt 1 ] && multiple=1
    OUTPUTS=()
    preset_resolve "$EN_PRESET"
    cli_target="$EN_TARGET"
    for job_path in "${jobs[@]}"; do
        EN_TARGET="$cli_target"
        job_load "$job_path"
        local effective_target="$cli_target" stored_target
        if [ -z "$effective_target" ]; then
            stored_target=$(job_get target_height '')
            [ -n "$stored_target" ] && effective_target="$stored_target"
        fi
        EN_TARGET="$effective_target"
        if [ "$EN_TENBIT" -eq 1 ] && [ "$(job_get tonemap 0)" = "1" ]; then
            die 4 "--10bit cannot be combined with a tonemapped job."
        fi
        [ "$dry_run" -eq 1 ] || set_log_file "$JOB_DIR/logs/assemble.log"
        if job_source_changed && [ "$EN_FORCE" -ne 1 ]; then
            die 4 "Source changed since the job was created: $(job_source_path)" "Use --force only if the existing upscaled frames still match the source."
        fi
        if job_has_chunks; then
            assemble_chunked_job "$JOB_DIR" "$multiple" "$dry_run"
            OUTPUTS[${#OUTPUTS[@]}]="$CHUNK_ASSEMBLE_OUTPUT"
            continue
        fi
        probe_media "$(job_source_path)"
        local upscaled_dir
        if [ -n "$EN_UPSCALED_DIR" ]; then
            upscaled_dir=$(abspath "$EN_UPSCALED_DIR")
        else
            upscaled_dir=$(job_get upscaled_dir '')
            if [ -n "$upscaled_dir" ]; then
                case "$upscaled_dir" in
                    /*) ;;
                    *) upscaled_dir="$JOB_DIR/$upscaled_dir" ;;
                esac
                upscaled_dir=$(abspath "$upscaled_dir")
            else
                upscaled_dir="$JOB_DIR/upscaled"
            fi
        fi
        [ -d "$upscaled_dir" ] || die 4 "No upscaled frames found: $upscaled_dir" "Run Upscayl on the frames folder first, or pass --upscaled-dir."
        local any_frame
        any_frame=$(find "$upscaled_dir" -maxdepth 2 -type f -name 'frame_*' -size +0c 2>/dev/null | head -n 1)
        [ -n "$any_frame" ] || die 4 "No upscaled frames found: $upscaled_dir" "Run Upscayl on the frames folder first, or pass --upscaled-dir."

        local stored_count expected_arg
        stored_count=$(job_get frame_count 0)
        expected_arg=""
        [ "$stored_count" -gt 0 ] && expected_arg="$stored_count"
        validate_frame_set "$upscaled_dir" "$expected_arg" "$EN_PICK" "$EN_VERIFY"
        if [ "$dry_run" -eq 0 ]; then build_sequence; fi
        local dims frame_w frame_h
        dims=$(probe_frame_dimensions "${FS_PATHS[0]}") || exit $?
        frame_w=${dims%%,*}; frame_h=${dims#*,}
        output_dimensions "$frame_w" "$frame_h" "$EN_TARGET" "$EN_ALLOW_HUGE"
        local expected_w="$OUT_W" expected_h="$OUT_H"

        local audio_mode subs_mode
        if [ -n "$EN_AUDIO" ]; then audio_mode="$EN_AUDIO"
        elif [ "$CFG_DEFAULT_AUDIO" != "auto" ]; then audio_mode="$CFG_DEFAULT_AUDIO"
        else audio_mode="$PRESET_AUDIO"; fi
        if [ -n "$EN_SUBS" ]; then subs_mode="$EN_SUBS"
        elif [ "$CFG_DEFAULT_SUBS" != "auto" ]; then subs_mode="$CFG_DEFAULT_SUBS"
        else subs_mode="$PRESET_SUBS"; fi
        audio_plan "$audio_mode" "$EN_AUDIO_BITRATE" "$EN_ALL_AUDIO"
        local range_start i
        range_start=$(job_get range_start 0)
        if num_cmp "$range_start" gt 0; then
            local has_copy=0
            i=0
            while [ "$i" -lt "${#AUD_MODE[@]}" ]; do [ "${AUD_MODE[$i]}" = "copy" ] && has_copy=1; i=$((i + 1)); done
            if [ "$has_copy" -eq 1 ]; then
                log_warn "Trimming active: copied audio is re-encoded as AAC for a sample-accurate start."
                i=0
                while [ "$i" -lt "${#AUD_MODE[@]}" ]; do [ "${AUD_MODE[$i]}" = "copy" ] && AUD_MODE[$i]=aac; i=$((i + 1)); done
            fi
            [ "$M_CHAPTERS" -gt 0 ] && log_warn "Chapters come from the source and may not be shifted for the trimmed range."
        fi
        subtitle_plan "$subs_mode"
        encoder_candidates "$EN_ENCODER"
        local final_output
        final_output=$(resolve_output_path "$PRESET_EXT" "$multiple") || exit $?
        if [ "$dry_run" -eq 1 ]; then
            log_info "Would assemble $(basename "$JOB_DIR") -> $final_output"
            OUTPUTS[${#OUTPUTS[@]}]="$final_output"
            continue
        fi
        mkdir -p "$(dirname "$final_output")" || die 4 "Could not create output directory: $(dirname "$final_output")"
        PARTIAL_PATH="$(dirname "$final_output")/$(basename "$final_output" | sed 's/\.[^.]*$//').partial.${final_output##*.}"
        job_clear_stage assemble
        local index=0 rc=0 detail
        while [ "$index" -lt "${#CAND_CODEC[@]}" ]; do
            CHOSEN_FAMILY="${CAND_FAMILY[$index]}"
            CHOSEN_CODEC="${CAND_CODEC[$index]}"
            build_assemble_command "$PARTIAL_PATH" "$frame_w" "$frame_h"
            CMD[0]="$CFG_FFMPEG"
            log_debug "\$ $(display_command "${CMD[@]}")"
            run_child "${CMD[@]}"
            rc=$?
            if [ "$rc" -eq 0 ]; then break; fi
            detail=$(child_tail 50)
            if [ "$EN_ENCODER" = "auto" ] && [ "$index" -lt $(( ${#CAND_CODEC[@]} - 1 )) ]; then
                log_warn "Encoder $CHOSEN_CODEC failed; trying the next encoder."
                index=$((index + 1))
                continue
            fi
            rm -f "$PARTIAL_PATH"; PARTIAL_PATH=""
            cleanup_temp_files
            die 7 "Encoding failed for: $(job_source_path)" "$detail"
        done
        cleanup_temp_files
        repair_color_tags "$PARTIAL_PATH" "$PRESET_CONTAINER"
        validate_output "$PARTIAL_PATH" "$expected_w" "$expected_h" "$AUD_ENABLED" "${#SUB_MODE[@]}"
        mv -f "$PARTIAL_PATH" "$final_output" || die 1 "Could not write $final_output"
        PARTIAL_PATH=""
        rm -rf "$JOB_DIR/sequence"
        job_set upscaled_count "$FS_COUNT"
        job_set preset "$PRESET_NAME"
        job_set encoder "$EN_ENCODER"
        job_set encoder_codec "$CHOSEN_CODEC"
        job_set audio "$audio_mode"
        job_set audio_bitrate "$EN_AUDIO_BITRATE"
        job_set all_audio "$EN_ALL_AUDIO"
        job_set subs "$subs_mode"
        job_set ten_bit "$EN_TENBIT"
        job_set target_height "$EN_TARGET"
        job_set last_error ""
        job_save
        job_mark assemble
        if [ "$EN_CLEANUP" -eq 1 ]; then
            publish_and_purge "$JOB_DIR" "$final_output"
            final_output="$PUBLISHED_OUTPUT"
            UVP_LOG_FILE=""
        fi
        OUTPUTS[${#OUTPUTS[@]}]="$final_output"
    done
}
