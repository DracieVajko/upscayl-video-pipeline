# Upscayl Video Pipeline V2 - admin module.
# split-all, finish, status and clean.
# Sourced by upscayl-video.sh; not meant to be run directly.
# shellcheck shell=bash

split_all() {
    SP_FORMAT="${SP_FORMAT:-png}"; SP_PNG="${SP_PNG:-1}"; SP_JPEG="${SP_JPEG:-1}"
    SP_DENOISE="${SP_DENOISE:-none}"; SP_TONEMAP="${SP_TONEMAP:-0}"; SP_DECODE="${SP_DECODE:-auto}"
    SP_SCALE="${SP_SCALE:-$CFG_DEFAULT_SCALE}"; SP_MODEL="${SP_MODEL:-$CFG_DEFAULT_MODEL}"
    SP_FORCE="${SP_FORCE:-0}"

    local input_dir="$CFG_INPUT_DIR" source frames_dir n media tonemap
    mkdir -p "$input_dir"
    local list
    list=$(find "$input_dir" -type f \( -iname '*.mp4' -o -iname '*.mov' -o -iname '*.mkv' -o -iname '*.avi' -o -iname '*.webm' -o -iname '*.m4v' -o -iname '*.mts' -o -iname '*.m2ts' \) | sort)
    if [ -z "$list" ]; then die 2 "No videos found in: $input_dir" "Put the original videos in the input folder and run again."; fi
    log_info "Inputs: $(printf '%s\n' "$list" | wc -l | tr -d ' ') - work: $CFG_WORK_DIR"

    if [ "$OPT_DRY_RUN" -eq 1 ]; then log_info "Dry run: nothing written."; return 0; fi

    while IFS= read -r source; do
        [ -n "$source" ] || continue
        source=$(abspath "$source")
        probe_media "$source"
        tonemap=0
        if [ "$SP_TONEMAP" -eq 1 ]; then tonemap=1
        elif [ "$OPT_NO_TONEMAP" -eq 1 ]; then tonemap=0
        elif [ "$M_HDR" = "1" ]; then tonemap=1; fi
        if [ "$M_HDR" = "1" ] && [ "$tonemap" -ne 1 ]; then
            die 4 "HDR source detected. Upscayl models are 8-bit SDR." "Re-run with --tonemap to convert HDR to SDR BT.709."
        fi
        SP_TONEMAP="$tonemap"
        run_split 0 1 "$OPT_DRY_RUN" "$source" || { log_error "Failed: $source"; continue; }
        job_load "$JOB_DIR"
        if [ -z "$(job_get frames_dir '')" ]; then
            mkdir -p "$JOB_DIR/batch00001" || die 1 "Could not create batch dir"
            mv "$JOB_DIR/frames" "$JOB_DIR/batch00001/in"
            rm -rf "$JOB_DIR/frames" "$JOB_DIR/upscaled" 2>/dev/null || true
            job_set frames_dir batch00001/in
            job_set upscaled_dir batch00001/out
            job_set layout batches
            job_save
        fi
        mkdir -p "$JOB_DIR/batch00001/out"
        # audio
        local audio_dir="$JOB_DIR/audio" idx n=0
        mkdir -p "$audio_dir"
        local indices
        indices=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$source" 2>/dev/null)
        if [ -z "$indices" ]; then
            job_set audio_tracks 0; job_save
            printf 'tracks=0\n' > "$audio_dir/info.txt"
        else
            printf 'tracks=%s\n' "$(printf '%s\n' "$indices" | wc -l | tr -d ' ')" > "$audio_dir/info.txt"
            while IFS= read -r idx; do
                [ -n "$idx" ] || continue
                n=$((n + 1))
                local target
                target="$audio_dir/track$(printf '%02d' "$n").mka"
                if ! ffmpeg -hide_banner -nostdin -y -i "$source" -map "0:$idx" -vn -sn -dn -c copy "$target" >/dev/null 2>&1; then
                    ffmpeg -hide_banner -nostdin -y -i "$source" -map "0:$idx" -vn -sn -dn -c:a flac "$target" >/dev/null 2>&1
                fi
            done <<EOF
$indices
EOF
            job_set audio_tracks "$n"; job_save
        fi
        log_info "Job $(basename "$JOB_DIR"): frames -> $JOB_DIR/batch00001/in"
    done <<EOF
$list
EOF

    local jobs job
    jobs=$(find_jobs "$CFG_WORK_DIR")
    if [ -n "$jobs" ]; then
        {
            printf 'job,source,frames,in,out,audio_tracks,output\n'
            while IFS= read -r job; do
                [ -n "$job" ] || continue
                job_load "$job"
                printf '%s,%s,%s,%s,%s,%s,%s\n' "$(basename "$job")" "$(job_source_path)" "$(job_get frame_count 0)" "$(job_frames_dir)" "$(job_upscaled_dir)" "$(job_get audio_tracks 0)" "$job/output"
            done <<EOF
$jobs
EOF
        } > "$CFG_WORK_DIR/manifest.csv"
        printf 'Upscayl Video Pipeline - workspace\n\nPoint the Upscayl GUI at:\n  Input:  <job>/batch00001/in\n  Output: <job>/batch00001/out\n\nThen run: upscayl-video.sh finish --all\n\nJobs:\n' > "$CFG_WORK_DIR/README-UPScayl.txt"
        while IFS= read -r job; do
            [ -n "$job" ] || continue
            printf '  %s: %s\n' "$(basename "$job")" "$job" >> "$CFG_WORK_DIR/README-UPScayl.txt"
        done <<EOF
$jobs
EOF
    fi
    return 0
}

