#!/bin/bash
# =========================================================
#  OPLUS ODM PATCHER — Inject OnePlus HALs into Xiaomi ODM
#  Usage: ./oplus_odm_patcher.sh <OPLUS_OTA_URL> <XIAOMI_OTA_URL>
# =========================================================

set +e

SCRIPT_START=$(date +%s)

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
OUTPUT_DIR="$WORK_DIR/odm_output"

mkdir -p "$BIN_DIR" "$OPLUS_DL" "$XIAOMI_DL" "$OPLUS_PROJECT" "$XIAOMI_PROJECT" "$OUTPUT_DIR"
export PATH="$BIN_DIR:$PATH"

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

# =========================================================
#  2. DOWNLOAD BOTH OTAs
# =========================================================
log_step "📥 Downloading OTAs..."
tg_progress "📥 Downloading OPLUS OTA..."

log_info "Downloading OPLUS OTA..."
aria2c -x 16 -s 16 --allow-overwrite=true -d "$OPLUS_DL" -o "oplus_ota.zip" "$OPLUS_URL" 2>&1 | tail -1
if [ ! -f "$OPLUS_DL/oplus_ota.zip" ]; then
    log_error "Failed to download OPLUS OTA"
    tg_send "❌ *ODM Patch Failed*\nCould not download OPLUS OTA."
    exit 1
fi
log_success "OPLUS OTA downloaded"

tg_progress "📥 Downloading Xiaomi OTA..."

log_info "Downloading Xiaomi OTA..."
aria2c -x 16 -s 16 --allow-overwrite=true -d "$XIAOMI_DL" -o "xiaomi_ota.zip" "$XIAOMI_URL" 2>&1 | tail -1
if [ ! -f "$XIAOMI_DL/xiaomi_ota.zip" ]; then
    log_error "Failed to download Xiaomi OTA"
    tg_send "❌ *ODM Patch Failed*\nCould not download Xiaomi OTA."
    exit 1
fi
log_success "Xiaomi OTA downloaded"

# =========================================================
#  3. EXTRACT ODM IMAGES FROM PAYLOAD
# =========================================================
log_step "📦 Extracting ODM images from payloads..."
tg_progress "📦 Extracting ODM from payloads..."

# OPLUS
log_info "Extracting OPLUS payload.bin..."
cd "$OPLUS_DL"
unzip -o -q oplus_ota.zip payload.bin 2>/dev/null || 7z e -y oplus_ota.zip payload.bin >/dev/null 2>&1
if [ ! -f "payload.bin" ]; then
    log_error "No payload.bin in OPLUS OTA"
    tg_send "❌ *ODM Patch Failed*\nNo payload.bin found in OPLUS OTA."
    exit 1
fi

log_info "Dumping OPLUS odm.img..."
payload-dumper-go -p odm -o "$OPLUS_DL" payload.bin
OPLUS_ODM=$(find "$OPLUS_DL" -name "odm.img" -print -quit)
if [ -z "$OPLUS_ODM" ] || [ ! -f "$OPLUS_ODM" ]; then
    log_error "Failed to extract OPLUS odm.img"
    tg_send "❌ *ODM Patch Failed*\nCould not extract OPLUS odm.img from payload."
    exit 1
fi
log_success "OPLUS odm.img extracted: $(du -h "$OPLUS_ODM" | cut -f1)"

# Cleanup OPLUS payload
rm -f "$OPLUS_DL/payload.bin" "$OPLUS_DL/oplus_ota.zip"

# XIAOMI
log_info "Extracting Xiaomi payload.bin..."
cd "$XIAOMI_DL"
unzip -o -q xiaomi_ota.zip payload.bin 2>/dev/null || 7z e -y xiaomi_ota.zip payload.bin >/dev/null 2>&1
if [ ! -f "payload.bin" ]; then
    log_error "No payload.bin in Xiaomi OTA"
    tg_send "❌ *ODM Patch Failed*\nNo payload.bin found in Xiaomi OTA."
    exit 1
fi

log_info "Dumping Xiaomi odm.img..."
payload-dumper-go -p odm -o "$XIAOMI_DL" payload.bin
XIAOMI_ODM=$(find "$XIAOMI_DL" -name "odm.img" -print -quit)
if [ -z "$XIAOMI_ODM" ] || [ ! -f "$XIAOMI_ODM" ]; then
    log_error "Failed to extract Xiaomi odm.img"
    tg_send "❌ *ODM Patch Failed*\nCould not extract Xiaomi odm.img from payload."
    exit 1
