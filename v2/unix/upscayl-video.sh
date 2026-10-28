#!/usr/bin/env bash
# Upscayl Video Pipeline V2 - native Unix implementation.
# Requires bash 3.2+, FFmpeg/ffprobe, and Upscayl's CLI.
# No Python, Node, or jq.

# No `set -u`: bash 3.2 fails on empty array expansions under nounset.
UVP_VERSION="0.3.1"
UVP_PROGRAM="upscayl-video"
UVP_TOOL_DIR=$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd -P)
UVP_LOG_FILE=""
UVP_VERBOSE=0
UVP_QUIET=0
HAS_CYGPATH=0
if command -v cygpath >/dev/null 2>&1; then HAS_CYGPATH=1; fi
# Create the scratch directory before any command substitution. A lazy
# creation inside $(...) would run the EXIT trap in the subshell and delete the
# file before the caller can use it.
UVP_TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/uvp.XXXXXX") || {
    printf 'Could not create a temporary directory\n' >&2
    exit 1
}
trap 'rm -rf "$UVP_TMP_DIR"' EXIT

# ---------------------------------------------------------------------------
# Errors and logging
# ---------------------------------------------------------------------------

die() {
    local code="$1"
    local message="$2"
    local hint="${3:-}"
    log_file_line "ERROR" "$message"
    printf '%s\n' "$message" >&2
    if [ -n "$hint" ]; then
        printf 'Hint: %s\n' "$hint" >&2
    fi
    if [ -n "${UVP_ERROR_FILE:-}" ]; then
        printf '%s' "$message" > "$UVP_ERROR_FILE" 2>/dev/null || true
    fi
    if [ -n "${JOB_DIR:-}" ] && [ -f "$JOB_DIR/job.txt" ] && [ "${UVP_IN_DIE:-0}" != "1" ]; then
        UVP_IN_DIE=1
        job_set last_error "$message"
        job_save || true
        UVP_IN_DIE=0
    fi
    if [ -n "${PARTIAL_PATH:-}" ] && [ -e "$PARTIAL_PATH" ]; then
        rm -f "$PARTIAL_PATH" 2>/dev/null || true
    fi
    exit "$code"
}

timestamp_now() {
    local value base offset
    value=$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')
    case "$value" in
        *[+-][0-9][0-9][0-9][0-9])
            base="${value%????}"
            offset="${value#"$base"}"
            value="${base}${offset%??}:${offset#??}"
            ;;
    esac
    printf '%s' "$value"
}

log_file_line() {
    local level="$1"
    local message="$2"
    if [ -n "$UVP_LOG_FILE" ]; then
        printf '%s [%s] %s\n' "$(timestamp_now)" "$level" "$message" >> "$UVP_LOG_FILE" 2>/dev/null || true
    fi
}

log_info() {
    log_file_line "INFO" "$1"
    if [ "$UVP_QUIET" -eq 0 ]; then
        printf '%s\n' "$1"
    fi
}

log_warn() {
    log_file_line "WARN" "$1"
    if [ "$UVP_QUIET" -eq 0 ]; then
        printf '%s\n' "$1" >&2
    fi
}

log_debug() {
    log_file_line "DEBUG" "$1"
    if [ "$UVP_VERBOSE" -eq 1 ]; then
        printf '%s\n' "$1" >&2
    fi
}

set_log_file() {
    UVP_LOG_FILE="$1"
    local parent
    parent=$(dirname "$UVP_LOG_FILE")
    [ -d "$parent" ] || mkdir -p "$parent"
}

new_temp_file() {
    mktemp "$UVP_TMP_DIR/file.XXXXXX"
}

cleanup_temp_files() {
    [ -n "$LAST_OUT" ] && rm -f "$LAST_OUT" 2>/dev/null
    [ -n "$LAST_ERR" ] && rm -f "$LAST_ERR" 2>/dev/null
    LAST_OUT=""
    LAST_ERR=""
}

native_arg() {
    if [ "$HAS_CYGPATH" -eq 1 ]; then
        case "$1" in
            /*)
                cygpath -m "$1"
                return 0
                ;;
        esac
    fi
    printf '%s' "$1"
}

quote_for_display() {
    case "$1" in
        *[[:space:]]*) printf '"%s"' "$1" ;;
        *) printf '%s' "$1" ;;
    esac
}

display_command() {
    local out="" arg
    for arg in "$@"; do
        if [ -n "$out" ]; then out="$out "; fi
        out="$out$(quote_for_display "$arg")"
    done
    printf '%s' "$out"
}

# Globals used by run_child and its callers.
LAST_OUT=""
LAST_ERR=""
LAST_RC=0
CHILD_CWD=""
CHILD_ICD=""

run_child() {
    LAST_OUT=$(new_temp_file)
    LAST_ERR=$(new_temp_file)
    local rc icd_value="$CHILD_ICD" arg
    if [ -n "$icd_value" ] && [ "$HAS_CYGPATH" -eq 1 ]; then
        icd_value=$(cygpath -w "$icd_value")
    fi
    local converted
    converted=()
    for arg in "$@"; do
        converted[${#converted[@]}]="$(native_arg "$arg")"
    done
    if [ -n "$CHILD_CWD" ]; then
        if [ -n "$icd_value" ]; then
            ( cd "$CHILD_CWD" && VK_ICD_FILENAMES="$icd_value" "${converted[@]}" ) > "$LAST_OUT" 2> "$LAST_ERR"
        else
            ( cd "$CHILD_CWD" && "${converted[@]}" ) > "$LAST_OUT" 2> "$LAST_ERR"
        fi
    else
        if [ -n "$icd_value" ]; then
            VK_ICD_FILENAMES="$icd_value" "${converted[@]}" > "$LAST_OUT" 2> "$LAST_ERR"
        else
            "${converted[@]}" > "$LAST_OUT" 2> "$LAST_ERR"
        fi
    fi
    rc=$?
    LAST_RC=$rc
    return $rc
}

child_output() {
    cat "$LAST_OUT" 2>/dev/null || true
}

child_error() {
    cat "$LAST_ERR" 2>/dev/null || true
}

child_tail() {
    local lines="${1:-50}"
    {
        tail -n "$lines" "$LAST_ERR" 2>/dev/null || true
        tail -n "$lines" "$LAST_OUT" 2>/dev/null || true
    } | sed '/^$/d'
}

# Run a command, capture stdout in RUN_STDOUT, fail when nonzero.
run_capture() {
    log_debug "\$ $(display_command "$@")"
    run_child "$@"
    local rc=$?
    RUN_STDOUT=$(child_output)
    RUN_STDERR=$(child_error)
    cleanup_temp_files
    if [ "$rc" -ne 0 ]; then
        local detail
        detail=$(printf '%s\n%s' "$RUN_STDERR" "$RUN_STDOUT" | tail -n 50)
        local message="Command failed with exit code $rc: $(display_command "$@")"
        [ -n "$detail" ] && message="$message
$detail"
        die 1 "$message"
    fi
}

# ---------------------------------------------------------------------------
# Text, paths, and key=value files
# ---------------------------------------------------------------------------

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

lower() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

expand_home() {
    case "$1" in
        "~") printf '%s' "$HOME" ;;
        "~/"*) printf '%s/%s' "$HOME" "${1#\~/}" ;;
        *) printf '%s' "$1" ;;
    esac
}

normalize_absolute() {
    # Lexically normalize an absolute path with a POSIX-only implementation.
    local input="$1" part out=""
    local oldIFS="$IFS"
    set -f
    IFS='/'
    set -- $input
    IFS="$oldIFS"
    set +f
    for part in "$@"; do
        case "$part" in
            ''|'.') ;;
            '..') out="${out%/*}" ;;
            *) out="$out/$part" ;;
        esac
    done
    [ -n "$out" ] || out="/"
    printf '%s' "$out"
}

abspath() {
    local path base
    case "$1" in
        [A-Za-z]:[\\/]*)
            if [ "$HAS_CYGPATH" -eq 1 ]; then
                path=$(cygpath -u "$1")
            else
                path="$1"
            fi
            ;;
        *)
            path=$(expand_home "$1")
            ;;
    esac
    base="${2:-$PWD}"
    case "$path" in
        /*) ;;
        *) path="$base/$path" ;;
    esac
    normalize_absolute "$path"
}

same_path() {
    [ "$(abspath "$1")" = "$(abspath "$2")" ]
}

within_path() {
    local path root
    path=$(abspath "$1")
    root=$(abspath "$2")
    root="${root%/}"
    [ "$path" = "$root" ] && return 0
    case "$path" in
        "$root"/*) return 0 ;;
    esac
    return 1
}

ensure_within() {
    local path root
    path=$(abspath "$1")
    root=$(abspath "$2")
    if ! within_path "$path" "$root"; then
        die 4 "Path is outside the allowed root: $path (root: $root)"
    fi
    printf '%s' "$path"
}

file_mtime() {
    local path="$1" value=""
    if stat -c %Y "$path" >/dev/null 2>&1; then
        value=$(stat -c %Y "$path")
    elif stat -f %m "$path" >/dev/null 2>&1; then
        value=$(stat -f %m "$path")
    fi
    printf '%s' "${value:-0}"
}

file_size() {
    local value=""
    if stat -c %s "$1" >/dev/null 2>&1; then
        value=$(stat -c %s "$1")
    elif stat -f %z "$1" >/dev/null 2>&1; then
        value=$(stat -f %z "$1")
    elif [ -f "$1" ]; then
        value=$(wc -c < "$1" | tr -d ' ')
    fi
    printf '%s' "${value:-0}"
}

free_bytes() {
    local path="$1"
    while [ ! -e "$path" ] && [ "$path" != "/" ]; do
        path=$(dirname "$path")
    done
    df -Pk "$path" 2>/dev/null | awk 'NR==2 { printf "%.0f", $4 * 1024 }'
}

read_text_file() {
    sed '1s/^\xEF\xBB\xBF//' "$1"
}

# Key/value storage for config and job files.
KV_KEYS=()
KV_VALUES=()

kv_clear() {
    KV_KEYS=()
    KV_VALUES=()
}

kv_load() {
    local file="$1"
    kv_clear
    [ -f "$file" ] || return 0
    local line key value check
    while IFS= read -r line || [ -n "$line" ]; do
        line=${line%$'\r'}
        check="${line#"${line%%[![:space:]]*}"}"
        check="${check%"${check##*[![:space:]]}"}"
        [ -n "$check" ] || continue
        case "$check" in \#*) continue ;; esac
        case "$line" in
            *=*) ;;
            *) continue ;;
        esac
        key="${line%%=*}"
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        value="${line#*=}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        kv_set "$key" "$value"
    done < "$file"
}

kv_get() {
    local key="$1" default="${2:-}" i=0
    while [ "$i" -lt "${#KV_KEYS[@]}" ]; do
        if [ "${KV_KEYS[$i]}" = "$key" ]; then
            printf '%s' "${KV_VALUES[$i]}"
            return 0
        fi
        i=$((i + 1))
    done
    printf '%s' "$default"
}

kv_set() {
    local key="$1" value="$2" i=0
    while [ "$i" -lt "${#KV_KEYS[@]}" ]; do
        if [ "${KV_KEYS[$i]}" = "$key" ]; then
            KV_VALUES[$i]="$value"
            return 0
        fi
        i=$((i + 1))
    done
    KV_KEYS[${#KV_KEYS[@]}]="$key"
    KV_VALUES[${#KV_VALUES[@]}]="$value"
}

kv_write() {
    local file="$1" i=0 text=""
    while [ "$i" -lt "${#KV_KEYS[@]}" ]; do
        text="$text${KV_KEYS[$i]}=${KV_VALUES[$i]}
"
        i=$((i + 1))
    done
    write_text_atomic "$file" "$text"
}

write_text_atomic() {
    local file="$1" text="$2" parent temporary
    parent=$(dirname "$file")
    [ -d "$parent" ] || mkdir -p "$parent"
    temporary="$file.tmp.$$"
    printf '%s' "$text" > "$temporary" || die 1 "Could not write $temporary"
    mv -f "$temporary" "$file" || die 1 "Could not replace $file"
}

# ---------------------------------------------------------------------------
# Numbers, durations, display helpers
# ---------------------------------------------------------------------------

round_even() {
    awk -v x="$1" 'BEGIN {
        neg = (x < 0) ? -1 : 1;
        if (neg < 0) x = -x;
        i = int(x);
        f = x - i;
        if (f > 0.5 || (f == 0.5 && i % 2 == 1)) i = i + 1;
        printf "%.0f", neg * i;
    }'
}

num_cmp() {
    # num_cmp A OP B; OP is lt, le, gt, ge, eq, ne
    awk -v a="$1" -v b="$3" -v op="$2" 'BEGIN {
        if (op == "lt") exit !(a < b);
        if (op == "le") exit !(a <= b);
        if (op == "gt") exit !(a > b);
        if (op == "ge") exit !(a >= b);
        if (op == "eq") exit !(a == b);
        if (op == "ne") exit !(a != b);
        exit 1;
    }'
}

fcalc() {
    # fcalc A OP B [FORMAT]
    local format="${4:-%.3f}"
    awk -v a="$1" -v op="$2" -v b="$3" -v fmt="$format" 'BEGIN {
        if (op == "+") r = a + b;
        else if (op == "-") r = a - b;
        else if (op == "*") r = a * b;
        else if (op == "/") r = (b == 0) ? 0 : a / b;
        else r = 0;
        printf fmt, r;
    }'
}

format_duration() {
    awk -v s="$1" 'BEGIN {
        if (s < 0) s = 0;
        ms = int(s * 1000 + 0.5);
        h = int(ms / 3600000); ms -= h * 3600000;
        m = int(ms / 60000); ms -= m * 60000;
        sec = int(ms / 1000); ms -= sec * 1000;
        printf "%02d:%02d:%02d.%03d", h, m, sec, ms;
    }'
}

format_bytes() {
    awk -v b="$1" 'BEGIN {
        if (b < 0) b = 0;
        if (b < 1024) { printf "%.0f B", b; exit }
        split("KiB MiB GiB TiB PiB", units, " ");
        v = b; i = 1;
        while (v >= 1024 && i < 5) { v /= 1024; i++ }
        printf "%.1f %s", v, units[i-1];
    }'
}

parse_time_value() {
    local raw value parts count i
    raw=$(trim "$1")
    [ -n "$raw" ] || die 4 "Time value is empty"
    case "$raw" in -*) die 4 "Time value must not be negative: $1" ;; esac
    count=$(printf '%s' "$raw" | awk -F: '{print NF}')
    [ "$count" -le 3 ] || die 4 "Invalid time value: $1"
    local oldIFS="$IFS"
    IFS=':'
    set -- $raw
    IFS="$oldIFS"
    local total=0
    local index=0
    for value in "$@"; do
        [ -n "$value" ] || die 4 "Invalid time value: $1"
        case "$value" in
            *[!0-9.]*|*.*.*|.*|*.) die 4 "Invalid time value: $1" ;;
        esac
        if [ "$index" -gt 0 ]; then
            num_cmp "$value" ge 60 && die 4 "Minutes and seconds must be below 60: $1"
        fi
        total=$(fcalc "$total" '*' 60 '%.12f')
        total=$(fcalc "$total" '+' "$value" '%.12f')
        index=$((index + 1))
    done
    printf '%.6f' "$total"
}

normalize_fps() {
    # normalize_fps AVG REAL -> sets FPS_NUM FPS_DEN FPS_RATIONAL FPS_DECIMAL
    local avg="$1" real="$2" candidate num den gcd a b temp
    FPS_NUM=30; FPS_DEN=1
    for candidate in "$avg" "$real"; do
        case "$candidate" in
            */*) ;;
            *) continue ;;
        esac
        num=${candidate%%/*}
        den=${candidate#*/}
        case "$num" in ''|*[!0-9]*) continue ;; esac
        case "$den" in ''|*[!0-9]*) continue ;; esac
        [ "$num" -gt 0 ] && [ "$den" -gt 0 ] || continue
        a=$num; b=$den
        while [ "$b" -ne 0 ]; do temp=$b; b=$((a % b)); a=$temp; done
        FPS_NUM=$((num / a)); FPS_DEN=$((den / a))
        break
    done
    FPS_RATIONAL="$FPS_NUM/$FPS_DEN"
    FPS_DECIMAL=$(fcalc "$FPS_NUM" '/' "$FPS_DEN" '%.6f')
    FPS_TEXT=$(fcalc "$FPS_NUM" '/' "$FPS_DEN" '%.3f')
}

