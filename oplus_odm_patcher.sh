#!/bin/bash
# =========================================================
#  OPLUS ODM PATCHER — Inject OnePlus HALs into Xiaomi ODM
#  Usage: ./oplus_odm_patcher.sh <OPLUS_OTA_URL> <XIAOMI_OTA_URL>
# =========================================================

set +e

SCRIPT_START=$(date +%s)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- COLOR CODES ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# --- LOGGING ---
log_info()    { echo -e "${CYAN}[INFO]${NC} $(date +"%H:%M:%S") - $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $(date +"%H:%M:%S") - $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $(date +"%H:%M:%S") - $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $(date +"%H:%M:%S") - $1"; }
log_step()    { echo -e "${MAGENTA}[STEP]${NC} $(date +"%H:%M:%S") - $1"; }

# --- TELEGRAM PROGRESS ---
TG_MSG_ID=""

tg_progress() {
    [ -z "$TELEGRAM_TOKEN" ] || [ -z "$CHAT_ID" ] && return
    local msg="$1"
    local timestamp=$(date +"%H:%M:%S")
    local full_text="⚙️ *OPLUS ODM Patcher*

$msg
_Last Update: $timestamp_"

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

tg_send() {
    [ -z "$TELEGRAM_TOKEN" ] || [ -z "$CHAT_ID" ] && return
    curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage" \
        -d chat_id="$CHAT_ID" \
        -d parse_mode="Markdown" \
        -d text="$1" >/dev/null
}

# --- INPUTS ---
OPLUS_URL="$1"
XIAOMI_URL="$2"

if [ -z "$OPLUS_URL" ] || [ -z "$XIAOMI_URL" ]; then
    log_error "Usage: $0 <OPLUS_OTA_URL> <XIAOMI_OTA_URL>"
    exit 1
fi

# --- DIRECTORIES ---
WORK_DIR=$(pwd)
BIN_DIR="$WORK_DIR/bin"
OPLUS_DL="$WORK_DIR/oplus_ota"
XIAOMI_DL="$WORK_DIR/xiaomi_ota"
OPLUS_PROJECT="$WORK_DIR/oplus_project"
XIAOMI_PROJECT="$WORK_DIR/xiaomi_project"
SYSTEM_PROJECT="$WORK_DIR/system_project"
OUTPUT_DIR="$WORK_DIR/odm_output"

mkdir -p "$BIN_DIR" "$OPLUS_DL" "$XIAOMI_DL" "$OPLUS_PROJECT" "$XIAOMI_PROJECT" "$OUTPUT_DIR"

# Flags for optional features (fail gracefully)
SYSTEM_MERGE_OK=false
VENDOR_PATCH_OK=false
export PATH="$BIN_DIR:$PATH"

# Disk space helper
log_disk() { log_info "💾 Disk free: $(df -h . | awk 'NR==2{print $4}')"; }

# Disk threshold check — returns 1 if disk critically low
check_disk_threshold() {
    local threshold_gb=${1:-5}
    local free_kb=$(df . | awk 'NR==2{print $4}')
    local free_gb=$((free_kb / 1024 / 1024))
    if [ "$free_gb" -lt "$threshold_gb" ]; then
        log_error "Disk critically low (${free_gb}GB free, need ${threshold_gb}GB). Skipping."
        return 1
    fi
    return 0
}

# Generic partition unpacker (reusable for system, vendor, etc.)
unpack_partition() {
    local img="$1"        # path to .img file
    local out_dir="$2"    # where to unpack (e.g. system_project/system)
    local label="$3"      # for logging
    local config_dir="$4" # where config/ appears (parent of out_dir)

    mkdir -p "$out_dir"

    local EROFS_BIN="$SCRIPT_DIR/bin/extract.erofs"
    if [ -f "$EROFS_BIN" ]; then
        chmod +x "$EROFS_BIN" 2>/dev/null
        cd "$config_dir"
        "$EROFS_BIN" -i "$img" -x 2>&1 | tail -5
        cd "$WORK_DIR"
        if [ -d "$out_dir" ] && [ "$(ls -A "$out_dir" 2>/dev/null)" ]; then
            log_success "$label unpacked successfully"
            return 0
        fi
    fi

    # Fallback: fsck.erofs
    if command -v fsck.erofs &>/dev/null; then
        fsck.erofs --extract="$out_dir" "$img" 2>&1 | tail -3
        if [ "$(ls -A "$out_dir" 2>/dev/null)" ]; then
            log_success "$label unpacked (fsck fallback, no xattrs)"
            mkdir -p "$config_dir/config"
            return 0
        fi
    fi

    log_error "Failed to unpack $label"
    return 1
}

# Merge a my_* partition into the system tree
merge_my_partition() {
    local img="$1"
    local part_name="$2"   # e.g. "my_product"
    local system_dir="$3"  # destination: $SYSTEM_PROJECT/system

    if [ -z "$img" ] || [ ! -f "$img" ]; then
        log_warning "  Skipping $part_name — image not found"
        return 0
    fi

    check_disk_threshold 3 || return 0

    log_info "Merging $part_name into system..."
    local tmp_dir="$WORK_DIR/${part_name}_tmp"
    mkdir -p "$tmp_dir"

    # Unpack into temp dir
    local EROFS_BIN="$SCRIPT_DIR/bin/extract.erofs"
    if [ -f "$EROFS_BIN" ]; then
        chmod +x "$EROFS_BIN" 2>/dev/null
        cd "$tmp_dir"
        "$EROFS_BIN" -i "$img" -x 2>&1 | tail -3
        cd "$WORK_DIR"
    fi

    local src_dir="$tmp_dir/$part_name"
    if [ ! -d "$src_dir" ] || [ -z "$(ls -A "$src_dir" 2>/dev/null)" ]; then
        # Fallback: fsck
        if command -v fsck.erofs &>/dev/null; then
            fsck.erofs --extract="$src_dir" "$img" 2>&1 | tail -3
        fi
    fi

    if [ ! -d "$src_dir" ] || [ -z "$(ls -A "$src_dir" 2>/dev/null)" ]; then
        log_warning "  Could not unpack $part_name — skipping"
        rm -rf "$tmp_dir"
        rm -f "$img"
        return 0
    fi

    # MERGE: cp -a with overwrite (my_* always wins over base system)
    if command -v rsync &>/dev/null; then
        rsync -a --no-perms "$src_dir/" "$system_dir/" 2>/dev/null
    else
        cp -a "$src_dir/." "$system_dir/" 2>/dev/null
    fi

    local merged_count=$(find "$src_dir" -type f 2>/dev/null | wc -l)
    log_success "  ✓ Merged $part_name: $merged_count files into system"

    # Capture contexts from this my_* partition for merging
    local my_ctx="$tmp_dir/config/${part_name}_file_contexts"
    if [ -f "$my_ctx" ]; then
        cat "$my_ctx" >> "$SYSTEM_PROJECT/config/my_combined_contexts.tmp" 2>/dev/null
    fi

    # Cleanup immediately to free disk
    rm -rf "$tmp_dir"
    rm -f "$img"
    log_disk
}

# =========================================================
#  1. INSTALL TOOLS
# =========================================================
log_step "🛠️  Installing tools..."
tg_progress "📦 Installing dependencies..."

sudo apt-get update -qq
sudo apt-get install -y -qq python3 erofs-utils jq aria2 zip unzip p7zip-full curl git >/dev/null 2>&1
log_success "System deps installed"

# payload-dumper-go
if [ ! -f "$BIN_DIR/payload-dumper-go" ]; then
    log_info "Downloading payload-dumper-go..."
    wget -q -O pd.tar.gz https://github.com/ssut/payload-dumper-go/releases/download/1.2.2/payload-dumper-go_1.2.2_linux_amd64.tar.gz
    tar -xzf pd.tar.gz
    find . -type f -name "payload-dumper-go" -not -path "*/bin/*" -exec mv {} "$BIN_DIR/" \;
    chmod +x "$BIN_DIR/payload-dumper-go"
    rm -f pd.tar.gz
    log_success "payload-dumper-go installed"
fi

# extract.erofs (from sekaiacg/erofs-extract — produces config/ with file_contexts)
if [ ! -f "$BIN_DIR/extract.erofs" ]; then
    log_info "Building extract.erofs..."
    cd "$WORK_DIR"
    git clone --depth 1 https://github.com/sekaiacg/erofs-extract.git erofs_build 2>/dev/null
    if [ -d "erofs_build" ]; then
        cd erofs_build
        # Try pre-built release first
        EROFS_RELEASE_URL="https://github.com/sekaiacg/erofs-extract/releases/latest/download/extract.erofs-linux-x86_64"
        if curl -fsSL -o "$BIN_DIR/extract.erofs" "$EROFS_RELEASE_URL" 2>/dev/null; then
            chmod +x "$BIN_DIR/extract.erofs"
            log_success "extract.erofs downloaded (pre-built)"
        else
            log_warning "Pre-built not available, building from source..."
            make -j$(nproc) 2>/dev/null
            if [ -f "extract.erofs" ]; then
                cp extract.erofs "$BIN_DIR/"
                chmod +x "$BIN_DIR/extract.erofs"
                log_success "extract.erofs built from source"
            else
                log_warning "extract.erofs build failed, falling back to fsck.erofs"
            fi
        fi
        cd "$WORK_DIR"
        rm -rf erofs_build
    fi
fi

cd "$WORK_DIR"
log_disk

# =========================================================
#  2. DOWNLOAD & EXTRACT — SEQUENTIAL (save disk space)
#     Download one OTA → extract payload → dump ODM → delete → repeat
# =========================================================

# --- OPLUS OTA ---
log_step "📥 OPLUS: Download → Extract → Cleanup"
tg_progress "📥 Downloading OPLUS OTA..."

log_info "Downloading OPLUS OTA..."
aria2c -x 16 -s 16 --allow-overwrite=true -d "$OPLUS_DL" -o "oplus_ota.zip" "$OPLUS_URL" 2>&1 | tail -1
if [ ! -f "$OPLUS_DL/oplus_ota.zip" ]; then
    log_error "Failed to download OPLUS OTA"
    tg_send "❌ *ODM Patch Failed*\nCould not download OPLUS OTA."
    exit 1
fi
log_success "OPLUS OTA downloaded: $(du -h "$OPLUS_DL/oplus_ota.zip" | cut -f1)"

log_info "Extracting OPLUS payload.bin..."
cd "$OPLUS_DL"
unzip -o -q oplus_ota.zip payload.bin 2>/dev/null || 7z e -y oplus_ota.zip payload.bin >/dev/null 2>&1
# DELETE ZIP IMMEDIATELY
rm -f "$OPLUS_DL/oplus_ota.zip"
log_info "Deleted OPLUS OTA zip"

if [ ! -f "payload.bin" ]; then
    log_error "No payload.bin in OPLUS OTA"
    tg_send "❌ *ODM Patch Failed*\nNo payload.bin found in OPLUS OTA."
    exit 1
fi

log_info "Dumping OPLUS partitions (odm + system + my_*)..."
tg_progress "📦 Extracting OPLUS partitions..."
payload-dumper-go -p odm,system,system_ext,product,my_product,my_engineering,my_stock,my_heytap,my_carrier,my_region,my_bigball,my_manifest -o "$OPLUS_DL" payload.bin 2>&1 | tail -3
# DELETE PAYLOAD IMMEDIATELY
rm -f "$OPLUS_DL/payload.bin"
log_info "Deleted OPLUS payload.bin"

# --- Locate extracted images ---
OPLUS_ODM=$(find "$OPLUS_DL" -name "odm.img" -print -quit)
if [ -z "$OPLUS_ODM" ] || [ ! -f "$OPLUS_ODM" ]; then
    log_error "Failed to extract OPLUS odm.img"
    tg_send "❌ *ODM Patch Failed*\nCould not extract OPLUS odm.img from payload."
    exit 1
fi
log_success "OPLUS odm.img extracted: $(du -h "$OPLUS_ODM" | cut -f1)"

# System images (optional — failure doesn't block ODM patch)
OPLUS_SYSTEM_IMG=$(find "$OPLUS_DL" -name "system.img" -print -quit)
OPLUS_SYSTEM_EXT_IMG=$(find "$OPLUS_DL" -name "system_ext.img" -print -quit)
OPLUS_PRODUCT_IMG=$(find "$OPLUS_DL" -name "product.img" -print -quit)

if [ -n "$OPLUS_SYSTEM_IMG" ] && [ -f "$OPLUS_SYSTEM_IMG" ]; then
    log_success "OPLUS system.img extracted: $(du -h "$OPLUS_SYSTEM_IMG" | cut -f1)"
else
    log_warning "OPLUS system.img not found — system merge will be skipped"
fi
[ -n "$OPLUS_SYSTEM_EXT_IMG" ] && [ -f "$OPLUS_SYSTEM_EXT_IMG" ] && \
    log_success "OPLUS system_ext.img: $(du -h "$OPLUS_SYSTEM_EXT_IMG" | cut -f1)"
[ -n "$OPLUS_PRODUCT_IMG" ] && [ -f "$OPLUS_PRODUCT_IMG" ] && \
    log_success "OPLUS product.img: $(du -h "$OPLUS_PRODUCT_IMG" | cut -f1)"

# my_* images (optional)
OPLUS_MY_MANIFEST_IMG=$(find "$OPLUS_DL" -name "my_manifest.img" -print -quit)
OPLUS_MY_STOCK_IMG=$(find "$OPLUS_DL" -name "my_stock.img" -print -quit)
OPLUS_MY_HEYTAP_IMG=$(find "$OPLUS_DL" -name "my_heytap.img" -print -quit)
OPLUS_MY_CARRIER_IMG=$(find "$OPLUS_DL" -name "my_carrier.img" -print -quit)
OPLUS_MY_REGION_IMG=$(find "$OPLUS_DL" -name "my_region.img" -print -quit)
OPLUS_MY_BIGBALL_IMG=$(find "$OPLUS_DL" -name "my_bigball.img" -print -quit)
OPLUS_MY_ENGINEERING_IMG=$(find "$OPLUS_DL" -name "my_engineering.img" -print -quit)
OPLUS_MY_PRODUCT_IMG=$(find "$OPLUS_DL" -name "my_product.img" -print -quit)

MY_FOUND=0
for _mi in "$OPLUS_MY_MANIFEST_IMG" "$OPLUS_MY_STOCK_IMG" "$OPLUS_MY_HEYTAP_IMG" \
          "$OPLUS_MY_CARRIER_IMG" "$OPLUS_MY_REGION_IMG" "$OPLUS_MY_BIGBALL_IMG" \
          "$OPLUS_MY_ENGINEERING_IMG" "$OPLUS_MY_PRODUCT_IMG"; do
    [ -n "$_mi" ] && [ -f "$_mi" ] && MY_FOUND=$((MY_FOUND + 1))
done
log_info "Found $MY_FOUND my_* partition images"
log_disk

# --- XIAOMI OTA ---
log_step "📥 Xiaomi: Download → Extract → Cleanup"
tg_progress "📥 Downloading Xiaomi OTA..."

log_info "Downloading Xiaomi OTA..."
aria2c -x 16 -s 16 --allow-overwrite=true -d "$XIAOMI_DL" -o "xiaomi_ota.zip" "$XIAOMI_URL" 2>&1 | tail -1
if [ ! -f "$XIAOMI_DL/xiaomi_ota.zip" ]; then
    log_error "Failed to download Xiaomi OTA"
    tg_send "❌ *ODM Patch Failed*\nCould not download Xiaomi OTA."
    exit 1
fi
log_success "Xiaomi OTA downloaded: $(du -h "$XIAOMI_DL/xiaomi_ota.zip" | cut -f1)"

log_info "Extracting Xiaomi payload.bin..."
cd "$XIAOMI_DL"
unzip -o -q xiaomi_ota.zip payload.bin 2>/dev/null || 7z e -y xiaomi_ota.zip payload.bin >/dev/null 2>&1
# DELETE ZIP IMMEDIATELY
rm -f "$XIAOMI_DL/xiaomi_ota.zip"
log_info "Deleted Xiaomi OTA zip"

if [ ! -f "payload.bin" ]; then
    log_error "No payload.bin in Xiaomi OTA"
    tg_send "❌ *ODM Patch Failed*\nNo payload.bin found in Xiaomi OTA."
    exit 1
fi

log_info "Dumping Xiaomi odm.img + vendor.img..."
payload-dumper-go -p odm,vendor -o "$XIAOMI_DL" payload.bin 2>&1 | tail -3
# DELETE PAYLOAD IMMEDIATELY
rm -f "$XIAOMI_DL/payload.bin"
log_info "Deleted Xiaomi payload.bin"

XIAOMI_ODM=$(find "$XIAOMI_DL" -name "odm.img" -print -quit)
if [ -z "$XIAOMI_ODM" ] || [ ! -f "$XIAOMI_ODM" ]; then
    log_error "Failed to extract Xiaomi odm.img"
    tg_send "❌ *ODM Patch Failed*\nCould not extract Xiaomi odm.img from payload."
    exit 1
fi
log_success "Xiaomi odm.img extracted: $(du -h "$XIAOMI_ODM" | cut -f1)"

# Vendor (optional — for fstab patching)
XIAOMI_VENDOR_IMG=$(find "$XIAOMI_DL" -name "vendor.img" -print -quit)
if [ -n "$XIAOMI_VENDOR_IMG" ] && [ -f "$XIAOMI_VENDOR_IMG" ]; then
    log_success "Xiaomi vendor.img extracted: $(du -h "$XIAOMI_VENDOR_IMG" | cut -f1)"
else
    log_warning "Xiaomi vendor.img not found — vendor fstab patch will be skipped"
    XIAOMI_VENDOR_IMG=""
fi

cd "$WORK_DIR"
log_disk

# =========================================================
#  4. UNPACK BOTH ODM IMAGES
# =========================================================
log_step "📂 Unpacking ODM images..."
tg_progress "📂 Unpacking ODM images..."

# Function to unpack an ODM image into project_dir/odm + project_dir/config
unpack_odm() {
    local img="$1"
    local project_dir="$2"
    local label="$3"

    mkdir -p "$project_dir"

    # === PRIMARY: Use bundled extract.erofs (extracts xattrs = SELinux contexts) ===
    local EROFS_BIN="$SCRIPT_DIR/bin/extract.erofs"
    if [ -f "$EROFS_BIN" ]; then
        chmod +x "$EROFS_BIN" 2>/dev/null
        log_info "Unpacking $label with bundled extract.erofs -x..."
        cd "$project_dir"
        "$EROFS_BIN" -i "$img" -x 2>&1 | tail -5

        # extract.erofs puts files in odm/ and config in config/
        if [ -d "$project_dir/odm" ] && [ "$(ls -A $project_dir/odm 2>/dev/null)" ]; then
            log_success "$label unpacked with extract.erofs (xattrs extracted)"
            # Check if config was produced
            if [ -f "$project_dir/config/odm_file_contexts" ]; then
                local ctx_lines=$(wc -l < "$project_dir/config/odm_file_contexts")
                log_success "  → Found odm_file_contexts ($ctx_lines entries)"
            fi
            if [ -f "$project_dir/config/odm_fs_config" ]; then
                local fs_lines=$(wc -l < "$project_dir/config/odm_fs_config")
                log_success "  → Found odm_fs_config ($fs_lines entries)"
            fi
            cd "$WORK_DIR"
            return 0
        fi
    fi

    # === FALLBACK 1: System extract.erofs ===
    if command -v extract.erofs &>/dev/null; then
        log_info "Trying system extract.erofs for $label..."
        cd "$project_dir"
        extract.erofs -i "$img" -x 2>&1 | tail -5
        if [ -d "$project_dir/odm" ] && [ "$(ls -A $project_dir/odm 2>/dev/null)" ]; then
            log_success "$label unpacked with system extract.erofs"
            cd "$WORK_DIR"
            return 0
        fi
    fi

    # === FALLBACK 2: fsck.erofs --extract (NO xattrs) ===
    log_info "Trying fsck.erofs for $label..."
    mkdir -p "$project_dir/odm"
    fsck.erofs --extract="$project_dir/odm" "$img" 2>&1 | tail -3

    if [ "$(ls -A $project_dir/odm 2>/dev/null)" ]; then
        log_success "$label unpacked with fsck.erofs"
        log_warning "fsck.erofs does NOT extract xattrs — contexts must be generated from scratch"
        mkdir -p "$project_dir/config"
        cd "$WORK_DIR"
        return 0
    fi

    # === FALLBACK 3: erofsfuse mount ===
    log_info "Trying erofsfuse mount for $label..."
    local mnt="$project_dir/mnt_tmp"
    mkdir -p "$mnt"
    erofsfuse "$img" "$mnt" 2>/dev/null
    if mountpoint -q "$mnt" 2>/dev/null; then
        cp -a "$mnt/"* "$project_dir/odm/" 2>/dev/null
        fusermount -u "$mnt" 2>/dev/null
        rmdir "$mnt" 2>/dev/null
        log_success "$label unpacked via erofsfuse"
        mkdir -p "$project_dir/config"
        cd "$WORK_DIR"
        return 0
    fi

    log_error "Failed to unpack $label"
    cd "$WORK_DIR"
    return 1
}

unpack_odm "$OPLUS_ODM" "$OPLUS_PROJECT" "OPLUS ODM"
if [ $? -ne 0 ]; then
    tg_send "❌ *ODM Patch Failed*\nCould not unpack OPLUS odm.img"
    exit 1
fi

unpack_odm "$XIAOMI_ODM" "$XIAOMI_PROJECT" "Xiaomi ODM"
if [ $? -ne 0 ]; then
    tg_send "❌ *ODM Patch Failed*\nCould not unpack Xiaomi odm.img"
    exit 1
fi

# Delete raw ODM .img files
rm -f "$OPLUS_ODM" "$XIAOMI_ODM"

# Move non-ODM images to staging BEFORE deleting DL dirs
STAGING_DIR="$WORK_DIR/staging"
mkdir -p "$STAGING_DIR"

# Preserve OPLUS system images + my_* images
for _img_name in system.img system_ext.img product.img \
    my_product.img my_engineering.img my_stock.img my_heytap.img \
    my_carrier.img my_region.img my_bigball.img my_manifest.img; do
    _src=$(find "$OPLUS_DL" -name "$_img_name" -print -quit 2>/dev/null)
    if [ -n "$_src" ] && [ -f "$_src" ]; then
        mv "$_src" "$STAGING_DIR/" 2>/dev/null
    fi
done

# Preserve Xiaomi vendor.img
_vendor_src=$(find "$XIAOMI_DL" -name "vendor.img" -print -quit 2>/dev/null)
if [ -n "$_vendor_src" ] && [ -f "$_vendor_src" ]; then
    mv "$_vendor_src" "$STAGING_DIR/" 2>/dev/null
fi

# Now safe to delete DL dirs
rm -rf "$OPLUS_DL" "$XIAOMI_DL"

# Update variables to point to staging locations
[ -f "$STAGING_DIR/system.img" ] && OPLUS_SYSTEM_IMG="$STAGING_DIR/system.img"
[ -f "$STAGING_DIR/system_ext.img" ] && OPLUS_SYSTEM_EXT_IMG="$STAGING_DIR/system_ext.img"
[ -f "$STAGING_DIR/product.img" ] && OPLUS_PRODUCT_IMG="$STAGING_DIR/product.img"
[ -f "$STAGING_DIR/vendor.img" ] && XIAOMI_VENDOR_IMG="$STAGING_DIR/vendor.img"
[ -f "$STAGING_DIR/my_manifest.img" ] && OPLUS_MY_MANIFEST_IMG="$STAGING_DIR/my_manifest.img"
[ -f "$STAGING_DIR/my_stock.img" ] && OPLUS_MY_STOCK_IMG="$STAGING_DIR/my_stock.img"
[ -f "$STAGING_DIR/my_heytap.img" ] && OPLUS_MY_HEYTAP_IMG="$STAGING_DIR/my_heytap.img"
[ -f "$STAGING_DIR/my_carrier.img" ] && OPLUS_MY_CARRIER_IMG="$STAGING_DIR/my_carrier.img"
[ -f "$STAGING_DIR/my_region.img" ] && OPLUS_MY_REGION_IMG="$STAGING_DIR/my_region.img"
[ -f "$STAGING_DIR/my_bigball.img" ] && OPLUS_MY_BIGBALL_IMG="$STAGING_DIR/my_bigball.img"
[ -f "$STAGING_DIR/my_engineering.img" ] && OPLUS_MY_ENGINEERING_IMG="$STAGING_DIR/my_engineering.img"
[ -f "$STAGING_DIR/my_product.img" ] && OPLUS_MY_PRODUCT_IMG="$STAGING_DIR/my_product.img"

log_info "Staged $(ls "$STAGING_DIR"/*.img 2>/dev/null | wc -l) images for system merge + vendor patch"
log_disk

OPLUS_ODM_DIR="$OPLUS_PROJECT/odm"
XIAOMI_ODM_DIR="$XIAOMI_PROJECT/odm"
OPLUS_CONFIG="$OPLUS_PROJECT/config"
XIAOMI_CONFIG="$XIAOMI_PROJECT/config"

log_info "OPLUS ODM contents: $(ls "$OPLUS_ODM_DIR" 2>/dev/null | tr '\n' ' ')"
log_info "Xiaomi ODM contents: $(ls "$XIAOMI_ODM_DIR" 2>/dev/null | tr '\n' ' ')"

# =========================================================
#  5. HAL INJECTION ENGINE (Refined — Working Build Analysis)
# =========================================================
log_step "💉 Injecting OPLUS HALs into Xiaomi ODM..."
tg_progress "💉 Injecting OPLUS HALs..."

INJECT_COUNT=0
INJECT_ERRORS=0
SKIP_COUNT=0

# Helper: copy a file from OPLUS to Xiaomi with NO-CLOBBER protection
# Never overwrites existing Xiaomi-native files
inject_file() {
    local src="$1"
    local dst="$2"

    if [ -d "$src" ]; then
        mkdir -p "$dst"
        # Use cp -a --no-clobber to preserve Xiaomi originals
        cp -a -n "$src/"* "$dst/" 2>/dev/null
        local count=$(find "$src" -type f | wc -l)
        INJECT_COUNT=$((INJECT_COUNT + count))
        log_success "  ✓ Injected dir: $(basename "$src") ($count files)"
    elif [ -f "$src" ]; then
        mkdir -p "$(dirname "$dst")"
        if [ -f "$dst" ]; then
            # File already exists — skip to preserve Xiaomi native
            SKIP_COUNT=$((SKIP_COUNT + 1))
            return 0
        fi
        cp -a "$src" "$dst" 2>/dev/null
        INJECT_COUNT=$((INJECT_COUNT + 1))
        log_success "  ✓ Injected: $(basename "$src")"
    else
        INJECT_ERRORS=$((INJECT_ERRORS + 1))
    fi
}

# Force-inject: overwrites even if destination exists (for OPLUS-specific HALs)
inject_file_force() {
    local src="$1"
    local dst="$2"

    if [ -d "$src" ]; then
        mkdir -p "$dst"
        cp -a "$src/"* "$dst/" 2>/dev/null
        local count=$(find "$src" -type f | wc -l)
        INJECT_COUNT=$((INJECT_COUNT + count))
        log_success "  ✓ Force-injected dir: $(basename "$src") ($count files)"
    elif [ -f "$src" ]; then
        mkdir -p "$(dirname "$dst")"
        cp -a "$src" "$dst" 2>/dev/null
        INJECT_COUNT=$((INJECT_COUNT + 1))
        log_success "  ✓ Injected: $(basename "$src")"
    else
        INJECT_ERRORS=$((INJECT_ERRORS + 1))
    fi
}

# ===========================================================
# TWO-TIER KEYWORD SYSTEM (from working build analysis)
# Services need STRICT filtering to avoid bootloops.
# Libs are just dependencies — safe to include broadly.
# ===========================================================

# TIER 1: STRICT — for bin/hw services, etc/init, etc/vintf
# Only inject service binaries + manifests + init RCs for these categories:
SERVICE_KEYWORDS="charger|performance|powermonitor|olc|stability|power.stats|power_stats"
# NFC service stack
NFC_SERVICE_KW="nfc|nxp|secure_element|esepowermanager|keymint.*strongbox.*nxp|weaver.*nxp"
# Combined service filter
SERVICE_FILTER="$SERVICE_KEYWORDS|$NFC_SERVICE_KW"

# BLACKLIST — explicitly skip these service binaries even if they match above
# These are device-specific HALs that WILL cause bootloops on Xiaomi
SKIP_SERVICES="biometrics|face|fingerprint|fingerprintpay|cammidasservice|cryptoeng|displaypanelfeature|eid|fido|gameinference|gameopt|location_aidl|riskdetect|rpmh|urcc|vibrator|wifi-aidl|misc-V|oplusSensor|osml|touch|transfer|transmessage|qrtr"

# TIER 2: BROAD — for lib/lib64 .so files (safe as dependencies)
LIB_KEYWORDS="oplus|oppo|nfc|nxp|secure_element|esepowermanager|pnscr|sn100|sn220|nq_client|nfc_nci|se_nq|ls_nq|jcos|omapi|mifare|olc|osense|gaia|handlefactory|power.stats|keymint.*nxp|weaver.*nxp"

# TIER 2: For permissions (safe — just feature declarations)
PERM_KEYWORDS="oplus|nfc|nxp|omapi|mifare|charger|stability|olc|power|performance"

log_info "Service filter: $SERVICE_FILTER"
log_info "Skip services: $SKIP_SERVICES"

# --- bin/hw/ — HAL service binaries (STRICT filtering) ---
log_info "Injecting HAL binaries (bin/hw) — STRICT mode..."
tg_progress "💉 Injecting HAL binaries..."
if [ -d "$OPLUS_ODM_DIR/bin/hw" ]; then
    for hal_bin in "$OPLUS_ODM_DIR/bin/hw/"*; do
        [ -f "$hal_bin" ] || continue
        fname=$(basename "$hal_bin")
        # First check blacklist — skip unwanted services
        if echo "$fname" | grep -qiE "$SKIP_SERVICES"; then
            log_warning "  ✗ Skipped (blacklisted): $fname"
            continue
        fi
        # Then check whitelist — only inject matching services
        if echo "$fname" | grep -qiE "$SERVICE_FILTER"; then
            inject_file_force "$hal_bin" "$XIAOMI_ODM_DIR/bin/hw/$fname"
        fi
    done
fi

# --- bin/ — OPLUS scripts and standalone NFC binaries ---
log_info "Injecting bin/ scripts..."
if [ -d "$OPLUS_ODM_DIR/bin" ]; then
    for bin_file in "$OPLUS_ODM_DIR/bin/"*; do
        [ -f "$bin_file" ] || continue
        fname=$(basename "$bin_file")
        # Only inject NFC-related binaries and performance script
        if echo "$fname" | grep -qiE "nfc|nqnfcinfo|oplus_performance"; then
            inject_file "$bin_file" "$XIAOMI_ODM_DIR/bin/$fname"
        fi
    done
fi
# Always inject performance script if present
[ -f "$OPLUS_ODM_DIR/bin/oplus_performance.sh" ] && inject_file_force "$OPLUS_ODM_DIR/bin/oplus_performance.sh" "$XIAOMI_ODM_DIR/bin/oplus_performance.sh"

# --- lib/ & lib64/ — Shared Libraries (BROAD filtering — safe as deps) ---
for arch in "lib" "lib64"; do
    log_info "Injecting $arch/ (broad mode)..."
    tg_progress "💉 Injecting $arch/..."
    
    # Main dir (.so files)
    if [ -d "$OPLUS_ODM_DIR/$arch" ]; then
        for lib_file in "$OPLUS_ODM_DIR/$arch/"*.so; do
            [ -f "$lib_file" ] || continue
            fname=$(basename "$lib_file")
            if echo "$fname" | grep -qiE "$LIB_KEYWORDS"; then
                inject_file "$lib_file" "$XIAOMI_ODM_DIR/$arch/$fname"
            fi
        done
    fi

    # hw/ subdir
    if [ -d "$OPLUS_ODM_DIR/$arch/hw" ]; then
        log_info "Injecting $arch/hw/..."
        mkdir -p "$XIAOMI_ODM_DIR/$arch/hw"
        for lib_file in "$OPLUS_ODM_DIR/$arch/hw/"*.so; do
            [ -f "$lib_file" ] || continue
            fname=$(basename "$lib_file")
            if echo "$fname" | grep -qiE "$LIB_KEYWORDS"; then
                inject_file "$lib_file" "$XIAOMI_ODM_DIR/$arch/hw/$fname"
            fi
        done
    fi
done

# --- firmware/ (fastchg only — from working build) ---
log_info "Injecting firmware/fastchg..."
tg_progress "💉 Injecting firmware..."
if [ -d "$OPLUS_ODM_DIR/firmware/fastchg" ]; then
    mkdir -p "$XIAOMI_ODM_DIR/firmware/fastchg"
    cp -a -n "$OPLUS_ODM_DIR/firmware/fastchg/"* "$XIAOMI_ODM_DIR/firmware/fastchg/" 2>/dev/null
    local_count=$(find "$OPLUS_ODM_DIR/firmware/fastchg" -type f | wc -l)
    INJECT_COUNT=$((INJECT_COUNT + local_count))
    log_success "  ✓ Injected firmware/fastchg ($local_count files)"
elif [ -d "$OPLUS_ODM_DIR/firmware" ]; then
    mkdir -p "$XIAOMI_ODM_DIR/firmware"
    cp -a -n "$OPLUS_ODM_DIR/firmware/"* "$XIAOMI_ODM_DIR/firmware/" 2>/dev/null
    log_success "  ✓ Injected firmware/ contents (fallback)"
fi

# --- etc/ — Configs, Init, VINTF, Permissions ---
log_info "Injecting etc/ configs..."
tg_progress "💉 Injecting configs & manifests..."

# etc/init/ — STRICT: only inject init RCs for whitelisted services
if [ -d "$OPLUS_ODM_DIR/etc/init" ]; then
    log_info "Injecting etc/init/ — STRICT mode..."
    mkdir -p "$XIAOMI_ODM_DIR/etc/init"
    for item in "$OPLUS_ODM_DIR/etc/init/"*; do
        [ -f "$item" ] || continue
        fname=$(basename "$item")
        # Blacklist check first
        if echo "$fname" | grep -qiE "$SKIP_SERVICES"; then
            log_warning "  ✗ Skipped init RC: $fname"
            continue
        fi
        # Whitelist check
        if echo "$fname" | grep -qiE "$SERVICE_FILTER"; then
            inject_file_force "$item" "$XIAOMI_ODM_DIR/etc/init/$fname"
        fi
    done
fi

# etc/vintf/manifest/ — STRICT: only inject VINTF manifests for whitelisted services
if [ -d "$OPLUS_ODM_DIR/etc/vintf/manifest" ]; then
    log_info "Injecting etc/vintf/manifest/ — STRICT mode..."
    mkdir -p "$XIAOMI_ODM_DIR/etc/vintf/manifest"
    for item in "$OPLUS_ODM_DIR/etc/vintf/manifest/"*; do
        [ -f "$item" ] || continue
        fname=$(basename "$item")
        # Blacklist check first
        if echo "$fname" | grep -qiE "$SKIP_SERVICES"; then
            log_warning "  ✗ Skipped VINTF: $fname"
            continue
        fi
        # Whitelist check
        if echo "$fname" | grep -qiE "$SERVICE_FILTER"; then
            inject_file_force "$item" "$XIAOMI_ODM_DIR/etc/vintf/manifest/$fname"
        fi
    done
fi

# etc/permissions/ — BROAD: inject all OPLUS/NFC permission XMLs (safe — just declarations)
if [ -d "$OPLUS_ODM_DIR/etc/permissions" ]; then
    log_info "Injecting etc/permissions/ (broad mode, recursive)..."
    find "$OPLUS_ODM_DIR/etc/permissions" -type f | while read -r item; do
        rel=$(realpath --relative-to="$OPLUS_ODM_DIR/etc/permissions" "$item")
        fname=$(basename "$item")
        if echo "$fname" | grep -qiE "$PERM_KEYWORDS"; then
            dst_dir=$(dirname "$XIAOMI_ODM_DIR/etc/permissions/$rel")
            mkdir -p "$dst_dir"
            inject_file_force "$item" "$XIAOMI_ODM_DIR/etc/permissions/$rel"
        fi
    done
fi

# etc/nfc/ — Complete NFC config directory
if [ -d "$OPLUS_ODM_DIR/etc/nfc" ]; then
    log_info "Injecting etc/nfc/ directory..."
    inject_file "$OPLUS_ODM_DIR/etc/nfc" "$XIAOMI_ODM_DIR/etc/nfc"
fi

# etc/dolby/ — Dolby configs
if [ -d "$OPLUS_ODM_DIR/etc/dolby" ]; then
    log_info "Injecting etc/dolby/ directory..."
    inject_file "$OPLUS_ODM_DIR/etc/dolby" "$XIAOMI_ODM_DIR/etc/dolby"
fi

# Specific config dirs/files (power, thermal)
inject_file "$OPLUS_ODM_DIR/etc/ThermalServiceConfig" "$XIAOMI_ODM_DIR/etc/ThermalServiceConfig"
inject_file "$OPLUS_ODM_DIR/etc/power_profile" "$XIAOMI_ODM_DIR/etc/power_profile"
inject_file "$OPLUS_ODM_DIR/etc/power_save" "$XIAOMI_ODM_DIR/etc/power_save"
inject_file "$OPLUS_ODM_DIR/etc/temperature_profile" "$XIAOMI_ODM_DIR/etc/temperature_profile"
[ -f "$OPLUS_ODM_DIR/etc/custom_power.cfg" ] && inject_file_force "$OPLUS_ODM_DIR/etc/custom_power.cfg" "$XIAOMI_ODM_DIR/etc/custom_power.cfg"
[ -f "$OPLUS_ODM_DIR/etc/power_stats_config.xml" ] && inject_file_force "$OPLUS_ODM_DIR/etc/power_stats_config.xml" "$XIAOMI_ODM_DIR/etc/power_stats_config.xml"

log_info "Injection summary: $INJECT_COUNT injected, $SKIP_COUNT skipped (Xiaomi native preserved), $INJECT_ERRORS not found"


# =========================================================
#  6. PROPS INJECTION (NexDroid Prop)
# =========================================================
log_step "📝 Generating nexdroid.prop..."
tg_progress "📝 Generating nexdroid.prop..."

NEXDROID_PROP="$XIAOMI_ODM_DIR/nexdroid.prop"
OPLUS_BUILD_PROP="$OPLUS_ODM_DIR/build.prop"
[ ! -f "$OPLUS_BUILD_PROP" ] && OPLUS_BUILD_PROP="$OPLUS_ODM_DIR/etc/build.prop"

echo "# NexDroid OPLUS Properties" > "$NEXDROID_PROP"

# 1. Dump ENTIRE OPLUS build.prop
if [ -f "$OPLUS_BUILD_PROP" ]; then
    log_info "Dumping OPLUS props from $(basename "$OPLUS_BUILD_PROP")..."
    cat "$OPLUS_BUILD_PROP" >> "$NEXDROID_PROP"
else
    log_warning "OPLUS build.prop not found"
fi

# 2. Append Device-Specific & Hardcoded Props
log_info "Appending NexDroid specific props..."
cat <<EOF >> "$NEXDROID_PROP"

# === NexDroid Extras ===
# Camera & Display (SM7475 - Redmi Note 12 Turbo / POCO F5)
ro.vendor.oplus.camera.frontCamSize=16MP
ro.vendor.oplus.camera.backCamSize=64MP+8MP+2MP
ro.sf.lcd_density=480
ro.oplus.display.screenSizeInches.primary=6.67
ro.oplus.display.rc.size=70,70,70,70
ro.build.device_family=OPSM7475
ro.product.oplus.cpuinfo=SM7475
ro.soc.model=SM7475

# Bluetooth & Audio
bluetooth.profile.asha.central.enabled=true
bluetooth.profile.a2dp.source.enabled=true
bluetooth.profile.avrcp.target.enabled=true
bluetooth.profile.bap.broadcast.assist.enabled=false
bluetooth.profile.bap.unicast.client.enabled=false
bluetooth.profile.bap.broadcast.source.enabled=false
bluetooth.profile.bas.client.enabled=true
bluetooth.profile.ccp.server.enabled=false
bluetooth.profile.csip.set_coordinator.enabled=false
bluetooth.profile.gatt.enabled=true
bluetooth.profile.hap.client.enabled=false
bluetooth.profile.hfp.ag.enabled=true
bluetooth.profile.hid.host.enabled=true
bluetooth.profile.mcp.server.enabled=false
bluetooth.profile.opp.enabled=true
bluetooth.profile.pan.nap.enabled=true
bluetooth.profile.pan.panu.enabled=true
bluetooth.profile.vcp.controller.enabled=false
bluetooth.profile.avrcp.controller.enabled=false
bluetooth.profile.hid.device.enabled=true
bluetooth.profile.map.server.enabled=true
bluetooth.profile.pbap.server.enabled=true
bluetooth.profile.sap.server.enabled=false
vendor.bluetooth.startbtlogger=false

# Logging & Debug
debug.sqlite.journalmode=OFF
debug.sqlite.wal.syncmode=OFF
persist.logd.limit=OFF
persist.logd.size=65536
persist.logd.size.crash=1M
persist.logd.size.radio=1M
persist.logd.size.system=1M
persist.mm.enable.prefetch=false
log.tag.stats_log=OFF
ro.logd.size=64K
ro.logd.size.stats=64K
persist.sys.offlinelog.kernel=false
persist.sys.offlinelog.logcat=false
persist.sys.offlinelog.logcatkernel=false
persist.sys.force_sw_gles=0
ro.kernel.android.checkjni=0
ro.kernel.checkjni=0
persist.wpa_supplicant.debug=false

# Power & Performance
pm.sleep_mode=1
ro.ril.disable.power.collapse=0
wifi.supplicant_scan_interval=200
dalvik.vm.heapmaxfree=8m
dalvik.vm.heapminfree=4m
dalvik.vm.heapstartsize=48m
ro.lmk.low=1001
ro.lmk.medium=900
ro.lmk.critical_upgrade=false
ro.lmk.enhance_batch_kill=false
ro.lmk.enable_adaptive_lmk=false
ro.lmk.use_minfree_levels=false
ro.lmk.kill_heaviest_task=false
ro.vendor.qti.sys.fw.bg_apps_limit=600
ro.vendor.qti.sys.fw.bservice_enable=true
ro.vendor.qti.sys.fw.bservice_limit=60

# Security & USB
persist.sys.usb.config=mtp
sys.usb.config=mtp
sys.usb.state=mtp
persist.service.adb.enable=1
persist.sys.disable_rescue=true
ro.boot.flash.locked=1
ro.boot.vbmeta.device_state=locked
ro.boot.verifiedbootstate=green
ro.boot.veritymode=enforcing
ro.boot.selinux=enforcing
ro.boot.warranty_bit=0
ro.build.tags=release-keys
ro.build.type=user
ro.control_privapp_permissions=disable
ro.debuggable=0
ro.is_ever_orange=0
ro.secure=1
ro.vendor.boot.warranty_bit=0
ro.vendor.warranty_bit=0
ro.warranty_bit=0
vendor.boot.vbmeta.device_state=locked
vendor.boot.verifiedbootstate=green
ro.crypto.state=encrypted

# Customization
sys.miui.ndcd=off
persist.vendor.display.miui.composer_boost=4-7
persist.sys.high_report_rate.enable=0
persist.sys.pause.charging.enable=0
persist.sys.fuckoiface.enable=0
persist.sys.less_blur.enable=1
persist.sys.high_refresh_rate.enable=0
persist.sys.performance.enable=0
persist.sys.performance_pro.enable=1
ro.config.notification_sound=Whoop_doop.ogg
ro.config.calendar_sound=Cozy.ogg
ro.config.alarm_alert=Cloudscape.ogg
ro.config.notification_sim2=Free.ogg
ro.config.notification_sms=Free.ogg
ro.config.ringtone_sim2=OnePlus_new_feeling.ogg
ro.config.ringtone=OnePlus_new_feeling.ogg
EOF

# 3. Add Import to Xiaomi build.prop
XIAOMI_BUILD_PROP="$XIAOMI_ODM_DIR/build.prop"
[ ! -f "$XIAOMI_BUILD_PROP" ] && XIAOMI_BUILD_PROP="$XIAOMI_ODM_DIR/etc/build.prop"

if [ -f "$XIAOMI_BUILD_PROP" ]; then
    log_info "Injecting imports into $(basename "$XIAOMI_BUILD_PROP")..."
    # Add imports only if not present
    if ! grep -q "nexdroid.prop" "$XIAOMI_BUILD_PROP"; then
        cat <<EOF >> "$XIAOMI_BUILD_PROP"

# === NexDroid OPLUS Imports ===
import /odm/nexdroid.prop
import /odm/etc/\${ro.boot.prjname}/build.gsi.prop
import /odm/etc/\${ro.boot.prjname}/build.\${ro.boot.flag}.prop
import /mnt/vendor/my_product/etc/\${ro.boot.prjname}/build.\${ro.boot.flag}.prop

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
EOF
    fi
fi
log_success "nexdroid.prop generated and linked"
log_disk


# =========================================================
#  7. CONTEXT GENERATION ENGINE (MIO-KITCHEN approach)
#     Merges Xiaomi original contexts (from extract.erofs)
#     + generates new entries for injected OPLUS files with
#     proper OPLUS HAL contexts.
# =========================================================
log_step "🏷️  Generating file_contexts..."
tg_progress "🏷️ Generating file_contexts..."

# Free disk: delete OPLUS project NOW (injection is done)
log_info "Deleting OPLUS project to free disk..."
rm -rf "$OPLUS_PROJECT"
log_disk

XIAOMI_CONTEXTS="$XIAOMI_CONFIG/odm_file_contexts"
XIAOMI_FS_CONFIG="$XIAOMI_CONFIG/odm_fs_config"
mkdir -p "$XIAOMI_CONFIG"

# Check if Xiaomi already has contexts (from extract.erofs -x)
if [ -f "$XIAOMI_CONTEXTS" ] && [ -s "$XIAOMI_CONTEXTS" ]; then
    log_info "Found existing Xiaomi file_contexts ($(wc -l < "$XIAOMI_CONTEXTS") entries)"
    cp "$XIAOMI_CONTEXTS" "$XIAOMI_CONTEXTS.orig"
fi

# Python Engine: MIO-KITCHEN-style context patching
# 1. Read existing Xiaomi contexts as base dict (path -> context)
# 2. Walk the FINAL merged filesystem
# 3. For each path: re.escape() for SELinux-safe path escaping
# 4. If path exists in base -> keep original context
# 5. If path is NEW -> assign OPLUS HAL context rules
# 6. Write sorted merged output
cat > "$WORK_DIR/context_gen.py" << 'PYEOF'
import os
import sys
import re
from re import escape as re_escape

odm_dir = sys.argv[1]
out_file = sys.argv[2]
orig_ctx_file = sys.argv[3] if len(sys.argv) > 3 else ""

print(f"Context engine: {odm_dir}")

# ==== MIO-KITCHEN str_to_selinux ====
def str_to_selinux(s):
    """Escape path for file_contexts format (like MIO-KITCHEN)."""
    if s.endswith('(/.*)?'):
        return s
    escaped = re_escape(s).replace('\\-', '-')
    return escaped

# ==== PHASE 1: Load existing Xiaomi contexts ====
base_contexts = {}  # path -> context

if orig_ctx_file and os.path.isfile(orig_ctx_file):
    print(f"Loading existing contexts from: {orig_ctx_file}")
    with open(orig_ctx_file, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            parts = line.split()
            if len(parts) >= 2:
                base_contexts[parts[0]] = parts[1]
    print(f"Loaded {len(base_contexts)} existing Xiaomi contexts")
else:
    print("No existing contexts found — generating from scratch")

# ==== PHASE 2: OPLUS HAL Context Rules ====
# These are the OPLUS-specific contexts that differ from Xiaomi defaults.
# Xiaomi uses different context types for their HALs.
def get_oplus_context(rel_path, fname):
    """Assign SELinux context for OPLUS-injected files.
    Xiaomi-original files should keep their original contexts from base_contexts.
    This function is ONLY called for NEW files not in the base."""
    
    # ===== BINARIES (bin/hw/) =====
    if '/bin/hw/' in rel_path:
        # NXP NFC HAL
        if 'nxp' in fname and 'nfc' in fname:
            return "u:object_r:hal_nfc_default_exec:s0"
        # QTI Secure Element
        if 'secure_element' in fname:
            return "u:object_r:hal_secure_element_default_exec:s0"
        # QTI ESE Power Manager
        if 'esepowermanager' in fname:
            return "u:object_r:vendor_hal_esepowermanager_qti_exec:s0"
        # Xiaomi Mikeybag
        if 'mikeybag' in fname:
            return "u:object_r:hal_mikeybag_default_exec:s0"
        # All OPLUS HALs: charger, performance, powermonitor, olc, stability, nfc_aidl, nfcExtns
        return "u:object_r:hal_allocator_default_exec:s0"
    
    if '/bin/' in rel_path:
        if 'mikeybag' in fname:
            return "u:object_r:hal_mikeybag_default_exec:s0"
        if 'nqnfcinfo' in fname:
            return "u:object_r:vendor_nqnfcinfo_exec:s0"
        if 'oplus_performance' in fname:
            return "u:object_r:hal_allocator_default_exec:s0"
        return "u:object_r:vendor_file:s0"
    
    # ===== LIBRARIES =====
    if re.match(r'.*/lib(64)?/hw/', rel_path):
        return "u:object_r:vendor_file:s0"
    if re.match(r'.*/lib(64)?/', rel_path):
        if 'osense' in fname and 'client' in fname:
            return "u:object_r:same_process_hal_file:s0"
        return "u:object_r:vendor_file:s0"
    
    # ===== PROPS =====
    if fname.endswith('.prop'):
        return "u:object_r:vendor_file:s0"
    
    # ===== ETC / CONFIGS =====
    if '/etc/' in rel_path:
        if 'selinux/precompiled_sepolicy' in rel_path and not fname.endswith('.sha256'):
            return "u:object_r:sepolicy_file:s0"
        if fname == 'build.prop':
            return "u:object_r:vendor_file:s0"
        return "u:object_r:vendor_configs_file:s0"
    
    # ===== FIRMWARE =====
    if '/firmware/' in rel_path:
        return "u:object_r:vendor_configs_file:s0"
    
    return "u:object_r:vendor_file:s0"

def get_dir_context(rel_path):
    """Context for directories."""
    if '/etc' in rel_path:
        return "u:object_r:vendor_configs_file:s0"
    if re.match(r'.*/lib(64)?/hw$', rel_path):
        return "u:object_r:vendor_hal_file:s0"
    if '/firmware/' in rel_path:
        return "u:object_r:vendor_configs_file:s0"
    return "u:object_r:vendor_file:s0"

# ==== PHASE 3: Walk filesystem (MIO-KITCHEN scan_dir approach) ====
part_name = os.path.basename(odm_dir)  # 'odm'
merged = dict(base_contexts)  # Start with existing contexts
add_count = 0

# Static base entries (always include)
static_entries = [
    ('/', 'u:object_r:vendor_file:s0'),
    ('/lost+found', 'u:object_r:vendor_file:s0'),
    (f'/{part_name}', 'u:object_r:vendor_file:s0'),
    (f'/{part_name}/', 'u:object_r:vendor_file:s0'),
    (f'/{part_name}/lost\\+found', 'u:object_r:vendor_file:s0'),
]
for path, ctx in static_entries:
    if path not in merged:
        merged[path] = ctx

# Walk the entire ODM directory
for root, dirs, files in os.walk(odm_dir):
    dirs.sort()
    files.sort()
    
    for d in sorted(dirs):
        full_path = os.path.join(root, d)
        # Build path relative to parent: /odm/bin/hw
        rel = os.path.join(root, d).replace(os.path.dirname(odm_dir), '').replace('\\', '/')
        if not rel.startswith('/'):
            rel = '/' + rel
        escaped = str_to_selinux(rel)
        
        if escaped not in merged:
            ctx = get_dir_context(rel)
            merged[escaped] = ctx
            add_count += 1
    
    for f in sorted(files):
        full_path = os.path.join(root, f)
        rel = os.path.join(root, f).replace(os.path.dirname(odm_dir), '').replace('\\', '/')
        if not rel.startswith('/'):
            rel = '/' + rel
        escaped = str_to_selinux(rel)
        
        if escaped not in merged:
            ctx = get_oplus_context(rel, f)
            merged[escaped] = ctx
            add_count += 1

# ==== PHASE 4: Write sorted file_contexts ====
with open(out_file, 'w', newline='\n') as fh:
    for path in sorted(merged.keys()):
        fh.write(f"{path} {merged[path]}\n")

print(f"Context complete: {len(base_contexts)} existing + {add_count} new = {len(merged)} total entries")

# ==== PHASE 5: Generate fs_config (MIO-KITCHEN fspatch approach) ====
# fs_config format: path uid gid mode [capabilities] [link_target]
fs_config_file = sys.argv[4] if len(sys.argv) > 4 else ""
if fs_config_file:
    print(f"Generating fs_config: {fs_config_file}")
    
    # Load existing fs_config as base
    base_fs = {}
    orig_fs_file = fs_config_file + ".orig"
    if os.path.isfile(orig_fs_file):
        with open(orig_fs_file, 'r', encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                parts = line.split()
                if len(parts) >= 4:
                    base_fs[parts[0]] = parts[1:]
        print(f"Loaded {len(base_fs)} existing fs_config entries")
    
    # Walk filesystem and generate entries for ALL files
    fs_entries = dict(base_fs)
    fs_add = 0
    
    # Static base entries
    if '/' not in fs_entries:
        fs_entries['/'] = ['0', '0', '0755']
    if 'odm' not in fs_entries:
        fs_entries['odm'] = ['0', '2000', '0755']
    
    for root, dirs, files in os.walk(odm_dir):
        dirs.sort()
        files.sort()
        
        for d in sorted(dirs):
            full_path = os.path.join(root, d)
            # fs_config uses paths like: odm/bin/hw (NO leading slash)
            rel = full_path.replace(os.path.dirname(odm_dir), '').replace('\\', '/').lstrip('/')
            
            if rel not in fs_entries:
                # Directories: 0 gid 0755
                gid = '2000' if '/bin' in rel else '0'
                fs_entries[rel] = ['0', gid, '0755']
                fs_add += 1
        
        for f in sorted(files):
            full_path = os.path.join(root, f)
            rel = full_path.replace(os.path.dirname(odm_dir), '').replace('\\', '/').lstrip('/')
            
            if rel not in fs_entries:
                # Files: determine mode based on path
                if '/bin/' in rel or '/bin' == rel.rsplit('/', 1)[0]:
                    # Executables
                    gid = '2000'
                    mode = '0750' if f.endswith('.sh') else '0755'
                elif f.endswith('.sh'):
                    gid = '0'
                    mode = '0750'
                else:
                    gid = '0'
                    mode = '0644'
                fs_entries[rel] = ['0', gid, mode]
                fs_add += 1
    
    # Write sorted fs_config
    with open(fs_config_file, 'w', newline='\n') as fh:
        for path in sorted(fs_entries.keys()):
            fh.write(f"{path} {' '.join(fs_entries[path])}\n")
    
    print(f"fs_config complete: {len(base_fs)} existing + {fs_add} new = {len(fs_entries)} total entries")
PYEOF

# Back up existing fs_config if it exists
if [ -f "$XIAOMI_FS_CONFIG" ] && [ -s "$XIAOMI_FS_CONFIG" ]; then
    log_info "Found existing Xiaomi fs_config ($(wc -l < "$XIAOMI_FS_CONFIG") entries)"
    cp "$XIAOMI_FS_CONFIG" "$XIAOMI_FS_CONFIG.orig"
fi

# Run with optional original contexts file + fs_config output
if [ -f "$XIAOMI_CONTEXTS.orig" ]; then
    python3 "$WORK_DIR/context_gen.py" "$XIAOMI_ODM_DIR" "$XIAOMI_CONTEXTS" "$XIAOMI_CONTEXTS.orig" "$XIAOMI_FS_CONFIG"
else
    python3 "$WORK_DIR/context_gen.py" "$XIAOMI_ODM_DIR" "$XIAOMI_CONTEXTS" "" "$XIAOMI_FS_CONFIG"
fi

# Verify contexts were generated properly
if [ -f "$XIAOMI_CONTEXTS" ]; then
    CTX_LINES=$(wc -l < "$XIAOMI_CONTEXTS")
    log_success "Context generation complete: $CTX_LINES entries"
    if [ "$CTX_LINES" -lt 50 ]; then
        log_warning "Context file seems too small ($CTX_LINES entries)! Check for errors."
    fi
else
    log_error "Context generation FAILED — no output file!"
fi

# Verify fs_config
if [ -f "$XIAOMI_FS_CONFIG" ]; then
    FS_LINES=$(wc -l < "$XIAOMI_FS_CONFIG")
    log_success "fs_config generation complete: $FS_LINES entries"
else
    log_warning "fs_config not generated — mkfs.erofs will use defaults"
fi

rm -f "$WORK_DIR/context_gen.py" "$XIAOMI_CONTEXTS.orig" "$XIAOMI_FS_CONFIG.orig"


# =========================================================
#  9. REPACK ODM IMAGE
# =========================================================
log_step "📦 Repacking patched Xiaomi ODM..."
tg_progress "📦 Repacking ODM image..."

PATCHED_ODM="$OUTPUT_DIR/odm.img"

# Calculate the size needed
ODM_SIZE=$(du -sb "$XIAOMI_ODM_DIR" | cut -f1)
# Add 10% headroom
ODM_SIZE=$((ODM_SIZE + ODM_SIZE / 10))
log_info "ODM dir size: $(du -sh "$XIAOMI_ODM_DIR" | cut -f1), allocating $(numfmt --to=iec $ODM_SIZE)"

# Try mkfs.erofs first (most Xiaomi devices use EROFS)
# Try bundled mkfs.erofs first (has libselinux + fs-config support)
MKFS_BIN="$SCRIPT_DIR/bin/mkfs.erofs"
if [ -f "$MKFS_BIN" ]; then
    chmod +x "$MKFS_BIN" 2>/dev/null
    log_info "Using bundled mkfs.erofs (with libselinux)..."
    MKFS_CMD="$MKFS_BIN"
elif command -v mkfs.erofs &>/dev/null; then
    log_info "Using system mkfs.erofs..."
    MKFS_CMD="mkfs.erofs"
else
    log_error "mkfs.erofs not found!"
    MKFS_CMD=""
fi

if [ -n "$MKFS_CMD" ]; then
    log_info "Repacking with mkfs.erofs..."
    tg_progress "📦 Repacking ODM (mkfs.erofs)..."
    EROFS_VER=$($MKFS_CMD --version 2>&1 | head -1 || echo "unknown")
    log_info "mkfs.erofs version: $EROFS_VER"

    # Build args — MIO-KITCHEN pattern
    EROFS_ARGS="-zlz4hc,9 -T 1230768000 --mount-point=/odm"
    
    # file-contexts (SELinux labels)
    if [ -f "$XIAOMI_CONTEXTS" ] && [ -s "$XIAOMI_CONTEXTS" ]; then
        EROFS_ARGS="$EROFS_ARGS --file-contexts=$XIAOMI_CONTEXTS"
        log_info "Using file_contexts: $XIAOMI_CONTEXTS ($(wc -l < "$XIAOMI_CONTEXTS") entries)"
    fi

    # fs-config (ownership + permissions)
    if [ -f "$XIAOMI_FS_CONFIG" ] && [ -s "$XIAOMI_FS_CONFIG" ]; then
        EROFS_ARGS="$EROFS_ARGS --fs-config-file=$XIAOMI_FS_CONFIG"
        log_info "Using fs_config: $XIAOMI_FS_CONFIG ($(wc -l < "$XIAOMI_FS_CONFIG") entries)"
    fi



    log_info "EROFS args: $EROFS_ARGS"

    $MKFS_CMD $EROFS_ARGS \
        "$PATCHED_ODM" \
        "$XIAOMI_ODM_DIR" 2>&1 | tail -5

    if [ ! -f "$PATCHED_ODM" ] || [ ! -s "$PATCHED_ODM" ]; then
        log_warning "Repack failed with full args, retrying minimal..."
        rm -f "$PATCHED_ODM"
        $MKFS_CMD -zlz4hc \
            --mount-point=/odm \
            "$PATCHED_ODM" \
            "$XIAOMI_ODM_DIR" 2>&1 | tail -5
    fi

    if [ -f "$PATCHED_ODM" ] && [ -s "$PATCHED_ODM" ]; then
        log_success "ODM repacked with EROFS: $(du -h "$PATCHED_ODM" | cut -f1)"
    fi
fi

if [ ! -f "$PATCHED_ODM" ] || [ ! -s "$PATCHED_ODM" ]; then
    log_error "Failed to repack ODM image"
    tg_send "❌ *ODM Patch Failed*\nCould not repack ODM image."
    exit 1
fi

# Sanity check: image must be at least 1MB (4KB = mkfs abort stub)
PATCHED_SIZE=$(stat -c%s "$PATCHED_ODM" 2>/dev/null || echo 0)
if [ "$PATCHED_SIZE" -lt 1048576 ]; then
    log_error "ODM image is only $(numfmt --to=iec $PATCHED_SIZE) — mkfs.erofs likely aborted!"
    log_error "This usually means --fs-config-file is missing entries for injected files."
    tg_send "❌ *ODM Patch Failed*\nRepack produced a ${PATCHED_SIZE}B stub image (expected >1MB)."
    exit 1
fi

log_success "Patched ODM image ready: $(du -h "$PATCHED_ODM" | cut -f1)"

# Free disk: delete Xiaomi ODM project (only the repacked image is needed now)
log_info "Deleting Xiaomi ODM project to free disk..."
rm -rf "$XIAOMI_PROJECT"
log_disk

# =========================================================
#  10. VENDOR FSTAB PATCH (AVB removal + ext4 fallback)
# =========================================================
VENDOR_DIR=""
VENDOR_CONFIG=""
PATCHED_VENDOR="$OUTPUT_DIR/vendor.img"

if [ -n "$XIAOMI_VENDOR_IMG" ] && [ -f "$XIAOMI_VENDOR_IMG" ]; then
    if check_disk_threshold 3; then
        log_step "🔧 Patching Xiaomi vendor fstab..."
        tg_progress "🔧 Patching vendor fstab..."

        VENDOR_DIR="$WORK_DIR/vendor_project/vendor"
        VENDOR_CONFIG="$WORK_DIR/vendor_project"
        mkdir -p "$VENDOR_CONFIG"

        unpack_partition "$XIAOMI_VENDOR_IMG" "$VENDOR_DIR" "Xiaomi vendor" "$VENDOR_CONFIG"
        rm -f "$XIAOMI_VENDOR_IMG"

        if [ -d "$VENDOR_DIR" ] && [ "$(ls -A "$VENDOR_DIR" 2>/dev/null)" ]; then
            # Save original vendor contexts + fs_config
            if [ -f "$VENDOR_CONFIG/config/vendor_file_contexts" ]; then
                cp "$VENDOR_CONFIG/config/vendor_file_contexts" "$VENDOR_CONFIG/config/vendor_file_contexts.orig"
            fi
            if [ -f "$VENDOR_CONFIG/config/vendor_fs_config" ]; then
                cp "$VENDOR_CONFIG/config/vendor_fs_config" "$VENDOR_CONFIG/config/vendor_fs_config.orig"
            fi

            # --- FSTAB PATCHER (AVB removal + ext4 fallback, NO decrypt removal) ---
            FSTAB_PATCHED=0
            while IFS= read -r -d '' fstab_file; do
                log_info "Patching fstab: $(basename "$fstab_file")"
                python3 - "$fstab_file" << 'FSTAB_PY'
import sys, re, os

fstab_path = sys.argv[1]
try:
    with open(fstab_path, 'r', encoding='utf-8') as f:
        lines = f.readlines()
except UnicodeDecodeError:
    with open(fstab_path, 'r', encoding='latin-1') as f:
        lines = f.readlines()

output = []
changes = 0
# Logical partitions that get ext4 fallback
LOGICAL_PARTS = {'system', 'system_ext', 'product', 'vendor', 'odm', 'system_dlkm', 'vendor_dlkm'}

for line in lines:
    stripped = line.strip()
    # Skip comments and empty lines
    if not stripped or stripped.startswith('#'):
        output.append(line)
        continue

    cols = stripped.split()
    if len(cols) < 5:
        output.append(line)
        continue

    src, mnt, fstype, mntopts, fsmgr = cols[0], cols[1], cols[2], cols[3], cols[4]

    # --- OPERATION 1: Remove AVB flags from fs_mgr_flags ---
    orig_fsmgr = fsmgr
    # Remove avb=vbmeta_system, avb=vbmeta, avb_keys=<path>
    fsmgr = re.sub(r',?avb=vbmeta_system', '', fsmgr)
    fsmgr = re.sub(r',?avb=vbmeta', '', fsmgr)
    fsmgr = re.sub(r',?avb_keys=[^,]*', '', fsmgr)
    # Remove standalone verify and avb (word boundaries)
    fsmgr = re.sub(r',?(?<![a-z_])verify(?![a-z_])', '', fsmgr)
    fsmgr = re.sub(r',?(?<![a-z_])avb(?![a-z_=])', '', fsmgr)
    # Clean up dangling commas
    fsmgr = re.sub(r'^,+', '', fsmgr)
    fsmgr = re.sub(r',+$', '', fsmgr)
    fsmgr = re.sub(r',{2,}', ',', fsmgr)
    if not fsmgr:
        fsmgr = 'defaults'

    if fsmgr != orig_fsmgr:
        changes += 1

    # Reconstruct line with proper spacing
    new_line = f"{src:<56}{mnt:<23}{fstype:<8}{mntopts:<53}{fsmgr}\n"
    output.append(new_line)

    # --- OPERATION 2: Add ext4 fallback for erofs logical partitions ---
    part_name = src.strip()
    if fstype == 'erofs' and part_name in LOGICAL_PARTS:
        ext4_opts = 'ro,barrier=1,discard'
        ext4_line = f"{src:<56}{mnt:<23}{'ext4':<8}{ext4_opts:<53}{fsmgr}\n"
        # Only add if not already followed by an ext4 line for same mount
        output.append(ext4_line)
        changes += 1

if changes > 0:
    with open(fstab_path, 'w', encoding='utf-8', newline='\n') as f:
        f.writelines(output)
    print(f"Patched {changes} entries in {os.path.basename(fstab_path)}")
else:
    print(f"No changes needed in {os.path.basename(fstab_path)}")
FSTAB_PY
                FSTAB_PATCHED=$((FSTAB_PATCHED + 1))
            done < <(find "$VENDOR_DIR" -name "fstab*" -type f -print0 2>/dev/null)

            if [ "$FSTAB_PATCHED" -gt 0 ]; then
                log_success "Vendor fstab patch complete ($FSTAB_PATCHED files patched)"
            else
                log_warning "No fstab files found in vendor"
            fi

            # --- REPACK VENDOR ---
            log_info "Repacking vendor.img..."
            VENDOR_CONTEXTS="$VENDOR_CONFIG/config/vendor_file_contexts"
            VENDOR_FS_CFG="$VENDOR_CONFIG/config/vendor_fs_config"

            MKFS_BIN="$SCRIPT_DIR/bin/mkfs.erofs"
            [ ! -f "$MKFS_BIN" ] && MKFS_BIN="mkfs.erofs"

            V_ARGS="-zlz4hc,9 -T 1230768000 --mount-point=/vendor"
            [ -f "$VENDOR_CONTEXTS" ] && [ -s "$VENDOR_CONTEXTS" ] && \
                V_ARGS="$V_ARGS --file-contexts=$VENDOR_CONTEXTS"
            [ -f "$VENDOR_FS_CFG" ] && [ -s "$VENDOR_FS_CFG" ] && \
                V_ARGS="$V_ARGS --fs-config-file=$VENDOR_FS_CFG"

            $MKFS_BIN $V_ARGS "$PATCHED_VENDOR" "$VENDOR_DIR" 2>&1 | tail -5

            V_SIZE=$(stat -c%s "$PATCHED_VENDOR" 2>/dev/null || echo 0)
            if [ "$V_SIZE" -gt 1048576 ]; then
                log_success "vendor.img repacked: $(du -h "$PATCHED_VENDOR" | cut -f1)"
                VENDOR_PATCH_OK=true
            else
                log_error "vendor.img repack failed (${V_SIZE}B)"
                rm -f "$PATCHED_VENDOR"
            fi
        else
            log_warning "Vendor unpack failed — skipping vendor fstab patch"
        fi

        # Cleanup vendor project
        rm -rf "$WORK_DIR/vendor_project"
        log_disk
    else
        log_warning "Disk too low for vendor patch — skipping"
    fi
else
    log_info "No Xiaomi vendor.img — vendor fstab patch skipped"
fi


# =========================================================
#  11. SYSTEM PARTITION MERGE (OPLUS my_* → system)
# =========================================================
if [ -n "$OPLUS_SYSTEM_IMG" ] && [ -f "$OPLUS_SYSTEM_IMG" ]; then
    if check_disk_threshold 5; then
        log_step "📦 Unpacking system partitions..."
        tg_progress "📦 Unpacking system partitions..."
        mkdir -p "$SYSTEM_PROJECT/config"

        # --- Unpack system.img ---
        unpack_partition "$OPLUS_SYSTEM_IMG" "$SYSTEM_PROJECT/system" "OPLUS system" "$SYSTEM_PROJECT"
        rm -f "$OPLUS_SYSTEM_IMG"

        if [ -d "$SYSTEM_PROJECT/system" ] && [ "$(ls -A "$SYSTEM_PROJECT/system" 2>/dev/null)" ]; then
            # Save original contexts
            [ -f "$SYSTEM_PROJECT/config/system_file_contexts" ] && \
                cp "$SYSTEM_PROJECT/config/system_file_contexts" "$SYSTEM_PROJECT/config/system_file_contexts.orig"
            [ -f "$SYSTEM_PROJECT/config/system_fs_config" ] && \
                cp "$SYSTEM_PROJECT/config/system_fs_config" "$SYSTEM_PROJECT/config/system_fs_config.orig"

            # --- Unpack system_ext.img ---
            if [ -n "$OPLUS_SYSTEM_EXT_IMG" ] && [ -f "$OPLUS_SYSTEM_EXT_IMG" ]; then
                unpack_partition "$OPLUS_SYSTEM_EXT_IMG" "$SYSTEM_PROJECT/system_ext" "OPLUS system_ext" "$SYSTEM_PROJECT"
                rm -f "$OPLUS_SYSTEM_EXT_IMG"
            fi

            # --- Unpack product.img ---
            if [ -n "$OPLUS_PRODUCT_IMG" ] && [ -f "$OPLUS_PRODUCT_IMG" ]; then
                unpack_partition "$OPLUS_PRODUCT_IMG" "$SYSTEM_PROJECT/product" "OPLUS product" "$SYSTEM_PROJECT"
                rm -f "$OPLUS_PRODUCT_IMG"
            fi

            log_disk

            # --- Merge my_* partitions into system (priority order) ---
            log_step "🔀 Merging my_* overlays into system..."
            tg_progress "🔀 Merging my_* overlays..."

            merge_my_partition "$OPLUS_MY_MANIFEST_IMG"    "my_manifest"    "$SYSTEM_PROJECT/system"
            merge_my_partition "$OPLUS_MY_STOCK_IMG"       "my_stock"       "$SYSTEM_PROJECT/system"
            merge_my_partition "$OPLUS_MY_HEYTAP_IMG"      "my_heytap"      "$SYSTEM_PROJECT/system"
            merge_my_partition "$OPLUS_MY_CARRIER_IMG"     "my_carrier"     "$SYSTEM_PROJECT/system"
            merge_my_partition "$OPLUS_MY_REGION_IMG"      "my_region"      "$SYSTEM_PROJECT/system"
            merge_my_partition "$OPLUS_MY_BIGBALL_IMG"     "my_bigball"     "$SYSTEM_PROJECT/system"
            merge_my_partition "$OPLUS_MY_ENGINEERING_IMG" "my_engineering" "$SYSTEM_PROJECT/system"
            merge_my_partition "$OPLUS_MY_PRODUCT_IMG"     "my_product"     "$SYSTEM_PROJECT/system"

            # --- System context + fs_config generation ---
            log_step "🏷️  Generating system file_contexts + fs_config..."
            tg_progress "🏷️ Generating system contexts..."

            SYS_CONTEXTS="$SYSTEM_PROJECT/config/system_file_contexts"
            SYS_FS_CONFIG="$SYSTEM_PROJECT/config/system_fs_config"

            cat > "$WORK_DIR/system_context_gen.py" << 'SYSCTX_PY'
import os, sys, re
from re import escape as re_escape

system_dir    = sys.argv[1]
out_ctx       = sys.argv[2]
orig_ctx      = sys.argv[3] if len(sys.argv) > 3 else ""
out_fs        = sys.argv[4] if len(sys.argv) > 4 else ""
orig_fs       = sys.argv[5] if len(sys.argv) > 5 else ""
my_ctx_file   = sys.argv[6] if len(sys.argv) > 6 else ""

def str_to_selinux(s):
    if s.endswith('(/.*)?'):
        return s
    return re_escape(s).replace('\\-', '-')

# PHASE 1: Load base contexts
base = {}
for f in [orig_ctx, my_ctx_file]:
    if f and os.path.isfile(f):
        with open(f, 'r', encoding='utf-8', errors='replace') as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith('#'):
                    continue
                parts = line.split()
                if len(parts) >= 2:
                    base[parts[0]] = parts[1]
print(f"Loaded {len(base)} base context entries")

# PHASE 2: Context rules for new files
def get_ctx(rel, fname):
    if '/bin/' in rel or '/xbin/' in rel:
        return "u:object_r:system_file:s0"
    if '/lib/' in rel or '/lib64/' in rel:
        return "u:object_r:system_lib_file:s0"
    if fname.endswith('.apk'):
        return "u:object_r:system_app_file:s0"
    if '/priv-app/' in rel or '/app/' in rel:
        return "u:object_r:system_app_file:s0"
    if '/etc/' in rel:
        return "u:object_r:system_file:s0"
    return "u:object_r:system_file:s0"

def get_dir_ctx(rel):
    if '/lib' in rel:
        return "u:object_r:system_lib_file:s0"
    if '/app' in rel or '/priv-app' in rel:
        return "u:object_r:system_app_file:s0"
    return "u:object_r:system_file:s0"

# PHASE 3: Walk filesystem
merged = dict(base)
add_count = 0
part = os.path.basename(system_dir)

for path, ctx in [('/', 'u:object_r:system_file:s0'),
                   (f'/{part}', 'u:object_r:system_file:s0'),
                   (f'/{part}/', 'u:object_r:system_file:s0')]:
    if path not in merged:
        merged[path] = ctx

for root, dirs, files in os.walk(system_dir):
    dirs.sort(); files.sort()
    for d in sorted(dirs):
        rel = os.path.join(root, d).replace(os.path.dirname(system_dir), '').replace('\\', '/').lstrip('/')
        if not rel.startswith('/'):
            rel = '/' + rel
        esc = str_to_selinux(rel)
        if esc not in merged:
            merged[esc] = get_dir_ctx(rel)
            add_count += 1
    for f in sorted(files):
        rel = os.path.join(root, f).replace(os.path.dirname(system_dir), '').replace('\\', '/').lstrip('/')
        if not rel.startswith('/'):
            rel = '/' + rel
        esc = str_to_selinux(rel)
        if esc not in merged:
            merged[esc] = get_ctx(rel, f)
            add_count += 1

# PHASE 4: Write contexts
with open(out_ctx, 'w', newline='\n') as fh:
    for p in sorted(merged.keys()):
        fh.write(f"{p} {merged[p]}\n")
print(f"Contexts: {len(base)} base + {add_count} new = {len(merged)} total")

# PHASE 5: fs_config
if out_fs:
    base_fs = {}
    if orig_fs and os.path.isfile(orig_fs):
        with open(orig_fs, 'r', encoding='utf-8', errors='replace') as fh:
            for line in fh:
                parts = line.strip().split()
                if len(parts) >= 4:
                    base_fs[parts[0]] = parts[1:]
    fs = dict(base_fs)
    fs_add = 0
    if '/' not in fs: fs['/'] = ['0','0','0755']
    if part not in fs: fs[part] = ['0','2000','0755']
    for root, dirs, files in os.walk(system_dir):
        dirs.sort(); files.sort()
        for d in sorted(dirs):
            rel = os.path.join(root, d).replace(os.path.dirname(system_dir), '').replace('\\', '/').lstrip('/')
            if rel not in fs:
                gid = '2000' if '/bin' in rel else '0'
                fs[rel] = ['0', gid, '0755']
                fs_add += 1
        for f in sorted(files):
            rel = os.path.join(root, f).replace(os.path.dirname(system_dir), '').replace('\\', '/').lstrip('/')
            if rel not in fs:
                if '/bin/' in rel:
                    fs[rel] = ['0','2000','0750' if f.endswith('.sh') else '0755']
                else:
                    fs[rel] = ['0','0','0644']
                fs_add += 1
    with open(out_fs, 'w', newline='\n') as fh:
        for p in sorted(fs.keys()):
            fh.write(f"{p} {' '.join(fs[p])}\n")
    print(f"fs_config: {len(base_fs)} base + {fs_add} new = {len(fs)} total")
SYSCTX_PY

            python3 "$WORK_DIR/system_context_gen.py" \
                "$SYSTEM_PROJECT/system" \
                "$SYS_CONTEXTS" \
                "$SYSTEM_PROJECT/config/system_file_contexts.orig" \
                "$SYS_FS_CONFIG" \
                "$SYSTEM_PROJECT/config/system_fs_config.orig" \
                "$SYSTEM_PROJECT/config/my_combined_contexts.tmp"

            SYSTEM_USE_CONTEXTS=false
            if [ -f "$SYS_CONTEXTS" ] && [ -f "$SYS_FS_CONFIG" ]; then
                SYS_CTX_LINES=$(wc -l < "$SYS_CONTEXTS")
                SYS_FS_LINES=$(wc -l < "$SYS_FS_CONFIG")
                if [ "$SYS_CTX_LINES" -gt 100 ] && [ "$SYS_FS_LINES" -gt 100 ]; then
                    log_success "System file_contexts: $SYS_CTX_LINES entries"
                    log_success "System fs_config: $SYS_FS_LINES entries"
                    SYSTEM_USE_CONTEXTS=true
                else
                    log_warning "System contexts too small — will repack without"
                fi
            fi

            rm -f "$WORK_DIR/system_context_gen.py" \
                  "$SYSTEM_PROJECT/config/system_file_contexts.orig" \
                  "$SYSTEM_PROJECT/config/system_fs_config.orig" \
                  "$SYSTEM_PROJECT/config/my_combined_contexts.tmp"

            # --- Repack system.img ---
            log_step "📦 Repacking system images..."
            tg_progress "📦 Repacking system images..."

            MKFS_BIN="$SCRIPT_DIR/bin/mkfs.erofs"
            [ ! -f "$MKFS_BIN" ] && MKFS_BIN="mkfs.erofs"

            PATCHED_SYSTEM="$OUTPUT_DIR/system.img"
            S_ARGS="-zlz4hc,9 -T 1230768000 --mount-point=/system"
            if [ "$SYSTEM_USE_CONTEXTS" = true ]; then
                S_ARGS="$S_ARGS --file-contexts=$SYS_CONTEXTS"
                S_ARGS="$S_ARGS --fs-config-file=$SYS_FS_CONFIG"
            fi
            $MKFS_BIN $S_ARGS "$PATCHED_SYSTEM" "$SYSTEM_PROJECT/system" 2>&1 | tail -5

            S_SIZE=$(stat -c%s "$PATCHED_SYSTEM" 2>/dev/null || echo 0)
            if [ "$S_SIZE" -lt 10485760 ]; then
                log_warning "system.img too small (${S_SIZE}B) — retrying without contexts..."
                rm -f "$PATCHED_SYSTEM"
                $MKFS_BIN -zlz4hc,9 -T 1230768000 --mount-point=/system \
                    "$PATCHED_SYSTEM" "$SYSTEM_PROJECT/system" 2>&1 | tail -5
                S_SIZE=$(stat -c%s "$PATCHED_SYSTEM" 2>/dev/null || echo 0)
            fi

            if [ "$S_SIZE" -gt 10485760 ]; then
                log_success "system.img repacked: $(du -h "$PATCHED_SYSTEM" | cut -f1)"
                SYSTEM_MERGE_OK=true
            else
                log_error "system.img repack failed"
                rm -f "$PATCHED_SYSTEM"
            fi
            rm -rf "$SYSTEM_PROJECT/system"

            # --- Repack system_ext.img (unchanged, just repack) ---
            PATCHED_SYSTEM_EXT="$OUTPUT_DIR/system_ext.img"
            if [ -d "$SYSTEM_PROJECT/system_ext" ] && [ "$(ls -A "$SYSTEM_PROJECT/system_ext" 2>/dev/null)" ]; then
                E_ARGS="-zlz4hc,9 -T 1230768000 --mount-point=/system_ext"
                [ -f "$SYSTEM_PROJECT/config/system_ext_file_contexts" ] && \
                    E_ARGS="$E_ARGS --file-contexts=$SYSTEM_PROJECT/config/system_ext_file_contexts"
                [ -f "$SYSTEM_PROJECT/config/system_ext_fs_config" ] && \
                    E_ARGS="$E_ARGS --fs-config-file=$SYSTEM_PROJECT/config/system_ext_fs_config"
                $MKFS_BIN $E_ARGS "$PATCHED_SYSTEM_EXT" "$SYSTEM_PROJECT/system_ext" 2>&1 | tail -5

                E_SIZE=$(stat -c%s "$PATCHED_SYSTEM_EXT" 2>/dev/null || echo 0)
                if [ "$E_SIZE" -gt 1048576 ]; then
                    log_success "system_ext.img repacked: $(du -h "$PATCHED_SYSTEM_EXT" | cut -f1)"
                else
                    log_error "system_ext.img repack failed"
                    rm -f "$PATCHED_SYSTEM_EXT"
                fi
                rm -rf "$SYSTEM_PROJECT/system_ext"
            fi

            # --- Repack product.img (unchanged, just repack) ---
            PATCHED_PRODUCT="$OUTPUT_DIR/product.img"
            if [ -d "$SYSTEM_PROJECT/product" ] && [ "$(ls -A "$SYSTEM_PROJECT/product" 2>/dev/null)" ]; then
                P_ARGS="-zlz4hc,9 -T 1230768000 --mount-point=/product"
                [ -f "$SYSTEM_PROJECT/config/product_file_contexts" ] && \
                    P_ARGS="$P_ARGS --file-contexts=$SYSTEM_PROJECT/config/product_file_contexts"
                [ -f "$SYSTEM_PROJECT/config/product_fs_config" ] && \
                    P_ARGS="$P_ARGS --fs-config-file=$SYSTEM_PROJECT/config/product_fs_config"
                $MKFS_BIN $P_ARGS "$PATCHED_PRODUCT" "$SYSTEM_PROJECT/product" 2>&1 | tail -5

                P_SIZE=$(stat -c%s "$PATCHED_PRODUCT" 2>/dev/null || echo 0)
                if [ "$P_SIZE" -gt 1048576 ]; then
                    log_success "product.img repacked: $(du -h "$PATCHED_PRODUCT" | cut -f1)"
                else
                    log_error "product.img repack failed"
                    rm -f "$PATCHED_PRODUCT"
                fi
                rm -rf "$SYSTEM_PROJECT/product"
            fi

            rm -rf "$SYSTEM_PROJECT"
            log_disk
        else
            log_warning "System unpack failed — skipping system merge"
            rm -f "$OPLUS_SYSTEM_IMG" "$OPLUS_SYSTEM_EXT_IMG" "$OPLUS_PRODUCT_IMG"
        fi
    else
        log_warning "Disk too low for system merge — skipping"
        rm -f "$OPLUS_SYSTEM_IMG"
    fi
else
    log_info "No OPLUS system.img — system merge skipped"
fi

# Delete any remaining my_* images that weren't processed
rm -f "$OPLUS_MY_MANIFEST_IMG" "$OPLUS_MY_STOCK_IMG" "$OPLUS_MY_HEYTAP_IMG" \
      "$OPLUS_MY_CARRIER_IMG" "$OPLUS_MY_REGION_IMG" "$OPLUS_MY_BIGBALL_IMG" \
      "$OPLUS_MY_ENGINEERING_IMG" "$OPLUS_MY_PRODUCT_IMG" 2>/dev/null
log_disk

# =========================================================
#  12. CREATE ZIP FILES + UPLOAD
# =========================================================
log_step "☁️  Creating zips and uploading..."
tg_progress "☁️ Creating zips and uploading..."

# --- Upload helpers (all logging to stderr to avoid URL poisoning) ---
upload_pixeldrain() {
    local file="$1"
    local fname=$(basename "$file")
    local response=""

    if [ -n "$PIXELDRAIN_KEY" ]; then
        log_info "Uploading $fname to PixelDrain (authenticated)..." >&2
        response=$(curl -s -T "$file" \
            -u ":$PIXELDRAIN_KEY" \
            "https://pixeldrain.com/api/file/$fname")
    else
        log_info "Uploading $fname to PixelDrain (anonymous)..." >&2
        response=$(curl -s -T "$file" \
            "https://pixeldrain.com/api/file/$fname")
    fi

    local pd_id=$(echo "$response" | jq -r '.id // empty')
    if [ -n "$pd_id" ]; then
        echo "https://pixeldrain.com/u/$pd_id"
        return 0
    else
        log_error "PixelDrain failed: $(echo "$response" | jq -r '.message // .value // "unknown error"')" >&2
        return 1
    fi
}

upload_gofile() {
    local file="$1"
    log_info "Uploading $(basename "$file") to GoFile (fallback)..." >&2

    local server=$(curl -s "https://api.gofile.io/servers" | jq -r '.data.servers[0].name // "store1"')
    local response=$(curl -s -F "file=@$file" "https://${server}.gofile.io/contents/uploadfile")
    local dl_url=$(echo "$response" | jq -r '.data.downloadPage // empty')

    if [ -n "$dl_url" ]; then
        echo "$dl_url"
        return 0
    else
        log_error "GoFile failed: $response" >&2
        return 1
    fi
}

# --- Create ZIP files ---
cd "$OUTPUT_DIR"

# ZIP 1: ODM + Vendor (always includes odm.img, conditionally includes vendor.img)
ODM_ZIP_FILES="odm.img"
[ "$VENDOR_PATCH_OK" = true ] && [ -f "vendor.img" ] && ODM_ZIP_FILES="$ODM_ZIP_FILES vendor.img"
zip -0 odm_patched.zip $ODM_ZIP_FILES 2>/dev/null
ODM_ZIP_SIZE=$(du -h "odm_patched.zip" 2>/dev/null | cut -f1)
log_success "Created odm_patched.zip: $ODM_ZIP_SIZE (contains: $ODM_ZIP_FILES)"

# ZIP 2: System images (only if system merge succeeded)
SYSTEM_ZIP_OK=false
SYSTEM_ZIP_FILES=""
[ -f "system.img" ] && SYSTEM_ZIP_FILES="$SYSTEM_ZIP_FILES system.img"
[ -f "system_ext.img" ] && SYSTEM_ZIP_FILES="$SYSTEM_ZIP_FILES system_ext.img"
[ -f "product.img" ] && SYSTEM_ZIP_FILES="$SYSTEM_ZIP_FILES product.img"

if [ -n "$SYSTEM_ZIP_FILES" ]; then
    zip -0 system_patched.zip $SYSTEM_ZIP_FILES 2>/dev/null
    SYS_ZIP_SIZE=$(du -h "system_patched.zip" 2>/dev/null | cut -f1)
    log_success "Created system_patched.zip: $SYS_ZIP_SIZE"
    SYSTEM_ZIP_OK=true
else
    log_info "No system images to zip — system_patched.zip not created"
fi

# Remove loose .img files (zips are the deliverables)
rm -f odm.img vendor.img system.img system_ext.img product.img
cd "$WORK_DIR"

# --- Upload ODM zip ---
ODM_UPLOAD_LINK=$(upload_pixeldrain "$OUTPUT_DIR/odm_patched.zip") || \
ODM_UPLOAD_LINK=$(upload_gofile "$OUTPUT_DIR/odm_patched.zip") || \
ODM_UPLOAD_LINK="UPLOAD_FAILED"

[ "$ODM_UPLOAD_LINK" != "UPLOAD_FAILED" ] && log_success "ODM zip uploaded: $ODM_UPLOAD_LINK"

# --- Upload System zip ---
SYSTEM_UPLOAD_LINK="NOT_CREATED"
if [ "$SYSTEM_ZIP_OK" = true ]; then
    SYSTEM_UPLOAD_LINK=$(upload_pixeldrain "$OUTPUT_DIR/system_patched.zip") || \
    SYSTEM_UPLOAD_LINK=$(upload_gofile "$OUTPUT_DIR/system_patched.zip") || \
    SYSTEM_UPLOAD_LINK="UPLOAD_FAILED"

    [ "$SYSTEM_UPLOAD_LINK" != "UPLOAD_FAILED" ] && log_success "System zip uploaded: $SYSTEM_UPLOAD_LINK"
fi

# --- Upload tool itself (best-effort) ---
TOOL_UPLOAD_LINK=""
if [ -f "$SCRIPT_DIR/oplus_odm_patcher.sh" ]; then
    TOOL_UPLOAD_LINK=$(upload_pixeldrain "$SCRIPT_DIR/oplus_odm_patcher.sh") || \
    TOOL_UPLOAD_LINK=""
    [ -n "$TOOL_UPLOAD_LINK" ] && log_success "Tool uploaded: $TOOL_UPLOAD_LINK"
fi

# =========================================================
#  13. CLEANUP
# =========================================================
log_step "🧹 Cleaning up..."

rm -rf "$OPLUS_PROJECT" "$XIAOMI_PROJECT" "$SYSTEM_PROJECT" "$OPLUS_DL" "$XIAOMI_DL" \
       "$WORK_DIR/vendor_project" "$STAGING_DIR" 2>/dev/null

SCRIPT_END=$(date +%s)
ELAPSED=$((SCRIPT_END - SCRIPT_START))
ELAPSED_MIN=$((ELAPSED / 60))
ELAPSED_SEC=$((ELAPSED % 60))

# =========================================================
#  14. FINAL TELEGRAM NOTIFICATION
# =========================================================
log_step "📤 Sending result..."

if [ "$ODM_UPLOAD_LINK" != "UPLOAD_FAILED" ] || { [ "$SYSTEM_UPLOAD_LINK" != "UPLOAD_FAILED" ] && [ "$SYSTEM_UPLOAD_LINK" != "NOT_CREATED" ]; }; then
    FINAL_MSG="✅ *OPLUS ODM Patcher Complete*

📦 *ODM Files Injected:* \`$INJECT_COUNT\`
⏱ *Time:* ${ELAPSED_MIN}m ${ELAPSED_SEC}s

📥 *Downloads:*"

    if [ "$ODM_UPLOAD_LINK" != "UPLOAD_FAILED" ]; then
        FINAL_MSG="$FINAL_MSG
[📱 ODM Patched](${ODM_UPLOAD_LINK})"
        if [ "$VENDOR_PATCH_OK" = true ]; then
            FINAL_MSG="$FINAL_MSG (odm + vendor with AVB-disabled fstab)"
        fi
    fi

    if [ "$SYSTEM_UPLOAD_LINK" != "NOT_CREATED" ] && [ "$SYSTEM_UPLOAD_LINK" != "UPLOAD_FAILED" ]; then
        FINAL_MSG="$FINAL_MSG
[🗂 System Patched](${SYSTEM_UPLOAD_LINK}) (system + system ext + product)"
    elif [ "$SYSTEM_ZIP_OK" = true ] && [ "$SYSTEM_UPLOAD_LINK" = "UPLOAD_FAILED" ]; then
        FINAL_MSG="$FINAL_MSG
⚠️ System zip upload failed"
    fi

    if [ -n "$TOOL_UPLOAD_LINK" ]; then
        FINAL_MSG="$FINAL_MSG
[🔧 OPLUS HyperOS Modder Tool](${TOOL_UPLOAD_LINK})"
    fi

    FINAL_MSG="$FINAL_MSG

Xiaomi ODM patched with OPLUS HALs.
System merged with OPLUS overlays."
else
    FINAL_MSG="⚠️ *Patcher Finished — All Uploads Failed*
⏱ Time: ${ELAPSED_MIN}m ${ELAPSED_SEC}s
Check runner logs for details."
fi

tg_send "$FINAL_MSG"

log_success "=== OPLUS ODM PATCHER COMPLETE ==="
log_info "Injected: $INJECT_COUNT files | Time: ${ELAPSED_MIN}m ${ELAPSED_SEC}s"
[ "$ODM_UPLOAD_LINK" != "UPLOAD_FAILED" ] && log_info "ODM: $ODM_UPLOAD_LINK"
[ "$SYSTEM_UPLOAD_LINK" != "UPLOAD_FAILED" ] && [ "$SYSTEM_UPLOAD_LINK" != "NOT_CREATED" ] && \
    log_info "System: $SYSTEM_UPLOAD_LINK"

exit 0
