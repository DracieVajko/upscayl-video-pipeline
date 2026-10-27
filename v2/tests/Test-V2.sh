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
trap 'rm -rf "$TEMP_ROOT" "$UVP_TMP_DIR"' EXIT

# --- string, time, and format helpers ---
assert_eq "a b" "$(trim "  a b  ")" "trim"
assert_eq "video" "$(sanitize_job_id "   ")" "sanitize empty"
assert_eq "a_b" "$(sanitize_job_id "a__b")" "sanitize repeated underscore"
assert_eq "CON_" "$(sanitize_job_id "CON")" "sanitize reserved"
assert_eq "Å¾luÅ¥ouÄkÃ½" "$(sanitize_job_id "Å¾luÅ¥ouÄkÃ½")" "sanitize unicode"
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

# --- source media state survives probing a chunk segment/output ---
M_SOURCE="source.mp4"; M_WIDTH=321; M_HEIGHT=241; M_CHAPTERS=2
AUDIO_INDEX=(1); AUDIO_CODEC=(aac); SUB_INDEX=(2); SUB_CODEC=(subrip)
save_media_state
M_SOURCE="segment.ts"; M_WIDTH=322; M_HEIGHT=242; M_CHAPTERS=0
AUDIO_INDEX=(); AUDIO_CODEC=(); SUB_INDEX=(); SUB_CODEC=()
restore_media_state
assert_eq "source.mp4" "$M_SOURCE" "media state source"
assert_eq "321" "$M_WIDTH" "media state width"
assert_eq "2" "$M_CHAPTERS" "media state chapters"
assert_eq "1" "${#AUDIO_INDEX[@]}" "media state audio"
assert_eq "1" "${#SUB_INDEX[@]}" "media state subtitle count"
assert_eq "2" "${SUB_INDEX[0]}" "media state subtitle index"

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

# --- --opt=value parsing keeps every positional argument ---
COMMAND=split
parse_options --format=png "first.mp4" "second.mp4"
assert_eq "png" "$SP_FORMAT" "opt=value format"
assert_eq "2" "${#POSITIONALS[@]}" "opt=value positionals"
assert_eq "first.mp4" "${POSITIONALS[0]}" "opt=value first positional"
assert_eq "second.mp4" "${POSITIONALS[1]}" "opt=value second positional"
parse_options --work-dir=/tmp/uvp-work sample.mp4
assert_eq "/tmp/uvp-work" "$OPT_WORK_DIR" "opt=value work dir"

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
        ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=160x120:rate=25" \
            -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 1 \
            -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac -shortest "$CLIP"
        CFG_WORK_DIR="$TEMP_ROOT/integration"
        SP_FPS=""; SP_START=""; SP_END=""; SP_FORMAT=png; SP_JPEG=1; SP_PNG=3
        SP_DENOISE=none; SP_TONEMAP=0; SP_DECODE=cpu; SP_SCALE=2; SP_TARGET=""
        SP_MODEL=upscayl-lite-4x; SP_VERIFY=0; SP_RECURSIVE=0; SP_FORCE=0
        run_split 0 1 0 "$CLIP"
        assert_eq "25" "$(job_get frame_count 0)" "integration split frames"
        assert_eq "25/1" "$(job_get fps '')" "integration split fps"
        JOB_UNDER_TEST="$JOB_DIR"
        mkdir -p "$TEMP_ROOT/empty-upscaled"
        EN_PRESET=mp4-h264; EN_ENCODER=cpu; EN_QUALITY=balanced; EN_CRF=""
        EN_AUDIO=copy; EN_AUDIO_BITRATE=192; EN_ALL_AUDIO=0; EN_SUBS=none
        EN_TENBIT=0; EN_TARGET=""; EN_CLEANUP=0; EN_OUTPUT=""
        EN_UPSCALED_DIR="$TEMP_ROOT/empty-upscaled"; EN_PICK=error; EN_VERIFY=0
        EN_ALLOW_HUGE=0; EN_FORCE=1; EN_KEEP_CHUNKS=0
        ( run_assemble 0 "$JOB_UNDER_TEST" ) >/dev/null 2>&1
        assert_code 4 $? "integration bad assemble exit"
        job_load "$JOB_UNDER_TEST"
        assert_true "$( [ -n "$(job_get last_error '')" ]; echo $? )" "integration last_error recorded"
        EN_PRESET=mp4-h264; EN_ENCODER=cpu; EN_QUALITY=balanced; EN_CRF=""
        EN_AUDIO=copy; EN_AUDIO_BITRATE=192; EN_ALL_AUDIO=0; EN_SUBS=none
        EN_TENBIT=0; EN_TARGET=""; EN_CLEANUP=0; EN_OUTPUT=""
        EN_UPSCALED_DIR="$JOB_DIR/frames"; EN_PICK=error; EN_VERIFY=0
        EN_ALLOW_HUGE=0; EN_FORCE=1; EN_KEEP_CHUNKS=0
        run_assemble 0 "$JOB_DIR"
        assert_eq "1" "${#OUTPUTS[@]}" "integration assemble output"
        OUT_FPS=$("$CFG_FFPROBE" -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=nw=1:nk=1 "${OUTPUTS[0]}" | head -n 1)
        assert_eq "25/1" "$OUT_FPS" "integration output fps"

        # Chunked run with a fake upscaler, odd dimensions, audio, and chapters.
        MODEL_DIR="$TEMP_ROOT/models"
        mkdir -p "$MODEL_DIR"
        : > "$MODEL_DIR/fake-model.param"
        : > "$MODEL_DIR/fake-model.bin"
        FAKE="$TEMP_ROOT/fake-upscayl"
        cat > "$FAKE" <<'FAKE_EOF'
