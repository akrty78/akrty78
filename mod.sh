#!/bin/bash

# =========================================================
#  NEXDROID GOONER - SPEED ZIP EDITION
# =========================================================

set +e 

ROM_URL="$1"
GITHUB_WORKSPACE=$(pwd)
BIN_DIR="$GITHUB_WORKSPACE/bin"
OUTPUT_DIR="$GITHUB_WORKSPACE/NexMod_Output"
IMAGES_DIR="$OUTPUT_DIR/images"
SUPER_DIR="$OUTPUT_DIR/super"
TEMP_DIR="$GITHUB_WORKSPACE/temp"

# 1. SETUP
echo "🛠️  Setting up Environment..."
mkdir -p "$IMAGES_DIR" "$SUPER_DIR" "$TEMP_DIR" "$BIN_DIR"
export PATH="$BIN_DIR:$PATH"

# Install 7zip for fast multithreaded zipping
sudo apt-get update -y
sudo apt-get install -y python3 python3-pip erofs-utils erofsfuse jq aria2 zip unzip liblz4-tool p7zip-full

# 2. PAYLOAD DUMPER
if [ ! -f "$BIN_DIR/payload-dumper-go" ]; then
    wget -q -O pd.tar.gz https://github.com/ssut/payload-dumper-go/releases/download/1.2.2/payload-dumper-go_1.2.2_linux_amd64.tar.gz
    tar -xzf pd.tar.gz
    find . -type f -name "payload-dumper-go" -not -path "*/bin/*" -exec mv {} "$BIN_DIR/" \;
    chmod +x "$BIN_DIR/payload-dumper-go"
    rm pd.tar.gz
fi

# 3. DOWNLOAD
echo "⬇️  Downloading ROM..."
cd "$TEMP_DIR"
aria2c -x 16 -s 16 --file-allocation=none -o "rom.zip" "$ROM_URL"
if [ ! -f "rom.zip" ]; then echo "❌ Download Failed"; exit 1; fi

unzip -o "rom.zip" payload.bin
rm "rom.zip"

# 4. EXTRACT
echo "🔍 Extracting..."
payload-dumper-go -o "$IMAGES_DIR" payload.bin > /dev/null 2>&1

# 5. DETECT INFO
echo "🕵️  Detecting Info..."
DEVICE_CODE="unknown"
OS_VER="1.0.0"

if [ -f "$IMAGES_DIR/mi_ext.img" ]; then
    mkdir -p mnt_detect
    erofsfuse "$IMAGES_DIR/mi_ext.img" mnt_detect
    PROP="mnt_detect/etc/build.prop"
    if [ -f "$PROP" ]; then
        RAW=$(grep "ro.product.mod_device=" "$PROP" | head -1 | cut -d'=' -f2)
        DEVICE_CODE=$(echo "$RAW" | cut -d'_' -f1)
    fi
    fusermount -uz mnt_detect
fi
if [ -f "$IMAGES_DIR/system.img" ]; then
    mkdir -p mnt_detect
    erofsfuse "$IMAGES_DIR/system.img" mnt_detect
    PROP=$(find mnt_detect -name build.prop | head -1)
    if [ -f "$PROP" ]; then
        RAW_OS=$(grep "ro.system.build.version.incremental=" "$PROP" | head -1 | cut -d'=' -f2)
        [ ! -z "$RAW_OS" ] && OS_VER="$RAW_OS"
    fi
    fusermount -uz mnt_detect
    rmdir mnt_detect
fi
echo "   -> Device: $DEVICE_CODE | Ver: $OS_VER"

# 6. PATCH VBMETA
echo "🛡️  Patching VBMETA..."
cat <<EOF > patch_vbmeta.py
import sys
def patch_image(path):
    try:
        with open(path, 'r+b') as f:
            f.seek(123)
            f.write(b'\x03') 
    except: pass
