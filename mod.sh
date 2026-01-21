#!/bin/bash

# =========================================================
#  NEXDROID GOONER - STANDARD FLASHER EDITION
#  (Manual Super.img + Format Data Script)
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
pip3 install gdown --break-system-packages

# 2. PAYLOAD DUMPER
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
        
        # CALL INJECTOR
        if [ -f "$GITHUB_WORKSPACE/inject_gapps.py" ]; then
             python3 "$GITHUB_WORKSPACE/inject_gapps.py" "${part}_dump"
        fi

        # MANUAL MODS
        if [ -d "$GITHUB_WORKSPACE/mods/$part" ]; then
            echo "      💉 Injecting Manual Mods..."
            cp -r "$GITHUB_WORKSPACE/mods/$part/"* "${part}_dump/"
        fi
        
        # REPACK
        mkfs.erofs -zlz4 "$SUPER_DIR/${part}.img" "${part}_dump" > /dev/null
        rm -rf "${part}_dump"
    fi
done

# 8. CREATE ORGANIZED ZIPS
echo "📦  Creating Organized Zips..."

# --- ZIP 1: SUPER IMAGES (Raw Images for you to build super.img) ---
cd "$SUPER_DIR"
SUPER_ZIP="Super_Images_${DEVICE_CODE}_${OS_VER}.zip"
7z a -tzip -mx3 -mmt=$(nproc) "$SUPER_ZIP" *.img > /dev/null
mv "$SUPER_ZIP" "$OUTPUT_DIR/"
rm *.img

# --- ZIP 2: FIRMWARE + NORMAL SCRIPT ---
cd "$OUTPUT_DIR"
mkdir -p FirmwarePack/bin/windows
mkdir -p FirmwarePack/bin/linux
mkdir -p FirmwarePack/bin/macos
mkdir -p FirmwarePack/images

# A. Download Tools
echo "   ⬇️  Fetching Platform Tools..."
wget -q -O tools-win.zip https://dl.google.com/android/repository/platform-tools-latest-windows.zip
wget -q -O tools-lin.zip https://dl.google.com/android/repository/platform-tools-latest-linux.zip
wget -q -O tools-mac.zip https://dl.google.com/android/repository/platform-tools-latest-darwin.zip

