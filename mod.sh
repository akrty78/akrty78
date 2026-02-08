#!/bin/bash
# =========================================================
#  NEXDROID MANAGER - ROOT POWER EDITION v58 (DIRECT DEX)
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

# --- DIRECTORIES ---
GITHUB_WORKSPACE=$(pwd)
BIN_DIR="$GITHUB_WORKSPACE/bin"
OUTPUT_DIR="$GITHUB_WORKSPACE/NexMod_Output"
IMAGES_DIR="$OUTPUT_DIR/images"
SUPER_DIR="$OUTPUT_DIR/super"
TEMP_DIR="$GITHUB_WORKSPACE/temp"
KAORIOS_DIR="$GITHUB_WORKSPACE/nex_kaorios"
KEYS_DIR="$BIN_DIR/keys"

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
persist.sys.kaorios=kousei
ro.control_privapp_permissions=
'

# --- FUNCTIONS ---
install_gapp_logic() {
    local app_list="$1"; local target_root="$2"
    local installed=0
    local missing=0
    
    for app in $app_list; do
        local src=$(find "$GITHUB_WORKSPACE/gapps_src" -name "${app}.apk" -print -quit)
        if [ -f "$src" ]; then
            mkdir -p "$target_root/$app"
            cp "$src" "$target_root/$app/${app}.apk"
            chmod 644 "$target_root/$app/${app}.apk"
            echo "         ✅ $app.apk → $(basename $target_root)/$app/"
            installed=$((installed + 1))
        else
            echo "         ⚠️ $app.apk (not found in gapps_src)"
            missing=$((missing + 1))
        fi
    done
    
    echo "         📊 Installed: $installed | Missing: $missing"
}

# --- SIGNING FUNCTIONS ---
sign_apk() {
    local apk_path="$1"
    local apk_name=$(basename "$apk_path")
    
    if [ ! -f "$apk_path" ]; then
        echo "      ⚠️ APK not found: $apk_path"
        return 1
    fi
    
    # Backup original
    cp "$apk_path" "${apk_path}.unsigned"
    
    # Zipalign first (if available)
    if command -v zipalign &> /dev/null; then
        zipalign -f 4 "$apk_path" "${apk_path}.aligned" 2>/dev/null
        if [ -f "${apk_path}.aligned" ]; then
            mv "${apk_path}.aligned" "$apk_path"
        fi
    fi
    
    # Sign with apksigner (preferred) or jarsigner
    if command -v apksigner &> /dev/null; then
        apksigner sign --key "$KEYS_DIR/testkey.pk8" \
                      --cert "$KEYS_DIR/testkey.x509.pem" \
                      "$apk_path" 2>/dev/null
        if [ $? -eq 0 ]; then
            echo "      ✅ Signed: $apk_name (apksigner)"
            rm -f "${apk_path}.unsigned"
            return 0
        fi
    fi
    
    # Fallback to jarsigner
    if command -v jarsigner &> /dev/null; then
        if [ ! -f "$KEYS_DIR/platform.keystore" ]; then
            keytool -genkeypair -keystore "$KEYS_DIR/platform.keystore" \
                    -storepass android -alias platform -keypass android \
                    -keyalg RSA -keysize 2048 -validity 10000 \
                    -dname "CN=Android, OU=Android, O=Android, L=Android, S=Android, C=US" 2>/dev/null
        fi
        
        jarsigner -keystore "$KEYS_DIR/platform.keystore" \
                  -storepass android -keypass android \
                  -digestalg SHA1 -sigalg SHA1withRSA \
                  "$apk_path" platform 2>/dev/null
        
        if [ $? -eq 0 ]; then
            echo "      ✅ Signed: $apk_name (jarsigner)"
            rm -f "${apk_path}.unsigned"
            return 0
        fi
    fi
    
    # If signing failed, restore backup
    echo "      ⚠️ Signing failed for $apk_name, using unsigned version"
    if [ -f "${apk_path}.unsigned" ]; then
        mv "${apk_path}.unsigned" "$apk_path"
    fi
    return 1
}

# =========================================================
#  2. SETUP & TOOLS
# =========================================================
echo "🛠️  Setting up Environment..."
mkdir -p "$IMAGES_DIR" "$SUPER_DIR" "$TEMP_DIR" "$BIN_DIR" "$KAORIOS_DIR" "$KEYS_DIR"
export PATH="$BIN_DIR:$PATH"

sudo apt-get update -y
sudo apt-get install -y python3 python3-pip erofs-utils erofsfuse jq aria2 zip unzip \
    liblz4-tool p7zip-full aapt git openjdk-17-jre-headless zipalign apksigner

pip3 install gdown --break-system-packages

# Setup signing keys
if [ ! -f "$KEYS_DIR/testkey.pk8" ]; then
    echo "🔑 Generating signing keys..."
    cd "$KEYS_DIR"
    
    openssl genrsa -out testkey.pem 2048 2>/dev/null
    openssl req -new -x509 -key testkey.pem -out testkey.x509.pem -days 10000 \
        -subj "/C=US/ST=California/L=Mountain View/O=Android/OU=Android/CN=Android" 2>/dev/null
    openssl pkcs8 -in testkey.pem -topk8 -outform DER -out testkey.pk8 -nocrypt 2>/dev/null
    
    keytool -genkeypair -keystore platform.keystore \
            -storepass android -alias platform -keypass android \
            -keyalg RSA -keysize 2048 -validity 10000 \
            -dname "CN=Android, OU=Android, O=Android, L=Android, S=Android, C=US" 2>/dev/null
    
    echo "   ✅ Signing keys generated"
    cd "$GITHUB_WORKSPACE"
