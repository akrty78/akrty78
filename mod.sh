#!/bin/bash

# =========================================================
#  NEXDROID GOONER - ROOT POWER EDITION v16
#  (Fix: Absolute Paths for Framework Patching & Safety)
# =========================================================

set +e 

# --- INPUTS ---
ROM_URL="$1"

# --- 1. INSTANT METADATA EXTRACTION ---
FILENAME=$(basename "$ROM_URL" | cut -d'?' -f1)
echo "🔍 Analyzing OTA Link..."
DEVICE_CODE=$(echo "$FILENAME" | awk -F'-ota_full' '{print $1}')
OS_VER=$(echo "$FILENAME" | awk -F'ota_full-' '{print $2}' | awk -F'-user' '{print $1}')
ANDROID_VER=$(echo "$FILENAME" | awk -F'user-' '{print $2}' | cut -d'-' -f1)
[ -z "$DEVICE_CODE" ] && DEVICE_CODE="UnknownDevice"
[ -z "$OS_VER" ] && OS_VER="UnknownOS"
[ -z "$ANDROID_VER" ] && ANDROID_VER="0.0"
echo "   > Target: ota-nexdroid-${OS_VER}_${DEVICE_CODE}_${ANDROID_VER}.zip"

# --- CONFIGURATION ---
GAPPS_LINK="https://drive.google.com/file/d/1soDPsc9dhdXbuHLSx4t2L3u7x0fOlx_8/view?usp=drive_link"
NEX_PACKAGE_LINK="https://drive.google.com/file/d/1y2-7qEk_wkjLdkz93ydq1ReMLlCY5Deu/view?usp=sharing"
LAUNCHER_REPO="Mods-Center/HyperOS-Launcher"
KAORIOS_REPO="https://github.com/Wuang26/Kaorios-Toolbox.git"

# --- DIRECTORIES ---
GITHUB_WORKSPACE=$(pwd)
BIN_DIR="$GITHUB_WORKSPACE/bin"
OUTPUT_DIR="$GITHUB_WORKSPACE/NexMod_Output"
IMAGES_DIR="$OUTPUT_DIR/images"
SUPER_DIR="$OUTPUT_DIR/super"
TEMP_DIR="$GITHUB_WORKSPACE/temp"
KAORIOS_DIR="$GITHUB_WORKSPACE/nex_kaorios"

# --- BLOATWARE LIST ---
BLOAT_LIST="
com.xiaomi.aiasst.vision com.miui.carlink com.bsp.catchlog com.miui.nextpay
com.xiaomi.aiasst.service com.miui.securityinputmethod com.xiaomi.market com.miui.greenguard
com.mipay.wallet com.miui.systemAdSolution com.miui.bugreport com.xiaomi.migameservice
com.xiaomi.payment com.sohu.inputmethod.sogou.xiaomi com.android.updater com.miui.voiceassist
com.miui.voicetrigger com.xiaomi.xaee com.xiaomi.aireco com.baidu.input_mi com.mi.health
com.mfashiongallery.emag com.duokan.reader com.android.email com.xiaomi.gamecenter
com.miui.huanji com.miui.newmidrive com.miui.newhome com.miui.virtualsim
com.xiaomi.mibrain.speech com.xiaomi.youpin com.xiaomi.shop com.xiaomi.vipaccount
com.xiaomi.smarthome com.iflytek.inputmethod.miui
com.miui.miservice com.android.browser com.miui.player
com.miui.yellowpage com.xiaomi.gamecenter.sdk.service
cn.wps.moffice_eng.xiaomi.lite com.miui.tsmclient com.unionpay.tsmservice.mi com.xiaomi.ab
com.android.vending com.miui.fm com.miui.voiceassistProxy
"

# --- PROPS ---
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
# Kaorios Toolbox
persist.sys.kaorios=kousei
ro.control_privapp_permissions=
'

# =========================================================
#  2. SETUP & TOOLS
# =========================================================
echo "🛠️  Setting up Environment..."
mkdir -p "$IMAGES_DIR" "$SUPER_DIR" "$TEMP_DIR" "$BIN_DIR" "$KAORIOS_DIR"
export PATH="$BIN_DIR:$PATH"

