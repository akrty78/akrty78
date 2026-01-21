#!/bin/bash

# =========================================================
#  NEXDROID GOONER - MODULAR EDITION
#  (Refined for speed and modularity)
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
NEX_PACKAGE_LINK="https://drive.google.com/file/d/YOUR_NEX_PACKAGE_LINK/view?usp=sharing"
LAUNCHER_REPO="Mods-Center/HyperOS-Launcher"

# 1. SETUP
echo "🛠️  Setting up Environment..."
mkdir -p "$IMAGES_DIR" "$SUPER_DIR" "$TEMP_DIR" "$BIN_DIR"
export PATH="$BIN_DIR:$PATH"

sudo apt-get update -y
sudo apt-get install -y python3 python3-pip erofs-utils erofsfuse jq aria2 zip unzip liblz4-tool p7zip-full
pip3 install gdown --break-system-packages

# 2. DOWNLOAD LATEST LAUNCHER (Handles Zips & APKs)
echo "⬇️  Fetching HyperOS Launcher..."
LAUNCHER_URL=$(curl -s "https://api.github.com/repos/$LAUNCHER_REPO/releases/latest" | jq -r '.assets[] | select(.name | endswith(".zip")) | .browser_download_url' | head -n 1)

if [ ! -z "$LAUNCHER_URL" ] && [ "$LAUNCHER_URL" != "null" ]; then
    echo "   ⬇️ Downloading Zip: $LAUNCHER_URL"
    wget -q -O "$TEMP_DIR/Launcher_Release.zip" "$LAUNCHER_URL"
    
    # Extract and Find MiuiHome.apk inside nested folders
    unzip -q "$TEMP_DIR/Launcher_Release.zip" -d "$TEMP_DIR/Launcher_Extracted"
    FOUND_APK=$(find "$TEMP_DIR/Launcher_Extracted" -name "MiuiHome.apk" -type f | head -n 1)
    
    if [ ! -z "$FOUND_APK" ]; then
        mv "$FOUND_APK" "$TEMP_DIR/MiuiHome_Latest.apk"
        echo "   ✅ Extracted: MiuiHome_Latest.apk"
    else
        echo "   ⚠️  MiuiHome.apk not found inside the release zip!"
    fi
    rm -rf "$TEMP_DIR/Launcher_Extracted" "$TEMP_DIR/Launcher_Release.zip"
else
    echo "   ⚠️  No Zip found in $LAUNCHER_REPO releases."
fi

# 3. DOWNLOAD TOOLS & NEX-PACKAGE
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
    if [ -f "nex_pkg.zip" ]; then
        unzip -q nex_pkg.zip -d nex-package
        rm nex_pkg.zip
    fi
fi

# Ensure nexpackage.sh is executable
if [ -f "$GITHUB_WORKSPACE/nexpackage.sh" ]; then
    chmod +x "$GITHUB_WORKSPACE/nexpackage.sh"
fi

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

# 7. PATCH VBMETA
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
        
        # A. PYTHON INJECTOR (GAPPS/PROPS)
        if [ -f "$GITHUB_WORKSPACE/inject_gapps.py" ]; then
             python3 "$GITHUB_WORKSPACE/inject_gapps.py" "${part}_dump"
        fi

        # B. RUN NEX-PACKAGE HANDLER (STANDALONE FILE)
        if [ -f "$GITHUB_WORKSPACE/nexpackage.sh" ]; then
             "$GITHUB_WORKSPACE/nexpackage.sh" "${part}_dump" "$part" "$TEMP_DIR"
        else
             echo "⚠️  nexpackage.sh not found in repo!"
        fi
        
        # REPACK
        mkfs.erofs -zlz4 "$SUPER_DIR/${part}.img" "${part}_dump" > /dev/null
        rm -rf "${part}_dump"
    fi
done

# 9. CREATE ZIPS
echo "📦  Creating Zips..."

# Zip 1: Super
cd "$SUPER_DIR"
SUPER_ZIP="Super_Images_${DEVICE_CODE}_${OS_VER}.zip"
7z a -tzip -mx3 -mmt=$(nproc) "$SUPER_ZIP" *.img > /dev/null
mv "$SUPER_ZIP" "$OUTPUT_DIR/"
rm *.img

# Zip 2: Firmware
cd "$OUTPUT_DIR"
mkdir -p FirmwarePack/bin/windows FirmwarePack/bin/linux FirmwarePack/bin/macos FirmwarePack/images

