#!/bin/bash

ROM_URL="$1"
GITHUB_WORKSPACE=$(pwd)
BIN_DIR="$GITHUB_WORKSPACE/bin"
OUTPUT_DIR="$GITHUB_WORKSPACE/NexMod_Output"
IMAGES_DIR="$OUTPUT_DIR/images"
TOOLS_DIR="$OUTPUT_DIR/tools"
TEMP_DIR="$GITHUB_WORKSPACE/temp"

# 1. SETUP
echo "🛠️  Setting up..."
mkdir -p "$IMAGES_DIR" "$TOOLS_DIR" "$TEMP_DIR"
chmod +x "$BIN_DIR"/*
export PATH="$BIN_DIR:$PATH"
sudo apt-get update -y && sudo apt-get install -y python3 python3-pip erofs-utils jq aria2 zip unzip

# 2. DOWNLOAD & EXTRACT
echo "⬇️  Downloading..."
cd "$TEMP_DIR"
aria2c -x 16 -s 16 -o "rom.zip" "$ROM_URL"
unzip -o "rom.zip" payload.bin
payload-dumper-go -o raw_images payload.bin
rm "rom.zip" payload.bin

# Move firmware to output
cd raw_images
mv boot.img dtbo.img vendor_boot.img recovery.img init_boot.img "$IMAGES_DIR/" 2>/dev/null
mv vbmeta.img vbmeta_system.img vbmeta_vendor.img "$IMAGES_DIR/" 2>/dev/null

# 3. DETECT DEVICE & SAFETY CHECK
extract.erofs -i system.img -x -o extracted_system
BUILD_PROP="extracted_system/system/build.prop"
DEVICE_CODE=$(grep "ro.product.device=" "$BUILD_PROP" | head -1 | cut -d'=' -f2)
OS_VER=$(grep "ro.system.build.version.incremental=" "$BUILD_PROP" | head -1 | cut -d'=' -f2)
ANDROID_VER=$(grep "ro.system.build.version.release=" "$BUILD_PROP" | head -1 | cut -d'=' -f2)
rm -rf extracted_system

echo "✅  Device: $DEVICE_CODE | OS: $OS_VER | Android: $ANDROID_VER"

SUPER_SIZE=$(jq -r --arg dev "$DEVICE_CODE" '.[$dev].super_size' "$GITHUB_WORKSPACE/devices.json")
if [ "$SUPER_SIZE" == "null" ]; then
    echo "❌  DEVICE UNKNOWN! Add '$DEVICE_CODE' to devices.json to proceed."
    exit 1
fi

# 4. MODDING & REPACKING LOOP
LPM_ARGS=""
# Detect ALL dynamic partitions (including dlkm and mi_ext)
for part in system system_dlkm vendor vendor_dlkm product odm mi_ext; do
    if [ -f "${part}.img" ]; then
        echo "⚙️  Modding: $part"
        
        # A. Unpack
        extract.erofs -i "${part}.img" -x -o "${part}_dump"
        rm "${part}.img"
        
        # B. Inject Mods (If folder exists in your repo)
        if [ -d "$GITHUB_WORKSPACE/mods/$part" ]; then
            echo "    -> Injecting custom files..."
            cp -r "$GITHUB_WORKSPACE/mods/$part/"* "${part}_dump/"
        fi
        
        # C. Repack EROFS
        mkfs.erofs -zLZ4HC "${part}_mod.img" "${part}_dump"
        rm -rf "${part}_dump"
        
        # D. Add to Super map
        IMG_SIZE=$(stat -c%s "${part}_mod.img")
        LPM_ARGS="$LPM_ARGS --partition ${part}:readonly:${IMG_SIZE}:main --image ${part}=${part}_mod.img"
    fi
done

# 5. BUILD SUPER
echo "🔨  Building Super ($SUPER_SIZE bytes)..."
lpmake --metadata-size 65536 --super-name super --metadata-slots 2 \
       --device super:$SUPER_SIZE --group main:$SUPER_SIZE \
       $LPM_ARGS --output "$IMAGES_DIR/super.img"

# 6. FINALIZE
cd "$OUTPUT_DIR"
python3 "$GITHUB_WORKSPACE/gen_scripts.py" "$DEVICE_CODE" "images"

# Get ADB Tools
wget -q https://dl.google.com/android/repository/platform-tools-latest-windows.zip
unzip -q platform-tools-latest-windows.zip && mv platform-tools/* tools/ && rm -rf platform-tools*

# 7. ZIP & UPLOAD
ZIP_NAME="ota_NexDroid_Extended_${DEVICE_CODE}_${OS_VER}_A${ANDROID_VER}.zip"
echo "📦  Zipping $ZIP_NAME..."
zip -r -q "$ZIP_NAME" .

echo "☁️  Uploading..."
curl -T "$ZIP_NAME" -u : https://pixeldrain.com/api/file/