#!/usr/bin/env bash
input=""; output=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -i) input="$2"; shift 2 ;;
        -o) output="$2"; shift 2 ;;
        *) shift ;;
    esac
done
for file in "$input"/*; do
    [ -f "$file" ] || continue
    cp "$file" "$output/$(basename "$file")"
done
FAKE_EOF
        chmod +x "$FAKE"
        SRT="$TEMP_ROOT/chunk.srt"
        printf '1\n00:00:00,200 --> 00:00:01,000\nOne\n\n2\n00:00:01,200 --> 00:00:02,000\nTwo\n' > "$SRT"
        META="$TEMP_ROOT/chunk.chapters.txt"
        printf ';FFMETADATA1\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=6000\ntitle=One\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=6000\nEND=12000\ntitle=Two\n' > "$META"
        CHUNK_CLIP="$TEMP_ROOT/chunk11.mkv"
        ffmpeg -hide_banner -loglevel error -y \
            -f lavfi -i "testsrc2=size=322x242:rate=25" \
            -f lavfi -i "sine=frequency=330:sample_rate=48000" \
            -i "$META" \
            -vf "format=rgb24,crop=321:241" -t 12 \
            -map 0:v -map 1:a -map_metadata 2 -map_chapters 2 \
            -c:v ffv1 -pix_fmt bgr0 -c:a aac -b:a 96k -shortest "$CHUNK_CLIP"
        CFG_UPSCAYL_BIN="$FAKE"
        CFG_MODELS_DIR="$MODEL_DIR"
        US_MODEL=fake-model; US_SCALE=2; US_GPU=0; US_TILE=128; US_BATCH=50
        US_THREADS="1:2:2"; US_ICD=""; US_BIN=""; US_MODELS=""; US_RETRY=0
        SP_FORMAT=png; SP_DENOISE=none; SP_TONEMAP=0; SP_DECODE=cpu
        SP_SCALE=2; SP_TARGET=""; SP_MODEL=fake-model; SP_FPS=""; SP_START=""; SP_END=""
        EN_TARGET=""; EN_OUTPUT="$TEMP_ROOT/chunk-out.mp4"; EN_KEEP_CHUNKS=1
        EN_CLEANUP=0; EN_ALLOW_HUGE=0; EN_FORCE=1
        RUN_CLEANUP=0
        run_chunked "$CHUNK_CLIP" 10
        CHUNK_INFO=$("$CFG_FFPROBE" -v error -count_frames -select_streams v:0 \
            -show_entries stream=width,height,nb_read_frames -of default=nw=1 "$CHUNK_OUTPUT")
        assert_eq "322" "$(printf '%s\n' "$CHUNK_INFO" | sed -n 's/^width=//p')" "chunked output width"
        assert_eq "242" "$(printf '%s\n' "$CHUNK_INFO" | sed -n 's/^height=//p')" "chunked output height"
        assert_eq "300" "$(printf '%s\n' "$CHUNK_INFO" | sed -n 's/^nb_read_frames=//p')" "chunked output frames"
        CHAPTERS=$("$CFG_FFPROBE" -v error -show_chapters -of csv=p=0 "$CHUNK_OUTPUT" | grep -c . || true)
        assert_eq "2" "$CHAPTERS" "chunked output chapters"

        # Finish an existing chunked job with assemble instead of run.
        rm -f "$CHUNK_OUTPUT" "$JOB_DIR/.done_assemble"
        EN_OUTPUT="$TEMP_ROOT/chunk-assembled.mp4"
        EN_UPSCALED_DIR=""
        EN_FORCE=1
        run_assemble 0 "$JOB_DIR"
        assert_eq "1" "${#OUTPUTS[@]}" "chunked assemble output count"
        assert_true "$( [ -f "${OUTPUTS[0]}" ]; echo $? )" "chunked assemble output exists"
        CHUNK_FRAMES=$("$CFG_FFPROBE" -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of default=nw=1:nk=1 "${OUTPUTS[0]}")
        assert_eq "300" "$CHUNK_FRAMES" "chunked assemble frames"
    fi
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    for failure in "${FAILURES[@]}"; do printf 'FAIL: %s\n' "$failure"; done
    exit 1
fi
exit 0
