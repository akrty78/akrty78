#!/bin/bash

# =========================================================
#  NEXDROID GOONER - ROOT POWER EDITION
#  (Uses Sudo for FS operations to ensure files stick)
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
# Standard /product/app/
PRODUCT_APP="SoundPickerGoogle MiuiBiometric LatinImeGoogle GoogleTTS GooglePartnerSetup GeminiShell"

# Privileged /product/priv-app/
PRODUCT_PRIV="Wizard Velvet Phonesky MIUIPackageInstaller GoogleRestore GooglePartnerSetup Assistant AndroidAutoStub"

# --- PERMISSIONS CONFIGURATION ---
# Source folder in your repo: permissions/
PERM_FILE_LIST="
cn.google.services.xml
com.android.vending.xml
com.google.android.apps.googleassistant.xml
com.google.android.googlequicksearchbox.xml
com.google.android.setupwizard.xml
cross_device_services.xml
gemini_shell.xml
google-initial-package-stopped-states.xml
google-staged-installer-whitelist.xml
google.xml
google_build.xml
google_exclusives_enable.xml
initial-package-stopped-states-aosp.xml
microsoft.xml
preinstalled-packages-platform-overlays.xml
preinstalled-packages-platform-telephony-product.xml
privapp-permissions-deviceintegrationservice.xml
privapp-permissions-gms-international-product.xml
privapp-permissions-microsoft-product.xml
privapp-permissions-miui-product.xml
split-permissions-google.xml
"

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
sudo apt-get install -y python3 python3-pip erofs-utils erofsfuse jq aria2 zip unzip liblz4-tool p7zip-full apktool aapt
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
unzip -o "rom.zip" payload.bin && rm "rom.zip" 

echo "🔍 Extracting Firmware..."
payload-dumper-go -o "$IMAGES_DIR" payload.bin > /dev/null 2>&1
rm payload.bin

