#!/bin/bash

# =========================================================
#  NEXDROID GOONER - DOCKER GOD MODE
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

# Install basics
sudo apt-get update -y
sudo apt-get install -y python3 python3-pip erofs-utils erofsfuse jq aria2 zip unzip liblz4-tool

# 2. GET TOOLS (Standard Download)
echo "⬇️  Fetching Tools..."
if [ ! -f "$BIN_DIR/payload-dumper-go" ]; then
    wget -q https://github.com/ssut/payload-dumper-go/releases/download/1.2.2/payload-dumper-go_1.2.2_linux_amd64.tar.gz
    tar -xzf payload-dumper-go_1.2.2_linux_amd64.tar.gz
    find . -type f -name "payload-dumper-go" -not -path "*/bin/*" -exec mv {} "$BIN_DIR/" \;
    chmod +x "$BIN_DIR/payload-dumper-go"
fi

# We download lpmake, but we will run it inside Docker later
if [ ! -f "$BIN_DIR/lpmake" ]; then
    wget -q -O "$BIN_DIR/lpmake" "https://github.com/elfamigos/android-tools-bin/raw/main/linux/lpmake"
    chmod +x "$BIN_DIR/lpmake"
fi

# 3. DOWNLOAD ROM
echo "⬇️  Downloading ROM..."
cd "$TEMP_DIR"
aria2c -x 16 -s 16 --file-allocation=none -o "rom.zip" "$ROM_URL"
unzip -o "rom.zip" payload.bin
rm "rom.zip"

# 4. EXTRACT FIRMWARE
echo "🔍 Extracting Firmware..."
payload-dumper-go -p boot,dtbo,vendor_boot,recovery,init_boot,vbmeta,vbmeta_system,vbmeta_vendor -o "$IMAGES_DIR" payload.bin > /dev/null 2>&1

# 5. SMART DETECTION
echo "🕵️  Detecting Device Identity..."
payload-dumper-go -p mi_ext,system -o . payload.bin > /dev/null 2>&1

DEVICE_CODE=""
if [ -f "mi_ext.img" ]; then
    mkdir -p mnt_id
    erofsfuse mi_ext.img mnt_id
    if [ -f "mnt_id/etc/build.prop" ]; then
        RAW_CODE=$(grep "ro.product.mod_device=" "mnt_id/etc/build.prop" | head -1 | cut -d'=' -f2)
        if [ ! -z "$RAW_CODE" ]; then
            DEVICE_CODE=$(echo "$RAW_CODE" | cut -d'_' -f1)
            echo "    ✅ Found mod_device in mi_ext: $RAW_CODE (Using: $DEVICE_CODE)"
        fi
    fi
    fusermount -u mnt_id
    rm mi_ext.img
fi

if [ -f "system.img" ]; then
    mkdir -p mnt_id
    erofsfuse system.img mnt_id
    if [ -f "mnt_id/system/build.prop" ]; then SYS_PROP="mnt_id/system/build.prop"; else SYS_PROP=$(find mnt_id -name "build.prop" | head -n 1); fi

    if [ -z "$DEVICE_CODE" ]; then
        DEVICE_CODE=$(grep "ro.product.device=" "$SYS_PROP" | head -1 | cut -d'=' -f2)
        if [ -z "$DEVICE_CODE" ]; then DEVICE_CODE=$(grep "ro.product.system.device=" "$SYS_PROP" | head -1 | cut -d'=' -f2); fi
    fi
    OS_VER=$(grep "ro.system.build.version.incremental=" "$SYS_PROP" | head -1 | cut -d'=' -f2)
    fusermount -u mnt_id
    rmdir mnt_id
    rm system.img
fi

if [ -z "$DEVICE_CODE" ]; then echo "❌ CRITICAL: Detection Failed!"; exit 1; fi

echo "✅  Identity: $DEVICE_CODE | $OS_VER"

SUPER_SIZE=$(jq -r --arg dev "$DEVICE_CODE" '.[$dev].super_size' "$GITHUB_WORKSPACE/devices.json")
if [ "$SUPER_SIZE" == "null" ] || [ -z "$SUPER_SIZE" ]; then echo "❌  DEVICE UNKNOWN: '$DEVICE_CODE' - Add to devices.json"; exit 1; fi