fi
log_success "Xiaomi odm.img extracted: $(du -h "$XIAOMI_ODM" | cut -f1)"

# Cleanup Xiaomi payload
rm -f "$XIAOMI_DL/payload.bin" "$XIAOMI_DL/xiaomi_ota.zip"

cd "$WORK_DIR"

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

    # Try extract.erofs first (produces odm/ + config/)
    if [ -f "$BIN_DIR/extract.erofs" ]; then
        log_info "Unpacking $label with extract.erofs..."
        cd "$project_dir"
        "$BIN_DIR/extract.erofs" -i "$img" -x -o . 2>&1 | tail -5

        # extract.erofs puts files in odm/ and config in config/
        if [ -d "$project_dir/odm" ] && [ "$(ls -A $project_dir/odm 2>/dev/null)" ]; then
            log_success "$label unpacked with extract.erofs"
            cd "$WORK_DIR"
            return 0
        fi
    fi

    # Fallback: fsck.erofs --extract
    log_info "Trying fsck.erofs for $label..."
    mkdir -p "$project_dir/odm"
    fsck.erofs --extract="$project_dir/odm" "$img" 2>&1 | tail -3

    if [ "$(ls -A $project_dir/odm 2>/dev/null)" ]; then
        log_success "$label unpacked with fsck.erofs"
        # fsck.erofs doesn't produce config/, we generate file_contexts from the image
        mkdir -p "$project_dir/config"
        # Dump file_contexts from EROFS extended attributes if possible
        log_warning "config/odm_file_contexts may need manual population for $label"
        cd "$WORK_DIR"
        return 0
    fi

    # Fallback: erofsfuse mount
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

# Delete raw .img files now — free disk space
rm -f "$OPLUS_ODM" "$XIAOMI_ODM"

OPLUS_ODM_DIR="$OPLUS_PROJECT/odm"
XIAOMI_ODM_DIR="$XIAOMI_PROJECT/odm"
OPLUS_CONFIG="$OPLUS_PROJECT/config"
XIAOMI_CONFIG="$XIAOMI_PROJECT/config"

log_info "OPLUS ODM contents: $(ls "$OPLUS_ODM_DIR" 2>/dev/null | tr '\n' ' ')"
log_info "Xiaomi ODM contents: $(ls "$XIAOMI_ODM_DIR" 2>/dev/null | tr '\n' ' ')"

# =========================================================
#  5. HAL INJECTION ENGINE
# =========================================================
log_step "💉 Injecting OPLUS HALs into Xiaomi ODM..."
tg_progress "💉 Injecting OPLUS HALs..."

INJECT_COUNT=0
INJECT_ERRORS=0

# Helper: copy a file/dir from OPLUS to Xiaomi, preserving permissions
inject_file() {
    local src="$1"
    local dst="$2"

    if [ -d "$src" ]; then
        mkdir -p "$dst"
        cp -a "$src/"* "$dst/" 2>/dev/null
        local count=$(find "$src" -type f | wc -l)
        INJECT_COUNT=$((INJECT_COUNT + count))
        log_success "  ✓ Injected dir: $(basename "$src") ($count files)"
    elif [ -f "$src" ]; then
        mkdir -p "$(dirname "$dst")"
        cp -a "$src" "$dst" 2>/dev/null
        INJECT_COUNT=$((INJECT_COUNT + 1))
        log_success "  ✓ Injected: $(basename "$src")"
    else
        log_warning "  ✗ Not found: $src"
        INJECT_ERRORS=$((INJECT_ERRORS + 1))
    fi
}

# --- bin/hw/ — HAL service binaries ---
log_info "Injecting HAL binaries (bin/hw)..."
if [ -d "$OPLUS_ODM_DIR/bin/hw" ]; then
    for hal_bin in "$OPLUS_ODM_DIR/bin/hw/"*; do
        [ -f "$hal_bin" ] || continue
        fname=$(basename "$hal_bin")
        # Only inject oplus/vendor.oplus related binaries
        case "$fname" in
            *oplus*|*oppo*|vendor-oplus*|vendor.oplus*|android.hardware.power.stats*)
                inject_file "$hal_bin" "$XIAOMI_ODM_DIR/bin/hw/$fname"
                ;;
        esac
    done