sudo apt-get update -y
sudo apt-get install -y python3 python3-pip erofs-utils erofsfuse jq aria2 zip unzip liblz4-tool p7zip-full apktool aapt git
pip3 install gdown --break-system-packages

# =========================================================
#  3. DOWNLOAD RESOURCES
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
if [ ! -d "nex_pkg" ]; then
    echo "⬇️  Downloading NexPackage..."
    gdown "$NEX_PACKAGE_LINK" -O nex.zip --fuzzy
    unzip -q nex.zip -d nex_pkg && rm nex.zip
fi

# Kaorios Toolbox (Dynamic Asset Fetching)
echo "⬇️  Preparing Kaorios Toolbox..."
if [ ! -d "$KAORIOS_DIR/repo" ]; then
    git clone --depth 1 "$KAORIOS_REPO" "$KAORIOS_DIR/repo" >/dev/null 2>&1
fi

if [ ! -f "$KAORIOS_DIR/classes.dex" ]; then
    echo "   -> Fetching Latest Release Info..."
    LATEST_JSON=$(curl -s "https://api.github.com/repos/Wuang26/Kaorios-Toolbox/releases/latest")
    
    APK_URL=$(echo "$LATEST_JSON" | jq -r '.assets[] | select(.name | contains("KaoriosToolbox") and endswith(".apk")) | .browser_download_url')
    XML_URL=$(echo "$LATEST_JSON" | jq -r '.assets[] | select(.name | endswith(".xml")) | .browser_download_url')
    DEX_URL=$(echo "$LATEST_JSON" | jq -r '.assets[] | select(.name | contains("classes") and endswith(".dex")) | .browser_download_url')
    
    [ ! -z "$APK_URL" ] && [ "$APK_URL" != "null" ] && wget -q -O "$KAORIOS_DIR/KaoriosToolbox.apk" "$APK_URL"
    [ ! -z "$XML_URL" ] && [ "$XML_URL" != "null" ] && wget -q -O "$KAORIOS_DIR/kaorios_perm.xml" "$XML_URL"
    [ ! -z "$DEX_URL" ] && [ "$DEX_URL" != "null" ] && wget -q -O "$KAORIOS_DIR/classes.dex" "$DEX_URL"
fi

if [ ! -s "$KAORIOS_DIR/classes.dex" ]; then
    echo "   ⚠️ WARNING: classes.dex failed to download! Kaorios patch will be skipped."
else
    echo "   ✅ Kaorios assets ready."
fi

# Launcher
LAUNCHER_URL=$(curl -s "https://api.github.com/repos/$LAUNCHER_REPO/releases/latest" | jq -r '.assets[] | select(.name | endswith(".zip")) | .browser_download_url' | head -n 1)
if [ ! -z "$LAUNCHER_URL" ] && [ "$LAUNCHER_URL" != "null" ]; then
    wget -q -O l.zip "$LAUNCHER_URL"
    unzip -q l.zip -d l_ext
    FOUND=$(find l_ext -name "MiuiHome.apk" -type f | head -n 1)
    [ ! -z "$FOUND" ] && mv "$FOUND" "$TEMP_DIR/MiuiHome_Latest.apk"
    rm -rf l_ext l.zip
fi

# =========================================================
#  4. DOWNLOAD & EXTRACT ROM
# =========================================================
echo "⬇️  Downloading ROM..."
cd "$TEMP_DIR"
aria2c -x 16 -s 16 --file-allocation=none -o "rom.zip" "$ROM_URL"
if [ ! -f "rom.zip" ]; then echo "❌ Download Failed"; exit 1; fi
unzip -o "rom.zip" payload.bin && rm "rom.zip" 

echo "🔍 Extracting Firmware..."
payload-dumper-go -o "$IMAGES_DIR" payload.bin > /dev/null 2>&1
rm payload.bin

