# Upscayl Video Pipeline V2 - chunking module.
# Chunk planning and segment concatenation.
# Sourced by upscayl-video.sh; not meant to be run directly.
# shellcheck shell=bash

# ---------------------------------------------------------------------------
# Chunking
# ---------------------------------------------------------------------------

CH_INDEX=(); CH_START=(); CH_END=(); CH_START_FRAME=(); CH_FRAMES=()

plan_chunks() {
    local duration="$1" fps="$2" chunk_seconds="$3" total start end start_frame end_frame frame_count sum=0 idx=1
    CH_INDEX=(); CH_START=(); CH_END=(); CH_START_FRAME=(); CH_FRAMES=()
    [ "$chunk_seconds" -ge 10 ] || die 4 "Chunk length must be at least 10 seconds"
    if num_cmp "$duration" le 0 || num_cmp "$fps" le 0; then return 0; fi
    total=$(round_even "$(fcalc "$duration" '*' "$fps" '%.9f')")
    start=0
    while num_cmp "$start" lt "$(fcalc "$duration" '-' 0.000000001 '%.9f')"; do
        end=$(fcalc "$start" '+' "$chunk_seconds" '%.9f')
        if num_cmp "$end" gt "$duration"; then end="$duration"; fi
        start_frame=$(( $(round_even "$(fcalc "$start" '*' "$fps" '%.9f')") + 1 ))
        end_frame=$(round_even "$(fcalc "$end" '*' "$fps" '%.9f')")
        frame_count=$((end_frame - start_frame + 1))
        if [ "$frame_count" -gt 0 ]; then
            CH_INDEX[${#CH_INDEX[@]}]="$idx"
            CH_START[${#CH_START[@]}]="$start"
            CH_END[${#CH_END[@]}]="$end"
            CH_START_FRAME[${#CH_START_FRAME[@]}]="$start_frame"
            CH_FRAMES[${#CH_FRAMES[@]}]="$frame_count"
            sum=$((sum + frame_count))
            idx=$((idx + 1))
        fi
        start="$end"
    done
    [ "$sum" -eq "$total" ] || die 4 "Internal chunk frame accounting mismatch"
}

write_concat_list() {
    local output="$1"; shift
    local segments=("$@") segment native text
    text=""
    for segment in "${segments[@]}"; do
        native=$(abspath "$segment")
        # Git Bash may host a native Windows ffmpeg; concat list paths are not
        # converted by MSYS, so convert them explicitly when cygpath exists.
        if command -v cygpath >/dev/null 2>&1; then
            native=$(cygpath -m "$native")
        fi
        text="$text""file '$(printf '%s' "$native" | sed "s/'/'\\\\''/g")'
"
    done
    write_text_atomic "$output" "$text"
}

CONCAT_OUTPUT=""

concat_segments() {
    local output="$1"; shift
    local segments=("$@") list first_detail fallback fallback_list
    list="${output%.*}.txt"
    write_concat_list "$list" "${segments[@]}"
    CMD=("$CFG_FFMPEG" -hide_banner -nostdin -y -f concat -safe 0 -i "$list" -c copy -fflags +genpts "$output")
    log_debug "\$ $(display_command "${CMD[@]}")"
    run_child "${CMD[@]}"
    if [ "$LAST_RC" -eq 0 ]; then
        CONCAT_OUTPUT="$output"
        cleanup_temp_files
        return 0
    fi
    first_detail=$(child_tail 50)
    fallback="${output%.*}.mkv"
    fallback_list="${fallback%.*}.txt"
    write_concat_list "$fallback_list" "${segments[@]}"
    CMD=("$CFG_FFMPEG" -hide_banner -nostdin -y -f concat -safe 0 -i "$fallback_list" -c copy -fflags +genpts "$fallback")
    log_debug "\$ $(display_command "${CMD[@]}")"
    run_child "${CMD[@]}"
    if [ "$LAST_RC" -ne 0 ]; then
        local second_detail
        second_detail=$(child_tail 50)
        cleanup_temp_files
        die 7 "Could not concatenate chunk segments." "$first_detail
Matroska fallback: $second_detail"
    fi
    CONCAT_OUTPUT="$fallback"
    log_warn "Chunk concatenation failed in ${output##*.}; used Matroska fallback: $fallback"
    cleanup_temp_files
}

CHUNK_OUTPUT=""
RUN_CLEANUP=0
RUN_STOP_ON_ERROR=0
RUN_CHUNK_SECONDS="auto"

run_chunked() {
    local source="$1" chunk_seconds="$2"
    JOB_DIR=""
    probe_media "$source"
    num_cmp "$M_DURATION" gt 0 || die 4 "Could not determine video duration: $source"
    if [ -n "$SP_FPS" ]; then
        fps_override "$SP_FPS"
        M_FPS_NUM="$FPS_NUM"; M_FPS_DEN="$FPS_DEN"; M_FPS_RATIONAL="$FPS_RATIONAL"; M_FPS_DECIMAL="$FPS_DECIMAL"; M_FPS_TEXT="$FPS_TEXT"
    fi
    save_media_state
    local start end duration job
    if [ -n "$SP_START" ]; then start=$(parse_time_value "$SP_START") || exit $?; else start=0; fi
    if [ -n "$SP_END" ]; then end=$(parse_time_value "$SP_END") || exit $?; else end="$M_DURATION"; fi
    if num_cmp "$end" gt "$M_DURATION"; then end="$M_DURATION"; fi
    num_cmp "$start" lt "$end" || die 4 "Trim range is empty"
    duration=$(fcalc "$end" '-' "$start" '%.6f')
    find_or_create_job "$CFG_WORK_DIR" "$source" 1
    set_log_file "$JOB_DIR/logs/run.log"
    if [ "$M_HDR" -eq 1 ] && [ "$SP_TONEMAP" -ne 1 ]; then
        die 4 "HDR source detected. Upscayl models are 8-bit SDR." "Re-run with --tonemap to convert HDR to SDR BT.709."
    fi
    job_update_media
    if [ "$SP_TONEMAP" -eq 1 ]; then
        job_set color_primaries bt709; job_set color_trc bt709; job_set colorspace bt709; job_set color_range tv; job_set hdr 0
    fi
    resolve_scale
    local scale="$SCALE_CHOSEN" target="$TARGET_CHOSEN" total_frames
    total_frames=$(round_even "$(fcalc "$duration" '*' "$M_FPS_DECIMAL" '%.9f')")
    job_set duration "$(fcalc "$duration" '+' 0 '%.3f')"
    job_set range_start "$(fcalc "$start" '+' 0 '%.3f')"
    if [ -n "$SP_END" ]; then job_set range_end "$(fcalc "$end" '+' 0 '%.3f')"; else job_set range_end ""; fi
    job_set scale "$scale"
    job_set target_height "$target"
    job_set model "$SP_MODEL"
    job_set frame_format "$SP_FORMAT"
    job_set frame_pattern "$(frame_pattern "$SP_FORMAT")"
    job_set denoise "$SP_DENOISE"
    job_set decode "$SP_DECODE"
    job_set tonemap "$SP_TONEMAP"
    job_set frame_count "$total_frames"
    job_set upscaled_count 0
    job_set chunk_seconds "$chunk_seconds"
    job_set chunk_frames "$(round_even "$(fcalc "$chunk_seconds" '*' "$M_FPS_DECIMAL" '%.9f')")"
    job_save

    preset_resolve "$EN_PRESET"
    if [ -n "$US_BIN" ]; then CFG_UPSCAYL_BIN=$(abspath "$US_BIN"); fi
    if [ -n "$US_MODELS" ]; then CFG_MODELS_DIR=$(abspath "$US_MODELS"); fi
    resolve_upscayl_paths
    model_exists "$US_MODEL" || die 4 "Upscayl model not found: $US_MODEL"
    local vram tile icd
    vram=$(detect_vram_mb || true)
    resolve_tile "$US_TILE" "$vram"; tile="$TILE_VALUE"
    resolve_icd "$US_ICD"; icd="$ICD_PATH"
    plan_chunks "$duration" "$M_FPS_DECIMAL" "$chunk_seconds"
    [ "${#CH_INDEX[@]}" -gt 0 ] || die 4 "Chunk plan is empty"
    encoder_candidates "$EN_ENCODER"
    local audio_mode subs_mode
    if [ -n "$EN_AUDIO" ]; then audio_mode="$EN_AUDIO"; elif [ "$CFG_DEFAULT_AUDIO" != "auto" ]; then audio_mode="$CFG_DEFAULT_AUDIO"; else audio_mode="$PRESET_AUDIO"; fi
    if [ -n "$EN_SUBS" ]; then subs_mode="$EN_SUBS"; elif [ "$CFG_DEFAULT_SUBS" != "auto" ]; then subs_mode="$CFG_DEFAULT_SUBS"; else subs_mode="$PRESET_SUBS"; fi
    audio_plan "$audio_mode" "$EN_AUDIO_BITRATE" "$EN_ALL_AUDIO"
    if num_cmp "$start" gt 0; then
        local i=0
        while [ "$i" -lt "${#AUD_MODE[@]}" ]; do [ "${AUD_MODE[$i]}" = "copy" ] && AUD_MODE[$i]=aac; i=$((i + 1)); done
    fi
    subtitle_plan "$subs_mode"
    local final_output
    final_output=$(resolve_output_path "$PRESET_EXT" 0) || exit $?
    PARTIAL_PATH="$(dirname "$final_output")/$(basename "$final_output" | sed 's/\.[^.]*$//').partial.${final_output##*.}"
    mkdir -p "$(dirname "$final_output")" || die 1 "Could not create $(dirname "$final_output")"
    local chunks_dir="$JOB_DIR/chunks"
    local segments c
    segments=()
    local expected_w=0 expected_h=0 frames_done=0
    for c in "${!CH_INDEX[@]}"; do
        local idx="${CH_INDEX[$c]}" cstart="${CH_START[$c]}" cend="${CH_END[$c]}" cframes="${CH_FRAMES[$c]}"
        local free
        free=$(free_bytes "$CFG_WORK_DIR")
        [ "$free" -ge $((CFG_MIN_FREE_GB * 1073741824)) ] || die 5 "Free space fell below the configured minimum before a chunk."
        local ext segment marker chunk_dir frames_dir upscaled_dir split_start
        [ "$PRESET_CODEC" = "prores" ] && ext=mov || ext=ts
        segment="$chunks_dir/$(printf 'chunk_%04d' "$idx").$ext"
        marker="$JOB_DIR/.done_chunk_$(printf '%04d' "$idx")"
        segments[${#segments[@]}]="$segment"
        if [ -f "$marker" ] && [ -s "$segment" ]; then frames_done=$((frames_done + cframes)); continue; fi
        chunk_dir="$chunks_dir/$(printf 'chunk_%04d' "$idx")"
        rm -rf "$chunk_dir"
        frames_dir="$chunk_dir/frames"; upscaled_dir="$chunk_dir/upscaled"
        mkdir -p "$frames_dir" || die 1 "Could not create $frames_dir"
        split_start=$(fcalc "$start" '+' "$cstart" '%.6f')
        split_command "$(job_source_path)" "$split_start" "$(fcalc "$cend" '-' "$cstart" '%.6f')" 1 "$SP_FORMAT" "$SP_JPEG" "$SP_PNG" "$SP_DENOISE" "$SP_TONEMAP" "$SP_DECODE" "$frames_dir" "$cframes"
        CMD[0]="$CFG_FFMPEG"
        log_debug "\$ $(display_command "${CMD[@]}")"
        run_child "${CMD[@]}"
        [ "$LAST_RC" -eq 0 ] || { local detail; detail=$(child_tail 50); cleanup_temp_files; die 7 "Chunk $idx extraction failed" "$detail"; }
        cleanup_temp_files
        validate_frame_set "$frames_dir" "$cframes" error 0
        upscale_frames "$US_MODEL" "$US_SCALE" "$upscaled_dir" "$tile" "$(resolve_batch_size "$US_BATCH" $(( $(job_get width 1920) * scale )) $(( $(job_get height 1080) * scale )))" "$US_GPU" "$icd" "$US_THREADS" "$US_RETRY" "$frames_dir" "$cframes" "$total_frames" "$frames_done" "$US_ASSUME_YES"
        validate_frame_set "$upscaled_dir" "$cframes" error 0
        local dims frame_w frame_h
        dims=$(probe_frame_dimensions "${FS_PATHS[0]}") || exit $?
        frame_w=${dims%%,*}; frame_h=${dims#*,}
        EN_TARGET=""
        [ -n "$target" ] && EN_TARGET="$target"
        output_dimensions "$frame_w" "$frame_h" "$EN_TARGET" "$EN_ALLOW_HUGE"
        expected_w="$OUT_W"; expected_h="$OUT_H"
        local seg_ok=0 seg_detail=""
        local ci=0
        while [ "$ci" -lt "${#CAND_CODEC[@]}" ]; do
            CHOSEN_FAMILY="${CAND_FAMILY[$ci]}"; CHOSEN_CODEC="${CAND_CODEC[$ci]}"
            build_segment_command "$segment" "$frame_w" "$frame_h"
            CMD[0]="$CFG_FFMPEG"
            log_debug "\$ $(display_command "${CMD[@]}")"
            run_child "${CMD[@]}"
            if [ "$LAST_RC" -eq 0 ]; then seg_ok=1; break; fi
            seg_detail=$(child_tail 50)
            ci=$((ci + 1))
        done
        cleanup_temp_files
        [ "$seg_ok" -eq 1 ] || die 7 "Chunk $idx encode failed" "$seg_detail"
        probe_media "$segment"
        local segment_duration="$M_DURATION"
        restore_media_state
        num_cmp "$segment_duration" gt 0 || die 7 "Chunk $idx segment is invalid"
        : > "$marker"
        frames_done=$((frames_done + cframes))
        [ "$EN_KEEP_CHUNKS" -eq 1 ] || rm -rf "$chunk_dir"
    done
    if [ "$expected_w" -eq 0 ] && [ "${#segments[@]}" -gt 0 ]; then
        probe_media "${segments[0]}"
        expected_w="$M_WIDTH"; expected_h="$M_HEIGHT"
        restore_media_state
    fi
    local concat_output
    [ "$PRESET_CODEC" = "prores" ] && concat_output="$chunks_dir/concat.mov" || concat_output="$chunks_dir/concat.ts"
    concat_segments "$concat_output" "${segments[@]}"
    build_mux_command "$CONCAT_OUTPUT" "$PARTIAL_PATH" "$duration"
    CMD[0]="$CFG_FFMPEG"
    log_debug "\$ $(display_command "${CMD[@]}")"
    run_child "${CMD[@]}"
    if [ "$LAST_RC" -ne 0 ]; then local detail; detail=$(child_tail 50); cleanup_temp_files; die 7 "Could not mux the final output" "$detail"; fi
    cleanup_temp_files
    repair_color_tags "$PARTIAL_PATH" "$PRESET_CONTAINER"
    validate_output "$PARTIAL_PATH" "$expected_w" "$expected_h" "$AUD_ENABLED" "${#SUB_MODE[@]}"
    mv -f "$PARTIAL_PATH" "$final_output" || die 1 "Could not write $final_output"
    PARTIAL_PATH=""
    [ "$EN_KEEP_CHUNKS" -eq 1 ] || rm -rf "$chunks_dir"
    job_set preset "$PRESET_NAME"
    job_set encoder "$EN_ENCODER"
    job_set audio "$audio_mode"
    job_set subs "$subs_mode"
    job_set last_error ""
    job_save
    job_mark assemble
    if [ "$RUN_CLEANUP" -eq 1 ]; then
        publish_and_purge "$JOB_DIR" "$final_output"
        final_output="$PUBLISHED_OUTPUT"
        UVP_LOG_FILE=""
    fi
    CHUNK_OUTPUT="$final_output"
}
