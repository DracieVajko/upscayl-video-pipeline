# Upscayl Video Pipeline V2 - menu module.
# Interactive menu.
# Sourced by upscayl-video.sh; not meant to be run directly.
# shellcheck shell=bash

# ---------------------------------------------------------------------------
# Interactive menu
# ---------------------------------------------------------------------------

ask_value() {
    local label="$1" default="$2" answer
    if [ -n "$default" ]; then printf '%s [%s]: ' "$label" "$default" >&2; else printf '%s: ' "$label" >&2; fi
    IFS= read -r answer || answer=""
    answer=$(trim "$answer")
    [ -n "$answer" ] && printf '%s' "$answer" || printf '%s' "$default"
}

MENU_MODEL_NAMES=()
MENU_MODEL_DIRS=()
SELECTED_MODEL=""
SELECTED_MODEL_DIR=""
SELECTED_JOBS=()

menu_add_models() {
    local directory="$1" param name
    [ -d "$directory" ] || return 0
    for param in "$directory"/*.param; do
        [ -f "$param" ] || continue
        name=${param##*/}
        name=${name%.param}
        [ -f "$directory/$name.bin" ] || continue
        if ! array_contains "$name" "${MENU_MODEL_NAMES[@]}"; then
            MENU_MODEL_NAMES[${#MENU_MODEL_NAMES[@]}]="$name"
            MENU_MODEL_DIRS[${#MENU_MODEL_DIRS[@]}]="$directory"
        fi
    done
}

select_model() {
    MENU_MODEL_NAMES=(); MENU_MODEL_DIRS=()
    local discovery bin models
    if discovery=$( (resolve_upscayl_paths; printf '%s\n' "$UPSCAYL_BIN_PATH"; printf '%s\n' "$MODELS_DIR_PATH") 2>/dev/null ); then
        bin=$(printf '%s\n' "$discovery" | sed -n '1p')
        models=$(printf '%s\n' "$discovery" | sed -n '2p')
        [ -n "$models" ] && menu_add_models "$models"
        [ -n "$bin" ] && menu_add_models "$(dirname "$(dirname "$bin")")/models"
    fi
    [ -n "$CFG_MODELS_DIR" ] && menu_add_models "$CFG_MODELS_DIR"
    if [ "${#MENU_MODEL_NAMES[@]}" -eq 0 ]; then
        SELECTED_MODEL=$(ask_value "Model" "$CFG_DEFAULT_MODEL")
        SELECTED_MODEL_DIR=""
        return 0
    fi
    printf 'Models:\n'
    local i name hint
    i=0
    while [ "$i" -lt "${#MENU_MODEL_NAMES[@]}" ]; do
        name="${MENU_MODEL_NAMES[$i]}"
        case "$name" in
            upscayl-standard-4x) hint="general-purpose default" ;;
            upscayl-lite-4x) hint="fastest, good for long videos" ;;
            remacri-4x) hint="live-action detail" ;;
            ultramix-balanced-4x) hint="balanced live-action" ;;
            ultrasharp-4x) hint="sharp; may over-sharpen compressed sources" ;;
            high-fidelity-4x) hint="conservative, less hallucination" ;;
            digital-art-4x) hint="anime and illustrations" ;;
            *) hint="custom" ;;
        esac
        printf '  %s) %s - %s\n     %s\n' "$((i + 1))" "$name" "$hint" "${MENU_MODEL_DIRS[$i]}"
        i=$((i + 1))
    done
    local default_name="$CFG_DEFAULT_MODEL" answer number
    array_contains "$default_name" "${MENU_MODEL_NAMES[@]}" || default_name="${MENU_MODEL_NAMES[0]}"
    answer=$(ask_value "Model number or name" "$default_name")
    case "$answer" in
        *[!0-9]*|'') ;;
        *)
            number="$answer"
            if [ "$number" -ge 1 ] && [ "$number" -le "${#MENU_MODEL_NAMES[@]}" ]; then
                SELECTED_MODEL="${MENU_MODEL_NAMES[$((number - 1))]}"
                SELECTED_MODEL_DIR="${MENU_MODEL_DIRS[$((number - 1))]}"
                return 0
            fi
            ;;
    esac
    i=0
    while [ "$i" -lt "${#MENU_MODEL_NAMES[@]}" ]; do
        if [ "${MENU_MODEL_NAMES[$i]}" = "$answer" ]; then
            SELECTED_MODEL="$answer"
            SELECTED_MODEL_DIR="${MENU_MODEL_DIRS[$i]}"
            return 0
        fi
        i=$((i + 1))
    done
    SELECTED_MODEL="$answer"
    SELECTED_MODEL_DIR=""
}