# Tools Download
wget -q -O t-win.zip https://dl.google.com/android/repository/platform-tools-latest-windows.zip && unzip -q t-win.zip -d w && mv w/platform-tools/* FirmwarePack/bin/windows/ && rm -rf w t-win.zip
wget -q -O t-lin.zip https://dl.google.com/android/repository/platform-tools-latest-linux.zip && unzip -q t-lin.zip -d l && mv l/platform-tools/* FirmwarePack/bin/linux/ && rm -rf l t-lin.zip
wget -q -O t-mac.zip https://dl.google.com/android/repository/platform-tools-latest-darwin.zip && unzip -q t-mac.zip -d m && mv m/platform-tools/* FirmwarePack/bin/macos/ && rm -rf m t-mac.zip

# Move Images
find "$IMAGES_DIR" -maxdepth 1 -type f -name "*.img" -exec mv {} FirmwarePack/images/ \;

# Generate Flash Script
cat <<EOF > FirmwarePack/flash_rom_windows.bat
@echo off
cd %~dp0
set fastboot=bin\windows\fastboot.exe
if not exist %fastboot% echo %fastboot% not found. & pause & exit /B 1
echo ==================================================
echo       NEXDROID FLASHER (%DEVICE_CODE%)
echo ==================================================
echo.
echo 1. Connect device in FASTBOOT.
echo 2. Place 'super.img' in the 'images' folder.
echo.
%fastboot% wait-for-device
echo Device detected.
set /p choice=Flash and Format Data? [y/N] 
if /i "%choice%" neq "y" exit /B 0
%fastboot% set_active a
echo Flashing Firmware...
for %%f in (images\*.img) do (
    if /i "%%~nf" neq "super" if /i "%%~nf" neq "cust" if /i "%%~nf" neq "userdata" %fastboot% flash %%~nf "%%f"
)
if exist images\cust.img %fastboot% flash cust images\cust.img
if exist images\super.img (
    echo Flashing Super...
    %fastboot% flash super images\super.img
) else (
    echo [ERROR] super.img MISSING!
    pause & exit /B 1
)
echo Formatting Data...
%fastboot% erase metadata
%fastboot% erase userdata
%fastboot% reboot
EOF

cd FirmwarePack
FIRMWARE_ZIP="Firmware_Flasher_${DEVICE_CODE}_${OS_VER}.zip"
zip -r -q "../$FIRMWARE_ZIP" .

# 10. UPLOAD (Debug Mode)
echo "☁️  Uploading..."
cd "$OUTPUT_DIR"
FW_LINK=""; SUPER_LINK=""

# Firmware
if [ -f "$FIRMWARE_ZIP" ]; then
    echo "   ⬆️ Uploading Firmware..."
    [ -z "$PIXELDRAIN_KEY" ] && RESP=$(curl -s -T "$FIRMWARE_ZIP" "https://pixeldrain.com/api/file/") || RESP=$(curl -s -T "$FIRMWARE_ZIP" -u :$PIXELDRAIN_KEY "https://pixeldrain.com/api/file/")
    ID=$(echo "$RESP" | jq -r '.id')
    if [ ! -z "$ID" ] && [ "$ID" != "null" ]; then FW_LINK="https://pixeldrain.com/u/$ID"; else FW_LINK=$(curl -s --upload-file "$FIRMWARE_ZIP" "https://transfer.sh/$(basename "$FIRMWARE_ZIP")"); fi
    echo "      -> FW: $FW_LINK"
fi

# Super
if [ -f "$SUPER_ZIP" ]; then
    echo "   ⬆️ Uploading Super..."
    [ -z "$PIXELDRAIN_KEY" ] && RESP=$(curl -s -T "$SUPER_ZIP" "https://pixeldrain.com/api/file/") || RESP=$(curl -s -T "$SUPER_ZIP" -u :$PIXELDRAIN_KEY "https://pixeldrain.com/api/file/")
    ID=$(echo "$RESP" | jq -r '.id')
    if [ ! -z "$ID" ] && [ "$ID" != "null" ]; then SUPER_LINK="https://pixeldrain.com/u/$ID"; else SUPER_LINK=$(curl -s --upload-file "$SUPER_ZIP" "https://transfer.sh/$(basename "$SUPER_ZIP")"); fi
    echo "      -> Super: $SUPER_LINK"
fi

# 11. NOTIFY
if [ ! -z "$TELEGRAM_TOKEN" ] && [ ! -z "$CHAT_ID" ]; then
    MSG="✅ *Build Complete!*
📱 *Device:* \`${DEVICE_CODE}\`
🤖 *Version:* \`${OS_VER}\`"
    [[ "$FW_LINK" == http* ]] && MSG="${MSG}
📦 [Download Firmware](${FW_LINK})" || MSG="${MSG}
❌ Firmware Failed"
    [[ "$SUPER_LINK" == http* ]] && MSG="${MSG}
📦 [Download Super](${SUPER_LINK})" || MSG="${MSG}
❌ Super Failed"
    curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage" -d chat_id="$CHAT_ID" -d parse_mode="Markdown" -d text="$MSG" > /dev/null
fi