fi

# =========================================================
#  3. DOWNLOAD RESOURCES
# =========================================================
# APKTOOL 2.12.1
if [ ! -f "$BIN_DIR/apktool.jar" ]; then
    echo "⬇️  Fetching Apktool v2.12.1..."
    APKTOOL_URL="https://github.com/iBotPeaches/Apktool/releases/download/v2.12.1/apktool_2.12.1.jar"
    wget -q -O "$BIN_DIR/apktool.jar" "$APKTOOL_URL"
    
    if [ -f "$BIN_DIR/apktool.jar" ]; then
        echo "   ✅ Installed Apktool v2.12.1"
        cat > "$BIN_DIR/apktool" <<'APKTOOL_SCRIPT'
#!/bin/bash
APKTOOL_JAR="$(dirname "$0")/apktool.jar"
FRAMEWORK_DIR="$HOME/.local/share/apktool/framework"
mkdir -p "$FRAMEWORK_DIR"
exec java -Xmx8G -Djava.io.tmpdir=/tmp -jar "$APKTOOL_JAR" "$@"
APKTOOL_SCRIPT
        chmod +x "$BIN_DIR/apktool"
    else
        echo "   ❌ Failed to download Apktool! Falling back to apt..."
        sudo apt-get install -y apktool
    fi
fi

# BAKSMALI/SMALI for Direct Dex Editing
if [ ! -f "$BIN_DIR/baksmali.jar" ]; then
    echo "⬇️  Installing baksmali/smali v2.5.2..."
    wget -q -O "$BIN_DIR/baksmali.jar" "https://github.com/JesusFreke/smali/releases/download/v2.5.2/baksmali-2.5.2.jar"
    wget -q -O "$BIN_DIR/smali.jar" "https://github.com/JesusFreke/smali/releases/download/v2.5.2/smali-2.5.2.jar"
    
    cat > "$BIN_DIR/baksmali" <<'BAKSMALI_WRAPPER'
#!/bin/bash
exec java -jar "$(dirname "$0")/baksmali.jar" "$@"
BAKSMALI_WRAPPER
    
    cat > "$BIN_DIR/smali" <<'SMALI_WRAPPER'
#!/bin/bash
exec java -jar "$(dirname "$0")/smali.jar" "$@"
SMALI_WRAPPER
    
    chmod +x "$BIN_DIR/baksmali" "$BIN_DIR/smali"
    echo "   ✅ baksmali/smali installed"
fi

# Payload Dumper
if [ ! -f "$BIN_DIR/payload-dumper-go" ]; then
    echo "⬇️  Installing Payload Dumper..."
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
    if [ -f "gapps.zip" ]; then
        unzip -q gapps.zip -d gapps_src && rm gapps.zip
    fi
fi

# NexPackage
if [ ! -d "nex_pkg" ]; then
    echo "⬇️  Downloading NexPackage..."
    gdown "$NEX_PACKAGE_LINK" -O nex.zip --fuzzy
    if [ -f "nex.zip" ]; then
        unzip -q nex.zip -d nex_pkg && rm nex.zip
    fi
fi

# Kaorios Assets
echo "⬇️  Preparing Kaorios Assets..."
if [ ! -f "$KAORIOS_DIR/classes.dex" ]; then
    LATEST_JSON=$(curl -s "https://api.github.com/repos/Wuang26/Kaorios-Toolbox/releases/latest")
    APK_URL=$(echo "$LATEST_JSON" | jq -r '.assets[] | select(.name | contains("KaoriosToolbox") and endswith(".apk")) | .browser_download_url')
    XML_URL=$(echo "$LATEST_JSON" | jq -r '.assets[] | select(.name | endswith(".xml")) | .browser_download_url')
    DEX_URL=$(echo "$LATEST_JSON" | jq -r '.assets[] | select(.name | contains("classes") and endswith(".dex")) | .browser_download_url')
    
    [ ! -z "$APK_URL" ] && [ "$APK_URL" != "null" ] && wget -q -O "$KAORIOS_DIR/KaoriosToolbox.apk" "$APK_URL"
    [ ! -z "$XML_URL" ] && [ "$XML_URL" != "null" ] && wget -q -O "$KAORIOS_DIR/kaorios_perm.xml" "$XML_URL"
    [ ! -z "$DEX_URL" ] && [ "$DEX_URL" != "null" ] && wget -q -O "$KAORIOS_DIR/classes.dex" "$DEX_URL"
fi

# Launcher
if [ ! -f "$TEMP_DIR/MiuiHome_Latest.apk" ]; then
    echo "⬇️  Downloading Launcher..."
    LAUNCHER_URL=$(curl -s "https://api.github.com/repos/$LAUNCHER_REPO/releases/latest" | jq -r '.assets[] | select(.name | endswith(".zip")) | .browser_download_url' | head -n 1)
    if [ ! -z "$LAUNCHER_URL" ] && [ "$LAUNCHER_URL" != "null" ]; then
        wget -q -O l.zip "$LAUNCHER_URL"
        unzip -q l.zip -d l_ext
        FOUND=$(find l_ext -name "MiuiHome.apk" -type f | head -n 1)
        [ ! -z "$FOUND" ] && mv "$FOUND" "$TEMP_DIR/MiuiHome_Latest.apk"
        rm -rf l_ext l.zip
    fi
fi

