#!/bin/bash

# =========================================================
#  NEXDROID GOONER - ROOT POWER EDITION v11
#  (Fixed: default-permissions-google.xml injection path)
# =========================================================

set +e 

# --- INPUTS ---
ROM_URL="$1"

# --- 1. INSTANT METADATA EXTRACTION ---
FILENAME=$(basename "$ROM_URL" | cut -d'?' -f1)

echo "🔍 Analyzing OTA Link..."

# Extract Device Code
DEVICE_CODE=$(echo "$FILENAME" | awk -F'-ota_full' '{print $1}')

# Extract OS Version
OS_VER=$(echo "$FILENAME" | awk -F'ota_full-' '{print $2}' | awk -F'-user' '{print $1}')

# Extract Android Version
ANDROID_VER=$(echo "$FILENAME" | awk -F'user-' '{print $2}' | cut -d'-' -f1)

# Fallbacks
[ -z "$DEVICE_CODE" ] && DEVICE_CODE="UnknownDevice"
[ -z "$OS_VER" ] && OS_VER="UnknownOS"
[ -z "$ANDROID_VER" ] && ANDROID_VER="0.0"

echo "   > Device:  $DEVICE_CODE"
echo "   > OS Ver:  $OS_VER"
echo "   > Android: $ANDROID_VER"
echo "   > Target:  ota-nexdroid-${OS_VER}_${DEVICE_CODE}_${ANDROID_VER}.zip"

# --- CONFIGURATION ---
GAPPS_LINK="https://drive.google.com/file/d/1soDPsc9dhdXbuHLSx4t2L3u7x0fOlx_8/view?usp=drive_link"
# NexPackage Link
NEX_PACKAGE_LINK="https://drive.google.com/file/d/1y2-7qEk_wkjLdkz93ydq1ReMLlCY5Deu/view?usp=sharing"
LAUNCHER_REPO="Mods-Center/HyperOS-Launcher"

# --- DIRECTORIES ---
GITHUB_WORKSPACE=$(pwd)
BIN_DIR="$GITHUB_WORKSPACE/bin"
OUTPUT_DIR="$GITHUB_WORKSPACE/NexMod_Output"
IMAGES_DIR="$OUTPUT_DIR/images"
SUPER_DIR="$OUTPUT_DIR/super"
TEMP_DIR="$GITHUB_WORKSPACE/temp"

# --- BLOATWARE LIST (BY PACKAGE NAME) ---
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

# --- APPS CONFIGURATION ---
PRODUCT_APP="SoundPickerGoogle MiuiBiometric LatinImeGoogle GoogleTTS GooglePartnerSetup GeminiShell"
PRODUCT_PRIV="Wizard Velvet Phonesky MIUIPackageInstaller GoogleRestore GooglePartnerSetup Assistant AndroidAutoStub"

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
#  2. SETUP & TOOLS
# =========================================================
echo "🛠️  Setting up Environment..."
mkdir -p "$IMAGES_DIR" "$SUPER_DIR" "$TEMP_DIR" "$BIN_DIR"
export PATH="$BIN_DIR:$PATH"

sudo apt-get update -y
sudo apt-get install -y python3 python3-pip erofs-utils erofsfuse jq aria2 zip unzip liblz4-tool p7zip-full apktool aapt
pip3 install gdown --break-system-packages

# =========================================================
#  3. DOWNLOAD RESOURCES
# =========================================================
if [ ! -f "$BIN_DIR/payload-dumper-go" ]; then
    wget -q -O pd.tar.gz https://github.com/ssut/payload-dumper-go/releases/download/1.2.2/payload-dumper-go_1.2.2_linux_amd64.tar.gz
    tar -xzf pd.tar.gz
    find . -type f -name "payload-dumper-go" -not -path "*/bin/*" -exec mv {} "$BIN_DIR/" \;
    chmod +x "$BIN_DIR/payload-dumper-go"
    rm pd.tar.gz
fi

if [ ! -d "gapps_src" ]; then
    echo "⬇️  Downloading GApps..."
    gdown "$GAPPS_LINK" -O gapps.zip --fuzzy
    unzip -q gapps.zip -d gapps_src && rm gapps.zip
fi

# Download and extract NexPackage
if [ ! -d "nex_pkg" ]; then
    echo "⬇️  Downloading NexPackage..."
    gdown "$NEX_PACKAGE_LINK" -O nex.zip --fuzzy
    unzip -q nex.zip -d nex_pkg && rm nex.zip
