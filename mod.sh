#!/bin/bash

# =========================================================
#  NEXDROID GOONER - FINAL INTEGRATED EDITION
#  (Single Script: Downloads, Mods, Patches, Builds)
# =========================================================

set +e 

# --- INPUTS ---
ROM_URL="$1"

# --- DIRECTORIES ---
GITHUB_WORKSPACE=$(pwd)
BIN_DIR="$GITHUB_WORKSPACE/bin"
OUTPUT_DIR="$GITHUB_WORKSPACE/NexMod_Output"
IMAGES_DIR="$OUTPUT_DIR/images"
SUPER_DIR="$OUTPUT_DIR/super"
TEMP_DIR="$GITHUB_WORKSPACE/temp"

# --- CONFIGURATION ---
# 1. GApps (Google Drive Link)
GAPPS_LINK="https://drive.google.com/file/d/1soDPsc9dhdXbuHLSx4t2L3u7x0fOlx_8/view?usp=drive_link"

# 2. NexPackage (Your Assets)
NEX_PACKAGE_LINK="https://drive.google.com/file/d/YOUR_NEX_PACKAGE_LINK/view?usp=sharing"

# 3. Launcher Repo
LAUNCHER_REPO="Mods-Center/HyperOS-Launcher"

# 4. GApps List
PRODUCT_APP="GoogleTTS SoundPickerGoogle LatinImeGoogle MiuiBiometric GeminiShell Wizard"
PRODUCT_PRIV="AndroidAutoStub GoogleRestore GooglePartnerSetup Assistant HotwordEnrollmentYGoogleRISCV_WIDEBAND Velvet Phonesky MIUIPackageInstaller"

# 5. Props
PROPS_CONTENT='
ro.miui.support_super_clipboard=1
persist.sys.support_super_clipboard=1
ro.miui.support.system.app.uninstall.v2=true
ro.vendor.audio.sfx.harmankardon=1
vendor.audio.lowpower=false
ro.vendor.audio.feature.spatial=7
debug.sf.disable_backpressure=1
debug.sf.latch_unsignaled=1
ro.surface_flinger.use_content_detection_for_refresh_rate=true
ro.HOME_APP_ADJ=1
persist.sys.purgeable_assets=1
ro.config.zram=true
dalvik.vm.heapgrowthlimit=128m
dalvik.vm.heapsize=256m
dalvik.vm.execution-mode=int:jit
persist.vendor.sys.memplus.enable=true
wifi.supplicant_scan_interval=180
ro.config.hw_power_saving=1
persist.radio.add_power_save=1
pm.sleep_mode=1
ro.ril.disable.power.collapse=0
doze.display.supported=true
persist.vendor.night.charge=true
net.ipv4.tcp_sack=1
net.ipv4.tcp_fack=1
persist.logd.limit=OFF
ro.logdumpd.enabled=0
ro.lmk.debug=false
profiler.force_disable_err_rpt=1
ro.miui.has_gmscore=1
'

# =========================================================
#  1. INITIALIZATION & TOOLS
# =========================================================
echo "🛠️  Setting up Environment..."
mkdir -p "$IMAGES_DIR" "$SUPER_DIR" "$TEMP_DIR" "$BIN_DIR"
export PATH="$BIN_DIR:$PATH"

sudo apt-get update -y
sudo apt-get install -y python3 python3-pip erofs-utils erofsfuse jq aria2 zip unzip liblz4-tool p7zip-full apktool apksigner openjdk-17-jdk
pip3 install gdown --break-system-packages

# Generate Signing Keys (For patching APKs)
if [ ! -f "testkey.pk8" ]; then
    echo "🔑 Generating Signing Keys..."
    openssl genrsa -out key.pem 2048
    openssl req -new -key key.pem -out request.pem -subj "/C=US/ST=CA/L=Mountain View/O=Android/OU=Android/CN=Android/emailAddress=android@android.com"
    openssl x509 -req -days 9999 -in request.pem -signkey key.pem -out testkey.x509.pem
    openssl pkcs8 -topk8 -outform DER -in key.pem -inform PEM -out testkey.pk8 -nocrypt
    rm key.pem request.pem
