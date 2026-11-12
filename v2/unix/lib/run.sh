# Upscayl Video Pipeline V2 - run module.
# The all-in-one run over one or more inputs.
# Sourced by upscayl-video.sh; not meant to be run directly.
# shellcheck shell=bash

# ---------------------------------------------------------------------------
# Run all, status, clean
# ---------------------------------------------------------------------------

RUN_FAILED=0
RUN_EXIT_CODE=0
RUN_RESULTS=()

run_one_input() {
    local input="$1" result_file="$2" job output t0 t1 t2 t3
    t0=$(date +%s)
    run_split 0 "${OPT_YES:-0}" 0 "$input"
    job="${JOB_PATHS[0]}"
    t1=$(date +%s)
    run_upscale 0 "$job"
    t2=$(date +%s)
    run_assemble 0 "$job"
    t3=$(date +%s)
    log_debug "stage timings: split=$((t1 - t0))s upscale=$((t2 - t1))s assemble=$((t3 - t2))s"
    output="${OUTPUTS[0]}"
    write_text_atomic "$result_file" "job=$job
output=$output
"
}

AUTO_CHUNK_SECONDS=0

auto_chunk_seconds() {
    local input="$1" source start end duration fps frames scale sample free cap floor
    source=$(abspath "$input")
    probe_media "$source"
    num_cmp "$M_DURATION" gt 0 || { AUTO_CHUNK_SECONDS=0; return 0; }
    start=0
    if [ -n "$SP_START" ]; then start=$(parse_time_value "$SP_START") || exit $?; fi
    if [ -n "$SP_END" ]; then end=$(parse_time_value "$SP_END") || exit $?; else end="$M_DURATION"; fi
    if num_cmp "$end" gt "$M_DURATION"; then end="$M_DURATION"; fi
    duration=$(fcalc "$end" '-' "$start" '%.6f')
    num_cmp "$duration" gt 0 || { AUTO_CHUNK_SECONDS=0; return 0; }
    find_or_create_job "$CFG_WORK_DIR" "$source" 0
    if job_has_chunks; then
        local stored
        stored=$(job_get chunk_seconds 0)
        [ "$stored" -gt 0 ] || stored=60
        AUTO_CHUNK_SECONDS="$stored"
        return 0
    fi
    if test_has_frames; then AUTO_CHUNK_SECONDS=0; return 0; fi
    resolve_scale
    scale="$SCALE_CHOSEN"
    fps="$M_FPS_DECIMAL"
    frames=$(round_even "$(fcalc "$duration" '*' "$fps" '%.9f')")
    sample=$(sample_frame_bytes "$(job_source_path)" "$start" "$duration" "$SP_FORMAT" "$SP_DENOISE" "$SP_TONEMAP" "$SP_DECODE") || exit $?
    disk_estimate "$sample" "$frames" "$scale"
    free=$(free_bytes "$CFG_WORK_DIR")
    log_info "Auto-chunk estimate: $(format_duration "$duration"), $frames frames, estimated $(format_bytes "$EST_TOTAL_BYTES"), free $(format_bytes "$free")"
    cap=$((CFG_MAX_WORK_GB * 1073741824))
    floor=$((CFG_MIN_FREE_GB * 1073741824))
    if [ "$EST_TOTAL_BYTES" -gt "$cap" ] || [ $((free - EST_TOTAL_BYTES)) -lt "$floor" ]; then
        log_info "Automatic chunking enabled; using 60s chunks."
        AUTO_CHUNK_SECONDS=60
    else
        AUTO_CHUNK_SECONDS=0
    fi
}