# Patch VBMeta
python3 -c "import sys; open(sys.argv[1], 'r+b').write(b'\x03', 123) if __name__=='__main__' else None" "$IMAGES_DIR/vbmeta.img" 2>/dev/null

# =========================================================
#  5. PARTITION MODIFICATION LOOP
# =========================================================
echo "🔄 Processing Partitions..."
LOGICALS="system system_ext product mi_ext vendor odm"

for part in $LOGICALS; do
    if [ -f "$IMAGES_DIR/${part}.img" ]; then
        echo "   -> Modding $part..."
        mkdir -p "${part}_dump" "mnt"
        
        # Mount & Copy
        sudo erofsfuse "$IMAGES_DIR/${part}.img" "mnt"
        if [ -z "$(sudo ls -A mnt)" ]; then
            echo "      ❌ ERROR: Mount failed!"
            sudo fusermount -uz "mnt"
            continue
        fi
        sudo cp -a "mnt/." "${part}_dump/"
        sudo chown -R $(whoami) "${part}_dump"
        sudo fusermount -uz "mnt"
        rm "$IMAGES_DIR/${part}.img"
        DUMP_DIR="${part}_dump"

        # -----------------------------
        # A. DEBLOATER
        # -----------------------------
        echo "      🗑️  Debloating..."
        echo "$BLOAT_LIST" | tr ' ' '\n' | grep -v "^\s*$" > "$TEMP_DIR/bloat_target_list.txt"
        find "$DUMP_DIR" -type f -name "*.apk" | while read apk_file; do
            pkg_name=$(aapt dump badging "$apk_file" 2>/dev/null | grep "package: name=" | cut -d"'" -f2)
            if [ ! -z "$pkg_name" ]; then
                if grep -Fxq "$pkg_name" "$TEMP_DIR/bloat_target_list.txt"; then
                    rm -rf "$(dirname "$apk_file")"
                fi
            fi
        done

        # -----------------------------
        # B. GAPPS INJECTION
        # -----------------------------
        if [ "$part" == "product" ] && [ -d "$GITHUB_WORKSPACE/gapps_src" ]; then
            echo "      🔵 Injecting GApps..."
            APP_ROOT="$DUMP_DIR/app"; PRIV_ROOT="$DUMP_DIR/priv-app"
            mkdir -p "$APP_ROOT" "$PRIV_ROOT"
            
             install_gapp_logic() {
                local app_list="$1"; local target_root="$2"
                for app in $app_list; do
                    local src=$(find "$GITHUB_WORKSPACE/gapps_src" -name "${app}.apk" -print -quit)
                    if [ -f "$src" ]; then
                        mkdir -p "$target_root/$app"
                        cp "$src" "$target_root/$app/${app}.apk"
                        chmod 644 "$target_root/$app/${app}.apk"
                    fi
                done
            }
            P_APP="SoundPickerGoogle MiuiBiometric LatinImeGoogle GoogleTTS GooglePartnerSetup GeminiShell"
            P_PRIV="Wizard Velvet Phonesky MIUIPackageInstaller GoogleRestore GooglePartnerSetup Assistant AndroidAutoStub"
            install_gapp_logic "$P_PRIV" "$PRIV_ROOT"
            install_gapp_logic "$P_APP" "$APP_ROOT"
        fi

        # -----------------------------
        # C. KAORIOS TOOLBOX (SYSTEM FRAMEWORK)
        # -----------------------------
        if [ "$part" == "system" ]; then
            echo "      🌸 Kaorios: Patching Framework..."
            
            # [FIXED] USE ABSOLUTE PATH to prevent 'mv' errors when changing directories
            # readlink -f will convert the relative path (system_dump/...) to absolute (/home/runner/...)
            RAW_PATH=$(find "$DUMP_DIR" -name "framework.jar" -type f | head -n 1)
            FW_JAR=$(readlink -f "$RAW_PATH")
            
            if [ ! -z "$FW_JAR" ] && [ -s "$KAORIOS_DIR/classes.dex" ]; then
                echo "         -> Target: $FW_JAR"
                
                # 1. DEX INJECTION
                echo "         -> Injecting classes.dex..."
                DEX_COUNT=$(unzip -l "$FW_JAR" | grep "classes.*\.dex" | wc -l)
                NEXT_DEX="classes$((DEX_COUNT + 1)).dex"
                if [ "$DEX_COUNT" -eq 1 ]; then NEXT_DEX="classes2.dex"; fi
                
                cp "$FW_JAR" "$TEMP_DIR/framework.jar"
                cp "$KAORIOS_DIR/classes.dex" "$TEMP_DIR/$NEXT_DEX"
                
                # Switch to temp to zip
                cd "$TEMP_DIR"
                zip -u -q "framework.jar" "$NEXT_DEX"
                
                # Move back using ABSOLUTE path
                mv "framework.jar" "$FW_JAR"
                
                # IMPORTANT: Go back to workspace immediately
                cd "$GITHUB_WORKSPACE"
                
                echo "            + Added $NEXT_DEX"

                # 2. SMALI PATCHER
                PATCHER_SCRIPT=$(find "$KAORIOS_DIR/repo" -name "*.py" -path "*/Toolbox-patcher/*" | head -1)
                if [ ! -z "$PATCHER_SCRIPT" ]; then
                    echo "         -> Running Repo Patcher..."
                    set +e
                    python3 "$PATCHER_SCRIPT" "$FW_JAR"
                    if [ $? -eq 0 ]; then
                        echo "            ✅ Framework Patched Successfully!"
                    else
                        echo "            ⚠️ Patcher failed (Skipping)."
                    fi
                    set +e
                fi
            else
                echo "         ! SKIPPED: framework.jar not found or classes.dex missing."
            fi
        fi

        # -----------------------------
        # D. NEXPACKAGE & KAORIOS ASSETS (PRODUCT)
        # -----------------------------
        if [ "$part" == "product" ]; then
            echo "      📦 Injecting NexPackage & Kaorios Assets..."
            
            PERM_DIR="$DUMP_DIR/etc/permissions"
            DEF_PERM_DIR="$DUMP_DIR/etc/default-permissions"
            OVERLAY_DIR="$DUMP_DIR/overlay"
            MEDIA_DIR="$DUMP_DIR/media"
            THEME_DIR="$DUMP_DIR/media/theme/default"
            KAORIOS_PRIV="$DUMP_DIR/priv-app/KaoriosToolbox"
            
            mkdir -p "$PERM_DIR" "$DEF_PERM_DIR" "$OVERLAY_DIR" "$MEDIA_DIR" "$THEME_DIR" "$KAORIOS_PRIV"
            
            # 1. Kaorios App & Perms
            if [ -f "$KAORIOS_DIR/KaoriosToolbox.apk" ]; then
                cp "$KAORIOS_DIR/KaoriosToolbox.apk" "$KAORIOS_PRIV/"
                chmod 644 "$KAORIOS_PRIV/KaoriosToolbox.apk"
            fi
            if [ -f "$KAORIOS_DIR/kaorios_perm.xml" ]; then
                cp "$KAORIOS_DIR/kaorios_perm.xml" "$PERM_DIR/"
                chmod 644 "$PERM_DIR/"*.xml
            fi

            # 2. NexPackage Logic
            if [ -d "$GITHUB_WORKSPACE/nex_pkg" ]; then
                # A. Default Permissions (Strict Folder)
                DEF_XML="default-permissions-google.xml"
                if [ -f "$GITHUB_WORKSPACE/nex_pkg/$DEF_XML" ]; then
                     cp "$GITHUB_WORKSPACE/nex_pkg/$DEF_XML" "$DEF_PERM_DIR/"
                     chmod 644 "$DEF_PERM_DIR/$DEF_XML"
                     echo "         ✅ Default Perms Injected."
                fi
                
                # B. Other Permissions
                find "$GITHUB_WORKSPACE/nex_pkg" -maxdepth 1 -name "*.xml" ! -name "$DEF_XML" -exec cp {} "$PERM_DIR/" \;
                chmod 644 "$PERM_DIR/"*.xml 2>/dev/null || true
                
                # C. Overlays
                cp "$GITHUB_WORKSPACE/nex_pkg/"*.apk "$OVERLAY_DIR/" 2>/dev/null
                chmod 644 "$OVERLAY_DIR/"*.apk 2>/dev/null || true
                
                # D. Bootanimation
                [ -f "$GITHUB_WORKSPACE/nex_pkg/bootanimation.zip" ] && cp "$GITHUB_WORKSPACE/nex_pkg/bootanimation.zip" "$MEDIA_DIR/"
                
                # E. Lock Wallpaper
                [ -f "$GITHUB_WORKSPACE/nex_pkg/lock_wallpaper" ] && cp "$GITHUB_WORKSPACE/nex_pkg/lock_wallpaper" "$THEME_DIR/"
            fi
        fi
        
        # -----------------------------
        # E. SMALI PATCHER (Provision.apk)
        # -----------------------------
        PROV_APK=$(find "$DUMP_DIR" -name "Provision.apk" -type f -print -quit)
        if [ ! -z "$PROV_APK" ]; then
            echo "      🔧 Patching Provision.apk..."
            apktool d -r -f "$PROV_APK" -o "prov_temp" > /dev/null 2>&1
            if [ -d "prov_temp" ]; then
                grep -r "IS_INTERNATIONAL_BUILD" "prov_temp" | cut -d: -f1 | while read smali_file; do
                    sed -i -E 's/sget-boolean ([vp][0-9]+), Lmiui\/os\/Build;->IS_INTERNATIONAL_BUILD:Z/const\/4 \1, 0x1/g' "$smali_file"
                done
            fi
            apktool b "prov_temp" -o "$PROV_APK" > /dev/null 2>&1
            rm -rf "prov_temp"
        fi

        # -----------------------------
        # F. REPACK
        # -----------------------------
        find "$DUMP_DIR" -name "build.prop" | while read prop; do echo "$PROPS_CONTENT" >> "$prop"; done
        sudo mkfs.erofs -zlz4 "$SUPER_DIR/${part}.img" "$DUMP_DIR"
        sudo rm -rf "$DUMP_DIR"
    fi
