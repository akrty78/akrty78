#!/bin/bash

# =========================================================
#  NEXDROID GOONER - SMART MOUNT EDITION (FIXED)
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

# Install Tools (Added erofsfuse!)
sudo apt-get update -y
sudo apt-get install -y python3 python3-pip erofs-utils erofsfuse jq aria2 zip unzip

# AUTO-DOWNLOAD PAYLOAD DUMPER
if [ ! -f "$BIN_DIR/payload-dumper-go" ]; then
    echo "⬇️  Fetching Tools..."
    wget -q https://github.com/ssut/payload-dumper-go/releases/download/1.2.2/payload-dumper-go_1.2.2_linux_amd64.tar.gz
    tar -xzf payload-dumper-go_1.2.2_linux_amd64.tar.gz
    find . -type f -name "payload-dumper-go" -not -path "*/bin/*" -exec mv {} "$BIN_DIR/" \;
    chmod +x "$BIN_DIR/payload-dumper-go"
fi

# 2. DOWNLOAD ROM
echo "⬇️  Downloading ROM..."
cd "$TEMP_DIR"
aria2c -x 16 -s 16 --file-allocation=none -o "rom.zip" "$ROM_URL"
unzip -o "rom.zip" payload.bin
rm "rom.zip"

# 3. EXTRACT FIRMWARE (Small files)
echo "🔍 Extracting Firmware..."
payload-dumper-go -p boot,dtbo,vendor_boot,recovery,init_boot,vbmeta,vbmeta_system,vbmeta_vendor -o "$IMAGES_DIR" payload.bin > /dev/null 2>&1

# 4. DETECT DEVICE (Using Mount)
echo "🕵️  Detecting Device..."
# Extract system.img temporarily
payload-dumper-go -p system -o . payload.bin > /dev/null 2>&1

# Mount it instead of extracting (Saves space/tools)
mkdir -p mnt_system
erofsfuse system.img mnt_system

# Find build.prop inside mount
if [ -f "mnt_system/system/build.prop" ]; then
    BUILD_PROP="mnt_system/system/build.prop"
elif [ -f "mnt_system/build.prop" ]; then
    BUILD_PROP="mnt_system/build.prop"
else
    BUILD_PROP=$(find mnt_system -name "build.prop" | head -n 1)
fi

if [ -z "$BUILD_PROP" ]; then
    echo "❌ CRITICAL: build.prop not found in system image!"
    fusermount -u mnt_system
    exit 1
fi

echo "🔎 Reading: $BUILD_PROP"
DEVICE_CODE=$(grep "ro.product.device=" "$BUILD_PROP" | head -1 | cut -d'=' -f2)
OS_VER=$(grep "ro.system.build.version.incremental=" "$BUILD_PROP" | head -1 | cut -d'=' -f2)
ANDROID_VER=$(grep "ro.system.build.version.release=" "$BUILD_PROP" | head -1 | cut -d'=' -f2)

# Unmount and Cleanup
fusermount -u mnt_system
rmdir mnt_system
rm system.img 

echo "✅  Identity: $DEVICE_CODE | $OS_VER"

SUPER_SIZE=$(jq -r --arg dev "$DEVICE_CODE" '.[$dev].super_size' "$GITHUB_WORKSPACE/devices.json")
if [ "$SUPER_SIZE" == "null" ] || [ -z "$SUPER_SIZE" ]; then
    echo "❌  DEVICE UNKNOWN! Add '$DEVICE_CODE' to devices.json."
    exit 1
fi

# 5. MODDING LOOP (Mount & Copy)
LPM_ARGS=""
PARTITIONS="system system_dlkm vendor vendor_dlkm product odm mi_ext"

for part in $PARTITIONS; do
    echo "🔄 Processing: $part"
    
    # Extract RAW image
    payload-dumper-go -p "$part" -o . payload.bin > /dev/null 2>&1
    
    if [ -f "${part}.img" ]; then
        # Create Dump Folder
        mkdir -p "${part}_dump"
        mkdir -p "mnt_point"
        
        # Mount EROFS
        erofsfuse "${part}.img" "mnt_point"
        
        # Copy files OUT of mount (So we can edit them)
        # -a preserves permissions
        cp -a "mnt_point/." "${part}_dump/"
        
        # Unmount & Clean raw image
        fusermount -u "mnt_point"
        rmdir "mnt_point"
        rm "${part}.img"
        
        # Inject Mods
        if [ -d "$GITHUB_WORKSPACE/mods/$part" ]; then
            echo "    -> Injecting Mods..."
            cp -r "$GITHUB_WORKSPACE/mods/$part/"* "${part}_dump/"
        fi
        
        # Repack
        mkfs.erofs -zLZ4HC "${part}_mod.img" "${part}_dump"
        rm -rf "${part}_dump"
        
        # Add to list
        IMG_SIZE=$(stat -c%s "${part}_mod.img")
        LPM_ARGS="$LPM_ARGS --partition ${part}:readonly:${IMG_SIZE}:main --image ${part}=${part}_mod.img"
    else
        echo "    (Skipped)"
    fi
done

rm payload.bin

# 6. BUILD SUPER
echo "🔨  Building Super..."
lpmake --metadata-size 65536 --super-name super --metadata-slots 2 \
       --device super:$SUPER_SIZE --group main:$SUPER_SIZE \
       $LPM_ARGS --output "$IMAGES_DIR/super.img"

# 7. FINALIZE
cd "$OUTPUT_DIR"
python3 "$GITHUB_WORKSPACE/gen_scripts.py" "$DEVICE_CODE" "images"

echo "📥  Bundling ADB..."
wget -q https://dl.google.com/android/repository/platform-tools-latest-windows.zip
unzip -q platform-tools-latest-windows.zip && mv platform-tools/* tools/ && rm -rf platform-tools*

# 8. UPLOAD
ZIP_NAME="ota_NexDroid_${DEVICE_CODE}_${OS_VER}.zip"
echo "📦  Zipping..."
zip -r -q "$ZIP_NAME" .
curl -T "$ZIP_NAME" -u : https://pixeldrain.com/api/file/
