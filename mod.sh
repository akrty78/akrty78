#!/bin/bash

# =========================================================
#  NEXDROID GOONER - ROOT POWER EDITION v30
#  (Fix: Implements User's 5-Part Patching Guide Exactly)
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

# --- EMBEDDED PYTHON PATCHER (The 5-Part Logic) ---
cat <<'EOF' > "$BIN_DIR/kaorios_patcher.py"
import os
import sys
import re

def patch_file(file_path, target_method_re, code_to_insert, position, search_term=None):
    if not os.path.exists(file_path):
        return False
    
    with open(file_path, 'r') as f:
        content = f.read()
    
    # 1. Find Method (Multi-line regex)
    method_match = re.search(target_method_re, content, re.MULTILINE | re.DOTALL)
    if not method_match:
        print(f"   [FAIL] Method not found in {os.path.basename(file_path)}")
        return False

    method_start = method_match.start()
    end_match = re.search(r'^\.end method', content[method_start:], re.MULTILINE)
    if not end_match:
        print("   [FAIL] Method end not found.")
        return False
    
    method_end = method_start + end_match.end()
    method_body = content[method_start:method_end]
    new_body = method_body
    
    # 2. Apply Patch
    # A. Below .registers
    if position == 'registers':
        reg_match = re.search(r'\.(registers|locals)\s+\d+', method_body)
        if reg_match:
            idx = reg_match.end()
            new_body = method_body[:idx] + "\n" + code_to_insert + method_body[idx:]
        else:
            print("   [FAIL] .registers not found.")
            return False

    # B. Below specific search string (Robust)
    elif position == 'below_search' and search_term:
        # Create regex to match the search term, allowing flexible whitespace
        # Escape special chars, then replace space with \s+
        search_re = re.escape(search_term).replace(r'\ ', r'\s+')
        search_match = re.search(search_re, method_body)
        
        if search_match:
            idx = search_match.end()
            new_body = method_body[:idx] + "\n" + code_to_insert + method_body[idx:]
        else:
            print(f"   [FAIL] String not found: '{search_term}'")
            return False

    # 3. Save
    new_content = content[:method_start] + new_body + content[method_end:]
    with open(file_path, 'w') as f:
        f.write(new_content)
    print(f"   [OK] Patched: {os.path.basename(file_path)}")
    return True

# --- PAYLOADS (Flattened to single-line where possible) ---

# [PART 1]
p1_code = """
    invoke-static {}, Landroid/app/ActivityThread;->currentPackageName()Ljava/lang/String;
    move-result-object v0
    :try_start_kaori_override
    iget-object v1, p0, Landroid/app/ApplicationPackageManager;->mContext:Landroid/app/ContextImpl;
    invoke-static {v1, p1, v0}, Lcom/android/internal/util/kaorios/KaoriFeatureOverrides;->getOverride(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;)Ljava/lang/Boolean;
    move-result-object v0
    :try_end_kaori_override
    .catchall {:try_start_kaori_override .. :try_end_kaori_override} :catchall_kaori_override
    goto :goto_kaori_override
    :catchall_kaori_override
    const/4 v0, 0x0
    :goto_kaori_override
    if-eqz v0, :cond_kaori_override
    invoke-virtual {v0}, Ljava/lang/Boolean;->booleanValue()Z
    move-result p0
    return p0
    :cond_kaori_override
"""

# [PART 2 & 3]
p2_code = "    invoke-static {p1}, Lcom/android/internal/util/kaorios/KaoriPropsUtils;->KaoriProps(Landroid/content/Context;)V"
p3_code = "    invoke-static {p3}, Lcom/android/internal/util/kaorios/KaoriPropsUtils;->KaoriProps(Landroid/content/Context;)V"

# [PART 4]
p4_code = """
    invoke-static {v0}, Lcom/android/internal/util/kaorios/KaoriKeyboxHooks;->KaoriGetKeyEntry(Landroid/system/keystore2/KeyEntryResponse;)Landroid/system/keystore2/KeyEntryResponse;
    move-result-object v0
"""

# [PART 5]
p5_code_1 = "    invoke-static {}, Lcom/android/internal/util/kaorios/KaoriPropsUtils;->KaoriGetCertificateChain()V"
p5_code_2 = """
    invoke-static {v3}, Lcom/android/internal/util/kaorios/KaoriKeyboxHooks;->KaoriGetCertificateChain([Ljava/security/cert/Certificate;)[Ljava/security/cert/Certificate;
    move-result-object v3
"""

