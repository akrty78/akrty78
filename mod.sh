#!/bin/bash

# =========================================================
#  NEXDROID GOONER - ROM MODDER ENGINE
# =========================================================

ROM_URL="$1"
GITHUB_WORKSPACE=$(pwd)
BIN_DIR="$GITHUB_WORKSPACE/bin"
OUTPUT_DIR="$GITHUB_WORKSPACE/NexMod_Output"
IMAGES_DIR="$OUTPUT_DIR/images"
TOOLS_DIR="$OUTPUT_DIR/tools"
TEMP_DIR="$GITHUB_WORKSPACE/temp"

# 1. SETUP ENVIRONMENT
echo "🛠️  Setting up Environment..."
mkdir -p "$IMAGES_DIR" "$TOOLS_DIR" "$TEMP_DIR"
chmod +x "$BIN_DIR"/*
export PATH="$BIN_DIR:$PATH"

# Install Dependencies
sudo apt-get update -y
sudo apt-get install -y python3 python3-pip android-sdk-libsparse-utils erofs-utils jq aria2 zip unzip

# 2. DOWNLOAD ROM
echo "⬇️  Downloading ROM..."
cd "$TEMP_DIR"
aria2c -x 16 -s 16 -o "official_rom.zip" "$ROM_URL"

# 3. EXTRACT PAYLOAD
echo "📦 Extracting Payload..."
unzip -o "official_rom.zip" payload.bin
rm "official_rom.zip" # Clean up

# 4. DUMP FIRMWARE
echo "🔍 Dumping Images..."
payload-dumper-go -o raw_images payload.bin
rm payload.bin # Clean up

# Move standard firmware to Output immediately
cd raw_images
mv boot.img dtbo.img vendor_boot.img recovery.img "$IMAGES_DIR/" 2>/dev/null
# Move vbmeta to Output (Patching handled by flash flags in batch script)
mv vbmeta.img vbmeta_system.img vbmeta_vendor.img "$IMAGES_DIR/" 2>/dev/null

# 5. DEVICE DETECTION
echo "🕵️  Detecting Device Identity..."
# We extract system.img just to read build.prop
extract.erofs -i system.img -x -o extracted_system
BUILD_PROP="extracted_system/system/build.prop"

# Read Props
DEVICE_CODE=$(grep "ro.product.device=" "$BUILD_PROP" | head -1 | cut -d'=' -f2)
OS_VER=$(grep "ro.system.build.version.incremental=" "$BUILD_PROP" | head -1 | cut -d'=' -f2)
ANDROID_VER=$(grep "ro.system.build.version.release=" "$BUILD_PROP" | head -1 | cut -d'=' -f2)

echo "✅  Identity: $DEVICE_CODE (HyperOS $OS_VER | Android $ANDROID_VER)"

# 6. SAFETY CHECK (The "Brick Preventer")
SUPER_SIZE=$(jq -r --arg dev "$DEVICE_CODE" '.[$dev].super_size' "$GITHUB_WORKSPACE/devices.json")

if [ "$SUPER_SIZE" == "null" ] || [ -z "$SUPER_SIZE" ]; then
    echo "❌  CRITICAL ERROR: Device '$DEVICE_CODE' is not in devices.json!"
    echo "    Aborting to prevent bricking."
    exit 1
fi
echo "📏  Target Super Size: $SUPER_SIZE bytes"

# 7. THE MODDING LOOP (Dynamic Partition Handling)
# We scan for any "logical" partition found in the dump
LPM_ARGS=""
PARTITIONS="system system_dlkm vendor vendor_dlkm product odm mi_ext"

for part in $PARTITIONS; do
    if [ -f "${part}.img" ]; then
        echo "⚙️  Processing Partition: $part"
        
        # A. Extract EROFS
        extract.erofs -i "${part}.img" -x -o "${part}_dump"
        rm "${part}.img" # Delete raw image to save space
        
        # ==========================================
        # 🟢 YOUR CUSTOM MODS GO HERE
        # ==========================================
        
        # Example 1: Debloat
        if [ "$part" == "product" ]; then
            echo "    -> Removing Bloatware..."
            rm -rf "${part}_dump/app/MSA"
            rm -rf "${part}_dump/priv-app/MiuiBrowser"
        fi
        
        # Example 2: Replace Files (From your repo's 'mods' folder)
        if [ -d "$GITHUB_WORKSPACE/mods/$part" ]; then
            echo "    -> Injecting Custom Files..."
            cp -r "$GITHUB_WORKSPACE/mods/$part/"* "${part}_dump/"
        fi

        # ==========================================
        # 🔴 END OF MODS
        # ==========================================
        
        # B. Repack to EROFS
        # We use strict EROFS compression to save space
        mkfs.erofs -zLZ4HC "${part}_mod.img" "${part}_dump"
        
        # C. Add to LPMake Arguments
        IMG_SIZE=$(stat -c%s "${part}_mod.img")
        echo "    -> Size: $IMG_SIZE bytes"
        LPM_ARGS="$LPM_ARGS --partition ${part}:readonly:${IMG_SIZE}:main --image ${part}=${part}_mod.img"
        
        # Cleanup
        rm -rf "${part}_dump"
    fi
done

# 8. BUILD SUPER IMAGE
echo "🔨  Building Super Image (This is the heavy part)..."
lpmake --metadata-size 65536 \
       --super-name super \
       --metadata-slots 2 \
       --device super:$SUPER_SIZE \
       --group main:$SUPER_SIZE \
       $LPM_ARGS \
       --output "$IMAGES_DIR/super.img"

# 9. FINALIZE PACKAGE
echo "📜  Generating Scripts..."
cd "$OUTPUT_DIR"
# Generate Bat/Sh scripts
python3 "$GITHUB_WORKSPACE/gen_scripts.py" "$DEVICE_CODE" "images"

# Download Platform Tools (ADB/Fastboot) for the user
echo "📥  Bundling ADB/Fastboot..."
wget -q https://dl.google.com/android/repository/platform-tools-latest-windows.zip
unzip -q platform-tools-latest-windows.zip
mv platform-tools/* tools/
rm -rf platform-tools platform-tools-latest-windows.zip

# 10. ZIP & UPLOAD
ZIP_NAME="ota_NexDroid_Extended_${DEVICE_CODE}_${OS_VER}_A${ANDROID_VER}.zip"
echo "📦  Zipping: $ZIP_NAME"
zip -r -q "$ZIP_NAME" .

echo "☁️  Uploading to PixelDrain..."
curl -T "$ZIP_NAME" -u : https://pixeldrain.com/api/file/

echo "✅  DONE!"