fi

# =========================================================
#  2. DOWNLOAD RESOURCES
# =========================================================

# A. Payload Dumper
if [ ! -f "$BIN_DIR/payload-dumper-go" ]; then
    wget -q -O pd.tar.gz https://github.com/ssut/payload-dumper-go/releases/download/1.2.2/payload-dumper-go_1.2.2_linux_amd64.tar.gz
    tar -xzf pd.tar.gz
    find . -type f -name "payload-dumper-go" -not -path "*/bin/*" -exec mv {} "$BIN_DIR/" \;
    chmod +x "$BIN_DIR/payload-dumper-go"
    rm pd.tar.gz
fi

# B. GApps Bundle
if [ ! -d "gapps_src" ]; then
    echo "⬇️  Downloading GApps..."
    gdown "$GAPPS_LINK" -O gapps.zip --fuzzy
    unzip -q gapps.zip -d gapps_src && rm gapps.zip
fi

# C. NexPackage
if [[ "$NEX_PACKAGE_LINK" == *"drive.google.com"* ]]; then
    echo "⬇️  Downloading NexPackage..."
    gdown "$NEX_PACKAGE_LINK" -O nex.zip --fuzzy
    unzip -q nex.zip -d nex_pkg && rm nex.zip
fi

# D. HyperOS Launcher
echo "⬇️  Fetching Launcher..."
LAUNCHER_URL=$(curl -s "https://api.github.com/repos/$LAUNCHER_REPO/releases/latest" | jq -r '.assets[] | select(.name | endswith(".zip")) | .browser_download_url' | head -n 1)
if [ ! -z "$LAUNCHER_URL" ] && [ "$LAUNCHER_URL" != "null" ]; then
    wget -q -O l.zip "$LAUNCHER_URL"
    unzip -q l.zip -d l_ext
    FOUND=$(find l_ext -name "MiuiHome.apk" -type f | head -n 1)
    [ ! -z "$FOUND" ] && mv "$FOUND" "$TEMP_DIR/MiuiHome_Latest.apk"
    rm -rf l_ext l.zip
fi

# =========================================================
#  3. DOWNLOAD & EXTRACT ROM
# =========================================================
echo "⬇️  Downloading ROM..."
cd "$TEMP_DIR"
aria2c -x 16 -s 16 --file-allocation=none -o "rom.zip" "$ROM_URL"
if [ ! -f "rom.zip" ]; then echo "❌ Download Failed"; exit 1; fi
unzip -o "rom.zip" payload.bin && rm "rom.zip"

echo "🔍 Extracting Firmware..."
payload-dumper-go -o "$IMAGES_DIR" payload.bin > /dev/null 2>&1

# Detect Device
DEVICE_CODE="unknown"; OS_VER="1.0.0"
if [ -f "$IMAGES_DIR/mi_ext.img" ]; then
    mkdir -p mnt; erofsfuse "$IMAGES_DIR/mi_ext.img" mnt
    RAW=$(grep "ro.product.mod_device=" "mnt/etc/build.prop" 2>/dev/null | head -1 | cut -d'=' -f2)
    [ ! -z "$RAW" ] && DEVICE_CODE=$(echo "$RAW" | cut -d'_' -f1)
    fusermount -uz mnt
fi
echo "   -> Device: $DEVICE_CODE"

# Patch VBMeta
echo "🛡️  Patching VBMeta..."
python3 -c "import sys; open(sys.argv[1], 'r+b').write(b'\x03', 123) if __name__=='__main__' else None" "$IMAGES_DIR/vbmeta.img" 2>/dev/null

# =========================================================
#  4. PARTITION MODIFICATION LOOP
# =========================================================
echo "🔄 Processing Partitions..."
LOGICALS="system system_ext product mi_ext vendor odm"