root_dir = sys.argv[1]
for r, d, f in os.walk(root_dir):
    
    # 1. ApplicationPackageManager
    if 'ApplicationPackageManager.smali' in f:
        path = os.path.join(r, 'ApplicationPackageManager.smali')
        meth = r'hasSystemFeature\(Ljava/lang/String;I\)Z'
        patch_file(path, meth, p1_code, 'registers')

    # 2. Instrumentation
    if 'Instrumentation.smali' in f:
        path = os.path.join(r, 'Instrumentation.smali')
        
        # Method 1
        meth1 = r'newApplication\(Ljava/lang/Class;Landroid/content/Context;\)Landroid/app/Application;'
        # STRICT Search Term from instructions
        search1 = r'invoke-virtual {v0, p1}, Landroid/app/Application;->attach(Landroid/content/Context;)V'
        patch_file(path, meth1, p2_code, 'below_search', search1)
        
        # Method 2
        meth2 = r'newApplication\(Ljava/lang/ClassLoader;Ljava/lang/String;Landroid/content/Context;\)Landroid/app/Application;'
        # STRICT Search Term
        search2 = r'invoke-virtual {v0, p3}, Landroid/app/Application;->attach(Landroid/content/Context;)V'
        patch_file(path, meth2, p3_code, 'below_search', search2)

    # 3. KeyStore2
    if 'KeyStore2.smali' in f:
        path = os.path.join(r, 'KeyStore2.smali')
        meth = r'getKeyEntry\(Landroid/system/keystore2/KeyDescriptor;\)Landroid/system/keystore2/KeyEntryResponse;'
        # STRICT Search Term
        search = r'check-cast v0, Landroid/system/keystore2/KeyEntryResponse;'
        patch_file(path, meth, p4_code, 'below_search', search)

    # 4. AndroidKeyStoreSpi
    if 'AndroidKeyStoreSpi.smali' in f:
        path = os.path.join(r, 'AndroidKeyStoreSpi.smali')
        meth = r'engineGetCertificateChain\(Ljava/lang/String;\)\[Ljava/security/cert/Certificate;'
        
        # Hook 1: Below registers
        patch_file(path, meth, p5_code_1, 'registers')
        
        # Hook 2: Below specific line
        search = r'aput-object v2, v3, v4'
        patch_file(path, meth, p5_code_2, 'below_search', search)
EOF

# =========================================================
#  2. SETUP & TOOLS
# =========================================================
echo "🛠️  Setting up Environment..."
mkdir -p "$IMAGES_DIR" "$SUPER_DIR" "$TEMP_DIR" "$BIN_DIR" "$KAORIOS_DIR"
export PATH="$BIN_DIR:$PATH"

sudo apt-get update -y
sudo apt-get install -y python3 python3-pip erofs-utils erofsfuse jq aria2 zip unzip liblz4-tool p7zip-full aapt git openjdk-17-jre-headless
pip3 install gdown --break-system-packages

# =========================================================
#  3. DOWNLOAD RESOURCES
# =========================================================
# 1. SETUP APKTOOL 2.12.1 (Strict)
if [ ! -f "$BIN_DIR/apktool.jar" ]; then
    echo "⬇️  Fetching Apktool v2.12.1..."
    APKTOOL_URL="https://github.com/iBotPeaches/Apktool/releases/download/v2.12.1/apktool_2.12.1.jar"
    wget -q -O "$BIN_DIR/apktool.jar" "$APKTOOL_URL"
    
    if [ -f "$BIN_DIR/apktool.jar" ]; then
        echo "   ✅ Installed Apktool v2.12.1"
        echo '#!/bin/bash' > "$BIN_DIR/apktool"
        echo 'java -jar "'"$BIN_DIR"'/apktool.jar" "$@"' >> "$BIN_DIR/apktool"
        chmod +x "$BIN_DIR/apktool"
    else
        echo "   ❌ Failed to download Apktool! Falling back to apt..."
        sudo apt-get install -y apktool
    fi
fi

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

