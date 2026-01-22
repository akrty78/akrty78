#!/bin/bash

# =========================================================
#  NEXDROID GOONER - MAGISK TESTER EDITION
#  (Builds a small Magisk Module to test APKs instantly)
# =========================================================

set +e 

ROM_URL="$1"
GITHUB_WORKSPACE=$(pwd)
BIN_DIR="$GITHUB_WORKSPACE/bin"
OUTPUT_DIR="$GITHUB_WORKSPACE/NexMod_Output"
IMAGES_DIR="$OUTPUT_DIR/images"
SUPER_DIR="$OUTPUT_DIR/super"
TEMP_DIR="$GITHUB_WORKSPACE/temp"

# 🔴 CONFIGURATION
NEX_PACKAGE_LINK="https://drive.google.com/file/d/1Fr3G5t6y5qD5zYtbKzHsSc9ymhjqrhr-/view?usp=sharing"
LAUNCHER_REPO="Mods-Center/HyperOS-Launcher"

# 1. SETUP
echo "🛠️  Setting up Environment..."
mkdir -p "$IMAGES_DIR" "$SUPER_DIR" "$TEMP_DIR" "$BIN_DIR"
export PATH="$BIN_DIR:$PATH"

sudo apt-get update -y
sudo apt-get install -y python3 python3-pip erofs-utils erofsfuse jq aria2 zip unzip liblz4-tool p7zip-full apktool apksigner openjdk-17-jdk
pip3 install gdown --break-system-packages

# --- KEY GENERATION ---
if [ ! -f "testkey.pk8" ]; then
    echo "🔑 Generating Signing Keys..."
    openssl genrsa -out key.pem 2048
    openssl req -new -key key.pem -out request.pem -subj "/C=US/ST=CA/L=Mountain View/O=Android/OU=Android/CN=Android/emailAddress=android@android.com"
    openssl x509 -req -days 9999 -in request.pem -signkey key.pem -out testkey.x509.pem
    openssl pkcs8 -topk8 -outform DER -in key.pem -inform PEM -out testkey.pk8 -nocrypt
    rm key.pem request.pem
fi

# 2. DOWNLOAD LATEST LAUNCHER
echo "⬇️  Fetching HyperOS Launcher..."
LAUNCHER_URL=$(curl -s "https://api.github.com/repos/$LAUNCHER_REPO/releases/latest" | jq -r '.assets[] | select(.name | endswith(".zip")) | .browser_download_url' | head -n 1)

if [ ! -z "$LAUNCHER_URL" ] && [ "$LAUNCHER_URL" != "null" ]; then
    echo "   ⬇️ Downloading Zip: $LAUNCHER_URL"
    wget -q -O "$TEMP_DIR/Launcher_Release.zip" "$LAUNCHER_URL"
    unzip -q "$TEMP_DIR/Launcher_Release.zip" -d "$TEMP_DIR/Launcher_Extracted"
    FOUND_APK=$(find "$TEMP_DIR/Launcher_Extracted" -name "MiuiHome.apk" -type f | head -n 1)
    if [ ! -z "$FOUND_APK" ]; then
        mv "$FOUND_APK" "$TEMP_DIR/MiuiHome_Latest.apk"
        echo "   ✅ Extracted: MiuiHome_Latest.apk"
    fi
    rm -rf "$TEMP_DIR/Launcher_Extracted" "$TEMP_DIR/Launcher_Release.zip"
else
    echo "   ⚠️  No Zip found in $LAUNCHER_REPO releases."
fi

# 3. DOWNLOAD RESOURCES
if [ ! -f "$BIN_DIR/payload-dumper-go" ]; then
    wget -q -O pd.tar.gz https://github.com/ssut/payload-dumper-go/releases/download/1.2.2/payload-dumper-go_1.2.2_linux_amd64.tar.gz
    tar -xzf pd.tar.gz
    find . -type f -name "payload-dumper-go" -not -path "*/bin/*" -exec mv {} "$BIN_DIR/" \;
    chmod +x "$BIN_DIR/payload-dumper-go"
    rm pd.tar.gz
fi

if [[ "$NEX_PACKAGE_LINK" == *"drive.google.com"* ]]; then
    echo "⬇️  Downloading Nex-Package..."
    gdown "$NEX_PACKAGE_LINK" -O nex_pkg.zip --fuzzy
    if [ -f "nex_pkg.zip" ]; then unzip -q nex_pkg.zip -d nex-package; rm nex_pkg.zip; fi
fi