fps_override() {
    local text num den a b temp
    text=$(trim "$1")
    case "$text" in
        */*)
            num=${text%%/*}; den=${text#*/}
            case "$num" in ''|*[!0-9]*) die 4 "Invalid --fps value: $1" ;; esac
            case "$den" in ''|*[!0-9]*) die 4 "Invalid --fps value: $1" ;; esac
            [ "$num" -gt 0 ] && [ "$den" -gt 0 ] || die 4 "Invalid --fps value: $1"
            ;;
        *)
            case "$text" in
                *[!0-9.]*|*.*.*|.*|*.) die 4 "Invalid --fps value: $1" ;;
            esac
            den=1
            num=$text
            case "$text" in
                *.*)
                    den=1
                    local frac="${text#*.}" i=0
                    while [ "$i" -lt "${#frac}" ]; do den=$((den * 10)); i=$((i + 1)); done
                    num=$(awk -v v="$text" -v d="$den" 'BEGIN { printf "%.0f", v * d }')
                    ;;
            esac
            [ "$num" -gt 0 ] || die 4 "Invalid --fps value: $1"
            ;;
    esac
    a=$num; b=$den
    while [ "$b" -ne 0 ]; do temp=$b; b=$((a % b)); a=$temp; done
    FPS_NUM=$((num / a)); FPS_DEN=$((den / a))
    FPS_RATIONAL="$FPS_NUM/$FPS_DEN"
    FPS_DECIMAL=$(fcalc "$FPS_NUM" '/' "$FPS_DEN" '%.6f')
    FPS_TEXT=$(fcalc "$FPS_NUM" '/' "$FPS_DEN" '%.3f')
}

sanitize_job_id() {
    local value="$1"
    value=$(printf '%s' "$value" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    value=$(printf '%s' "$value" | LC_ALL=C sed 's/[<>:"\/\\|?*]/_/g' | tr -d '\000-\037')
    value=$(printf '%s' "$value" | sed 's/[[:space:]][[:space:]]*/_/g; s/__*/_/g; s/^[._ ]*//; s/[._ ]*$//')
    [ -n "$value" ] || { printf 'video'; return; }
    value=$(printf '%s' "$value" | cut -c1-80)
    value=$(printf '%s' "$value" | sed 's/^[._ ]*//; s/[._ ]*$//')
    [ -n "$value" ] || { printf 'video'; return; }
    case "$(lower "$value")" in
        con|prn|aux|nul|com[1-9]|lpt[1-9])
            value=$(printf '%s' "$value" | cut -c1-79)_
            ;;
    esac
    printf '%s' "$value"
}

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
        */*|*\\*|'~'|'~/'*) return 0 ;;
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

# ---------------------------------------------------------------------------
# Media probing
# ---------------------------------------------------------------------------

M_SOURCE=""
M_DURATION="0"
M_WIDTH="0"
M_HEIGHT="0"
M_PIX_FMT="unknown"
M_VIDEO_INDEX="0"
M_FPS_NUM=30
M_FPS_DEN=1
M_FPS_RATIONAL="30/1"
M_FPS_DECIMAL="30.000"
M_FPS_TEXT="30.000"
M_CHAPTERS="0"
M_COLOR_PRIMARIES=""
M_COLOR_TRC=""
M_COLOR_SPACE=""
M_COLOR_RANGE=""
M_ROTATION="0"
M_HDR="0"
M_SOURCE_SIZE="0"
M_SOURCE_MTIME="0"
M_NB_FRAMES=""
M_SAR=""

AUDIO_INDEX=()
AUDIO_CODEC=()
AUDIO_CHANNELS=()
SUB_INDEX=()
SUB_CODEC=()

probe_media() {
    local source="$1" fields line key value source_arg
    M_SOURCE=$(abspath "$source")
    if [ "$HAS_CYGPATH" -eq 1 ]; then source_arg=$(cygpath -m "$M_SOURCE"); else source_arg="$M_SOURCE"; fi
    [ -f "$M_SOURCE" ] || die 4 "Source not found: $source"

    fields=$("$CFG_FFPROBE" -v error -select_streams v:0 -count_packets \
        -show_entries stream=index,width,height,pix_fmt,avg_frame_rate,r_frame_rate,duration,color_primaries,color_transfer,color_space,color_range,nb_read_packets,sample_aspect_ratio \
        -of default=nw=1 "$source_arg" 2>/dev/null) || die 4 "ffprobe failed for: $source"

    M_WIDTH=""; M_HEIGHT=""; M_PIX_FMT="unknown"; M_VIDEO_INDEX="0"
    M_DURATION=""; M_FPS_AVG=""; M_FPS_REAL=""; M_NB_FRAMES=""
    M_COLOR_PRIMARIES=""; M_COLOR_TRC=""; M_COLOR_SPACE=""; M_COLOR_RANGE=""; M_SAR=""
    while IFS= read -r line || [ -n "$line" ]; do
        line=${line%$'\r'}
        case "$line" in
            *=*) ;;
            *) continue ;;
        esac
        key=${line%%=*}
        value=${line#*=}
        case "$key" in
            width) M_WIDTH="$value" ;;
            height) M_HEIGHT="$value" ;;
            pix_fmt) M_PIX_FMT="$value" ;;
            index) M_VIDEO_INDEX="$value" ;;
            duration) M_DURATION="$value" ;;
            avg_frame_rate) M_FPS_AVG="$value" ;;
            r_frame_rate) M_FPS_REAL="$value" ;;
            nb_read_packets) M_NB_FRAMES="$value" ;;
            color_primaries) M_COLOR_PRIMARIES="$value" ;;
            color_transfer) M_COLOR_TRC="$value" ;;
            color_space) M_COLOR_SPACE="$value" ;;
            color_range) M_COLOR_RANGE="$value" ;;
            sample_aspect_ratio) M_SAR="$value" ;;
        esac
    done <<EOF
$fields
EOF

    [ -n "$M_WIDTH" ] && [ -n "$M_HEIGHT" ] || die 4 "No video stream found in: $source"
    [ "$M_WIDTH" -gt 0 ] && [ "$M_HEIGHT" -gt 0 ] || die 4 "Invalid video dimensions in: $source"

    normalize_fps "${M_FPS_AVG:-}" "${M_FPS_REAL:-}"
    M_FPS_NUM="$FPS_NUM"
    M_FPS_DEN="$FPS_DEN"
    M_FPS_RATIONAL="$FPS_RATIONAL"
    M_FPS_DECIMAL="$FPS_DECIMAL"
    M_FPS_TEXT="$FPS_TEXT"

    case "$M_NB_FRAMES" in
        ''|*[!0-9]*) M_NB_FRAMES="" ;;
    esac
    case "$M_DURATION" in
        ''|*[!0-9.]*) M_DURATION="" ;;
    esac
    if [ -z "$M_DURATION" ] && [ -n "$M_NB_FRAMES" ] && [ "$M_NB_FRAMES" -gt 0 ]; then
        M_DURATION=$(fcalc "$M_NB_FRAMES" '*' "$FPS_DEN" '%.6f')
        M_DURATION=$(fcalc "$M_DURATION" '/' "$FPS_NUM" '%.6f')
    fi
    if [ -z "$M_DURATION" ]; then
        local format_duration
        format_duration=$("$CFG_FFPROBE" -v error -show_entries format=duration -of default=nw=1:nk=1 "$source_arg" 2>/dev/null | head -n 1)
        case "$format_duration" in ''|*[!0-9.]*) format_duration="" ;; esac
        if [ -n "$format_duration" ]; then
            M_DURATION="$format_duration"
        fi
    fi
    if [ -z "$M_DURATION" ] && [ -z "$M_NB_FRAMES" ]; then
        local tail_end
        tail_end=$(probe_last_video_end "$source_arg" "")
        [ -n "$tail_end" ] && M_DURATION="$tail_end"
    fi
    [ -n "$M_DURATION" ] || M_DURATION="0"

    AUDIO_INDEX=(); AUDIO_CODEC=(); AUDIO_CHANNELS=()
    local audio_lines
    audio_lines=$("$CFG_FFPROBE" -v error -select_streams a -show_entries stream=index,codec_name,channels -of csv=p=0 "$source_arg" 2>/dev/null || true)
    if [ -n "$audio_lines" ]; then
        local ai ac ach
        while IFS=, read -r ai ac ach; do
            [ -n "$ai" ] || continue
            AUDIO_INDEX[${#AUDIO_INDEX[@]}]="$ai"
            AUDIO_CODEC[${#AUDIO_CODEC[@]}]="${ac:-unknown}"
            AUDIO_CHANNELS[${#AUDIO_CHANNELS[@]}]="${ach:-0}"
        done <<EOF
$audio_lines
EOF
    fi

    SUB_INDEX=(); SUB_CODEC=()
    local sub_lines
    sub_lines=$("$CFG_FFPROBE" -v error -select_streams s -show_entries stream=index,codec_name -of csv=p=0 "$source_arg" 2>/dev/null || true)
    if [ -n "$sub_lines" ]; then
        local si sc
        while IFS=, read -r si sc; do
            [ -n "$si" ] || continue
            SUB_INDEX[${#SUB_INDEX[@]}]="$si"
            SUB_CODEC[${#SUB_CODEC[@]}]="${sc:-unknown}"
        done <<EOF
$sub_lines
EOF
    fi

    M_CHAPTERS=$("$CFG_FFPROBE" -v error -show_chapters -show_entries chapter=start_time -of csv=p=0 "$source_arg" 2>/dev/null | grep -c . || true)
    [ -n "$M_CHAPTERS" ] || M_CHAPTERS=0

    local rotation
    rotation=$("$CFG_FFPROBE" -v error -select_streams v:0 -show_entries stream=side_data_list -of json "$source_arg" 2>/dev/null | tr -d ' \n' | sed -n 's/.*"rotation":\(-\{0,1\}[0-9][0-9]*\).*/\1/p' | head -n 1)
    if [ -z "$rotation" ]; then
        rotation=$("$CFG_FFPROBE" -v error -select_streams v:0 -show_entries stream_tags=rotate -of default=nw=1:nk=1 "$source_arg" 2>/dev/null | head -n 1)
        case "$rotation" in ''|*[!0-9-]*) rotation=0 ;; esac
    fi
    rotation=$(( (rotation % 360 + 360) % 360 ))
    M_ROTATION="$rotation"

    case "$(lower "$M_COLOR_TRC")" in
        smpte2084|arib-std-b67) M_HDR=1 ;;
        *) M_HDR=0 ;;
    esac

    M_SOURCE_SIZE=$(file_size "$M_SOURCE")
    M_SOURCE_MTIME=$(file_mtime "$M_SOURCE")
}

S_M_SOURCE=""; S_M_DURATION=""; S_M_WIDTH=""; S_M_HEIGHT=""; S_M_PIX_FMT=""
S_M_VIDEO_INDEX=""; S_M_FPS_NUM=""; S_M_FPS_DEN=""; S_M_FPS_RATIONAL=""
S_M_FPS_DECIMAL=""; S_M_FPS_TEXT=""; S_M_CHAPTERS=""; S_M_COLOR_PRIMARIES=""
S_M_COLOR_TRC=""; S_M_COLOR_SPACE=""; S_M_COLOR_RANGE=""; S_M_ROTATION=""
S_M_HDR=""; S_M_SOURCE_SIZE=""; S_M_SOURCE_MTIME=""; S_M_NB_FRAMES=""; S_M_SAR=""
S_AUDIO_INDEX=(); S_AUDIO_CODEC=(); S_AUDIO_CHANNELS=()
S_SUB_INDEX=(); S_SUB_CODEC=()

