# Upscayl Video Pipeline V2 - doctor module.
# Environment checks.
# Sourced by upscayl-video.sh; not meant to be run directly.
# shellcheck shell=bash

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
