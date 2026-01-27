#!/bin/bash

# =========================================================
#  NEXDROID MANAGER - ROOT POWER EDITION v52
#  (Fix: Direct MiuiBooster Replace + Strict Phrase App Detection)
# =========================================================

set +e 

# --- INPUTS ---
ROM_URL="$1"

# --- 1. METADATA ---
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

# --- FUNCTIONS ---
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

# --- GENERATE APK-MODDER.SH (For Settings.apk) ---
# We keep this as it works well for the simple true/false patches
cat <<'EOF' > "$GITHUB_WORKSPACE/apk-modder.sh"
#!/bin/bash
APK_PATH="$1"; TARGET_CLASS="$2"; TARGET_METHOD="$3"; RETURN_VAL="$4"
BIN_DIR="$(pwd)/bin"; TEMP_MOD="temp_modder"
export PATH="$BIN_DIR:$PATH"
[ ! -f "$APK_PATH" ] && exit 1
echo "   [APK-Modder] 💉 Patching $TARGET_METHOD..."
rm -rf "$TEMP_MOD"
apktool d -r -f "$APK_PATH" -o "$TEMP_MOD" >/dev/null 2>&1
CLASS_PATH=$(echo "$TARGET_CLASS" | sed 's/\./\//g')
SMALI_FILE=$(find "$TEMP_MOD" -type f -path "*/$CLASS_PATH.smali" | head -n 1)
[ -z "$SMALI_FILE" ] && { echo "   [APK-Modder] ⚠️ Class not found"; rm -rf "$TEMP_MOD"; exit 0; }

cat <<PY > "$BIN_DIR/wiper.py"
import sys, re
file_path = sys.argv[1]; method_name = sys.argv[2]; ret_type = sys.argv[3]
tpl_true = ".registers 1\n    const/4 v0, 0x1\n    return v0"
tpl_false = ".registers 1\n    const/4 v0, 0x0\n    return v0"
tpl_void = ".registers 0\n    return-void"
payload = tpl_void
if ret_type.lower() == 'true': payload = tpl_true
elif ret_type.lower() == 'false': payload = tpl_false
with open(file_path, 'r') as f: content = f.read()
pattern = r'(\.method.* ' + re.escape(method_name) + r'\(.*)(?s:.*?)(\.end method)'
new_content, count = re.subn(pattern, lambda m: m.group(1) + "\n" + payload + "\n" + m.group(2), content)
if count > 0:
    with open(file_path, 'w') as f: f.write(new_content)
    print("PATCHED")
PY
RESULT=$(python3 "$BIN_DIR/wiper.py" "$SMALI_FILE" "$TARGET_METHOD" "$RETURN_VAL")
[ "$RESULT" == "PATCHED" ] && apktool b -c "$TEMP_MOD" -o "$APK_PATH" >/dev/null 2>&1 && echo "   [APK-Modder] ✅ Done."
rm -rf "$TEMP_MOD" "$BIN_DIR/wiper.py"
EOF
chmod +x "$GITHUB_WORKSPACE/apk-modder.sh"

# =========================================================
#  2. SETUP & TOOLS
# =========================================================
echo "🛠️  Setting up Environment..."
mkdir -p "$IMAGES_DIR" "$SUPER_DIR" "$TEMP_DIR" "$BIN_DIR" "$KAORIOS_DIR"
export PATH="$BIN_DIR:$PATH"

sudo apt-get update -y
sudo apt-get install -y python3 python3-pip erofs-utils erofsfuse jq aria2 zip unzip liblz4-tool p7zip-full aapt git openjdk-17-jre-headless
pip3 install gdown --break-system-packages

if [ -f "apk-modder.sh" ]; then chmod +x apk-modder.sh; fi

# =========================================================
#  3. DOWNLOAD RESOURCES
# =========================================================
if [ ! -f "$BIN_DIR/apktool.jar" ]; then
    echo "⬇️  Fetching Apktool v2.12.1..."
    wget -q -O "$BIN_DIR/apktool.jar" "https://github.com/iBotPeaches/Apktool/releases/download/v2.12.1/apktool_2.12.1.jar"
    if [ -f "$BIN_DIR/apktool.jar" ]; then
        echo '#!/bin/bash' > "$BIN_DIR/apktool"
        echo 'java -Xmx4G -jar "'"$BIN_DIR"'/apktool.jar" "$@"' >> "$BIN_DIR/apktool"
        chmod +x "$BIN_DIR/apktool"
    else
        sudo apt-get install -y apktool
    fi