# =========================================================
#  4. DOWNLOAD & EXTRACT ROM
# =========================================================
echo "⬇️  Downloading ROM..."
cd "$TEMP_DIR"
aria2c -x 16 -s 16 --file-allocation=none -o "rom.zip" "$ROM_URL"
if [ ! -f "rom.zip" ]; then 
    echo "❌ Download Failed"
    exit 1
fi

unzip -o "rom.zip" payload.bin && rm "rom.zip" 

echo "🔍 Extracting Firmware..."
payload-dumper-go -o "$IMAGES_DIR" payload.bin > /dev/null 2>&1
rm payload.bin

# Patch VBMeta
if [ -f "$IMAGES_DIR/vbmeta.img" ]; then
    python3 -c "
with open('$IMAGES_DIR/vbmeta.img', 'r+b') as f:
    f.seek(123)
    f.write(b'\x03')
" 2>/dev/null
    echo "   ✅ VBMeta patched"
fi

# =========================================================
#  5. PARTITION MODIFICATION LOOP
# =========================================================
echo "🔄 Processing Partitions..."
LOGICALS="system system_ext product mi_ext vendor odm"

for part in $LOGICALS; do
    if [ -f "$IMAGES_DIR/${part}.img" ]; then
        echo ""
        echo "========================================"
        echo "   PROCESSING: $part"
        echo "========================================"
        
        # Show what will be processed in this partition
        case "$part" in
            "system")
                echo "   📋 Tasks: build.prop injection"
                ;;
            "system_ext")
                echo "   📋 Tasks: MiuiBooster, MIUI-framework, Provision.apk, Settings.apk"
                ;;
            "product")
                echo "   📋 Tasks: Debloater, GApps, MIUIFrequentPhrase, NexPackage"
                ;;
            *)
                echo "   📋 Tasks: build.prop injection"
                ;;
        esac
        echo ""
        
        DUMP_DIR="$GITHUB_WORKSPACE/${part}_dump"
        mkdir -p "$DUMP_DIR" "mnt"
        
        sudo erofsfuse "$IMAGES_DIR/${part}.img" "mnt"
        if [ -z "$(sudo ls -A mnt 2>/dev/null)" ]; then
            echo "   ❌ ERROR: Mount failed!"
            sudo fusermount -uz "mnt" 2>/dev/null || sudo umount "mnt" 2>/dev/null
            continue
        fi
        
        sudo cp -a "mnt/." "$DUMP_DIR/"
        sudo chown -R $(whoami):$(whoami) "$DUMP_DIR"
        sudo fusermount -uz "mnt" 2>/dev/null || sudo umount "mnt" 2>/dev/null
        rm "$IMAGES_DIR/${part}.img"

        # A. DEBLOATER (PRODUCT PARTITION ONLY)
        if [ "$part" == "product" ]; then
            echo "   🗑️  Debloating..."
            echo "$BLOAT_LIST" | tr ' ' '\n' | grep -v "^\s*$" > "$TEMP_DIR/bloat_target_list.txt"
            
            BLOAT_COUNT=0
            APK_COUNT=0
            
            echo "      🔍 Scanning for APKs in: $DUMP_DIR"
            
            while IFS= read -r apk_file; do
                APK_COUNT=$((APK_COUNT + 1))
                pkg_name=$(aapt dump badging "$apk_file" 2>/dev/null | grep "package: name=" | cut -d"'" -f2)
                
                if [ ! -z "$pkg_name" ]; then
                    if grep -Fxq "$pkg_name" "$TEMP_DIR/bloat_target_list.txt"; then
                        rm -rf "$(dirname "$apk_file")"
                        echo "      ❌ Removed: $pkg_name ($(dirname "$apk_file"))"
                        BLOAT_COUNT=$((BLOAT_COUNT + 1))
                    fi
                fi
            done < <(find "$DUMP_DIR" -type f -name "*.apk")
            
            echo "      📊 Scanned: $APK_COUNT APKs | Removed: $BLOAT_COUNT bloatware packages"
        fi

        # B. GAPPS INJECTION
        if [ "$part" == "product" ] && [ -d "$GITHUB_WORKSPACE/gapps_src" ]; then
            echo "   🔵 Injecting GApps..."
            APP_ROOT="$DUMP_DIR/app"
            PRIV_ROOT="$DUMP_DIR/priv-app"
            mkdir -p "$APP_ROOT" "$PRIV_ROOT"
            
            echo "      📂 GApps source: $GITHUB_WORKSPACE/gapps_src"
            
            P_APP="SoundPickerGoogle MiuiBiometric LatinImeGoogle GoogleTTS GooglePartnerSetup GeminiShell"
            P_PRIV="Velvet Phonesky MIUIPackageInstaller GoogleRestore GooglePartnerSetup Assistant AndroidAutoStub"
            
            echo "      📦 Installing to /app..."
            install_gapp_logic "$P_APP" "$APP_ROOT"
            
            echo "      📦 Installing to /priv-app..."
            install_gapp_logic "$P_PRIV" "$PRIV_ROOT"
            
            echo "      ✅ GApps injection complete"
        elif [ "$part" == "product" ]; then
            echo "   ⚠️ Skipping GApps injection (gapps_src not found)"
        fi

        # C. KAORIOS FRAMEWORK PATCHER - REMOVED AS REQUESTED
        # (Section removed entirely)

        # D. MIUI BOOSTER PATCHING
        if [ "$part" == "system_ext" ]; then
            echo "   🚀 Kaorios: Patching MiuiBooster..."
            BOOST_JAR=$(find "$DUMP_DIR" -name "MiuiBooster.jar" -type f | head -n 1)
            
            if [ ! -z "$BOOST_JAR" ] && [ -f "$BOOST_JAR" ]; then
                echo "      ✅ Found: $BOOST_JAR"
                
                cat <<'EOF_BOOST' > "$TEMP_DIR/patch_booster.py"
