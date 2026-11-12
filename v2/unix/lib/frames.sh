# Upscayl Video Pipeline V2 - frames module.
# Frame set handling and disk estimates.
# Sourced by upscayl-video.sh; not meant to be run directly.
# shellcheck shell=bash

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