fi

# --- bin/ — Shell scripts and standalone binaries ---
log_info "Injecting bin/ scripts..."
BIN_INJECT_LIST="
oplus_performance.sh
"
for item in $BIN_INJECT_LIST; do
    if [ -f "$OPLUS_ODM_DIR/bin/$item" ]; then
        inject_file "$OPLUS_ODM_DIR/bin/$item" "$XIAOMI_ODM_DIR/bin/$item"
    fi
done

# --- lib/ — 32-bit shared libraries ---
log_info "Injecting lib/ (32-bit)..."
if [ -d "$OPLUS_ODM_DIR/lib" ]; then
    for lib_file in "$OPLUS_ODM_DIR/lib/"*.so; do
        [ -f "$lib_file" ] || continue
        fname=$(basename "$lib_file")
        case "$fname" in
            *oplus*|*oppo*|*osense*|*Gaia*|*charger*|*olc*|*performance*|*powermonitor*|*handlefactory*|*stability*)
                inject_file "$lib_file" "$XIAOMI_ODM_DIR/lib/$fname"
                ;;
        esac
    done
fi

# --- lib64/ — 64-bit shared libraries ---
log_info "Injecting lib64/ (64-bit)..."
if [ -d "$OPLUS_ODM_DIR/lib64" ]; then
    for lib_file in "$OPLUS_ODM_DIR/lib64/"*.so; do
        [ -f "$lib_file" ] || continue
        fname=$(basename "$lib_file")
        case "$fname" in
            *oplus*|*oppo*|*osense*|*Gaia*|*charger*|*olc*|*performance*|*powermonitor*|*handlefactory*|*stability*)
                inject_file "$lib_file" "$XIAOMI_ODM_DIR/lib64/$fname"
                ;;
        esac
    done
fi

# --- etc/init/ — Init RC scripts for HALs ---
log_info "Injecting etc/init/ RC scripts..."
if [ -d "$OPLUS_ODM_DIR/etc/init" ]; then
    for rc_file in "$OPLUS_ODM_DIR/etc/init/"*.rc; do
        [ -f "$rc_file" ] || continue
        fname=$(basename "$rc_file")
        case "$fname" in
            *oplus*|*oppo*|*charger*|*performance*|*powermonitor*|*olc*|*stability*|*power.stats*)
                inject_file "$rc_file" "$XIAOMI_ODM_DIR/etc/init/$fname"
                ;;
        esac
    done
fi

# --- etc/vintf/manifest/ — VINTF HAL manifests ---
log_info "Injecting etc/vintf/manifest/ XMLs..."
if [ -d "$OPLUS_ODM_DIR/etc/vintf/manifest" ]; then
    for xml_file in "$OPLUS_ODM_DIR/etc/vintf/manifest/"*.xml; do
        [ -f "$xml_file" ] || continue
        fname=$(basename "$xml_file")
        case "$fname" in
            *oplus*|*oppo*|*charger*|*performance*|*powermonitor*|*olc*|*stability*|*power.stats*)
                inject_file "$xml_file" "$XIAOMI_ODM_DIR/etc/vintf/manifest/$fname"
                ;;
        esac
    done
fi

# --- etc/permissions/ — Feature permission XMLs ---
log_info "Injecting etc/permissions/ XMLs..."
if [ -d "$OPLUS_ODM_DIR/etc/permissions" ]; then
    for xml_file in "$OPLUS_ODM_DIR/etc/permissions/"*.xml; do
        [ -f "$xml_file" ] || continue
        fname=$(basename "$xml_file")
        case "$fname" in
            *oplus*|*oppo*|*charger*|*performance*|*powermonitor*|*olc*|*stability*|*power*)
                inject_file "$xml_file" "$XIAOMI_ODM_DIR/etc/permissions/$fname"
                ;;
        esac
    done
fi

# --- etc/ config files ---
log_info "Injecting etc/ config files..."

# ThermalServiceConfig
inject_file "$OPLUS_ODM_DIR/etc/ThermalServiceConfig" "$XIAOMI_ODM_DIR/etc/ThermalServiceConfig"