run_all() {
    local dry_run="$1"; shift
    local inputs
    inputs=("$@")
    local input result_file err_file err_text rc chunk_value output_text status name
    if [ "${#inputs[@]}" -gt 1 ] && [ -n "$EN_OUTPUT" ]; then
        local requested_output requested_base
        requested_output=$(abspath "$EN_OUTPUT")
        requested_base=${requested_output##*/}
        case "$requested_base" in
            *.*) if [ ! -d "$requested_output" ]; then
                    die 2 "With multiple inputs, --output must be a directory." "Pass a directory (or omit --output)."
                 fi ;;
        esac
    fi
    if [ "$dry_run" -eq 1 ]; then
        preset_resolve "$EN_PRESET"
        local dry_results=()
        for input in "${inputs[@]}"; do
            run_split 0 "${OPT_YES:-0}" 1 "$input"
            local duration fps frames scale chunk_seconds chunks output
            duration=$(job_get duration 0)
            fps=$(job_get fps_decimal 0)
            frames=$(round_even "$(fcalc "$duration" '*' "$fps" '%.9f')")
            scale=$(job_get scale 0)
            [ "$scale" -gt 0 ] || scale="$US_SCALE"
            chunk_value=$(lower "$(trim "$RUN_CHUNK_SECONDS")")
            if [ "$chunk_value" != "0" ] && [ "$chunk_value" != "auto" ]; then
                case "$chunk_value" in *[!0-9]*) die 4 "Invalid --chunk-seconds: $chunk_value" ;; esac
                chunk_seconds="$chunk_value"
                [ "$chunk_seconds" -ge 10 ] || chunk_seconds=10
                plan_chunks "$duration" "$fps" "$chunk_seconds"
                log_info "Would process $frames frames in ${#CH_INDEX[@]} chunks of ${chunk_seconds}s"
            elif [ "$chunk_value" = "auto" ]; then
                log_info "Would decide automatic chunking for $frames frames from the disk estimate"
            fi
            log_info "Would upscale $frames frames with $US_MODEL at ${scale}x"
            output=$(default_output_path "$PRESET_EXT")
            log_info "Would assemble -> $output"
            dry_results[${#dry_results[@]}]="DRY|$input|-"
        done
        if [ "$UVP_QUIET" -eq 0 ]; then
            printf '%-32s %-8s %s\n' "INPUT" "STATUS" "OUTPUT"
            local entry
            for entry in "${dry_results[@]}"; do
                local d_status="${entry%%|*}"
                local rest="${entry#*|}"
                local d_input="${rest%%|*}"
                local d_name
                d_name=$(basename "$d_input")
                printf '%-32s %-8s %s\n' "${d_name:0:32}" "$d_status" "-"
            done
        fi
        return 0
    fi
    RUN_FAILED=0; RUN_RESULTS=()
    for input in "${inputs[@]}"; do
        JOB_DIR=""
        result_file=$(new_temp_file)
        err_file=$(new_temp_file)
        chunk_value=$(lower "$(trim "$RUN_CHUNK_SECONDS")")
        chunk_seconds=0
        if [ "$chunk_value" = "auto" ]; then
            auto_chunk_seconds "$input"
            chunk_seconds="$AUTO_CHUNK_SECONDS"
        elif [ "$chunk_value" != "0" ]; then
            case "$chunk_value" in *[!0-9]*) die 4 "Invalid --chunk-seconds: $chunk_value" ;; esac
            chunk_seconds="$chunk_value"
            if [ "$chunk_seconds" -lt 10 ]; then
                log_warn "--chunk-seconds $chunk_seconds is below the minimum; using 10 seconds."
                chunk_seconds=10
            fi
        fi
        if [ "$chunk_seconds" -gt 0 ]; then
            (
                UVP_ERROR_FILE="$err_file"
                run_chunked "$input" "$chunk_seconds"
                write_text_atomic "$result_file" "job=$JOB_DIR
output=$CHUNK_OUTPUT
"
            )
            rc=$?
        else
            (
                UVP_ERROR_FILE="$err_file"
                run_one_input "$input" "$result_file"
            )
            rc=$?
        fi
        if [ "$rc" -eq 0 ]; then
            output_text=$(sed -n 's/^output=//p' "$result_file" | head -n 1)
            RUN_RESULTS[${#RUN_RESULTS[@]}]="OK|$input|$output_text"
        else
            err_text=$(head -n 1 "$err_file" 2>/dev/null)
            [ -n "$err_text" ] || err_text="failed with exit code $rc"
            RUN_RESULTS[${#RUN_RESULTS[@]}]="FAILED|$input|$err_text"
            RUN_FAILED=1
            [ "$RUN_EXIT_CODE" -eq 0 ] && RUN_EXIT_CODE=$rc
            if [ "$RUN_STOP_ON_ERROR" -eq 1 ]; then
                rm -f "$result_file" "$err_file"
                break
            fi
        fi
        rm -f "$result_file" "$err_file"
    done
    if [ "$UVP_QUIET" -eq 0 ]; then
        printf '%-32s %-8s %s\n' "INPUT" "STATUS" "OUTPUT"
        local entry
        for entry in "${RUN_RESULTS[@]}"; do
            status="${entry%%|*}"
            entry="${entry#*|}"
            input="${entry%%|*}"
            output_text="${entry#*|}"
            name=$(basename "$input")
            printf '%-32s %-8s %s\n' "${name:0:32}" "$status" "$output_text"
        done
    fi
    [ "$RUN_FAILED" -eq 0 ] && return 0
    return 1
}