import sys, re, os, subprocess

jar_path = sys.argv[1]
temp_dir = "bst_tmp_$$"

ret = subprocess.call(f"apktool d -r -f '{jar_path}' -o {temp_dir} >/dev/null 2>&1", shell=True)
if ret != 0:
    print("      ❌ Decompile failed")
    sys.exit(1)

target_file = None
for root, dirs, files in os.walk(temp_dir):
    if "DeviceLevelUtils.smali" in files:
        target_file = os.path.join(root, "DeviceLevelUtils.smali")
        break

if not target_file:
    print("      ⚠️ DeviceLevelUtils.smali not found")
    sys.exit(0)

with open(target_file, 'r') as f:
    content = f.read()

method_body = """
    .registers 2

    const-string v0, "v:1,c:3,g:3"

    .line 130
    invoke-direct {p0, v0}, Lcom/miui/performance/DeviceLevelUtils;->parseDeviceLevelList(Ljava/lang/String;)V

    .line 140
    return-void
"""

pattern = re.compile(r'(\.method public initDeviceLevel\(\)V)(.*?)(\.end method)', re.DOTALL)
new_content = pattern.sub(f"\\1{method_body}\\3", content)

if content != new_content:
    with open(target_file, 'w') as f:
        f.write(new_content)
    print("      ✅ Method replaced: initDeviceLevel()")
    
    ret = subprocess.call(f"apktool b -c {temp_dir} -o 'booster_patched.jar' >/dev/null 2>&1", shell=True)
    if ret == 0 and os.path.exists("booster_patched.jar"):
        os.replace("booster_patched.jar", jar_path)
        print("      ✅ MiuiBooster repacked")
    else:
        print("      ❌ Recompile failed")
else:
    print("      ⚠️ Method already patched or not found")

import shutil
if os.path.exists(temp_dir):
    shutil.rmtree(temp_dir)