done

# =========================================================
#  6. COMPRESSION & UPLOAD
# =========================================================
echo "📦  Zipping Super..."
cd "$SUPER_DIR"
SUPER_ZIP="ota-nexdroid-${OS_VER}_${DEVICE_CODE}_${ANDROID_VER}.zip"
7z a -tzip -mx1 -mmt=$(nproc) "$SUPER_ZIP" *.img > /dev/null
mv "$SUPER_ZIP" "$OUTPUT_DIR/"

echo "📦  Zipping Firmware..."
cd "$OUTPUT_DIR"
mkdir -p FirmwarePack/images
find "$IMAGES_DIR" -maxdepth 1 -type f -name "*.img" -exec mv {} FirmwarePack/images/ \;

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
    local file=$1; [ ! -f "$file" ] && return
    echo "   ⬆️ Uploading $file..."
    if [ -z "$PIXELDRAIN_KEY" ]; then
        LINK=$(curl -s -T "$file" "https://pixeldrain.com/api/file/" | jq -r '"https://pixeldrain.com/u/" + .id')
    else
        LINK=$(curl -s -T "$file" -u :$PIXELDRAIN_KEY "https://pixeldrain.com/api/file/" | jq -r '"https://pixeldrain.com/u/" + .id')
    fi
    [ ! -z "$LINK" ] && [ "$LINK" != "null" ] && echo "$LINK" || echo "Upload Failed"
}

LINK_FW=$(upload "Firmware_Flasher.zip")
LINK_SUPER=$(upload "$SUPER_ZIP")

if [ ! -z "$TELEGRAM_TOKEN" ]; then
    MSG="✅ *Build Done!*
📱 *Device:* $DEVICE_CODE
📦 [Firmware]($LINK_FW)
📦 [Super]($LINK_SUPER)"
    curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage" -d chat_id="$CHAT_ID" -d parse_mode="Markdown" -d text="$MSG" > /dev/null
fi
