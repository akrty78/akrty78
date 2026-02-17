#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  OPLUS-ODM-BUILDER v1.0
#  Injects OPLUS HALs, libraries, configs & properties
#  into a Xiaomi ODM image for cross-platform OPLUS support.
# ═══════════════════════════════════════════════════════════════

set +e

SCRIPT_START=$(date +%s)

# ── Color Codes ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# ── Logging ──
log_info()    { echo -e "${BLUE}[INFO]${NC} $*" >&2; }
log_success() { echo -e "${GREEN}[OK]${NC} $*" >&2; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()    { echo -e "${MAGENTA}$*${NC}" >&2; }

# ── Telegram Progress ──
TG_MSG_ID=""

tg_progress() {
    [ -z "$TELEGRAM_TOKEN" ] || [ -z "$CHAT_ID" ] && return
    local msg="$1"
    local timestamp=$(date +"%H:%M:%S")
    local full_text="⚙️ *OPLUS-ODM-BUILDER*

$msg
_Last Update: ${timestamp}_"

    if [ -z "$TG_MSG_ID" ]; then
        local resp
        resp=$(curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage" \
            -d chat_id="$CHAT_ID" \
            -d parse_mode="Markdown" \
            -d text="$full_text")
        TG_MSG_ID=$(echo "$resp" | jq -r '.result.message_id')
    else
        curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/editMessageText" \
            -d chat_id="$CHAT_ID" \
            -d message_id="$TG_MSG_ID" \
            -d parse_mode="Markdown" \
            -d text="$full_text" >/dev/null
    fi
}

show_progress() {
    local step="$1" total="$2" message="$3"
    echo "" >&2
    log_step "[$step/$total] $message"
    echo "$(printf '=%.0s' $(seq 1 50))" >&2
}

# ── Inputs ──
OPLUS_OTA_URL="$1"
XIAOMI_OTA_URL="$2"

if [ -z "$OPLUS_OTA_URL" ] || [ -z "$XIAOMI_OTA_URL" ]; then
    log_error "Usage: $0 <OPLUS_OTA_URL> <XIAOMI_OTA_URL>"
    exit 1
fi

# Use /mnt — GitHub Actions has ~65GB there vs ~30GB on /tmp
WORK_DIR="${ODM_WORK_DIR:-/mnt/oplus_odm_builder_$$}"
LOG_FILE="$WORK_DIR/oplus_odm_builder.log"
TOTAL_STEPS=13
mkdir -p "$WORK_DIR"

# ── Error Trap ──
cleanup_on_exit() {
    log_info "Cleaning up mount points..."
    umount "$WORK_DIR/mount_oplus" 2>/dev/null || true
    umount "$WORK_DIR/mount_xiaomi" 2>/dev/null || true
    umount "$WORK_DIR/mount_repack" 2>/dev/null || true
    # WORK_DIR is cleaned at the end of main; on error we leave it for debug
}
trap cleanup_on_exit EXIT

# ═══════════════════════════════════════════════════════════════
#  1. PRE-FLIGHT CHECKS
# ═══════════════════════════════════════════════════════════════
preflight_checks() {
    show_progress 1 $TOTAL_STEPS "Pre-flight checks"
    tg_progress "🔍 **[1/$TOTAL_STEPS] Running pre-flight checks...**"

    local required_tools=("wget" "unzip" "jq" "curl" "mkfs.ext4" "e2fsck" "resize2fs")
    local missing=0

    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            log_error "Required tool '$tool' not found"
            missing=1
        fi
    done

    # payload-dumper-go
    if ! command -v payload-dumper-go &>/dev/null; then
        log_warning "payload-dumper-go not in PATH, checking local ./bin..."
        if [ -f "./bin/payload-dumper-go" ]; then
            export PATH="$(pwd)/bin:$PATH"
        else
            log_error "payload-dumper-go not found. Install it first."
            missing=1
        fi
    fi

    # make_ext4fs / e2fsdroid — optional but recommended for SELinux context application
    if command -v make_ext4fs &>/dev/null; then
        log_success "make_ext4fs available (SELinux contexts will be applied natively)"
    elif command -v e2fsdroid &>/dev/null; then
        log_success "e2fsdroid available (SELinux contexts will be applied post-creation)"
    else
        log_warning "Neither make_ext4fs nor e2fsdroid found — SELinux contexts will NOT be applied"
        log_warning "Image will still work but file labels may be missing"
    fi

    [ "$missing" -eq 1 ] && { log_error "Missing tools. Aborting."; exit 1; }

    # Disk space check (need ~10GB)
    local free_kb
    free_kb=$(df "${ODM_WORK_DIR:-/mnt}" 2>/dev/null | tail -1 | awk '{print $4}')
    if [ -n "$free_kb" ] && [ "$free_kb" -lt 10485760 ] 2>/dev/null; then
        log_error "Insufficient disk space. Need ≥10GB free in /tmp (have: $((free_kb/1024))MB)"
        exit 1
    fi

    log_success "All pre-flight checks passed"
}

# ═══════════════════════════════════════════════════════════════
#  2. OTA DOWNLOAD
# ═══════════════════════════════════════════════════════════════
download_ota() {
    local url="$1" output="$2" label="$3"
    log_info "Downloading $label..."
    log_info "URL: ${url:0:80}..."

    local retries=3
    while [ $retries -gt 0 ]; do
        # Prefer aria2c — multi-connection, compact progress bar (summary mode for CI)
        if command -v aria2c &>/dev/null; then
            aria2c -x 8 -s 8 --console-log-level=error \
                --summary-interval=5 \
                --download-result=hide \
                -d "$(dirname "$output")" \
                -o "$(basename "$output")" \
                "$url"
        # Fallback: curl with horizontal progress bar
        elif command -v curl &>/dev/null; then
            curl -L --progress-bar -o "$output" "$url"
        # Last resort: wget forced horizontal bar (no dots)
        else
            wget --progress=bar:force:noscroll -O "$output" "$url"
        fi

        if [ -f "$output" ] && [ -s "$output" ]; then
            local size
            size=$(du -h "$output" | cut -f1)
            log_success "$label downloaded ($size)"
            return 0
        fi

        retries=$((retries - 1))
        [ $retries -gt 0 ] && log_warning "Download failed, retrying in 5s... ($retries left)" && sleep 5
    done

    log_error "Failed to download $label after all retries"
    exit 1
}

# ═══════════════════════════════════════════════════════════════
#  3. ODM EXTRACTION FROM OTA
# ═══════════════════════════════════════════════════════════════
extract_odm_from_ota() {
    local ota_zip="$1" work_sub="$2" label="$3"
    mkdir -p "$work_sub"

    log_info "Extracting payload.bin from $label OTA..."
    unzip -j -o "$ota_zip" "payload.bin" -d "$work_sub" 2>/dev/null

    if [ ! -f "$work_sub/payload.bin" ]; then
        log_error "payload.bin not found in $label OTA"
        exit 1
    fi

    log_info "Extracting odm.img from payload.bin..."
    payload-dumper-go -p odm -o "$work_sub" "$work_sub/payload.bin"

    if [ ! -f "$work_sub/odm.img" ]; then
        log_error "odm.img extraction failed for $label"
        exit 1
    fi

    # Remove payload.bin immediately to save space
    rm -f "$work_sub/payload.bin"

    local img_size
    img_size=$(du -h "$work_sub/odm.img" | cut -f1)
    log_success "Extracted odm.img ($img_size)"

    echo "$work_sub/odm.img"
}

# ═══════════════════════════════════════════════════════════════
#  4. ODM IMAGE MOUNTING
# ═══════════════════════════════════════════════════════════════
mount_odm() {
    local odm_img="$1" mount_point="$2" label="$3"
    mkdir -p "$mount_point"

    # ── Step 1: Sparse image conversion ──────────────────────────────────
    # payload-dumper-go outputs Android sparse images. blkid returns "unknown"
    # on them and mount -o loop fails. Always attempt simg2img first.
    if command -v simg2img &>/dev/null; then
        local magic
        magic=$(od -A n -t x4 -N 4 "$odm_img" 2>/dev/null | tr -d ' 
')
        if [ "$magic" = "3aff26ed" ]; then
            log_info "$label ODM is Android sparse — converting to raw..."
            local sparse_size free_bytes
            sparse_size=$(stat -c%s "$odm_img")
            free_bytes=$(df --output=avail -B1 "${ODM_WORK_DIR:-/mnt}" 2>/dev/null | tail -1 | tr -d ' ')
            local needed=$(( sparse_size * 3 ))
            if [ -n "$free_bytes" ] && [ "$free_bytes" -lt "$needed" ]; then
                log_error "Not enough space to unsparse $label: need ~$((needed/1024/1024/1024))GB, have $((free_bytes/1024/1024/1024))GB on /mnt"
                exit 1
            fi
            local raw_img="${odm_img%.img}_raw.img"
            if simg2img "$odm_img" "$raw_img"; then
                mv "$raw_img" "$odm_img"
                log_success "$label sparse → raw conversion complete"
            else
                rm -f "$raw_img"
                log_error "simg2img failed for $label"
                exit 1
            fi
        else
            log_info "$label ODM is not sparse (magic: $magic)"
        fi
    else
        log_error "simg2img not found — install android-sdk-libsparse-utils"
        exit 1
    fi

    # ── Step 2: Detect filesystem type ───────────────────────────────────
    local fs_type
    fs_type=$(blkid -s TYPE -o value "$odm_img" 2>/dev/null || echo "unknown")
    log_info "$label filesystem type: $fs_type"

    # ── Step 3: EROFS ─────────────────────────────────────────────────────
    if [ "$fs_type" = "erofs" ]; then
        log_info "$label ODM is EROFS — extracting to directory..."
        if command -v extract.erofs &>/dev/null; then
            extract.erofs -i "$odm_img" -x -T 4 -o "$mount_point" 2>/dev/null ||             extract.erofs -i "$odm_img" -x -o "$mount_point" 2>/dev/null
        elif command -v fsck.erofs &>/dev/null; then
            fsck.erofs --extract="$mount_point" "$odm_img" 2>/dev/null
        else
            log_error "No EROFS extraction tool found — install erofs-utils"
            exit 1
        fi
        log_success "$label ODM extracted (EROFS → directory)"

    # ── Step 4: EXT4 mount ────────────────────────────────────────────────
    else
        log_info "Mounting $label ODM (ext4) read-write..."
        if ! mount -o loop,rw "$odm_img" "$mount_point" 2>/dev/null; then
            log_warning "RW mount failed — attempting filesystem repair..."
            e2fsck -fy "$odm_img" >/dev/null 2>&1 || true
            if ! mount -o loop,rw "$odm_img" "$mount_point" 2>/dev/null; then
                log_error "Failed to mount $label odm.img after repair"
                log_info "Image info: $(file "$odm_img")" >&2
                log_info "blkid: $(blkid "$odm_img" 2>&1 || true)" >&2
                exit 1
            fi
        fi
        log_success "$label ODM mounted at $mount_point"
    fi
}

# ═══════════════════════════════════════════════════════════════
#  5. OPLUS COMPONENT EXTRACTION
# ═══════════════════════════════════════════════════════════════
extract_oplus_components() {
    local oplus_mount="$1" comp_dir="$2"
    mkdir -p "$comp_dir"/{bin,bin/hw,lib,lib64,etc/init,etc/permissions,etc/vintf/manifest}

    local bin_count=0 lib_count=0 cfg_count=0

    # ── Permission manifest ──
    local perm_manifest="$comp_dir/permissions.manifest"
    > "$perm_manifest"

    record_perm() {
        local src="$1" rel_path="$2"
        local perm uid gid
        perm=$(stat -c "%a" "$src" 2>/dev/null || echo "644")
        uid=$(stat -c "%u" "$src" 2>/dev/null || echo "0")
        gid=$(stat -c "%g" "$src" 2>/dev/null || echo "2000")
        echo "$rel_path $perm $uid:$gid" >> "$perm_manifest"
    }

    # ── /odm/bin/ — OPLUS binaries ──
    if [ -d "$oplus_mount/bin" ]; then
        for f in "$oplus_mount"/bin/*; do
            [ ! -f "$f" ] && continue
            local bname=$(basename "$f")
            case "$bname" in
                *oplus*|vendor.oplus.*|vendor-oplus-*|oplus_performance*)
                    cp -a "$f" "$comp_dir/bin/"
                    record_perm "$f" "/odm/bin/$bname"
                    bin_count=$((bin_count + 1))
                    ;;
            esac
        done
    fi

    # ── /odm/bin/hw/ — HAL binaries ──
    if [ -d "$oplus_mount/bin/hw" ]; then
        for f in "$oplus_mount"/bin/hw/*; do
            [ ! -f "$f" ] && continue
            local bname=$(basename "$f")
            case "$bname" in
                *oplus*|*charger*|*stability*|*performance*|*powermonitor*|*olc2*|*power.stats*impl.oplus*)
                    cp -a "$f" "$comp_dir/bin/hw/"
                    record_perm "$f" "/odm/bin/hw/$bname"
                    bin_count=$((bin_count + 1))
                    ;;
            esac
        done
    fi

    # ── /odm/lib/ — 32-bit libraries ──
    if [ -d "$oplus_mount/lib" ]; then
        for f in "$oplus_mount"/lib/*.so; do
            [ ! -f "$f" ] && continue
            local bname=$(basename "$f")
            case "$bname" in
                vendor.oplus.*|libGaiaClient*|libosense*|libosensenativeproxy*|*oplus*|*performance*|*charger*|*olc2*|*powermonitor*|*handlefactory*|*power.stats*|*osense*)
                    cp -a "$f" "$comp_dir/lib/"
                    record_perm "$f" "/odm/lib/$bname"
                    lib_count=$((lib_count + 1))
                    ;;
            esac
        done
    fi

    # ── /odm/lib64/ — 64-bit libraries ──
    if [ -d "$oplus_mount/lib64" ]; then
        for f in "$oplus_mount"/lib64/*.so; do
            [ ! -f "$f" ] && continue
            local bname=$(basename "$f")
            case "$bname" in
                vendor.oplus.*|libGaiaClient*|libosense*|libosensenativeproxy*|*oplus*|*performance*|*charger*|*olc2*|*powermonitor*|*handlefactory*|*power.stats*|*osense*)
                    cp -a "$f" "$comp_dir/lib64/"
                    record_perm "$f" "/odm/lib64/$bname"
                    lib_count=$((lib_count + 1))
                    ;;
            esac
        done
    fi

    # ── /odm/etc/init/*.rc — init scripts ──
    if [ -d "$oplus_mount/etc/init" ]; then
        for f in "$oplus_mount"/etc/init/*.rc; do
            [ ! -f "$f" ] && continue
            local bname=$(basename "$f")
            case "$bname" in
                *oplus*|*charger*|*stability*|*performance*|*powermonitor*|*olc2*|*power.stats*)
                    cp -a "$f" "$comp_dir/etc/init/"
                    record_perm "$f" "/odm/etc/init/$bname"
                    cfg_count=$((cfg_count + 1))
                    ;;
            esac
        done
    fi

    # ── /odm/etc/permissions/*.xml — permission XMLs ──
    if [ -d "$oplus_mount/etc/permissions" ]; then
        for f in "$oplus_mount"/etc/permissions/*.xml; do
            [ ! -f "$f" ] && continue
            local bname=$(basename "$f")
            case "$bname" in
                *oplus*|*charger*|*stability*|*performance*|*olc2*|*power*)
                    cp -a "$f" "$comp_dir/etc/permissions/"
                    record_perm "$f" "/odm/etc/permissions/$bname"
                    cfg_count=$((cfg_count + 1))
                    ;;
            esac
        done
    fi

    # ── /odm/etc/vintf/manifest/*.xml — VINTF manifests ──
    if [ -d "$oplus_mount/etc/vintf/manifest" ]; then
        for f in "$oplus_mount"/etc/vintf/manifest/*.xml; do
            [ ! -f "$f" ] && continue
            local bname=$(basename "$f")
            case "$bname" in
                *oplus*|*charger*|*stability*|*performance*|*powermonitor*|*olc2*|*power*)
                    cp -a "$f" "$comp_dir/etc/vintf/manifest/"
                    record_perm "$f" "/odm/etc/vintf/manifest/$bname"
                    cfg_count=$((cfg_count + 1))
                    ;;
            esac
        done
    fi

    # ── Config directories (copy entire) ──
    for cfgdir in power_profile power_save temperature_profile ThermalServiceConfig; do
        if [ -d "$oplus_mount/etc/$cfgdir" ]; then
            cp -a "$oplus_mount/etc/$cfgdir" "$comp_dir/etc/"
            # Record perms recursively
            find "$oplus_mount/etc/$cfgdir" -type f | while read -r cf; do
                local relp="/odm/etc/${cf#$oplus_mount/etc/}"
                record_perm "$cf" "$relp"
            done
            cfg_count=$((cfg_count + $(find "$oplus_mount/etc/$cfgdir" -type f | wc -l)))
        fi
    done

    # ── Standalone config files ──
    for scf in custom_power.cfg power_stats_config.xml; do
        if [ -f "$oplus_mount/etc/$scf" ]; then
            cp -a "$oplus_mount/etc/$scf" "$comp_dir/etc/"
            record_perm "$oplus_mount/etc/$scf" "/odm/etc/$scf"
            cfg_count=$((cfg_count + 1))
        fi
    done

    # ── build.prop ──
    if [ -f "$oplus_mount/build.prop" ]; then
        cp -a "$oplus_mount/build.prop" "$comp_dir/"
        log_info "Captured OPLUS build.prop"
    fi

    log_success "Extracted: $bin_count binaries, $lib_count libraries, $cfg_count configs"
}

# ═══════════════════════════════════════════════════════════════
#  6. SELINUX CONTEXT GENERATION ENGINE
# ═══════════════════════════════════════════════════════════════
generate_selinux_contexts() {
    local oplus_contexts_file="$1"
    local comp_dir="$2"
    local output_contexts="$3"

    > "$output_contexts"
    local transformed=0

    # ── Transform context helper ──
    transform_context() {
        local ctx="$1" path="$2"

        # Executables: any oplus-related exec context → hal_allocator_default_exec
        if echo "$ctx" | grep -qE '(oplus_exec|hal_oplus|hal_charger_oplus|hal_project_oplus|hal_fingerprint_oppo|vendor_oplus_performance|oplus_performance|oplus_sensor|oplus_touch|hal_face_oplus|hal_fido|hal_cryptoeng|hal_gameopt|transmessage|hal_esim|oplus_osml|oplus_misc|oplus_sensor_aidl|oplus_nfc|oplus_rpmh|oplus_cammidasservice|oplus_wifi|oplus_location|hal_vibrator|hal_urcc|nfcextns|displaypanelfeature|dvs_aidl|riskdetect|fingerprintpay)'; then
            echo "u:object_r:hal_allocator_default_exec:s0"
            return
        fi

        # Binaries in /odm/bin/ or /odm/bin/hw/ that we're injecting
        if echo "$path" | grep -qE '^/odm/bin/(hw/)?'; then
            if echo "$ctx" | grep -qE '_exec:s0$'; then
                echo "u:object_r:hal_allocator_default_exec:s0"
                return
            fi
        fi

        # same_process_hal_file: keep as-is
        if echo "$ctx" | grep -q 'same_process_hal_file'; then
            echo "$ctx"
            return
        fi

        # vendor_configs_file: keep as-is
        if echo "$ctx" | grep -q 'vendor_configs_file'; then
            echo "$ctx"
            return
        fi

        # vendor_file: keep as-is
        if echo "$ctx" | grep -q 'vendor_file'; then
            echo "$ctx"
            return
        fi

        # Default for libraries
        if echo "$path" | grep -qE '\.(so|so\..*)$'; then
            echo "u:object_r:vendor_file:s0"
            return
        fi

        # Default for config files
        if echo "$path" | grep -qE '^/odm/etc/'; then
            echo "u:object_r:vendor_configs_file:s0"
            return
        fi

        # Fallback
        echo "u:object_r:vendor_file:s0"
    }

    log_info "Parsing OPLUS file_contexts and generating transformed entries..."

    # Build list of injected file basenames
    local injected_files="$WORK_DIR/injected_files.txt"
    > "$injected_files"
    find "$comp_dir" -type f | while read -r f; do
        local rel="${f#$comp_dir}"
        echo "/odm$rel" >> "$injected_files"
    done

    # ── Strategy 1: Match from OPLUS file_contexts ──
    if [ -f "$oplus_contexts_file" ]; then
        while IFS= read -r line; do
            # Skip comments and empty lines
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$(echo "$line" | tr -d '[:space:]')" ]] && continue

            local ctx_path ctx_label
            ctx_path=$(echo "$line" | awk '{print $1}')
            ctx_label=$(echo "$line" | awk '{print $2}')

            [ -z "$ctx_path" ] || [ -z "$ctx_label" ] && continue

            # Convert regex path to plain path for matching
            local plain_path
            plain_path=$(echo "$ctx_path" | sed 's|\\\.|\.|g; s|\\+|+|g; s|(vendor\|odm)|odm|g; s|/(vendor\|odm)/|/odm/|g')

            # Check if any injected file matches
            local matched=0
            while IFS= read -r injfile; do
                # Exact match or glob match
                if [ "$injfile" = "$plain_path" ]; then
                    matched=1
                    break
                fi
                # Check if the plain_path regex could match
                if echo "$injfile" | grep -qE "$(echo "$ctx_path" | sed 's|/(vendor\|odm)/|/odm/|g')" 2>/dev/null; then
                    matched=1
                    break
                fi
            done < "$injected_files"

            if [ "$matched" -eq 1 ]; then
                local new_ctx
                new_ctx=$(transform_context "$ctx_label" "$plain_path")
                # Ensure path pattern uses /odm prefix
                local new_path
                new_path=$(echo "$ctx_path" | sed 's|/(vendor\|odm)/|/odm/|g')
                echo "$new_path $new_ctx" >> "$output_contexts"
                transformed=$((transformed + 1))
            fi
        done < "$oplus_contexts_file"
    fi

    # ── Strategy 2: Generate entries for files NOT matched in file_contexts ──
    while IFS= read -r injfile; do
        # Check if already in output
        local escaped
        escaped=$(echo "$injfile" | sed 's/\./\\./g; s/\+/\\+/g')
        if ! grep -qF "$injfile" "$output_contexts" 2>/dev/null; then
            local auto_ctx
            # Determine context by file type and location
            if echo "$injfile" | grep -qE '^/odm/bin/(hw/)?'; then
                auto_ctx="u:object_r:hal_allocator_default_exec:s0"
            elif echo "$injfile" | grep -qE '^/odm/lib(64)?/.*osense.*\.so$'; then
                auto_ctx="u:object_r:same_process_hal_file:s0"
            elif echo "$injfile" | grep -qE '^/odm/lib(64)?/.*\.so$'; then
                auto_ctx="u:object_r:vendor_file:s0"
            elif echo "$injfile" | grep -qE '^/odm/etc/'; then
                auto_ctx="u:object_r:vendor_configs_file:s0"
            else
                auto_ctx="u:object_r:vendor_file:s0"
            fi

            # Escape dots and plus for regex in file_contexts format
            local fc_path
            fc_path=$(echo "$injfile" | sed 's/\./\\./g; s/\+/\\+/g')
            echo "$fc_path $auto_ctx" >> "$output_contexts"
            transformed=$((transformed + 1))
        fi
    done < "$injected_files"

    # ── Add directory context entries ──
    for dir_entry in \
        "/odm/etc u:object_r:vendor_configs_file:s0" \
        "/odm/etc/init u:object_r:vendor_configs_file:s0" \
        "/odm/etc/permissions u:object_r:vendor_configs_file:s0" \
        "/odm/etc/vintf u:object_r:vendor_configs_file:s0" \
        "/odm/etc/vintf/manifest u:object_r:vendor_configs_file:s0" \
        "/odm/etc/power_profile u:object_r:vendor_configs_file:s0" \
        "/odm/etc/power_save u:object_r:vendor_configs_file:s0" \
        "/odm/etc/temperature_profile u:object_r:vendor_configs_file:s0" \
        "/odm/etc/ThermalServiceConfig u:object_r:vendor_configs_file:s0" \
        "/odm/lib u:object_r:vendor_file:s0" \
        "/odm/lib64 u:object_r:vendor_file:s0"; do
        if ! grep -qF "$(echo "$dir_entry" | awk '{print $1}')" "$output_contexts" 2>/dev/null; then
            echo "$dir_entry" >> "$output_contexts"
        fi
    done

    # Sort and deduplicate
    sort -u -o "$output_contexts" "$output_contexts"

    log_success "Generated $transformed context entries"
}

# ═══════════════════════════════════════════════════════════════
#  7. INJECT OPLUS COMPONENTS INTO XIAOMI ODM
# ═══════════════════════════════════════════════════════════════
inject_oplus_to_xiaomi() {
    local comp_dir="$1" xiaomi_mount="$2" contexts_file="$3"
    local perm_manifest="$comp_dir/permissions.manifest"

    local injected_bins=0 injected_libs=0 injected_cfgs=0

    # ── Copy binaries ──
    if [ -d "$comp_dir/bin" ]; then
        mkdir -p "$xiaomi_mount/bin/hw"
        for f in "$comp_dir"/bin/*; do
            [ ! -f "$f" ] && continue
            cp -a "$f" "$xiaomi_mount/bin/"
            injected_bins=$((injected_bins + 1))
        done
        for f in "$comp_dir"/bin/hw/*; do
            [ ! -f "$f" ] && continue
            cp -a "$f" "$xiaomi_mount/bin/hw/"
            injected_bins=$((injected_bins + 1))
        done
    fi

    # ── Copy libraries ──
    for libdir in lib lib64; do
        if [ -d "$comp_dir/$libdir" ]; then
            mkdir -p "$xiaomi_mount/$libdir"
            for f in "$comp_dir/$libdir"/*.so; do
                [ ! -f "$f" ] && continue
                cp -a "$f" "$xiaomi_mount/$libdir/"
                injected_libs=$((injected_libs + 1))
            done
        fi
    done

    # ── Copy config files ──
    for cfgsubdir in etc/init etc/permissions etc/vintf/manifest etc/power_profile etc/power_save etc/temperature_profile etc/ThermalServiceConfig; do
        if [ -d "$comp_dir/$cfgsubdir" ]; then
            mkdir -p "$xiaomi_mount/$cfgsubdir"
            find "$comp_dir/$cfgsubdir" -type f | while read -r cf; do
                local relp="${cf#$comp_dir/}"
                local destdir
                destdir=$(dirname "$xiaomi_mount/$relp")
                mkdir -p "$destdir"
                cp -a "$cf" "$xiaomi_mount/$relp"
                injected_cfgs=$((injected_cfgs + 1))
            done
        fi
    done

    # Standalone config files
    for scf in custom_power.cfg power_stats_config.xml; do
        if [ -f "$comp_dir/etc/$scf" ]; then
            mkdir -p "$xiaomi_mount/etc"
            cp -a "$comp_dir/etc/$scf" "$xiaomi_mount/etc/"
            injected_cfgs=$((injected_cfgs + 1))
        fi
    done

    # ── Apply permissions from manifest ──
    if [ -f "$perm_manifest" ]; then
        log_info "Applying file permissions..."
        while IFS=' ' read -r rel_path mode ownership; do
            local target="$xiaomi_mount${rel_path#/odm}"
            if [ -f "$target" ]; then
                chmod "$mode" "$target" 2>/dev/null
                chown "$ownership" "$target" 2>/dev/null
            fi
        done < "$perm_manifest"
    fi

    # NOTE: SELinux contexts are NOT injected into /odm/etc/selinux/ inside the image.
    # They are applied via e2fsdroid during image repacking (see repack_odm_image).

    log_success "Injected: $injected_bins binaries, $injected_libs libraries, $injected_cfgs configs"
}

# ═══════════════════════════════════════════════════════════════
#  8. BUILD PROPERTY INJECTION
# ═══════════════════════════════════════════════════════════════
inject_build_properties() {
    local oplus_buildprop="$1"
    local xiaomi_odm_buildprop="$2"
    local xiaomi_etc_buildprop="$3"

    # ── Merge OPLUS props into /odm/build.prop ──
    if [ -f "$oplus_buildprop" ] && [ -f "$xiaomi_odm_buildprop" ]; then
        log_info "Merging OPLUS properties into /odm/build.prop..."
        {
            echo ""
            echo "##############################################"
            echo "# OPLUS ODM Properties - Injected by OPLUS-ODM-BUILDER"
            echo "##############################################"
            grep -v '^#' "$oplus_buildprop" | grep -v '^$'
        } >> "$xiaomi_odm_buildprop"
        log_success "OPLUS properties merged into /odm/build.prop"
    elif [ -f "$oplus_buildprop" ]; then
        log_warning "/odm/build.prop not found in Xiaomi ODM, creating..."
        cp "$oplus_buildprop" "$xiaomi_odm_buildprop"
    fi

    # ── Add OPLUS import statements to /odm/etc/build.prop ──
    if [ -f "$xiaomi_etc_buildprop" ]; then
        log_info "Adding OPLUS import statements to /odm/etc/build.prop..."
    else
        log_warning "/odm/etc/build.prop not found, creating..."
        mkdir -p "$(dirname "$xiaomi_etc_buildprop")"
        touch "$xiaomi_etc_buildprop"
    fi

    cat >> "$xiaomi_etc_buildprop" << 'OPLUS_IMPORTS'

##############################################
# OPLUS Imports - Required for OPLUS HALs
##############################################
import /odm/nexdroid.prop
import /odm/etc/${ro.boot.prjname}/build.gsi.prop
import /odm/etc/${ro.boot.prjname}/build.${ro.boot.flag}.prop
import /mnt/vendor/my_product/etc/${ro.boot.prjname}/build.${ro.boot.flag}.prop
import /my_bigball/build.prop
import /my_carrier/build.prop
import /my_company/build.prop
import /my_engineering/build.prop
import /my_heytap/build.prop
import /my_manifest/build.prop
import /my_preload/build.prop
import /my_product/build.prop
import /my_region/build.prop
import /my_stock/build.prop
OPLUS_IMPORTS

    log_success "OPLUS import statements added to /odm/etc/build.prop"
}

# ═══════════════════════════════════════════════════════════════
#  9. VERIFICATION
# ═══════════════════════════════════════════════════════════════
verify_patched_odm() {
    local patched_mount="$1"
    local contexts_file="$2"

    log_info "Verifying patched ODM..."

    # Count injected OPLUS HALs
    local oplus_hal_count=0
    if [ -d "$patched_mount/bin/hw" ]; then
        oplus_hal_count=$(find "$patched_mount/bin/hw" -name "*oplus*" -o -name "*charger*" -o -name "*performance*" -o -name "*olc2*" -o -name "*powermonitor*" 2>/dev/null | wc -l)
    fi
    log_info "Found $oplus_hal_count OPLUS HAL binaries"

    # Check external SELinux contexts file (NOT inside /odm/etc/selinux)
    if [ -f "$contexts_file" ]; then
        local context_entries
        context_entries=$(wc -l < "$contexts_file" 2>/dev/null || echo "0")
        log_info "Generated $context_entries SELinux context entries (external config)"
    else
        log_warning "External odm_file_contexts not generated"
    fi

    # Check build.prop
    if grep -q "OPLUS ODM Properties" "$patched_mount/build.prop" 2>/dev/null; then
        log_success "OPLUS properties present in build.prop"
    else
        log_warning "OPLUS properties not found in build.prop"
    fi

    # Check etc/build.prop imports
    if grep -q "OPLUS Imports" "$patched_mount/etc/build.prop" 2>/dev/null; then
        log_success "OPLUS imports present in etc/build.prop"
    else
        log_warning "OPLUS imports not found in etc/build.prop"
    fi

    log_success "Verification complete"
}

# ═══════════════════════════════════════════════════════════════
#  10. ODM IMAGE REPACKING
# ═══════════════════════════════════════════════════════════════
repack_odm_image() {
    local source_dir="$1" output_img="$2" contexts_file="$3"

    log_info "Calculating required image size..."
    local used_bytes
    used_bytes=$(du -sb "$source_dir" 2>/dev/null | cut -f1)
    # Add 15% overhead for filesystem metadata
    local img_bytes=$(( (used_bytes * 115) / 100 ))
    # Minimum 256MB
    [ "$img_bytes" -lt 268435456 ] && img_bytes=268435456
    local img_mb=$(( img_bytes / 1048576 ))

    log_info "Image size: ${img_mb}MB (content: $((used_bytes / 1048576))MB + overhead)"

    # ── Strategy 1: make_ext4fs (best — handles SELinux natively) ──
    if command -v make_ext4fs &>/dev/null; then
        log_info "Using make_ext4fs to create image with SELinux contexts..."
        if [ -f "$contexts_file" ] && [ -s "$contexts_file" ]; then
            make_ext4fs -l "${img_bytes}" -L odm -a odm -S "$contexts_file" "$output_img" "$source_dir"
        else
            make_ext4fs -l "${img_bytes}" -L odm -a odm "$output_img" "$source_dir"
        fi

        if [ $? -eq 0 ] && [ -f "$output_img" ]; then
            log_success "Image created with make_ext4fs (SELinux contexts applied)"
        else
            log_warning "make_ext4fs failed, falling back to mkfs.ext4..."
            # Fall through to mkfs.ext4 method below
            rm -f "$output_img"
        fi
    fi

    # ── Strategy 2: mkfs.ext4 + e2fsdroid (fallback) ──
    if [ ! -f "$output_img" ]; then
        log_info "Using mkfs.ext4 to create image..."

        dd if=/dev/zero of="$output_img" bs=1 count=0 seek="$img_bytes" 2>/dev/null
        mkfs.ext4 -L odm -b 4096 -q "$output_img"

        # Mount and copy
        local temp_mount="$WORK_DIR/mount_repack"
        mkdir -p "$temp_mount"
        mount -o loop "$output_img" "$temp_mount"

        log_info "Copying patched files into new image..."
        cp -a "$source_dir"/* "$temp_mount/" 2>/dev/null || cp -a "$source_dir"/. "$temp_mount/"

        umount "$temp_mount"
        rm -rf "$temp_mount"

        # Apply SELinux contexts via e2fsdroid if available
        if [ -f "$contexts_file" ] && [ -s "$contexts_file" ] && command -v e2fsdroid &>/dev/null; then
            log_info "Applying SELinux contexts via e2fsdroid..."
            e2fsdroid -e -S "$contexts_file" -a /odm "$output_img" 2>/dev/null
            if [ $? -eq 0 ]; then
                log_success "SELinux contexts applied to image metadata"
            else
                log_warning "e2fsdroid returned non-zero (contexts may be partial)"
            fi
        elif [ -f "$contexts_file" ] && [ -s "$contexts_file" ]; then
            log_warning "Neither make_ext4fs nor e2fsdroid available — SELinux contexts NOT applied"
        fi
    fi

    # Optimize
    log_info "Optimizing image..."
    e2fsck -fy "$output_img" >/dev/null 2>&1 || true
    resize2fs -M "$output_img" >/dev/null 2>&1 || true

    local final_size
    final_size=$(du -h "$output_img" | cut -f1)
    log_success "Repacked ODM image: $final_size"
}

# ═══════════════════════════════════════════════════════════════
#  11. PIXELDRAIN UPLOAD
# ═══════════════════════════════════════════════════════════════
upload_to_pixeldrain() {
    local file_path="$1"

    log_info "Uploading to PixelDrain..."
    local response
    if [ -n "$PIXELDRAIN_KEY" ]; then
        response=$(curl -s -T "$file_path" -u ":$PIXELDRAIN_KEY" "https://pixeldrain.com/api/file/")
    else
        response=$(curl -s -T "$file_path" "https://pixeldrain.com/api/file/")
    fi

    local file_id
    file_id=$(echo "$response" | jq -r '.id // empty')

    if [ -n "$file_id" ] && [ "$file_id" != "null" ]; then
        PIXELDRAIN_LINK="https://pixeldrain.com/u/$file_id"
        log_success "Upload successful!"
        log_success "Download Link: $PIXELDRAIN_LINK"
    else
        log_error "Upload failed: $response"
        PIXELDRAIN_LINK="https://pixeldrain.com"
    fi
}

# ═══════════════════════════════════════════════════════════════
#  12. TELEGRAM FINAL NOTIFICATION
# ═══════════════════════════════════════════════════════════════
send_final_notification() {
    local link="$1"

    [ -z "$TELEGRAM_TOKEN" ] || [ -z "$CHAT_ID" ] && return

    # Delete progress message
    if [ -n "$TG_MSG_ID" ]; then
        curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/deleteMessage" \
            -d chat_id="$CHAT_ID" \
            -d message_id="$TG_MSG_ID" >/dev/null
    fi

    # Compile time
    local script_end compile_secs compile_time
    script_end=$(date +%s)
    compile_secs=$((script_end - SCRIPT_START))
    compile_time=$(printf "%02dm %02ds" $((compile_secs / 60)) $((compile_secs % 60)))
    local build_date
    build_date=$(date +"%H:%M")

    local final_size
    final_size=$(du -h "$WORK_DIR/xiaomi_odm_patched.img" 2>/dev/null | cut -f1 || echo "N/A")

    local NOTIFY_CHAT="${REQUESTER_CHAT_ID:-$CHAT_ID}"

    local SAFE_TEXT="⚙️ *OPLUS-ODM-BUILDER*

\`\`\`
Patched ODM Build Info
Tool: OPLUS-ODM-BUILDER v1.0
\`\`\`

*Components Injected:*
— OPLUS HALs & Binaries
— Shared Libraries (lib/lib64)
— Init Scripts & Configs
— VINTF Manifests
— SELinux Contexts
— Build Properties & Imports

Total Size : \`$final_size\`
Compiled Time: \`$compile_time\`
Built at: \`$build_date\`"

    local JSON_PAYLOAD
    JSON_PAYLOAD=$(jq -n \
        --arg chat_id "$NOTIFY_CHAT" \
        --arg text "$SAFE_TEXT" \
        --arg url "$link" \
        --arg btn "⬇️  Download ODM" \
        '{
            chat_id: $chat_id,
            parse_mode: "Markdown",
            text: $text,
            disable_web_page_preview: true,
            reply_markup: {
                inline_keyboard: [
                    [{text: $btn, url: $url}]
                ]
            }
        }')

    local HTTP_CODE
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage" \
        -H "Content-Type: application/json" \
        -d "$JSON_PAYLOAD")

    if [ "$HTTP_CODE" -eq 200 ]; then
        log_success "Telegram notification sent to $NOTIFY_CHAT"
    else
        log_warning "Telegram notification failed (HTTP $HTTP_CODE), trying fallback..."
        curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage" \
            -d chat_id="$NOTIFY_CHAT" \
            -d text="✅ ODM Patched: $link" >/dev/null
    fi
}

# ═══════════════════════════════════════════════════════════════
#  13. CLEANUP
# ═══════════════════════════════════════════════════════════════
full_cleanup() {
    show_progress $TOTAL_STEPS $TOTAL_STEPS "Cleaning up"
    tg_progress "🧹 **[$TOTAL_STEPS/$TOTAL_STEPS] Cleaning up...**"

    # Unmount everything
    umount "$WORK_DIR/mount_oplus" 2>/dev/null || true
    umount "$WORK_DIR/mount_xiaomi" 2>/dev/null || true

    # Remove everything except the final patched image (already uploaded)
    rm -f "$WORK_DIR"/*.zip
    rm -f "$WORK_DIR"/oplus_extracted/odm.img
    rm -f "$WORK_DIR"/xiaomi_extracted/odm.img
    rm -rf "$WORK_DIR"/oplus_extracted
    rm -rf "$WORK_DIR"/xiaomi_extracted
    rm -rf "$WORK_DIR"/oplus_components
    rm -rf "$WORK_DIR"/mount_oplus
    rm -rf "$WORK_DIR"/mount_xiaomi
    rm -f "$WORK_DIR"/generated_contexts.txt
    rm -f "$WORK_DIR"/injected_files.txt

    # Final cleanup — remove entire work dir
    rm -rf "$WORK_DIR"

    log_success "Cleanup complete"
}

# ═══════════════════════════════════════════════════════════════
#  MAIN ORCHESTRATOR
# ═══════════════════════════════════════════════════════════════
oplus_odm_main() {
    echo ""
    echo "=========================================="
    echo "    OPLUS-ODM-BUILDER v1.0"
    echo "=========================================="
    echo ""

    # ── Step 1: Pre-flight ──
    preflight_checks

    # ── Step 2: Download OPLUS OTA ──
    show_progress 2 $TOTAL_STEPS "Downloading OPLUS OTA"
    tg_progress "📥 **[2/$TOTAL_STEPS] Downloading OPLUS OTA...**"
    download_ota "$OPLUS_OTA_URL" "$WORK_DIR/oplus_ota.zip" "OPLUS OTA"

    # ── Step 3: Download Xiaomi OTA ──
    show_progress 3 $TOTAL_STEPS "Downloading Xiaomi OTA"
    tg_progress "📥 **[3/$TOTAL_STEPS] Downloading Xiaomi OTA...**"
    download_ota "$XIAOMI_OTA_URL" "$WORK_DIR/xiaomi_ota.zip" "Xiaomi OTA"

    # ── Step 4: Extract OPLUS ODM ──
    show_progress 4 $TOTAL_STEPS "Extracting OPLUS ODM"
    tg_progress "📦 **[4/$TOTAL_STEPS] Extracting OPLUS ODM image...**"
    OPLUS_ODM=$(extract_odm_from_ota "$WORK_DIR/oplus_ota.zip" "$WORK_DIR/oplus_extracted" "OPLUS")
    # Remove OTA to save space
    rm -f "$WORK_DIR/oplus_ota.zip"

    # ── Step 5: Extract Xiaomi ODM ──
    show_progress 5 $TOTAL_STEPS "Extracting Xiaomi ODM"
    tg_progress "📦 **[5/$TOTAL_STEPS] Extracting Xiaomi ODM image...**"
    XIAOMI_ODM=$(extract_odm_from_ota "$WORK_DIR/xiaomi_ota.zip" "$WORK_DIR/xiaomi_extracted" "Xiaomi")
    rm -f "$WORK_DIR/xiaomi_ota.zip"

    # ── Step 6: Mount OPLUS ODM ──
    show_progress 6 $TOTAL_STEPS "Mounting OPLUS ODM"
    tg_progress "🔧 **[6/$TOTAL_STEPS] Mounting OPLUS ODM...**"
    mount_odm "$OPLUS_ODM" "$WORK_DIR/mount_oplus" "OPLUS"

    # ── Step 7: Mount Xiaomi ODM ──
    show_progress 7 $TOTAL_STEPS "Mounting Xiaomi ODM"
    tg_progress "🔧 **[7/$TOTAL_STEPS] Mounting Xiaomi ODM...**"
    mount_odm "$XIAOMI_ODM" "$WORK_DIR/mount_xiaomi" "Xiaomi"

    # ── Step 8: Extract OPLUS Components ──
    show_progress 8 $TOTAL_STEPS "Extracting OPLUS components"
    tg_progress "🔍 **[8/$TOTAL_STEPS] Extracting OPLUS HALs, libraries & configs...**"
    extract_oplus_components "$WORK_DIR/mount_oplus" "$WORK_DIR/oplus_components"

    # ── Step 9: Generate SELinux Contexts ──
    # Read from OPLUS's unpacked odm_file_contexts (inside the mounted/extracted ODM)
    # Generate transformed entries into an EXTERNAL config file for repacking
    show_progress 9 $TOTAL_STEPS "Generating SELinux contexts"
    tg_progress "🛡️ **[9/$TOTAL_STEPS] Generating SELinux context mappings...**"
    local oplus_fc="$WORK_DIR/mount_oplus/etc/selinux/odm_file_contexts"

    # Also check for Xiaomi's existing contexts to merge with
    local xiaomi_fc="$WORK_DIR/mount_xiaomi/etc/selinux/odm_file_contexts"
    local merged_contexts="$WORK_DIR/odm_file_contexts"

    # Start with Xiaomi's existing contexts (preserve them)
    if [ -f "$xiaomi_fc" ]; then
        cp "$xiaomi_fc" "$merged_contexts"
        log_info "Preserved Xiaomi's existing odm_file_contexts as base"
    else
        > "$merged_contexts"
        log_warning "No existing Xiaomi odm_file_contexts found, starting fresh"
    fi

    # Generate OPLUS transformed entries
    generate_selinux_contexts \
        "$oplus_fc" \
        "$WORK_DIR/oplus_components" \
        "$WORK_DIR/generated_contexts.txt"

    # Append generated OPLUS entries to the merged config
    if [ -f "$WORK_DIR/generated_contexts.txt" ] && [ -s "$WORK_DIR/generated_contexts.txt" ]; then
        echo "" >> "$merged_contexts"
        echo "# ── OPLUS ODM Contexts (Injected by OPLUS-ODM-BUILDER) ──" >> "$merged_contexts"
        cat "$WORK_DIR/generated_contexts.txt" >> "$merged_contexts"
        log_success "Merged OPLUS contexts into external odm_file_contexts config"
    fi

    # ── Step 10: Inject into Xiaomi ODM ──
    show_progress 10 $TOTAL_STEPS "Injecting OPLUS components into Xiaomi ODM"
    tg_progress "💉 **[10/$TOTAL_STEPS] Injecting OPLUS components into Xiaomi ODM...**"
    inject_oplus_to_xiaomi \
        "$WORK_DIR/oplus_components" \
        "$WORK_DIR/mount_xiaomi" \
        "$merged_contexts"

    # ── Inject build properties ──
    inject_build_properties \
        "$WORK_DIR/oplus_components/build.prop" \
        "$WORK_DIR/mount_xiaomi/build.prop" \
        "$WORK_DIR/mount_xiaomi/etc/build.prop"

    # ── Verify ──
    verify_patched_odm "$WORK_DIR/mount_xiaomi" "$merged_contexts"

    # ── Unmount OPLUS (no longer needed) ──
    umount "$WORK_DIR/mount_oplus" 2>/dev/null || true
    rm -f "$WORK_DIR/oplus_extracted/odm.img"

    # ── Step 11: Repack ──
    show_progress 11 $TOTAL_STEPS "Repacking Xiaomi ODM"
    tg_progress "📦 **[11/$TOTAL_STEPS] Repacking patched ODM image...**"

    # If Xiaomi ODM was mounted (ext4), unmount first then repack from directory
    # If it was EROFS-extracted, mount_xiaomi IS the directory already
    local xiaomi_source="$WORK_DIR/mount_xiaomi"

    # Check if mount_xiaomi is a mount point
    if mountpoint -q "$xiaomi_source" 2>/dev/null; then
        # It's mounted — create a copy directory
        local copy_dir="$WORK_DIR/xiaomi_copy"
        mkdir -p "$copy_dir"
        cp -a "$xiaomi_source"/* "$copy_dir/" 2>/dev/null || cp -a "$xiaomi_source"/. "$copy_dir/"
        umount "$xiaomi_source" 2>/dev/null || true
        xiaomi_source="$copy_dir"
    fi

    repack_odm_image "$xiaomi_source" "$WORK_DIR/xiaomi_odm_patched.img" "$merged_contexts"

    # ── Step 12: Upload ──
    show_progress 12 $TOTAL_STEPS "Uploading to PixelDrain"
    tg_progress "☁️ **[12/$TOTAL_STEPS] Uploading patched ODM to PixelDrain...**"
    upload_to_pixeldrain "$WORK_DIR/xiaomi_odm_patched.img"

    # ── Telegram notification ──
    send_final_notification "$PIXELDRAIN_LINK"

    # ── Step 13: Cleanup ──
    full_cleanup

    echo ""
    echo "======================================"
    echo "✅ OPLUS-ODM-BUILDER completed successfully!"
    echo "======================================"
    echo "Download Link: $PIXELDRAIN_LINK"
    echo "======================================"
    echo ""
}

# ── Entry Point ──
oplus_odm_main