if __name__ == "__main__": patch_image(sys.argv[1])
EOF
[ -f "$IMAGES_DIR/vbmeta.img" ] && python3 patch_vbmeta.py "$IMAGES_DIR/vbmeta.img"
[ -f "$IMAGES_DIR/vbmeta_system.img" ] && python3 patch_vbmeta.py "$IMAGES_DIR/vbmeta_system.img"
rm patch_vbmeta.py

# 7. MOD & PREPARE FOR ZIP
echo "🔄 Modding Partitions..."
LOGICALS="system system_ext product mi_ext vendor odm system_dlkm vendor_dlkm"

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
        
        # REPACK to SUPER_DIR
        mkfs.erofs -zlz4 "$SUPER_DIR/${part}.img" "${part}_dump" > /dev/null
        rm -rf "${part}_dump"
    fi
done

# 8. CREATE INNER ZIP (Super Pack)
echo "⚡ Zipping Super Images (Multithreaded)..."
cd "$SUPER_DIR"

# Zip all .img files into super_pack.zip
# -tzip = Create Zip format
# -mx3 = Fast compression (Good balance of speed/size)
# -mmt = Use all CPU cores (FAST)
7z a -tzip -mx3 -mmt=$(nproc) "super_pack.zip" *.img > /dev/null

if [ -f "super_pack.zip" ]; then
    echo "   ✅ Inner Zip Created"
    rm *.img # Delete raw images
    mv "super_pack.zip" "$OUTPUT_DIR/"
else
    echo "   ❌ Inner Zip Failed"
    exit 1
fi

# 9. CREATE FINAL ZIP
echo "📦  Creating Final Bundle..."
cd "$OUTPUT_DIR"

# Move firmware here
find "$IMAGES_DIR" -maxdepth 1 -type f -name "*.img" -exec mv {} . \;

ZIP_NAME="ota_[NexDroid]_${DEVICE_CODE}_${OS_VER}.zip"

# Zip Firmware + super_pack.zip
zip -r -q "$ZIP_NAME" .

# 10. UPLOAD
echo "☁️  Uploading..."
FILE_SIZE=$(du -h "$ZIP_NAME" | cut -f1)
echo "    Size: $FILE_SIZE"

# Mirror 1 (PixelDrain)
if [ -z "$PIXELDRAIN_KEY" ]; then
    PD_R=$(curl -s -T "$ZIP_NAME" "https://pixeldrain.com/api/file/")
else
    PD_R=$(curl -s -T "$ZIP_NAME" -u :$PIXELDRAIN_KEY "https://pixeldrain.com/api/file/")
fi
PD_ID=$(echo "$PD_R" | jq -r '.id')

if [ ! -z "$PD_ID" ] && [ "$PD_ID" != "null" ]; then
    LINK="https://pixeldrain.com/u/$PD_ID"
    SUCCESS=true
else
    # Mirror 2 (Transfer.sh)
    echo "    ⚠️ Backup Mirror..."
    LINK=$(curl -s --upload-file "$ZIP_NAME" "https://transfer.sh/$(basename "$ZIP_NAME")")
    if [[ "$LINK" == *"transfer.sh"* ]]; then SUCCESS=true; else SUCCESS=false; fi
fi

# 11. NOTIFY
if [ ! -z "$TELEGRAM_TOKEN" ] && [ ! -z "$CHAT_ID" ]; then
    if [ "$SUCCESS" = true ]; then
        MSG="✅ *Build Complete!*
        
📱 Device: \`${DEVICE_CODE}\`
📦 Size: ${FILE_SIZE}
ℹ️ _Structure: super_pack.zip (Inside) + Firmware_
⬇️ [Download](${LINK})"
    else
        MSG="❌ *Upload Failed!* Size: ${FILE_SIZE}"
    fi
    curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage" \
        -d chat_id="$CHAT_ID" \
        -d parse_mode="Markdown" \
        -d text="$MSG" > /dev/null
fi