save_media_state() {
    S_M_SOURCE="$M_SOURCE"; S_M_DURATION="$M_DURATION"
    S_M_WIDTH="$M_WIDTH"; S_M_HEIGHT="$M_HEIGHT"; S_M_PIX_FMT="$M_PIX_FMT"
    S_M_VIDEO_INDEX="$M_VIDEO_INDEX"
    S_M_FPS_NUM="$M_FPS_NUM"; S_M_FPS_DEN="$M_FPS_DEN"
    S_M_FPS_RATIONAL="$M_FPS_RATIONAL"; S_M_FPS_DECIMAL="$M_FPS_DECIMAL"; S_M_FPS_TEXT="$M_FPS_TEXT"
    S_M_CHAPTERS="$M_CHAPTERS"
    S_M_COLOR_PRIMARIES="$M_COLOR_PRIMARIES"; S_M_COLOR_TRC="$M_COLOR_TRC"
    S_M_COLOR_SPACE="$M_COLOR_SPACE"; S_M_COLOR_RANGE="$M_COLOR_RANGE"
    S_M_ROTATION="$M_ROTATION"; S_M_HDR="$M_HDR"
    S_M_SOURCE_SIZE="$M_SOURCE_SIZE"; S_M_SOURCE_MTIME="$M_SOURCE_MTIME"
    S_M_NB_FRAMES="$M_NB_FRAMES"; S_M_SAR="$M_SAR"
    S_AUDIO_INDEX=("${AUDIO_INDEX[@]}"); S_AUDIO_CODEC=("${AUDIO_CODEC[@]}")
    S_AUDIO_CHANNELS=("${AUDIO_CHANNELS[@]}")
    S_SUB_INDEX=("${SUB_INDEX[@]}"); S_SUB_CODEC=("${SUB_CODEC[@]}")
}

restore_media_state() {
    M_SOURCE="$S_M_SOURCE"; M_DURATION="$S_M_DURATION"
    M_WIDTH="$S_M_WIDTH"; M_HEIGHT="$S_M_HEIGHT"; M_PIX_FMT="$S_M_PIX_FMT"
    M_VIDEO_INDEX="$S_M_VIDEO_INDEX"
    M_FPS_NUM="$S_M_FPS_NUM"; M_FPS_DEN="$S_M_FPS_DEN"
    M_FPS_RATIONAL="$S_M_FPS_RATIONAL"; M_FPS_DECIMAL="$S_M_FPS_DECIMAL"; M_FPS_TEXT="$S_M_FPS_TEXT"
    M_CHAPTERS="$S_M_CHAPTERS"
    M_COLOR_PRIMARIES="$S_M_COLOR_PRIMARIES"; M_COLOR_TRC="$S_M_COLOR_TRC"
    M_COLOR_SPACE="$S_M_COLOR_SPACE"; M_COLOR_RANGE="$S_M_COLOR_RANGE"
    M_ROTATION="$S_M_ROTATION"; M_HDR="$S_M_HDR"
    M_SOURCE_SIZE="$S_M_SOURCE_SIZE"; M_SOURCE_MTIME="$S_M_SOURCE_MTIME"
    M_NB_FRAMES="$S_M_NB_FRAMES"; M_SAR="$S_M_SAR"
    AUDIO_INDEX=("${S_AUDIO_INDEX[@]}"); AUDIO_CODEC=("${S_AUDIO_CODEC[@]}")
    AUDIO_CHANNELS=("${S_AUDIO_CHANNELS[@]}")
    SUB_INDEX=("${S_SUB_INDEX[@]}"); SUB_CODEC=("${S_SUB_CODEC[@]}")
}

probe_last_video_end() {
    local source="$1" format_duration="$2" start output max native_source="$1"
    if [ "$HAS_CYGPATH" -eq 1 ]; then native_source=$(cygpath -m "$source"); fi
    case "$format_duration" in
        ''|0|*[!0-9.]*) format_duration=$("$CFG_FFPROBE" -v error -show_entries format=duration -of default=nw=1:nk=1 "$native_source" 2>/dev/null | head -n 1) ;;
    esac
    case "$format_duration" in ''|*[!0-9.]*) return 1 ;; esac
    start=$(fcalc "$format_duration" '-' 2 '%.3f')
    if num_cmp "$start" lt 0; then start=0; fi
    output=$("$CFG_FFPROBE" -v error -select_streams v:0 -show_entries packet=pts_time,duration_time -of csv=p=0 -read_intervals "${start}%+2.0" "$native_source" 2>/dev/null || true)
    [ -n "$output" ] || return 1
    max=$(printf '%s\n' "$output" | awk -F, '
        NF >= 1 && $1 != "" && $1 != "N/A" {
            pts = $1 + 0;
            dur = (NF >= 2 && $2 != "N/A") ? $2 + 0 : 0;
            end = pts + dur;
            if (end > max) max = end;
        }
        END { if (max > 0) printf "%.6f", max }
    ')
    [ -n "$max" ] && [ "$max" != "0" ] || return 1
    printf '%s' "$max"
}

probe_frame_dimensions() {
    local path="$1" value probe_path="$1"
    if [ "$HAS_CYGPATH" -eq 1 ]; then probe_path=$(cygpath -m "$path"); fi
    value=$("$CFG_FFPROBE" -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$probe_path" 2>/dev/null | head -n 1)
    case "$value" in
        *,*) printf '%s' "$value" ;;
        *) die 4 "Could not read frame dimensions: $path" ;;
    esac
}

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

# ---------------------------------------------------------------------------
# Frames
# ---------------------------------------------------------------------------

FS_DIR=""
FS_EXT=""
FS_EXT_DETECTED=""
FS_COUNT=0
FS_INDICES=()
FS_PATHS=()

frame_pattern() {
    case "$(lower "$1")" in
        png) printf 'frame_%%08d.png' ;;
        jpg|jpeg) printf 'frame_%%08d.jpg' ;;
        *) die 4 "Unsupported frame format: $1" ;;
    esac
}

scan_frames() {
    local dir="$1" recursive="${2:-0}" maxdepth=1 path base rest idx8 rest2 ext
    [ -d "$dir" ] || return 0
    [ "$recursive" -eq 1 ] && maxdepth=2
    find "$dir" -maxdepth "$maxdepth" -type f 2>/dev/null | while IFS= read -r path; do
        [ -s "$path" ] || continue
        base=${path##*/}
        case "$base" in
            [Ff][Rr][Aa][Mm][Ee]_*) ;;
            *) continue ;;
        esac
        rest=${base:6}
        idx8=${rest:0:8}
        rest2=${rest:8}
        case "$idx8" in
            [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;
            *) continue ;;
        esac
        case "$rest2" in
            ''|_*|-*|.*) ;;
            *) continue ;;
        esac
        ext=${rest2##*.}
        case "$ext" in
            [Pp][Nn][Gg]|[Jj][Pp][Gg]|[Jj][Pp][Ee][Gg]|[Ww][Ee][Bb][Pp]) ;;
            *) continue ;;
        esac
        printf '%s\t%s\n' "$((10#$idx8))" "$path"
    done | sort -n -k1,1
}

count_contiguous_frames() {
    local dir="$1" ext="$2" wanted tmp
    wanted=$(lower "$ext")
    wanted=${wanted#.}
    tmp=$(new_temp_file)
    scan_frames "$dir" 0 > "$tmp"
    awk -F'\t' -v wanted="$wanted" 'BEGIN { expected = 0; done = 0 }
        {
            name = $2;
            n = tolower(name);
            ok = 0;
            if (wanted == "png") { if (n ~ /\.png$/) ok = 1 }
            else if (wanted == "jpg" || wanted == "jpeg") { if (n ~ /\.jpe?g$/) ok = 1 }
            else if (wanted == "webp") { if (n ~ /\.webp$/) ok = 1 }
            if (!ok) next;
            idx = $1 + 0;
            if (idx == expected + 1) { expected++ }
            else if (idx > expected + 1) { print expected; done = 1; exit }
        }
        END { if (!done) print expected }
    ' "$tmp"
    rm -f "$tmp"
}

frame_signature_ok() {
    local path="$1" header
    header=$(od -An -tx1 -N12 "$path" 2>/dev/null | tr -d ' \n')
    case "$header" in
        89504e470d0a1a0a*) return 0 ;;
        ffd8ff*) return 0 ;;
        52494646????????57454250*) return 0 ;;
    esac
    return 1
}