fi

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
echo "🛡️  Patching VBMeta..."
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
        
        # 1. Mount (as Root)
        sudo erofsfuse "$IMAGES_DIR/${part}.img" "mnt"
        
        # 2. Check mount
        if [ -z "$(sudo ls -A mnt)" ]; then
            echo "      ❌ ERROR: Mount failed or empty image!"
            sudo fusermount -uz "mnt"
            continue
        fi

        # 3. Copy
        sudo cp -a "mnt/." "${part}_dump/"
        sudo chown -R $(whoami) "${part}_dump"
        
        sudo fusermount -uz "mnt"
        rm "$IMAGES_DIR/${part}.img"
        
        DUMP_DIR="${part}_dump"

        # -----------------------------
        # A. DEBLOATER
        # -----------------------------
        echo "      🗑️  Debloating by Package Name..."
        echo "$BLOAT_LIST" | tr ' ' '\n' | grep -v "^\s*$" > "$TEMP_DIR/bloat_target_list.txt"
        find "$DUMP_DIR" -type f -name "*.apk" | while read apk_file; do
            pkg_name=$(aapt dump badging "$apk_file" 2>/dev/null | grep "package: name=" | cut -d"'" -f2)
            if [ ! -z "$pkg_name" ]; then
                if grep -Fxq "$pkg_name" "$TEMP_DIR/bloat_target_list.txt"; then
                    app_dir=$(dirname "$apk_file")
                    if [ -d "$app_dir" ]; then
                        rm -rf "$app_dir"
                        echo "          🔥 Nuked: $pkg_name"
                    fi
                fi
            fi
        done

        # -----------------------------
        # B. GAPPS INJECTION
        # -----------------------------
        if [ "$part" == "product" ] && [ -d "$GITHUB_WORKSPACE/gapps_src" ]; then
            echo "      🔵 Injecting GApps into Product..."
            
            APP_ROOT="$DUMP_DIR/app"
            PRIV_ROOT="$DUMP_DIR/priv-app"
            mkdir -p "$APP_ROOT" "$PRIV_ROOT"

            install_gapp_logic() {
                local app_list="$1"
                local target_root="$2"
                local type_label="$3"

                for app in $app_list; do
                    local src_apk=$(find "$GITHUB_WORKSPACE/gapps_src" -name "${app}.apk" -print -quit)
                    if [ -f "$src_apk" ]; then
                        local dest_path="$target_root/$app"
                        mkdir -p "$dest_path"
                        cp "$src_apk" "$dest_path/${app}.apk"
                        chmod 755 "$dest_path"
                        chmod 644 "$dest_path/${app}.apk"
                        echo "          + Installed $type_label: $app"
                    else
                        echo "          ! Missing Source: $app"
                    fi
                done
            }

            install_gapp_logic "$PRODUCT_PRIV" "$PRIV_ROOT" "priv-app"
            install_gapp_logic "$PRODUCT_APP" "$APP_ROOT" "app"
        fi

        # -----------------------------
        # C. SMALI PATCHER
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
            echo "          ✅ Patch Applied (Unsigned)."
        fi

        # -----------------------------
        # D. NEXPACKAGE INJECTION (FIXED)
        # -----------------------------
        if [ "$part" == "product" ] && [ -d "$GITHUB_WORKSPACE/nex_pkg" ]; then
            echo "      📦 Injecting NexPackage Assets..."
            
            # Define Targets
            PERM_DIR="$DUMP_DIR/etc/permissions"
            DEF_PERM_DIR="$DUMP_DIR/etc/default-permissions"
            OVERLAY_DIR="$DUMP_DIR/overlay"
            MEDIA_DIR="$DUMP_DIR/media"
            THEME_DIR="$DUMP_DIR/media/theme/default"
            
            # Create Directories (Ensure default-permissions exists!)
            mkdir -p "$PERM_DIR" "$DEF_PERM_DIR" "$OVERLAY_DIR" "$MEDIA_DIR" "$THEME_DIR"
            
            # 1. Inject Default Permissions (Special Handling)
            # We strictly move default-permissions-google.xml to its specific folder
            DEF_XML_NAME="default-permissions-google.xml"
            DEF_XML_SRC="$GITHUB_WORKSPACE/nex_pkg/$DEF_XML_NAME"
            
            if [ -f "$DEF_XML_SRC" ]; then
                 cp "$DEF_XML_SRC" "$DEF_PERM_DIR/"
                 chmod 644 "$DEF_PERM_DIR/$DEF_XML_NAME"
                 echo "         ✅ $DEF_XML_NAME -> etc/default-permissions/"
            else
                 echo "         ⚠️  Missing $DEF_XML_NAME in zip!"
            fi

            # 2. Inject General Permissions (All other XMLs)
            echo "         -> Injecting Standard XMLs..."
            # Find all XMLs EXCEPT the default permissions one, and copy them to etc/permissions
            find "$GITHUB_WORKSPACE/nex_pkg" -maxdepth 1 -name "*.xml" ! -name "$DEF_XML_NAME" -exec cp {} "$PERM_DIR/" \;
            chmod 644 "$PERM_DIR/"*.xml 2>/dev/null || true

            # 3. Inject Overlays (APKs)
            echo "         -> Injecting Overlays..."
            cp "$GITHUB_WORKSPACE/nex_pkg/"*.apk "$OVERLAY_DIR/" 2>/dev/null
            if ls "$OVERLAY_DIR/"*.apk 1> /dev/null 2>&1; then
                chmod 644 "$OVERLAY_DIR/"*.apk
            fi

            # 4. Inject Bootanimation
            echo "         -> Injecting Bootanimation..."
            BOOT_SRC="$GITHUB_WORKSPACE/nex_pkg/bootanimation.zip"
            if [ -f "$BOOT_SRC" ]; then
                 cp "$BOOT_SRC" "$MEDIA_DIR/bootanimation.zip"
                 chmod 644 "$MEDIA_DIR/bootanimation.zip"
            fi

            # 5. Inject Lock Wallpaper
            echo "         -> Injecting Lock Wallpaper..."
            LOCK_SRC="$GITHUB_WORKSPACE/nex_pkg/lock_wallpaper"
            if [ -f "$LOCK_SRC" ]; then
                 cp "$LOCK_SRC" "$THEME_DIR/lock_wallpaper"
                 chmod 644 "$THEME_DIR/lock_wallpaper"
            fi
        fi
        
        # -----------------------------
        # E. REPACK
        # -----------------------------
        find "$DUMP_DIR" -name "build.prop" | while read prop; do echo "$PROPS_CONTENT" >> "$prop"; done
        
        if [ "$part" == "product" ]; then
             COUNT=$(find "$DUMP_DIR" -name "GoogleTTS.apk" | wc -l)
             if [ "$COUNT" -gt 0 ]; then
                 echo "      ✅ VERIFIED: Google Apps exist in dump before repacking."
             else
                 echo "      ❌ WARNING: Google Apps MISSING in dump before repacking!"
             fi
        fi
        
        sudo mkfs.erofs -zlz4 "$SUPER_DIR/${part}.img" "$DUMP_DIR"
        sudo rm -rf "$DUMP_DIR"
    fi
