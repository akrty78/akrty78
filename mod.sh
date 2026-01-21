#!/bin/bash

# =========================================================
#  NEXDROID GOONER - PORTABLE MODE (NO INSTALLS)
# =========================================================

# Disable exit on error to handle things manually
set +e 

ROM_URL="$1"
GITHUB_WORKSPACE=$(pwd)
BIN_DIR="$GITHUB_WORKSPACE/bin"
OUTPUT_DIR="$GITHUB_WORKSPACE/NexMod_Output"
IMAGES_DIR="$OUTPUT_DIR/images"
TOOLS_DIR="$GITHUB_WORKSPACE/tools_portable"
TEMP_DIR="$GITHUB_WORKSPACE/temp"
OTATOOLS_DIR="$GITHUB_WORKSPACE/otatools"

# 1. CLEANUP BAD STATE
# If a previous run left a bad zip, delete it.
if [ -f "otatools.zip" ]; then
    FILE_SIZE=$(stat -c%s "otatools.zip")
    if [ "$FILE_SIZE" -lt 1000000 ]; then
        echo "🗑️  Deleting corrupt otatools.zip ($FILE_SIZE bytes)..."
        rm "otatools.zip"
    fi
fi

# 2. SETUP ENVIRONMENT
echo "🛠️  Setting up Environment..."
mkdir -p "$IMAGES_DIR" "$TOOLS_DIR" "$TEMP_DIR" "$OTATOOLS_DIR" "$BIN_DIR"
export PATH="$BIN_DIR:$PATH"

# Install only safe tools
sudo apt-get update -y
sudo apt-get install -y python3 python3-pip erofs-utils erofsfuse jq aria2 zip unzip liblz4-tool

# 3. PORTABLE LIBRARY SETUP (THE FIX)
# We do NOT use dpkg -i. We extract the libs to a folder and point LD_LIBRARY_PATH there.
echo "💉 Setting up Portable Libraries..."
mkdir -p "$TOOLS_DIR/lib64"

# Download the libs
wget -q -O libssl.deb "http://security.ubuntu.com/ubuntu/pool/main/o/openssl/libssl1.1_1.1.1f-1ubuntu2.23_amd64.deb"
wget -q -O libtinfo.deb "http://security.ubuntu.com/ubuntu/pool/universe/n/ncurses/libtinfo5_6.3-2ubuntu0.1_amd64.deb"
wget -q -O libncurses.deb "http://security.ubuntu.com/ubuntu/pool/universe/n/ncurses/libncurses5_6.3-2ubuntu0.1_amd64.deb"

# Extract them safely (dpkg -x extracts without installing)
dpkg -x libssl.deb "$TOOLS_DIR"
dpkg -x libtinfo.deb "$TOOLS_DIR"
dpkg -x libncurses.deb "$TOOLS_DIR"