validate_frame_set() {
    local dir="$1" expected="${2:-}" pick="${3:-error}" verify="${4:-0}"
    local tmp idx path prev paths count selected max missing extra details ext current i
    FS_DIR=$(abspath "$dir")
    FS_INDICES=(); FS_PATHS=(); FS_EXT_DETECTED=""
    [ -d "$FS_DIR" ] || die 4 "No upscaled frames found: $FS_DIR"

    tmp=$(new_temp_file)
    scan_frames "$FS_DIR" 1 > "$tmp"
    [ -s "$tmp" ] || { rm -f "$tmp"; die 4 "No valid frames found in: $FS_DIR"; }

    prev=""
    paths=()
    while IFS=$'\t' read -r idx path; do
        idx=$((10#$idx))
        if [ -z "$prev" ]; then prev="$idx"; paths=("$path"); continue; fi
        if [ "$idx" = "$prev" ]; then
            paths[${#paths[@]}]="$path"
            continue
        fi
        select_frame_candidate "$prev" "$pick" "${paths[@]}"
        prev="$idx"
        paths=("$path")
    done < "$tmp"
    if [ -n "$prev" ]; then
        select_frame_candidate "$prev" "$pick" "${paths[@]}"
    fi
    rm -f "$tmp"

    count=${#FS_INDICES[@]}
    [ "$count" -gt 0 ] || die 4 "No valid frames found in: $FS_DIR"

    max=${FS_INDICES[$((count - 1))]}
    [ "$max" -ge 1 ] || max=1
    if [ -n "$expected" ]; then
        [ "$max" -lt "$expected" ] && max="$expected"
    fi
    missing=""
    extra=""
    local i=1
    while [ "$i" -le "$max" ]; do
        if ! array_contains "$i" "${FS_INDICES[@]}"; then
            missing="$missing $(printf '%08d' "$i")"
            [ "$(printf '%s' "$missing" | wc -w)" -ge 20 ] && break
        fi
        i=$((i + 1))
    done
    if [ -n "$expected" ]; then
        for idx in "${FS_INDICES[@]}"; do
            if [ "$idx" -gt "$expected" ]; then
                extra="$extra $(printf '%08d' "$idx")"
                [ "$(printf '%s' "$extra" | wc -w)" -ge 20 ] && break
            fi
        done
    fi
    if [ -n "$missing" ] || [ -n "$extra" ]; then
        details=""
        [ -n "$missing" ] && details="missing:$missing"
        [ -n "$extra" ] && details="$details; unexpected:$extra"
        die 4 "Frame set is not contiguous in: $FS_DIR" "${details#; }"
    fi

    FS_EXT="$FS_EXT_DETECTED"
    [ -n "$FS_EXT" ] || die 4 "Could not determine the frame extension in: $FS_DIR"

    if [ "$verify" -eq 1 ]; then
        i=0
        while [ "$i" -lt "${#FS_PATHS[@]}" ]; do
            frame_signature_ok "${FS_PATHS[$i]}" || die 4 "Invalid frame signature at index $(printf '%08d' "${FS_INDICES[$i]}"): ${FS_PATHS[$i]}"
            i=$((i + 1))
        done
    fi
    FS_COUNT=${#FS_INDICES[@]}
}

# Globals used by select_frame_candidate.
SELECTED_PATH=""

select_frame_candidate() {
    local idx="$1" pick="$2" path best best_mtime best_size mtime size
    shift 2
    local paths
    paths=("$@")
    if [ "${#paths[@]}" -eq 1 ]; then
        SELECTED_PATH="${paths[0]}"
    elif [ "$pick" = "error" ]; then
        die 4 "Multiple frames for index $(printf '%08d' "$idx"): $(printf '%s, ' "${paths[@]}" | sed 's/, $//')" "Use --pick newest or --pick largest, or remove duplicates."
    elif [ "$pick" = "newest" ]; then
        best="${paths[0]}"
        best_mtime=$(file_mtime "$best")
        for path in "${paths[@]}"; do
            mtime=$(file_mtime "$path")
            if [ "$mtime" -gt "$best_mtime" ] || { [ "$mtime" = "$best_mtime" ] && [ "$(basename "$path")" \> "$(basename "$best")" ]; }; then
                best="$path"; best_mtime="$mtime"
            fi
        done
        SELECTED_PATH="$best"
    elif [ "$pick" = "largest" ]; then
        best="${paths[0]}"
        best_size=$(file_size "$best")
        for path in "${paths[@]}"; do
            size=$(file_size "$path")
            if [ "$size" -gt "$best_size" ] || { [ "$size" = "$best_size" ] && [ "$(basename "$path")" \> "$(basename "$best")" ]; }; then
                best="$path"; best_size="$size"
            fi
        done
        SELECTED_PATH="$best"
    else
        die 4 "Unknown --pick mode: $pick"
    fi
    local current=""
    case "${SELECTED_PATH##*.}" in
        [Pp][Nn][Gg]) current=png ;;
        [Jj][Pp][Gg]) current=jpg ;;
        [Jj][Pp][Ee][Gg]) current=jpeg ;;
        [Ww][Ee][Bb][Pp]) current=webp ;;
    esac
    if [ -z "$FS_EXT_DETECTED" ]; then
        FS_EXT_DETECTED="$current"
    elif [ "$FS_EXT_DETECTED" != "$current" ]; then
        die 4 "Mixed frame formats are not supported: $FS_EXT_DETECTED, $current"
    fi
    FS_INDICES[${#FS_INDICES[@]}]="$idx"
    FS_PATHS[${#FS_PATHS[@]}]="$SELECTED_PATH"
}

array_contains() {
    local needle="$1" item
    shift
    for item in "$@"; do
        [ "$item" = "$needle" ] && return 0
    done
    return 1
}

build_sequence() {
    local target_source target ext name
    # Normalized already?
    local i=0 normalized=1
    if [ "${#FS_PATHS[@]}" -eq 0 ]; then normalized=0; fi
    while [ "$i" -lt "${#FS_PATHS[@]}" ]; do
        name="frame_$(printf '%08d' "${FS_INDICES[$i]}").$FS_EXT"
        if [ "${FS_PATHS[$i]##*/}" != "$name" ]; then normalized=0; break; fi
        i=$((i + 1))
    done
    [ "$normalized" -eq 1 ] && return 0
    [ "${#FS_PATHS[@]}" -gt 0 ] || die 4 "Cannot build an image sequence from zero frames"

    local sequence="$JOB_DIR/sequence"
    rm -rf "$sequence"
    mkdir -p "$sequence" || die 1 "Could not create $sequence"
    local new_paths
    new_paths=()
    i=0
    while [ "$i" -lt "${#FS_PATHS[@]}" ]; do
        source="${FS_PATHS[$i]}"
        name="frame_$(printf '%08d' "${FS_INDICES[$i]}").$FS_EXT"
        target="$sequence/$name"
        if ! ln "$source" "$target" 2>/dev/null; then
            cp -p "$source" "$target" || die 1 "Could not copy $source"
        fi
        new_paths[${#new_paths[@]}]="$target"
        i=$((i + 1))
    done
    FS_DIR="$sequence"
    FS_PATHS=("${new_paths[@]}")
    log_debug "Normalized ${#FS_PATHS[@]} frames into $sequence"
}

# ---------------------------------------------------------------------------
# Disk estimates
# ---------------------------------------------------------------------------

sample_frame_bytes() {
    local source="$1" start="$2" duration="$3" fmt="$4" denoise="$5" tonemap="$6" decode="$7"
    local total offset sample_at temp_dir out command_file
    total="$duration"
    offset=$(fcalc "$total" '*' 0.1 '%.6f')
    if num_cmp "$offset" gt 1; then offset=1; fi
    if num_cmp "$offset" lt 0; then offset=0; fi
    sample_at=$(fcalc "$start" '+' "$offset" '%.6f')
    if num_cmp "$total" le 0; then sample_at="$start"; fi

    temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/upscayl-sample.XXXXXX") || die 1 "Could not create a temporary directory"
    split_command "$source" "$sample_at" "" 1 "$fmt" 1 3 "$denoise" "$tonemap" "$decode" "$temp_dir" 1
    CMD[0]="$CFG_FFMPEG"
    log_debug "\$ $(display_command "${CMD[@]}")"
    run_child "${CMD[@]}"
    if [ "$LAST_RC" -eq 0 ]; then
        local first
        first=$(find "$temp_dir" -maxdepth 1 -type f -size +0c 2>/dev/null | head -n 1)
        if [ -n "$first" ]; then
            file_size "$first"
            rm -rf "$temp_dir"
            cleanup_temp_files
            return 0
        fi
    fi
    rm -rf "$temp_dir"
    cleanup_temp_files
    local fallback
    if [ "$(lower "$fmt")" = "jpg" ]; then
        fallback=$((M_WIDTH * M_HEIGHT))
    else
        fallback=$((M_WIDTH * M_HEIGHT * 3))
    fi
    [ "$fallback" -gt 0 ] || fallback=1
    log_warn "Could not measure a sample frame; using $(format_bytes "$fallback") per frame"
    printf '%s' "$fallback"
}

disk_estimate() {
    # Sets EST_FRAME_BYTES EST_FRAMES_BYTES EST_UPSCALED_BYTES EST_TOTAL_BYTES
    local sample="$1" frames="$2" scale="$3"
    EST_FRAME_BYTES="$sample"
    EST_FRAMES_BYTES=$(awk -v s="$sample" -v n="$frames" 'BEGIN { printf "%.0f", s * n * 1.15 }')
    EST_UPSCALED_BYTES=$(awk -v s="$sample" -v n="$frames" -v k="$scale" 'BEGIN { printf "%.0f", s * k * k * n * 1.15 }')
    EST_TOTAL_BYTES=$(awk -v a="$EST_FRAMES_BYTES" -v b="$EST_UPSCALED_BYTES" 'BEGIN { printf "%.0f", a + b + 1073741824 }')
}

check_disk_estimate() {
    local free="$1" cap floor remaining
    cap=$((CFG_MAX_WORK_GB * 1073741824))
    if [ "$EST_TOTAL_BYTES" -gt "$cap" ]; then
        log_warn "Estimated work size $(format_bytes "$EST_TOTAL_BYTES") exceeds the $CFG_MAX_WORK_GB GiB cap; a long job should use chunked processing."
    fi
    floor=$((CFG_MIN_FREE_GB * 1073741824))
    remaining=$((free - EST_TOTAL_BYTES))
    if [ "$remaining" -lt "$floor" ]; then
        die 5 "Not enough free space: need $(format_bytes "$EST_TOTAL_BYTES") plus $CFG_MIN_FREE_GB GiB free, have $(format_bytes "$free")" "Use --work-dir on a larger drive, reduce the time range, or split the video first."
    fi
}

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
    local expected_values="$SP_FORMAT|$media_fps|$(fcalc "$start" '+' 0 '%.3f')|$expected_range_end|$SP_DENOISE|$SP_TONEMAP|$SP_PNG|$SP_JPEG"
    local i=1
    local oldIFS="$IFS"
    IFS='|'
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

# ---------------------------------------------------------------------------
# Encoding, audio/subtitle plans, and assemble
# ---------------------------------------------------------------------------

PRESET_NAME=""; PRESET_CONTAINER=""; PRESET_EXT=""; PRESET_CODEC=""
PRESET_AUDIO=""; PRESET_SUBS=""

preset_resolve() {
    PRESET_NAME=$(lower "$1")
    case "$PRESET_NAME" in
        mp4-h264) PRESET_CONTAINER=mp4; PRESET_EXT=mp4; PRESET_CODEC=h264; PRESET_AUDIO=auto; PRESET_SUBS=auto ;;
        mp4-hevc) PRESET_CONTAINER=mp4; PRESET_EXT=mp4; PRESET_CODEC=hevc; PRESET_AUDIO=auto; PRESET_SUBS=auto ;;
        mkv-hevc) PRESET_CONTAINER=mkv; PRESET_EXT=mkv; PRESET_CODEC=hevc; PRESET_AUDIO=copy; PRESET_SUBS=copy ;;
        mov-prores) PRESET_CONTAINER=mov; PRESET_EXT=mov; PRESET_CODEC=prores; PRESET_AUDIO=pcm; PRESET_SUBS=auto ;;
        *) die 4 "Unknown preset: $1" "Choose one of: mkv-hevc, mov-prores, mp4-h264, mp4-hevc" ;;
    esac
}

QUALITY_VALUE=0

quality_resolve() {
    local quality="$1" crf="${2:-}" level value
    level=$(lower "$quality")
    case "$level" in fast|balanced|quality) ;; *) die 4 "Unknown quality level: $quality" ;; esac
    if [ "$PRESET_CODEC" = "prores" ]; then
        [ -z "$crf" ] || die 4 "ProRes does not support --crf; use --quality instead"
        QUALITY_VALUE=0
        return 0
    fi
    if [ -n "$crf" ]; then
        case "$crf" in *[!0-9]*) die 4 "--crf must be between 0 and 51 for H.264/HEVC" ;; esac
        [ "$crf" -ge 0 ] && [ "$crf" -le 51 ] || die 4 "--crf must be between 0 and 51 for H.264/HEVC"
        QUALITY_VALUE="$crf"
        return 0
    fi
    if [ "$PRESET_CODEC" = "h264" ]; then
        case "$level" in fast) QUALITY_VALUE=22 ;; balanced) QUALITY_VALUE=20 ;; quality) QUALITY_VALUE=18 ;; esac
    else
        case "$level" in fast) QUALITY_VALUE=24 ;; balanced) QUALITY_VALUE=22 ;; quality) QUALITY_VALUE=20 ;; esac
    fi
}

ENCODER_LIST=""
ENCODER_CACHE_FILE=""

load_encoders() {
    [ -n "$ENCODER_CACHE_FILE" ] && return 0
    ENCODER_CACHE_FILE=$(new_temp_file)
    run_capture "$CFG_FFMPEG" -hide_banner -encoders
    printf '%s\n' "$RUN_STDOUT" > "$ENCODER_CACHE_FILE"
}

encoder_available() {
    load_encoders
    awk -v name="$1" '
        length($1) == 6 && $1 ~ /^[A-Z.]+$/ && $2 == name { found = 1 }
        END { exit !found }
    ' "$ENCODER_CACHE_FILE"
}

CAND_FAMILY=()
CAND_CODEC=()

ENC_ARGS=()

apply_quality() {
    local family="$1" codec="$2" level="$3"
    level=$(lower "$level")
    ENC_ARGS=()
    if [ "$codec" = "prores_ks" ]; then
        case "$level" in fast) ENC_ARGS=(1) ;; balanced) ENC_ARGS=(2) ;; quality) ENC_ARGS=(3) ;; esac
        return 0
    fi
    case "$family" in
        nvidia)
            case "$level" in
                fast) ENC_ARGS=(-preset p5 -tune hq -rc vbr) ;;
                balanced) ENC_ARGS=(-preset p6 -tune hq -rc vbr) ;;
                quality) ENC_ARGS=(-preset p7 -tune hq -rc vbr -multipass fullres -spatial_aq 1 -aq-strength 12) ;;
            esac
            ;;
        amd)
            ENC_ARGS=(-quality quality -rc cqp)
            ;;
        *)
            case "$codec" in
                libx264)
                    case "$level" in fast) ENC_ARGS=(-preset veryfast) ;; balanced) ENC_ARGS=(-preset medium) ;; quality) ENC_ARGS=(-preset slow) ;; esac
                    ;;
                libx265)
                    case "$level" in fast) ENC_ARGS=(-preset fast) ;; balanced) ENC_ARGS=(-preset medium) ;; quality) ENC_ARGS=(-preset slow) ;; esac
                    ;;
            esac
            ;;
    esac
}

VCA=()

video_codec_args() {
    local family="$1" codec="$2" quality="$3" tenbit="$4" pixfmt profile
    VCA=()
    if [ "$codec" = "prores_ks" ]; then
        [ "$tenbit" -eq 1 ] && die 4 "--10bit is not valid with ProRes; ProRes is already 10-bit"
        profile="${ENC_ARGS[0]:-3}"
        VCA=(-c:v prores_ks -profile:v "$profile" -vendor apl0 -pix_fmt yuv422p10le)
        return 0
    fi
    case "$codec" in h264_nvenc|h264_amf|libx264) [ "$tenbit" -eq 1 ] && die 4 "--10bit is only valid for HEVC output" ;; esac
    VCA=(-c:v "$codec")
    case "$family" in
        nvidia)
            local has_preset=0 arg
            for arg in "${ENC_ARGS[@]}"; do [ "$arg" = "-preset" ] && has_preset=1; done
            if [ "$has_preset" -eq 0 ]; then VCA=("${VCA[@]}" -preset p6 -tune hq -rc vbr); fi
            VCA=("${VCA[@]}" "${ENC_ARGS[@]}" -cq "$quality" -b:v 0)
            ;;
        amd)
            VCA=("${VCA[@]}" "${ENC_ARGS[@]}" -qp_i "$quality" -qp_p "$quality")
            ;;
        *)
            case "$codec" in
                libx264|libx265)
                    VCA=("${VCA[@]}" "${ENC_ARGS[@]}" -crf "$quality")
                    ;;
            esac
            ;;
    esac
    case "$codec" in
        hevc_nvenc|hevc_amf|libx265) [ "$tenbit" -eq 1 ] && pixfmt=yuv420p10le || pixfmt=yuv420p ;;
        *) pixfmt=yuv420p ;;
    esac
    VCA=("${VCA[@]}" -pix_fmt "$pixfmt")
}

encoder_candidates() {
    local requested="$1" family codec
    requested=$(lower "$requested")
    CAND_FAMILY=(); CAND_CODEC=()
    case "$requested" in auto) local order="nvidia amd cpu" ;; nvidia|amd|cpu) local order="$requested" ;; *) die 4 "Unknown encoder: $requested" ;; esac
    for family in $order; do
        case "$PRESET_CODEC:$family" in
            h264:nvidia) codec=h264_nvenc ;;
            h264:amd) codec=h264_amf ;;
            h264:cpu) codec=libx264 ;;
            hevc:nvidia) codec=hevc_nvenc ;;
            hevc:amd) codec=hevc_amf ;;
            hevc:cpu) codec=libx265 ;;
            prores:nvidia) codec="" ;;
            prores:amd) codec="" ;;
            prores:cpu) codec=prores_ks ;;
            *) codec="" ;;
        esac
        [ -n "$codec" ] || continue
        if encoder_available "$codec"; then
            CAND_FAMILY[${#CAND_FAMILY[@]}]="$family"
            CAND_CODEC[${#CAND_CODEC[@]}]="$codec"
        fi
    done
    if [ "${#CAND_CODEC[@]}" -eq 0 ]; then
        if [ "$requested" = "auto" ]; then
            die 3 "No usable encoder found for $PRESET_NAME" "Install FFmpeg with the required encoders or use --encoder cpu."
        fi
        die 3 "Encoder not available: $requested" "Use --encoder auto or cpu."
    fi
}

AUD_ENABLED=0
AUD_SRC=()
AUD_MODE=()

audio_compatible() {
    local container="$1" codec
    codec=$(lower "$2")
    case "$container" in
        mkv) return 0 ;;
        mp4) case "$codec" in aac|mp3|ac3|eac3|alac) return 0 ;; esac ;;
        mov) case "$codec" in aac|mp3|ac3|eac3|alac|pcm_*) return 0 ;; esac ;;
    esac
    return 1
}