EOF_BOOST

                python3 "$TEMP_DIR/patch_booster.py" "$BOOST_JAR"
                rm -f "$TEMP_DIR/patch_booster.py"
            else
                echo "      ⚠️ MiuiBooster.jar not found, skipping..."
            fi
        fi

        # E. MIUI-FRAMEWORK (Baidu → Gboard)
        if [ "$part" == "system_ext" ]; then
            echo "   ⌨️  Redirecting Baidu IME to Gboard..."
            MF_JAR=$(find "$DUMP_DIR" -name "miui-framework.jar" -type f | head -n 1)
            
            if [ ! -z "$MF_JAR" ] && [ -f "$MF_JAR" ]; then
                echo "      ✅ Found: $MF_JAR"
                cp "$MF_JAR" "${MF_JAR}.bak"
                rm -rf "$TEMP_DIR/mf.jar" "$TEMP_DIR/mf_src"
                cp "$MF_JAR" "$TEMP_DIR/mf.jar"
                
                cd "$TEMP_DIR"
                if timeout 5m apktool d -r -f "mf.jar" -o "mf_src" >/dev/null 2>&1; then
                    echo "      📦 Decompiled successfully"
                    PATCHED=0
                    grep -rl "com.baidu.input_mi" "mf_src" | while read f; do
                        if [[ "$f" == *"InputMethodServiceInjector.smali"* ]]; then
                            sed -i 's/com\.baidu\.input_mi/com.google.android.inputmethod.latin/g' "$f"
                            echo "      ✅ Patched: $(basename $f)"
                            PATCHED=1
                        fi
                    done
                    
                    if [ "$PATCHED" -eq 1 ] || grep -rq "com.google.android.inputmethod.latin" "mf_src"; then
                        apktool b -c "mf_src" -o "mf_patched.jar" >/dev/null 2>&1
                        if [ -f "mf_patched.jar" ]; then
                            mv "mf_patched.jar" "$MF_JAR"
                            echo "      ✅ miui-framework.jar repacked successfully"
                        else
                            echo "      ❌ Recompile failed"
                        fi
                    else
                        echo "      ⚠️ No Baidu IME references found"
                    fi
                else
                    echo "      ❌ Decompile failed"
                fi
                cd "$GITHUB_WORKSPACE"
            else
                echo "      ⚠️ miui-framework.jar not found, skipping..."
            fi
        fi

        # F. MIUI FREQUENT PHRASE (PRODUCT PARTITION)
        if [ "$part" == "product" ]; then
            MFP_APK=$(find "$DUMP_DIR" -name "MIUIFrequentPhrase.apk" -type f -print -quit)
            if [ ! -z "$MFP_APK" ] && [ -f "$MFP_APK" ]; then
                echo "   🎨 Modding MIUIFrequentPhrase..."
                echo "      ✅ Found: $MFP_APK"
            rm -rf "$TEMP_DIR/mfp.apk" "$TEMP_DIR/mfp_src"
            cp "$MFP_APK" "$TEMP_DIR/mfp.apk"
            
            cd "$TEMP_DIR"
            if timeout 5m apktool d -f "mfp.apk" -o "mfp_src" >/dev/null 2>&1; then
                echo "      📦 Decompiled successfully"
                
                # Patch IME
                IME_FILES=$(find "mfp_src" -name "InputMethodBottomManager.smali" | wc -l)
                if [ "$IME_FILES" -gt 0 ]; then
                    find "mfp_src" -name "InputMethodBottomManager.smali" -exec sed -i 's/com\.baidu\.input_mi/com.google.android.inputmethod.latin/g' {} +
                    echo "      ✅ Patched IME redirect (Baidu → Gboard)"
                else
                    echo "      ⚠️ InputMethodBottomManager.smali not found"
                fi
                
                if [ -f "mfp_src/res/values/colors.xml" ]; then
                    sed -i 's|<color name="input_bottom_background_color">.*</color>|<color name="input_bottom_background_color">@android:color/system_neutral1_50</color>|g' "mfp_src/res/values/colors.xml"
                    echo "      ✅ Patched colors.xml (light theme)"
                fi
                if [ -f "mfp_src/res/values-night/colors.xml" ]; then
                    sed -i 's|<color name="input_bottom_background_color">.*</color>|<color name="input_bottom_background_color">@android:color/system_neutral1_900</color>|g' "mfp_src/res/values-night/colors.xml"
                    echo "      ✅ Patched colors.xml (dark theme)"
                fi
                
                apktool b -c "mfp_src" -o "mfp_patched.apk" >/dev/null 2>&1
                if [ -f "mfp_patched.apk" ]; then
                    echo "      📦 Recompiled successfully"
                    sign_apk "mfp_patched.apk"
                    mv "mfp_patched.apk" "$MFP_APK"
                    echo "      ✅ MIUIFrequentPhrase patched & signed"
                else
                    echo "      ❌ Recompile failed"
                fi
            else
                echo "      ❌ Decompile failed"
            fi
            cd "$GITHUB_WORKSPACE"
            fi
        fi

        # G. NEXPACKAGE INJECTION
        if [ "$part" == "product" ]; then
            echo "   📦 Injecting NexPackage Assets..."
            PERM_DIR="$DUMP_DIR/etc/permissions"
            DEF_PERM_DIR="$DUMP_DIR/etc/default-permissions"
            OVERLAY_DIR="$DUMP_DIR/overlay"
            MEDIA_DIR="$DUMP_DIR/media"
            THEME_DIR="$DUMP_DIR/media/theme/default"
            KAORIOS_PRIV="$DUMP_DIR/priv-app/KaoriosToolbox"
            
            mkdir -p "$PERM_DIR" "$DEF_PERM_DIR" "$OVERLAY_DIR" "$MEDIA_DIR" "$THEME_DIR" "$KAORIOS_PRIV"
            
            echo "      🌸 Installing Kaorios Toolbox..."
            if [ -f "$KAORIOS_DIR/KaoriosToolbox.apk" ]; then
                cp "$KAORIOS_DIR/KaoriosToolbox.apk" "$KAORIOS_PRIV/"
                echo "         ✅ KaoriosToolbox.apk → /priv-app/KaoriosToolbox/"
            else
                echo "         ⚠️ KaoriosToolbox.apk not found"
            fi
            
            if [ -f "$KAORIOS_DIR/kaorios_perm.xml" ]; then
                cp "$KAORIOS_DIR/kaorios_perm.xml" "$PERM_DIR/"
                echo "         ✅ kaorios_perm.xml → /etc/permissions/"
            else
                echo "         ⚠️ kaorios_perm.xml not found"
            fi

            if [ -d "$GITHUB_WORKSPACE/nex_pkg" ]; then
                echo "      📂 Installing NexPackage assets..."
                
                DEF_XML="default-permissions-google.xml"
                if [ -f "$GITHUB_WORKSPACE/nex_pkg/$DEF_XML" ]; then
                    cp "$GITHUB_WORKSPACE/nex_pkg/$DEF_XML" "$DEF_PERM_DIR/"
                    chmod 644 "$DEF_PERM_DIR/$DEF_XML"
                    echo "         ✅ $DEF_XML → /etc/default-permissions/"
                fi
                
                XML_COUNT=$(find "$GITHUB_WORKSPACE/nex_pkg" -maxdepth 1 -name "*.xml" ! -name "$DEF_XML" | wc -l)
                if [ "$XML_COUNT" -gt 0 ]; then
                    find "$GITHUB_WORKSPACE/nex_pkg" -maxdepth 1 -name "*.xml" ! -name "$DEF_XML" -exec cp {} "$PERM_DIR/" \;
                    echo "         ✅ $XML_COUNT permission XML(s) → /etc/permissions/"
                fi
                
                APK_COUNT=$(find "$GITHUB_WORKSPACE/nex_pkg" -maxdepth 1 -name "*.apk" | wc -l)
                if [ "$APK_COUNT" -gt 0 ]; then
                    find "$GITHUB_WORKSPACE/nex_pkg" -maxdepth 1 -name "*.apk" -exec cp {} "$OVERLAY_DIR/" \;
                    echo "         ✅ $APK_COUNT overlay APK(s) → /overlay/"
                fi
                
                if [ -f "$GITHUB_WORKSPACE/nex_pkg/bootanimation.zip" ]; then
                    cp "$GITHUB_WORKSPACE/nex_pkg/bootanimation.zip" "$MEDIA_DIR/"
                    echo "         ✅ bootanimation.zip → /media/"
                fi
                
                if [ -f "$GITHUB_WORKSPACE/nex_pkg/lock_wallpaper" ]; then
                    cp "$GITHUB_WORKSPACE/nex_pkg/lock_wallpaper" "$THEME_DIR/"
                    echo "         ✅ lock_wallpaper → /media/theme/default/"
                fi
                
                echo "      ✅ NexPackage assets deployed"
            else
                echo "      ⚠️ NexPackage directory not found, skipping..."
            fi
        fi
        
        # H. PROVISION PATCHER (DIRECT DEX EDITING - NO MANIFEST TOUCH)
        # Provision.apk is located in system_ext/priv-app
        if [ "$part" == "system_ext" ]; then
            PROV_APK=$(find "$DUMP_DIR" -name "Provision.apk" -type f -print -quit)
            if [ ! -z "$PROV_APK" ] && [ -f "$PROV_APK" ]; then
                echo "   🔧 Patching Provision.apk (Direct Dex Method)..."
                echo "      ✅ Found: $PROV_APK"
            
            PROV_WORK="$TEMP_DIR/prov_dex_$$"
            mkdir -p "$PROV_WORK"
            
            # Extract ONLY dex files
            echo "      📦 Extracting dex files (manifest untouched)..."
            DEX_EXTRACTED=$(unzip -j "$PROV_APK" 'classes*.dex' -d "$PROV_WORK/" 2>/dev/null | grep -c "inflating:" || echo "0")
            echo "      📊 Extracted $DEX_EXTRACTED dex file(s)"
            
            # Process each dex
            PATCHED_COUNT=0
            for dex_file in "$PROV_WORK"/classes*.dex; do
                [ ! -f "$dex_file" ] && continue
                
                dex_name=$(basename "$dex_file" .dex)
                smali_out="$PROV_WORK/${dex_name}_smali"
                
                echo "      🔍 Processing $dex_name.dex..."
                
                # Decompile dex to smali
                java -jar "$BIN_DIR/baksmali.jar" d "$dex_file" -o "$smali_out" 2>/dev/null
                
                if [ -d "$smali_out" ]; then
                    # Patch IS_INTERNATIONAL_BUILD checks
                    SMALI_COUNT=$(find "$smali_out" -type f -name "*.smali" -exec grep -l "IS_INTERNATIONAL_BUILD" {} \; | wc -l)
                    
                    if [ "$SMALI_COUNT" -gt 0 ]; then
                        echo "         ✅ Found $SMALI_COUNT file(s) with IS_INTERNATIONAL_BUILD"
                        find "$smali_out" -type f -name "*.smali" -exec grep -l "IS_INTERNATIONAL_BUILD" {} \; | while read smali_file; do
                            sed -i -E 's/sget-boolean ([vp][0-9]+), Lmiui\/os\/Build;->IS_INTERNATIONAL_BUILD:Z/const\/4 \1, 0x1/g' "$smali_file"
                        done
                        PATCHED_COUNT=$((PATCHED_COUNT + 1))
                    else
                        echo "         ⚠️ No IS_INTERNATIONAL_BUILD references found"
                    fi
                    
                    # Recompile smali to dex
                    java -jar "$BIN_DIR/smali.jar" a "$smali_out" -o "${dex_file}.patched" 2>/dev/null
                    
                    if [ -f "${dex_file}.patched" ]; then
                        mv "${dex_file}.patched" "$dex_file"
                        echo "         ✅ Recompiled: $dex_name.dex"
                    fi
                fi
            done
            
            echo "      📦 Injecting patched dex files back into APK..."
            # Inject patched dex back into APK (preserving manifest)
            cd "$PROV_WORK"
            for dex_file in classes*.dex; do
                [ ! -f "$dex_file" ] && continue
                zip -d "$PROV_APK" "$dex_file" 2>/dev/null
                zip -u "$PROV_APK" "$dex_file" 2>/dev/null
            done
            
            # Verify manifest integrity
            MANIFEST_HASH=$(unzip -p "$PROV_APK" AndroidManifest.xml 2>/dev/null | md5sum | cut -d' ' -f1)
            echo "      📋 Manifest Hash: $MANIFEST_HASH (unchanged)"
            echo "      ✅ Provision.apk patched successfully ($PATCHED_COUNT dex file(s) modified)"
            
            cd "$GITHUB_WORKSPACE"
            rm -rf "$PROV_WORK"
            else
                echo "   ⚠️ Provision.apk not found in system_ext, skipping..."
            fi
        fi

        # I. SETTINGS.APK PATCH (DIRECT DEX EDITING - NO MANIFEST TOUCH)
        # Settings.apk is located in system_ext/priv-app
        if [ "$part" == "system_ext" ]; then
            SETTINGS_APK=$(find "$DUMP_DIR" -name "Settings.apk" -type f -print -quit)
            if [ ! -z "$SETTINGS_APK" ] && [ -f "$SETTINGS_APK" ]; then
                echo "   💊 Modding Settings.apk (Direct Dex Method)..."
                echo "      ✅ Found: $SETTINGS_APK"
            
            SETTINGS_WORK="$TEMP_DIR/settings_dex_$$"
            mkdir -p "$SETTINGS_WORK"
            
            # Extract ONLY dex files
            echo "      📦 Extracting dex files (manifest untouched)..."
            DEX_EXTRACTED=$(unzip -j "$SETTINGS_APK" 'classes*.dex' -d "$SETTINGS_WORK/" 2>/dev/null | grep -c "inflating:" || echo "0")
            echo "      📊 Extracted $DEX_EXTRACTED dex file(s)"
            
            # Process each dex
            PATCHED=0
            for dex_file in "$SETTINGS_WORK"/classes*.dex; do
                [ ! -f "$dex_file" ] && continue
                
                dex_name=$(basename "$dex_file" .dex)
                smali_out="$SETTINGS_WORK/${dex_name}_smali"
                
                echo "      🔍 Processing $dex_name.dex..."
                
                # Decompile
                java -jar "$BIN_DIR/baksmali.jar" d "$dex_file" -o "$smali_out" 2>/dev/null
                
                if [ -d "$smali_out" ]; then
                    # Find and patch isAiSupported method
                    TARGET_FILE=$(find "$smali_out" -path "*/com/android/settings/InternalDeviceUtils.smali" -type f)
                    
                    if [ ! -z "$TARGET_FILE" ] && [ -f "$TARGET_FILE" ]; then
                        echo "         ✅ Found InternalDeviceUtils.smali"
                        # Patch the method to always return true
                        python3 <<'PYTHON_PATCHER' "$TARGET_FILE"