# Kaorios Assets
echo "⬇️  Preparing Kaorios Assets..."
if [ ! -f "$KAORIOS_DIR/classes.dex" ]; then
    echo "   -> Fetching Release Info..."
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
        
        # Absolute Path Logic
        DUMP_DIR="$GITHUB_WORKSPACE/${part}_dump"
        mkdir -p "$DUMP_DIR" "mnt"
        
        sudo erofsfuse "$IMAGES_DIR/${part}.img" "mnt"
        if [ -z "$(sudo ls -A mnt)" ]; then
            echo "      ❌ ERROR: Mount failed!"
            sudo fusermount -uz "mnt"
            continue
        fi
        sudo cp -a "mnt/." "$DUMP_DIR/"
        sudo chown -R $(whoami) "$DUMP_DIR"
        sudo fusermount -uz "mnt"
        rm "$IMAGES_DIR/${part}.img"

        # A. DEBLOATER
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

        # B. GAPPS INJECTION
        if [ "$part" == "product" ] && [ -d "$GITHUB_WORKSPACE/gapps_src" ]; then
            echo "      🔵 Injecting GApps..."
            APP_ROOT="$DUMP_DIR/app"; PRIV_ROOT="$DUMP_DIR/priv-app"
            mkdir -p "$APP_ROOT" "$PRIV_ROOT"
            
            P_APP="SoundPickerGoogle MiuiBiometric LatinImeGoogle GoogleTTS GooglePartnerSetup GeminiShell"
            P_PRIV="Wizard Velvet Phonesky MIUIPackageInstaller GoogleRestore GooglePartnerSetup Assistant AndroidAutoStub"
            install_gapp_logic "$P_PRIV" "$PRIV_ROOT"
            install_gapp_logic "$P_APP" "$APP_ROOT"
        fi

        # C. KAORIOS TOOLBOX
        if [ "$part" == "system" ]; then
            echo "      🌸 Kaorios: Patching Framework..."
            RAW_PATH=$(find "$DUMP_DIR" -name "framework.jar" -type f | head -n 1)
            FW_JAR=$(readlink -f "$RAW_PATH")
            
            if [ ! -z "$FW_JAR" ] && [ -s "$KAORIOS_DIR/classes.dex" ]; then
                echo "         -> Target: $FW_JAR"
                cp "$FW_JAR" "${FW_JAR}.bak"
                
                # Clean & Decompile
                rm -rf "$TEMP_DIR/framework.jar" "$TEMP_DIR/fw_src" "$TEMP_DIR/framework_patched.jar"
                echo "         -> Decompiling..."
                cp "$FW_JAR" "$TEMP_DIR/framework.jar"
                cd "$TEMP_DIR"
                if ! apktool d -r -f "framework.jar" -o "fw_src" >/dev/null 2>&1; then
                    echo "         ❌ ERROR: Decompile Failed!"
                else
                    # Patch
                    echo "         -> Running Patcher..."
                    python3 "$BIN_DIR/kaorios_patcher.py" "fw_src"
                    
                    # Recompile
                    echo "         -> Recompiling..."
                    apktool b -c "fw_src" -o "framework_patched.jar" > build_log.txt 2>&1
                    
                    if [ -f "framework_patched.jar" ]; then
                        # Inject Dex
                        echo "         -> Injecting classes.dex..."
                        DEX_SIZE=$(du -h "$KAORIOS_DIR/classes.dex" | cut -f1)
                        echo "            (Dex Source: $DEX_SIZE)"
                        
                        DEX_COUNT=$(unzip -l "framework_patched.jar" | grep "classes.*\.dex" | wc -l)
                        NEXT_DEX="classes$((DEX_COUNT + 1)).dex"
                        if [ "$DEX_COUNT" -eq 1 ]; then NEXT_DEX="classes2.dex"; fi
                        
                        cp "$KAORIOS_DIR/classes.dex" "$NEXT_DEX"
                        zip -u -q "framework_patched.jar" "$NEXT_DEX"
                        
                        mv "framework_patched.jar" "$FW_JAR"
                        echo "            ✅ Framework Patched & Injected!"
                    else
                        echo "         ❌ ERROR: Recompile Failed!"
                        tail -n 20 build_log.txt
                        cp "${FW_JAR}.bak" "$FW_JAR"
                    fi
                fi
                cd "$GITHUB_WORKSPACE"
            else
                echo "         ! SKIPPED: framework.jar not found or classes.dex missing."
            fi
        fi

        # D. NEXPACKAGE
        if [ "$part" == "product" ]; then
            echo "      📦 Injecting NexPackage Assets..."
            PERM_DIR="$DUMP_DIR/etc/permissions"
            DEF_PERM_DIR="$DUMP_DIR/etc/default-permissions"
            OVERLAY_DIR="$DUMP_DIR/overlay"
            MEDIA_DIR="$DUMP_DIR/media"
            THEME_DIR="$DUMP_DIR/media/theme/default"
            KAORIOS_PRIV="$DUMP_DIR/priv-app/KaoriosToolbox"
            
            mkdir -p "$PERM_DIR" "$DEF_PERM_DIR" "$OVERLAY_DIR" "$MEDIA_DIR" "$THEME_DIR" "$KAORIOS_PRIV"
            
            [ -f "$KAORIOS_DIR/KaoriosToolbox.apk" ] && cp "$KAORIOS_DIR/KaoriosToolbox.apk" "$KAORIOS_PRIV/"
            [ -f "$KAORIOS_DIR/kaorios_perm.xml" ] && cp "$KAORIOS_DIR/kaorios_perm.xml" "$PERM_DIR/"

            if [ -d "$GITHUB_WORKSPACE/nex_pkg" ]; then
                DEF_XML="default-permissions-google.xml"
                if [ -f "$GITHUB_WORKSPACE/nex_pkg/$DEF_XML" ]; then
                     cp "$GITHUB_WORKSPACE/nex_pkg/$DEF_XML" "$DEF_PERM_DIR/"
                     chmod 644 "$DEF_PERM_DIR/$DEF_XML"
                fi
                find "$GITHUB_WORKSPACE/nex_pkg" -maxdepth 1 -name "*.xml" ! -name "$DEF_XML" -exec cp {} "$PERM_DIR/" \;
                cp "$GITHUB_WORKSPACE/nex_pkg/"*.apk "$OVERLAY_DIR/" 2>/dev/null
                [ -f "$GITHUB_WORKSPACE/nex_pkg/bootanimation.zip" ] && cp "$GITHUB_WORKSPACE/nex_pkg/bootanimation.zip" "$MEDIA_DIR/"
                [ -f "$GITHUB_WORKSPACE/nex_pkg/lock_wallpaper" ] && cp "$GITHUB_WORKSPACE/nex_pkg/lock_wallpaper" "$THEME_DIR/"
            fi
        fi
        
        # E. PROVISION PATCHER
        echo "      🔎 Searching for Provision.apk in $DUMP_DIR..."
        PROV_APK=$(find "$DUMP_DIR" -name "Provision.apk" -type f -print -quit)
        if [ ! -z "$PROV_APK" ]; then
            echo "      🔧 Patching Provision.apk found at: $PROV_APK"
            apktool d -r -f "$PROV_APK" -o "prov_temp" > /dev/null 2>&1
            if [ -d "prov_temp" ]; then
                grep -r "IS_INTERNATIONAL_BUILD" "prov_temp" | cut -d: -f1 | while read smali_file; do
                    sed -i -E 's/sget-boolean ([vp][0-9]+), Lmiui\/os\/Build;->IS_INTERNATIONAL_BUILD:Z/const\/4 \1, 0x1/g' "$smali_file"
                done
            fi
            apktool b "prov_temp" -o "$PROV_APK" > /dev/null 2>&1
            rm -rf "prov_temp"
        else
            echo "      ⚠️ Provision.apk NOT FOUND in $part."
        fi

        # F. REPACK
        find "$DUMP_DIR" -name "build.prop" | while read prop; do echo "$PROPS_CONTENT" >> "$prop"; done
        sudo mkfs.erofs -zlz4 "$SUPER_DIR/${part}.img" "$DUMP_DIR"
        sudo rm -rf "$DUMP_DIR"
    fi
