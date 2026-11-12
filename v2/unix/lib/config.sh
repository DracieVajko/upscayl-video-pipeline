# Upscayl Video Pipeline V2 - config module.
# Configuration file loading and tool resolution.
# Sourced by upscayl-video.sh; not meant to be run directly.
# shellcheck shell=bash

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

CFG_FFMPEG=""
CFG_FFPROBE=""
CFG_UPSCAYL_BIN=""
CFG_MODELS_DIR=""
CFG_WORK_DIR=""
CFG_OUTPUT_DIR=""
CFG_INPUT_DIR="input"
CFG_DEFAULT_MODEL="upscayl-standard-4x"
CFG_DEFAULT_SCALE="2"
CFG_DEFAULT_PRESET="mp4-h264"
CFG_DEFAULT_ENCODER="auto"
CFG_DEFAULT_AUDIO="auto"
CFG_DEFAULT_SUBS="auto"
CFG_TILE="auto"
CFG_BATCH_SIZE="100"
CFG_GPU="0"
CFG_ICD="auto"
CFG_MAX_WORK_GB="40"
CFG_MIN_FREE_GB="5"
CFG_CLEANUP="0"
CFG_CONFIG_PATH=""
CFG_TOOL_DIR=""

config_defaults() {
    CFG_FFMPEG="ffmpeg"
    CFG_FFPROBE="ffprobe"
    CFG_UPSCAYL_BIN="auto"
    CFG_MODELS_DIR="auto"
    CFG_WORK_DIR="work"
    CFG_OUTPUT_DIR="output"
    CFG_INPUT_DIR="input"
    CFG_DEFAULT_MODEL="upscayl-standard-4x"
    CFG_DEFAULT_SCALE="2"
    CFG_DEFAULT_PRESET="mp4-h264"
    CFG_DEFAULT_ENCODER="auto"
    CFG_DEFAULT_AUDIO="auto"
    CFG_DEFAULT_SUBS="auto"
    CFG_TILE="auto"
    CFG_BATCH_SIZE="100"
    CFG_GPU="0"
    CFG_ICD="auto"
    CFG_MAX_WORK_GB="40"
    CFG_MIN_FREE_GB="5"
    CFG_CLEANUP="0"
}

