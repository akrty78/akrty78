#!/bin/bash

# =========================================================
#  NEXDROID GOONER - PATH FINDER EDITION
# =========================================================

ROM_URL="$1"
GITHUB_WORKSPACE=$(pwd)
BIN_DIR="$GITHUB_WORKSPACE/bin"
OUTPUT_DIR="$GITHUB_WORKSPACE/NexMod_Output"
IMAGES_DIR="$OUTPUT_DIR/images"
TOOLS_DIR="$OUTPUT_DIR/tools"
TEMP_DIR="$GITHUB_WORKSPACE/temp"
OTATOOLS_DIR="$GITHUB_WORKSPACE/otatools"
FINAL_TOOLS_DIR="$GITHUB_WORKSPACE/flat_tools" # New Clean Dir

# 1. SETUP
echo "🛠️  Setting up Environment..."
mkdir -p "$IMAGES_DIR" "$TOOLS_DIR" "$TEMP_DIR" "$OTATOOLS_DIR" "$FINAL_TOOLS_DIR"
chmod +x "$BIN_DIR"/*
export PATH="$BIN_DIR:$PATH"

# Install basics
sudo apt-get update -y
sudo apt-get install -y python3 python3-pip erofs-utils erofsfuse jq aria2 zip unzip liblz4-tool

# 2. PREPARE TOOLS (With flattening logic)
echo "⬇️  Fetching & Flattening Toolchain..."

# Download SebaUbuntu's verified OTATools
wget -q -O "otatools.zip" "https://github.com/SebaUbuntu/otatools-build/releases/download/v0.0.1/otatools.zip"
unzip -q "otatools.zip" -d "$OTATOOLS_DIR"
rm "otatools.zip"

# FIND LPMAKE AND MOVE PARENT FOLDER
# This finds 'lpmake' anywhere inside otatools/ and saves its directory path
LPMAKE_PATH=$(find "$OTATOOLS_DIR" -name "lpmake" -type f | head -n 1)

if [ -z "$LPMAKE_PATH" ]; then
    echo "❌ CRITICAL: lpmake binary not found in downloaded zip!"
    find "$OTATOOLS_DIR" -maxdepth 3 # Debug print
    exit 1
fi

echo "    Found lpmake at: $LPMAKE_PATH"
SOURCE_BIN_DIR=$(dirname "$LPMAKE_PATH")   # e.g., .../bin
SOURCE_ROOT_DIR=$(dirname "$SOURCE_BIN_DIR") # e.g., .../otatools

# Move contents to clean folder to avoid nested paths
echo "    Moving tools to: $FINAL_TOOLS_DIR"
cp -r "$SOURCE_ROOT_DIR/"* "$FINAL_TOOLS_DIR/"
chmod -R 777 "$FINAL_TOOLS_DIR"

# 3. DOWNLOAD PAYLOAD DUMPER
if [ ! -f "$BIN_DIR/payload-dumper-go" ]; then
    wget -q https://github.com/ssut/payload-dumper-go/releases/download/1.2.2/payload-dumper-go_1.2.2_linux_amd64.tar.gz
    tar -xzf payload-dumper-go_1.2.2_linux_amd64.tar.gz
    find . -type f -name "payload-dumper-go" -not -path "*/bin/*" -exec mv {} "$BIN_DIR/" \;
    chmod +x "$BIN_DIR/payload-dumper-go"
fi

# 4. DOWNLOAD ROM
echo "⬇️  Downloading ROM..."
cd "$TEMP_DIR"
aria2c -x 16 -s 16 --file-allocation=none -o "rom.zip" "$ROM_URL"
unzip -o "rom.zip" payload.bin
rm "rom.zip"

# 5. EXTRACT FIRMWARE
echo "🔍 Extracting Firmware..."
payload-dumper-go -p boot,dtbo,vendor_boot,recovery,init_boot,vbmeta,vbmeta_system,vbmeta_vendor -o "$IMAGES_DIR" payload.bin > /dev/null 2>&1

# 6. SMART DETECTION
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

# 7. MODDING ENGINE
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

# 8. BUILD SUPER IMAGE (Docker 18.04 + Flatted Path)
echo "🔨  Building Super..."
echo "    Max Size: $SUPER_SIZE"

# We map /work to GITHUB_WORKSPACE.
# We expect tools in /work/flat_tools/bin/lpmake
docker run --rm -v "$GITHUB_WORKSPACE":/work -w /work ubuntu:18.04 bash -c "
    echo '    -> Docker: Installing basics...' &&
    apt-get update -qq && apt-get install -y libssl1.0.0 libncurses5 > /dev/null 2>&1 || true &&
    
    echo '    -> Docker: Setting up paths...' &&
    export PATH=/work/flat_tools/bin:\$PATH &&
    export LD_LIBRARY_PATH=/work/flat_tools/lib64:\$LD_LIBRARY_PATH &&
    
    echo '    -> Docker: Verifying binary...' &&
    ls -l /work/flat_tools/bin/lpmake && 
    
    echo '    -> Docker: Running Build...' &&
    /work/flat_tools/bin/lpmake --metadata-size 65536 --super-name super --metadata-slots 2 \
    --device super:$SUPER_SIZE --group main:$SUPER_SIZE \
    $LPM_ARGS --output /work/NexMod_Output/images/super.img
"

if [ ! -f "$IMAGES_DIR/super.img" ]; then
    echo "❌ CRITICAL: Docker build failed (See logs above)."
    exit 1
fi

echo "✅ Super Image Created Successfully!"

# 9. FINALIZE & UPLOAD
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