fi

if [ ! -f "$BIN_DIR/payload-dumper-go" ]; then
    wget -q -O pd.tar.gz https://github.com/ssut/payload-dumper-go/releases/download/1.2.2/payload-dumper-go_1.2.2_linux_amd64.tar.gz
    tar -xzf pd.tar.gz
    find . -type f -name "payload-dumper-go" -not -path "*/bin/*" -exec mv {} "$BIN_DIR/" \;
    chmod +x "$BIN_DIR/payload-dumper-go"
    rm pd.tar.gz
fi

for link in "$GAPPS_LINK:gapps.zip" "$NEX_PACKAGE_LINK:nex.zip"; do
    url="${link%%:*}"; name="${link##*:}"
    if [ ! -f "$name" ]; then echo "⬇️ Downloading $name..."; gdown "$url" -O "$name" --fuzzy; fi
done
[ -f "gapps.zip" ] && { unzip -q gapps.zip -d gapps_src; rm gapps.zip; }
[ -f "nex.zip" ] && { unzip -q nex.zip -d nex_pkg; rm nex.zip; }

if [ ! -f "$KAORIOS_DIR/classes.dex" ]; then
    echo "⬇️ Fetching Kaorios Assets..."
    LATEST_JSON=$(curl -s "https://api.github.com/repos/Wuang26/Kaorios-Toolbox/releases/latest")
    for type in "apk" "xml" "dex"; do
        URL=$(echo "$LATEST_JSON" | jq -r --arg t "$type" '.assets[] | select(.name | endswith("."+$t)) | .browser_download_url' | head -n 1)
        [ ! -z "$URL" ] && wget -q -P "$KAORIOS_DIR" "$URL"
    done
fi

if [ ! -f "$TEMP_DIR/MiuiHome_Latest.apk" ]; then
    L_URL=$(curl -s "https://api.github.com/repos/$LAUNCHER_REPO/releases/latest" | jq -r '.assets[] | select(.name | endswith(".zip")) | .browser_download_url' | head -n 1)
    if [ ! -z "$L_URL" ]; then
        wget -q -O l.zip "$L_URL"; unzip -q l.zip -d l_ext
        find l_ext -name "MiuiHome.apk" -exec mv {} "$TEMP_DIR/MiuiHome_Latest.apk" \;
        rm -rf l_ext l.zip
    fi
fi

# =========================================================
#  4. DOWNLOAD & EXTRACT ROM
# =========================================================
echo "⬇️  Downloading ROM..."
cd "$TEMP_DIR"
aria2c -x 16 -s 16 --file-allocation=none -o "rom.zip" "$ROM_URL"
[ ! -f "rom.zip" ] && { echo "❌ Download Failed"; exit 1; }
unzip -o "rom.zip" payload.bin && rm "rom.zip" 

echo "🔍 Extracting Firmware..."
payload-dumper-go -o "$IMAGES_DIR" payload.bin > /dev/null 2>&1
rm payload.bin
python3 -c "import sys; open(sys.argv[1], 'r+b').write(b'\x03', 123) if __name__=='__main__' else None" "$IMAGES_DIR/vbmeta.img" 2>/dev/null

# =========================================================
#  5. PARTITION MODIFICATION LOOP
# =========================================================
echo "🔄 Processing Partitions..."
LOGICALS="system system_ext product mi_ext vendor odm"

