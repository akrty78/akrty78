#!/bin/bash

# =========================================================
#  NEXDROID GOONER - COMPATIBILITY MODE (BULLETPROOF V2)
# =========================================================

# Fail on any error immediately (Safety First)
set -e 

ROM_URL="$1"
GITHUB_WORKSPACE=$(pwd)
BIN_DIR="$GITHUB_WORKSPACE/bin"
OUTPUT_DIR="$GITHUB_WORKSPACE/NexMod_Output"
IMAGES_DIR="$OUTPUT_DIR/images"
TOOLS_DIR="$OUTPUT_DIR/tools"
TEMP_DIR="$GITHUB_WORKSPACE/temp"
OTATOOLS_DIR="$GITHUB_WORKSPACE/otatools"

# 1. SETUP & DEPENDENCIES
echo "🛠️  Setting up Environment..."
mkdir -p "$IMAGES_DIR" "$TOOLS_DIR" "$TEMP_DIR" "$OTATOOLS_DIR" "$BIN_DIR"
export PATH="$BIN_DIR:$PATH"

# Install standard tools
sudo apt-get update -y
sudo apt-get install -y python3 python3-pip erofs-utils erofsfuse jq aria2 zip unzip liblz4-tool

# --- STEP 1: FIX THE OS (Install Deleted Libraries) ---
# Ubuntu 24.04 (Noble) killed these libs. We fetch stable 22.04 (Jammy) versions.
echo "💉 Injecting Legacy System Libraries..."

# Download with specific output names to avoid file-not-found errors
wget -q -O libssl1.1.deb http://security.ubuntu.com/ubuntu/pool/main/o/openssl/libssl1.1_1.1.1f-1ubuntu2.23_amd64.deb
wget -q -O libtinfo5.deb http://security.ubuntu.com/ubuntu/pool/universe/n/ncurses/libtinfo5_6.3-2ubuntu0.1_amd64.deb

# Install them
sudo dpkg -i libssl1.1.deb libtinfo5.deb
rm *.deb

# 2. DOWNLOAD VERIFIED TOOLS
echo "⬇️  Fetching Verified Toolchain..."

# Clean old binaries
rm -f "$BIN_DIR/lpmake" "$BIN_DIR/lpmake.exe"

# Download SebaUbuntu's OTATools (Known Good)
wget -q -O "otatools.zip" "https://github.com/SebaUbuntu/otatools-build/releases/download/v0.0.1/otatools.zip"

# Verify zip before unzipping
if unzip -tq otatools.zip; then
    unzip -q -o "otatools.zip" -d "$OTATOOLS_DIR"
    rm "otatools.zip"
else
    echo "❌ CRITICAL: OTATools download failed (Corrupt Zip). Dumping header:"
    head -n 5 otatools.zip
    exit 1
fi

# Link the internal libraries
export PATH="$OTATOOLS_DIR/bin:$PATH"
export LD_LIBRARY_PATH="$OTATOOLS_DIR/lib64:$LD_LIBRARY_PATH"

# 3. PRE-FLIGHT CHECK
echo "🧪 Pre-flight check: Testing lpmake..."
# Turn off 'set -e' temporarily to catch the error manually
set +e
lpmake --help > /dev/null 2>&1
LPM_STATUS=$?
set -e

if [ $LPM_STATUS -ne 0 ]; then
    echo "❌ CRITICAL ERROR: lpmake failed to start!"
    echo "   Dumping dependency info:"
    ldd "$OTATOOLS_DIR/bin/lpmake"
    exit 1
else
    echo "   ✅ lpmake is healthy and running."
fi

# 4. DOWNLOAD PAYLOAD DUMPER
if [ ! -f "$BIN_DIR/payload-dumper-go" ]; then
    wget -q -O pdg.tar.gz https://github.com/ssut/payload-dumper-go/releases/download/1.2.2/payload-dumper-go_1.2.2_linux_amd64.tar.gz
    tar -xzf pdg.tar.gz
    # Smart find to handle directory nesting
    find . -name "payload-dumper-go" -type f -exec mv {} "$BIN_DIR/" \;
    chmod +x "$BIN_DIR/payload-dumper-go"
    rm pdg.tar.gz
fi

# 5. DOWNLOAD ROM
echo "⬇️  Downloading ROM..."
cd "$TEMP_DIR"
# aria2c is faster and handles errors better than wget
aria2c -x 16 -s 16 --console-log-level=warn --file-allocation=none -o "rom.zip" "$ROM_URL"
unzip -o "rom.zip" payload.bin
rm "rom.zip"

# 6. EXTRACT FIRMWARE
echo "🔍 Extracting Firmware..."
payload-dumper-go -p boot,dtbo,vendor_boot,recovery,init_boot,vbmeta,vbmeta_system,vbmeta_vendor -o "$IMAGES_DIR" payload.bin > /dev/null 2>&1

# 7. SMART DETECTION
echo "🕵️  Detecting Device Identity..."
payload-dumper-go -p mi_ext,system -o . payload.bin > /dev/null 2>&1