# 6. MODDING ENGINE
LPM_ARGS=""
PARTITIONS="system system_dlkm vendor vendor_dlkm product odm mi_ext"
FOUND_PARTITIONS=false

for part in $PARTITIONS; do
    echo "🔄 Processing: $part"
    payload-dumper-go -p "$part" -o . payload.bin > /dev/null 2>&1
    
    if [ -f "${part}.img" ]; then
        FOUND_PARTITIONS=true
        mkdir -p "${part}_dump" "mnt_point"
        
        erofsfuse "${part}.img" "mnt_point"
        cp -a "mnt_point/." "${part}_dump/"
        fusermount -u "mnt_point"
        rmdir "mnt_point"
        rm "${part}.img"
        
        if [ -d "$GITHUB_WORKSPACE/mods/$part" ]; then
            echo "    -> Injecting Mods..."
            cp -r "$GITHUB_WORKSPACE/mods/$part/"* "${part}_dump/"
        fi
        
        mkfs.erofs -zlz4 "${part}_mod.img" "${part}_dump"
        if [ $? -ne 0 ]; then
            echo "❌ CRITICAL: Failed to compress $part!"
            exit 1
        fi
        
        rm -rf "${part}_dump"
        
        IMG_SIZE=$(stat -c%s "${part}_mod.img")
        LPM_ARGS="$LPM_ARGS --partition ${part}:readonly:${IMG_SIZE}:main --image ${part}=${part}_mod.img"
    else
        echo "    (Skipped)"
    fi
done

rm payload.bin

if [ "$FOUND_PARTITIONS" = false ]; then echo "❌ CRITICAL: No partitions found!"; exit 1; fi

# 7. BUILD SUPER IMAGE (VIA DOCKER)
echo "🔨  Building Super (Using Docker Container)..."
echo "    Max Size: $SUPER_SIZE"

# We use Docker to run an older Ubuntu (20.04) where lpmake works perfectly.
# This bypasses all library errors on the host.
docker run --rm -v "$GITHUB_WORKSPACE":/work -w /work ubuntu:20.04 bash -c "
    apt-get update && apt-get install -y libssl1.1 libncurses5 && 
    ./bin/lpmake --metadata-size 65536 --super-name super --metadata-slots 2 \
    --device super:$SUPER_SIZE --group main:$SUPER_SIZE \
    $LPM_ARGS --output /work/NexMod_Output/images/super.img
"

if [ ! -f "$IMAGES_DIR/super.img" ]; then
    echo "❌ CRITICAL: Docker build failed."
    exit 1
fi

echo "✅ Super Image Created Successfully!"

# 8. FINALIZE & UPLOAD
cd "$OUTPUT_DIR"
python3 "$GITHUB_WORKSPACE/gen_scripts.py" "$DEVICE_CODE" "images"

echo "📥  Bundling ADB..."
wget -q https://dl.google.com/android/repository/platform-tools-latest-windows.zip
unzip -q platform-tools-latest-windows.zip && mv platform-tools/* tools/ && rm -rf platform-tools*

ZIP_NAME="ota_NexDroid_${DEVICE_CODE}_${OS_VER}.zip"
echo "📦  Zipping..."
zip -r -q "$ZIP_NAME" .

echo "☁️  Uploading to PixelDrain..."
if [ -z "$PIXELDRAIN_KEY" ]; then
    RESPONSE=$(curl -s -T "$ZIP_NAME" "https://pixeldrain.com/api/file/")
else
    RESPONSE=$(curl -s -T "$ZIP_NAME" -u :$PIXELDRAIN_KEY "https://pixeldrain.com/api/file/")
fi

FILE_ID=$(echo $RESPONSE | jq -r '.id')
if [ "$FILE_ID" == "null" ] || [ -z "$FILE_ID" ]; then echo "❌ Upload Failed: $RESPONSE"; exit 1; fi

DOWNLOAD_LINK="https://pixeldrain.com/u/$FILE_ID"
echo "✅ DONE! Link: $DOWNLOAD_LINK"