audio_plan() {
    local mode="$1" bitrate="$2" all_audio="$3"
    local requested stream_mode i bad=""
    requested=$(lower "$mode")
    case "$requested" in auto|copy|aac|pcm|none) ;; *) die 4 "Unknown audio mode: $mode" ;; esac
    [ "$bitrate" -gt 0 ] || die 4 "Audio bitrate must be greater than zero"
    AUD_ENABLED=0; AUD_SRC=(); AUD_MODE=()
    if [ "${#AUDIO_INDEX[@]}" -eq 0 ] || [ "$requested" = "none" ]; then return 0; fi
    if [ "$requested" = "auto" ]; then
        case "$PRESET_AUDIO" in copy|aac|pcm) requested="$PRESET_AUDIO" ;; esac
    fi
    if [ "$requested" = "pcm" ]; then
        [ "$PRESET_CONTAINER" = "mp4" ] && die 4 "PCM audio is not supported in MP4." "Use --preset mkv-hevc or --audio aac."
        i=0
        while [ "$i" -lt "${#AUDIO_INDEX[@]}" ]; do
            AUD_SRC[${#AUD_SRC[@]}]="${AUDIO_INDEX[$i]}"; AUD_MODE[${#AUD_MODE[@]}]="pcm"
            [ "$all_audio" -eq 1 ] || break
            i=$((i + 1))
        done
        AUD_ENABLED=1
        return 0
    fi
    if [ "$requested" = "copy" ]; then
        i=0
        while [ "$i" -lt "${#AUDIO_INDEX[@]}" ]; do
            if ! audio_compatible "$PRESET_CONTAINER" "${AUDIO_CODEC[$i]}"; then bad="$bad ${AUDIO_CODEC[$i]}"; fi
            [ "$all_audio" -eq 1 ] || break
            i=$((i + 1))
        done
        if [ -n "$bad" ]; then
            die 4 "Audio codec cannot be copied into $PRESET_CONTAINER:$bad" "Use --audio aac or --preset mkv-hevc."
        fi
        i=0
        while [ "$i" -lt "${#AUDIO_INDEX[@]}" ]; do
            AUD_SRC[${#AUD_SRC[@]}]="${AUDIO_INDEX[$i]}"; AUD_MODE[${#AUD_MODE[@]}]="copy"
            [ "$all_audio" -eq 1 ] || break
            i=$((i + 1))
        done
        AUD_ENABLED=1
        return 0
    fi
    if [ "$requested" = "aac" ]; then
        i=0
        while [ "$i" -lt "${#AUDIO_INDEX[@]}" ]; do
            AUD_SRC[${#AUD_SRC[@]}]="${AUDIO_INDEX[$i]}"; AUD_MODE[${#AUD_MODE[@]}]="aac"
            [ "$all_audio" -eq 1 ] || break
            i=$((i + 1))
        done
        AUD_ENABLED=1
        return 0
    fi
    i=0
    while [ "$i" -lt "${#AUDIO_INDEX[@]}" ]; do
        stream_mode=copy
        audio_compatible "$PRESET_CONTAINER" "${AUDIO_CODEC[$i]}" || stream_mode=aac
        AUD_SRC[${#AUD_SRC[@]}]="${AUDIO_INDEX[$i]}"; AUD_MODE[${#AUD_MODE[@]}]="$stream_mode"
        [ "$all_audio" -eq 1 ] || break
        i=$((i + 1))
    done
    AUD_ENABLED=1
}

SUB_SRC=()
SUB_MODE=()
SUB_DROPPED=()

subtitle_compatible() {
    local container="$1" codec
    codec=$(lower "$2")
    case "$container" in
        mkv) [ "$codec" != "mov_text" ] && return 0 ;;
        mp4|mov) [ "$codec" = "mov_text" ] && return 0 ;;
    esac
    return 1
}

is_image_subtitle() {
    case "$(lower "$1")" in hdmv_pgs_subtitle|dvd_subtitle|dvb_subtitle|xsub) return 0 ;; esac
    return 1
}

is_text_subtitle() {
    case "$(lower "$1")" in subrip|ass|ssa|webvtt|mov_text|text) return 0 ;; esac
    return 1
}

subtitle_plan() {
    local mode="$1" requested i codec text_mode bad="" image="" dropped=""
    requested=$(lower "$mode")
    SUB_SRC=(); SUB_MODE=(); SUB_DROPPED=()
    case "$requested" in auto|copy|convert|none) ;; *) die 4 "Unknown subtitle mode: $mode" ;; esac
    [ "${#SUB_INDEX[@]}" -eq 0 ] && return 0
    [ "$requested" = "none" ] && return 0
    if [ "$requested" = "copy" ]; then
        i=0
        while [ "$i" -lt "${#SUB_INDEX[@]}" ]; do
            subtitle_compatible "$PRESET_CONTAINER" "${SUB_CODEC[$i]}" || bad="$bad ${SUB_CODEC[$i]}"
            i=$((i + 1))
        done
        [ -n "$bad" ] && die 4 "Subtitle codec cannot be copied into $PRESET_CONTAINER:$bad" "Use --subs convert or --preset mkv-hevc."
        i=0
        while [ "$i" -lt "${#SUB_INDEX[@]}" ]; do
            SUB_SRC[${#SUB_SRC[@]}]="${SUB_INDEX[$i]}"; SUB_MODE[${#SUB_MODE[@]}]="copy"
            i=$((i + 1))
        done
        return 0
    fi
    if [ "$requested" = "convert" ]; then
        i=0
        while [ "$i" -lt "${#SUB_INDEX[@]}" ]; do
            if is_image_subtitle "${SUB_CODEC[$i]}"; then image="$image ${SUB_INDEX[$i]}"; fi
            i=$((i + 1))
        done
        [ -n "$image" ] && die 4 "Image subtitles cannot be converted to a text format." "Use --preset mkv-hevc to keep them."
        if [ "$PRESET_CONTAINER" = "mkv" ]; then text_mode=subrip; else text_mode=mov_text; fi
        i=0
        while [ "$i" -lt "${#SUB_INDEX[@]}" ]; do
            SUB_SRC[${#SUB_SRC[@]}]="${SUB_INDEX[$i]}"; SUB_MODE[${#SUB_MODE[@]}]="$text_mode"
            i=$((i + 1))
        done
        return 0
    fi
    if [ "$PRESET_CONTAINER" = "mkv" ]; then
        i=0
        while [ "$i" -lt "${#SUB_INDEX[@]}" ]; do
            SUB_SRC[${#SUB_SRC[@]}]="${SUB_INDEX[$i]}"
            if [ "$(lower "${SUB_CODEC[$i]}")" = "mov_text" ]; then SUB_MODE[${#SUB_MODE[@]}]=subrip; else SUB_MODE[${#SUB_MODE[@]}]=copy; fi
            i=$((i + 1))
        done
        return 0
    fi
    i=0
    while [ "$i" -lt "${#SUB_INDEX[@]}" ]; do
        codec=$(lower "${SUB_CODEC[$i]}")
        if is_image_subtitle "$codec"; then
            dropped="$dropped ${SUB_INDEX[$i]}"
        elif is_text_subtitle "$codec"; then
            SUB_SRC[${#SUB_SRC[@]}]="${SUB_INDEX[$i]}"; SUB_MODE[${#SUB_MODE[@]}]=mov_text
        else
            dropped="$dropped ${SUB_INDEX[$i]}"
        fi
        i=$((i + 1))
    done
    if [ -n "$dropped" ]; then
        log_warn "Dropped subtitle stream(s)$dropped that cannot be stored in $PRESET_CONTAINER; use mkv-hevc to keep them."
        SUB_DROPPED=($dropped)
    fi
}

OUT_W=0
OUT_H=0

even_value() {
    local value="$1"
    if [ $((value % 2)) -eq 0 ]; then printf '%s' "$value"; else printf '%s' "$((value + 1))"; fi
}

output_dimensions() {
    local frame_w="$1" frame_h="$2" target="$3" allow_huge="$4" raw_width
    if [ -n "$target" ]; then
        target=$(even_value "$target")
        [ "$target" -lt 2 ] && target=2
        [ "$target" -gt "$frame_h" ] && die 4 "--target-height ($target) exceeds the upscaled height ($frame_h)"
        OUT_H="$target"
        raw_width=$(round_even "$(awk -v w="$frame_w" -v t="$target" -v h="$frame_h" 'BEGIN { printf "%.9f", w * t / h }')")
        [ "$raw_width" -lt 2 ] && raw_width=2
        OUT_W=$(even_value "$raw_width")
    else
        OUT_W="$frame_w"; OUT_H="$frame_h"
    fi
    if [ "$allow_huge" -ne 1 ]; then
        if [ "$OUT_W" -gt 8192 ] || [ "$OUT_H" -gt 8192 ]; then
            die 4 "Output exceeds 8192 px on a side; use --allow-huge only if you really need it"
        fi
        if [ $((OUT_W * OUT_H)) -gt 40000000 ]; then
            die 4 "Output exceeds 40 megapixels; use --allow-huge only if you really need it"
        fi
    fi
}

COLOR_VALUE=""

color_value() {
    local key="$1" media_value="$2" height="$3" value default text allowed
    value=$(job_get "$key" '')
    [ -n "$value" ] || value="$media_value"
    if [ "$height" -ge 720 ]; then default=bt709; else default=smpte170m; fi
    if [ "$key" = "color_range" ]; then
        text=$(lower "$(trim "$value")")
        case "$text" in tv|pc) COLOR_VALUE="$text" ;; *) COLOR_VALUE=tv ;; esac
        return 0
    fi
    text=$(lower "$(trim "$value")")
    case "$key" in
        color_primaries) allowed="bt709 bt470m bt470bg smpte170m smpte240m film bt2020 smpte428 smpte431 smpte432 jedec-p22 ebu3213" ;;
        color_trc) allowed="bt709 gamma22 gamma28 smpte170m smpte240m linear log100 log316 iec61966-2-4 bt1361e iec61966-2-1 bt2020-10 bt2020-12 smpte2084 smpte428 arib-std-b67" ;;
        colorspace) allowed="bt709 fcc bt470bg smpte170m smpte240m ycgco bt2020nc bt2020c smpte2085 chroma-derived-nc chroma-derived-c ictcp" ;;
        *) allowed="" ;;
    esac
    case " $allowed " in
        *" $text "*) COLOR_VALUE="$text" ;;
        *) COLOR_VALUE="$default" ;;
    esac
}

build_filters_and_colors() {
    # Sets FILTER_ARGS and COLOR_ARGS for assemble/segment commands.
    local target="$1" height="$2" color_range filter_list=""
    FILTER_ARGS=(); COLOR_ARGS=()
    color_value color_range "$M_COLOR_RANGE" "$height"
    color_range="$COLOR_VALUE"
    if [ "$color_range" = "pc" ]; then
        filter_list="scale=in_range=pc:out_range=tv"
        color_range=tv
    fi
    if [ -n "$target" ]; then
        filter_list="${filter_list:+$filter_list,}scale=-2:$target:flags=lanczos"
    fi
    [ -n "$filter_list" ] && FILTER_ARGS=(-vf "$filter_list")
    color_value color_primaries "$M_COLOR_PRIMARIES" "$height"; COLOR_ARGS=(-color_primaries "$COLOR_VALUE")
    color_value color_trc "$M_COLOR_TRC" "$height"; COLOR_ARGS=("${COLOR_ARGS[@]}" -color_trc "$COLOR_VALUE")
    color_value colorspace "$M_COLOR_SPACE" "$height"; COLOR_ARGS=("${COLOR_ARGS[@]}" -colorspace "$COLOR_VALUE")
    COLOR_ARGS=("${COLOR_ARGS[@]}" -color_range "$color_range")
}

EN_PRESET="mp4-h264"; EN_ENCODER="auto"; EN_QUALITY="balanced"; EN_CRF=""
EN_AUDIO=""; EN_AUDIO_BITRATE=192; EN_ALL_AUDIO=0; EN_SUBS=""; EN_TENBIT=0
EN_TARGET=""; EN_CLEANUP=0; EN_OUTPUT=""; EN_UPSCALED_DIR=""; EN_PICK="error"
EN_VERIFY=0; EN_ALLOW_HUGE=0; EN_FORCE=0; EN_KEEP_CHUNKS=0

FILTER_ARGS=(); COLOR_ARGS=()

build_assemble_command() {
    local output="$1" frame_w="$2" frame_h="$3"
    local has_source=0 fps pattern i codec duration_value
    quality_resolve "$EN_QUALITY" "$EN_CRF"
    apply_quality "$CHOSEN_FAMILY" "$CHOSEN_CODEC" "$EN_QUALITY"
    video_codec_args "$CHOSEN_FAMILY" "$CHOSEN_CODEC" "$QUALITY_VALUE" "$EN_TENBIT"
    output_dimensions "$frame_w" "$frame_h" "${EN_TARGET:-}" "$EN_ALLOW_HUGE"
    if [ "$AUD_ENABLED" -eq 1 ] || [ "${#SUB_SRC[@]}" -gt 0 ] || [ "$M_CHAPTERS" -gt 0 ]; then has_source=1; fi
    fps=$(job_get fps "$FPS_RATIONAL")
    pattern="frame_%08d.$FS_EXT"
    CMD=(ffmpeg -hide_banner -nostdin -y -benchmark -framerate "$fps" -start_number "${FS_INDICES[0]}" -i "$FS_DIR/$pattern")
    if [ "$has_source" -eq 1 ]; then
        local range_start
        range_start=$(job_get range_start 0)
        if num_cmp "$range_start" gt 0; then CMD=("${CMD[@]}" -ss "$(fcalc "$range_start" '+' 0 '%.6f')"); fi
        CMD=("${CMD[@]}" -i "$(job_source_path)")
    fi
    CMD=("${CMD[@]}" -map 0:v:0)
    if [ "$AUD_ENABLED" -eq 1 ]; then
        i=0
        while [ "$i" -lt "${#AUD_SRC[@]}" ]; do
            CMD=("${CMD[@]}" -map "1:${AUD_SRC[$i]}")
            i=$((i + 1))
        done
        i=0
        while [ "$i" -lt "${#AUD_MODE[@]}" ]; do
            case "${AUD_MODE[$i]}" in
                copy) codec=copy ;;
                aac) codec=aac ;;
                pcm) codec=pcm_s24le ;;
            esac
            CMD=("${CMD[@]}" "-c:a:$i" "$codec")
            [ "${AUD_MODE[$i]}" = "aac" ] && CMD=("${CMD[@]}" "-b:a:$i" "${EN_AUDIO_BITRATE}k")
            i=$((i + 1))
        done
    else
        CMD=("${CMD[@]}" -an)
    fi
    if [ "${#SUB_SRC[@]}" -gt 0 ]; then
        i=0
        while [ "$i" -lt "${#SUB_SRC[@]}" ]; do
            CMD=("${CMD[@]}" -map "1:${SUB_SRC[$i]}")
            i=$((i + 1))
        done
        i=0
        while [ "$i" -lt "${#SUB_MODE[@]}" ]; do
            CMD=("${CMD[@]}" "-c:s:$i" "${SUB_MODE[$i]}")
            i=$((i + 1))
        done
    fi
    [ "$M_CHAPTERS" -gt 0 ] && CMD=("${CMD[@]}" -map_chapters 1)
    CMD=("${CMD[@]}" "${VCA[@]}")
    build_filters_and_colors "$EN_TARGET" "$OUT_H"
    CMD=("${CMD[@]}" "${FILTER_ARGS[@]}" "${COLOR_ARGS[@]}")
    CMD=("${CMD[@]}" -metadata:s:v:0 rotate=0)
    [ "$has_source" -eq 1 ] && CMD=("${CMD[@]}" -map_metadata 1)
    case "$PRESET_CONTAINER" in mp4|mov) CMD=("${CMD[@]}" -movflags +faststart) ;; esac
    if [ "$PRESET_CODEC" = "hevc" ] && { [ "$PRESET_CONTAINER" = "mp4" ] || [ "$PRESET_CONTAINER" = "mov" ]; }; then
        CMD=("${CMD[@]}" -tag:v hvc1)
    fi
    if [ "$AUD_ENABLED" -eq 1 ] || [ "${#SUB_SRC[@]}" -gt 0 ]; then
        duration_value=$(job_get duration 0)
        if num_cmp "$duration_value" le 0; then
            duration_value=$(fcalc "$FS_COUNT" '/' "$( [ -n "$M_FPS_DECIMAL" ] && printf '%s' "$M_FPS_DECIMAL" || printf 30 )" '%.6f')
        fi
        CMD=("${CMD[@]}" -t "$(fcalc "$duration_value" '+' 0 '%.6f')")
    fi
    CMD=("${CMD[@]}" "$output")
}