# Move libs to our single lib64 folder
# The structure inside .deb is usually usr/lib/x86_64-linux-gnu or lib/x86_64-linux-gnu
cp -r "$TOOLS_DIR"/usr/lib/x86_64-linux-gnu/* "$TOOLS_DIR/lib64/" 2>/dev/null
cp -r "$TOOLS_DIR"/lib/x86_64-linux-gnu/* "$TOOLS_DIR/lib64/" 2>/dev/null

rm *.deb

# 4. DOWNLOAD OTA TOOLS
echo "⬇️  Fetching OTATools..."

if [ ! -f "otatools.zip" ]; then
    # Use a solid mirror
    wget -q -O "otatools.zip" "https://sourceforge.net/projects/xiaomi-mt6768/files/tmp/otatools.zip/download"
fi

# Unzip
unzip -q -o "otatools.zip" -d "$OTATOOLS_DIR"

# FIND LPMAKE (Nuclear Search)
echo "🔍 Locating lpmake..."
FOUND_BIN=$(find "$OTATOOLS_DIR" -type f -name "lpmake" | head -n 1)

if [ -z "$FOUND_BIN" ]; then
    echo "❌ CRITICAL: lpmake binary not found! The zip is likely garbage."
    ls -R "$OTATOOLS_DIR"
    exit 1
fi

REAL_BIN_DIR=$(dirname "$FOUND_BIN")

# 5. ACTIVATE PORTABLE MODE
# We point the system to use our extracted libs instead of the missing system ones
export PATH="$REAL_BIN_DIR:$PATH"
export LD_LIBRARY_PATH="$TOOLS_DIR/lib64:$REAL_BIN_DIR/../lib64:$LD_LIBRARY_PATH"

echo "   📍 Binary: $FOUND_BIN"
echo "   📍 Lib Path: $LD_LIBRARY_PATH"

# Verify
lpmake --help > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "❌ CRITICAL: lpmake failed to start."
    # Use the portable linker to check what's missing
    ldd "$FOUND_BIN"
    exit 1
fi
echo "   ✅ lpmake is healthy (Portable Mode)."

# 6. DOWNLOAD PAYLOAD DUMPER
if [ ! -f "$BIN_DIR/payload-dumper-go" ]; then
    wget -q -O pd.tar.gz https://github.com/ssut/payload-dumper-go/releases/download/1.2.2/payload-dumper-go_1.2.2_linux_amd64.tar.gz
    tar -xzf pd.tar.gz
    find . -type f -name "payload-dumper-go" -not -path "*/bin/*" -exec mv {} "$BIN_DIR/" \;
    chmod +x "$BIN_DIR/payload-dumper-go"
    rm pd.tar.gz
fi

# 7. PROCESS ROM
echo "⬇️  Downloading ROM..."
cd "$TEMP_DIR"
aria2c -x 16 -s 16 --file-allocation=none -o "rom.zip" "$ROM_URL"
if [ ! -f "rom.zip" ]; then echo "❌ Download Failed"; exit 1; fi

unzip -o "rom.zip" payload.bin
rm "rom.zip"

echo "🔍 Extracting All Partitions..."
payload-dumper-go -o "$IMAGES_DIR" payload.bin > /dev/null 2>&1

# 8. DETECT DEVICE
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

# 9. REPACK & BUILD SUPER (VAB)
echo "🔄 Repacking & Building VAB Super..."
LPM_ARGS=""
LOGICALS="system system_dlkm vendor vendor_dlkm product odm mi_ext"

for part in $LOGICALS; do
    if [ -f "$IMAGES_DIR/${part}.img" ]; then
        mkdir -p "${part}_dump" "mnt_point"
        erofsfuse "$IMAGES_DIR/${part}.img" "mnt_point"
        cp -a "mnt_point/." "${part}_dump/"
        fusermount -uz "mnt_point"
        rmdir "mnt_point"
        rm "$IMAGES_DIR/${part}.img"
        
        # INJECT MODS
        if [ -d "$GITHUB_WORKSPACE/mods/$part" ]; then
            cp -r "$GITHUB_WORKSPACE/mods/$part/"* "${part}_dump/"
        fi
        
        mkfs.erofs -zlz4 "$IMAGES_DIR/${part}.img" "${part}_dump" > /dev/null
        rm -rf "${part}_dump"
        
        IMG_SIZE=$(stat -c%s "$IMAGES_DIR/${part}.img")
        LPM_ARGS="$LPM_ARGS --partition ${part}:readonly:${IMG_SIZE}:main --image ${part}=$IMAGES_DIR/${part}.img"
    fi
done

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

# 10. PACK & UPLOAD
echo "📦  Zipping..."
cd "$OUTPUT_DIR"
curl -L -o tools.zip https://dl.google.com/android/repository/platform-tools-latest-windows.zip
unzip -q tools.zip && mkdir -p bin/windows && mv platform-tools/* bin/windows/ && rm -rf platform-tools tools.zip

if [ -f "$GITHUB_WORKSPACE/gen_scripts.py" ]; then
    python3 "$GITHUB_WORKSPACE/gen_scripts.py" "$DEVICE_CODE" "images"
fi

ZIP_NAME="NexDroid_${DEVICE_CODE}_VAB_Pack.zip"
zip -r -q "$ZIP_NAME" .

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