# Detect Device
DEVICE_CODE="unknown"
if [ -f "$IMAGES_DIR/mi_ext.img" ]; then
    mkdir -p mnt; sudo erofsfuse "$IMAGES_DIR/mi_ext.img" mnt
    # Need sudo to read the mounted file now
    RAW=$(sudo grep "ro.product.mod_device=" "mnt/etc/build.prop" 2>/dev/null | head -1 | cut -d'=' -f2)
    [ ! -z "$RAW" ] && DEVICE_CODE=$(echo "$RAW" | cut -d'_' -f1)
    sudo fusermount -uz mnt
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
        
        # [FIXED]: Use SUDO for mount so ROOT can read it
        sudo erofsfuse "$IMAGES_DIR/${part}.img" "mnt"
        
        # Check if mount worked
        if [ -z "$(ls -A mnt)" ]; then
            echo "      ❌ ERROR: Mount failed or empty image!"
            sudo fusermount -uz "mnt"
            continue
        fi

        # Copy with Permissions (sudo cp -a)
        sudo cp -a "mnt/." "${part}_dump/"
        sudo chown -R $(whoami) "${part}_dump" # Reclaim ownership for editing
        
        # [FIXED]: Unmount with sudo
        sudo fusermount -uz "mnt"
        rm "$IMAGES_DIR/${part}.img"
        
        DUMP_DIR="${part}_dump"

        # -----------------------------
        # A. DEBLOATER (PACKAGE NAME EDITION)
        # -----------------------------
        echo "      🗑️  Debloating by Package Name..."
        
        # Create temp list for grep
        echo "$BLOAT_LIST" | tr ' ' '\n' | grep -v "^\s*$" > "$TEMP_DIR/bloat_target_list.txt"

        # Find all APKs
        find "$DUMP_DIR" -type f -name "*.apk" | while read apk_file; do
            # Read internal package name
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
        # B. GAPPS & PERMISSIONS INJECTION
        # -----------------------------
        if [ "$part" == "product" ] && [ -d "$GITHUB_WORKSPACE/gapps_src" ]; then
            echo "      🔵 Injecting GApps into Product..."
            
            APP_ROOT=$(find "$DUMP_DIR" -type d -name "app" -print -quit)
            PRIV_ROOT=$(find "$DUMP_DIR" -type d -name "priv-app" -print -quit)
            ETC_ROOT=$(find "$DUMP_DIR" -type d -name "etc" -print -quit)
            
            # --- 1. APP INJECTION HELPER ---
            install_gapp_logic() {
                local app_list="$1"
                local target_root="$2"
                local type_label="$3"

                if [ -z "$target_root" ]; then
                    echo "      ⚠️  Warning: $type_label folder not found!"
                    return
                fi

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

            # --- 2. PERMISSIONS INJECTION (XMLs) ---
            if [ ! -z "$ETC_ROOT" ] && [ -d "$GITHUB_WORKSPACE/permissions" ]; then
                echo "      -> Injecting Permissions XMLs..."
                
                # A. Standard Permissions (product/etc/permissions/)
                TARGET_PERM_DIR="$ETC_ROOT/permissions"
                mkdir -p "$TARGET_PERM_DIR"
                
                for xml in $PERM_FILE_LIST; do
                    local src_xml="$GITHUB_WORKSPACE/permissions/$xml"
                    if [ -f "$src_xml" ]; then
                        cp "$src_xml" "$TARGET_PERM_DIR/"
                        chmod 644 "$TARGET_PERM_DIR/$xml"
                        echo "          + Perm: $xml"
                    else
                        echo "          ⚠️  Missing Perm XML: $xml"
                    fi
                done

                # B. Default Permissions (product/etc/default-permissions/)
                TARGET_DEF_DIR="$ETC_ROOT/default-permissions"
                mkdir -p "$TARGET_DEF_DIR"
                
                local def_xml="default-permissions-google.xml"
                local src_def="$GITHUB_WORKSPACE/permissions/$def_xml"
                
                if [ -f "$src_def" ]; then
                    cp "$src_def" "$TARGET_DEF_DIR/"
                    chmod 644 "$TARGET_DEF_DIR/$def_xml"
                    echo "          + Default Perm: $def_xml"
                else
                    echo "          ⚠️  Missing Default Perm XML: $def_xml"
                fi
            fi
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
        # D. NEXPACKAGE
        # -----------------------------
        if [ -f "$TEMP_DIR/MiuiHome_Latest.apk" ]; then
            TARGET=$(find "$DUMP_DIR" -name "MiuiHome.apk" -type f -print -quit)
            if [ ! -z "$TARGET" ]; then
                cp "$TEMP_DIR/MiuiHome_Latest.apk" "$TARGET"
                chmod 644 "$TARGET"
                echo "      📱 Launcher Updated."
            fi
        fi
        if [ -d "$GITHUB_WORKSPACE/nex_pkg" ]; then
            MEDIA_DIR=$(find "$DUMP_DIR" -type d -name "media" -print -quit)
            if [ ! -z "$MEDIA_DIR" ]; then
                [ -f "$GITHUB_WORKSPACE/nex_pkg/bootanimation.zip" ] && cp "$GITHUB_WORKSPACE/nex_pkg/bootanimation.zip" "$MEDIA_DIR/"
                [ -d "$GITHUB_WORKSPACE/nex_pkg/walls" ] && mkdir -p "$MEDIA_DIR/wallpaper/wallpaper_group" && cp -r "$GITHUB_WORKSPACE/nex_pkg/walls/"* "$MEDIA_DIR/wallpaper/wallpaper_group/" 2>/dev/null
            fi
        fi
        
        # -----------------------------
        # E. REPACK
        # -----------------------------
        find "$DUMP_DIR" -name "build.prop" | while read prop; do echo "$PROPS_CONTENT" >> "$prop"; done
        
        # VERIFY BEFORE REPACKING
        if [ "$part" == "product" ]; then
             COUNT=$(find "$DUMP_DIR" -name "GoogleTTS.apk" | wc -l)
             if [ "$COUNT" -gt 0 ]; then
                 echo "      ✅ VERIFIED: Google Apps exist in dump before repacking."
             else
                 echo "      ❌ WARNING: Google Apps MISSING in dump before repacking!"
             fi
        fi
        
        # USE SUDO TO REPACK
        sudo mkfs.erofs -zlz4 "$SUPER_DIR/${part}.img" "$DUMP_DIR"
        sudo rm -rf "$DUMP_DIR"
    fi
done

# =========================================================
#  5. COMPRESSION & UPLOAD
# =========================================================
echo "📦  Zipping Super..."
cd "$SUPER_DIR"
SUPER_ZIP="Super_Images_${DEVICE_CODE}.zip"
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
