# Upscayl Video Pipeline V2 - core module.
# Errors, logging and process invocation.
# Sourced by upscayl-video.sh; not meant to be run directly.
# shellcheck shell=bash

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
        local message
        message="Command failed with exit code $rc: $(display_command "$@")"
        [ -n "$detail" ] && message="$message
$detail"
        die 1 "$message"
    fi
}
