#!/bin/bash

# =========================================================
#  NEXDROID GOONER - FIRMWARE ONLY EDITION
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

# Install basics (erofsfuse is needed for device detection only)
sudo apt-get update -y
sudo apt-get install -y python3 python3-pip erofsfuse jq aria2 zip unzip

# 2. DOWNLOAD PAYLOAD DUMPER
if [ ! -f "$BIN_DIR/payload-dumper-go" ]; then
    echo "⬇️  Fetching Payload Dumper..."
    wget -q https://github.com/ssut/payload-dumper-go/releases/download/1.2.2/payload-dumper-go_1.2.2_linux_amd64.tar.gz
    tar -xzf payload-dumper-go_1.2.2_linux_amd64.tar.gz
    find . -type f -name "payload-dumper-go" -not -path "*/bin/*" -exec mv {} "$BIN_DIR/" \;
    chmod +x "$BIN_DIR/payload-dumper-go"
fi

# 3. DOWNLOAD ROM
echo "⬇️  Downloading ROM..."
cd "$TEMP_DIR"
aria2c -x 16 -s 16 --file-allocation=none -o "rom.zip" "$ROM_URL"
unzip -o "rom.zip" payload.bin
rm "rom.zip"

# 4. EXTRACT FIRMWARE
echo "🔍 Extracting Firmware Images..."
# We dump all standard boot/recovery partitions
payload-dumper-go -p boot,dtbo,vendor_boot,recovery,init_boot,vbmeta,vbmeta_system,vbmeta_vendor,logo,splash -o "$IMAGES_DIR" payload.bin > /dev/null 2>&1

# Check if we got anything
if [ -z "$(ls -A $IMAGES_DIR)" ]; then
    echo "❌ CRITICAL: No firmware images found! Is the ROM valid?"
    exit 1
fi

echo "    ✅ Extracted: $(ls $IMAGES_DIR | xargs)"

# 5. SMART DETECTION (To name the zip correctly)
echo "🕵️  Detecting Device Identity..."
payload-dumper-go -p mi_ext,system -o . payload.bin > /dev/null 2>&1

DEVICE_CODE=""
OS_VER=""

# Check mi_ext (Best for HyperOS)
if [ -f "mi_ext.img" ]; then
    mkdir -p mnt_id
    erofsfuse mi_ext.img mnt_id
    if [ -f "mnt_id/etc/build.prop" ]; then
        RAW_CODE=$(grep "ro.product.mod_device=" "mnt_id/etc/build.prop" | head -1 | cut -d'=' -f2)
        if [ ! -z "$RAW_CODE" ]; then
            DEVICE_CODE=$(echo "$RAW_CODE" | cut -d'_' -f1)
        fi
    fi
    fusermount -u mnt_id
    rm mi_ext.img
fi

# Check System (Fallback)
if [ -f "system.img" ]; then
    mkdir -p mnt_id
    erofsfuse system.img mnt_id
    if [ -f "mnt_id/system/build.prop" ]; then SYS_PROP="mnt_id/system/build.prop"; else SYS_PROP=$(find mnt_id -name "build.prop" | head -n 1); fi

    if [ -z "$DEVICE_CODE" ]; then
        DEVICE_CODE=$(grep "ro.product.device=" "$SYS_PROP" | head -1 | cut -d'=' -f2)
    fi
    OS_VER=$(grep "ro.system.build.version.incremental=" "$SYS_PROP" | head -1 | cut -d'=' -f2)
    fusermount -u mnt_id
    rmdir mnt_id
    rm system.img
fi

# Fallback if detection totally fails
if [ -z "$DEVICE_CODE" ]; then DEVICE_CODE="UnknownDevice"; fi
if [ -z "$OS_VER" ]; then OS_VER="UnknownVer"; fi

echo "✅  Identity: $DEVICE_CODE | $OS_VER"

# 6. GENERATE SCRIPTS & FINALIZE
rm payload.bin

echo "📜  Generating Flashing Scripts..."
cd "$OUTPUT_DIR"
# This Python script needs to scan images/ and make the bat/sh files
python3 "$GITHUB_WORKSPACE/gen_scripts.py" "$DEVICE_CODE" "images"

echo "📥  Bundling ADB..."
wget -q https://dl.google.com/android/repository/platform-tools-latest-windows.zip
unzip -q platform-tools-latest-windows.zip && mv platform-tools/* tools/ && rm -rf platform-tools*

ZIP_NAME="Firmware_NexDroid_${DEVICE_CODE}_${OS_VER}.zip"
echo "📦  Zipping: $ZIP_NAME"
zip -r -q "$ZIP_NAME" .

echo "☁️  Uploading to PixelDrain..."
if [ -z "$PIXELDRAIN_KEY" ]; then
    RESPONSE=$(curl -s -T "$ZIP_NAME" "https://pixeldrain.com/api/file/")
else
    RESPONSE=$(curl -s -T "$ZIP_NAME" -u :$PIXELDRAIN_KEY "https://pixeldrain.com/api/file/")
fi

FILE_ID=$(echo $RESPONSE | jq -r '.id')
if [ "$FILE_ID" == "null" ] || [ -z "$FILE_ID" ]; then
    echo "❌ Upload Failed: $RESPONSE"
    exit 1
fi

DOWNLOAD_LINK="https://pixeldrain.com/u/$FILE_ID"
echo "✅ DONE! Link: $DOWNLOAD_LINK"