unzip -q tools-win.zip -d win_tmp && mv win_tmp/platform-tools/* FirmwarePack/bin/windows/ && rm -rf win_tmp tools-win.zip
unzip -q tools-lin.zip -d lin_tmp && mv lin_tmp/platform-tools/* FirmwarePack/bin/linux/ && rm -rf lin_tmp tools-lin.zip
unzip -q tools-mac.zip -d mac_tmp && mv mac_tmp/platform-tools/* FirmwarePack/bin/macos/ && rm -rf mac_tmp tools-mac.zip

# B. Move Firmware Images
echo "   📂 Moving Firmware..."
find "$IMAGES_DIR" -maxdepth 1 -type f -name "*.img" -exec mv {} FirmwarePack/images/ \;

# C. GENERATE THE "NORMAL" SCRIPT (Your Request)
echo "   📝 Generating Standard Script..."
cat <<EOF > FirmwarePack/flash_rom_windows.bat
@echo off
cd %~dp0
set fastboot=bin\windows\fastboot.exe
if not exist %fastboot% echo %fastboot% not found. & pause & exit /B 1

echo ==================================================
echo       NEXDROID FLASHER (%DEVICE_CODE%)
echo ==================================================
echo.
echo 1. Connect device in FASTBOOT mode (Vol Down + Power).
echo 2. Make sure you have placed 'super.img' inside the 'images' folder.
echo.

echo Waiting for device...
%fastboot% wait-for-device
echo Device detected.

echo.
echo --------------------------------------------------
echo Your device will be flashed and DATA will be formatted.
echo You will lose all apps and files.
echo --------------------------------------------------
set /p choice=Do you want to continue? [y/N] 
if /i "%choice%" neq "y" exit /B 0

echo.
echo [1/3] Setting Active Slot A...
%fastboot% set_active a

echo [2/3] Flashing Firmware...
rem Loop through all images except super/cust/userdata
for %%f in (images\*.img) do (
    if /i "%%~nf" neq "super" (
        if /i "%%~nf" neq "cust" (
            if /i "%%~nf" neq "userdata" (
                echo     - Flashing %%~nf...
                %fastboot% flash %%~nf "%%f"
            )
        )
    )
)

echo [3/3] Flashing Super & Cust...
if exist images\cust.img (
    echo     - Flashing cust...
    %fastboot% flash cust images\cust.img
)

if exist images\super.img (
    echo     - Flashing super...
    %fastboot% flash super images\super.img
) else (
    echo [ERROR] super.img NOT FOUND in images folder!
    echo Please build super.img and put it there.
    pause
    exit /B 1
)

echo.
echo [4/4] Formatting Data...
%fastboot% erase metadata
%fastboot% erase userdata

echo.
echo [DONE] Rebooting...
%fastboot% reboot
pause
EOF

# D. Zip Firmware Pack
cd FirmwarePack
FIRMWARE_ZIP="Firmware_Flasher_${DEVICE_CODE}_${OS_VER}.zip"
zip -r -q "../$FIRMWARE_ZIP" .

# 9. UPLOAD (Debug Mode)
echo "☁️  Uploading..."
cd "$OUTPUT_DIR"

# Variables
FW_LINK=""
SUPER_LINK=""

# --- A. UPLOAD FIRMWARE ---
if [ -f "$FIRMWARE_ZIP" ]; then
    echo "   ⬆️ Uploading Firmware: $FIRMWARE_ZIP"
    if [ -z "$PIXELDRAIN_KEY" ]; then
        RESP=$(curl -s -T "$FIRMWARE_ZIP" "https://pixeldrain.com/api/file/")
    else
        RESP=$(curl -s -T "$FIRMWARE_ZIP" -u :$PIXELDRAIN_KEY "https://pixeldrain.com/api/file/")
    fi
    ID=$(echo "$RESP" | jq -r '.id')
    
    if [ ! -z "$ID" ] && [ "$ID" != "null" ]; then
        FW_LINK="https://pixeldrain.com/u/$ID"
        echo "      ✅ Firmware: $FW_LINK"
    else
        FW_LINK=$(curl -s --upload-file "$FIRMWARE_ZIP" "https://transfer.sh/$(basename "$FIRMWARE_ZIP")")
        echo "      ✅ Backup FW: $FW_LINK"
    fi
else
    echo "   ❌ Firmware Zip Missing!"
fi

# --- B. UPLOAD SUPER IMAGES ---
if [ -f "$SUPER_ZIP" ]; then
    echo "   ⬆️ Uploading Super Zip: $SUPER_ZIP"
    if [ -z "$PIXELDRAIN_KEY" ]; then
        RESP=$(curl -s -T "$SUPER_ZIP" "https://pixeldrain.com/api/file/")
    else
        RESP=$(curl -s -T "$SUPER_ZIP" -u :$PIXELDRAIN_KEY "https://pixeldrain.com/api/file/")
    fi
    ID=$(echo "$RESP" | jq -r '.id')
    
    if [ ! -z "$ID" ] && [ "$ID" != "null" ]; then
        SUPER_LINK="https://pixeldrain.com/u/$ID"
        echo "      ✅ Super: $SUPER_LINK"
    else
        SUPER_LINK=$(curl -s --upload-file "$SUPER_ZIP" "https://transfer.sh/$(basename "$SUPER_ZIP")")
        echo "      ✅ Backup Super: $SUPER_LINK"
    fi
else
    echo "   ❌ Super Zip Missing!"
fi

# 10. NOTIFY
if [ ! -z "$TELEGRAM_TOKEN" ] && [ ! -z "$CHAT_ID" ]; then
    echo "   🔔 Notifying Telegram..."
    MSG="✅ *Build Complete!*
    
📱 *Device:* \`${DEVICE_CODE}\`
🤖 *Version:* \`${OS_VER}\`"

    if [[ "$FW_LINK" == http* ]]; then
        MSG="${MSG}

📦 [Download Firmware](${FW_LINK})"
    else
        MSG="${MSG}

❌ Firmware Upload Failed"
    fi

    if [[ "$SUPER_LINK" == http* ]]; then
        MSG="${MSG}

📦 [Download Super Images](${SUPER_LINK})"
    else
        MSG="${MSG}

❌ Super Upload Failed"
    fi

    curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage" \
        -d chat_id="$CHAT_ID" \
        -d parse_mode="Markdown" \
        -d text="$MSG" > /dev/null
fi