# power_profile
inject_file "$OPLUS_ODM_DIR/etc/power_profile" "$XIAOMI_ODM_DIR/etc/power_profile"

# power_save
inject_file "$OPLUS_ODM_DIR/etc/power_save" "$XIAOMI_ODM_DIR/etc/power_save"

# temperature_profile
inject_file "$OPLUS_ODM_DIR/etc/temperature_profile" "$XIAOMI_ODM_DIR/etc/temperature_profile"

# Individual config files
for cfg_file in custom_power.cfg power_stats_config.xml; do
    if [ -f "$OPLUS_ODM_DIR/etc/$cfg_file" ]; then
        inject_file "$OPLUS_ODM_DIR/etc/$cfg_file" "$XIAOMI_ODM_DIR/etc/$cfg_file"
    fi
done

log_success "HAL injection complete: $INJECT_COUNT files injected, $INJECT_ERRORS warnings"

# =========================================================
#  6. PERMISSION CLONING (fs_config)
# =========================================================
log_step "🔒 Cloning file permissions..."
tg_progress "🔒 Cloning permissions & contexts..."

OPLUS_FS_CONFIG="$OPLUS_CONFIG/odm_fs_config"
XIAOMI_FS_CONFIG="$XIAOMI_CONFIG/odm_fs_config"

# If OPLUS fs_config exists, merge entries for injected files
if [ -f "$OPLUS_FS_CONFIG" ] && [ -f "$XIAOMI_FS_CONFIG" ]; then
    log_info "Merging fs_config entries..."
    FS_MERGED=0

    while IFS= read -r line; do
        # fs_config format: <path> <uid> <gid> <mode> [caps]
        fs_path=$(echo "$line" | awk '{print $1}')
        [ -z "$fs_path" ] && continue

        # Check if this path corresponds to a file we injected
        rel_path="${fs_path#odm/}"
        if [ -f "$XIAOMI_ODM_DIR/$rel_path" ] || [ -d "$XIAOMI_ODM_DIR/$rel_path" ]; then
            # Check if already in Xiaomi fs_config
            if ! grep -qF "$fs_path" "$XIAOMI_FS_CONFIG" 2>/dev/null; then
                echo "$line" >> "$XIAOMI_FS_CONFIG"
                FS_MERGED=$((FS_MERGED + 1))
            fi
        fi
    done < "$OPLUS_FS_CONFIG"

    log_success "fs_config: $FS_MERGED entries merged"
else
    log_warning "fs_config not found in one or both projects — generating from injected files"

    # Generate fs_config entries for injected files
    mkdir -p "$XIAOMI_CONFIG"
    [ ! -f "$XIAOMI_FS_CONFIG" ] && touch "$XIAOMI_FS_CONFIG"

    # Generate entries for bin/hw — executable
    find "$XIAOMI_ODM_DIR/bin" -type f 2>/dev/null | while read f; do
        rel="odm/${f#$XIAOMI_ODM_DIR/}"
        if ! grep -qF "$rel" "$XIAOMI_FS_CONFIG" 2>/dev/null; then
            echo "$rel 0 2000 0755" >> "$XIAOMI_FS_CONFIG"
        fi
    done

    # Generate entries for lib/lib64 — shared libs
    for libdir in lib lib64; do
        find "$XIAOMI_ODM_DIR/$libdir" -name "*.so" -type f 2>/dev/null | while read f; do
            rel="odm/${f#$XIAOMI_ODM_DIR/}"
            if ! grep -qF "$rel" "$XIAOMI_FS_CONFIG" 2>/dev/null; then
                echo "$rel 0 0 0644" >> "$XIAOMI_FS_CONFIG"
            fi
        done
    done

    # Generate entries for etc/ — config files
    find "$XIAOMI_ODM_DIR/etc" -type f 2>/dev/null | while read f; do
        rel="odm/${f#$XIAOMI_ODM_DIR/}"
        if ! grep -qF "$rel" "$XIAOMI_FS_CONFIG" 2>/dev/null; then
            echo "$rel 0 0 0644" >> "$XIAOMI_FS_CONFIG"
        fi
    done

    log_success "fs_config generated for injected files"
fi

# =========================================================
#  7. CONTEXT MERGE ENGINE
# =========================================================
log_step "🏷️  Merging file_contexts metadata..."

