#!/bin/bash
# oplus_odm_patcher.sh - OPLUS-ODM-BUILDER v2.0
# Injects OPLUS HALs into Xiaomi ODM images

set -eE  # Exit on error and inherit traps
set -o pipefail

# ============================================
# CONFIGURATION
# ============================================

OPLUS_URL="${1:-}"
XIAOMI_URL="${2:-}"
CHAT_ID="${3:-${CHAT_ID}}"
REQUESTER_CHAT_ID="${4:-${REQUESTER_CHAT_ID:-$CHAT_ID}}"
TELEGRAM_TOKEN="${TELEGRAM_TOKEN}"
PIXELDRAIN_KEY="${PIXELDRAIN_KEY}"

WORK_DIR="${WORK_DIR:-/tmp/oplus_odm_builder_$$}"
LOG_FILE="$WORK_DIR/build.log"
START_TIME=$(date +%s)

# ============================================
# LOGGING FUNCTIONS
# ============================================

log() {
    local level="$1"
    shift
    local msg="$*"
    local ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] [$level] $msg" | tee -a "$LOG_FILE"
}

send_telegram() {
    local msg="$1"
    [ -z "$TELEGRAM_TOKEN" ] || [ -z "$REQUESTER_CHAT_ID" ] && return 0
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
        -d chat_id="$REQUESTER_CHAT_ID" \
        -d text="$msg" \
        -d parse_mode="Markdown" \
        -d disable_web_page_preview=true >/dev/null 2>&1 || true
}

send_progress() {
    local step=$1 total=$2 msg="$3"
    local pct=$((step * 100 / total))
    local bar=""
    for i in $(seq 1 20); do
        [ $i -le $((pct / 5)) ] && bar+="█" || bar+="░"
    done
    log "INFO" "[$step/$total] $msg"
    send_telegram "⏳ *OPLUS-ODM-BUILDER*

${bar} ${pct}%

*Step $step of $total*
$msg"
}

# ============================================
# ERROR HANDLING
# ============================================

cleanup_on_error() {
    log "ERROR" "Build failed at line $1"
    send_telegram "❌ *Build Failed*

Error at line $1
Check logs for details"
    cleanup_all
    exit 1
}

trap 'cleanup_on_error $LINENO' ERR

# ============================================
# VALIDATION
# ============================================

if [ -z "$OPLUS_URL" ] || [ -z "$XIAOMI_URL" ]; then
    echo "Usage: $0 <OPLUS_OTA_URL> <XIAOMI_OTA_URL>"
    exit 1
fi

mkdir -p "$WORK_DIR"

log "INFO" "OPLUS-ODM-BUILDER v2.0 Starting"
log "INFO" "OPLUS OTA: $OPLUS_URL"
log "INFO" "Xiaomi OTA: $XIAOMI_URL"

send_telegram "🚀 *OPLUS-ODM-BUILDER Started*

📱 OPLUS OTA: ${OPLUS_URL:0:50}...
📱 Xiaomi OTA: ${XIAOMI_URL:0:50}...

⏱️ Estimated: 15-30 minutes"

# ============================================
# PREFLIGHT CHECKS
# ============================================

send_progress 1 13 "Pre-flight checks..."

REQUIRED_TOOLS="wget aria2c unzip mount umount mkfs.ext4 e2fsck resize2fs curl jq stat md5sum payload-dumper-go"
MISSING=""

for tool in $REQUIRED_TOOLS; do
    command -v $tool >/dev/null 2>&1 || MISSING="$MISSING $tool"
done

if [ -n "$MISSING" ]; then
    log "ERROR" "Missing tools:$MISSING"
    send_telegram "❌ *Pre-flight Failed*

Missing tools:$MISSING"
    exit 1
fi

FREE_SPACE=$(df /tmp | tail -1 | awk '{print $4}')
if [ "$FREE_SPACE" -lt 10485760 ]; then
    log "ERROR" "Need 10GB free space"
    send_telegram "❌ *Insufficient Disk Space*

Need: 10GB
Available: $((FREE_SPACE / 1024 / 1024))GB"
    exit 1
fi

log "INFO" "Pre-flight checks passed"