import sys
import re

smali_file = sys.argv[1]

with open(smali_file, 'r') as f:
    content = f.read()

# Pattern to find isAiSupported method and replace its body
pattern = r'(\.method .*isAiSupported\(\)Z)(.*?)(\.end method)'

replacement = r'''\1
    .registers 1
    const/4 v0, 0x1
    return v0
\3'''

new_content = re.sub(pattern, replacement, content, flags=re.DOTALL)

if content != new_content:
    with open(smali_file, 'w') as f:
        f.write(new_content)
    print("         ✅ Patched: isAiSupported() → return true")
else:
    print("         ⚠️ Method not found or already patched")
PYTHON_PATCHER
                        PATCHED=1
                    fi
                    
                    # Recompile
                    java -jar "$BIN_DIR/smali.jar" a "$smali_out" -o "${dex_file}.patched" 2>/dev/null
                    
                    if [ -f "${dex_file}.patched" ]; then
                        mv "${dex_file}.patched" "$dex_file"
                        echo "         ✅ Recompiled: $dex_name.dex"
                    fi
                fi
            done
            
            echo "      📦 Injecting patched dex files back into APK..."
            # Inject back
            cd "$SETTINGS_WORK"
            for dex_file in classes*.dex; do
                [ ! -f "$dex_file" ] && continue
                zip -d "$SETTINGS_APK" "$dex_file" 2>/dev/null
                zip -u "$SETTINGS_APK" "$dex_file" 2>/dev/null
            done
            
            if [ "$PATCHED" -eq 1 ]; then
                echo "      ✅ Settings.apk patched successfully (AI Support enabled)"
            else
                echo "      ⚠️ Settings.apk processed but no patches applied"
            fi
            
            cd "$GITHUB_WORKSPACE"
            rm -rf "$SETTINGS_WORK"
            else
                echo "   ⚠️ Settings.apk not found in system_ext, skipping..."
            fi
        fi

        # J. ADD PROPS
        echo "   📝 Injecting build.prop tweaks..."
        find "$DUMP_DIR" -name "build.prop" | while read prop; do 
            echo "$PROPS_CONTENT" >> "$prop"
            echo "      ✅ Modified: $prop"
        done

        # K. REPACK PARTITION
        echo "   📦 Repacking $part partition..."
        sudo mkfs.erofs -zlz4hc,9 "$SUPER_DIR/${part}.img" "$DUMP_DIR" 2>&1 | grep -v "^$"
        
        if [ -f "$SUPER_DIR/${part}.img" ]; then
            echo "      ✅ $part.img created successfully"
            sudo rm -rf "$DUMP_DIR"
        else
            echo "      ❌ Failed to create $part.img"
            exit 1
        fi
    fi
