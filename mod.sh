#!/bin/bash

# =========================================================
#  NEXDROID GOONER - MANUAL PACK (PATCHED VBMETA)
# =========================================================

# Disable exit on error
set +e 

ROM_URL="$1"
GITHUB_WORKSPACE=$(pwd)
BIN_DIR="$GITHUB_WORKSPACE/bin"
OUTPUT_DIR="$GITHUB_WORKSPACE/NexMod_Output"
IMAGES_DIR="$OUTPUT_DIR/images"
SUPER_DIR="$OUTPUT_DIR/super" # Folder for system/vendor images
TEMP_DIR="$GITHUB_WORKSPACE/temp"

# 1. SETUP ENVIRONMENT
echo "🛠️  Setting up Environment..."
mkdir -p "$IMAGES_DIR" "$SUPER_DIR" "$TEMP_DIR" "$BIN_DIR"
export PATH="$BIN_DIR:$PATH"

sudo apt-get update -y
sudo apt-get install -y python3 python3-pip erofs-utils erofsfuse jq aria2 zip unzip liblz4-tool

# 2. DOWNLOAD PAYLOAD DUMPER
if [ ! -f "$BIN_DIR/payload-dumper-go" ]; then
    wget -q -O pd.tar.gz https://github.com/ssut/payload-dumper-go/releases/download/1.2.2/payload-dumper-go_1.2.2_linux_amd64.tar.gz
    tar -xzf pd.tar.gz
    find . -type f -name "payload-dumper-go" -not -path "*/bin/*" -exec mv {} "$BIN_DIR/" \;
    chmod +x "$BIN_DIR/payload-dumper-go"
    rm pd.tar.gz
fi

# 3. DOWNLOAD ROM
echo "⬇️  Downloading ROM..."
cd "$TEMP_DIR"
aria2c -x 16 -s 16 --file-allocation=none -o "rom.zip" "$ROM_URL"
if [ ! -f "rom.zip" ]; then echo "❌ Download Failed"; exit 1; fi

unzip -o "rom.zip" payload.bin
rm "rom.zip"

# 4. EXTRACT EVERYTHING
echo "🔍 Extracting All Partitions..."
payload-dumper-go -o "$IMAGES_DIR" payload.bin > /dev/null 2>&1

# 5. DETECT INFO (Device, OS, Android Ver)
echo "🕵️  Detecting Device Info..."
DEVICE_CODE="unknown"
OS_VER="1.0.0"
ANDROID_VER="14"

# We check mi_ext first, then system
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
    PROP="mnt_detect/system/build.prop"
    # Fallback path
    if [ ! -f "$PROP" ]; then PROP=$(find mnt_detect -name build.prop | head -1); fi
    
    if [ -f "$PROP" ]; then
        # OS Version (e.g. OS1.0.5.0.UMCNXM)
        RAW_OS=$(grep "ro.system.build.version.incremental=" "$PROP" | head -1 | cut -d'=' -f2)
        if [ ! -z "$RAW_OS" ]; then OS_VER="$RAW_OS"; fi
        
        # Android Version (e.g. 14)
        RAW_AND=$(grep "ro.system.build.version.release=" "$PROP" | head -1 | cut -d'=' -f2)
        if [ ! -z "$RAW_AND" ]; then ANDROID_VER="$RAW_AND"; fi
    fi
    fusermount -uz mnt_detect
    rmdir mnt_detect
fi

echo "   -> Device:  $DEVICE_CODE"
echo "   -> Version: $OS_VER"
echo "   -> Android: $ANDROID_VER"

# 6. DISABLE VBMETA VERIFICATION (Python Script)
echo "🛡️  Patching VBMETA to Disable Verification..."
cat <<EOF > patch_vbmeta.py
import sys

def patch_image(path):
    try:
        with open(path, 'r+b') as f:
            f.seek(123)
            # Flag 0 (0x00) -> Disable Verity (0x01) + Disable Verification (0x02) = 0x03
            # We just overwrite with 2 (Disable Verification) or 3 (Both)
            # Standard for Xiaomi modding is usually just disable verification bit.
            f.write(b'\x03') 
        print(f"Patched: {path}")
    except FileNotFoundError:
        pass

if __name__ == "__main__":
    patch_image(sys.argv[1])
EOF

if [ -f "$IMAGES_DIR/vbmeta.img" ]; then
    python3 patch_vbmeta.py "$IMAGES_DIR/vbmeta.img"
fi
if [ -f "$IMAGES_DIR/vbmeta_system.img" ]; then
    python3 patch_vbmeta.py "$IMAGES_DIR/vbmeta_system.img"
fi
rm patch_vbmeta.py

# 7. MOD INJECTION & REPACK
echo "🔄 Modding Logical Partitions..."
LOGICALS="system system_dlkm vendor vendor_dlkm product odm mi_ext"

for part in $LOGICALS; do
    if [ -f "$IMAGES_DIR/${part}.img" ]; then
        echo "   -> Processing $part..."
        mkdir -p "${part}_dump" "mnt_point"
        
        erofsfuse "$IMAGES_DIR/${part}.img" "mnt_point"
        cp -a "mnt_point/." "${part}_dump/"
        fusermount -uz "mnt_point"
        rmdir "mnt_point"
        rm "$IMAGES_DIR/${part}.img" # Delete original from firmware folder
        
        # INJECT MODS
        if [ -d "$GITHUB_WORKSPACE/mods/$part" ]; then
            echo "      💉 Injecting mods..."
            cp -r "$GITHUB_WORKSPACE/mods/$part/"* "${part}_dump/"
        fi
        
        # REPACK (Output to 'super' folder for manual building)
        mkfs.erofs -zlz4 "$SUPER_DIR/${part}.img" "${part}_dump" > /dev/null
        rm -rf "${part}_dump"
    fi
done

# 8. ORGANIZE
# Move firmware (boot, patched vbmeta, etc) to root of output
find "$IMAGES_DIR" -maxdepth 1 -type f -name "*.img" -exec mv {} "$OUTPUT_DIR/" \;

# 9. ZIP IT
echo "📦  Zipping..."
cd "$OUTPUT_DIR"

# ZIP NAME FORMAT: ota_[NexDroid]_{devicename}_{OSVERSION}_{android version}
ZIP_NAME="ota_[NexDroid]_${DEVICE_CODE}_${OS_VER}_${ANDROID_VER}.zip"

# Zip everything in Output Dir (Firmware + 'super' folder)
zip -r -q "$ZIP_NAME" .

# 10. UPLOAD
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

# 11. NOTIFY
if [ ! -z "$TELEGRAM_TOKEN" ] && [ ! -z "$CHAT_ID" ]; then
    if [ "$UPLOAD_SUCCESS" = true ]; then
        MSG="✅ *Modding Complete!*
        
📱 *Device:* \`${DEVICE_CODE}\`
🤖 *Android:* \`${ANDROID_VER}\`
💿 *Version:* \`${OS_VER}\`
        
ℹ️ _Contains patched vbmeta & raw super images._
⬇️ [Download Pack](${DOWNLOAD_LINK})"
    else
        MSG="❌ *Upload Failed!* Check GitHub Logs."
    fi
    curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage" \
        -d chat_id="$CHAT_ID" \
        -d parse_mode="Markdown" \
        -d text="$MSG" > /dev/null
fi
