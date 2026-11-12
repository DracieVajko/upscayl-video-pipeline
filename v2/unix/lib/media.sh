# Upscayl Video Pipeline V2 - media module.
# Media probing (ffprobe) helpers.
# Sourced by upscayl-video.sh; not meant to be run directly.
# shellcheck shell=bash

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
