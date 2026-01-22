#!/bin/bash
# =========================================================
#  GAPPS INJECTOR (BASH EDITION)
#  Dynamic Path Detection + Debloat + Props
# =========================================================

PARTITION_ROOT="$1"
GAPPS_SRC="gapps"
PERM_SRC="permissions"
NUKE_FILE="nuke.txt"
GDRIVE_ZIP_LINK="https://drive.google.com/file/d/1soDPsc9dhdXbuHLSx4t2L3u7x0fOlx_8/view?usp=drive_link"

# --- CONFIGURATION ---
# App Lists (Space separated)
PRODUCT_APP="GoogleTTS SoundPickerGoogle LatinImeGoogle MiuiBiometric GeminiShell Wizard"
PRODUCT_PRIV="AndroidAutoStub GoogleRestore GooglePartnerSetup Assistant HotwordEnrollmentYGoogleRISCV_WIDEBAND Velvet Phonesky MIUIPackageInstaller"

# Custom Props Content
PROPS_CONTENT='
# === NEXDROID CUSTOM PROPS ===
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
persist.service.pcsync.enable=0
persist.service.lgospd.enable=0
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
ro.control.privapp_permissions=
'

# --- 1. DOWNLOAD GAPPS ---
if [ ! -d "$GAPPS_SRC" ]; then
    echo "      ⬇️ Downloading GApps Bundle..."
    # Check if gdown exists, otherwise try wget (gdown is better for Drive)
    if command -v gdown &> /dev/null; then
        gdown "$GDRIVE_ZIP_LINK" -O gapps_bundle.zip --fuzzy
    else
        echo "      ⚠️ gdown not found, skipping download."
    fi

    if [ -f "gapps_bundle.zip" ]; then
        echo "      📦 Extracting..."
        unzip -q gapps_bundle.zip -d "$GAPPS_SRC" && rm gapps_bundle.zip
    fi
fi

# --- 2. DEBLOAT (NUKE) ---
if [ -f "$NUKE_FILE" ]; then
    echo "      🗑️  Running Debloater..."
    # Read nuke file line by line
    while IFS= read -r app || [[ -n "$app" ]]; do
        # Skip empty lines
        [[ -z "$app" ]] && continue
        
        # Find directory matching app name (Case insensitive-ish via standard find logic)
        # Note: 'find' -name is case sensitive. For insenstive use -iname.
        found=$(find "$PARTITION_ROOT" -type d -iname "$app")
        
        if [ ! -z "$found" ]; then
            rm -rf "$found"
            echo "         🔥 Nuked: $app"
        fi
    done < "$NUKE_FILE"
fi

# --- 3. INJECT APKS ---
# Dynamic Path Detection
APP_DIR=$(find "$PARTITION_ROOT" -type d -name "app" -print -quit)
PRIV_DIR=$(find "$PARTITION_ROOT" -type d -name "priv-app" -print -quit)

echo "      📦 Injecting GApps (App: ${APP_DIR##*/} | Priv: ${PRIV_DIR##*/})"

install_list() {
    local list=$1
    local dest_root=$2
    
    if [ -z "$dest_root" ]; then return; fi
    
    for app_name in $list; do
        apk_file="${app_name}.apk"
        # Find source APK recursively in gapps folder
        src=$(find "$GAPPS_SRC" -name "$apk_file" -print -quit)
        
        if [ -f "$src" ]; then
            # Create destination folder (Same name as APK base)
            dest_folder="$dest_root/$app_name"
            mkdir -p "$dest_folder"
            cp "$src" "$dest_folder/"
            chmod 644 "$dest_folder/$apk_file"
            echo "         + Installed: $app_name"
        else
            echo "         ⚠️  Missing: $apk_file"
        fi
    done
}

install_list "$PRODUCT_APP" "$APP_DIR"
install_list "$PRODUCT_PRIV" "$PRIV_DIR"

# --- 4. INJECT PERMISSIONS ---
# Dynamic ETC detection
ETC_DIR=$(find "$PARTITION_ROOT" -type d -name "etc" -print -quit)

if [ ! -z "$ETC_DIR" ] && [ -d "$PERM_SRC" ]; then
    echo "      🔑 Injecting Permissions..."
    
    # Map Format: "XML_Filename:Destination_Subfolder_Inside_Etc"
    # Using array for portability
    PERM_LIST=(
        "default-permissions-google.xml:default-permissions"
        "split-permissions-google.xml:permissions"
        "privapp-permissions-miui-product.xml:permissions"
        "privapp-permissions-microsoft-product.xml:permissions"
        "privapp-permissions-gms-international-product.xml:permissions"
        "com.google.android.apps.googleassistant.xml:permissions"
        "privapp-permissions-deviceintegrationservice.xml:permissions"
        "cn.google.services.xml:permissions"
        "com.google.android.googlequicksearchbox.xml:permissions"
        "com.android.vending:permissions"
        "google.xml:sysconfig"
        "google_build.xml:sysconfig"
        "google_exclusives_enable.xml:sysconfig"
        "google-hiddenapi-package-allowlist.xml:sysconfig"
        "google-initial-package-stopped-states.xml:sysconfig"
        "google-staged-installer-whitelist.xml:sysconfig"
        "initial-package-stopped-states-aosp.xml:sysconfig"
        "microsoft.xml:sysconfig"
        "preinstalled-packages-platform-handheld-product.xml:sysconfig"
        "preinstalled-packages-platform-overlays.xml:sysconfig"
        "preinstalled-packages-platform-telephony-product.xml:sysconfig"
        "sysconfig_contextual_search.xml:sysconfig"
        "xmscore.config.xml:sysconfig"
        "google_aicore.xml:sysconfig"
        "gemini_shell.xml:sysconfig"
        "cross_device_services.xml:sysconfig"
    )

    for entry in "${PERM_LIST[@]}"; do
        xml="${entry%%:*}"
        subdir="${entry##*:}"
        
        src="$PERM_SRC/$xml"
        if [ -f "$src" ]; then
            dest="$ETC_DIR/$subdir"
            mkdir -p "$dest"
            cp "$src" "$dest/"
        fi
    done
fi

# --- 5. INJECT PROPS ---
echo "      🚀 Injecting Props..."
find "$PARTITION_ROOT" -name "build.prop" | while read prop_file; do
    echo "$PROPS_CONTENT" >> "$prop_file"
    echo "         + Patched: $prop_file"
done
