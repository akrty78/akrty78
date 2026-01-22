#!/bin/bash

# =========================================================
#  NEXDROID GOONER - STABILITY EDITION
#  (Unsigned + Resource Saver + Upload Fallback)
# =========================================================

set +e 

# --- INPUTS ---
ROM_URL="$1"

# --- CONFIGURATION ---
GAPPS_LINK="https://drive.google.com/file/d/1soDPsc9dhdXbuHLSx4t2L3u7x0fOlx_8/view?usp=drive_link"
NEX_PACKAGE_LINK="https://drive.google.com/file/d/YOUR_NEX_PACKAGE_LINK/view?usp=sharing"
LAUNCHER_REPO="Mods-Center/HyperOS-Launcher"

# --- DIRECTORIES ---
GITHUB_WORKSPACE=$(pwd)
BIN_DIR="$GITHUB_WORKSPACE/bin"
OUTPUT_DIR="$GITHUB_WORKSPACE/NexMod_Output"
IMAGES_DIR="$OUTPUT_DIR/images"
SUPER_DIR="$OUTPUT_DIR/super"
TEMP_DIR="$GITHUB_WORKSPACE/temp"

# --- APPS & PROPS ---
PRODUCT_APP="GoogleTTS SoundPickerGoogle LatinImeGoogle MiuiBiometric GeminiShell Wizard"
PRODUCT_PRIV="AndroidAutoStub GoogleRestore GooglePartnerSetup Assistant HotwordEnrollmentYGoogleRISCV_WIDEBAND Velvet Phonesky MIUIPackageInstaller"
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
#  1. SETUP & TOOLS
# =========================================================
echo "🛠️  Setting up Environment..."
mkdir -p "$IMAGES_DIR" "$SUPER_DIR" "$TEMP_DIR" "$BIN_DIR"
export PATH="$BIN_DIR:$PATH"

sudo apt-get update -y
# Minimal install to save time/space
sudo apt-get install -y python3 python3-pip erofs-utils erofsfuse jq aria2 zip unzip liblz4-tool p7zip-full apktool
pip3 install gdown --break-system-packages

# =========================================================
#  2. DOWNLOAD RESOURCES
# =========================================================
# Payload Dumper
if [ ! -f "$BIN_DIR/payload-dumper-go" ]; then
    wget -q -O pd.tar.gz https://github.com/ssut/payload-dumper-go/releases/download/1.2.2/payload-dumper-go_1.2.2_linux_amd64.tar.gz
    tar -xzf pd.tar.gz
    find . -type f -name "payload-dumper-go" -not -path "*/bin/*" -exec mv {} "$BIN_DIR/" \;
    chmod +x "$BIN_DIR/payload-dumper-go"
    rm pd.tar.gz
fi

# GApps
if [ ! -d "gapps_src" ]; then
    echo "⬇️  Downloading GApps..."
    gdown "$GAPPS_LINK" -O gapps.zip --fuzzy
    unzip -q gapps.zip -d gapps_src && rm gapps.zip
fi

# NexPackage
if [[ "$NEX_PACKAGE_LINK" == *"drive.google.com"* ]]; then
    echo "⬇️  Downloading NexPackage..."
    gdown "$NEX_PACKAGE_LINK" -O nex.zip --fuzzy
    unzip -q nex.zip -d nex_pkg && rm nex.zip
fi

# Launcher
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
unzip -o "rom.zip" payload.bin && rm "rom.zip" # CLEANUP IMMEDIATELY

echo "🔍 Extracting Firmware..."
payload-dumper-go -o "$IMAGES_DIR" payload.bin > /dev/null 2>&1
rm payload.bin # CLEANUP IMMEDIATELY

# Detect Device
DEVICE_CODE="unknown"
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
        rm "$IMAGES_DIR/${part}.img" # CLEANUP INPUT IMAGE IMMEDIATELY
        
        DUMP_DIR="${part}_dump"

        # A. GAPPS (Product Only)
        if [ "$part" == "product" ] && [ -d "$GITHUB_WORKSPACE/gapps_src" ]; then
            echo "      🔵 Injecting GApps..."
            APP_DIR=$(find "$DUMP_DIR" -type d -name "app" -print -quit)
            PRIV_DIR=$(find "$DUMP_DIR" -type d -name "priv-app" -print -quit)
            inject_app() {
                local list=$1; local dest=$2
                [ -z "$dest" ] && return
                for app in $list; do
                    src=$(find "$GITHUB_WORKSPACE/gapps_src" -name "${app}.apk" -print -quit)
                    if [ -f "$src" ]; then
                        mkdir -p "$dest/$app"; cp "$src" "$dest/$app/"
                        chmod 644 "$dest/$app/${app}.apk"; echo "         + $app"
                    fi
                done
            }
            inject_app "$PRODUCT_APP" "$APP_DIR"
            inject_app "$PRODUCT_PRIV" "$PRIV_DIR"
            
            ETC_DIR=$(find "$DUMP_DIR" -type d -name "etc" -print -quit)
            if [ ! -z "$ETC_DIR" ]; then
                find "$GITHUB_WORKSPACE/gapps_src" -name "*.xml" | while read xml; do
                    [ -d "$ETC_DIR/permissions" ] && cp "$xml" "$ETC_DIR/permissions/" 2>/dev/null
                    [ -d "$ETC_DIR/sysconfig" ] && cp "$xml" "$ETC_DIR/sysconfig/" 2>/dev/null
                done
            fi
        fi

        # B. SMALI PATCHER (Unsigned)
        PROV_APK=$(find "$DUMP_DIR" -name "Provision.apk" -type f -print -quit)
        if [ ! -z "$PROV_APK" ]; then
            echo "      🔧 Patching Provision.apk..."
            apktool d -r -f "$PROV_APK" -o "prov_temp" > /dev/null 2>&1
            if [ -d "prov_temp" ]; then
                grep -r "IS_INTERNATIONAL_BUILD" "prov_temp" | cut -d: -f1 | while read smali_file; do
                    sed -i -E 's/sget-boolean ([vp][0-9]+), Lmiui\/os\/Build;->IS_INTERNATIONAL_BUILD:Z/const\/4 \1, 0x1/g' "$smali_file"
                done
            fi
            apktool b "prov_