done

# Clean up mount point
sudo rm -rf "mnt"

# =========================================================
#  6. PACKAGING & UPLOAD
# =========================================================
echo ""
echo "========================================"
echo "   FINAL PACKAGING"
echo "========================================"

PACK_DIR="$OUTPUT_DIR/Final_Pack"
mkdir -p "$PACK_DIR/super" "$PACK_DIR/images"

# Move super partitions
echo "📦 Organizing super partitions..."
SUPER_TARGETS="system system_ext product mi_ext vendor odm system_dlkm vendor_dlkm"
for img in $SUPER_TARGETS; do
    if [ -f "$SUPER_DIR/${img}.img" ]; then
        mv "$SUPER_DIR/${img}.img" "$PACK_DIR/super/"
        echo "   ✅ $img.img"
    elif [ -f "$IMAGES_DIR/${img}.img" ]; then
        mv "$IMAGES_DIR/${img}.img" "$PACK_DIR/super/"
        echo "   ✅ $img.img (from images)"
    fi
done

# Move firmware images
echo "📦 Organizing firmware images..."
find "$IMAGES_DIR" -maxdepth 1 -type f -name "*.img" -exec mv {} "$PACK_DIR/images/" \;

# Create flash script
cat <<'EOF' > "$PACK_DIR/flash_rom.bat"
@echo off
echo ========================================
echo      NEXDROID FLASHER v58
echo ========================================
echo.
echo Checking fastboot...
fastboot --version >nul 2>&1
if errorlevel 1 (
    echo ERROR: Fastboot not found! Install Android Platform Tools.
    pause
    exit /b 1
)
echo.
echo WARNING: This will ERASE all data!
echo Press Ctrl+C to cancel, or
pause
echo.
fastboot set_active a
echo [1/3] Flashing Firmware...
for %%f in (images\*.img) do (
    echo    Flashing %%~nf...
    fastboot flash %%~nf "%%f"
)
echo.
echo [2/3] Flashing Super Partitions...
for %%f in (super\*.img) do (
    echo    Flashing %%~nf...
    fastboot flash %%~nf "%%f"
)
echo.
echo [3/3] Wiping Data...
fastboot erase userdata
fastboot erase metadata
echo.
echo ========================================
echo      DONE! Rebooting...
echo ========================================
fastboot reboot
echo.
pause
EOF

