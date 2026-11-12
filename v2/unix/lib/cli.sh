# Upscayl Video Pipeline V2 - cli module.
# Option parsing and command dispatch.
# Sourced by upscayl-video.sh; not meant to be run directly.
# shellcheck shell=bash

# ---------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------

RESOLVED_JOBS=()

resolve_jobs() {
    local all="$1"; shift
    local args
    args=("$@")
    RESOLVED_JOBS=()
    if [ "$all" -eq 1 ]; then
        [ "${#args[@]}" -eq 0 ] || die 2 "Use either job folders or --all/--all-jobs, not both."
        local found
        found=$(find_jobs "$CFG_WORK_DIR")
        [ -n "$found" ] || die 2 "No jobs found in: $CFG_WORK_DIR"
        while IFS= read -r job_path; do
            [ -n "$job_path" ] && RESOLVED_JOBS[${#RESOLVED_JOBS[@]}]="$job_path"
        done <<EOF
$found
EOF
        return 0
    fi
    [ "${#args[@]}" -gt 0 ] || die 2 "No job folders given." "Pass a job folder or use --all."
    local raw resolved seen existing job_path
    seen=$(new_temp_file)
    for raw in "${args[@]}"; do
        resolved=$(abspath "$raw")
        if [ -d "$resolved" ] && [ ! -f "$resolved/job.txt" ]; then
            local nested nested_job
            nested=$(find_jobs "$resolved")
            if [ -n "$nested" ]; then
                while IFS= read -r nested_job; do
                    [ -n "$nested_job" ] || continue
                    if ! grep -Fxq "$nested_job" "$seen"; then
                        printf '%s\n' "$nested_job" >> "$seen"
                        RESOLVED_JOBS[${#RESOLVED_JOBS[@]}]="$nested_job"
                    fi
                done <<EOF
$nested
EOF
                continue
            fi
        fi
        job_load "$resolved"
        resolved="$JOB_DIR"
        if ! grep -Fxq "$resolved" "$seen"; then
            printf '%s\n' "$resolved" >> "$seen"
            RESOLVED_JOBS[${#RESOLVED_JOBS[@]}]="$resolved"
        fi
    done
    rm -f "$seen"
    local sorted
    sorted=$(printf '%s\n' "${RESOLVED_JOBS[@]}" 2>/dev/null | sort -f)
    RESOLVED_JOBS=()
    while IFS= read -r job_path; do
        [ -n "$job_path" ] && RESOLVED_JOBS[${#RESOLVED_JOBS[@]}]="$job_path"
    done <<EOF
$sorted
EOF
}

show_help() {
    printf 'usage: upscayl-video <command> [options]\n\n'
    printf 'Upscayl Video Pipeline V2 - split, upscale with Upscayl, assemble.\n\n'
    printf 'commands:\n'
    printf '  doctor     Check FFmpeg, encoders, Upscayl, and the work directory\n'
    printf '  split      Extract frames from videos\n'
    printf '  split-all  Split every video in the input directory\n'
    printf '  upscale    Upscale frames with the Upscayl CLI\n'
    printf '  assemble   Reassemble upscaled frames into a video\n'
    printf '  finish     Assemble the workspace jobs and publish them\n'
    printf '  run        Split, upscale, and assemble in one pass\n'
    printf '  model-test Compare the Upscayl models on sample frames\n'
    printf '  status     Show jobs and their progress\n'
    printf '  clean      Delete selected intermediate directories\n\n'
    printf 'global options:\n'
    printf '  --work-dir DIR  --config FILE  --ffmpeg PATH  --ffprobe PATH\n'
    printf '  --ffmpeg-args "ARGS"  extra FFmpeg flags for finish\n'
    printf '  --verbose  --quiet  --yes  --force  --dry-run  --version  --help\n'
}

reset_options() {
    OPT_WORK_DIR=""; OPT_OUTPUT_DIR=""; OPT_INPUT_DIR=""; OPT_CONFIG=""; OPT_FFMPEG=""; OPT_PROBEFILE=""; OPT_PROFILE="default"; OPT_KEEP=0; OPT_NO_TONEMAP=0; OPT_JOB=""; OPT_RESUME=0
    OPT_FFMPEG_ARGS=""; EN_FFMPEG_ARGS=()
    OPT_FFPROBE=""; OPT_VERBOSE=0; OPT_QUIET=0; OPT_YES=0; OPT_FORCE=0; OPT_DRY_RUN=0
    OPT_MAX_WORK=""; OPT_MIN_FREE=""
    SP_FPS=""; SP_START=""; SP_END=""; SP_FORMAT="png"; SP_JPEG=1; SP_PNG=3
    SP_DENOISE="none"; SP_TONEMAP=0; SP_DECODE="auto"; SP_SCALE=""; SP_TARGET=""
    SP_MODEL=""; SP_VERIFY=0; SP_RECURSIVE=0; SP_FORCE=0
    US_MODEL=""; US_SCALE=""; US_GPU=""; US_TILE=""; US_BATCH=""; US_THREADS="1:2:2"; US_ASSUME_YES=1
    US_ICD=""; US_BIN=""; US_MODELS=""; US_UPSCALED_DIR=""; US_RETRY=1; US_FORCE=0
    EN_PRESET=""; EN_ENCODER=""; EN_QUALITY="balanced"; EN_QUALITY_SET=0; EN_CRF=""; EN_CRF_SET=0
    EN_AUDIO=""; EN_AUDIO_BITRATE=192; EN_ALL_AUDIO=0; EN_SUBS=""; EN_TENBIT=0
    EN_TARGET=""; EN_CLEANUP=0; EN_OUTPUT=""; EN_UPSCALED_DIR=""; EN_PICK="error"
    EN_VERIFY=0; EN_ALLOW_HUGE=0; EN_FORCE=0; EN_KEEP_CHUNKS=0
    CLEAN_FRAMES=0; CLEAN_UPSCALED=0; CLEAN_CHUNKS=0; CLEAN_SEQUENCE=0
    CLEAN_BATCH=0; CLEAN_OUTPUT=0; CLEAN_ALL_INTERMEDIATES=0
    RUN_CLEANUP=0; RUN_STOP_ON_ERROR=0; RUN_CHUNK_SECONDS="auto"
    DOCTOR_WORK_DIR=""; DOCTOR_SKIP_SMOKE=0
    POSITIONALS=(); RESOLVED_JOBS=()
    ALL_JOBS=0; ASSEMBLE_ALL=0; COMMAND=""
}

need_value() {
    local name="$1" count="$2"
    [ "$count" -ge 2 ] || die 2 "argument $name: expected one argument"
}

validate_ffmpeg_args() {
    local text="$1" token base blocked=""
    [ -n "$text" ] || return 0
    for token in $text; do
        case "$token" in
            -*) ;;
            *) continue ;;
        esac
        base="${token%%:*}"
        case "$base" in
            -i|-map|-filter_complex|-lavfi|-vf|-af|-filter|-ss|-t|-to|-c|-codec|-y|-n|-f|-vn|-an|-sn|-dn|-map_metadata|-map_chapters|-frames|-r|-s|-aspect|-pix_fmt|-vcodec|-acodec|-scodec|-dcodec|-vframes|-aframes)
                blocked="$blocked $token"
                ;;
        esac
    done
    if [ -n "$blocked" ]; then
        die 4 "Blocked FFmpeg arguments:$blocked" "Input, mapping, filters, and overwrite flags are controlled by the pipeline."
    fi
}

parse_options() {
    local token name value
    POSITIONALS=()
    ALL_JOBS=0; ASSEMBLE_ALL=0
    while [ "$#" -gt 0 ]; do
        token="$1"
        case "$token" in
            --*=*)
                name="${token%%=*}"
                value="${token#*=}"
                shift
                set -- "$name" "$value" "$@"
                token="$1"
                ;;
        esac
        case "$token" in
            --work-dir) need_value "$token" "$#"; OPT_WORK_DIR="$2"; shift 2 ;;
            --output-dir) need_value "$token" "$#"; OPT_OUTPUT_DIR="$2"; shift 2 ;;
            --config) need_value "$token" "$#"; OPT_CONFIG="$2"; shift 2 ;;
            --ffmpeg) need_value "$token" "$#"; OPT_FFMPEG="$2"; shift 2 ;;
            --ffprobe) need_value "$token" "$#"; OPT_FFPROBE="$2"; shift 2 ;;
            --ffmpeg-args) need_value "$token" "$#"; OPT_FFMPEG_ARGS="$2"; shift 2 ;;
            --verbose) OPT_VERBOSE=1; shift ;;
            --quiet) OPT_QUIET=1; shift ;;
            --yes) OPT_YES=1; shift ;;
            --force) OPT_FORCE=1; shift ;;
            --dry-run) OPT_DRY_RUN=1; shift ;;
            --max-work-gb) need_value "$token" "$#"; OPT_MAX_WORK=$(require_int "$2" max-work-gb) || exit $?; shift 2 ;;
            --min-free-gb) need_value "$token" "$#"; OPT_MIN_FREE=$(require_int "$2" min-free-gb) || exit $?; shift 2 ;;
            -h|--help) show_help; exit 0 ;;
            --version) printf '%s %s\n' "$UVP_PROGRAM" "$UVP_VERSION"; exit 0 ;;
            --)
                shift
                while [ "$#" -gt 0 ]; do POSITIONALS[${#POSITIONALS[@]}]="$1"; shift; done
                ;;
            --fps) need_value "$token" "$#"; SP_FPS="$2"; shift 2 ;;
            --start) need_value "$token" "$#"; SP_START="$2"; shift 2 ;;
            --end) need_value "$token" "$#"; SP_END="$2"; shift 2 ;;
            --format) need_value "$token" "$#"; SP_FORMAT="$2"; case "$SP_FORMAT" in png|jpg) ;; *) die 2 "argument --format: invalid choice: '$SP_FORMAT'" ;; esac; shift 2 ;;
            --jpeg-quality) need_value "$token" "$#"; SP_JPEG=$(require_int "$2" jpeg-quality) || exit $?; shift 2 ;;
            --png-compression) need_value "$token" "$#"; SP_PNG=$(require_int "$2" png-compression) || exit $?; shift 2 ;;
            --denoise) need_value "$token" "$#"; SP_DENOISE="$2"; case "$SP_DENOISE" in none|light|medium|strong) ;; *) die 2 "argument --denoise: invalid choice: '$SP_DENOISE'" ;; esac; shift 2 ;;
            --tonemap) SP_TONEMAP=1; if [ "$COMMAND" = "assemble" ]; then die 4 "--tonemap is a split-stage option; re-split with --tonemap instead."; fi; shift ;;
            --no-tonemap) SP_TONEMAP=0; OPT_NO_TONEMAP=1; shift ;;
            --job) need_value "$token" "$#"; OPT_JOB="$2"; shift 2 ;;
            --decode) need_value "$token" "$#"; SP_DECODE="$2"; case "$SP_DECODE" in cpu|gpu|auto) ;; *) die 2 "argument --decode: invalid choice: '$SP_DECODE'" ;; esac; shift 2 ;;
            --scale) need_value "$token" "$#"; value=$(require_int "$2" scale) || exit $?; case "$value" in 2|3|4) ;; *) die 2 "argument --scale: invalid choice: $value" ;; esac; SP_SCALE="$value"; US_SCALE="$value"; shift 2 ;;
            --target-height) need_value "$token" "$#"; SP_TARGET=$(require_int "$2" target-height) || exit $?; EN_TARGET="$SP_TARGET"; shift 2 ;;
            --model) need_value "$token" "$#"; SP_MODEL="$2"; US_MODEL="$2"; shift 2 ;;
            --verify-frames) SP_VERIFY=1; EN_VERIFY=1; shift ;;
            --recursive) SP_RECURSIVE=1; shift ;;
            --all) ALL_JOBS=1; ASSEMBLE_ALL=1; shift ;;
            --preset) need_value "$token" "$#"; EN_PRESET="$2"; OPT_PRESET="$2"; case "$EN_PRESET" in mp4-h264|mp4-hevc|mkv-hevc|mov-prores) ;; *) die 2 "argument --preset: invalid choice: '$EN_PRESET'" ;; esac; shift 2 ;;
            --encoder) need_value "$token" "$#"; EN_ENCODER="$2"; OPT_ENCODER="$2"; case "$EN_ENCODER" in auto|nvidia|amd|cpu) ;; *) die 2 "argument --encoder: invalid choice: '$EN_ENCODER'" ;; esac; shift 2 ;;
            --quality) need_value "$token" "$#"; EN_QUALITY="$2"; OPT_QUALITY="$2"; EN_QUALITY_SET=1; case "$EN_QUALITY" in fast|balanced|quality) ;; *) die 2 "argument --quality: invalid choice: '$EN_QUALITY'" ;; esac; shift 2 ;;
            --crf) need_value "$token" "$#"; EN_CRF=$(require_int "$2" crf) || exit $?; EN_CRF_SET=1; shift 2 ;;
            --audio) need_value "$token" "$#"; EN_AUDIO="$2"; case "$EN_AUDIO" in auto|copy|aac|pcm|none) ;; *) die 2 "argument --audio: invalid choice: '$EN_AUDIO'" ;; esac; shift 2 ;;
            --audio-bitrate) need_value "$token" "$#"; EN_AUDIO_BITRATE=$(require_int "$2" audio-bitrate) || exit $?; shift 2 ;;
            --all-audio) EN_ALL_AUDIO=1; shift ;;
            --subs) need_value "$token" "$#"; EN_SUBS="$2"; case "$EN_SUBS" in auto|copy|convert|none) ;; *) die 2 "argument --subs: invalid choice: '$EN_SUBS'" ;; esac; shift 2 ;;
            --10bit) EN_TENBIT=1; shift ;;
            --cleanup) EN_CLEANUP=1; RUN_CLEANUP=1; shift ;;
            --keep-chunks) EN_KEEP_CHUNKS=1; shift ;;
            --input-dir) need_value "$token" "$#"; OPT_INPUT_DIR="$2"; shift 2 ;;
            --profile) need_value "$token" "$#"; OPT_PROFILE="$2"; case "$OPT_PROFILE" in default|fast|quality) ;; *) die 2 "argument --profile: invalid choice: '$OPT_PROFILE'" ;; esac; shift 2 ;;
            --resume) OPT_RESUME=1; shift ;;
            --keep) OPT_KEEP=1; shift ;;
            --output) need_value "$token" "$#"; EN_OUTPUT="$2"; shift 2 ;;
            --upscaled-dir) need_value "$token" "$#"; US_UPSCALED_DIR="$2"; EN_UPSCALED_DIR="$2"; shift 2 ;;
            --pick) need_value "$token" "$#"; EN_PICK="$2"; case "$EN_PICK" in error|newest|largest) ;; *) die 2 "argument --pick: invalid choice: '$EN_PICK'" ;; esac; shift 2 ;;
            --allow-huge) EN_ALLOW_HUGE=1; shift ;;
            --stop-on-error) RUN_STOP_ON_ERROR=1; shift ;;
            --chunk-seconds) need_value "$token" "$#"; RUN_CHUNK_SECONDS="$2"; shift 2 ;;
            --gpu) need_value "$token" "$#"; US_GPU=$(require_int "$2" gpu) || exit $?; shift 2 ;;
            --tile) need_value "$token" "$#"; US_TILE="$2"; shift 2 ;;
            --batch-size) need_value "$token" "$#"; US_BATCH=$(require_int "$2" batch-size) || exit $?; shift 2 ;;
            --threads) need_value "$token" "$#"; US_THREADS="$2"; shift 2 ;;
            --icd) need_value "$token" "$#"; US_ICD="$2"; shift 2 ;;
            --upscayl-bin) need_value "$token" "$#"; US_BIN="$2"; shift 2 ;;
            --models-dir) need_value "$token" "$#"; US_MODELS="$2"; shift 2 ;;
            --retry) need_value "$token" "$#"; US_RETRY=$(require_int "$2" retry) || exit $?; shift 2 ;;
            --frames) CLEAN_FRAMES=1; shift ;;
            --upscaled) CLEAN_UPSCALED=1; shift ;;
            --chunks) CLEAN_CHUNKS=1; shift ;;
            --batch) CLEAN_BATCH=1; shift ;;
            --all-intermediates) CLEAN_ALL_INTERMEDIATES=1; shift ;;
            --include-output) CLEAN_OUTPUT=1; shift ;;
            --all-jobs) ASSEMBLE_ALL=1; ALL_JOBS=1; shift ;;
            --skip-upscayl-smoke) DOCTOR_SKIP_SMOKE=1; shift ;;
            -*) die 2 "unrecognized argument: $token" "Run with --help for usage." ;;
            *) POSITIONALS[${#POSITIONALS[@]}]="$token"; shift ;;
        esac
    done
}

apply_config_defaults() {
    [ -n "$SP_MODEL" ] || SP_MODEL="$CFG_DEFAULT_MODEL"
    [ -n "$US_MODEL" ] || US_MODEL="$CFG_DEFAULT_MODEL"
    [ -n "$EN_PRESET" ] || EN_PRESET="$CFG_DEFAULT_PRESET"
    [ -n "$EN_ENCODER" ] || EN_ENCODER="$CFG_DEFAULT_ENCODER"
    [ -n "$US_SCALE" ] || US_SCALE="$CFG_DEFAULT_SCALE"
    [ -n "$US_GPU" ] || US_GPU="$CFG_GPU"
    [ -n "$US_TILE" ] || US_TILE="$CFG_TILE"
    [ -n "$US_BATCH" ] || US_BATCH="$CFG_BATCH_SIZE"
    SP_FORCE="$OPT_FORCE"; US_FORCE="$OPT_FORCE"; EN_FORCE="$OPT_FORCE"
    US_ASSUME_YES="$OPT_YES"
}

main() {
    reset_options
    local args
    args=("$@")
    local i=0 token command="" prefix=() rest=()
    if [ "${#args[@]}" -eq 0 ]; then
        if [ ! -t 0 ]; then show_help; exit 2; fi
        config_load "" "$UVP_TOOL_DIR" "" "" "" ""
        run_menu
        exit $?
    fi
    while [ "$i" -lt "${#args[@]}" ]; do
        token="${args[$i]}"
        case "$token" in
            --version) printf '%s %s\n' "$UVP_PROGRAM" "$UVP_VERSION"; exit 0 ;;
            -h|--help) show_help; exit 0 ;;
            --work-dir|--config|--ffmpeg|--ffprobe|--max-work-gb|--min-free-gb)
                [ $((i + 1)) -lt "${#args[@]}" ] || die 2 "argument $token: expected one argument"
                prefix[${#prefix[@]}]="$token"; prefix[${#prefix[@]}]="${args[$((i + 1))]}"
                i=$((i + 2))
                ;;
            --verbose|--quiet|--yes|--force|--dry-run)
                prefix[${#prefix[@]}]="$token"
                i=$((i + 1))
                ;;
            --work-dir=*|--config=*|--ffmpeg=*|--ffprobe=*|--max-work-gb=*|--min-free-gb=*)
                prefix[${#prefix[@]}]="$token"
                i=$((i + 1))
                ;;
            --) die 2 "the following arguments are required: command" ;;
            -*) die 2 "unrecognized argument: $token" "Run with --help for usage." ;;
            *) command="$token"; i=$((i + 1)); break ;;
        esac
    done
    if [ -z "$command" ]; then
        die 2 "the following arguments are required: command" "Run with --help for usage."
    fi
    case "$command" in
        doctor|split|split-all|upscale|assemble|finish|run|status|clean|model-test) ;;
        *) die 2 "invalid choice: '$command'" "choose from: doctor, split, split-all, upscale, assemble, finish, run, model-test, status, clean" ;;
    esac
    COMMAND="$command"
    while [ "$i" -lt "${#args[@]}" ]; do
        rest[${#rest[@]}]="${args[$i]}"
        i=$((i + 1))
    done
    local combined
    combined=()
    local entry
    for entry in "${prefix[@]}"; do combined[${#combined[@]}]="$entry"; done
    for entry in "${rest[@]}"; do combined[${#combined[@]}]="$entry"; done
    parse_options "${combined[@]}"
    validate_ffmpeg_args "$OPT_FFMPEG_ARGS"
    if [ -n "$OPT_FFMPEG_ARGS" ]; then
        # shellcheck disable=SC2206  # the flags are a whitespace separated list
        EN_FFMPEG_ARGS=($OPT_FFMPEG_ARGS)
    fi
    case "$command" in
        status|doctor)
            [ "${#POSITIONALS[@]}" -eq 0 ] || die 2 "unrecognized arguments: ${POSITIONALS[*]}" "Run with --help for usage."
            ;;
    esac

    if [ "$EN_QUALITY_SET" -eq 1 ] && [ "$EN_CRF_SET" -eq 1 ]; then
        die 4 "--quality and --crf are mutually exclusive."
    fi
    [ "$OPT_VERBOSE" -eq 1 ] && UVP_VERBOSE=1
    [ "$OPT_QUIET" -eq 1 ] && UVP_QUIET=1
    config_load "$OPT_CONFIG" "$UVP_TOOL_DIR" "$OPT_WORK_DIR" "$OPT_OUTPUT_DIR" "$OPT_INPUT_DIR" "$OPT_FFMPEG" "$OPT_FFPROBE" "$OPT_MAX_WORK" "$OPT_MIN_FREE"
    apply_config_defaults

    local dry="$OPT_DRY_RUN" yes="$OPT_YES" rc
    case "$command" in
        split-all)
            SP_FORMAT="${SP_FORMAT:-png}"; SP_PNG="${SP_PNG:-1}"; SP_JPEG="${SP_JPEG:-1}"
            SP_DENOISE="${SP_DENOISE:-none}"; SP_TONEMAP="${SP_TONEMAP:-0}"; SP_DECODE="${SP_DECODE:-auto}"
            SP_SCALE="${SP_SCALE:-$CFG_DEFAULT_SCALE}"; SP_MODEL="${SP_MODEL:-$CFG_DEFAULT_MODEL}"; SP_FORCE="${SP_FORCE:-0}"
            split_all
            exit 0
            ;;
        finish)
            OPT_PROFILE="${OPT_PROFILE:-default}"
            local candidate
            FINISH_JOBS=()
            while IFS= read -r candidate; do
                [ -n "$candidate" ] || continue
                FINISH_JOBS[${#FINISH_JOBS[@]}]="$candidate"
            done <<EOF
$(find_jobs "$CFG_WORK_DIR")
EOF
            if [ -n "$OPT_JOB" ]; then
                MATCHED_JOBS=()
                for candidate in "${FINISH_JOBS[@]}"; do
                    if [ "$(basename "$candidate")" = "$OPT_JOB" ]; then
                        MATCHED_JOBS[${#MATCHED_JOBS[@]}]="$candidate"
                    fi
                done
                [ ${#MATCHED_JOBS[@]} -gt 0 ] || die 4 "Job not found: $OPT_JOB" "Run 'status' to list available jobs."
                if finish_all "${MATCHED_JOBS[@]}"; then exit 0; else exit 1; fi
            elif [ "$ALL_JOBS" -eq 1 ]; then
                if finish_all "${FINISH_JOBS[@]}"; then exit 0; else exit 1; fi
            else
                die 2 "finish requires --all or --job NAME" "Use 'upscayl-video finish --all' to process every job."
            fi
            ;;
        split)
            resolve_inputs "$SP_RECURSIVE" "${POSITIONALS[@]}"
            run_split "$SP_RECURSIVE" "$yes" "$dry" "${INPUT_PATHS[@]}"
            [ "${#JOB_PATHS[@]}" -gt 0 ] && log_info "Split complete: ${#JOB_PATHS[@]} job(s)"
            exit 0
            ;;
        upscale)
            resolve_jobs "$ALL_JOBS" "${POSITIONALS[@]}"
            run_upscale "$dry" "${RESOLVED_JOBS[@]}"
            [ "${#RESOLVED_JOBS[@]}" -gt 0 ] && log_info "Upscaled ${#RESOLVED_JOBS[@]} job(s)"
            exit 0
            ;;
        assemble)
            resolve_jobs "$ASSEMBLE_ALL" "${POSITIONALS[@]}"
            run_assemble "$dry" "${RESOLVED_JOBS[@]}"
            [ "${#OUTPUTS[@]}" -gt 0 ] && log_info "Assembled ${#OUTPUTS[@]} video(s)"
            exit 0
            ;;
        run)
            if [ "$RUN_CLEANUP" -eq 0 ] && [ "$CFG_CLEANUP" = "1" ]; then
                RUN_CLEANUP=1
            fi
            EN_CLEANUP="$RUN_CLEANUP"
            resolve_inputs "$SP_RECURSIVE" "${POSITIONALS[@]}"
            if run_all "$dry" "${INPUT_PATHS[@]}"; then exit 0; else exit "${RUN_EXIT_CODE:-1}"; fi
            ;;
        model-test)
            log_info "model-test is a V2 follow-up; see docs/VALIDATION.md"
            exit 3
            ;;
        status)
            run_status "$OPT_VERBOSE"
            exit 0
            ;;
        clean)
            resolve_jobs "$ASSEMBLE_ALL" "${POSITIONALS[@]}"
            run_clean "$dry" "${RESOLVED_JOBS[@]}"
            exit 0
            ;;
        doctor)
            DOCTOR_WORK_DIR="$OPT_WORK_DIR"
            run_doctor "$DOCTOR_WORK_DIR" "$DOCTOR_SKIP_SMOKE" "$OPT_VERBOSE"
            exit $?
            ;;
    esac
    exit 1
}
