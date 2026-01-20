#!/bin/bash

ROM_URL="$1"
GITHUB_WORKSPACE=$(pwd)
BIN_DIR="$GITHUB_WORKSPACE/bin"
OUTPUT_DIR="$GITHUB_WORKSPACE/NexMod_Output"
IMAGES_DIR="$OUTPUT_DIR/images"
TOOLS_DIR="$OUTPUT_DIR/tools"
TEMP_DIR="$GITHUB_WORKSPACE/temp"

# 1. SETUP & AUTO-INSTALL TOOLS
echo "🛠️  Setting up Environment..."
mkdir -p "$IMAGES_DIR" "$TOOLS_DIR" "$TEMP_DIR"
chmod +x "$BIN_DIR"/*
export PATH="$BIN_DIR:$PATH"

# Install System Tools (Includes erofs-utils!)
sudo apt-get update -y
sudo apt-get install -y python3 python3-pip erofs-utils jq aria2 zip unzip

# AUTO-DOWNLOAD PAYLOAD DUMPER (No need to upload anymore)
echo "⬇️  Fetching Tools..."
wget -q https://github.com/ssut/payload-dumper-go/releases/download/1.2.2/payload-dumper-go_1.2.2_linux_amd64.tar.gz
tar -xzf payload-dumper-go_1.2.2_linux_amd64.tar.gz
mv payload-dumper-go_1.2.2_linux_amd64/payload-dumper-go "$BIN_DIR/"
chmod +x "$BIN_DIR/payload-dumper-go"

# 2. DOWNLOAD ROM
echo "⬇️  Downloading ROM..."
cd "$TEMP_DIR"
aria2c -x 16 -s 16 -o "rom.zip" "$ROM_URL"
unzip -o "rom.zip" payload.bin
rm "rom.zip"

# 3. DUMP FIRMWARE
echo "🔍 Dumping Images..."
payload-dumper-go -o raw_images payload.bin
rm payload.bin

# Move firmware
cd raw_images
mv boot.img dtbo.img vendor_boot.img recovery.img init_boot.img "$IMAGES_DIR/" 2>/dev/null
mv vbmeta.img vbmeta_system.img vbmeta_vendor.img "$IMAGES_DIR/" 2>/dev/null

# 4. DETECT DEVICE
echo "🕵️  Detecting Device..."
# Use mkfs.erofs (System Standard Name) instead of erofs_mkfs
extract.erofs -i system.img -x -o extracted_system
BUILD_PROP="extracted_system/system/build.prop"

DEVICE_CODE=$(grep "ro.product.device=" "$BUILD_PROP" | head -1 | cut -d'=' -f2)
OS_VER=$(grep "ro.system.build.version.incremental=" "$BUILD_PROP" | head -1 | cut -d'=' -f2)
ANDROID_VER=$(grep "ro.system.build.version.release=" "$BUILD_PROP" | head -1 | cut -d'=' -f2)
rm -rf extracted_system

echo "✅  Identity: $DEVICE_CODE | $OS_VER"

SUPER_SIZE=$(jq -r --arg dev "$DEVICE_CODE" '.[$dev].super_size' "$GITHUB_WORKSPACE/devices.json")
if [ "$SUPER_SIZE" == "null" ]; then
    echo "❌  DEVICE UNKNOWN! Update devices.json."
    exit 1
fi

# 5. MOD & REPACK
LPM_ARGS=""
for part in system system_dlkm vendor vendor_dlkm product odm mi_ext; do
    if [ -f "${part}.img" ]; then
        echo "⚙️  Modding: $part"
        
        # Unpack
        extract.erofs -i "${part}.img" -x -o "${part}_dump"
        rm "${part}.img"
        
        # Inject Mods
        if [ -d "$GITHUB_WORKSPACE/mods/$part" ]; then
            cp -r "$GITHUB_WORKSPACE/mods/$part/"* "${part}_dump/"
        fi
        
        # Repack (Using system mkfs.erofs)
        mkfs.erofs -zLZ4HC "${part}_mod.img" "${part}_dump"
        rm -rf "${part}_dump"
        
        IMG_SIZE=$(stat -c%s "${part}_mod.img")
        LPM_ARGS="$LPM_ARGS --partition ${part}:readonly:${IMG_SIZE}:main --image ${part}=${part}_mod.img"
    fi
done

# 6. BUILD SUPER (Uses your uploaded lpmake)
echo "🔨  Building Super..."
lpmake --metadata-size 65536 --super-name super --metadata-slots 2 \
       --device super:$SUPER_SIZE --group main:$SUPER_SIZE \
       $LPM_ARGS --output "$IMAGES_DIR/super.img"

# 7. FINALIZE
cd "$OUTPUT_DIR"
python3 "$GITHUB_WORKSPACE/gen_scripts.py" "$DEVICE_CODE" "images"

# Get ADB
wget -q https://dl.google.com/android/repository/platform-tools-latest-windows.zip
unzip -q platform-tools-latest-windows.zip && mv platform-tools/* tools/ && rm -rf platform-tools*

# 8. UPLOAD
ZIP_NAME="ota_NexDroid_${DEVICE_CODE}_${OS_VER}.zip"
zip -r -q "$ZIP_NAME" .
curl -T "$ZIP_NAME" -u : https://pixeldrain.com/api/file/