chmod +x "$GITHUB_WORKSPACE/nexpackage.sh" 2>/dev/null
chmod +x "$GITHUB_WORKSPACE/inject_gapps.sh" 2>/dev/null

# 4. DOWNLOAD ROM
echo "⬇️  Downloading ROM..."
cd "$TEMP_DIR"
aria2c -x 16 -s 16 --file-allocation=none -o "rom.zip" "$ROM_URL"
if [ ! -f "rom.zip" ]; then echo "❌ Download Failed"; exit 1; fi
unzip -o "rom.zip" payload.bin && rm "rom.zip"

# 5. EXTRACT
echo "🔍 Extracting..."
payload-dumper-go -o "$IMAGES_DIR" payload.bin > /dev/null 2>&1

# 6. DETECT INFO
echo "🕵️  Detecting Info..."
DEVICE_CODE="unknown"; OS_VER="1.0.0"
if [ -f "$IMAGES_DIR/mi_ext.img" ]; then
    mkdir -p mnt_detect; erofsfuse "$IMAGES_DIR/mi_ext.img" mnt_detect
    PROP="mnt_detect/etc/build.prop"
    if [ -f "$PROP" ]; then
        RAW=$(grep "ro.product.mod_device=" "$PROP" | head -1 | cut -d'=' -f2)
        DEVICE_CODE=$(echo "$RAW" | cut -d'_' -f1)
    fi
    fusermount -uz mnt_detect
fi
if [ -f "$IMAGES_DIR/system.img" ]; then
    mkdir -p mnt_detect; erofsfuse "$IMAGES_DIR/system.img" mnt_detect
    PROP=$(find mnt_detect -name build.prop | head -1)
    if [ -f "$PROP" ]; then
        RAW_OS=$(grep "ro.system.build.version.incremental=" "$PROP" | head -1 | cut -d'=' -f2)
        [ ! -z "$RAW_OS" ] && OS_VER="$RAW_OS"
    fi
    fusermount -uz mnt_detect; rmdir mnt_detect
fi
echo "   -> Device: $DEVICE_CODE | Ver: $OS_VER"

# 7. PATCH VBMETA
echo "🛡️  Patching VBMETA..."
cat <<EOF > patch_vbmeta.py
import sys
def patch_image(path):
    try:
        with open(path, 'r+b') as f: f.seek(123); f.write(b'\x03') 
    except: pass
if __name__ == "__main__": patch_image(sys.argv[1])
EOF
[ -f "$IMAGES_DIR/vbmeta.img" ] && python3 patch_vbmeta.py "$IMAGES_DIR/vbmeta.img"
[ -f "$IMAGES_DIR/vbmeta_system.img" ] && python3 patch_vbmeta.py "$IMAGES_DIR/vbmeta_system.img"
rm patch_vbmeta.py

# 8. PROCESS PARTITIONS
echo "🔄 Processing Partitions..."
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
        
        # A. GAPPS
        if [ -f "$GITHUB_WORKSPACE/inject_gapps.sh" ]; then
             bash "$GITHUB_WORKSPACE/inject_gapps.sh" "${part}_dump"
        fi
        # B. NEX-PACKAGE
        if [ -f "$GITHUB_WORKSPACE/nexpackage.sh" ]; then
             bash "$GITHUB_WORKSPACE/nexpackage.sh" "${part}_dump" "$part" "$TEMP_DIR"
        fi
        # C. AUTO-PATCHER
        if [ -f "$GITHUB_WORKSPACE/auto_patcher.py" ]; then
             python3 "$GITHUB_WORKSPACE/auto_patcher.py" "${part}_dump"
        fi
        
        # NOTE: We keep the dump folders for Magisk creation in next step
    fi
done

# 9. CREATE MAGISK TESTER (NEW FEATURE)
echo "📦  Building Magisk Module for Testing..."
MAGISK_DIR="$OUTPUT_DIR/Magisk_Module"
mkdir -p "$MAGISK_DIR/system"

# Map dump folders to Magisk system structure
# FORMAT: "DumpName:MagiskPath"
PART_MAPS=(
    "system_dump:system"
    "product_dump:system/product"
    "system_ext_dump:system/system_ext"
    "vendor_dump:system/vendor"
    "mi_ext_dump:system/mi_ext"
)

# Files to extract for testing (Add more if needed)
TEST_FILES="Provision.apk MiuiHome.apk"
FOUND_COUNT=0