OPLUS_CONTEXTS="$OPLUS_CONFIG/odm_file_contexts"
XIAOMI_CONTEXTS="$XIAOMI_CONFIG/odm_file_contexts"

# The context merge Python engine — handles all the transformation logic
cat > "$WORK_DIR/context_merger.py" << 'PYEOF'
#!/usr/bin/env python3
"""
OPLUS → Xiaomi ODM file_contexts merger.

Reads OPLUS odm_file_contexts, transforms OPLUS-specific SELinux labels
to Xiaomi-compatible ones, and appends to Xiaomi odm_file_contexts.

This is image METADATA merging, NOT sepolicy injection.
We only modify the config/odm_file_contexts file that gets baked into
the image at repack time.

Transformation rules:
  - /bin/hw/ executables with *_exec:s0 → hal_allocator_default_exec:s0
  - /bin/ scripts with *_exec:s0        → hal_allocator_default_exec:s0
  - /lib/ and /lib64/ .so files         → keep original context (vendor_file or same_process_hal_file)
  - /etc/init/ rc files                 → vendor_configs_file:s0
  - /etc/vintf/, /etc/permissions/      → vendor_configs_file:s0
  - /etc/ config files/dirs             → vendor_configs_file:s0
  - Version numbers handled dynamically: V10→V5, @1.0→@2.1, etc.
"""

import re
import sys
import os

def load_contexts(path):
    """Load file_contexts into a dict {path_pattern: full_line}."""
    entries = {}
    if not os.path.exists(path):
        return entries
    with open(path, 'r') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            parts = line.split()
            if len(parts) >= 2:
                entries[parts[0]] = line
    return entries

def transform_context(line, injected_paths):
    """
    Transform an OPLUS file_contexts line to be Xiaomi-compatible.
    
    Args:
        line: Full line from OPLUS odm_file_contexts
        injected_paths: Set of relative paths that were actually injected
    
    Returns:
        Transformed line, or None if should not be included
    """
    parts = line.strip().split()
    if len(parts) < 2:
        return None
    
    path_pattern = parts[0]
    context = parts[1]
    
    # Extract the actual path (remove regex escapes for matching)
    clean_path = path_pattern.replace('\\+', '+').replace('\\.', '.')
    # Remove leading / for matching against injected paths
    match_path = clean_path.lstrip('/')
    
    # Determine the category of this file
    is_bin_hw = '/bin/hw/' in path_pattern
    is_bin = '/bin/' in path_pattern and '/bin/hw/' not in path_pattern
    is_lib = '/lib/' in path_pattern and '/lib64/' not in path_pattern
    is_lib64 = '/lib64/' in path_pattern
    is_etc_init = '/etc/init/' in path_pattern
    is_etc = '/etc/' in path_pattern
    
    # Transform the context based on file location
    if is_bin_hw or is_bin:
        # All executables in bin/ and bin/hw/ get hal_allocator_default_exec
        # This is the key transformation for making OPLUS HALs run on Xiaomi
        new_context = 'u:object_r:hal_allocator_default_exec:s0'
        return f"{path_pattern} {new_context}"
    
    elif is_lib or is_lib64:
        # Libraries keep their original context type
        # same_process_hal_file stays same_process_hal_file
        # vendor_file stays vendor_file
        if 'same_process_hal_file' in context:
            return f"{path_pattern} u:object_r:same_process_hal_file:s0"
        else:
            return f"{path_pattern} u:object_r:vendor_file:s0"
    
    elif is_etc_init or is_etc:
        # Config files and init scripts
        return f"{path_pattern} u:object_r:vendor_configs_file:s0"
    
    else:
        # Anything else — keep vendor_file
        return f"{path_pattern} u:object_r:vendor_file:s0"

def get_injected_paths(xiaomi_odm_dir):
    """Walk the Xiaomi ODM dir and collect all oplus-related file paths."""
    injected = set()
    for root, dirs, files in os.walk(xiaomi_odm_dir):
        for f in files:
            full = os.path.join(root, f)
            rel = os.path.relpath(full, os.path.dirname(xiaomi_odm_dir))
            injected.add(rel)
    return injected

def should_include_entry(path_pattern):
    """Check if this OPLUS entry is for an oplus/oppo HAL we care about."""
    keywords = [
        'oplus', 'oppo', 'charger', 'performance', 'powermonitor',
        'olc2', 'olc', 'stability', 'power.stats', 'power_stats',
        'osense', 'Gaia', 'handlefactory', 'osml'
    ]
    lower = path_pattern.lower()
    return any(kw.lower() in lower for kw in keywords)

