#!/usr/bin/env bash
# Plain bash test harness for the V2 Unix implementation.
# No Pester, bats, Python, Node, or jq dependency.

set -u

cd "$(dirname "$0")/../.." || exit 1
export UPSCAYL_V2_LIB=1
# shellcheck source=../unix/upscayl-video.sh
source v2/unix/upscayl-video.sh

PASS=0
FAIL=0
FAILURES=()

assert_eq() {
    local expected="$1" actual="$2" name="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILURES[${#FAILURES[@]}]="$name: expected [$expected], got [$actual]"
    fi
}

assert_true() {
    local condition="$1" name="$2"
    if [ "$condition" -eq 0 ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILURES[${#FAILURES[@]}]="$name: condition was false"
    fi
}

assert_code() {
    local expected="$1" actual="$2" name="$3"
    if [ "$expected" -eq "$actual" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILURES[${#FAILURES[@]}]="$name: expected exit $expected, got $actual"
    fi
}

TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/uvp-test.XXXXXX") || exit 1
trap 'rm -rf "$TEMP_ROOT"' EXIT

# --- string, time, and format helpers ---
assert_eq "a b" "$(trim "  a b  ")" "trim"
assert_eq "video" "$(sanitize_job_id "   ")" "sanitize empty"
assert_eq "a_b" "$(sanitize_job_id "a__b")" "sanitize repeated underscore"
assert_eq "CON_" "$(sanitize_job_id "CON")" "sanitize reserved"
assert_eq "Ã…Â¾luÃ…Â¥ouÃ„ÂkÃƒÂ½" "$(sanitize_job_id "Ã…Â¾luÃ…Â¥ouÃ„ÂkÃƒÂ½")" "sanitize unicode"
assert_eq "00:00:07.532" "$(format_duration 7.532)" "format duration"
assert_eq "1.0 KiB" "$(format_bytes 1024)" "format bytes KiB"
assert_eq "1.5 MiB" "$(format_bytes 1572864)" "format bytes MiB"
assert_eq "3661.500000" "$(parse_time_value "1:01:01.5")" "parse time hh:mm:ss"
( parse_time_value "1:99" ) >/dev/null 2>&1
assert_code 4 $? "parse time rejects 1:99"

normalize_fps "30000/1001" "60/1"
assert_eq "30000/1001" "$FPS_RATIONAL" "fps rational"
assert_eq "29.970" "$FPS_TEXT" "fps decimal"
normalize_fps "0/0" "25/1"
assert_eq "25/1" "$FPS_RATIONAL" "fps fallback"
normalize_fps "0/0" "0/0"
assert_eq "30/1" "$FPS_RATIONAL" "fps default"
fps_override "29.97"
assert_eq "2997/100" "$FPS_RATIONAL" "fps override decimal"
( fps_override "abc" ) >/dev/null 2>&1
assert_code 4 $? "fps override rejects text"

# --- key/value contract ---
KVFILE="$TEMP_ROOT/job.txt"
printf 'version=1\nsource=C:\\a b\\c=d.mov\n# comment\n\nempty=\n' > "$KVFILE"
kv_load "$KVFILE"
assert_eq "1" "$(kv_get version '')" "kv version"
assert_eq "C:\\a b\\c=d.mov" "$(kv_get source '')" "kv value with spaces and equals"
assert_eq "" "$(kv_get empty 'missing')" "kv empty value"
kv_set later x
kv_write "$KVFILE"
kv_load "$KVFILE"
assert_eq "x" "$(kv_get later '')" "kv write roundtrip"
assert_eq "C:\\a b\\c=d.mov" "$(kv_get source '')" "kv preserve value"

# --- jobs ---
WORK="$TEMP_ROOT/work"
SOURCE="$TEMP_ROOT/source.mp4"
printf 'video' > "$SOURCE"
find_or_create_job "$WORK" "$SOURCE" 1
assert_eq "$WORK/source" "$JOB_DIR" "job folder name"
job_set version 1
job_set source "$SOURCE"
job_set frame_count 5
job_save
job_load "$JOB_DIR"
assert_eq "5" "$(job_get frame_count 0)" "job save/load"
assert_eq "$SOURCE" "$(job_source_path)" "job source path"
job_mark split
assert_true "$(job_is_done split; echo $?)" "job marker"
job_clear_stage split
assert_eq "1" "$(job_is_done split; echo $?)" "job marker cleared"

# --- frames ---
FRAMES="$TEMP_ROOT/frames"
mkdir -p "$FRAMES"
i=1
while [ "$i" -le 5 ]; do
    file="$FRAMES/frame_$(printf '%08d' "$i").png"
    printf '\211PNG\r\n\032\n%s' "$i" > "$file"
    i=$((i + 1))
done
validate_frame_set "$FRAMES" 5 error 1
assert_eq "5" "$FS_COUNT" "frame count"
assert_eq "png" "$FS_EXT" "frame extension"
cp "$FRAMES/frame_00000001.png" "$FRAMES/frame_00000001_upscayl_4x.png"
( validate_frame_set "$FRAMES" 5 error 0 ) >/dev/null 2>&1
assert_code 4 $? "duplicate frame rejected"
validate_frame_set "$FRAMES" 5 newest 0
assert_eq "5" "$FS_COUNT" "duplicate resolved by pick"

# --- chunks, dimensions, colors ---
plan_chunks 12 30 10
assert_eq "2" "${#CH_INDEX[@]}" "chunk count"
assert_eq "300" "${CH_FRAMES[0]}" "chunk 1 frames"
assert_eq "60" "${CH_FRAMES[1]}" "chunk 2 frames"
assert_eq "301" "${CH_START_FRAME[1]}" "chunk 2 start frame"
( plan_chunks 12 30 5 ) >/dev/null 2>&1
assert_code 4 $? "chunk rejects below 10"

output_dimensions 640 480 240 0
assert_eq "320x240" "${OUT_W}x${OUT_H}" "dimensions target"
( output_dimensions 640 480 720 0 ) >/dev/null 2>&1
assert_code 4 $? "dimensions rejects target above frame"

job_set color_primaries ""
job_set color_trc ""
job_set colorspace ""
job_set color_range ""
color_value colorspace gbr 240
assert_eq "smpte170m" "$COLOR_VALUE" "color gbr sd fallback"
color_value colorspace gbr 1080
assert_eq "bt709" "$COLOR_VALUE" "color gbr hd fallback"
color_value color_range weird 240
assert_eq "tv" "$COLOR_VALUE" "color range invalid to tv"

# --- audio and subtitle plans ---
PRESET_NAME=mp4-h264; PRESET_CONTAINER=mp4; PRESET_EXT=mp4; PRESET_CODEC=h264
PRESET_AUDIO=auto; PRESET_SUBS=auto
AUDIO_INDEX=(1 3); AUDIO_CODEC=(aac opus); AUDIO_CHANNELS=(2 2)
audio_plan auto 192 1
assert_eq "2" "${#AUD_SRC[@]}" "audio auto all count"
assert_eq "copy" "${AUD_MODE[0]}" "audio auto copies aac"
assert_eq "aac" "${AUD_MODE[1]}" "audio auto encodes opus"
( audio_plan copy 192 1 ) >/dev/null 2>&1
assert_code 4 $? "audio copy rejects opus"
( audio_plan pcm 192 0 ) >/dev/null 2>&1
assert_code 4 $? "pcm rejected in mp4"

SUB_INDEX=(2 4); SUB_CODEC=(subrip hdmv_pgs_subtitle)
subtitle_plan auto
assert_eq "1" "${#SUB_SRC[@]}" "subs auto keeps text"
assert_eq "mov_text" "${SUB_MODE[0]}" "subs auto converts"
assert_eq "1" "${#SUB_DROPPED[@]}" "subs auto drops pgs"
PRESET_NAME=mkv-hevc; PRESET_CONTAINER=mkv; PRESET_EXT=mkv; PRESET_CODEC=hevc; PRESET_AUDIO=copy; PRESET_SUBS=copy
SUB_INDEX=(2); SUB_CODEC=(mov_text)
subtitle_plan auto
assert_eq "subrip" "${SUB_MODE[0]}" "subs auto mkv converts mov_text"
( subtitle_plan copy ) >/dev/null 2>&1
assert_code 4 $? "subs copy rejects mov_text in mkv"

# --- tile, batch, encoders ---
resolve_tile auto 4096; assert_eq "128" "$TILE_VALUE" "tile 4 GiB"
resolve_tile auto 12288; assert_eq "512" "$TILE_VALUE" "tile 12 GiB"
( resolve_tile 16 "" ) >/dev/null 2>&1
assert_code 4 $? "tile below 32"
assert_eq "50" "$(resolve_batch_size 0 4000 3000)" "batch >8MP"
assert_eq "100" "$(resolve_batch_size 0 1920 1080)" "batch normal"

if command -v ffmpeg >/dev/null 2>&1; then
    CFG_FFMPEG=$(command -v ffmpeg)
    PRESET_CODEC=h264
    encoder_candidates cpu
    assert_true "$( [ "${#CAND_CODEC[@]}" -ge 1 ]; echo $? )" "encoder candidates"
    assert_eq "libx264" "${CAND_CODEC[0]}" "encoder cpu forced"
fi

# --- CLI surface ---
cli() {
    ( unset UPSCAYL_V2_LIB; bash v2/unix/upscayl-video.sh "$@" )
}
VERSION_OUTPUT=$(cli --version 2>/dev/null)
assert_eq "upscayl-video $UVP_VERSION" "$VERSION_OUTPUT" "cli version"
cli --help >/dev/null 2>&1
assert_code 0 $? "cli help"
cli </dev/null >/dev/null 2>&1
assert_code 2 $? "cli no args without tty"
cli split x.mp4 --bogus >/dev/null 2>&1
assert_code 2 $? "cli unknown option"

# --- optional real-media integration ---
if [ "${RUN_V2_INTEGRATION:-0}" = "1" ]; then
    if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then
        CFG_FFMPEG=$(command -v ffmpeg)
        CFG_FFPROBE=$(command -v ffprobe)
        CLIP="$TEMP_ROOT/clip.mp4"
        ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=160x120:rate=30" \
            -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 1 \
            -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac -shortest "$CLIP"
        CFG_WORK_DIR="$TEMP_ROOT/integration"
        SP_FPS=""; SP_START=""; SP_END="0.5"; SP_FORMAT=png; SP_JPEG=1; SP_PNG=3
        SP_DENOISE=none; SP_TONEMAP=0; SP_DECODE=cpu; SP_SCALE=2; SP_TARGET=""
        SP_MODEL=upscayl-lite-4x; SP_VERIFY=0; SP_RECURSIVE=0; SP_FORCE=0
        run_split 0 1 0 "$CLIP"
        assert_eq "15" "$(job_get frame_count 0)" "integration split frames"
        EN_PRESET=mp4-h264; EN_ENCODER=cpu; EN_QUALITY=balanced; EN_CRF=""
        EN_AUDIO=copy; EN_AUDIO_BITRATE=192; EN_ALL_AUDIO=0; EN_SUBS=none
        EN_TENBIT=0; EN_TARGET=""; EN_CLEANUP=0; EN_OUTPUT=""
        EN_UPSCALED_DIR="$JOB_DIR/frames"; EN_PICK=error; EN_VERIFY=0
        EN_ALLOW_HUGE=0; EN_FORCE=1; EN_KEEP_CHUNKS=0
        run_assemble 0 "$JOB_DIR"
        assert_eq "1" "${#OUTPUTS[@]}" "integration assemble output"
    fi
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    for failure in "${FAILURES[@]}"; do printf 'FAIL: %s\n' "$failure"; done
    exit 1
fi
exit 0