for entry in "${PART_MAPS[@]}"; do
    dump_dir="${entry%%:*}"
    magisk_path="${entry##*:}"
    
    if [ -d "$dump_dir" ]; then
        for target in $TEST_FILES; do
            # Find file path inside dump
            found_path=$(find "$dump_dir" -name "$target" -type f -print -quit)
            
            if [ ! -z "$found_path" ]; then
                # Calculate relative path (e.g. priv-app/Provision/Provision.apk)
                rel_path="${found_path#$dump_dir/}"
                
                # Construct full destination
                dest_file="$MAGISK_DIR/$magisk_path/$rel_path"
                
                mkdir -p "$(dirname "$dest_file")"
                cp "$found_path" "$dest_file"
                echo "      + Added to Module: $magisk_path/$rel_path"
                FOUND_COUNT=$((FOUND_COUNT + 1))
            fi
        done
        
        # CLEANUP: Now we can delete the dump and repack image
        # This was moved from Step 8 to here to allow extracting files first
        part_name="${dump_dir%_dump}"
        mkfs.erofs -zlz4 "$SUPER_DIR/${part_name}.img" "$dump_dir" > /dev/null
        rm -rf "$dump_dir"
    fi
done

if [ "$FOUND_COUNT" -gt 0 ]; then
    # Create module.prop
    cat <<EOF > "$MAGISK_DIR/module.prop"
id=nexdroid_patch_test
name=NexDroid Patch Tester
version=v1.0
versionCode=1
author=NexDroid
description=Fast testing of patched APKs (Provision, Launcher) without full ROM flash.
EOF
    # Zip Module
    cd "$MAGISK_DIR"
    zip -r -q "$OUTPUT_DIR/Patch_Tester_Magisk.zip" .
    echo "      ✅ Magisk Module Created!"
else
    echo "      ⚠️  No modified files found for Magisk Module."
fi

# 10. CREATE FULL ZIPS
echo "📦  Creating Full Zips..."
cd "$SUPER_DIR"
SUPER_ZIP="Super_Images_${DEVICE_CODE}_${OS_VER}.zip"
7z a -tzip -mx3 -mmt=$(nproc) "$SUPER_ZIP" *.img > /dev/null
mv "$SUPER_ZIP" "$OUTPUT_DIR/"
rm *.img

cd "$OUTPUT_DIR"
mkdir -p FirmwarePack/images
find "$IMAGES_DIR" -maxdepth 1 -type f -name "*.img" -exec mv {} FirmwarePack/images/ \;
# (Add Flash Script Generation Here - Code omitted for brevity, stick to previous one)
cd FirmwarePack && zip -r -q "../Firmware_Flasher.zip" .

# 11. UPLOAD (3 FILES NOW)
echo "☁️  Uploading..."
cd "$OUTPUT_DIR"
FW_LINK=""; SUPER_LINK=""; TEST_LINK=""

# Function to upload
upload_file() {
    local file=$1
    if [ -f "$file" ]; then
        echo "   ⬆️ Uploading $file..."
        if [ -z "$PIXELDRAIN_KEY" ]; then
            resp=$(curl -s -T "$file" "https://pixeldrain.com/api/file/")
        else
            resp=$(curl -s -T "$file" -u :$PIXELDRAIN_KEY "https://pixeldrain.com/api/file/")
        fi
        id=$(echo "$resp" | jq -r '.id')
        if [ ! -z "$id" ] && [ "$id" != "null" ]; then
            echo "https://pixeldrain.com/u/$id"
        else
            curl -s --upload-file "$file" "https://transfer.sh/$(basename "$file")"
        fi
    fi
}

FW_LINK=$(upload_file "Firmware_Flasher.zip")
SUPER_LINK=$(upload_file "$SUPER_ZIP")
TEST_LINK=$(upload_file "Patch_Tester_Magisk.zip")

echo "   -> FW: $FW_LINK"
echo "   -> Super: $SUPER_LINK"
echo "   -> Tester: $TEST_LINK"

# 12. NOTIFY
if [ ! -z "$TELEGRAM_TOKEN" ] && [ ! -z "$CHAT_ID" ]; then
    MSG="✅ *Build Complete!*
📱 *Device:* \`${DEVICE_CODE}\`
"
    [[ "$TEST_LINK" == http* ]] && MSG="${MSG}
🧪 [Download Magisk Tester](${TEST_LINK}) (Fast Test)"

    [[ "$FW_LINK" == http* ]] && MSG="${MSG}
📦 [Download Firmware](${FW_LINK})"

    [[ "$SUPER_LINK" == http* ]] && MSG="${MSG}
📦 [Download Super](${SUPER_LINK})"

    curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage" -d chat_id="$CHAT_ID" -d parse_mode="Markdown" -d text="$MSG" > /dev/null
fi