# Create Linux flash script
cat <<'EOF' > "$PACK_DIR/flash_rom.sh"
#!/bin/bash
echo "========================================"
echo "      NEXDROID FLASHER v58"
echo "========================================"
echo ""
if ! command -v fastboot &> /dev/null; then
    echo "ERROR: Fastboot not found!"
    exit 1
fi
echo "WARNING: This will ERASE all data!"
read -p "Press Enter to continue or Ctrl+C to cancel..."
echo ""
fastboot set_active a
echo "[1/3] Flashing Firmware..."
for img in images/*.img; do
    name=$(basename "$img" .img)
    echo "   Flashing $name..."
    fastboot flash "$name" "$img"
done
echo ""
echo "[2/3] Flashing Super Partitions..."
for img in super/*.img; do
    name=$(basename "$img" .img)
    echo "   Flashing $name..."
    fastboot flash "$name" "$img"
done
echo ""
echo "[3/3] Wiping Data..."
fastboot erase userdata
fastboot erase metadata
echo ""
echo "========================================"
echo "      DONE! Rebooting..."
echo "========================================"
fastboot reboot
EOF
chmod +x "$PACK_DIR/flash_rom.sh"

# Create ZIP
cd "$PACK_DIR"
SUPER_ZIP="ota-nexdroid-${OS_VER}_${DEVICE_CODE}_${ANDROID_VER}.zip"
echo "📦 Creating final package: $SUPER_ZIP"
7z a -tzip -mx1 -mmt=$(nproc) "$SUPER_ZIP" . >/dev/null 2>&1

if [ -f "$SUPER_ZIP" ]; then
    SIZE=$(du -h "$SUPER_ZIP" | cut -f1)
    echo "   ✅ Package created: $SIZE"
    mv "$SUPER_ZIP" "$OUTPUT_DIR/"
else
    echo "   ❌ Failed to create package"
    exit 1
fi

# =========================================================
#  7. UPLOAD & NOTIFY
# =========================================================
echo ""
echo "☁️  Uploading to PixelDrain..."
cd "$OUTPUT_DIR"

upload() {
    local file=$1
    [ ! -f "$file" ] && return
    
    echo "   ⬆️ Uploading $file..."
    if [ -z "$PIXELDRAIN_KEY" ]; then
        curl -s -T "$file" "https://pixeldrain.com/api/file/" | jq -r '"https://pixeldrain.com/u/" + .id'
    else
        curl -s -T "$file" -u ":$PIXELDRAIN_KEY" "https://pixeldrain.com/api/file/" | jq -r '"https://pixeldrain.com/u/" + .id'
    fi
}

LINK_ZIP=$(upload "$SUPER_ZIP")

if [ -z "$LINK_ZIP" ] || [ "$LINK_ZIP" == "null" ]; then
    echo "   ❌ Upload failed"
    LINK_ZIP="https://pixeldrain.com"
    BTN_TEXT="Upload Failed"
else
    echo "   ✅ Upload successful"
    echo "   🔗 $LINK_ZIP"
    BTN_TEXT="Download ROM"
fi

# Telegram notification
if [ ! -z "$TELEGRAM_TOKEN" ] && [ ! -z "$CHAT_ID" ]; then
    echo ""
    echo "📣 Sending Telegram notification..."
    BUILD_DATE=$(date +"%Y-%m-%d %H:%M UTC")
    
    MSG_TEXT="🤖 **NEXDROID BUILD COMPLETE**
━━━━━━━━━━━━━━━━━━━━━━━━━━━
\`Device  : $DEVICE_CODE\`
\`Version : $OS_VER\`
\`Android : $ANDROID_VER\`
\`Built   : $BUILD_DATE\`
━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    JSON_PAYLOAD=$(jq -n \
        --arg chat_id "$CHAT_ID" \
        --arg text "$MSG_TEXT" \
        --arg url "$LINK_ZIP" \
        --arg btn "$BTN_TEXT" \
        '{
            chat_id: $chat_id,
            parse_mode: "Markdown",
            text: $text,
            reply_markup: {
                inline_keyboard: [[{text: $btn, url: $url}]]
            }
        }')

    HTTP_CODE=$(curl -s -w "%{http_code}" -o /tmp/tg_response.json \
        -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage" \
        -H "Content-Type: application/json" \
        -d "$JSON_PAYLOAD")
    
    if [ "$HTTP_CODE" == "200" ]; then
        echo "   ✅ Telegram notification sent"
    else
        echo "   ⚠️ Telegram API returned: $HTTP_CODE"
        echo "   Attempting text fallback..."
        curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage" \
            -d chat_id="$CHAT_ID" \
            -d text="✅ NexDroid Build Complete: $LINK_ZIP" >/dev/null
    fi
else
    echo "⚠️ Skipping Telegram notification (credentials not provided)"
fi

echo ""
echo "========================================"
echo "   ✅ BUILD COMPLETE!"
echo "========================================"
echo "Package: $SUPER_ZIP"
echo "Link: $LINK_ZIP"
echo ""

exit 0