done

# =========================================================
#  6. PACKAGING
# =========================================================
echo "📦  Creating Merged Pack..."
PACK_DIR="$OUTPUT_DIR/Final_Pack"
mkdir -p "$PACK_DIR/super" "$PACK_DIR/images"

SUPER_TARGETS="system system_ext product mi_ext vendor odm system_dlkm vendor_dlkm"
for img in $SUPER_TARGETS; do
    if [ -f "$SUPER_DIR/${img}.img" ]; then
        mv "$SUPER_DIR/${img}.img" "$PACK_DIR/super/"
    elif [ -f "$IMAGES_DIR/${img}.img" ]; then
        mv "$IMAGES_DIR/${img}.img" "$PACK_DIR/super/"
    fi
done

find "$IMAGES_DIR" -maxdepth 1 -type f -name "*.img" -exec mv {} "$PACK_DIR/images/" \;

cat <<'EOF' > "$PACK_DIR/flash_rom.bat"
@echo off
echo ========================================
echo      NEXDROID FLASHER
echo ========================================
fastboot set_active a
echo [1/3] Flashing Firmware...
for %%f in (images\*.img) do fastboot flash %%~nf "%%f"
echo [2/3] Flashing Super Partitions...
for %%f in (super\*.img) do fastboot flash %%~nf "%%f"
echo [3/3] Wiping Data...
fastboot erase userdata
fastboot reboot
pause
EOF

cd "$PACK_DIR"
SUPER_ZIP="ota-nexdroid-${OS_VER}_${DEVICE_CODE}_${ANDROID_VER}.zip"
echo "   > Zipping: $SUPER_ZIP"
7z a -tzip -mx1 -mmt=$(nproc) "$SUPER_ZIP" . > /dev/null
mv "$SUPER_ZIP" "$OUTPUT_DIR/"

# =========================================================
#  7. UPLOAD
# =========================================================
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

LINK_ZIP=$(upload "$SUPER_ZIP")

if [ ! -z "$TELEGRAM_TOKEN" ]; then
    MSG="✅ *Build Done!*
📱 *Device:* $DEVICE_CODE
📦 [ROM Zip]($LINK_ZIP)"
    curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage" -d chat_id="$CHAT_ID" -d parse_mode="Markdown" -d text="$MSG" > /dev/null
fi
