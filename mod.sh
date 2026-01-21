#!/bin/bash

# =========================================================
#  NEXDROID GOONER - RELIABLE DOWNLOAD EDITION
# =========================================================

ROM_URL="$1"
GITHUB_WORKSPACE=$(pwd)
BIN_DIR="$GITHUB_WORKSPACE/bin"
OUTPUT_DIR="$GITHUB_WORKSPACE/NexMod_Output"
IMAGES_DIR="$OUTPUT_DIR/images"
TOOLS_DIR="$OUTPUT_DIR/tools"
TEMP_DIR="$GITHUB_WORKSPACE/temp"
OTATOOLS_DIR="$GITHUB_WORKSPACE/otatools"

# 1. SETUP
echo "🛠️  Setting up Environment..."
mkdir -p "$IMAGES_DIR" "$TOOLS_DIR" "$TEMP_DIR" "$OTATOOLS_DIR"
chmod +x "$BIN_DIR"/*
export PATH="$BIN_DIR:$PATH"

sudo apt-get update -y
sudo apt-get install -y python3 python3-pip erofs-utils erofsfuse jq aria2 zip unzip liblz4-tool

# 2. PREPARE TOOLS (ROBUST DOWNLOADER)
echo "⬇️  Fetching Build Tools..."
rm -rf "$OTATOOLS_DIR"
mkdir -p "$OTATOOLS_DIR"

# Try Primary Source (GitHub)
echo "    -> Attempting Source 1..."
wget -q -O "otatools.zip" "https://github.com/SebaUbuntu/otatools-build/releases/download/v0.0.1/otatools.zip"

# Check size (Must be > 1MB)
FILE_SIZE=$(stat -c%s "otatools.zip")
if [ "$FILE_SIZE" -lt 1000000 ]; then
    echo "⚠️  Source 1 failed (File too small: $FILE_SIZE bytes). Trying Backup..."
    rm otatools.zip
    
    # Try Backup Source (SourceForge - Direct Link)
    # This is a known working mirror for Xiaomi.eu tools
    wget -q -O "otatools.zip" "https://sourceforge.net/projects/xiaomi-eu-multilang-miui-roms/files/xiaomi.eu/MIUI-14/TOOLS/lpmake_linux.zip/download"
fi

# Verify again
if [ ! -f "otatools.zip" ]; then
    echo "❌ CRITICAL: Failed to download tools from both sources!"
    exit 1
fi

unzip -q "otatools.zip" -d "$OTATOOLS_DIR"
rm "otatools.zip"

# FIND LPMAKE (Precision Search)
LPMAKE_BINARY=$(find "$OTATOOLS_DIR" -type f -name "lpmake" | head -n 1)

if [ -z "$LPMAKE_BINARY" ]; then
    echo "❌ CRITICAL: lpmake binary is MISSING from download!"
    # Debug: List what we actually got
    ls -R "$OTATOOLS_DIR"
    exit 1
fi

LPMAKE_BIN_DIR=$(dirname "$LPMAKE_BINARY")
TOOL_ROOT=$(dirname "$LPMAKE_BIN_DIR")

echo "    ✅ Found lpmake at: $LPMAKE_BINARY"
echo "    ✅ Tool Root: $TOOL_ROOT"
chmod -R 777 "$TOOL_ROOT"

# 3. DOWNLOAD PAYLOAD DUMPER
if [ ! -f "$BIN_DIR/payload-dumper-go" ]; then
    curl -L -o pd.tar.gz https://github.com/ssut/payload-dumper-go/releases/download/1.2.2/payload-dumper-go_1.2.2_linux_amd64.tar.gz
    tar -xzf pd.tar.gz
    find . -type f -name "payload-dumper-go" -not -path "*/bin/*" -exec mv {} "$BIN_DIR/" \;
    chmod +x "$BIN_DIR/payload-dumper-go"
fi

# 4. DOWNLOAD ROM
echo "⬇️  Downloading ROM..."
cd "$TEMP_DIR"
aria2c -x 16 -s 16 --file-allocation=none -o "rom.zip" "$ROM_URL"
unzip -o "rom.zip" payload.bin
rm "rom.zip"

# 5. EXTRACT EVERYTHING
echo "🔍 Extracting Full Suite..."
PARTITIONS="abl,bluetooth,countrycode,devcfg,dsp,dtbo,featenabler,hyp,imagefv,keymaster,modem,qupfw,rpm,tz,uefisecapp,vbmeta,vbmeta_system,vbmeta_vendor,xbl,xbl_config,boot,init_boot,vendor_boot,recovery,cust,logo,splash,system,system_dlkm,vendor,vendor_dlkm,product,odm,mi_ext"
payload-dumper-go -p $PARTITIONS -o "$IMAGES_DIR" payload.bin > /dev/null 2>&1

# 6. DETECT DEVICE
echo "🕵️  Detecting Device..."
DEVICE_CODE=""
if [ -f "$IMAGES_DIR/mi_ext.img" ]; then
    mkdir -p mnt_id
    erofsfuse "$IMAGES_DIR/mi_ext.img" mnt_id
    if [ -f "mnt_id/etc/build.prop" ]; then
        RAW_CODE=$(grep "ro.product.mod_device=" "mnt_id/etc/build.prop" | head -1 | cut -d'=' -f2)
        DEVICE_CODE=$(echo "$RAW_CODE" | cut -d'_' -f1)
    fi
    fusermount -u mnt_id
fi

if [ -z "$DEVICE_CODE" ]; then 
    echo "⚠️  Detection Failed! Assuming 'marble'."
    DEVICE_CODE="marble" 
fi
echo "✅  Device Code: $DEVICE_CODE"

SUPER_SIZE=$(jq -r --arg dev "$DEVICE_CODE" '.[$dev].super_size' "$GITHUB_WORKSPACE/devices.json")
if [ "$SUPER_SIZE" == "null" ] || [ -z "$SUPER_SIZE" ]; then 
    echo "⚠️  Size unknown. Using Default: 9126805504"
    SUPER_SIZE="9126805504"
fi

# 7. BUILD SUPER IMG (Docker with Exact Mount)
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
        
        if [ -d "$GITHUB_WORKSPACE/mods/$part" ]; then
            cp -r "$GITHUB_WORKSPACE/mods/$part/"* "${part}_dump/"
        fi
        
        mkfs.erofs -zlz4 "$IMAGES_DIR/${part}.img" "${part}_dump"
        rm -rf "${part}_dump"
        
        IMG_SIZE=$(stat -c%s "$IMAGES_DIR/${part}.img")
        LPM_ARGS="$LPM_ARGS --partition ${part}:readonly:${IMG_SIZE}:main --image ${part}=/work/NexMod_Output/images/${part}.img"
    fi
done

# DOCKER EXECUTION
docker run --rm \
    -v "$GITHUB_WORKSPACE":/work \
    -v "$TOOL_ROOT":/tools \
    -w /work \
    ubuntu:20.04 bash -c "
        echo '    -> Docker: Installing libs...' &&
        apt-get update -qq && apt-get install -y libssl1.1 libncurses5 > /dev/null 2>&1 &&
        
        echo '    -> Docker: Setting paths...' &&
        export PATH=/tools/bin:\$PATH &&
        export LD_LIBRARY_PATH=/tools/lib64:\$LD_LIBRARY_PATH &&
        
        echo '    -> Docker: Building...' &&
        lpmake --metadata-size 65536 --super-name super --metadata-slots 2 \
        --device super:$SUPER_SIZE --group main:$SUPER_SIZE \
        $LPM_ARGS --output /work/NexMod_Output/images/super.img
"

if [ ! -f "$IMAGES_DIR/super.img" ]; then
    echo "❌ CRITICAL: Super image FAILED to build!"
    exit 1
fi

echo "✅ Super Image Success!"
for part in $LOGICALS; do rm -f "$IMAGES_DIR/${part}.img"; done

# 8. BUNDLE PLATFORM TOOLS
echo "📥  Bundling Platform Tools..."
cd "$OUTPUT_DIR"
curl -L -o tools.zip https://dl.google.com/android/repository/platform-tools-latest-windows.zip
unzip -q tools.zip && mkdir -p bin/windows && mv platform-tools/* bin/windows/ && rm -rf platform-tools tools.zip

curl -L -o tools.zip https://dl.google.com/android/repository/platform-tools-latest-linux.zip
unzip -q tools.zip && mkdir -p bin/linux && mv platform-tools/* bin/linux/ && rm -rf platform-tools tools.zip

curl -L -o tools.zip https://dl.google.com/android/repository/platform-tools-latest-darwin.zip
unzip -q tools.zip && mkdir -p bin/macos && mv platform-tools/* bin/macos/ && rm -rf platform-tools tools.zip

# 9. GENERATE SCRIPTS & UPLOAD
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