path_like() {
    case "$1" in
        */*|*\\*|'~') return 0 ;;
        *) return 1 ;;
    esac
}

find_in_path() {
    command -v "$1" 2>/dev/null
}

resolve_executable() {
    local raw="$1" names="$2" name candidate found directory searched=""
    raw=$(trim "$raw")
    if [ -n "$raw" ] && path_like "$raw"; then
        candidate=$(abspath "$raw")
        if [ -d "$candidate" ]; then
            for name in $names; do
                searched="$searched $candidate/$name"
                if [ -f "$candidate/$name" ]; then
                    abspath "$candidate/$name"
                    return 0
                fi
            done
            die 3 "Executable not found in directory: $candidate" "Searched:$searched"
        fi
        if [ -f "$candidate" ]; then
            abspath "$candidate"
            return 0
        fi
        die 3 "Executable does not exist: $candidate" "Searched: $candidate"
    fi
    if [ -n "$raw" ]; then
        found=$(find_in_path "$raw")
        if [ -n "$found" ]; then abspath "$found"; return 0; fi
    fi
    for directory in "$CFG_TOOL_DIR" "$(dirname "$CFG_TOOL_DIR")" /usr/local/bin /opt/homebrew/bin /opt/local/bin /usr/bin /bin; do
        [ -n "$directory" ] || continue
        for name in $names; do
            if [ -f "$directory/$name" ]; then
                abspath "$directory/$name"
                return 0
            fi
        done
    done
    for name in $names; do
        found=$(find_in_path "$name")
        if [ -n "$found" ]; then abspath "$found"; return 0; fi
    done
    die 3 "Executable not found: ${raw:-$name}" "Searched PATH and common locations"
}

require_int() {
    local value="$1" key="$2"
    case "$value" in
        ''|-) die 4 "Invalid integer for $key: '$value'" ;;
        -*) case "${value#-}" in ''|*[!0-9]*) die 4 "Invalid integer for $key: '$value'" ;; esac ;;
        *[!0-9]*) die 4 "Invalid integer for $key: '$value'" ;;
    esac
    printf '%s' "$value"
}

require_bool() {
    case "$(lower "$1")" in
        1|true|yes|on) printf '1' ;;
        0|false|no|off|'') printf '0' ;;
        *) die 4 "Invalid boolean for $2: '$1'" ;;
    esac
}

config_load() {
    local config_path="$1" tool_dir="$2" override_work="$3" override_output="$4" override_ffmpeg="$5" override_ffprobe="$6" override_max_work="${7:-}" override_min_free="${8:-}"
    local config_dir search file_value value origin base scale preset encoder audio subs tile batch gpu maxwork minfree

    CFG_TOOL_DIR=$(abspath "$tool_dir")
    config_defaults
    if [ -n "$config_path" ]; then
        CFG_CONFIG_PATH=$(abspath "$config_path")
    else
        CFG_CONFIG_PATH="$CFG_TOOL_DIR/config.txt"
    fi
    config_dir=$(dirname "$CFG_CONFIG_PATH")
    kv_load "$CFG_CONFIG_PATH"

    if [ -n "$override_ffmpeg" ]; then
        value="$override_ffmpeg"
    else
        value=$(kv_get ffmpeg "$CFG_FFMPEG")
        if [ -n "$value" ] && path_like "$value"; then
            case "$value" in /*|'~'|'~/'*) ;; *) value="$config_dir/$value" ;; esac
        fi
    fi
    CFG_FFMPEG=$(resolve_executable "$value" "ffmpeg") || exit $?

    if [ -n "$override_ffprobe" ]; then
        value="$override_ffprobe"
    else
        value=$(kv_get ffprobe "$CFG_FFPROBE")
        if [ -n "$value" ] && path_like "$value"; then
            case "$value" in /*|'~'|'~/'*) ;; *) value="$config_dir/$value" ;; esac
        fi
    fi
    CFG_FFPROBE=$(resolve_executable "$value" "ffprobe") || exit $?

    CFG_DEFAULT_MODEL=$(kv_get default_model "$CFG_DEFAULT_MODEL")
    CFG_DEFAULT_MODEL=$(trim "$CFG_DEFAULT_MODEL")
    scale=$(kv_get default_scale "$CFG_DEFAULT_SCALE")
    case "$scale" in 2|3|4) ;; *) die 4 "default_scale must be 2, 3, or 4" ;; esac
    CFG_DEFAULT_SCALE="$scale"

    preset=$(lower "$(trim "$(kv_get default_preset "$CFG_DEFAULT_PRESET")")")
    case "$preset" in
        mp4-h264|mp4-hevc|mkv-hevc|mov-prores) ;;
        *) die 4 "default_preset must be one of mp4-h264, mp4-hevc, mkv-hevc, mov-prores" ;;
    esac
    CFG_DEFAULT_PRESET="$preset"

    encoder=$(lower "$(trim "$(kv_get default_encoder "$CFG_DEFAULT_ENCODER")")")
    case "$encoder" in
        auto|nvidia|amd|cpu) ;;
        *) die 4 "default_encoder must be one of auto, nvidia, amd, cpu" ;;
    esac
    CFG_DEFAULT_ENCODER="$encoder"

    audio=$(lower "$(trim "$(kv_get default_audio "$CFG_DEFAULT_AUDIO")")")
    case "$audio" in
        auto|copy|aac|pcm|none) ;;
        *) die 4 "default_audio must be one of auto, copy, aac, pcm, none" ;;
    esac
    CFG_DEFAULT_AUDIO="$audio"

    subs=$(lower "$(trim "$(kv_get default_subs "$CFG_DEFAULT_SUBS")")")
    case "$subs" in
        auto|copy|convert|none) ;;
        *) die 4 "default_subs must be one of auto, copy, convert, none" ;;
    esac
    CFG_DEFAULT_SUBS="$subs"

    tile=$(trim "$(kv_get tile "$CFG_TILE")")
    [ -n "$tile" ] || tile="auto"
    if [ "$tile" != "auto" ]; then
        case "$tile" in *[!0-9]*) die 4 "tile must be 'auto' or a non-negative integer" ;; esac
    fi
    CFG_TILE="$tile"

    batch=$(require_int "$(trim "$(kv_get batch_size "$CFG_BATCH_SIZE")")" batch_size) || exit $?
    [ "$batch" -gt 0 ] || die 4 "batch_size must be greater than zero"
    CFG_BATCH_SIZE="$batch"

    gpu=$(require_int "$(trim "$(kv_get gpu "$CFG_GPU")")" gpu) || exit $?
    [ "$gpu" -ge 0 ] || die 4 "gpu must be non-negative"
    CFG_GPU="$gpu"

    maxwork=$(require_int "$(trim "$(kv_get max_work_gb "$CFG_MAX_WORK_GB")")" max_work_gb) || exit $?
    [ -n "$override_max_work" ] && maxwork="$override_max_work"
    [ "$maxwork" -gt 0 ] || die 4 "max_work_gb must be greater than zero"
    CFG_MAX_WORK_GB="$maxwork"

    minfree=$(require_int "$(trim "$(kv_get min_free_gb "$CFG_MIN_FREE_GB")")" min_free_gb) || exit $?
    [ -n "$override_min_free" ] && minfree="$override_min_free"
    [ "$minfree" -ge 0 ] || die 4 "min_free_gb must be non-negative"
    CFG_MIN_FREE_GB="$minfree"

    CFG_CLEANUP=$(require_bool "$(kv_get cleanup "$CFG_CLEANUP")" cleanup) || exit $?
    CFG_ICD=$(trim "$(kv_get icd "$CFG_ICD")")
    [ -n "$CFG_ICD" ] || CFG_ICD="auto"

    value=$(trim "$(kv_get upscayl_bin "auto")")
    if [ -z "$value" ] || [ "$(lower "$value")" = "auto" ]; then
        CFG_UPSCAYL_BIN=""
    else
        case "$value" in /*|'~'|'~/'*) ;; *) value="$config_dir/$value" ;; esac
        CFG_UPSCAYL_BIN=$(abspath "$value")
    fi
    value=$(trim "$(kv_get models_dir "auto")")
    if [ -z "$value" ] || [ "$(lower "$value")" = "auto" ]; then
        CFG_MODELS_DIR=""
    else
        case "$value" in /*|'~'|'~/'*) ;; *) value="$config_dir/$value" ;; esac
        CFG_MODELS_DIR=$(abspath "$value")
    fi

    if [ -n "$override_work" ]; then
        CFG_WORK_DIR=$(abspath "$override_work" "$PWD")
    else
        value=$(kv_get work_dir "work")
        case "$value" in /*|'~'|'~/'*) ;; *) value="$config_dir/$value" ;; esac
        CFG_WORK_DIR=$(abspath "$value")
    fi

    if [ -n "$override_output" ]; then
        CFG_OUTPUT_DIR=$(abspath "$override_output" "$PWD")
    else
        value=$(kv_get output_dir "output")
        case "$value" in /*|'~'|'~/'*) ;; *) value="$config_dir/$value" ;; esac
        CFG_OUTPUT_DIR=$(abspath "$value")
    fi

    if [ -n "$override_input" ]; then
        CFG_INPUT_DIR=$(abspath "$override_input" "$PWD")
    else
        value=$(kv_get input_dir "input")
        case "$value" in /*|'~'|'~/'*) ;; *) value="$config_dir/$value" ;; esac
        CFG_INPUT_DIR=$(abspath "$value")
    fi
}
