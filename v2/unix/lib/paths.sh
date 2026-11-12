# Upscayl Video Pipeline V2 - paths module.
# Text, path, key/value and formatting helpers.
# Sourced by upscayl-video.sh; not meant to be run directly.
# shellcheck shell=bash

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
    # shellcheck disable=SC2086  # the caller passes a whitespace separated list
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
    # shellcheck disable=SC2086  # the caller passes a whitespace separated list
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