DEVICE_CODE=""
detect_device() {
    IMG_FILE="$1"
    MOUNT_DIR="mnt_detect"
    
    if [ -f "$IMG_FILE" ]; then
        mkdir -p "$MOUNT_DIR"
        erofsfuse "$IMG_FILE" "$MOUNT_DIR"
        
        # Search widely for build.prop
        PROP_FILE=$(find "$MOUNT_DIR" -name "build.prop" | head -n 1)
        
        if [ ! -z "$PROP_FILE" ]; then
            # Try ro.product.device first, then mod_device
            CODE=$(grep "ro.product.device=" "$PROP_FILE" | head -1 | cut -d'=' -f2)
            if [ -z "$CODE" ]; then
                 CODE=$(grep "ro.product.mod_device=" "$PROP_FILE" | head -1 | cut -d'=' -f2 | cut -d'_' -f1)
            fi
            
            # Capture OS Version while we are here
            if [ -z "$OS_VER" ]; then
                OS_VER=$(grep "ro.system.build.version.incremental=" "$PROP_FILE" | head -1 | cut -d'=' -f2)
            fi
        fi
        
        # Lazy unmount is safer on CI environments
        fusermount -uz "$MOUNT_DIR"
        rmdir "$MOUNT_DIR"
        rm "$IMG_FILE"
        echo "$CODE"
    fi
}

# Try mi_ext first (Xiaomi usually hides identity here)
DEVICE_CODE=$(detect_device "mi_ext.img")

# Fallback to system if mi_ext failed
if [ -z "$DEVICE_CODE" ]; then
    DEVICE_CODE=$(detect_device "system.img")
fi

if [ -z "$DEVICE_CODE" ]; then echo "❌ CRITICAL: Detection Failed!"; exit 1; fi

echo "✅  Identity: $DEVICE_CODE | $OS_VER"

# Validate against devices.json
SUPER_SIZE=$(jq -r --arg dev "$DEVICE_CODE" '.[$dev].super_size' "$GITHUB_WORKSPACE/devices.json")
if [ "$SUPER_SIZE" == "null" ] || [ -z "$SUPER_SIZE" ]; then 
    echo "❌  DEVICE UNKNOWN: '$DEVICE_CODE' - Add this device and its super_size to devices.json"
    exit 1
fi

# 8. MODDING ENGINE
LPM_ARGS=""
PARTITIONS="system system_dlkm vendor vendor_dlkm product odm mi_ext"
FOUND_PARTITIONS=false

for part in $PARTITIONS; do
    echo "🔄 Processing: $part"
    payload-dumper-go -p "$part" -o . payload.bin > /dev/null 2>&1
    
    if [ -f "${part}.img" ]; then
        FOUND_PARTITIONS=true
        mkdir -p "${part}_dump" "mnt_point"
        
        erofsfuse "${part}.img" "mnt_point"
        cp -a "mnt_point/." "${part}_dump/"
        fusermount -uz "mnt_point"
        rmdir "mnt_point"
        rm "${part}.img"
        
        # INJECT MODS IF THEY EXIST
        if [ -d "$GITHUB_WORKSPACE/mods/$part" ]; then
            echo "    -> Injecting Mods into $part..."
            cp -r "$GITHUB_WORKSPACE/mods/$part/"* "${part}_dump/"
        fi
        
        # Re-pack as EROFS (LZ4)
        mkfs.erofs -zlz4 "${part}_mod.img" "${part}_dump" > /dev/null
        
        rm -rf "${part}_dump"
        
        IMG_SIZE=$(stat -c%s "${part}_mod.img")
        LPM_ARGS="$LPM_ARGS --partition ${part}:readonly:${IMG_SIZE}:main --image ${part}=${part}_mod.img"
    else
        echo "    (Skipped - Partition not found)"
    fi
done

rm payload.bin

if [ "$FOUND_PARTITIONS" = false ]; then echo "❌ CRITICAL: No partitions found!"; exit 1; fi

# 9. BUILD SUPER IMAGE
echo "🔨  Building Super..."
echo "    Max Size: $SUPER_SIZE"

lpmake --metadata-size 65536 --super-name super --metadata-slots 2 \
       --device super:$SUPER_SIZE --group main:$SUPER_SIZE \
       $LPM_ARGS --output "$IMAGES_DIR/super.img" > lpmake_log.txt 2>&1

if [ ! -f "$IMAGES_DIR/super.img" ]; then
    echo "❌ CRITICAL: lpmake failed. LOGS:"
    cat lpmake_log.txt
    exit 1
fi

echo "✅ Super Image Created!"

# 10. FINALIZE & UPLOAD
cd "$OUTPUT_DIR"
# Only run gen_scripts if it exists
if [ -f "$GITHUB_WORKSPACE/gen_scripts.py" ]; then
    python3 "$GITHUB_WORKSPACE/gen_scripts.py" "$DEVICE_CODE" "images"
fi

echo "📥  Bundling ADB..."
wget -q -O adb.zip https://dl.google.com/android/repository/platform-tools-latest-windows.zip
unzip -q adb.zip && mv platform-tools/* tools/ && rm -rf platform-tools* adb.zip

ZIP_NAME="ota_NexDroid_${DEVICE_CODE}_${OS_VER}.zip"
echo "📦  Zipping..."
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
echo "::notice::Download Link: $DOWNLOAD_LINK"
echo "✅ DONE! Link: $DOWNLOAD_LINK"
