#!/bin/bash

# =========================================================
#  NEXDROID GOONER - COMPLETE EDITION
# =========================================================

ROM_URL="$1"
GITHUB_WORKSPACE=$(pwd)
BIN_DIR="$GITHUB_WORKSPACE/bin"
OUTPUT_DIR="$GITHUB_WORKSPACE/NexMod_Output"
IMAGES_DIR="$OUTPUT_DIR/images"
TOOLS_DIR="$OUTPUT_DIR/tools"
TEMP_DIR="$GITHUB_WORKSPACE/temp"
OTATOOLS_DIR="$GITHUB_WORKSPACE/otatools"
FINAL_TOOLS_DIR="$GITHUB_WORKSPACE/flat_tools"

# 1. SETUP
echo "🛠️  Setting up Environment..."
mkdir -p "$IMAGES_DIR" "$TOOLS_DIR" "$TEMP_DIR" "$OTATOOLS_DIR" "$FINAL_TOOLS_DIR"
chmod +x "$BIN_DIR"/*
export PATH="$BIN_DIR:$PATH"

sudo apt-get update -y
sudo apt-get install -y python3 python3-pip erofs-utils erofsfuse jq aria2 zip unzip liblz4-tool

# 2. PREPARE BUILD TOOLS (Robust Download)
echo "⬇️  Fetching Build Tools..."
rm -rf "$OTATOOLS_DIR" "$FINAL_TOOLS_DIR"
mkdir -p "$OTATOOLS_DIR" "$FINAL_TOOLS_DIR"

# Download OTATools with curl -L to fix redirects
curl -L -o "otatools.zip" "https://github.com/SebaUbuntu/otatools-build/releases/download/v0.0.1/otatools.zip"
unzip -q "otatools.zip" -d "$OTATOOLS_DIR"
rm "otatools.zip"

# Find lpmake (Path Finder Fix)
LPMAKE_PATH=$(find "$OTATOOLS_DIR" -name "lpmake" -type f | head -n 1)
SOURCE_DIR=$(dirname "$LPMAKE_PATH")
cp -r "$SOURCE_DIR/"* "$FINAL_TOOLS_DIR/"
chmod -R 777 "$FINAL_TOOLS_DIR"

# Download Payload Dumper
if [ ! -f "$BIN_DIR/payload-dumper-go" ]; then
    curl -L -o pd.tar.gz https://github.com/ssut/payload-dumper-go/releases/download/1.2.2/payload-dumper-go_1.2.2_linux_amd64.tar.gz
    tar -xzf pd.tar.gz
    find . -type f -name "payload-dumper-go" -not -path "*/bin/*" -exec mv {} "$BIN_DIR/" \;
    chmod +x "$BIN_DIR/payload-dumper-go"
fi

# 3. DOWNLOAD ROM
echo "⬇️  Downloading ROM..."
cd "$TEMP_DIR"
aria2c -x 16 -s 16 --file-allocation=none -o "rom.zip" "$ROM_URL"
unzip -o "rom.zip" payload.bin
rm "rom.zip"

# 4. EXTRACT EVERYTHING
echo "🔍 Extracting Full Partition Suite..."
PARTITIONS="abl,bluetooth,countrycode,devcfg,dsp,dtbo,featenabler,hyp,imagefv,keymaster,modem,qupfw,rpm,tz,uefisecapp,vbmeta,vbmeta_system,vbmeta_vendor,xbl,xbl_config,boot,init_boot,vendor_boot,recovery,cust,logo,splash,system,system_dlkm,vendor,vendor_dlkm,product,odm,mi_ext"

payload-dumper-go -p $PARTITIONS -o "$IMAGES_DIR" payload.bin > /dev/null 2>&1

# 5. DETECT DEVICE
echo "🕵️  Detecting Device..."
DEVICE_CODE=""
# Try mi_ext first
if [ -f "$IMAGES_DIR/mi_ext.img" ]; then
    mkdir -p mnt_id
    erofsfuse "$IMAGES_DIR/mi_ext.img" mnt_id
    if [ -f "mnt_id/etc/build.prop" ]; then
        RAW_CODE=$(grep "ro.product.mod_device=" "mnt_id/etc/build.prop" | head -1 | cut -d'=' -f2)
        DEVICE_CODE=$(echo "$RAW_CODE" | cut -d'_' -f1)
    fi
    fusermount -u mnt_id
fi

# Fallback to system
if [ -z "$DEVICE_CODE" ] && [ -f "$IMAGES_DIR/system.img" ]; then
    mkdir -p mnt_id
    erofsfuse "$IMAGES_DIR/system.img" mnt_id
    if [ -f "mnt_id/system/build.prop" ]; then
         DEVICE_CODE=$(grep "ro.product.device=" "mnt_id/system/build.prop" | head -1 | cut -d'=' -f2)
    fi
    fusermount -u mnt_id
fi

if [ -z "$DEVICE_CODE" ]; then DEVICE_CODE="generic"; fi
echo "✅  Device Code: $DEVICE_CODE"

SUPER_SIZE=$(jq -r --arg dev "$DEVICE_CODE" '.[$dev].super_size' "$GITHUB_WORKSPACE/devices.json")

# 6. BUILD SUPER IMG (Docker)
if [ "$SUPER_SIZE" != "null" ] && [ ! -z "$SUPER_SIZE" ]; then
    echo "🔨  Building Super (Size: $SUPER_SIZE)..."
    LPM_ARGS=""
    LOGICALS="system system_dlkm vendor vendor_dlkm product odm mi_ext"
    
    # Compress Logicals
    for part in $LOGICALS; do
        if [ -f "$IMAGES_DIR/${part}.img" ]; then
            mkdir -p "${part}_dump" "mnt_point"
            erofsfuse "$IMAGES_DIR/${part}.img" "mnt_point"
            cp -a "mnt_point/." "${part}_dump/"
            fusermount -u "mnt_point"
            rmdir "mnt_point"
            rm "$IMAGES_DIR/${part}.img"
            
            # Inject Mods Here if needed
            if [ -d "$GITHUB_WORKSPACE/mods/$part" ]; then
                cp -r "$GITHUB_WORKSPACE/mods/$part/"* "${part}_dump/"
            fi
            
            mkfs.erofs -zlz4 "$IMAGES_DIR/${part}.img" "${part}_dump"
            rm -rf "${part}_dump"
            
            IMG_SIZE=$(stat -c%s "$IMAGES_DIR/${part}.img")
            LPM_ARGS="$LPM_ARGS --partition ${part}:readonly:${IMG_SIZE}:main --image ${part}=/work/NexMod_Output/images/${part}.img"
        fi
    done
    
    # Run Docker Build
    docker run --rm -v "$GITHUB_WORKSPACE":/work -w /work ubuntu:20.04 bash -c "
        apt-get update -qq && apt-get install -y libssl1.1 libncurses5 > /dev/null 2>&1 &&
        export PATH=/work/flat_tools:\$PATH &&
        export LD_LIBRARY_PATH=/work/flat_tools/lib64:\$LD_LIBRARY_PATH &&
        /work/flat_tools/lpmake --metadata-size 65536 --super-name super --metadata-slots 2 \
        --device super:$SUPER_SIZE --group main:$SUPER_SIZE \
        $LPM_ARGS --output /work/NexMod_Output/images/super.img
    "
    
    # Cleanup logicals
    for part in $LOGICALS; do rm -f "$IMAGES_DIR/${part}.img"; done
else
    echo "⚠️  Skipping Super Build (Device not in JSON or Size Unknown)"
fi

# 7. BUNDLE PLATFORM TOOLS
echo "📥  Bundling Platform Tools..."
cd "$OUTPUT_DIR"

# Download Google's tools
curl -L -o tools.zip https://dl.google.com/android/repository/platform-tools-latest-windows.zip
unzip -q tools.zip && mkdir -p bin/windows && mv platform-tools/* bin/windows/ && rm -rf platform-tools tools.zip

curl -L -o tools.zip https://dl.google.com/android/repository/platform-tools-latest-linux.zip
unzip -q tools.zip && mkdir -p bin/linux && mv platform-tools/* bin/linux/ && rm -rf platform-tools tools.zip

curl -L -o tools.zip https://dl.google.com/android/repository/platform-tools-latest-darwin.zip
unzip -q tools.zip && mkdir -p bin/macos && mv platform-tools/* bin/macos/ && rm -rf platform-tools tools.zip

# 8. GENERATE SCRIPTS & UPLOAD
python3 "$GITHUB_WORKSPACE/gen_scripts.py" "$DEVICE_CODE" "images"

ZIP_NAME="NexDroid_${DEVICE_CODE}_FullROM.zip"
echo "📦  Zipping..."
zip -r -q "$ZIP_NAME" .

echo "☁️  Uploading..."
if [ -z "$PIXELDRAIN_KEY" ]; then
    RESPONSE=$(curl -s -T "$ZIP_NAME" "https://pixeldrain.com/api/file/")
else
    RESPONSE=$(curl -s -T "$ZIP_NAME" -u :$PIXELDRAIN_KEY "https://pixeldrain.com/api/file/")
fi

FILE_ID=$(echo $RESPONSE | jq -r '.id')
if [ "$FILE_ID" == "null" ] || [ -z "$FILE_ID" ]; then echo "❌ Upload Failed"; exit 1; fi

echo "✅ DONE! https://pixeldrain.com/u/$FILE_ID"