def main():
    if len(sys.argv) < 4:
        print("Usage: context_merger.py <oplus_contexts> <xiaomi_contexts> <xiaomi_odm_dir>")
        sys.exit(1)
    
    oplus_ctx_path = sys.argv[1]
    xiaomi_ctx_path = sys.argv[2]
    xiaomi_odm_dir = sys.argv[3]
    
    # Load existing contexts
    oplus_entries = load_contexts(oplus_ctx_path)
    xiaomi_entries = load_contexts(xiaomi_ctx_path)
    
    injected_paths = get_injected_paths(xiaomi_odm_dir)
    
    # Track what we merge
    merged = 0
    skipped = 0
    
    # Open Xiaomi contexts for appending
    with open(xiaomi_ctx_path, 'a') as out:
        out.write("\n# === OPLUS HAL CONTEXT ENTRIES (auto-merged) ===\n")
        
        for path_pattern, full_line in oplus_entries.items():
            # Only include entries for files we actually injected
            if not should_include_entry(path_pattern):
                skipped += 1
                continue
            
            # Skip if already exists in Xiaomi contexts
            if path_pattern in xiaomi_entries:
                skipped += 1
                continue
            
            # Transform the context
            transformed = transform_context(full_line, injected_paths)
            if transformed:
                out.write(transformed + "\n")
                merged += 1
            else:
                skipped += 1
    
    print(f"[CONTEXT] Merged: {merged} entries, Skipped: {skipped}")
    
    # Also handle version-variant paths
    # Some OPLUS HALs have different version numbers than what exists in the image
    # e.g., charger-V10-service in OPLUS vs charger-V5-service in Xiaomi
    # We need to add entries for the actual filenames that exist on disk
    version_added = 0
    with open(xiaomi_ctx_path, 'a') as out:
        for root, dirs, files in os.walk(os.path.join(xiaomi_odm_dir, 'bin')):
            for f in files:
                if not should_include_entry(f):
                    continue
                # Build the context path with regex escaping
                full_rel = os.path.relpath(os.path.join(root, f), os.path.dirname(xiaomi_odm_dir))
                ctx_path = '/' + full_rel.replace('.', '\\.').replace('+', '\\+')
                
                # Check if this exact path is already in contexts
                with open(xiaomi_ctx_path, 'r') as check:
                    existing = check.read()
                    if ctx_path in existing:
                        continue
                
                out.write(f"{ctx_path} u:object_r:hal_allocator_default_exec:s0\n")
                version_added += 1
        
        # Do the same for etc/init rc files
        init_dir = os.path.join(xiaomi_odm_dir, 'etc', 'init')
        if os.path.exists(init_dir):
            for f in os.listdir(init_dir):
                if not f.endswith('.rc'):
                    continue
                if not should_include_entry(f):
                    continue
                ctx_path = '/odm/etc/init/' + f.replace('.', '\\.')
                with open(xiaomi_ctx_path, 'r') as check:
                    if ctx_path in check.read():
                        continue
                out.write(f"{ctx_path} u:object_r:vendor_configs_file:s0\n")
                version_added += 1
    
    if version_added:
        print(f"[CONTEXT] Version-variant entries added: {version_added}")
    
    print("[CONTEXT] Done.")

if __name__ == '__main__':
    main()
PYEOF

# Ensure Xiaomi config dir and file_contexts exist
mkdir -p "$XIAOMI_CONFIG"
[ ! -f "$XIAOMI_CONTEXTS" ] && touch "$XIAOMI_CONTEXTS"

# Run context merger
if [ -f "$OPLUS_CONTEXTS" ]; then
    log_info "Running context merge engine..."
    python3 "$WORK_DIR/context_merger.py" "$OPLUS_CONTEXTS" "$XIAOMI_CONTEXTS" "$XIAOMI_ODM_DIR"
    log_success "Context merge complete"
else
    log_warning "OPLUS odm_file_contexts not found at $OPLUS_CONTEXTS"
    log_info "Generating file_contexts from injected files directly..."

    # Generate contexts for all injected oplus files
    python3 -c "
import os, sys

