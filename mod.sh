#!/bin/bash

# =========================================================
#  NEXDROID GOONER - FIRMWARE ONLY (NO SUPER)
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

sudo apt-get update -y
sudo apt-get install -y python3 python3-pip erofsfuse jq aria2 zip unzip

# 2. DOWNLOAD PAYLOAD DUMPER
if [ ! -f "$BIN_DIR/payload-dumper-go" ]; then
    echo "⬇️  Fetching Payload Dumper..."
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

# 4. EXTRACT FIRMWARE
echo "🔍 Extracting Firmware Images..."
# Exact list of physical partitions
PARTITIONS="abl,bluetooth,countrycode,devcfg,dsp,dtbo,featenabler,hyp,imagefv,keymaster,modem,qupfw,rpm,tz,uefisecapp,vbmeta,vbmeta_system,vbmeta_vendor,xbl,xbl_config,boot,init_boot,vendor_boot,recovery,cust,logo,splash"

payload-dumper-go -p $PARTITIONS -o "$IMAGES_DIR" payload.bin > /dev/null 2>&1

# 5. DETECT DEVICE (For naming)
echo "🕵️  Detecting Device..."
# We extract mi_ext just to read the prop, then delete it
payload-dumper-go -p mi_ext -o . payload.bin > /dev/null 2>&1

DEVICE_CODE=""
if [ -f "mi_ext.img" ]; then
    mkdir -p mnt_id
    erofsfuse mi_ext.img mnt_id
    if [ -f "mnt_id/etc/build.prop" ]; then
        RAW_CODE=$(grep "ro.product.mod_device=" "mnt_id/etc/build.prop" | head -1 | cut -d'=' -f2)
        DEVICE_CODE=$(echo "$RAW_CODE" | cut -d'_' -f1)
    fi
    fusermount -u mnt_id
    rm mi_ext.img
fi

if [ -z "$DEVICE_CODE" ]; then DEVICE_CODE="generic"; fi
echo "✅  Device Code: $DEVICE_CODE"

# 6. FINALIZE
rm payload.bin
cd "$OUTPUT_DIR"

# Generate Bat Script
python3 "$GITHUB_WORKSPACE/gen_scripts.py" "$DEVICE_CODE" "images"

# Get ADB Tools
echo "📥  Bundling ADB..."
wget -q https://dl.google.com/android/repository/platform-tools-latest-windows.zip
unzip -q platform-tools-latest-windows.zip && mv platform-tools/* tools/ && rm -rf platform-tools*
mkdir -p bin/windows
mv tools/* bin/windows/

ZIP_NAME="Firmware_NexDroid_${DEVICE_CODE}.zip"
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
