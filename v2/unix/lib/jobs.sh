# Upscayl Video Pipeline V2 - jobs module.
# The job.txt contract: read, write and discover jobs.
# Sourced by upscayl-video.sh; not meant to be run directly.
# shellcheck shell=bash

# ---------------------------------------------------------------------------
# Jobs
# ---------------------------------------------------------------------------

JOB_DIR=""
JOB_KEYS=()
JOB_VALUES=()

job_load() {
    local dir="$1"
    dir=$(abspath "$dir")
    [ -d "$dir" ] && [ -f "$dir/job.txt" ] || die 4 "Not a job folder (missing job.txt): $dir"
    JOB_DIR="$dir"
    kv_load "$JOB_DIR/job.txt"
    JOB_KEYS=("${KV_KEYS[@]}")
    JOB_VALUES=("${KV_VALUES[@]}")
    if [ -z "$(job_get source '')" ]; then
        die 4 "Job has no source path: $dir"
    fi
}

job_get() {
    local key="$1" default="${2:-}" i=0
    while [ "$i" -lt "${#JOB_KEYS[@]}" ]; do
        if [ "${JOB_KEYS[$i]}" = "$key" ]; then
            printf '%s' "${JOB_VALUES[$i]}"
            return 0
        fi
        i=$((i + 1))
    done
    printf '%s' "$default"
}

job_has() {
    local key="$1" i=0
    while [ "$i" -lt "${#JOB_KEYS[@]}" ]; do
        [ "${JOB_KEYS[$i]}" = "$key" ] && return 0
        i=$((i + 1))
    done
    return 1
}