for part in $LOGICALS; do
    if [ -f "$IMAGES_DIR/${part}.img" ]; then
        echo "   -> Modding $part..."
        DUMP_DIR="$GITHUB_WORKSPACE/${part}_dump"
        mkdir -p "$DUMP_DIR" "mnt"
        sudo erofsfuse "$IMAGES_DIR/${part}.img" "mnt"
        [ -z "$(sudo ls -A mnt)" ] && { echo "      ❌ Mount failed"; sudo fusermount -uz "mnt"; continue; }
        sudo cp -a "mnt/." "$DUMP_DIR/"; sudo chown -R $(whoami) "$DUMP_DIR"; sudo fusermount -uz "mnt"; rm "$IMAGES_DIR/${part}.img"

        # A. DEBLOATER
        echo "      🗑️  Debloating..."
        echo "$BLOAT_LIST" | tr ' ' '\n' > "$TEMP_DIR/bloat.txt"
        find "$DUMP_DIR" -name "*.apk" | while read apk; do
            pkg=$(aapt dump badging "$apk" 2>/dev/null | grep "package: name=" | cut -d"'" -f2)
            grep -Fxq "$pkg" "$TEMP_DIR/bloat.txt" && rm -rf "$(dirname "$apk")"
        done

        # B. GAPPS
        if [ "$part" == "product" ] && [ -d "$GITHUB_WORKSPACE/gapps_src" ]; then
            echo "      🔵 Injecting GApps..."
            install_gapp_logic "Wizard Velvet Phonesky MIUIPackageInstaller GoogleRestore GooglePartnerSetup Assistant AndroidAutoStub" "$DUMP_DIR/priv-app"
            install_gapp_logic "SoundPickerGoogle MiuiBiometric LatinImeGoogle GoogleTTS GooglePartnerSetup GeminiShell" "$DUMP_DIR/app"
        fi

        # C. MIUI BOOSTER [DIRECT FIX]
        if [ "$part" == "system_ext" ]; then
            echo "      🚀 Checking for MiuiBooster.jar..."
            BOOST_JAR=$(find "$DUMP_DIR" -name "MiuiBooster.jar" | head -n 1)
            
            if [ -z "$BOOST_JAR" ]; then
                echo "      ⚠️ MiuiBooster.jar NOT FOUND in this partition."
            else
                echo "      [LOG] Found at: $BOOST_JAR"
                cp "$BOOST_JAR" "${BOOST_JAR}.bak"
                rm -rf "$TEMP_DIR/boost_src"
                
                # Decompile
                if timeout 3m apktool d -r -f "$BOOST_JAR" -o "$TEMP_DIR/boost_src" >/dev/null 2>&1; then
                    echo "      [LOG] Decompiled. Searching for DeviceLevelUtils..."
                    
                    # Find specific smali file
                    UTILS_SMALI=$(find "$TEMP_DIR/boost_src" -name "DeviceLevelUtils.smali" | head -n 1)
                    
                    if [ -z "$UTILS_SMALI" ]; then
                        echo "      ❌ DeviceLevelUtils.smali NOT FOUND."
                    else
                        echo "      [LOG] Found Smali: $UTILS_SMALI. Applying Nuclear Patch..."
                        
                        # NUCLEAR PYTHON PATCHER (Inline)
cat <<PY > "$TEMP_DIR/patch_booster.py"
import sys, re
with open("$UTILS_SMALI", 'r') as f: content = f.read()

# Exact payload requested
payload = """.method public initDeviceLevel()V
    .registers 2
    const-string v0, "v:1,c:3,g:3"
    .line 130
    invoke-direct {p0, v0}, Lcom/miui/performance/DeviceLevelUtils;->parseDeviceLevelList(Ljava/lang/String;)V
    .line 140
    return-void
.end method"""

# Regex to find the whole method block
pattern = r'(\.method public initDeviceLevel\(\)V)(?s:.*?)(\.end method)'
new_content, count = re.subn(pattern, payload, content)

if count > 0:
    with open("$UTILS_SMALI", 'w') as f: f.write(new_content)
    print("SUCCESS")
else:
    print("FAIL")
