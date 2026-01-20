#!/bin/bash

# =========================================================
#  NEXDROID GOONER - HYPEROS SPECIALIST EDITION
# =========================================================

ROM_URL="$1"
GITHUB_WORKSPACE=$(pwd)
BIN_DIR="$GITHUB_WORKSPACE/bin"
OUTPUT_DIR="$GITHUB_WORKSPACE/NexMod_Output"
IMAGES_DIR="$OUTPUT_DIR/images"
TOOLS_DIR="$OUTPUT_DIR/tools"
TEMP_DIR="$GITHUB_WORKSPACE/temp"

# 1. SETUP
echo "🛠️  Setting up Environment..."
mkdir -p "$IMAGES_DIR" "$TOOLS_DIR" "$TEMP_DIR"
chmod +x "$BIN_DIR"/*
export PATH="$BIN_DIR:$PATH"

# Install Dependencies (with erofsfuse)
sudo apt-get update -y
sudo apt-get install -y python3 python3-pip erofs-utils erofsfuse jq aria2 zip unzip

# AUTO-DOWNLOAD PAYLOAD DUMPER
if [ ! -f "$BIN_DIR/payload-dumper-go" ]; then
    echo "⬇️  Fetching Tools..."
    wget -q https://github.com/ssut/payload-dumper-go/releases/download/1.2.2/payload-dumper-go_1.2.2_linux_amd64.tar.gz
    tar -xzf payload-dumper-go_1.2.2_linux_amd64.tar.gz
    find . -type f -name "payload-dumper-go" -not -path "*/bin/*" -exec mv {} "$BIN_DIR/" \;
    chmod +x "$BIN_DIR/payload-dumper-go"
fi

# 2. DOWNLOAD ROM
echo "⬇️  Downloading ROM..."
cd "$TEMP_DIR"
aria2c -x 16 -s 16 --file-allocation=none -o "rom.zip" "$ROM_URL"
unzip -o "rom.zip" payload.bin
rm "rom.zip"

# 3. EXTRACT FIRMWARE
echo "🔍 Extracting Firmware..."
payload-dumper-go -p boot,dtbo,vendor_boot,recovery,init_boot,vbmeta,vbmeta_system,vbmeta_vendor -o "$IMAGES_DIR" payload.bin > /dev/null 2>&1

# 4. DETECT DEVICE (HYPEROS LOGIC)
echo "🕵️  Detecting Device Identity..."

# A. Extract minimal partitions needed for ID (mi_ext + system)
payload-dumper-go -p mi_ext,system -o . payload.bin > /dev/null 2>&1

DEVICE_CODE=""

# CHECK 1: mi_ext (The User's Fix)
if [ -f "mi_ext.img" ]; then
    echo "    -> Checking mi_ext for Identity..."
    mkdir -p mnt_id
    erofsfuse mi_ext.img mnt_id
    
    if [ -f "mnt_id/etc/build.prop" ]; then
        # Look for ro.product.mod_device (e.g., marble_global)
        RAW_CODE=$(grep "ro.product.mod_device=" "mnt_id/etc/build.prop" | head -1 | cut -d'=' -f2)
        if [ ! -z "$RAW_CODE" ]; then
            # Strip suffix (marble_global -> marble)
            DEVICE_CODE=$(echo "$RAW_CODE" | cut -d'_' -f1)
            echo "    ✅ Found mod_device: $RAW_CODE (Using: $DEVICE_CODE)"
        fi
    fi
    fusermount -u mnt_id
    rm mi_ext.img
fi

# CHECK 2: System (Fallback & Version Info)
if [ -f "system.img" ]; then
    mkdir -p mnt_id
    erofsfuse system.img mnt_id
    
    # Locate build.prop
    if [ -f "mnt_id/system/build.prop" ]; then
        SYS_PROP="mnt_id/system/build.prop"
    else
        SYS_PROP=$(find mnt_id -name "build.prop" | head -n 1)
    fi

    # If mi_ext failed, try standard system props
    if [ -z "$DEVICE_CODE" ]; then
        echo "    ⚠️ mi_ext check failed. Checking System..."
        DEVICE_CODE=$(grep "ro.product.device=" "$SYS_PROP" | head -1 | cut -d'=' -f2)
        if [ -z "$DEVICE_CODE" ]; then
             DEVICE_CODE=$(grep "ro.product.system.device=" "$SYS_PROP" | head -1 | cut -d'=' -f2)
        fi
    fi

    # Get OS Versions
    OS_VER=$(grep "ro.system.build.version.incremental=" "$SYS_PROP" | head -1 | cut -d'=' -f2)
    ANDROID_VER=$(grep "ro.system.build.version.release=" "$SYS_PROP" | head -1 | cut -d'=' -f2)
    
    fusermount -u mnt_id
    rmdir mnt_id
    rm system.img
fi

# Validate
if [ -z "$DEVICE_CODE" ]; then
    echo "❌ CRITICAL: Could not detect Device Code in mi_ext or system!"
    exit 1
fi

echo "✅  Identity: $DEVICE_CODE | HyperOS $OS_VER"

# Check JSON
SUPER_SIZE=$(jq -r --arg dev "$DEVICE_CODE" '.[$dev].super_size' "$GITHUB_WORKSPACE/devices.json")
if [ "$SUPER_SIZE" == "null" ] || [ -z "$SUPER_SIZE" ]; then
    echo "❌  DEVICE UNKNOWN: '$DEVICE_CODE'"
    echo "    Please add '$DEVICE_CODE' to your devices.json file."
    exit 1
fi

# 5. MODDING LOOP
LPM_ARGS=""
PARTITIONS="system system_dlkm vendor vendor_dlkm product odm mi_ext"

for part in $PARTITIONS; do
    echo "🔄 Processing: $part"
    payload-dumper-go -p "$part" -o . payload.bin > /dev/null 2>&1
    
    if [ -f "${part}.img" ]; then
        mkdir -p "${part}_dump"
        mkdir -p "mnt_point"
        
        # MOUNT
        erofsfuse "${part}.img" "mnt_point"
        
        # COPY OUT (Preserve permissions)
        cp -a "mnt_point/." "${part}_dump/"
        
        # UNMOUNT & CLEAN
        fusermount -u "mnt_point"
        rmdir "mnt_point"
        rm "${part}.img"
        
        # INJECT
        if [ -d "$GITHUB_WORKSPACE/mods/$part" ]; then
            echo "    -> Injecting Mods..."
            cp -r "$GITHUB_WORKSPACE/mods/$part/"* "${part}_dump/"
        fi
        
        # REPACK
        mkfs.erofs -zLZ4HC "${part}_mod.img" "${part}_dump"
        rm -rf "${part}_dump"
        
        # LIST
        IMG_SIZE=$(stat -c%s "${part}_mod.img")
        LPM_ARGS="$LPM_ARGS --partition ${part}:readonly:${IMG_SIZE}:main --image ${part}=${part}_mod.img"
    else
        echo "    (Skipped)"
    fi
done

rm payload.bin

# 6. BUILD SUPER
echo "🔨  Building Super..."
lpmake --metadata-size 65536 --super-name super --metadata-slots 2 \
       --device super:$SUPER_SIZE --group main:$SUPER_SIZE \
       $LPM_ARGS --output "$IMAGES_DIR/super.img"

# 7. FINALIZE
cd "$OUTPUT_DIR"
python3 "$GITHUB_WORKSPACE/gen_scripts.py" "$DEVICE_CODE" "images"

echo "📥  Bundling ADB..."
wget -q https://dl.google.com/android/repository/platform-tools-latest-windows.zip
unzip -q platform-tools-latest-windows.zip && mv platform-tools/* tools/ && rm -rf platform-tools*

# 8. UPLOAD
ZIP_NAME="ota_NexDroid_${DEVICE_CODE}_${OS_VER}.zip"
echo "📦  Zipping..."
zip -r -q "$ZIP_NAME" .
curl -T "$ZIP_NAME" -u : https://pixeldrain.com/api/file/