for part in $LOGICALS; do
    if [ -f "$IMAGES_DIR/${part}.img" ]; then
        echo "   -> Modding $part..."
        mkdir -p "${part}_dump" "mnt"
        erofsfuse "$IMAGES_DIR/${part}.img" "mnt"
        cp -a "mnt/." "${part}_dump/"
        fusermount -uz "mnt"
        rm "$IMAGES_DIR/${part}.img"
        
        DUMP_DIR="${part}_dump"

        # ----------------------------------------
        # A. GAPPS INJECTION (Product Only)
        # ----------------------------------------
        if [ "$part" == "product" ] && [ -d "gapps_src" ]; then
            echo "      🔵 Injecting GApps..."
            
            # Find destination folders dynamically
            APP_DIR=$(find "$DUMP_DIR" -type d -name "app" -print -quit)
            PRIV_DIR=$(find "$DUMP_DIR" -type d -name "priv-app" -print -quit)
            
            inject_app() {
                local list=$1; local dest=$2
                [ -z "$dest" ] && return
                for app in $list; do
                    # Find APK in source
                    src=$(find "gapps_src" -name "${app}.apk" -print -quit)
                    if [ -f "$src" ]; then
                        mkdir -p "$dest/$app"
                        cp "$src" "$dest/$app/"
                        chmod 644 "$dest/$app/${app}.apk"
                        echo "         + $app"
                    fi
                done
            }
            
            inject_app "$PRODUCT_APP" "$APP_DIR"
            inject_app "$PRODUCT_PRIV" "$PRIV_DIR"
            
            # Permissions
            ETC_DIR=$(find "$DUMP_DIR" -type d -name "etc" -print -quit)
            if [ ! -z "$ETC_DIR" ]; then
                find "gapps_src" -name "*.xml" | while read xml; do
                    # Smart copy: decide subfolder based on filename content? 
                    # For simplicity, we assume permissions struct in source or dump to etc/permissions
                    # Or simpler: just dump all XMLs to etc/permissions and etc/sysconfig if they exist
                    [ -d "$ETC_DIR/permissions" ] && cp "$xml" "$ETC_DIR/permissions/" 2>/dev/null
                    [ -d "$ETC_DIR/sysconfig" ] && cp "$xml" "$ETC_DIR/sysconfig/" 2>/dev/null
                done
            fi
        fi

        # ----------------------------------------
        # B. SMALI PATCHER (Provision.apk)
        # ----------------------------------------
        # Search for Provision.apk in this partition
        PROV_APK=$(find "$DUMP_DIR" -name "Provision.apk" -type f -print -quit)
        
        if [ ! -z "$PROV_APK" ]; then
            echo "      🔧 Patching Provision.apk..."
            
            # 1. Decompile (No Resources to avoid crashes)
            apktool d -r -f "$PROV_APK" -o "prov_temp" > /dev/null 2>&1
            
            # 2. Find and Patch using SED (No Python!)
            # Look for: sget-boolean vX, Lmiui/os/Build;->IS_INTERNATIONAL_BUILD:Z
            # Replace with: const/4 vX, 0x1
            
            grep -r "IS_INTERNATIONAL_BUILD" "prov_temp" | cut -d: -f1 | while read smali_file; do
                echo "         > Patching: $smali_file"
                # Use sed with regex capture group to keep the register (v0, v1 etc)
                sed -i -E 's/sget-boolean ([vp][0-9]+), Lmiui\/os\/Build;->IS_INTERNATIONAL_BUILD:Z/const\/4 \1, 0x1/g' "$smali_file"
            done
            
            # 3. Recompile
            apktool b "prov_temp" -o "$PROV_APK" > /dev/null 2>&1
            
            # 4. Sign
            apksigner sign --key "key.pem" --cert "testkey.x509.pem" "$PROV_APK"
            
            # Cleanup
            rm -rf "prov_temp"
            echo "         ✅ Patch Applied."
        fi

        # ----------------------------------------
        # C. NEXPACKAGE (Launcher & Media)
        # ----------------------------------------
        # Launcher Update
        if [ -f "$TEMP_DIR/MiuiHome_Latest.apk" ]; then
            TARGET=$(find "$DUMP_DIR" -name "MiuiHome.apk" -type f -print -quit)
            if [ ! -z "$TARGET" ]; then
                cp "$TEMP_DIR/MiuiHome_Latest.apk" "$TARGET"
                chmod 644 "$TARGET"
                echo "      📱 Launcher Updated."
            fi
        fi

        # Media / Bootanim
        if [ -d "nex_pkg" ]; then
            MEDIA_DIR=$(find "$DUMP_DIR" -type d -name "media" -print -quit)
            if [ ! -z "$MEDIA_DIR" ]; then
                [ -f "nex_pkg/bootanimation.zip" ] && cp "nex_pkg/bootanimation.zip" "$MEDIA_DIR/"
                if [ -d "nex_pkg/walls" ]; then
                    mkdir -p "$MEDIA_DIR/wallpaper/wallpaper_group"
                    cp -r nex_pkg/walls/* "$MEDIA_DIR/wallpaper/wallpaper_group/" 2>/dev/null
                fi
            fi
        fi
        
        # ----------------------------------------
        # D. PROPS INJECTION
        # ----------------------------------------
        find "$DUMP_DIR" -name "build.prop" | while read prop; do
            echo "$PROPS_CONTENT" >> "$prop"
        done

        # ----------------------------------------
        # REPACK
        # ----------------------------------------
        mkfs.erofs -zlz4 "$SUPER_DIR/${part}.img" "$DUMP_DIR" > /dev/null
        rm -rf "$DUMP_DIR"
    fi
done

# =========================================================
#  5. COMPRESSION & UPLOAD
# =========================================================
echo "📦  Zipping Super..."
cd "$SUPER_DIR"
SUPER_ZIP="Super_Images_${DEVICE_CODE}.zip"
7z a -tzip -mx3 -mmt=$(nproc) "$SUPER_ZIP" *.img > /dev/null
mv "$SUPER_ZIP" "$OUTPUT_DIR/"

echo "📦  Zipping Firmware..."
cd "$OUTPUT_DIR"
mkdir -p FirmwarePack/images
find "$IMAGES_DIR" -maxdepth 1 -type f -name "*.img" -exec mv {} FirmwarePack/images/ \;

# Create Flasher Bat
cat <<EOF > FirmwarePack/flash_rom.bat
@echo off
fastboot set_active a
for %%f in (images\*.img) do fastboot flash %%~nf "%%f"
fastboot flash cust images\cust.img
fastboot flash super images\super.img
fastboot erase userdata
fastboot reboot
EOF

cd FirmwarePack && zip -r -q "../Firmware_Flasher.zip" .

echo "☁️  Uploading..."
cd "$OUTPUT_DIR"

upload() {
    [ ! -f "$1" ] && return
    echo "   ⬆️ $1"
    if [ -z "$PIXELDRAIN_KEY" ]; then
        curl -s -T "$1" "https://pixeldrain.com/api/file/" | jq -r '"https://pixeldrain.com/u/" + .id'
    else
        curl -s -T "$1" -u :$PIXELDRAIN_KEY "https://pixeldrain.com/api/file/" | jq -r '"https://pixeldrain.com/u/" + .id'
    fi
}

LINK_FW=$(upload "Firmware_Flasher.zip")
LINK_SUPER=$(upload "$SUPER_ZIP")

# Notify Telegram
if [ ! -z "$TELEGRAM_TOKEN" ]; then
    MSG="✅ *Build Done!*
📱 *Device:* $DEVICE_CODE
📦 [Firmware]($LINK_FW)
📦 [Super]($LINK_SUPER)"
    curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage" -d chat_id="$CHAT_ID" -d parse_mode="Markdown" -d text="$MSG" > /dev/null
fi