job_set() {
    local key="$1" value="$2" i=0
    while [ "$i" -lt "${#JOB_KEYS[@]}" ]; do
        if [ "${JOB_KEYS[$i]}" = "$key" ]; then
            JOB_VALUES[$i]="$value"
            return 0
        fi
        i=$((i + 1))
    done
    JOB_KEYS[${#JOB_KEYS[@]}]="$key"
    JOB_VALUES[${#JOB_VALUES[@]}]="$value"
}

job_save() {
    job_set updated "$(timestamp_now)"
    local text="" i=0
    while [ "$i" -lt "${#JOB_KEYS[@]}" ]; do
        text="$text${JOB_KEYS[$i]}=${JOB_VALUES[$i]}
"
        i=$((i + 1))
    done
    write_text_atomic "$JOB_DIR/job.txt" "$text"
    write_text_atomic "$JOB_DIR/source.txt" "$(job_source_path)
"
}

job_source_path() {
    abspath "$(job_get source '')"
}

job_mark() {
    : > "$JOB_DIR/.done_$1"
}

job_is_done() {
    [ -f "$JOB_DIR/.done_$1" ]
}

job_clear_stage() {
    rm -f "$JOB_DIR/.done_$1"
}

job_has_chunks() {
    local found
    found=$(find "$JOB_DIR" -maxdepth 1 -name '.done_chunk_*' -type f 2>/dev/null | head -n 1)
    [ -n "$found" ]
}

job_update_media() {
    job_set source "$M_SOURCE"
    job_set source_size "$M_SOURCE_SIZE"
    job_set source_mtime "$M_SOURCE_MTIME"
    job_set source_duration "$(fcalc "$M_DURATION" '+' 0 '%.3f')"
    job_set duration "$(fcalc "$M_DURATION" '+' 0 '%.3f')"
    job_set fps "$FPS_RATIONAL"
    job_set fps_decimal "$FPS_TEXT"
    job_set width "$M_WIDTH"
    job_set height "$M_HEIGHT"
    job_set pix_fmt "$M_PIX_FMT"
    job_set color_primaries "${M_COLOR_PRIMARIES:-unknown}"
    job_set color_trc "${M_COLOR_TRC:-unknown}"
    job_set colorspace "${M_COLOR_SPACE:-unknown}"
    job_set color_range "${M_COLOR_RANGE:-unknown}"
    job_set rotation "$M_ROTATION"
    if [ "$M_HDR" -eq 1 ]; then job_set hdr 1; else job_set hdr 0; fi
}

job_source_changed() {
    local size mtime stored_size stored_mtime
    job_has source_size || return 0
    job_has source_mtime || return 0
    [ -f "$(job_source_path)" ] || return 0
    size=$(file_size "$(job_source_path)")
    mtime=$(file_mtime "$(job_source_path)")
    stored_size=$(job_get source_size 0)
    stored_mtime=$(job_get source_mtime 0)
    [ "$size" = "$stored_size" ] && [ "$mtime" = "$stored_mtime" ] && return 1
    return 0
}

find_or_create_job() {
    local work_dir="$1" source="$2" create="${3:-1}"
    work_dir=$(abspath "$work_dir")
    source=$(abspath "$source")
    local base candidate suffix existing
    base=$(sanitize_job_id "$(basename "$source" | sed 's/\.[^.]*$//')")
    if [ "$create" -eq 1 ]; then mkdir -p "$work_dir" || die 1 "Could not create $work_dir"; fi
    candidate="$work_dir/$base"
    suffix=2
    while [ -e "$candidate" ]; do
        if [ -d "$candidate" ]; then
            existing=""
            if [ -f "$candidate/source.txt" ]; then
                existing=$(trim "$(read_text_file "$candidate/source.txt" | head -n 1)")
            fi
            if [ -z "$existing" ] && [ -f "$candidate/job.txt" ]; then
                existing=$(trim "$(sed -n 's/^source=//p' "$candidate/job.txt" | head -n 1)")
            fi
            if [ -n "$existing" ] && same_path "$existing" "$source"; then
                if [ -f "$candidate/job.txt" ]; then
                    job_load "$candidate"
                else
                    JOB_DIR="$candidate"
                    JOB_KEYS=(); JOB_VALUES=()
                    job_set version 1
                    job_set job_id "$(basename "$candidate")"
                    job_set source "$source"
                    job_set created "$(timestamp_now)"
                    job_set frame_pattern ""
                    job_set upscaled_dir ""
                    job_set frame_count 0
                    job_set upscaled_count 0
                    job_set chunk_seconds 0
                    job_set chunk_frames 0
                    job_set preset ""
                    job_set encoder ""
                    job_set audio ""
                    job_set audio_bitrate ""
                    job_set all_audio 0
                    job_set subs ""
                    job_set ten_bit 0
                    job_set target_height ""
                fi
                if [ "$create" -eq 1 ]; then
                    write_text_atomic "$JOB_DIR/source.txt" "$source
"
                fi
                log_debug "Reusing job: $candidate"
                return 0
            fi
        fi
        candidate="$work_dir/${base}_$suffix"
        suffix=$((suffix + 1))
    done

    JOB_DIR="$candidate"
    JOB_KEYS=(); JOB_VALUES=()
    job_set version 1
    job_set job_id "$(basename "$candidate")"
    job_set source "$source"
    job_set created "$(timestamp_now)"
    job_set frame_pattern ""
    job_set upscaled_dir ""
    job_set frame_count 0
    job_set upscaled_count 0
    job_set chunk_seconds 0
    job_set chunk_frames 0
    job_set preset ""
    job_set encoder ""
    job_set audio ""
    job_set audio_bitrate ""
    job_set all_audio 0
    job_set subs ""
    job_set ten_bit 0
    job_set target_height ""
    if [ "$create" -eq 1 ]; then
        mkdir -p "$candidate" || die 1 "Could not create $candidate"
        write_text_atomic "$JOB_DIR/source.txt" "$source
"
        log_debug "Created job: $candidate"
    fi
}

find_jobs() {
    local work_dir
    work_dir=$(abspath "$1")
    [ -d "$work_dir" ] || return 0
    find "$work_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | while IFS= read -r dir; do
        [ -f "$dir/job.txt" ] || continue
        if grep -q '^source=' "$dir/job.txt" 2>/dev/null || [ -s "$dir/source.txt" ]; then
            printf '%s\n' "$dir"
        fi
    done | sort -f
}