build_segment_command() {
    local output="$1" frame_w="$2" frame_h="$3"
    quality_resolve "$EN_QUALITY" "$EN_CRF"
    apply_quality "$CHOSEN_FAMILY" "$CHOSEN_CODEC" "$EN_QUALITY"
    video_codec_args "$CHOSEN_FAMILY" "$CHOSEN_CODEC" "$QUALITY_VALUE" "$EN_TENBIT"
    output_dimensions "$frame_w" "$frame_h" "${EN_TARGET:-}" "$EN_ALLOW_HUGE"
    local fps pattern
    fps=$(job_get fps "$FPS_RATIONAL")
    pattern="frame_%08d.$FS_EXT"
    CMD=(ffmpeg -hide_banner -nostdin -y -benchmark -framerate "$fps" -start_number "${FS_INDICES[0]}" -i "$FS_DIR/$pattern" -map 0:v:0 -an -sn -dn -frames:v "$FS_COUNT")
    CMD=("${CMD[@]}" "${VCA[@]}")
    build_filters_and_colors "$EN_TARGET" "$OUT_H"
    CMD=("${CMD[@]}" "${FILTER_ARGS[@]}" "${COLOR_ARGS[@]}" -metadata:s:v:0 rotate=0)
    if [ "$PRESET_CODEC" = "prores" ]; then
        CMD=("${CMD[@]}" -f mov)
    else
        CMD=("${CMD[@]}" -muxdelay 0 -muxpreload 0 -f mpegts)
    fi
    CMD=("${CMD[@]}" "$output")
}

build_mux_command() {
    local concat="$1" output="$2" duration="$3"
    local has_source=0 i codec range_start
    if [ "$AUD_ENABLED" -eq 1 ] || [ "${#SUB_SRC[@]}" -gt 0 ] || [ "$M_CHAPTERS" -gt 0 ]; then has_source=1; fi
    CMD=(ffmpeg -hide_banner -nostdin -y -benchmark -i "$concat")
    if [ "$has_source" -eq 1 ]; then
        range_start=$(job_get range_start 0)
        if num_cmp "$range_start" gt 0; then CMD=("${CMD[@]}" -ss "$(fcalc "$range_start" '+' 0 '%.6f')"); fi
        CMD=("${CMD[@]}" -i "$(job_source_path)")
    fi
    CMD=("${CMD[@]}" -map 0:v:0)
    if [ "$AUD_ENABLED" -eq 1 ]; then
        i=0
        while [ "$i" -lt "${#AUD_SRC[@]}" ]; do CMD=("${CMD[@]}" -map "1:${AUD_SRC[$i]}"); i=$((i + 1)); done
        i=0
        while [ "$i" -lt "${#AUD_MODE[@]}" ]; do
            case "${AUD_MODE[$i]}" in copy) codec=copy ;; aac) codec=aac ;; pcm) codec=pcm_s24le ;; esac
            CMD=("${CMD[@]}" "-c:a:$i" "$codec")
            [ "${AUD_MODE[$i]}" = "aac" ] && CMD=("${CMD[@]}" "-b:a:$i" "${EN_AUDIO_BITRATE}k")
            i=$((i + 1))
        done
    else
        CMD=("${CMD[@]}" -an)
    fi
    if [ "${#SUB_SRC[@]}" -gt 0 ]; then
        i=0
        while [ "$i" -lt "${#SUB_SRC[@]}" ]; do CMD=("${CMD[@]}" -map "1:${SUB_SRC[$i]}"); i=$((i + 1)); done
        i=0
        while [ "$i" -lt "${#SUB_MODE[@]}" ]; do CMD=("${CMD[@]}" "-c:s:$i" "${SUB_MODE[$i]}"); i=$((i + 1)); done
    fi
    [ "$M_CHAPTERS" -gt 0 ] && CMD=("${CMD[@]}" -map_chapters 1)
    CMD=("${CMD[@]}" -c:v copy -t "$(fcalc "$duration" '+' 0 '%.6f')")
    [ "$has_source" -eq 1 ] && CMD=("${CMD[@]}" -map_metadata 1)
    CMD=("${CMD[@]}" -metadata:s:v:0 rotate=0)
    case "$PRESET_CONTAINER" in mp4|mov) CMD=("${CMD[@]}" -movflags +faststart) ;; esac
    if [ "$PRESET_CODEC" = "hevc" ] && { [ "$PRESET_CONTAINER" = "mp4" ] || [ "$PRESET_CONTAINER" = "mov" ]; }; then
        CMD=("${CMD[@]}" -tag:v hvc1)
    fi
    CMD=("${CMD[@]}" "$output")
}

PARTIAL_PATH=""

repair_color_tags() {
    local path="$1" container="$2" temp
    probe_media "$path"
    if [ "$M_COLOR_PRIMARIES" = "bt709" ] && [ "$M_COLOR_TRC" = "bt709" ] && [ "$M_COLOR_SPACE" = "bt709" ] && [ "$M_COLOR_RANGE" = "tv" ]; then
        return 0
    fi
    temp="$(dirname "$path")/$(basename "$path" | sed 's/\.[^.]*$//').colorfix.${path##*.}"
    CMD=("$CFG_FFMPEG" -hide_banner -nostdin -y -i "$path" -map 0:v -map '0:a?' -map '0:s?' -map '0:t?' -c copy -color_primaries bt709 -color_trc bt709 -colorspace bt709 -color_range tv)
    case "$container" in mp4|mov) CMD=("${CMD[@]}" -movflags +faststart) ;; esac
    CMD=("${CMD[@]}" "$temp")
    log_debug "\$ $(display_command "${CMD[@]}")"
    run_child "${CMD[@]}"
    if [ "$LAST_RC" -ne 0 ]; then
        local detail
        detail=$(child_tail 50)
        cleanup_temp_files
        die 7 "Could not normalize color tags for $path" "$detail"
    fi
    cleanup_temp_files
    mv -f "$temp" "$path"
}

validate_output() {
    local output="$1" expected_w="$2" expected_h="$3" expected_audio="$4" expected_subs="$5"
    local problems="" expected_duration tolerance expected_fps has_audio expected_pixfmt probe_output="$output"
    if [ "$HAS_CYGPATH" -eq 1 ]; then probe_output=$(cygpath -m "$output"); fi
    "$CFG_FFPROBE" -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$probe_output" >/dev/null 2>&1 \
        || die 8 "Output is not a readable video: $output"
    probe_media "$output"
    if [ "$M_WIDTH" -ne "$expected_w" ] || [ "$M_HEIGHT" -ne "$expected_h" ]; then
        problems="$problems; dimensions ${M_WIDTH}x${M_HEIGHT}, expected ${expected_w}x${expected_h}"
    fi
    expected_duration=$(job_get duration "$M_DURATION")
    tolerance=$(awk -v fps="$M_FPS_DECIMAL" 'BEGIN { t = 1 / (fps > 1 ? fps : 1); if (t < 0.1) t = 0.1; printf "%.6f", t }')
    if ! awk -v a="$M_DURATION" -v b="$expected_duration" -v t="$tolerance" 'BEGIN { d = a - b; if (d < 0) d = -d; exit (d > t) }'; then
        problems="$problems; duration $(fcalc "$M_DURATION" '+' 0 '%.3f')s, expected $(fcalc "$expected_duration" '+' 0 '%.3f')s"
    fi
    expected_fps=$(job_get fps_decimal "$M_FPS_DECIMAL")
    if ! awk -v a="$M_FPS_DECIMAL" -v b="$expected_fps" 'BEGIN { d = a - b; if (d < 0) d = -d; exit (d > 0.02) }'; then
        problems="$problems; fps $(fcalc "$M_FPS_DECIMAL" '+' 0 '%.3f'), expected $(fcalc "$expected_fps" '+' 0 '%.3f')"
    fi
    if [ "${#AUDIO_INDEX[@]}" -gt 0 ]; then has_audio=1; else has_audio=0; fi
    if [ "$has_audio" -ne "$expected_audio" ]; then
        problems="$problems; audio streams ${#AUDIO_INDEX[@]}, expected $expected_audio"
    fi
    if [ "${#SUB_INDEX[@]}" -ne "$expected_subs" ]; then
        problems="$problems; subtitle streams ${#SUB_INDEX[@]}, expected $expected_subs"
    fi
    if [ "$PRESET_CODEC" = "prores" ]; then
        expected_pixfmt=yuv422p10le
    elif [ "$EN_TENBIT" -eq 1 ]; then
        expected_pixfmt=yuv420p10le
    else
        expected_pixfmt=yuv420p
    fi
    if [ "$M_PIX_FMT" != "$expected_pixfmt" ]; then
        problems="$problems; pixel format $M_PIX_FMT, expected $expected_pixfmt"
    fi
    if [ -n "$problems" ]; then
        die 8 "Output validation failed:${problems#; }"
    fi
}

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
                local target="$audio_dir/track$(printf '%02d' "$n").mka"
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
        count=$(find "$upscaled_dir" -type f -name 'frame_*' 2>/dev/null | wc -l | tr -d ' ')
        if [ "$count" -eq 0 ]; then log_warn "Skipping $(basename "$job"): no upscaled frames"; continue; fi
        profile="${OPT_PROFILE:-default}"
        preset=""; quality=""; encoder=""
        if [ "$profile" = "fast" ]; then preset="mp4-h264"; quality="fast"; encoder="auto"
        elif [ "$profile" = "quality" ]; then preset="mp4-hevc"; quality="quality"; encoder="auto"
        else preset="${OPT_PRESET:-$CFG_DEFAULT_PRESET}"; quality="${OPT_QUALITY:-balanced}"; encoder="${OPT_ENCODER:-$CFG_DEFAULT_ENCODER}"; fi
        [ -n "$OPT_PRESET" ] && preset="$OPT_PRESET"
        [ -n "$OPT_ENCODER" ] && encoder="$OPT_ENCODER"
        [ -n "$OPT_QUALITY" ] && quality="$OPT_QUALITY"
        if [ "${OPT_RESUME:-0}" = "1" ] && [ -f "$JOB_DIR/checkpoint" ]; then
            log_info "Resume: skipping completed job $(basename "$JOB_DIR")"
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

# ---------------------------------------------------------------------------
# Upscayl discovery and batching
# ---------------------------------------------------------------------------

UPSCAYL_BIN_PATH=""
MODELS_DIR_PATH=""
MODEL_NAMES=()

resolve_upscayl_binary() {
    local candidate
    if [ -n "$CFG_UPSCAYL_BIN" ]; then
        [ -d "$CFG_UPSCAYL_BIN" ] && CFG_UPSCAYL_BIN="$CFG_UPSCAYL_BIN/upscayl-bin"
        [ -f "$CFG_UPSCAYL_BIN" ] || die 3 "Upscayl CLI not found: $CFG_UPSCAYL_BIN" "Set upscayl_bin in config.txt or pass --upscayl-bin."
        UPSCAYL_BIN_PATH=$(abspath "$CFG_UPSCAYL_BIN")
        return 0
    fi
    if [ -n "${UPSCAYL_BIN:-}" ] && [ -f "$UPSCAYL_BIN" ]; then
        UPSCAYL_BIN_PATH=$(abspath "$UPSCAYL_BIN")
        return 0
    fi
    candidate=$(find_in_path upscayl-bin || true)
    if [ -n "$candidate" ]; then UPSCAYL_BIN_PATH=$(abspath "$candidate"); return 0; fi
    for candidate in /opt/upscayl/resources/bin/upscayl-bin /opt/Upscayl/resources/bin/upscayl-bin "/Applications/Upscayl.app/Contents/Resources/bin/upscayl-bin"; do
        if [ -f "$candidate" ]; then UPSCAYL_BIN_PATH="$candidate"; return 0; fi
    done
    die 3 "Upscayl CLI not found." "Install Upscayl or set upscayl_bin in config.txt / --upscayl-bin."
}

