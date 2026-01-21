#!/bin/bash

# =========================================================
#  NEXDROID GOONER - FINAL PRODUCTION BUILD (VAB ENABLED)
# =========================================================

# Disable immediate exit on error so we can handle errors manually and log them
set +e 

ROM_URL="$1"
GITHUB_WORKSPACE=$(pwd)
BIN_DIR="$GITHUB_WORKSPACE/bin"
OUTPUT_DIR="$GITHUB_WORKSPACE/NexMod_Output"
IMAGES_DIR="$OUTPUT_DIR/images"
TOOLS_DIR="$OUTPUT_DIR/tools"
TEMP_DIR="$GITHUB_WORKSPACE/temp"
OTATOOLS_DIR="$GITHUB_WORKSPACE/otatools"

# ---------------------------------------------------------
# 1. ENVIRONMENT SETUP
# ---------------------------------------------------------
echo "🛠️  Setting up Environment..."
mkdir -p "$IMAGES_DIR" "$TOOLS_DIR" "$TEMP_DIR" "$OTATOOLS_DIR" "$BIN_DIR"
export PATH="$BIN_DIR:$PATH"

# Install Native Dependencies
sudo apt-get update -y
sudo apt-get install -y python3 python3-pip erofs-utils erofsfuse jq aria2 zip unzip liblz4-tool

# --- FIX LIBRARY HELL (Ubuntu 24.04 Compatibility) ---
echo "💉 Injecting Legacy Libraries for lpmake..."
wget -q -O libssl.deb "http://security.ubuntu.com/ubuntu/pool/main/o/openssl/libssl1.1_1.1.1f-1ubuntu2.23_amd64.deb"
wget -q -O libtinfo.deb "http://security.ubuntu.com/ubuntu/pool/universe/n/ncurses/libtinfo5_6.3-2ubuntu0.1_amd64.deb"
wget -q -O libncurses.deb "http://security.ubuntu.com/ubuntu/pool/universe/n/ncurses/libncurses5_6.3-2ubuntu0.1_amd64.deb"
sudo dpkg -i libssl.deb libtinfo.deb libncurses.deb
rm *.deb

# ---------------------------------------------------------
# 2. TOOLCHAIN SETUP
# ---------------------------------------------------------
echo "⬇️  Fetching OTATools..."
wget -q -O "otatools.zip" "https://github.com/SebaUbuntu/otatools-build/releases/download/v0.0.1/otatools.zip"
unzip -q "otatools.zip" -d "$OTATOOLS_DIR"
rm "otatools.zip"

# Link Tools & Libs
export PATH="$OTATOOLS_DIR/bin:$PATH"
export LD_LIBRARY_PATH="$OTATOOLS_DIR/lib64:$LD_LIBRARY_PATH"

# Verify lpmake works natively
echo "🧪 Testing lpmake..."
lpmake --help > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "❌ CRITICAL: lpmake binary is broken. Check library dependencies."
    ldd "$OTATOOLS_DIR/bin/lpmake"
    exit 1
fi

# Download Payload Dumper
if [ ! -f "$BIN_DIR/payload-dumper-go" ]; then
    wget -q -O pd.tar.gz https://github.com/ssut/payload-dumper-go/releases/download/1.2.2/payload-dumper-go_1.2.2_linux_amd64.tar.gz
    tar -xzf pd.tar.gz
    find . -type f -name "payload-dumper-go" -not -path "*/bin/*" -exec mv {} "$BIN_DIR/" \;
    chmod +x "$BIN_DIR/payload-dumper-go"
    rm pd.tar.gz
fi

# ---------------------------------------------------------
# 3. ROM PROCESSING
# ---------------------------------------------------------
echo "⬇️  Downloading ROM..."
cd "$TEMP_DIR"
aria2c -x 16 -s 16 --file-allocation=none -o "rom.zip" "$ROM_URL"
if [ ! -f "rom.zip" ]; then echo "❌ Download Failed"; exit 1; fi

unzip -o "rom.zip" payload.bin
rm "rom.zip"

echo "🔍 Extracting All Partitions..."
payload-dumper-go -o "$IMAGES_DIR" payload.bin > /dev/null 2>&1

# ---------------------------------------------------------
# 4. DEVICE DETECTION
# ---------------------------------------------------------
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

# Load Super Size from JSON
SUPER_SIZE=$(jq -r --arg dev "$DEVICE_CODE" '.[$dev].super_size' "$GITHUB_WORKSPACE/devices.json")
if [ "$SUPER_SIZE" == "null" ] || [ -z "$SUPER_SIZE" ]; then 
    echo "⚠️  Super Size unknown for $DEVICE_CODE. Using safe default (9GB)."
    SUPER_SIZE="9126805504"
fi

# ---------------------------------------------------------
# 5. REPACKING & MODDING
# ---------------------------------------------------------
echo "🔄 Repacking Logical Partitions for VAB..."
LPM_ARGS=""
LOGICALS="system system_dlkm vendor vendor_dlkm product odm mi_ext"

