#!/usr/bin/env bash
# Run-Parity.sh -- compare the bash V2 pipeline with V1 on the same media.
# Requires bash, FFmpeg/ffprobe, Python (for V1), and cygpath on Git Bash.
# The cross-version job contract on Windows is covered by Run-Parity.ps1;
# this harness compares observable output produced by each version.

set -u
cd "$(dirname "$0")/../.." || exit 1
export UPSCAYL_V2_LIB=1
# shellcheck source=../unix/upscayl-video.sh
source v2/unix/upscayl-video.sh

PASS=0
FAIL=0
FAILURES=()

pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); FAILURES[${#FAILURES[@]}]="$1: $2"; printf 'FAIL  %s  (%s)\n' "$1" "$2"; }
check_eq() { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3" "expected [$1], got [$2]"; fi; }

FFMPEG=$(command -v ffmpeg || true)
FFPROBE=$(command -v ffprobe || true)
PYTHON=$(command -v python || command -v py || true)
if [ -z "$FFMPEG" ] || [ -z "$FFPROBE" ] || [ -z "$PYTHON" ]; then
    printf 'SKIP: ffmpeg/ffprobe/python not available\n'
    exit 0
fi
if ! command -v cygpath >/dev/null 2>&1; then
    printf 'SKIP: this harness is for Git Bash on Windows (cygpath missing)\n'
    exit 0
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/uvp-parity.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
WIN_TMP=$(cygpath -w "$TMP")
WIN_FFMPEG=$(cygpath -w "$FFMPEG")
WIN_FFPROBE=$(cygpath -w "$FFPROBE")
CLIP="$TMP/clip.mp4"
"$FFMPEG" -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=160x120:rate=30" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000" \
    -t 1 -c:v libx264 -preset veryfast -pix_fmt yuv420p \
    -color_primaries bt709 -color_trc bt709 -colorspace bt709 -color_range tv \
    -c:a aac -b:a 96k -shortest "$CLIP" || { printf 'fixture generation failed\n'; exit 1; }
WIN_CLIP=$(cygpath -w "$CLIP")

# --- V1 split and identity assemble ---
V1_WORK="$WIN_TMP/v1work"
V1_OUT="$(cygpath -u "$WIN_TMP")/v1out"
mkdir -p "$V1_OUT"
"$PYTHON" upscayl-video.py split "$WIN_CLIP" --end 1 --decode cpu \
    --work-dir "$V1_WORK" --ffmpeg "$WIN_FFMPEG" --ffprobe "$WIN_FFPROBE" >/dev/null || {
        printf 'V1 split failed\n'; exit 1;
    }
V1_JOB=$(find "$TMP/v1work" -mindepth 1 -maxdepth 1 -type d | head -n 1)
"$PYTHON" upscayl-video.py assemble "$(cygpath -w "$V1_JOB")" \
    --upscaled-dir "$(cygpath -w "$V1_JOB/frames")" \
    --preset mp4-h264 --encoder cpu --audio copy --subs none \
    --output "$(cygpath -w "$V1_OUT/v1.mp4")" --force \
    --ffmpeg "$WIN_FFMPEG" --ffprobe "$WIN_FFPROBE" >/dev/null || {
        printf 'V1 assemble failed\n'; exit 1;
    }

# --- V2 bash split and identity assemble ---
V2_WORK="$TMP/v2work"
CFG_FFMPEG="$FFMPEG"
CFG_FFPROBE="$FFPROBE"
CFG_WORK_DIR="$V2_WORK"
SP_FPS=""; SP_START=""; SP_END="1"; SP_FORMAT=png; SP_JPEG=1; SP_PNG=3
SP_DENOISE=none; SP_TONEMAP=0; SP_DECODE=cpu; SP_SCALE=2; SP_TARGET=""
SP_MODEL=upscayl-standard-4x; SP_VERIFY=0; SP_RECURSIVE=0; SP_FORCE=0
run_split 0 1 0 "$CLIP" || { printf 'V2 split failed\n'; exit 1; }
V2_JOB="$JOB_DIR"
EN_PRESET=mp4-h264; EN_ENCODER=cpu; EN_QUALITY=balanced; EN_CRF=""
EN_AUDIO=copy; EN_AUDIO_BITRATE=192; EN_ALL_AUDIO=0; EN_SUBS=none; EN_TENBIT=0
EN_TARGET=""; EN_CLEANUP=0; EN_OUTPUT="$TMP/v2out/v2.mp4"; EN_UPSCALED_DIR="$V2_JOB/frames"
EN_PICK=error; EN_VERIFY=0; EN_ALLOW_HUGE=0; EN_FORCE=1; EN_KEEP_CHUNKS=0
mkdir -p "$TMP/v2out"
run_assemble 0 "$V2_JOB" || { printf 'V2 assemble failed\n'; exit 1; }
V2_OUT="${OUTPUTS[0]}"

# --- job.txt value parity (paths and timestamps excluded) ---
job_value() {
    sed -n "s/^$2=//p" "$1/job.txt" | head -n 1
}
for key in version duration fps width height pix_fmt frame_count scale target_height \
           model frame_format denoise decode tonemap png_compression jpeg_quality \
           range_start range_end chunk_seconds chunk_frames; do
    check_eq "$(job_value "$V1_JOB" "$key")" "$(job_value "$V2_JOB" "$key")" "job value $key"
done

# --- output property parity ---
probe_value() {
    "$FFPROBE" -count_frames -v error -select_streams v:0 -show_entries "stream=$2" -of default=nw=1:nk=1 "$1" | head -n 1
}
check_eq "$(probe_value "$V1_OUT/v1.mp4" width)" "$(probe_value "$V2_OUT" width)" "output width"
check_eq "$(probe_value "$V1_OUT/v1.mp4" height)" "$(probe_value "$V2_OUT" height)" "output height"
check_eq "$(probe_value "$V1_OUT/v1.mp4" nb_read_frames)" "$(probe_value "$V2_OUT" nb_read_frames)" "output frames"
check_eq "$(probe_value "$V1_OUT/v1.mp4" color_primaries)" "bt709" "V1 color primaries"
check_eq "$(probe_value "$V2_OUT" color_primaries)" "bt709" "V2 color primaries"
check_eq "$(probe_value "$V2_OUT" color_transfer)" "bt709" "V2 color transfer"
check_eq "$(probe_value "$V2_OUT" color_space)" "bt709" "V2 color space"
check_eq "$(probe_value "$V2_OUT" color_range)" "tv" "V2 color range"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    for failure in "${FAILURES[@]}"; do printf 'FAIL: %s\n' "$failure"; done
    exit 1
fi
exit 0

