#!/bin/bash

# =========================================================
#  NEXDROID GOONER - FULL FASTBOOT ROM EDITION
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

# 2. PREPARE TOOLS (Fixed Download Logic)
echo "⬇️  Fetching Toolchain..."
rm -rf "$OTATOOLS_DIR" "$FINAL_TOOLS_DIR"
mkdir -p "$OTATOOLS_DIR" "$FINAL_TOOLS_DIR"

# Use curl -L to handle redirects correctly
curl -L -o "otatools.zip" "https://github.com/SebaUbuntu/otatools-build/releases/download/v0.0.1/otatools.zip"
unzip -q "otatools.zip" -d "$OTATOOLS_DIR"
rm "otatools.zip"

# Find lpmake and flatten
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

# 4. EXTRACT EVERYTHING (Firmware + Logic Partitions)
echo "🔍 Extracting Full Suite..."
# This list matches your requested script + logical partitions for super
payload-dumper-go -p abl,bluetooth,countrycode,devcfg,dsp,dtbo,featenabler,hyp,imagefv,keymaster,modem,qupfw,rpm,tz,uefisecapp,vbmeta,vbmeta_system,vbmeta_vendor,xbl,xbl_config,boot,init_boot,vendor_boot,cust,logo,splash,system,system_dlkm,vendor,vendor_dlkm,product,odm,mi_ext -o "$IMAGES_DIR" payload.bin > /dev/null 2>&1

# 5. DETECT DEVICE
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

# Fallback
if [ -z "$DEVICE_CODE" ]; then
    # Try getting it from system build.prop extraction if mi_ext failed
    # (Simplified for brevity, assuming mi_ext works on HyperOS)
    echo "⚠️ Warning: Could not detect device code. Defaulting to 'generic'."
    DEVICE_CODE="generic"
fi
echo "✅  Device: $DEVICE_CODE"

SUPER_SIZE=$(jq -r --arg dev "$DEVICE_CODE" '.[$dev].super_size' "$GITHUB_WORKSPACE/devices.json")
if [ "$SUPER_SIZE" == "null" ] || [ -z "$SUPER_SIZE" ]; then echo "❌  DEVICE UNKNOWN: '$DEVICE_CODE'"; exit 1; fi

# 6. BUILD SUPER.IMG (Docker Method)
echo "🔨  Building Super..."
LPM_ARGS=""
LOGICAL_PARTS="system system_dlkm vendor vendor_dlkm product odm mi_ext"

# Compress Logical Partitions first
for part in $LOGICAL_PARTS; do
    if [ -f "$IMAGES_DIR/${part}.img" ]; then
        echo "    -> Processing $part..."
        # Extract EROFS to raw folder
        mkdir -p "${part}_dump" "mnt_point"
        erofsfuse "$IMAGES_DIR/${part}.img" "mnt_point"
        cp -a "mnt_point/." "${part}_dump/"
        fusermount -u "mnt_point"
        rmdir "mnt_point"
        rm "$IMAGES_DIR/${part}.img" # Delete original to save space
        
        # Inject Mods (Optional)
        if [ -d "$GITHUB_WORKSPACE/mods/$part" ]; then
            cp -r "$GITHUB_WORKSPACE/mods/$part/"* "${part}_dump/"
        fi
        
        # Repack to EROFS (lz4)
        mkfs.erofs -zlz4 "$IMAGES_DIR/${part}.img" "${part}_dump"
        rm -rf "${part}_dump"
        
        IMG_SIZE=$(stat -c%s "$IMAGES_DIR/${part}.img")
        LPM_ARGS="$LPM_ARGS --partition ${part}:readonly:${IMG_SIZE}:main --image ${part}=/work/NexMod_Output/images/${part}.img"
    fi
done

# Build Super using Docker (Ubuntu 20.04 for compatibility)
docker run --rm -v "$GITHUB_WORKSPACE":/work -w /work ubuntu:20.04 bash -c "
    apt-get update -qq && apt-get install -y libssl1.1 libncurses5 > /dev/null 2>&1 &&
    export PATH=/work/flat_tools:\$PATH &&
    export LD_LIBRARY_PATH=/work/flat_tools/lib64:\$LD_LIBRARY_PATH &&
    /work/flat_tools/lpmake --metadata-size 65536 --super-name super --metadata-slots 2 \
    --device super:$SUPER_SIZE --group main:$SUPER_SIZE \
    $LPM_ARGS --output /work/NexMod_Output/images/super.img
"

if [ ! -f "$IMAGES_DIR/super.img" ]; then
    echo "❌ CRITICAL: Super image failed to build."
    exit 1
fi

# Clean up logical partitions (we only need super.img now)
for part in $LOGICAL_PARTS; do rm -f "$IMAGES_DIR/${part}.img"; done

# 7. FINALIZE
cd "$OUTPUT_DIR"
# Run your new Python script to make the batch file
python3 "$GITHUB_WORKSPACE/gen_scripts.py" "$DEVICE_CODE" "images"

echo "📥  Bundling ADB..."
wget -q https://dl.google.com/android/repository/platform-tools-latest-windows.zip
unzip -q platform-tools-latest-windows.zip && mv platform-tools/* tools/ && rm -rf platform-tools*
mkdir -p bin/windows
mv tools/* bin/windows/

ZIP_NAME="Fastboot_NexDroid_${DEVICE_CODE}.zip"
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
