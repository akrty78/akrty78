#!/bin/bash
# =========================================================
#  NEXDROID SMALI PATCHER
#  (Modular APK Patcher - Unsigned Edition)
# =========================================================

PARTITION_ROOT="$1"

if [ -z "$PARTITION_ROOT" ]; then
    echo "❌ Error: No partition root provided to smali_patcher."
    exit 1
fi

# =========================================================
#  DEFINED PATCHES
# =========================================================

patch_provision() {
    local apk_path="$1"
    echo "      🔧 Patching Provision.apk (International Build Bypass)..."
    
    # 1. Decompile (No Resources)
    apktool d -r -f "$apk_path" -o "prov_temp" > /dev/null 2>&1
    
    # 2. Apply Patch
    if [ -d "prov_temp" ]; then
        grep -r "IS_INTERNATIONAL_BUILD" "prov_temp" | cut -d: -f1 | while read smali_file; do
            # Replace sget-boolean with const/4 (True)
            sed -i -E 's/sget-boolean ([vp][0-9]+), Lmiui\/os\/Build;->IS_INTERNATIONAL_BUILD:Z/const\/4 \1, 0x1/g' "$smali_file"
        done
        
        # 3. Recompile
        apktool b "prov_temp" -o "$apk_path" > /dev/null 2>&1
        echo "         ✅ Patch Applied (Unsigned)."
    else
        echo "         ⚠️ Decompile Failed!"
    fi
    
    rm -rf "prov_temp"
}

# You can add more functions here later!
# patch_settings() { ... }
# patch_systemui() { ... }

# =========================================================
#  MAIN LOOP - SCANNER
# =========================================================

# Find all APKs in this partition
find "$PARTITION_ROOT" -name "*.apk" | while read apk_file; do
    apk_name=$(basename "$apk_file")
    
    case "$apk_name" in
        "Provision.apk")
            patch_provision "$apk_file"
            ;;
        
        # Add new cases here:
        # "Settings.apk")
        #    patch_settings "$apk_file"
        #    ;;
    esac
done
