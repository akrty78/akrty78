#!/bin/bash

# =========================================================
#  NEXDROID GOONER - NUCLEAR OPTION (AUTO-FIND BINARIES)
# =========================================================

# Disable exit on error (we handle them manually)
set +e 

ROM_URL="$1"
GITHUB_WORKSPACE=$(pwd)
BIN_DIR="$GITHUB_WORKSPACE/bin"
OUTPUT_DIR="$GITHUB_WORKSPACE/NexMod_Output"
IMAGES_DIR="$OUTPUT_DIR/images"
TOOLS_DIR="$OUTPUT_DIR/tools"
TEMP_DIR="$GITHUB_WORKSPACE/temp"
OTATOOLS_DIR="$GITHUB_WORKSPACE/otatools"

# 1. SETUP ENVIRONMENT
echo "🛠️  Setting up Environment..."
mkdir -p "$IMAGES_DIR" "$TOOLS_DIR" "$TEMP_DIR" "$OTATOOLS_DIR" "$BIN_DIR"
export PATH="$BIN_DIR:$PATH"

# Install Native Dependencies
sudo apt-get update -y
sudo apt-get install -y python3 python3-pip erofs-utils erofsfuse jq aria2 zip unzip liblz4-tool

# --- FIX LIBRARY HELL ---
echo "💉 Injecting Legacy Libraries..."
# We use --force-all to stop the script from crashing if packages conflict
wget -q -O libssl.deb "http://security.ubuntu.com/ubuntu/pool/main/o/openssl/libssl1.1_1.1.1f-1ubuntu2.23_amd64.deb"
wget -q -O libtinfo.deb "http://security.ubuntu.com/ubuntu/pool/universe/n/ncurses/libtinfo5_6.3-2ubuntu0.1_amd64.deb"
wget -q -O libncurses.deb "http://security.ubuntu.com/ubuntu/pool/universe/n/ncurses/libncurses5_6.3-2ubuntu0.1_amd64.deb"
sudo dpkg -i --force-all libssl.deb libtinfo.deb libncurses.deb || true
rm *.deb

# 2. TOOLCHAIN SETUP (SMART MODE)
echo "⬇️  Setting up OTATools..."

# Copy only if source and dest are different
if [ -f "$GITHUB_WORKSPACE/otatools.zip" ] && [ ! -f "./otatools.zip" ]; then
    echo "   ✅ Found local otatools.zip in repo."
    cp "$GITHUB_WORKSPACE/otatools.zip" .
elif [ -f "./otatools.zip" ]; then
    echo "   ✅ otatools.zip is already here."
else
    echo "   ⚠️ Local file missing. Downloading..."
    wget -U "Mozilla/5.0" -q -O "otatools.zip" "https://github.com/SebaUbuntu/otatools-build/releases/download/v0.0.1/otatools.zip"
fi

# EXTRACT
unzip -q -o "otatools.zip" -d "$OTATOOLS_DIR"

# --- THE FIX: FIND BINARY ANYWHERE ---
echo "🔍 Hunting for lpmake binary..."
FOUND_BIN=$(find "$OTATOOLS_DIR" -type f -name "lpmake" | head -n 1)

if [ -z "$FOUND_BIN" ]; then
    echo "❌ CRITICAL: lpmake binary vanished! The zip might be empty or corrupt."
    exit 1
fi

# Calculate actual paths dynamically
REAL_BIN_DIR=$(dirname "$FOUND_BIN")
REAL_ROOT_DIR=$(dirname "$REAL_BIN_DIR")

echo "   📍 Found binary at: $FOUND_BIN"
echo "   📍 Setting PATH to: $REAL_BIN_DIR"

# Export the correct paths
export PATH="$REAL_BIN_DIR:$PATH"
# Try lib64 first, then lib
if [ -d "$REAL_ROOT_DIR/lib64" ]; then
    export LD_LIBRARY_PATH="$REAL_ROOT_DIR/lib64:$LD_LIBRARY_PATH"
else
    export LD_LIBRARY_PATH="$REAL_ROOT_DIR/lib:$LD_LIBRARY_PATH"
fi

# Verify lpmake
lpmake --help > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "❌ CRITICAL: lpmake failed to start."
    ldd "$FOUND_BIN"
    exit 1
fi
echo "   ✅ lpmake is alive."

# Download Payload Dumper
if [ ! -f "$BIN_DIR/payload-dumper-go" ]; then
    wget -q -O pd.tar.gz https://github.com/ssut/payload-dumper-go/releases/download/1.2.2/payload-dumper-go_1.2.2_linux_amd64.tar.gz
    tar -xzf pd.tar.gz
    find . -type f -name "payload-dumper-go" -not -path "*/bin/*" -exec mv {} "$BIN_DIR/" \;
    chmod +x "$BIN_DIR/payload-dumper-go"
    rm pd.tar.gz
fi

# 3. ROM PROCESSING
echo "⬇️  Downloading ROM..."
cd "$TEMP_DIR"
aria2c -x 16 -s 16 --file-allocation=none -o "rom.zip" "$ROM_URL"
if [ ! -f "rom.zip" ]; then echo "❌ Download Failed"; exit 1; fi

unzip -o "rom.zip" payload.bin
rm "rom.zip"

echo "🔍 Extracting All Partitions..."
payload-dumper-go -o "$IMAGES_DIR" payload.bin > /dev/null 2>&1