# ============================================
# DOWNLOAD FUNCTION
# ============================================

download_ota() {
    local url="$1" output="$2" name="$3"
    log "INFO" "Downloading $name OTA..."
    
    aria2c -x 16 -s 16 -k 1M --max-tries=5 \
           -d "$(dirname "$output")" \
           -o "$(basename "$output")" \
           "$url" || {
        log "ERROR" "$name OTA download failed"
        return 1
    }
    
    # Validate
    [ -f "$output" ] || { log "ERROR" "$name OTA not found"; return 1; }
    
    local size=$(stat -c%s "$output")
    [ "$size" -lt 1000000 ] && { log "ERROR" "$name OTA too small"; return 1; }
    
    file "$output" | grep -qi "zip" || { log "ERROR" "$name OTA not a ZIP"; return 1; }
    unzip -l "$output" | grep -q "payload.bin" || { log "ERROR" "$name OTA missing payload.bin"; return 1; }
    
    log "INFO" "$name OTA validated ($(numfmt --to=iec-i --suffix=B $size))"
}

# ============================================
# EXTRACT ODM
# ============================================

extract_odm() {
    local ota="$1" workdir="$2" name="$3"
    log "INFO" "Extracting $name ODM..."
    
    mkdir -p "$workdir"
    unzip -q -j "$ota" "payload.bin" -d "$workdir" || return 1
    
    payload-dumper-go -p odm -o "$workdir" "$workdir/payload.bin" >/dev/null 2>&1 || {
        log "ERROR" "Failed to extract $name ODM from payload"
        return 1
    }
    
    rm -f "$workdir/payload.bin"
    
    [ -f "$workdir/odm.img" ] || { log "ERROR" "$name odm.img not found"; return 1; }
    
    log "INFO" "$name ODM extracted"
    echo "$workdir/odm.img"
}

# ============================================
# MOUNT ODM
# ============================================