select_jobs() {
    SELECTED_JOBS=()
    local target path answer number jobs job_path
    target=$(ask_value "Job folder or work dir" "")
    [ -n "$target" ] || return 0
    path=$(abspath "$target")
    if [ -f "$path/job.txt" ]; then
        SELECTED_JOBS[${#SELECTED_JOBS[@]}]="$path"
        return 0
    fi
    jobs=$(find_jobs "$path")
    if [ -z "$jobs" ]; then
        printf 'No jobs found in: %s\n' "$path"
        return 0
    fi
    printf 'Jobs:\n'
    number=0
    while IFS= read -r job_path; do
        [ -n "$job_path" ] || continue
        number=$((number + 1))
        job_load "$job_path"
        printf '  %s) %s <- %s\n' "$number" "$(basename "$job_path")" "$(job_source_path)"
    done <<EOF
$jobs
EOF
    answer=$(ask_value "Job number or 'a' for all" "a")
    answer=$(lower "$answer")
    case "$answer" in
        a|all)
            while IFS= read -r job_path; do
                [ -n "$job_path" ] && SELECTED_JOBS[${#SELECTED_JOBS[@]}]="$job_path"
            done <<EOF
$jobs
EOF
            ;;
        *[!0-9]*|'') printf 'Invalid job selection.\n' ;;
        *)
            number="$answer"
            if [ "$number" -ge 1 ]; then
                number=0
                while IFS= read -r job_path; do
                    [ -n "$job_path" ] || continue
                    number=$((number + 1))
                    if [ "$number" -eq "$answer" ]; then
                        SELECTED_JOBS[${#SELECTED_JOBS[@]}]="$job_path"
                        break
                    fi
                done <<EOF
$jobs
EOF
            fi
            ;;
    esac
}

menu_run_all() {
    local target model preset audio subs cleanup scale track tonemap=0 cleanup_default
    target=$(ask_value "Video file or folder" "")
    [ -n "$target" ] || return 0
    resolve_inputs 0 "$target"
    probe_media "${INPUT_PATHS[0]}"
    if [ "$M_HDR" -eq 1 ]; then
        local hdr_answer
        hdr_answer=$(ask_value "HDR source detected; tonemap to SDR BT.709? y/N" "n")
        case "$(lower "$hdr_answer")" in
            y|yes) tonemap=1 ;;
            *) printf 'Aborted: HDR requires --tonemap.\n'; return 0 ;;
        esac
    fi
    select_model
    model="$SELECTED_MODEL"
    local model_dir="$SELECTED_MODEL_DIR"
    preset=$(ask_value "Preset mp4-h264/mp4-hevc/mkv-hevc/mov-prores" "$CFG_DEFAULT_PRESET")
    case "$preset" in mp4-h264|mp4-hevc|mkv-hevc|mov-prores) ;; *) printf 'Unknown preset.\n'; return 0 ;; esac
    audio=$(ask_value "Audio auto/copy/aac/pcm/none" "auto")
    subs=$(ask_value "Subtitles auto/copy/convert/none" "auto")
    cleanup_default=n
    [ "$CFG_CLEANUP" = "1" ] && cleanup_default=y
    cleanup=$(ask_value "Delete intermediates after success? y/N" "$cleanup_default")
    scale="$CFG_DEFAULT_SCALE"
    SP_FPS=""; SP_START=""; SP_END=""; SP_FORMAT="png"; SP_JPEG=1; SP_PNG=3
    SP_DENOISE="none"; SP_TONEMAP="$tonemap"; SP_DECODE="auto"; SP_SCALE="$scale"; SP_TARGET=""
    SP_MODEL="$model"; SP_VERIFY=0; SP_RECURSIVE=0; SP_FORCE=0
    US_MODEL="$model"; US_SCALE="$scale"; US_GPU=0; US_TILE="auto"; US_BATCH=0; US_ASSUME_YES=0
    US_THREADS="1:2:2"; US_ICD=""; US_BIN=""; US_MODELS="$model_dir"; US_UPSCALED_DIR=""; US_RETRY=1; US_FORCE=0
    EN_PRESET="$preset"; EN_ENCODER="$CFG_DEFAULT_ENCODER"; EN_QUALITY="balanced"; EN_CRF=""
    if [ "$audio" = "auto" ]; then EN_AUDIO=""; else EN_AUDIO="$audio"; fi
    if [ "$subs" = "auto" ]; then EN_SUBS=""; else EN_SUBS="$subs"; fi
    EN_AUDIO_BITRATE=192; EN_ALL_AUDIO=0; EN_TENBIT=0; EN_TARGET=""
    if [ "$cleanup" = "y" ] || [ "$cleanup" = "yes" ]; then EN_CLEANUP=1; else EN_CLEANUP=0; fi
    EN_OUTPUT=""; EN_UPSCALED_DIR=""; EN_PICK="error"; EN_VERIFY=0; EN_ALLOW_HUGE=0; EN_FORCE=0; EN_KEEP_CHUNKS=0
    RUN_CLEANUP="$EN_CLEANUP"; RUN_STOP_ON_ERROR=0; RUN_CHUNK_SECONDS="auto"
    run_all 0 "${INPUT_PATHS[@]}" || true
}