PY
                        # Run Patch
                        RES=$(python3 "$TEMP_DIR/patch_booster.py")
                        if [ "$RES" == "SUCCESS" ]; then
                            echo "      [LOG] ✅ DeviceLevelUtils Patched Successfully."
                            apktool b -c "$TEMP_DIR/boost_src" -o "$TEMP_DIR/boost_patched.jar" >/dev/null 2>&1
                            [ -f "$TEMP_DIR/boost_patched.jar" ] && mv "$TEMP_DIR/boost_patched.jar" "$BOOST_JAR"
                        else
                            echo "      ❌ Regex Match Failed. Method signature changed?"
                        fi
                    fi
                else
                    echo "      ❌ Decompile Failed."
                fi
            fi
        fi

        # D. MIUI FRAMEWORK (Baidu -> Gboard)
        if [ "$part" == "system_ext" ]; then
            echo "      ⌨️  Patching MIUI Framework..."
            MF_JAR=$(find "$DUMP_DIR" -name "miui-framework.jar" | head -n 1)
            if [ ! -z "$MF_JAR" ]; then
                cp "$MF_JAR" "${MF_JAR}.bak"
                rm -rf "$TEMP_DIR/mf_src"
                if timeout 5m apktool d -r -f "$MF_JAR" -o "$TEMP_DIR/mf_src" >/dev/null 2>&1; then
                    grep -rl "com.baidu.input_mi" "$TEMP_DIR/mf_src" | xargs sed -i 's/com.baidu.input_mi/com.google.android.inputmethod.latin/g'
                    apktool b -c "$TEMP_DIR/mf_src" -o "$TEMP_DIR/patched.jar" >/dev/null 2>&1
                    [ -f "$TEMP_DIR/patched.jar" ] && { mv "$TEMP_DIR/patched.jar" "$MF_JAR"; echo "      ✅ Framework Patched."; }
                fi
            fi
        fi

        # E. MIUI PHRASE APP (Strict Package Check)
        if [ "$part" == "system_ext" ] || [ "$part" == "product" ]; then
            echo "      🎨 Searching for Phrase App (com.miui.phrase)..."
            
            # Find all APKs, check package name
            find "$DUMP_DIR" -name "*.apk" | while read apk; do
                pkg=$(aapt dump badging "$apk" 2>/dev/null | grep "package: name='com.miui.phrase'")
                
                if [ ! -z "$pkg" ]; then
                    echo "      [LOG] Found Target: $apk"
                    rm -rf "$TEMP_DIR/phrase_src"
                    
                    # Decompile WITH Resources
                    if timeout 5m apktool d -f "$apk" -o "$TEMP_DIR/phrase_src" >/dev/null 2>&1; then
                        echo "      [LOG] Patching Smali..."
                        find "$TEMP_DIR/phrase_src" -name "InputMethodBottomManager.smali" -exec sed -i 's/com.baidu.input_mi/com.google.android.inputmethod.latin/g' {} +
                        
                        echo "      [LOG] Patching Colors..."
                        [ -f "$TEMP_DIR/phrase_src/res/values/colors.xml" ] && sed -i 's|<color name="input_bottom_background_color">.*</color>|<color name="input_bottom_background_color">@android:color/system_neutral1_50</color>|g' "$TEMP_DIR/phrase_src/res/values/colors.xml"
                        [ -f "$TEMP_DIR/phrase_src/res/values-night/colors.xml" ] && sed -i 's|<color name="input_bottom_background_color">.*</color>|<color name="input_bottom_background_color">@android:color/system_neutral1_900</color>|g' "$TEMP_DIR/phrase_src/res/values-night/colors.xml"
                        
                        echo "      [LOG] Rebuilding..."
                        apktool b -c "$TEMP_DIR/phrase_src" -o "$TEMP_DIR/phrase_patched.apk" >/dev/null 2>&1
                        [ -f "$TEMP_DIR/phrase_patched.apk" ] && { mv "$TEMP_DIR/phrase_patched.apk" "$apk"; echo "      ✅ Phrase App Patched!"; }
                    else
                        echo "      ❌ Failed to decompile phrase app."
                    fi
                    break # Stop looking once found
                fi
            done
        fi

        # F. NEXPACKAGE
        if [ "$part" == "product" ] && [ -d "$GITHUB_WORKSPACE/nex_pkg" ]; then
            echo "      📦 Injecting NexPackage..."
            cp -r "$GITHUB_WORKSPACE/nex_pkg/"* "$DUMP_DIR/" 2>/dev/null
            chmod 644 "$DUMP_DIR/etc/permissions/"* 2>/dev/null
        fi
        
        # G. PROVISION
        PROV_APK=$(find "$DUMP_DIR" -name "Provision.apk" | head -n 1)
        if [ ! -z "$PROV_APK" ]; then
            echo "      🔧 Patching Provision..."
            apktool d -r -f "$PROV_APK" -o "prov_temp" > /dev/null 2>&1
            if [ -d "prov_temp" ]; then
                grep -r "IS_INTERNATIONAL_BUILD" "prov_temp" | cut -d: -f1 | xargs sed -i -E 's/sget-boolean ([vp][0-9]+), Lmiui\/os\/Build;->IS_INTERNATIONAL_BUILD:Z/const\/4 \1, 0x1/g'
                apktool b "prov_temp" -o "$PROV_APK" >/dev/null 2>&1
            fi; rm -rf "prov_temp"
        fi

        # H. SETTINGS MOD
        SETTINGS_APK=$(find "$DUMP_DIR" -name "Settings.apk" | head -n 1)
        [ ! -z "$SETTINGS_APK" ] && { echo "      💊 Modding Settings..."; ./apk-modder.sh "$SETTINGS_APK" "com/android/settings/InternalDeviceUtils" "isAiSupported" "true"; }

        # REPACK
        find "$DUMP_DIR" -name "build.prop" -exec bash -c "echo \"$PROPS_CONTENT\" >> {}" \;
        sudo mkfs.erofs -zlz4 "$SUPER_DIR/${part}.img" "$DUMP_DIR"
        sudo rm -rf "$DUMP_DIR"
    fi