mount_odm() {
    local img="$1" mnt="$2"
    log "INFO" "Mounting $(basename $(dirname $img)) ODM..."
    
    mkdir -p "$mnt"
    
    # Detect filesystem
    local fstype=$(blkid -s TYPE -o value "$img" 2>/dev/null || echo "unknown")
    log "INFO" "Filesystem: $fstype"
    
    # Handle EROFS (read-only)
    if [ "$fstype" = "erofs" ]; then
        log "INFO" "Converting EROFS to EXT4..."
        local tmpdir=$(mktemp -d)
        mount -t erofs -o loop,ro "$img" "$tmpdir" || {
            log "ERROR" "Failed to mount EROFS"
            rm -rf "$tmpdir"
            return 1
        }
        
        # Calculate size
        local size=$(du -sb "$tmpdir" | cut -f1)
        size=$((size * 130 / 100))  # 30% overhead
        
        # Create ext4
        local newimg="${img%.img}_ext4.img"
        dd if=/dev/zero of="$newimg" bs=1 count=0 seek=$size 2>/dev/null
        mkfs.ext4 -q -L odm "$newimg"
        
        # Copy contents
        local tmpdir2=$(mktemp -d)
        mount -o loop "$newimg" "$tmpdir2"
        cp -a "$tmpdir"/* "$tmpdir2"/ 2>/dev/null || true
        umount "$tmpdir2"
        umount "$tmpdir"
        rm -rf "$tmpdir" "$tmpdir2"
        
        mv "$newimg" "$img"
        fstype="ext4"
    fi
    
    # Mount read-write
    mount -o loop,rw "$img" "$mnt" || {
        log "WARN" "Mount failed, attempting repair..."
        e2fsck -fy "$img" >/dev/null 2>&1 || true
        mount -o loop,rw "$img" "$mnt" || {
            log "ERROR" "Failed to mount ODM"
            return 1
        }
    }
    
    log "INFO" "Mounted at $mnt"
}

# ============================================
# EXTRACT OPLUS COMPONENTS
# ============================================

extract_oplus_components() {
    local src="$1" dest="$2"
    log "INFO" "Extracting OPLUS components..."
    
    mkdir -p "$dest"/{bin/hw,lib,lib64,etc}
    
    local count=0
    local permfile="$dest/permissions.txt"
    > "$permfile"
    
    # Extract binaries from /bin/hw/
    if [ -d "$src/bin/hw" ]; then
        for f in "$src/bin/hw"/*; do
            [ -f "$f" ] || continue
            local name=$(basename "$f")
            if echo "$name" | grep -qiE "(oplus|oppo|charger|stability|performance|powermonitor|olc)"; then
                cp -p "$f" "$dest/bin/hw/"
                echo "/odm/bin/hw/$name|$(stat -c '%a %u:%g' "$f")" >> "$permfile"
                count=$((count + 1))
            fi
        done
    fi
    
    # Extract from /bin/
    if [ -d "$src/bin" ]; then
        for f in "$src/bin"/*; do
            [ -f "$f" ] || continue
            [ -d "$f" ] && continue
            local name=$(basename "$f")
            if echo "$name" | grep -qiE "(oplus|oppo)"; then
                cp -p "$f" "$dest/bin/"
                echo "/odm/bin/$name|$(stat -c '%a %u:%g' "$f")" >> "$permfile"
                count=$((count + 1))
            fi
        done
    fi
    
    # Extract libraries
    for libdir in lib lib64; do
        [ -d "$src/$libdir" ] || continue
        for f in "$src/$libdir"/*.so; do
            [ -f "$f" ] || continue
            local name=$(basename "$f")
            if echo "$name" | grep -qiE "(oplus|oppo|gaia|osense)"; then
                cp -p "$f" "$dest/$libdir/"
                echo "/odm/$libdir/$name|$(stat -c '%a %u:%g' "$f")" >> "$permfile"
                count=$((count + 1))
            fi
        done
    done
    
    # Extract configs
    for dir in init permissions vintf power_profile power_save temperature_profile ThermalServiceConfig; do
        [ -d "$src/etc/$dir" ] || continue
        mkdir -p "$dest/etc/$dir"
        find "$src/etc/$dir" -type f | while read f; do
            local rel=${f#$src/etc/}
            if grep -qiE "(oplus|charger|stability|performance|powermonitor)" "$f" 2>/dev/null || \
               echo "$f" | grep -qiE "(oplus|charger|stability|performance|powermonitor)"; then
                mkdir -p "$dest/etc/$(dirname "$rel")"
                cp -p "$f" "$dest/etc/$rel"
                echo "/odm/etc/$rel|$(stat -c '%a %u:%g' "$f")" >> "$permfile"
                count=$((count + 1))
            fi
        done
    done
    
    # Copy build.prop
    [ -f "$src/build.prop" ] && cp -p "$src/build.prop" "$dest/"
    
    # Copy file_contexts
    for ctx in etc/selinux/odm_file_contexts file_contexts; do
        [ -f "$src/$ctx" ] && cp -p "$src/$ctx" "$dest/" && break
    done
    
    log "INFO" "Extracted $count OPLUS components"
}

# ============================================
# GENERATE SELINUX CONTEXTS
# ============================================

generate_contexts() {
    local oplus_ctx="$1" output="$2"
    log "INFO" "Generating SELinux contexts..."
    
    [ -f "$oplus_ctx" ] || { log "ERROR" "OPLUS contexts not found"; return 1; }
    
    > "$output"
    local count=0
    
    while IFS= read -r line; do
        # Skip comments/empty
        [[ "$line" =~ ^#.*$ ]] && continue
        [[ -z "$line" ]] && continue
        
        # Parse line
        local path=$(echo "$line" | awk '{print $1}')
        local ctx=$(echo "$line" | awk '{print $2}')
        
        # Check if OPLUS-related
        echo "$path" | grep -qiE "(oplus|oppo|charger|stability|performance|powermonitor|olc)" || continue
        
        # Transform context
        local new_ctx="$ctx"
        if echo "$ctx" | grep -qE "oplus.*_exec|oppo.*_exec"; then
            new_ctx="u:object_r:hal_allocator_default_exec:s0"
        fi
        
        # Handle special libraries
        if echo "$path" | grep -qE "(osense|urcc)"; then
            new_ctx="u:object_r:same_process_hal_file:s0"
        fi
        
        # Convert path
        local new_path=$(echo "$path" | sed 's|/(vendor\|odm)/|/odm/|g' | sed 's/\\././g')
        
        echo "$new_path $new_ctx" >> "$output"
        count=$((count + 1))
    done < "$oplus_ctx"
    
    log "INFO" "Generated $count context entries"
}

# ============================================
# INJECT OPLUS TO XIAOMI
# ============================================

inject_oplus() {
    local src="$1" dest="$2" ctx_file="$3"
    log "INFO" "Injecting OPLUS components..."
    
    local permfile="$src/permissions.txt"
    local count=0
    
    # Inject binaries
    if [ -d "$src/bin/hw" ]; then
        mkdir -p "$dest/bin/hw"
        for f in "$src/bin/hw"/*; do
            [ -f "$f" ] || continue
            local name=$(basename "$f")
            cp -p "$f" "$dest/bin/hw/"
            
            # Apply permissions
            if [ -f "$permfile" ]; then
                local perm=$(grep "/odm/bin/hw/$name|" "$permfile" | cut -d'|' -f2)
                if [ -n "$perm" ]; then
                    local mode=$(echo "$perm" | cut -d' ' -f1)
                    local owner=$(echo "$perm" | cut -d' ' -f2)
                    chmod "$mode" "$dest/bin/hw/$name" 2>/dev/null || true
                    chown "$owner" "$dest/bin/hw/$name" 2>/dev/null || true
                fi
            fi
            count=$((count + 1))
        done
    fi
    
    # Inject /bin files
    if [ -d "$src/bin" ]; then
        for f in "$src/bin"/*; do
            [ -f "$f" ] || continue
            [ -d "$f" ] && continue
            local name=$(basename "$f")
            cp -p "$f" "$dest/bin/"
            count=$((count + 1))
        done
    fi
    
    # Inject libs
    for libdir in lib lib64; do
        [ -d "$src/$libdir" ] || continue
        mkdir -p "$dest/$libdir"
        cp -p "$src/$libdir"/*.so "$dest/$libdir/" 2>/dev/null || true
        count=$((count + $(ls "$src/$libdir"/*.so 2>/dev/null | wc -l)))
    done
    
    # Inject configs
    [ -d "$src/etc" ] && cp -rp "$src/etc"/* "$dest/etc/" 2>/dev/null || true
    
    # Inject contexts to odm_file_contexts
    local xiaomi_ctx=""
    for ctx in etc/selinux/odm_file_contexts file_contexts; do
        [ -f "$dest/$ctx" ] && xiaomi_ctx="$dest/$ctx" && break
    done
    
    if [ -n "$xiaomi_ctx" ] && [ -f "$ctx_file" ]; then
        log "INFO" "Injecting SELinux contexts to $(basename $xiaomi_ctx)..."
        echo "" >> "$xiaomi_ctx"
        echo "##############################################" >> "$xiaomi_ctx"
        echo "# OPLUS HAL Contexts - Injected" >> "$xiaomi_ctx"
        echo "##############################################" >> "$xiaomi_ctx"
        cat "$ctx_file" >> "$xiaomi_ctx"
    else
        log "WARN" "Could not inject contexts - file not found"
    fi
    
    log "INFO" "Injected $count components"
}

# ============================================
# INJECT BUILD PROPERTIES
# ============================================

inject_buildprop() {
    local oplus_prop="$1" xiaomi_odm_prop="$2" xiaomi_etc_prop="$3"
    log "INFO" "Injecting build properties..."
    
    # Append to /odm/build.prop
    if [ -f "$oplus_prop" ] && [ -f "$xiaomi_odm_prop" ]; then
        echo "" >> "$xiaomi_odm_prop"
        echo "##############################################" >> "$xiaomi_odm_prop"
        echo "# OPLUS Properties - Injected" >> "$xiaomi_odm_prop"
        echo "##############################################" >> "$xiaomi_odm_prop"
        grep -v '^#' "$oplus_prop" | grep -v '^$' >> "$xiaomi_odm_prop"
    fi
    
    # Add imports to /odm/etc/build.prop
    [ ! -f "$xiaomi_etc_prop" ] && touch "$xiaomi_etc_prop"
    
    cat >> "$xiaomi_etc_prop" << 'EOF'

##############################################
# OPLUS Imports
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
EOF
    
    log "INFO" "Build properties injected"
}

# ============================================
# REPACK ODM
# ============================================

repack_odm() {
    local mnt="$1" output="$2"
    log "INFO" "Repacking ODM image..."
    
    # Calculate size
    local size=$(du -sb "$mnt" | cut -f1)
    size=$((size * 120 / 100))  # 20% overhead
    
    log "INFO" "Creating ext4 image ($(numfmt --to=iec-i --suffix=B $size))..."
    
    # Create image
    dd if=/dev/zero of="$output" bs=1 count=0 seek=$size 2>/dev/null
    mkfs.ext4 -q -L odm -b 4096 "$output"
    
    # Mount and copy
    local tmpdir=$(mktemp -d)
    mount -o loop "$output" "$tmpdir" || {
        log "ERROR" "Failed to mount new image"
        rm -rf "$tmpdir"
        return 1
    }
    
    log "INFO" "Copying files..."
    cp -a "$mnt"/* "$tmpdir"/ || {
        log "ERROR" "Failed to copy files"
        umount "$tmpdir"
        rm -rf "$tmpdir"
        return 1
    }
    
    umount "$tmpdir"
    rm -rf "$tmpdir"
    
    # Optimize
    log "INFO" "Optimizing..."
    e2fsck -fy "$output" >/dev/null 2>&1 || true
    resize2fs -M "$output" >/dev/null 2>&1 || true
    
    local final=$(stat -c%s "$output")
    log "INFO" "Repacked: $(numfmt --to=iec-i --suffix=B $final)"
}

# ============================================
# UPLOAD TO PIXELDRAIN
# ============================================

upload_pixeldrain() {
    local file="$1"
    log "INFO" "Uploading to PixelDrain..."
    
    [ -f "$file" ] || { log "ERROR" "File not found"; return 1; }
    
    local args=(-F "file=@$file")
    [ -n "$PIXELDRAIN_KEY" ] && args+=(-H "Authorization: Basic $PIXELDRAIN_KEY")
    
    local resp=$(curl -s "${args[@]}" https://pixeldrain.com/api/file)
    local id=$(echo "$resp" | jq -r '.id // empty' 2>/dev/null)
    
    [ -z "$id" ] && { log "ERROR" "Upload failed: $resp"; return 1; }
    
    echo "https://pixeldrain.com/u/$id"
}

# ============================================
# CLEANUP
# ============================================

cleanup_all() {
    log "INFO" "Cleaning up..."
    
    # Unmount
    for m in "$WORK_DIR"/mount_*; do
        [ -d "$m" ] && umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
    done
    
    # Remove temps (keep only final patched image)
    rm -f "$WORK_DIR"/*.zip
    rm -f "$WORK_DIR"/*/payload.bin
    rm -rf "$WORK_DIR"/oplus_extracted/
    rm -rf "$WORK_DIR"/xiaomi_extracted/
    rm -rf "$WORK_DIR"/oplus_components/
    rm -f "$WORK_DIR"/oplus_odm.img
    rm -f "$WORK_DIR"/xiaomi_odm.img
    rm -rf "$WORK_DIR"/mount_*
}