menu_split() {
    local target fmt scale
    target=$(ask_value "Video file or folder" "")
    [ -n "$target" ] || return 0
    fmt=$(ask_value "Frame format png/jpg" "png")
    case "$fmt" in png|jpg) ;; *) printf 'Frame format must be png or jpg.\n'; return 0 ;; esac
    scale=$(ask_value "Scale 2/3/4" "$CFG_DEFAULT_SCALE")
    case "$scale" in 2|3|4) ;; *) printf 'Scale must be 2, 3, or 4.\n'; return 0 ;; esac
    SP_FPS=""; SP_START=""; SP_END=""; SP_FORMAT="$fmt"; SP_JPEG=1; SP_PNG=3
    SP_DENOISE="none"; SP_TONEMAP=0; SP_DECODE="auto"; SP_SCALE="$scale"; SP_TARGET=""
    SP_MODEL="$CFG_DEFAULT_MODEL"; SP_VERIFY=0; SP_RECURSIVE=0; SP_FORCE=0
    resolve_inputs 0 "$target"
    run_split 0 1 0 "${INPUT_PATHS[@]}"
}

menu_upscale() {
    local model scale model_dir
    select_jobs
    [ "${#SELECTED_JOBS[@]}" -gt 0 ] || return 0
    select_model
    model="$SELECTED_MODEL"
    model_dir="$SELECTED_MODEL_DIR"
    scale=$(ask_value "Scale 2/3/4" "$CFG_DEFAULT_SCALE")
    case "$scale" in 2|3|4) ;; *) printf 'Scale must be 2, 3, or 4.\n'; return 0 ;; esac
    printf 'Note: upscale writes frames only; audio and subtitles are muxed by Assemble or Run all.\n'
    US_MODEL="$model"; US_SCALE="$scale"; US_GPU=0; US_TILE="auto"; US_BATCH=0; US_ASSUME_YES=0
    US_THREADS="1:2:2"; US_ICD=""; US_BIN=""; US_MODELS="$model_dir"; US_UPSCALED_DIR=""; US_RETRY=1; US_FORCE=0
    run_upscale 0 "${SELECTED_JOBS[@]}"
}

