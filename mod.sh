#!/bin/bash

# =========================================================
#  NEXDROID GOONER - MODULAR EDITION
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

# 7. PROCESS PARTITIONS
echo "🔄 Modding, Debloating & Injecting..."
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
        
        # --- CALL PYTHON INJECTOR ---
        # We pass the dump directory to the python script
        # Check if python script exists in workspace
        if [ -f "$GITHUB_WORKSPACE/inject_gapps.py" ]; then
             python3 "$GITHUB_WORKSPACE/inject_gapps.py" "${part}_dump"
        else
             echo "⚠️  inject_gapps.py NOT FOUND! Skipping mods."
        fi

        # --- MANUAL MODS ---
        if [ -d "$GITHUB_WORKSPACE/mods/$part" ]; then
            echo "      💉 Injecting Manual Mods..."
            cp -r "$GITHUB_WORKSPACE/mods/$part/"* "${part}_dump/"
        fi
        
        # REPACK
        mkfs.erofs -zlz4 "$SUPER_DIR/${part}.img" "${part}_dump" > /dev/null
        rm -rf "${part}_dump"
    fi
done

# 8. CREATE ZIPS
echo "📦  Creating Zips..."
cd "$SUPER_DIR"
SUPER_ZIP="Super_Images_${DEVICE_CODE}_${OS_VER}.zip"
7z a -tzip -mx3 -mmt=$(nproc) "$SUPER_ZIP" *.img > /dev/null
mv "$SUPER_ZIP" "$OUTPUT_DIR/"
rm *.img

cd "$OUTPUT_DIR"
find "$IMAGES_DIR" -maxdepth 1 -type f -name "*.img" -exec mv {} . \;
if [ -f "$GITHUB_WORKSPACE/gen_scripts.py" ]; then
    python3 "$GITHUB_WORKSPACE/gen_scripts.py" "$DEVICE_CODE" "images"
fi
FIRMWARE_ZIP="Firmware_Flasher_${DEVICE_CODE}_${OS_VER}.zip"
zip -q "$FIRMWARE_ZIP" *.img *.bat *.sh bin/

# 9. UPLOAD
echo "☁️  Uploading..."
LINKS=""
UPLOAD_COUNT=0

for FILE in "$SUPER_ZIP" "$FIRMWARE_ZIP"; do
    if [ -f "$FILE" ]; then
        echo "   ⬆️ Uploading $FILE..."
        if [ -z "$PIXELDRAIN_KEY" ]; then
            RESPONSE=$(curl -s -T "$FILE" "https://pixeldrain.com/api/file/")
        else
            RESPONSE=$(curl -s -T "$FILE" -u :$PIXELDRAIN_KEY "https://pixeldrain.com/api/file/")
        fi
        
        FILE_ID=$(echo "$RESPONSE" | jq -r '.id')
        if [ ! -z "$FILE_ID" ] && [ "$FILE_ID" != "null" ]; then
            LINK="https://pixeldrain.com/u/$FILE_ID"
            LINKS="${LINKS}\n📂 [${FILE}](${LINK})"
            UPLOAD_COUNT=$((UPLOAD_COUNT+1))
        else
            LINK=$(curl -s --upload-file "$FILE" "https://transfer.sh/$(basename "$FILE")")
            if [[ "$LINK" == *"transfer.sh"* ]]; then
                 LINKS="${LINKS}\n📂 [${FILE}](${LINK})"
                 UPLOAD_COUNT=$((UPLOAD_COUNT+1))
            fi
        fi
    fi
done

# 10. NOTIFY
if [ ! -z "$TELEGRAM_TOKEN" ] && [ ! -z "$CHAT_ID" ]; then
    if [ "$UPLOAD_COUNT" -gt 0 ]; then
        MSG="✅ *Build Complete!*
        
📱 *Device:* \`${DEVICE_CODE}\`
✨ *Mods:* Debloat + GApps + Props
        
*Download Links:*
${LINKS}"
    else
        MSG="❌ *Upload Failed!*"
    fi
    curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage" \
        -d chat_id="$CHAT_ID" \
        -d parse_mode="Markdown" \
        -d text="$MSG" > /dev/null
fi