resolve_models_directory() {
    local candidate
    if [ -n "$CFG_MODELS_DIR" ] && [ -d "$CFG_MODELS_DIR" ]; then MODELS_DIR_PATH=$(abspath "$CFG_MODELS_DIR"); return 0; fi
    if [ -n "${UPSCAYL_MODELS:-}" ] && [ -d "$UPSCAYL_MODELS" ]; then MODELS_DIR_PATH=$(abspath "$UPSCAYL_MODELS"); return 0; fi
    candidate="$(dirname "$(dirname "$UPSCAYL_BIN_PATH")")/models"
    if [ -d "$candidate" ]; then MODELS_DIR_PATH=$(abspath "$candidate"); return 0; fi
    for candidate in /opt/upscayl/resources/models /opt/Upscayl/resources/models "/Applications/Upscayl.app/Contents/Resources/models"; do
        if [ -d "$candidate" ]; then MODELS_DIR_PATH="$candidate"; return 0; fi
    done
    die 3 "Upscayl models directory not found." "Set models_dir in config.txt or pass --models-dir."
}

list_models() {
    MODEL_NAMES=()
    [ -d "$MODELS_DIR_PATH" ] || die 3 "Upscayl models directory not found: $MODELS_DIR_PATH"
    local params name
    params=$(find "$MODELS_DIR_PATH" -maxdepth 1 -type f -name '*.param' 2>/dev/null | sort)
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        local base
        base="${name%.param}"
        if [ -f "$base.bin" ]; then
            MODEL_NAMES[${#MODEL_NAMES[@]}]="$(basename "$base")"
        fi
    done <<EOF
$params
EOF
    [ "${#MODEL_NAMES[@]}" -gt 0 ] || die 3 "No complete Upscayl models found in: $MODELS_DIR_PATH" "Each model needs matching .param and .bin files."
}

resolve_upscayl_paths() {
    resolve_upscayl_binary
    resolve_models_directory
    [ "$(basename "$MODELS_DIR_PATH")" = "models" ] || die 3 "Upscayl model directory must be named 'models': $MODELS_DIR_PATH" "Rename the folder or create a folder named models containing matching .param/.bin files."
    list_models
}

model_exists() {
    local wanted="$1" name
    for name in "${MODEL_NAMES[@]}"; do [ "$name" = "$wanted" ] && return 0; done
    return 1
}

resolve_icd() {
    local value="$1"
    [ -n "$value" ] || value="$CFG_ICD"
    [ -n "$value" ] || value=auto
    case "$(lower "$value")" in
        none|auto) ICD_PATH="" ;;
        *)
            ICD_PATH=$(abspath "$value")
            [ -f "$ICD_PATH" ] || die 4 "Vulkan ICD JSON not found: $ICD_PATH"
            ;;
    esac
}

ICD_PATH=""

detect_vram_mb() {
    local value
    if command -v nvidia-smi >/dev/null 2>&1; then
        value=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -n 1 | tr -d ' ')
        case "$value" in ''|*[!0-9]*) ;; *) printf '%s' "$value"; return 0 ;; esac
    fi
    printf ''
}

TILE_VALUE=0

resolve_tile() {
    local requested="$1" vram="${2:-}"
    requested=$(lower "$1")
    if [ "$requested" = "auto" ]; then
        if [ -z "$vram" ]; then TILE_VALUE=256
        elif [ "$vram" -le 4096 ]; then TILE_VALUE=128
        elif [ "$vram" -le 8192 ]; then TILE_VALUE=256
        else TILE_VALUE=512; fi
        return 0
    fi
    case "$requested" in *[!0-9]*) die 4 "Invalid tile size: $requested" ;; esac
    [ "$requested" -ge 32 ] || die 4 "Tile size must be at least 32"
    TILE_VALUE="$requested"
}

resolve_batch_size() {
    local requested="$1" width="$2" height="$3"
    if [ "$requested" -gt 0 ]; then printf '%s' "$requested"; return 0; fi
    if [ $((width * height)) -gt 8000000 ]; then printf 50; else printf 100; fi
}

MISSING=()

missing_indices() {
    local source_dir="$1" output_dir="$2" total="$3" src_map out_map result
    MISSING=()
    src_map=$(new_temp_file); out_map=$(new_temp_file)
    scan_frames "$source_dir" 0 > "$src_map"
    scan_frames "$output_dir" 0 > "$out_map"
    result=$(awk -F'\t' -v total="$total" '
        FNR==NR { src[$1] = 1; next }
        { out[$1] = 1 }
        END { for (i = 1; i <= total; i++) if (src[i] && !out[i]) print i }
    ' "$src_map" "$out_map")
    rm -f "$src_map" "$out_map"
    local idx
    while IFS= read -r idx; do
        [ -n "$idx" ] && MISSING[${#MISSING[@]}]="$idx"
    done <<EOF
$result
EOF
}

UPSCALED_COUNT=0

upscale_frames() {
    local model="$1" scale="$2" output_dir="$3" tile="$4" batch_size="$5" gpu="$6" icd="$7" threads="$8" retry="$9" source_dir="${10:-}" total="${11:-}" progress_total="${12:-}" progress_done="${13:-0}" assume_yes="${14:-1}"
    [ -n "$source_dir" ] || source_dir="$JOB_DIR/frames"
    [ -n "$total" ] || total=$(job_get frame_count 0)
    [ "$total" -gt 0 ] || die 4 "Job has no frame_count: $(basename "$JOB_DIR")"
    [ "$batch_size" -gt 0 ] || batch_size=1
    [ "$tile" -ge 32 ] || tile=32
    mkdir -p "$output_dir" || die 1 "Could not create $output_dir"

    local attempt=0 batch_number=1 eta_warned=0 batch work incoming outgoing rc idx source_file base stem result srcmap outmap
    local progress_start
    progress_start=$(date +%s)
    srcmap=$(new_temp_file)
    scan_frames "$source_dir" 0 > "$srcmap"
    SRC_MAP_I=(); SRC_MAP_P=()
    while IFS=$'\t' read -r src_idx src_path; do
        [ -n "$src_idx" ] || continue
        SRC_MAP_I[${#SRC_MAP_I[@]}]="$src_idx"
        SRC_MAP_P[${#SRC_MAP_P[@]}]="$src_path"
    done < "$srcmap"
    while :; do
        missing_indices "$source_dir" "$output_dir" "$total"
        [ "${#MISSING[@]}" -eq 0 ] && break
        batch=("${MISSING[@]:0:batch_size}")
        work="$JOB_DIR/$(printf 'batch_%04d' "$batch_number")"
        rm -rf "$work"
        incoming="$work/in"; outgoing="$work/out"
        mkdir -p "$incoming" "$outgoing" || die 1 "Could not create $work"
        for idx in "${batch[@]}"; do
            source_file=""
            local si=0
            while [ "$si" -lt "${#SRC_MAP_I[@]}" ]; do
                if [ "${SRC_MAP_I[$si]}" = "$idx" ]; then source_file="${SRC_MAP_P[$si]}"; break; fi
                si=$((si + 1))
            done
            [ -n "$source_file" ] || die 4 "Missing source frame $(printf '%08d' "$idx") for job $(basename "$JOB_DIR")"
            base=${source_file##*/}
            ln "$source_file" "$incoming/$base" 2>/dev/null || cp -p "$source_file" "$incoming/$base" || die 1 "Could not stage $source_file"
        done
        CMD=("$UPSCAYL_BIN_PATH" -i "$incoming" -o "$outgoing" -m "$MODELS_DIR_PATH" -n "$model" -s "$scale" -g "$gpu" -t "$tile" -j "$threads" -f png -c 0)
        CHILD_CWD=$(dirname "$UPSCAYL_BIN_PATH"); CHILD_ICD="$icd"
        log_debug "\$ $(display_command "${CMD[@]}")"
        run_child "${CMD[@]}"
        rc=$?
        CHILD_CWD=""; CHILD_ICD=""
        if [ "$rc" -ne 0 ]; then
            if [ "$attempt" -lt "$retry" ]; then
                attempt=$((attempt + 1))
                tile=$((tile / 2)); [ "$tile" -lt 64 ] && tile=64
                batch_size=$((batch_size / 2)); [ "$batch_size" -lt 1 ] && batch_size=1
                log_warn "Upscayl batch failed; retrying with tile=$tile, batch=$batch_size"
                rm -rf "$work"
                cleanup_temp_files
                continue
            fi
            local detail
            detail=$(child_tail 50)
            rm -rf "$work"
            cleanup_temp_files
            job_set last_error "Upscayl failed for job $(basename "$JOB_DIR")"
            job_save || true
            die 6 "Upscayl failed for job $(basename "$JOB_DIR")" "${detail:0:500}"
        fi
        OUT_MAP_S=(); OUT_MAP_P=()
        for result in "$outgoing"/*; do
            [ -f "$result" ] && [ -s "$result" ] || continue
            base=${result##*/}
            OUT_MAP_S[${#OUT_MAP_S[@]}]="${base%.*}"
            OUT_MAP_P[${#OUT_MAP_P[@]}]="$result"
        done
        for source_file in "$incoming"/*; do
            [ -f "$source_file" ] || continue
            base=${source_file##*/}
            stem="${base%.*}"
            result=""
            local oj=0
            while [ "$oj" -lt "${#OUT_MAP_S[@]}" ]; do
                if [ "${OUT_MAP_S[$oj]}" = "$stem" ]; then result="${OUT_MAP_P[$oj]}"; break; fi
                oj=$((oj + 1))
            done
            if [ -z "$result" ]; then
                rm -rf "$work"
                cleanup_temp_files
                job_set last_error "Upscayl produced no output for $base"
                job_save || true
                die 6 "Upscayl produced no output for $base"
            fi
            mv -f "$result" "$output_dir/$(basename "$result")" || die 1 "Could not move $result"
        done
        rm -rf "$work"
        cleanup_temp_files
        batch_number=$((batch_number + 1))
        attempt=0
        local done_count elapsed rate eta percent
        # Progress is measured by the number of upscaled frames on disk.
        local_done=$(find "$output_dir" -maxdepth 1 -type f -name 'frame_*' 2>/dev/null | wc -l | tr -d ' ')
        done_count=$((progress_done + local_done))
        if [ -n "$progress_total" ]; then display_total="$progress_total"; else display_total="$total"; fi
        elapsed=$(( $(date +%s) - progress_start ))
        [ "$elapsed" -gt 0 ] || elapsed=1
        rate=$(awk -v d="$done_count" -v e="$elapsed" 'BEGIN { printf "%.2f", d / e }')
        eta=$(awk -v d="$done_count" -v t="$display_total" -v e="$elapsed" 'BEGIN { r = d / e; if (r <= 0) print 0; else printf "%.0f", (t - d) / r }')
        percent=$(awk -v d="$done_count" -v t="$display_total" 'BEGIN { printf "%.1f", (t > 0) ? d / t * 100 : 100 }')
        log_info "upscale: $done_count/$display_total (${percent}%) ${rate}/s ETA $(format_duration "$eta" | cut -d. -f1)"
        if [ "$eta_warned" -eq 0 ] && [ "$eta" -gt 3600 ]; then
            eta_warned=1
            local eta_hours
            eta_hours=$(awk -v e="$eta" 'BEGIN { printf "%.1f", e / 3600 }')
            if [ "$eta" -gt 43200 ]; then
                log_warn "Estimated upscale time exceeds 12 hours; use a faster model (upscayl-lite-4x) or process the video in chunks."
            else
                log_warn "Estimated upscale time is ${eta_hours} hours."
            fi
            if [ "$assume_yes" -ne 1 ]; then
                if [ -t 0 ]; then
                    local answer
                    printf 'Continue? [y/N] ' >&2
                    IFS= read -r answer || answer=""
                    answer=$(lower "$(trim "$answer")")
                    case "$answer" in y|yes) ;; *) die 4 "Aborted by user." ;; esac
                else
                    die 4 "Estimated upscale time is ${eta_hours} hours." "Re-run with --yes to continue."
                fi
            fi
        fi
    done
    local count_map
    count_map=$(new_temp_file)
    scan_frames "$output_dir" 0 > "$count_map"
    UPSCALED_COUNT=$(awk -F'\t' '{ seen[$1] = 1 } END { print length(seen) }' "$count_map")
    rm -f "$count_map"
}

US_MODEL=""; US_SCALE=2; US_GPU=0; US_TILE="auto"; US_BATCH=0; US_THREADS="1:2:2"; US_ASSUME_YES=1
US_ICD=""; US_BIN=""; US_MODELS=""; US_UPSCALED_DIR=""; US_RETRY=1; US_FORCE=0

run_upscale() {
    local dry_run="$1"; shift
    local jobs
    jobs=("$@")
    local job_path
    # Apply CLI overrides to the effective config.
    if [ -n "$US_BIN" ]; then CFG_UPSCAYL_BIN=$(abspath "$US_BIN"); fi
    if [ -n "$US_MODELS" ]; then CFG_MODELS_DIR=$(abspath "$US_MODELS"); fi
    resolve_upscayl_paths
    model_exists "$US_MODEL" || die 4 "Upscayl model not found: $US_MODEL" "Installed: $(printf '%s, ' "${MODEL_NAMES[@]}" | sed 's/, $//')"
    local vram
    vram=$(detect_vram_mb || true)
    resolve_tile "$US_TILE" "$vram"
    local tile="$TILE_VALUE"
    resolve_icd "$US_ICD"
    local icd="$ICD_PATH"

    for job_path in "${jobs[@]}"; do
        job_load "$job_path"
        job_has_chunks && die 4 "Job is chunked: $(basename "$JOB_DIR")" "Resume it with the run command."
        [ -d "$JOB_DIR/frames" ] || die 4 "No frames found for job: $(basename "$JOB_DIR")" "Run split first."
        local frame_count output_dir existing=0 model_changed=0 scale_changed=0
        frame_count=$(job_get frame_count 0)
        if [ "$frame_count" -le 0 ]; then
            frame_count=$(count_contiguous_frames "$JOB_DIR/frames" "$(job_get frame_format png)")
        fi
        [ "$frame_count" -gt 0 ] || die 4 "Job has no frames: $(basename "$JOB_DIR")"
        if [ -n "$US_UPSCALED_DIR" ]; then output_dir=$(abspath "$US_UPSCALED_DIR"); else output_dir="$JOB_DIR/upscaled"; fi
        if [ -d "$output_dir" ]; then
            existing=$(find "$output_dir" -maxdepth 1 -type f 2>/dev/null | head -n 1)
        fi
        [ -n "$(job_get model '')" ] && [ "$(job_get model '')" != "$US_MODEL" ] && model_changed=1
        [ "$(job_get scale 0)" -gt 0 ] && [ "$(job_get scale 0)" -ne "$US_SCALE" ] && scale_changed=1
        if [ -n "$existing" ] && { [ "$model_changed" -eq 1 ] || [ "$scale_changed" -eq 1 ]; } && [ "$US_FORCE" -ne 1 ]; then
            die 4 "Existing upscaled frames use a different model or scale." "Use --force to clear them and upscale again."
        fi
        if [ -n "$existing" ] && [ "$US_FORCE" -eq 1 ] && { [ "$model_changed" -eq 1 ] || [ "$scale_changed" -eq 1 ]; }; then
            rm -rf "$output_dir"
            job_clear_stage upscale
            job_set upscaled_count 0
        fi
        local width height batch_size
        width=$(job_get width 1920); height=$(job_get height 1080)
        batch_size=$(resolve_batch_size "$US_BATCH" "$width" "$height")
        if [ "$dry_run" -eq 1 ]; then
            log_info "Would upscale $(basename "$JOB_DIR"): $frame_count frames with $US_MODEL at ${US_SCALE}x, tile $tile, batch $batch_size"
            continue
        fi
        upscale_frames "$US_MODEL" "$US_SCALE" "$output_dir" "$tile" "$batch_size" "$US_GPU" "$icd" "$US_THREADS" "$US_RETRY" "" "" "" "0" "$US_ASSUME_YES"
        job_set model "$US_MODEL"
        job_set scale "$US_SCALE"
        job_set tile "$tile"
        job_set batch_size "$batch_size"
        job_set upscaled_count "$UPSCALED_COUNT"
        job_set upscaled_dir "$output_dir"
        job_set last_error ""
        job_save
        job_mark upscale
    done
}

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
            err_text=$(cat "$err_file" 2>/dev/null | head -n 1)
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
        if job_is_done assemble && [ -n "$outputs" ]; then stage=done
        elif [ -n "$last_error" ]; then stage=failed
        elif job_has_chunks; then stage=chunk
        elif [ "$upscaled" -gt 0 ]; then stage=assemble
        elif [ "$frames" -gt 0 ]; then stage=upscale
        elif job_is_done split; then stage=split
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

# ---------------------------------------------------------------------------
# Doctor
# ---------------------------------------------------------------------------

DOCTOR_RESULTS=()

doctor_add() {
    DOCTOR_RESULTS[${#DOCTOR_RESULTS[@]}]="$1|$2|$3"
}

doctor_ffmpeg() {
    local name path marker output first
    for name in ffmpeg ffprobe; do
        if [ "$name" = "ffmpeg" ]; then path="$CFG_FFMPEG"; marker="ffmpeg version"; else path="$CFG_FFPROBE"; marker="ffprobe version"; fi
        if output=$( ( "$path" -version ) 2>&1 ); then
            first=$(printf '%s\n' "$output" | sed -n '1p')
            case "$(lower "$first")" in
                *"$marker"*) doctor_add OK "$name" "${first:0:160}" ;;
                *) doctor_add FAIL "$name" "${first:0:160}" ;;
            esac
        else
            first=$(printf '%s\n' "$output" | sed -n '1p')
            doctor_add FAIL "$name" "${first:0:160}"
        fi
    done
    if output=$( ( "$CFG_FFMPEG" -hide_banner -filters ) 2>&1 ); then
        case "$output" in
            *zscale*) doctor_add OK zscale "available for --tonemap" ;;
            *) doctor_add WARN zscale "missing; --tonemap is unavailable" ;;
        esac
    else
        doctor_add WARN zscale "could not inspect filters"
    fi
    doctor_add INFO glob "not required by this pipeline"
}

doctor_encoders() {
    load_encoders
    local name purpose
    for name in libx264 libx265 prores_ks h264_nvenc hevc_nvenc h264_amf hevc_amf; do
        case "$name" in
            libx264) purpose="required H.264 fallback"; status=FAIL ;;
            libx265) purpose="required for HEVC presets"; status=WARN ;;
            prores_ks) purpose="required for mov-prores"; status=WARN ;;
            h264_nvenc) purpose="NVIDIA H.264"; status=WARN ;;
            hevc_nvenc) purpose="NVIDIA HEVC"; status=WARN ;;
            h264_amf) purpose="AMD H.264"; status=WARN ;;
            hevc_amf) purpose="AMD HEVC"; status=WARN ;;
        esac
        if encoder_available "$name"; then
            doctor_add OK "$name" "$purpose"
        else
            if [ "$status" = "FAIL" ]; then doctor_add FAIL "$name" "missing: $purpose"; else doctor_add WARN "$name" "missing: $purpose"; fi
        fi
    done
    cleanup_temp_files
}