done

# =========================================================
#  6. COMPRESSION & UPLOAD
# =========================================================
echo "📦  Zipping Super..."
cd "$SUPER_DIR"

# Using Variables from Step 1
SUPER_ZIP="ota-nexdroid-${OS_VER}_${DEVICE_CODE}_${ANDROID_VER}.zip"

echo "   > Filename: $SUPER_ZIP"

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
    local file=$1
    [ ! -f "$file" ] && return
    
    echo "   ⬆️ Uploading $file (Attempt 1: PixelDrain)..."
    if [ -z "$PIXELDRAIN_KEY" ]; then
        LINK=$(curl -s -T "$file" "https://pixeldrain.com/api/file/" | jq -r '"https://pixeldrain.com/u/" + .id')
    else
        LINK=$(curl -s -T "$file" -u :$PIXELDRAIN_KEY "https://pixeldrain.com/api/file/" | jq -r '"https://pixeldrain.com/u/" + .id')
    fi

    if [[ "$LINK" == *"pixeldrain.com"* ]] && [[ "$LINK" != *"null"* ]]; then
        echo "$LINK"
        return
    fi

    echo "   ⚠️ PixelDrain failed. Attempt 2: Transfer.sh..."
    curl -s --upload-file "$file" "https://transfer.sh/$(basename "$file")"
}

LINK_FW=$(upload "Firmware_Flasher.zip")
LINK_SUPER=$(upload "$SUPER_ZIP")

if [ ! -z "$TELEGRAM_TOKEN" ]; then
    MSG="✅ *Build Done!*
📱 *Device:* $DEVICE_CODE
📦 [Firmware]($LINK_FW)
📦 [Super]($LINK_SUPER)"
    
    if [[ -z "$LINK_SUPER" ]] || [[ "$LINK_SUPER" == *"null"* ]]; then
        MSG="⚠️ *Build Finished but Upload Failed!*
Check GitHub Actions Artifacts."
    fi

    curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage" -d chat_id="$CHAT_ID" -d parse_mode="Markdown" -d text="$MSG" > /dev/null
fi
