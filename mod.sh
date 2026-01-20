#!/bin/bash

# =========================================================
#  NEXDROID GOONER - LOW DISK SPACE EDITION
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
sudo apt-get install -y python3 python3-pip erofs-utils jq aria2 zip unzip

# AUTO-DOWNLOAD PAYLOAD DUMPER
if [ ! -f "$BIN_DIR/payload-dumper-go" ]; then
    echo "⬇️  Fetching Tools..."
    wget -q https://github.com/ssut/payload-dumper-go/releases/download/1.2.2/payload-dumper-go_1.2.2_linux_amd64.tar.gz
    tar -xzf payload-dumper-go_1.2.2_linux_amd64.tar.gz
    find . -type f -name "payload-dumper-go" -not -path "*/bin/*" -exec mv {} "$BIN_DIR/" \;
    chmod +x "$BIN_DIR/payload-dumper-go"
fi

# 2. DOWNLOAD ROM (Streamlined)
echo "⬇️  Downloading ROM..."
cd "$TEMP_DIR"
aria2c -x 16 -s 16 --file-allocation=none -o "rom.zip" "$ROM_URL"
unzip -o "rom.zip" payload.bin
rm "rom.zip" # 🗑️ Free 6GB immediately

# 3. EXTRACT FIRMWARE (Small files only)
echo "🔍 Extracting Firmware..."
# We dump ONLY the small boot partitions first to save space
payload-dumper-go -p boot,dtbo,vendor_boot,recovery,init_boot,vbmeta,vbmeta_system,vbmeta_vendor -o "$IMAGES_DIR" payload.bin > /dev/null 2>&1

# 4. DETECT DEVICE (Extract System Temporarily)
echo "🕵️  Detecting Device..."
payload-dumper-go -p system -o . payload.bin > /dev/null 2>&1
extract.erofs -i system.img -x -o extracted_system

if [ -f "extracted_system/system/build.prop" ]; then
    BUILD_PROP="extracted_system/system/build.prop"
elif [ -f "extracted_system/build.prop" ]; then
    BUILD_PROP="extracted_system/build.prop"
else
    BUILD_PROP=$(find extracted_system -name "build.prop" | head -n 1)
fi

if [ -z "$BUILD_PROP" ]; then
    echo "❌ CRITICAL: build.prop not found!"
    exit 1
fi

DEVICE_CODE=$(grep "ro.product.device=" "$BUILD_PROP" | head -1 | cut -d'=' -f2)
OS_VER=$(grep "ro.system.build.version.incremental=" "$BUILD_PROP" | head -1 | cut -d'=' -f2)
ANDROID_VER=$(grep "ro.system.build.version.release=" "$BUILD_PROP" | head -1 | cut -d'=' -f2)

# CLEANUP SYSTEM IMMEDIATELY
rm -rf extracted_system system.img 

echo "✅  Identity: $DEVICE_CODE | $OS_VER"

SUPER_SIZE=$(jq -r --arg dev "$DEVICE_CODE" '.[$dev].super_size' "$GITHUB_WORKSPACE/devices.json")
if [ "$SUPER_SIZE" == "null" ] || [ -z "$SUPER_SIZE" ]; then
    echo "❌  DEVICE UNKNOWN! Update devices.json."
    exit 1
fi

# 5. SEQUENTIAL MODDING LOOP (The Space Saver)
LPM_ARGS=""
# List of big partitions to process one by one
PARTITIONS="system system_dlkm vendor vendor_dlkm product odm mi_ext"

for part in $PARTITIONS; do
    echo "🔄 Processing: $part"
    
    # A. Extract ONE partition
    payload-dumper-go -p "$part" -o . payload.bin > /dev/null 2>&1
    
    if [ -f "${part}.img" ]; then
        # B. Unpack EROFS
        extract.erofs -i "${part}.img" -x -o "${part}_dump"
        rm "${part}.img" # 🗑️ DELETE RAW IMAGE IMMEDIATELY
        
        # C. Mod (Inject files)
        if [ -d "$GITHUB_WORKSPACE/mods/$part" ]; then
            echo "    -> Injecting Mods..."
            cp -r "$GITHUB_WORKSPACE/mods/$part/"* "${part}_dump/"
        fi
        
        # D. Repack to EROFS (Compressed)
        mkfs.erofs -zLZ4HC "${part}_mod.img" "${part}_dump"
        rm -rf "${part}_dump" # 🗑️ DELETE DUMP FOLDER
        
        # E. Add to Super List
        IMG_SIZE=$(stat -c%s "${part}_mod.img")
        LPM_ARGS="$LPM_ARGS --partition ${part}:readonly:${IMG_SIZE}:main --image ${part}=${part}_mod.img"
    else
        echo "    (Skipped - Not found in payload)"
    fi
done

# We can now delete payload.bin as we are done with it
rm payload.bin # 🗑️ Free 6GB

# 6. BUILD SUPER IMAGE
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