doctor_encoder_smoke() {
    local name output
    for name in libx264 libx265 prores_ks h264_nvenc hevc_nvenc h264_amf hevc_amf; do
        encoder_available "$name" || continue
        if output=$( ( "$CFG_FFMPEG" -hide_banner -loglevel error -y -f lavfi -i color=c=gray:s=256x256 -frames:v 1 -c:v "$name" -f null - ) 2>&1 ); then
            doctor_add OK "smoke_$name" "1-frame encode"
        else
            doctor_add FAIL "smoke_$name" "$(printf '%s\n' "$output" | sed -n '1p' | cut -c1-160)"
        fi
    done
    cleanup_temp_files
}

doctor_work_dir() {
    local path probe free
    path="${DOCTOR_WORK_DIR:-$CFG_WORK_DIR}"
    if ! mkdir -p "$path" 2>/dev/null; then doctor_add FAIL work_dir "not writable: $path"; return 0; fi
    probe="$path/.doctor-$$.tmp"
    if ! printf 'ok' > "$probe" 2>/dev/null; then doctor_add FAIL work_dir "not writable: $path"; return 0; fi
    rm -f "$probe"
    free=$(free_bytes "$path")
    if [ "$free" -lt $((CFG_MIN_FREE_GB * 1073741824)) ]; then
        doctor_add FAIL work_dir "$(format_bytes "$free") free, need $CFG_MIN_FREE_GB GiB"
    else
        doctor_add OK work_dir "$(format_bytes "$free") free"
    fi
}

SMOKE_OK=0
SMOKE_DETAIL=""

invoke_upscayl_smoke() {
    local bin="$1" models="$2" model="$3" tile="$4" icd="$5"
    local temp_dir source target output
    SMOKE_OK=0; SMOKE_DETAIL=""
    temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/upscayl-smoke.XXXXXX") || { SMOKE_DETAIL="temporary directory failed"; return 0; }
    source="$temp_dir/in"; target="$temp_dir/out"
    mkdir -p "$source" "$target"
    if ! run_child "$CFG_FFMPEG" -hide_banner -loglevel error -y -f lavfi -i color=c=gray:s=64x64 -frames:v 1 "$source/test.png"; then
        SMOKE_DETAIL="test PNG failed"
        cleanup_temp_files; rm -rf "$temp_dir"
        return 0
    fi
    cleanup_temp_files
    CMD=("$bin" -i "$source" -o "$target" -m "$models" -n "$model" -s 2 -g 0 -t "$tile" -f png -c 0)
    CHILD_CWD=$(dirname "$bin"); CHILD_ICD="$icd"
    run_child "${CMD[@]}"
    local rc=$?
    CHILD_CWD=""; CHILD_ICD=""
    if [ "$rc" -ne 0 ]; then
        SMOKE_DETAIL=$(child_tail 3 | tr '\n' ' ' | cut -c1-500)
        cleanup_temp_files; rm -rf "$temp_dir"
        return 0
    fi
    output="$target/test.png"
    if [ ! -s "$output" ]; then
        SMOKE_DETAIL="Upscayl produced no output file"
    else
        SMOKE_OK=1
        SMOKE_DETAIL="OK"
    fi
    cleanup_temp_files
    rm -rf "$temp_dir"
}

doctor_upscayl() {
    local skip="$1" discovery rc bin models_line models_dir model_line model_list model icd
    discovery=$( ( resolve_upscayl_paths; printf '%s\n' "$UPSCAYL_BIN_PATH"; printf '%s\n' "$MODELS_DIR_PATH"; printf '%s\n' "${MODEL_NAMES[@]}" ) 2>/dev/null )
    rc=$?
    if [ "$rc" -ne 0 ]; then
        doctor_add WARN upscayl "Upscayl CLI or models not found"
        return 0
    fi
    bin=$(printf '%s\n' "$discovery" | sed -n '1p')
    models_dir=$(printf '%s\n' "$discovery" | sed -n '2p')
    model_list=$(printf '%s\n' "$discovery" | sed -n '3,$p')
    doctor_add OK upscayl "$bin"
    doctor_add OK upscayl_models "$models_dir"
    local count
    count=$(printf '%s\n' "$model_list" | sed '/^$/d' | wc -l | tr -d ' ')
    doctor_add OK upscayl_models "$count model(s)"
    if [ "$skip" -eq 1 ]; then doctor_add OK upscayl_smoke "skipped"; return 0; fi
    resolve_icd ""
    icd="$ICD_PATH"
    model=$(printf '%s\n' "$model_list" | sed -n '1p')
    invoke_upscayl_smoke "$bin" "$models_dir" "$model" 128 "$icd"
    if [ "$SMOKE_OK" -ne 1 ] && [ -z "$icd" ]; then
        doctor_add FAIL upscayl_smoke "$SMOKE_DETAIL"
        return 0
    fi
    if [ "$SMOKE_OK" -eq 1 ]; then doctor_add OK upscayl_smoke "$SMOKE_DETAIL"; else doctor_add FAIL upscayl_smoke "$SMOKE_DETAIL"; fi
}

run_doctor() {
    local work_dir="$1" skip_smoke="$2" verbose="$3"
    DOCTOR_RESULTS=()
    doctor_ffmpeg
    doctor_encoders
    doctor_encoder_smoke
    doctor_work_dir
    doctor_upscayl "$skip_smoke"
    if [ "$verbose" -eq 1 ]; then
        log_info "config: $CFG_CONFIG_PATH"
        log_info "ffmpeg: $CFG_FFMPEG"
        log_info "ffprobe: $CFG_FFPROBE"
    fi
    log_info "$(printf '%-6s %-16s %s' STATUS NAME DETAIL)"
    local entry status name detail
    for entry in "${DOCTOR_RESULTS[@]}"; do
        status="${entry%%|*}"; entry="${entry#*|}"; name="${entry%%|*}"; detail="${entry#*|}"
        log_info "$(printf '%-6s %-16s %s' "$status" "$name" "$detail")"
    done
    local disk_failed=0 upscayl_failed=0 required_failed=0
    for entry in "${DOCTOR_RESULTS[@]}"; do
        status="${entry%%|*}"; entry="${entry#*|}"; name="${entry%%|*}"
        [ "$name" = "work_dir" ] && [ "$status" = "FAIL" ] && disk_failed=1
        case "$name" in upscayl*) [ "$status" = "FAIL" ] && upscayl_failed=1 ;; esac
        if [ "$status" = "FAIL" ]; then
            case "$name" in ffmpeg|ffprobe|libx264|smoke_*) required_failed=1 ;; esac
        fi
    done
    [ "$disk_failed" -eq 1 ] && return 5
    [ "$required_failed" -eq 1 ] && return 3
    [ "$upscayl_failed" -eq 1 ] && return 6
    return 0
}

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
    discovery=$( (resolve_upscayl_paths; printf '%s\n' "$UPSCAYL_BIN_PATH"; printf '%s\n' "$MODELS_DIR_PATH") 2>/dev/null )
    if [ $? -eq 0 ]; then
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
    printf '  doctor    Check FFmpeg, encoders, Upscayl, and the work directory\n'
    printf '  split     Extract frames from videos\n'
    printf '  upscale   Upscale frames with the Upscayl CLI\n'
    printf '  assemble  Reassemble upscaled frames into a video\n'
    printf '  run       Split, upscale, and assemble in one pass\n'
    printf '  status    Show jobs and their progress\n'
    printf '  clean     Delete selected intermediate directories\n\n'
    printf 'global options:\n'
    printf '  --work-dir DIR  --config FILE  --ffmpeg PATH  --ffprobe PATH\n'
    printf '  --verbose  --quiet  --yes  --force  --dry-run  --version  --help\n'
}

reset_options() {
    OPT_WORK_DIR=""; OPT_OUTPUT_DIR=""; OPT_INPUT_DIR=""; OPT_CONFIG=""; OPT_FFMPEG=""; OPT_PROBEFILE=""; OPT_PROFILE="default"; OPT_KEEP=0; OPT_NO_TONEMAP=0; OPT_JOB=""; OPT_RESUME=0
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
        *) die 2 "invalid choice: '$command'" "choose from: doctor, split, split-all, upscale, assemble, finish, run, status, clean" ;;
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
            if [ -n "$OPT_JOB" ]; then
                local candidate finish_jobs=""
                for candidate in $(find_jobs "$CFG_WORK_DIR"); do
                    if [ "$(basename "$candidate")" = "$OPT_JOB" ]; then
                        finish_jobs="$finish_jobs $candidate"
                    fi
                done
                [ -n "$finish_jobs" ] || die 4 "Job not found: $OPT_JOB" "Run 'status' to list available jobs."
                if finish_all $finish_jobs; then exit 0; else exit 1; fi
            elif [ "$ALL_JOBS" -eq 1 ]; then
                if finish_all $(find_jobs "$CFG_WORK_DIR"); then exit 0; else exit 1; fi
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

if [ "${UPSCAYL_V2_LIB:-0}" != "1" ]; then
    main "$@"
fi