done

# =========================================================
#  6. FINALIZE
# =========================================================
echo "📦  Packaging..."
PACK_DIR="$OUTPUT_DIR/Final_Pack"; mkdir -p "$PACK_DIR/super" "$PACK_DIR/images"
find "$SUPER_DIR" -name "*.img" -exec mv {} "$PACK_DIR/super/" \;
find "$IMAGES_DIR" -name "*.img" -exec mv {} "$PACK_DIR/images/" \;

cat <<'EOF' > "$PACK_DIR/flash_rom.bat"
@echo off
echo ========================================
echo      NEXDROID FLASHER
echo ========================================
fastboot set_active a
for %%f in (images\*.img) do fastboot flash %%~nf "%%f"
for %%f in (super\*.img) do fastboot flash %%~nf "%%f"
fastboot erase userdata
fastboot reboot
pause
EOF

cd "$PACK_DIR"
SUPER_ZIP="ota-nexdroid-${OS_VER}_${DEVICE_CODE}_${ANDROID_VER}.zip"
7z a -tzip -mx1 -mmt=$(nproc) "$SUPER_ZIP" . > /dev/null
mv "$SUPER_ZIP" "$OUTPUT_DIR/"

echo "☁️  Uploading..."
cd "$OUTPUT_DIR"
upload() {
    curl -s -T "$1" -u :$PIXELDRAIN_KEY "https://pixeldrain.com/api/file/" | jq -r '"https://pixeldrain.com/u/" + .id'
}
LINK_ZIP=$(upload "$SUPER_ZIP")
echo "   > Link: $LINK_ZIP"

[ -z "$LINK_ZIP" ] || [ "$LINK_ZIP" == "null" ] && LINK_ZIP="https://pixeldrain.com" && BTN="Upload Failed" || BTN="Download ROM"

if [ ! -z "$TELEGRAM_TOKEN" ]; then
    MSG="**NEXDROID BUILD COMPLETE**
---------------------------
\`Device  : $DEVICE_CODE\`
\`Version : $OS_VER\`
\`Android : $ANDROID_VER\`"
    
    JSON=$(jq -n --arg c "$CHAT_ID" --arg t "$MSG" --arg u "$LINK_ZIP" --arg b "$BTN" \
    '{chat_id:$c, parse_mode:"Markdown", text:$t, reply_markup:{inline_keyboard:[[{text:$b, url:$u}]]}}')
    
    curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage" -H "Content-Type: application/json" -d "$JSON" >/dev/null
fi

exit 0