xiaomi_odm = sys.argv[1]
ctx_path = sys.argv[2]
count = 0

with open(ctx_path, 'a') as out:
    out.write('\n# === OPLUS HAL CONTEXT ENTRIES (generated) ===\n')
    for root, dirs, files in os.walk(xiaomi_odm):
        for f in files:
            full = os.path.join(root, f)
            rel = os.path.relpath(full, os.path.dirname(xiaomi_odm))
            lower = f.lower()
            
            if not any(kw in lower for kw in ['oplus', 'oppo', 'charger', 'performance',
                'powermonitor', 'olc', 'stability', 'power.stats', 'osense', 'gaia',
                'handlefactory']):
                continue
            
            ctx_entry = '/' + rel.replace('.', '\\\\.').replace('+', '\\\\+')
            
            if '/bin/' in rel:
                ctx = 'u:object_r:hal_allocator_default_exec:s0'
            elif '/lib' in rel:
                ctx = 'u:object_r:vendor_file:s0'
            elif '/etc/init/' in rel:
                ctx = 'u:object_r:vendor_configs_file:s0'
            else:
                ctx = 'u:object_r:vendor_configs_file:s0'
            
            out.write(f'{ctx_entry} {ctx}\n')
            count += 1

print(f'[CONTEXT] Generated {count} entries from injected files')
" "$XIAOMI_ODM_DIR" "$XIAOMI_CONTEXTS"
fi

rm -f "$WORK_DIR/context_merger.py"

# =========================================================
#  8. PROPS INJECTION
# =========================================================
log_step "📝 Injecting OPLUS props..."
tg_progress "📝 Injecting props..."

OPLUS_PROPS=""
# Collect props from OPLUS build.prop files
for prop_file in "$OPLUS_ODM_DIR/build.prop" "$OPLUS_ODM_DIR/etc/build.prop"; do
    if [ -f "$prop_file" ]; then
        log_info "Reading props from: $(basename "$prop_file")"
        # Extract oplus/oppo related props
        while IFS= read -r line; do
            case "$line" in
                ro.oplus.*|persist.oplus.*|ro.vendor.oplus.*|persist.vendor.oplus.*)
                    OPLUS_PROPS="$OPLUS_PROPS
$line"
                    ;;
            esac
        done < "$prop_file"
    fi
done

# Append to Xiaomi build.prop
if [ -n "$OPLUS_PROPS" ]; then
    XIAOMI_BUILD_PROP="$XIAOMI_ODM_DIR/build.prop"
    [ ! -f "$XIAOMI_BUILD_PROP" ] && XIAOMI_BUILD_PROP="$XIAOMI_ODM_DIR/etc/build.prop"

    if [ -f "$XIAOMI_BUILD_PROP" ]; then
        echo "" >> "$XIAOMI_BUILD_PROP"
        echo "# === OPLUS PROPS (auto-injected) ===" >> "$XIAOMI_BUILD_PROP"
        echo "$OPLUS_PROPS" >> "$XIAOMI_BUILD_PROP"
        PROP_COUNT=$(echo "$OPLUS_PROPS" | grep -c '=' || true)
        log_success "Injected $PROP_COUNT OPLUS props into $(basename "$XIAOMI_BUILD_PROP")"
    else
        log_warning "No Xiaomi build.prop found to inject props into"
    fi
else
    log_info "No OPLUS props found to inject"
fi

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
if command -v mkfs.erofs &>/dev/null; then
    log_info "Repacking with mkfs.erofs..."

    EROFS_ARGS="-zlz4hc,9"

    # Use file_contexts if available
    if [ -f "$XIAOMI_CONTEXTS" ] && [ -s "$XIAOMI_CONTEXTS" ]; then
        EROFS_ARGS="$EROFS_ARGS --file-contexts=$XIAOMI_CONTEXTS"
        log_info "Using file_contexts: $XIAOMI_CONTEXTS"
    fi

    # Use fs_config if available
    if [ -f "$XIAOMI_FS_CONFIG" ] && [ -s "$XIAOMI_FS_CONFIG" ]; then
        EROFS_ARGS="$EROFS_ARGS --fs-config-file=$XIAOMI_FS_CONFIG"
        log_info "Using fs_config: $XIAOMI_FS_CONFIG"
    fi

    mkfs.erofs $EROFS_ARGS \
        -T 1230768000 \
        --mount-point=/odm \
        "$PATCHED_ODM" \
        "$XIAOMI_ODM_DIR" 2>&1 | tail -5

    if [ -f "$PATCHED_ODM" ] && [ -s "$PATCHED_ODM" ]; then
        log_success "ODM repacked with EROFS: $(du -h "$PATCHED_ODM" | cut -f1)"
    else
        log_error "EROFS repack failed"
        # mkfs.erofs can fail if the version doesn't support all flags
        # Try without optional flags
        log_info "Retrying mkfs.erofs with minimal flags..."
        mkfs.erofs -zlz4hc \
            --mount-point=/odm \
            "$PATCHED_ODM" \
            "$XIAOMI_ODM_DIR" 2>&1 | tail -5
    fi