menu_assemble() {
    local preset encoder audio subs
    select_jobs
    [ "${#SELECTED_JOBS[@]}" -gt 0 ] || return 0
    preset=$(ask_value "Preset mp4-h264/mp4-hevc/mkv-hevc/mov-prores" "$CFG_DEFAULT_PRESET")
    case "$preset" in mp4-h264|mp4-hevc|mkv-hevc|mov-prores) ;; *) printf 'Unknown preset.\n'; return 0 ;; esac
    encoder=$(ask_value "Encoder auto/nvidia/amd/cpu" "$CFG_DEFAULT_ENCODER")
    case "$encoder" in auto|nvidia|amd|cpu) ;; *) printf 'Unknown encoder.\n'; return 0 ;; esac
    audio=$(ask_value "Audio auto/copy/aac/pcm/none" "auto")
    subs=$(ask_value "Subtitles auto/copy/convert/none" "auto")
    EN_PRESET="$preset"; EN_ENCODER="$encoder"; EN_QUALITY="balanced"; EN_CRF=""
    if [ "$audio" = "auto" ]; then EN_AUDIO=""; else EN_AUDIO="$audio"; fi
    if [ "$subs" = "auto" ]; then EN_SUBS=""; else EN_SUBS="$subs"; fi
    EN_AUDIO_BITRATE=192; EN_ALL_AUDIO=0; EN_TENBIT=0; EN_TARGET=""; EN_CLEANUP=0
    EN_OUTPUT=""; EN_UPSCALED_DIR=""; EN_PICK="error"; EN_VERIFY=0; EN_ALLOW_HUGE=0; EN_FORCE=0; EN_KEEP_CHUNKS=0
    run_assemble 0 "${SELECTED_JOBS[@]}"
}

run_menu() {
    local choice answer
    while :; do
        printf '\nUpscayl Video Pipeline\n'
        printf '1) Run all (split + upscale + assemble)\n'
        printf '2) Split video(s)\n'
        printf '3) Upscale a job\n'
        printf '4) Assemble a job\n'
        printf '5) Status\n'
        printf '6) Doctor\n'
        printf '7) Clean a job\n'
        printf '8) Settings\n'
        printf '9) Exit\n'
        printf 'Choose [9]: ' >&2
        IFS= read -r choice || return 0
        choice=$(trim "$choice")
        [ -n "$choice" ] || choice=9
        case "$choice" in
            9|q|quit|exit) return 0 ;;
            1) menu_run_all || true ;;
            2) menu_split || true ;;
            3) menu_upscale || true ;;
            4) menu_assemble || true ;;
            5) run_status 0 ;;
            6) run_doctor "" 1 0 || true ;;
            7)
                answer=$(ask_value "Job folder" "")
                [ -n "$answer" ] || continue
                resolve_jobs 0 "$answer"
                CLEAN_FRAMES=0; CLEAN_UPSCALED=0; CLEAN_CHUNKS=0; CLEAN_SEQUENCE=0; CLEAN_BATCH=0
                CLEAN_OUTPUT=0; CLEAN_ALL_INTERMEDIATES=1
                run_clean 0 "${RESOLVED_JOBS[@]}"
                ;;
            8)
                printf 'Config: %s\n' "$CFG_CONFIG_PATH"
                printf 'FFmpeg: %s\n' "$CFG_FFMPEG"
                printf 'Upscayl: %s\n' "${CFG_UPSCAYL_BIN:-auto}"
                printf 'Models: %s\n' "${CFG_MODELS_DIR:-auto}"
                printf 'Work dir: %s\n' "$CFG_WORK_DIR"
                printf 'Model/scale/preset: %s / %s / %s\n' "$CFG_DEFAULT_MODEL" "$CFG_DEFAULT_SCALE" "$CFG_DEFAULT_PRESET"
                printf 'Chunking/cleanup: auto / %s\n' "$CFG_CLEANUP"
                ;;
            *) printf 'Invalid choice.\n' ;;
        esac
    done
}