finish_all() {
    local failed=0 job count upscaled_dir
    local profile preset quality encoder
    for job in "$@"; do
        [ -d "$job" ] || { log_warn "Job not found: $job"; failed=$((failed + 1)); continue; }
        if [ "${OPT_RESUME:-0}" = "1" ] && [ -f "$job/checkpoint" ]; then
            log_info "Resume: skipping completed job $(basename "$job")"
            continue
        fi
        job_load "$job"
        upscaled_dir=$(job_upscaled_dir)
        frames_dir=$(job_frames_dir)
        in_count=$(find "$frames_dir" -type f -name 'frame_*' 2>/dev/null | wc -l | tr -d ' ')
        out_count=$(find "$upscaled_dir" -type f -name 'frame_*' 2>/dev/null | wc -l | tr -d ' ')
        if [ "${OPT_RESUME:-0}" = "1" ]; then
            if [ -f "$job/checkpoint" ]; then
                log_info "Resume: skipping completed job $(basename "$job")"
                continue
            fi
            if [ "$in_count" -gt 0 ] && [ "$out_count" -ge "$in_count" ]; then
                log_info "Resume: job $(basename "$job") already upscaled ($out_count/$in_count) — writing checkpoint"
                printf 'completed=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$job/checkpoint"
                continue
            fi
        fi
        count=$out_count
        if [ "$count" -eq 0 ]; then log_warn "Skipping $(basename "$job"): no upscaled frames"; continue; fi
        profile="${OPT_PROFILE:-default}"
        preset=""; quality=""; encoder=""
        if [ "$profile" = "fast" ]; then preset="mp4-h264"; quality="fast"; encoder="auto"
        elif [ "$profile" = "quality" ]; then preset="mp4-hevc"; quality="quality"; encoder="auto"
        else preset="${OPT_PRESET:-$CFG_DEFAULT_PRESET}"; quality="${OPT_QUALITY:-balanced}"; encoder="${OPT_ENCODER:-$CFG_DEFAULT_ENCODER}"; fi
        [ -n "$OPT_PRESET" ] && preset="$OPT_PRESET"
        [ -n "$OPT_ENCODER" ] && encoder="$OPT_ENCODER"
        [ -n "$OPT_QUALITY" ] && quality="$OPT_QUALITY"
        if [ "${OPT_RESUME:-0}" = "1" ] && [ -f "$job/checkpoint" ]; then
            log_info "Resume: skipping completed job $(basename "$job")"
            continue
        fi
        EN_PRESET="$preset"; EN_ENCODER="$encoder"; EN_QUALITY="$quality"
        EN_TARGET=""; EN_OUTPUT=""; EN_UPSCALED_DIR=""; EN_PICK="error"; EN_VERIFY=0; EN_KEEP_CHUNKS=0
        EN_CLEANUP=1; [ "${OPT_KEEP:-0}" = "1" ] && EN_CLEANUP=0
        if ! run_assemble 0 "$job"; then
            log_error "Failed: $(basename "$job")"
            failed=$((failed + 1))
        else
            printf 'completed=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$job/checkpoint"
        fi
    done
    if [ -z "$(find_jobs "$CFG_WORK_DIR")" ]; then
        rm -f "$CFG_WORK_DIR/manifest.csv" "$CFG_WORK_DIR/README-UPScayl.txt"
    fi
    if [ "$failed" -gt 0 ]; then
        log_info "Finished with $failed failure(s)"
        return 1
    fi
    return 0
}