fi

if [ ! -f "$PATCHED_ODM" ] || [ ! -s "$PATCHED_ODM" ]; then
    log_error "Failed to repack ODM image"
    tg_send "❌ *ODM Patch Failed*\nCould not repack ODM image."
    exit 1
fi

log_success "Patched ODM image ready: $(du -h "$PATCHED_ODM" | cut -f1)"

# =========================================================
#  10. UPLOAD TO PIXELDRAIN
# =========================================================
log_step "☁️  Uploading to PixelDrain..."
tg_progress "☁️ Uploading patched ODM to PixelDrain..."

UPLOAD_RESPONSE=$(curl -s -T "$PATCHED_ODM" \
    -H "Content-Type: application/octet-stream" \
    "https://pixeldrain.com/api/file/odm.img")

PD_ID=$(echo "$UPLOAD_RESPONSE" | jq -r '.id // empty')

if [ -n "$PD_ID" ]; then
    PD_LINK="https://pixeldrain.com/u/$PD_ID"
    log_success "Upload complete: $PD_LINK"
else
    log_error "PixelDrain upload failed: $UPLOAD_RESPONSE"
    # Try again
    log_info "Retrying upload..."
    UPLOAD_RESPONSE=$(curl -s -T "$PATCHED_ODM" "https://pixeldrain.com/api/file/odm.img")
    PD_ID=$(echo "$UPLOAD_RESPONSE" | jq -r '.id // empty')
    if [ -n "$PD_ID" ]; then
        PD_LINK="https://pixeldrain.com/u/$PD_ID"
        log_success "Upload complete (retry): $PD_LINK"
    else
        PD_LINK="UPLOAD_FAILED"
        log_error "Upload failed after retry"
    fi
fi

# =========================================================
#  11. CLEANUP
# =========================================================
log_step "🧹 Cleaning up..."

rm -rf "$OPLUS_PROJECT" "$XIAOMI_PROJECT" "$OPLUS_DL" "$XIAOMI_DL"
# Keep the output dir with the patched image

SCRIPT_END=$(date +%s)
ELAPSED=$((SCRIPT_END - SCRIPT_START))
ELAPSED_MIN=$((ELAPSED / 60))
ELAPSED_SEC=$((ELAPSED % 60))

# =========================================================
#  12. FINAL TELEGRAM NOTIFICATION
# =========================================================
log_step "📤 Sending result..."

if [ "$PD_LINK" != "UPLOAD_FAILED" ]; then
    FINAL_MSG="✅ *OPLUS ODM Patch Complete*

📦 *Files Injected:* \`$INJECT_COUNT\`
⏱ *Time:* ${ELAPSED_MIN}m ${ELAPSED_SEC}s

📥 *Download:*
[Patched odm.img]($PD_LINK)

_Flash this odm.img to replace your stock Xiaomi ODM._"
else
    FINAL_MSG="⚠️ *ODM Patch Finished (Upload Failed)*

📦 *Files Injected:* \`$INJECT_COUNT\`
⏱ *Time:* ${ELAPSED_MIN}m ${ELAPSED_SEC}s

❌ PixelDrain upload failed. Check logs for details."
fi

tg_send "$FINAL_MSG"

log_success "=== OPLUS ODM PATCHER COMPLETE ==="
log_info "Injected: $INJECT_COUNT files | Time: ${ELAPSED_MIN}m ${ELAPSED_SEC}s"
[ "$PD_LINK" != "UPLOAD_FAILED" ] && log_info "Download: $PD_LINK"