# 4. DEVICE DETECTION
echo "🕵️  Detecting Device..."
DEVICE_CODE=""
if [ -f "$IMAGES_DIR/mi_ext.img" ]; then
    mkdir -p mnt_detect
    erofsfuse "$IMAGES_DIR/mi_ext.img" mnt_detect
    if [ -f "mnt_detect/etc/build.prop" ]; then
        RAW=$(grep "ro.product.mod_device=" "mnt_detect/etc/build.prop" | head -1 | cut -d'=' -f2)
        DEVICE_CODE=$(echo "$RAW" | cut -d'_' -f1)
    fi
    fusermount -uz mnt_detect
    rmdir mnt_detect
fi

if [ -z "$DEVICE_CODE" ]; then 
    echo "⚠️  Detection Failed! Defaulting to 'marble'"
    DEVICE_CODE="marble"
fi
echo "   -> Detected: $DEVICE_CODE"

SUPER_SIZE=$(jq -r --arg dev "$DEVICE_CODE" '.[$dev].super_size' "$GITHUB_WORKSPACE/devices.json")
if [ "$SUPER_SIZE" == "null" ] || [ -z "$SUPER_SIZE" ]; then 
    SUPER_SIZE="9126805504"
fi

# 5. REPACKING FOR VAB
echo "🔄 Repacking Logical Partitions..."
LPM_ARGS=""
LOGICALS="system system_dlkm vendor vendor_dlkm product odm mi_ext"

for part in $LOGICALS; do
    if [ -f "$IMAGES_DIR/${part}.img" ]; then
        echo "   -> Processing $part..."
        mkdir -p "${part}_dump" "mnt_point"
        
        erofsfuse "$IMAGES_DIR/${part}.img" "mnt_point"
        cp -a "mnt_point/." "${part}_dump/"
        fusermount -uz "mnt_point"
        rmdir "mnt_point"
        rm "$IMAGES_DIR/${part}.img"
        
        # INJECT MODS
        if [ -d "$GITHUB_WORKSPACE/mods/$part" ]; then
            echo "      💉 Injecting mods..."
            cp -r "$GITHUB_WORKSPACE/mods/$part/"* "${part}_dump/"
        fi
        
        mkfs.erofs -zlz4 "$IMAGES_DIR/${part}.img" "${part}_dump" > /dev/null
        rm -rf "${part}_dump"
        
        IMG_SIZE=$(stat -c%s "$IMAGES_DIR/${part}.img")
        LPM_ARGS="$LPM_ARGS --partition ${part}:readonly:${IMG_SIZE}:main --image ${part}=$IMAGES_DIR/${part}.img"
    fi
done

# 6. BUILD SUPER (VAB)
echo "🔨  Building VAB Super Image..."
lpmake --metadata-size 65536 \
       --super-name super \
       --metadata-slots 3 \
       --virtual-ab \
       --device super:$SUPER_SIZE \
       --group main:$SUPER_SIZE \
       $LPM_ARGS \
       --sparse \
       --output "$IMAGES_DIR/super.img"

if [ -f "$IMAGES_DIR/super.img" ]; then
    echo "✅  SUPER.IMG CREATED!"
    for part in $LOGICALS; do rm -fv "$IMAGES_DIR/${part}.img"; done
else
    echo "❌  CRITICAL ERROR: lpmake failed."
    exit 1
fi

# 7. PACKAGING
echo "📦  Zipping Final ROM..."
cd "$OUTPUT_DIR"

curl -L -o tools.zip https://dl.google.com/android/repository/platform-tools-latest-windows.zip
unzip -q tools.zip && mkdir -p bin/windows && mv platform-tools/* bin/windows/ && rm -rf platform-tools tools.zip

if [ -f "$GITHUB_WORKSPACE/gen_scripts.py" ]; then
    python3 "$GITHUB_WORKSPACE/gen_scripts.py" "$DEVICE_CODE" "images"
fi

ZIP_NAME="NexDroid_${DEVICE_CODE}_VAB_Pack.zip"
zip -r -q "$ZIP_NAME" .

# 8. UPLOAD
echo "☁️  Uploading to PixelDrain..."
if [ -z "$PIXELDRAIN_KEY" ]; then
    RESPONSE=$(curl -s -T "$ZIP_NAME" "https://pixeldrain.com/api/file/")
else
    RESPONSE=$(curl -s -T "$ZIP_NAME" -u :$PIXELDRAIN_KEY "https://pixeldrain.com/api/file/")
fi

FILE_ID=$(echo $RESPONSE | jq -r '.id')
if [ "$FILE_ID" == "null" ] || [ -z "$FILE_ID" ]; then 
    echo "❌ Upload Failed"
    UPLOAD_SUCCESS=false
else
    DOWNLOAD_LINK="https://pixeldrain.com/u/$FILE_ID"
    echo "✅ Link: $DOWNLOAD_LINK"
    UPLOAD_SUCCESS=true
fi

# 9. NOTIFY
if [ ! -z "$TELEGRAM_TOKEN" ] && [ ! -z "$CHAT_ID" ]; then
    if [ "$UPLOAD_SUCCESS" = true ]; then
        MSG="✅ *VAB Build Complete!*
        
📱 Device: \`${DEVICE_CODE}\`
⬇️ [Download ROM](${DOWNLOAD_LINK})"
    else
        MSG="❌ *Upload Failed!* Check GitHub Logs."
    fi

    curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage" \
        -d chat_id="$CHAT_ID" \
        -d parse_mode="Markdown" \
        -d text="$MSG" > /dev/null
fi
