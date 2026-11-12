# Upscayl Video Pipeline V2 - upscayl module.
# Upscayl discovery, model lists, batching and frame upscaling.
# Sourced by upscayl-video.sh; not meant to be run directly.
# shellcheck shell=bash

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