# ============================================
# MAIN PIPELINE
# ============================================

main() {
    # Step 2: Download OPLUS
    send_progress 2 13 "Downloading OPLUS OTA..."
    download_ota "$OPLUS_URL" "$WORK_DIR/oplus.zip" "OPLUS"
    
    # Step 3: Download Xiaomi
    send_progress 3 13 "Downloading Xiaomi OTA..."
    download_ota "$XIAOMI_URL" "$WORK_DIR/xiaomi.zip" "Xiaomi"
    
    # Step 4: Extract OPLUS
    send_progress 4 13 "Extracting OPLUS ODM..."
    OPLUS_ODM=$(extract_odm "$WORK_DIR/oplus.zip" "$WORK_DIR/oplus_extracted" "OPLUS")
    
    # Step 5: Extract Xiaomi
    send_progress 5 13 "Extracting Xiaomi ODM..."
    XIAOMI_ODM=$(extract_odm "$WORK_DIR/xiaomi.zip" "$WORK_DIR/xiaomi_extracted" "Xiaomi")
    
    # Step 6: Mount OPLUS
    send_progress 6 13 "Mounting OPLUS ODM..."
    mount_odm "$OPLUS_ODM" "$WORK_DIR/mount_oplus"
    
    # Step 7: Mount Xiaomi
    send_progress 7 13 "Mounting Xiaomi ODM..."
    mount_odm "$XIAOMI_ODM" "$WORK_DIR/mount_xiaomi"
    
    # Step 8: Extract OPLUS components
    send_progress 8 13 "Extracting OPLUS components..."
    extract_oplus_components "$WORK_DIR/mount_oplus" "$WORK_DIR/oplus_components"
    
    # Step 9: Generate contexts
    send_progress 9 13 "Generating SELinux contexts..."
    
    # Find OPLUS context file
    OPLUS_CTX=""
    for f in "$WORK_DIR/oplus_components/odm_file_contexts" \
             "$WORK_DIR/mount_oplus/etc/selinux/odm_file_contexts" \
             "$WORK_DIR/mount_oplus/file_contexts"; do
        [ -f "$f" ] && OPLUS_CTX="$f" && break
    done
    
    [ -z "$OPLUS_CTX" ] && { log "ERROR" "OPLUS contexts not found"; exit 1; }
    
    generate_contexts "$OPLUS_CTX" "$WORK_DIR/generated_contexts.txt"
    
    # Step 10: Inject OPLUS
    send_progress 10 13 "Injecting OPLUS to Xiaomi..."
    inject_oplus "$WORK_DIR/oplus_components" \
                 "$WORK_DIR/mount_xiaomi" \
                 "$WORK_DIR/generated_contexts.txt"
    
    # Step 11: Inject properties
    send_progress 11 13 "Injecting build properties..."
    inject_buildprop "$WORK_DIR/oplus_components/build.prop" \
                     "$WORK_DIR/mount_xiaomi/build.prop" \
                     "$WORK_DIR/mount_xiaomi/etc/build.prop"
    
    # Step 12: Unmount and repack
    send_progress 12 13 "Repacking ODM..."
    
    umount "$WORK_DIR/mount_oplus" 2>/dev/null || true
    repack_odm "$WORK_DIR/mount_xiaomi" "$WORK_DIR/patched_odm.img"
    umount "$WORK_DIR/mount_xiaomi" 2>/dev/null || true
    
    # Step 13: Upload
    send_progress 13 13 "Uploading to PixelDrain..."
    LINK=$(upload_pixeldrain "$WORK_DIR/patched_odm.img")
    
    # Calculate metadata
    SIZE=$(stat -c%s "$WORK_DIR/patched_odm.img")
    MD5=$(md5sum "$WORK_DIR/patched_odm.img" | cut -d' ' -f1)
    DURATION=$(($(date +%s) - START_TIME))
    TIME=$(printf '%02d:%02d:%02d' $((DURATION/3600)) $((DURATION%3600/60)) $((DURATION%60)))
    
    # Cleanup
    cleanup_all
    
    # Send success notification
    send_telegram "🎉 *OPLUS-ODM-BUILDER Complete!*

📦 *Patched ODM Ready*
━━━━━━━━━━━━━━━━━━━
🔹 Size: $(numfmt --to=iec-i --suffix=B $SIZE)
🔹 MD5: \`${MD5:0:16}...\`
🔹 Time: $TIME

⚠️ *Flash Instructions:*
\`\`\`
fastboot flash odm odm.img
fastboot reboot
\`\`\`

⚠️ Backup current ODM first!

[Download Patched ODM]($LINK)"
    
    log "INFO" "SUCCESS!"
    echo ""
    echo "======================================"
    echo "✅ OPLUS-ODM-BUILDER COMPLETE"
    echo "======================================"
    echo "Download: $LINK"
    echo "Size: $(numfmt --to=iec-i --suffix=B $SIZE)"
    echo "MD5: $MD5"
    echo "Time: $TIME"
    echo "======================================"
}

# Run main pipeline
main