for part in $LOGICALS; do
    if [ -f "$IMAGES_DIR/${part}.img" ]; then
        echo "   -> Processing $part..."
        mkdir -p "${part}_dump" "mnt_point"
        
        # Mount & Copy
        erofsfuse "$IMAGES_DIR/${part}.img" "mnt_point"
        cp -a "mnt_point/." "${part}_dump/"
        fusermount -uz "mnt_point"
        rmdir "mnt_point"
        rm "$IMAGES_DIR/${part}.img"
        
        # INJECT MODS (If folder exists in repo)
        if [ -d "$GITHUB_WORKSPACE/mods/$part" ]; then
            echo "      💉 Injecting mods..."
            cp -r "$GITHUB_WORKSPACE/mods/$part/"* "${part}_dump/"
        fi
        
        # REPACK to EROFS (LZ4)
        mkfs.erofs -zlz4 "$IMAGES_DIR/${part}.img" "${part}_dump" > /dev/null
        rm -rf "${part}_dump"
        
        # Add to lpmake args
        IMG_SIZE=$(stat -c%s "$IMAGES_DIR/${part}.img")
        LPM_ARGS="$LPM_ARGS --partition ${part}:readonly:${IMG_SIZE}:main --image ${part}=$IMAGES_DIR/${part}.img"
    fi
done

# ---------------------------------------------------------
# 6. BUILDING SUPER.IMG (VIRTUAL A/B)
# ---------------------------------------------------------
echo "🔨  Building VAB Super Image..."
echo "    Target Size: $SUPER_SIZE"

# --virtual-ab : Enables VAB compression
# --sparse     : Creates sparse image for fastboot
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
    echo "✅  SUPER.IMG (VAB) CREATED SUCCESSFULLY!"
    
    # CLEANUP: Delete raw files so they don't bloat the zip
    echo "🧹  Cleaning up raw logical partitions..."
    for part in $LOGICALS; do
        rm -fv "$IMAGES_DIR/${part}.img"
    done
else
    echo "❌  CRITICAL ERROR: lpmake failed to build Super."
    exit 1
fi

# ---------------------------------------------------------
# 7. PACKAGING
# ---------------------------------------------------------
echo "📦  Zipping Final ROM..."
cd "$OUTPUT_DIR"

# Add Platform Tools (ADB/Fastboot)
curl -L -o tools.zip https://dl.google.com/android/repository/platform-tools-latest-windows.zip
unzip -q tools.zip && mkdir -p bin/windows && mv platform-tools/* bin/windows/ && rm -rf platform-tools tools.zip

# Generate Windows/Linux Flash Scripts
if [ -f "$GITHUB_WORKSPACE/gen_scripts.py" ]; then
    python3 "$GITHUB_WORKSPACE/gen_scripts.py" "$DEVICE_CODE" "images"
fi

ZIP_NAME="NexDroid_${DEVICE_CODE}_VAB_Pack.zip"
zip -r -q "$ZIP_NAME" .

# ---------------------------------------------------------
# 8. UPLOAD
# ---------------------------------------------------------
echo "☁️  Uploading to PixelDrain..."
if [ -z "$PIXELDRAIN_KEY" ]; then
    RESPONSE=$(curl -s -T "$ZIP_NAME" "https://pixeldrain.com/api/file/")
else
    RESPONSE=$(curl -s -T "$ZIP_NAME" -u :$PIXELDRAIN_KEY "https://pixeldrain.com/api/file/")
fi

# Parse Response
FILE_ID=$(echo $RESPONSE | jq -r '.id')
if [ "$FILE_ID" == "null" ] || [ -z "$FILE_ID" ]; then 
    echo "❌ Upload Failed: $RESPONSE"
    UPLOAD_SUCCESS=false
else
    DOWNLOAD_LINK="https://pixeldrain.com/u/$FILE_ID"
    echo "✅ Link: $DOWNLOAD_LINK"
    UPLOAD_SUCCESS=true
fi

# ---------------------------------------------------------
# 9. NOTIFICATION
# ---------------------------------------------------------
if [ ! -z "$TELEGRAM_TOKEN" ] && [ ! -z "$CHAT_ID" ]; then
    echo "🔔 Sending Telegram Notification..."
    
    if [ "$UPLOAD_SUCCESS" = true ]; then
        FILE_SIZE=$(du -h "$ZIP_NAME" | cut -f1)
        MSG="✅ *VAB Build Complete!*
        
📱 Device: \`${DEVICE_CODE}\`
📦 Size: ${FILE_SIZE}
⬇️ [Download ROM](${DOWNLOAD_LINK})"
    else
        MSG="❌ *Upload Failed!* The ROM was built, but PixelDrain rejected it. Check GitHub Logs."
    fi

    curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage" \
        -d chat_id="$CHAT_ID" \
        -d parse_mode="Markdown" \
        -d text="$MSG" > /dev/null
fi