run_status() {
    local verbose="$1" jobs job job_id frames upscaled stage outputs output_text last_error
    jobs=$(find_jobs "$CFG_WORK_DIR")
    if [ -z "$jobs" ]; then
        log_info "No jobs found in: $CFG_WORK_DIR"
        return 0
    fi
    log_info "$(printf '%-24s %-10s %7s %9s  %s' JOB STAGE FRAMES UPSCALED OUTPUT)"
    while IFS= read -r job; do
        [ -n "$job" ] || continue
        job_load "$job"
        frames=$(count_contiguous_frames "$JOB_DIR/frames" "$(job_get frame_format png)")
        upscaled=$(find "$JOB_DIR/upscaled" -maxdepth 2 -type f -name 'frame_*' 2>/dev/null | wc -l | tr -d ' ')
        outputs=$(find "$JOB_DIR/output" -maxdepth 1 -type f 2>/dev/null | sort | head -n 1)
        output_text="-"
        [ -n "$outputs" ] && output_text="$(basename "$outputs") ($(format_bytes "$(file_size "$outputs")"))"
        last_error=$(job_get last_error '')
        # shellcheck disable=SC1010,SC2209  # shellcheck misreads a function call used as a condition
        if job_is_done "assemble" && [ -n "$outputs" ]; then stage=done
        elif [ -n "$last_error" ]; then stage=failed
        elif job_has_chunks; then stage=chunk
        elif [ "$upscaled" -gt 0 ]; then stage=assemble
        elif [ "$frames" -gt 0 ]; then stage=upscale
        elif job_is_done "split"; then stage=split
        else stage=empty; fi
        job_id=$(basename "$JOB_DIR")
        log_info "$(printf '%-24s %-10s %7s %9s  %s' "${job_id:0:24}" "$stage" "$frames" "$upscaled" "$output_text")"
        if [ "$verbose" -eq 1 ]; then
            log_info "  path: $JOB_DIR"
            log_info "  source: $(job_source_path)"
            log_info "  settings: scale=$(job_get scale '') target_height=$(job_get target_height '') model=$(job_get model '') frame_format=$(job_get frame_format '') decode=$(job_get decode '') preset=$(job_get preset '')"
        fi
    done <<EOF
$jobs
EOF
}

CLEAN_FRAMES=0; CLEAN_UPSCALED=0; CLEAN_CHUNKS=0; CLEAN_SEQUENCE=0
CLEAN_BATCH=0; CLEAN_OUTPUT=0; CLEAN_ALL_INTERMEDIATES=0

run_clean() {
    local dry_run="$1"; shift
    local jobs
    local job_path target source
    jobs=("$@")
    for job_path in "${jobs[@]}"; do
        job_load "$job_path"
        ensure_within "$JOB_DIR" "$CFG_WORK_DIR" >/dev/null
        [ -f "$JOB_DIR/job.txt" ] || die 4 "Not a job folder: $JOB_DIR"
        local -a targets
        targets=()
        if [ "$CLEAN_ALL_INTERMEDIATES" -eq 1 ]; then CLEAN_FRAMES=1; CLEAN_UPSCALED=1; CLEAN_CHUNKS=1; CLEAN_SEQUENCE=1; CLEAN_BATCH=1; fi
        [ "$CLEAN_FRAMES" -eq 1 ] && targets[${#targets[@]}]="$JOB_DIR/frames"
        [ "$CLEAN_UPSCALED" -eq 1 ] && targets[${#targets[@]}]="$JOB_DIR/upscaled"
        [ "$CLEAN_CHUNKS" -eq 1 ] && targets[${#targets[@]}]="$JOB_DIR/chunks"
        [ "$CLEAN_SEQUENCE" -eq 1 ] && targets[${#targets[@]}]="$JOB_DIR/sequence"
        if [ "$CLEAN_BATCH" -eq 1 ]; then
            local batch
            for batch in "$JOB_DIR"/batch_*; do [ -d "$batch" ] && targets[${#targets[@]}]="$batch"; done
        fi
        [ "$CLEAN_OUTPUT" -eq 1 ] && targets[${#targets[@]}]="$JOB_DIR/output"
        source=$(job_source_path)
        for target in "${targets[@]}"; do
            target=$(ensure_within "$target" "$JOB_DIR") || exit $?
            if same_path "$source" "$target" || within_path "$source" "$target"; then
                die 4 "Refusing to delete a folder that contains the source video: $target"
            fi
            [ -e "$target" ] || continue
            if [ "$dry_run" -eq 1 ]; then log_info "Would delete: $target"; else rm -rf "$target" && log_info "Deleted: $target"; fi
        done
        if [ "$dry_run" -eq 0 ]; then
            [ "$CLEAN_FRAMES" -eq 1 ] && job_clear_stage split
            [ "$CLEAN_UPSCALED" -eq 1 ] && job_clear_stage upscale
            [ "$CLEAN_OUTPUT" -eq 1 ] && job_clear_stage assemble
        fi
    done
}
