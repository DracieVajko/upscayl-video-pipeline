# Upscayl Video Pipeline V2 - encode module.
# Presets, encoder selection, audio and subtitle plans, encode commands.
# Sourced by upscayl-video.sh; not meant to be run directly.
# shellcheck shell=bash

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
        # shellcheck disable=SC2206  # the dropped indices are a whitespace separated list
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
    if [ "${#EN_FFMPEG_ARGS[@]}" -gt 0 ]; then
        CMD=("${CMD[@]}" "${EN_FFMPEG_ARGS[@]}")
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
