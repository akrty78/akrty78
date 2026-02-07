#!/bin/bash
# =========================================================
#  NEXDROID DIRECT-DEX PATCHER (MT Manager Logic)
#  Safely mods System Apps without breaking Manifests
# =========================================================

PARTITION_ROOT="$1"
TOOLS_DIR="$(pwd)/bin"
mkdir -p "$TOOLS_DIR"

# --- 1. DOWNLOAD TOOLS (Baksmali/Smali) ---
# We need these to edit Dex directly, bypassing Apktool's manifest rebuilding
if [ ! -f "$TOOLS_DIR/baksmali.jar" ]; then
    echo "⬇️  Fetching Smali/Baksmali..."
    wget -q -O "$TOOLS_DIR/baksmali.jar" "https://bitbucket.org/JesusFreke/smali/downloads/baksmali-2.5.2.jar"
    wget -q -O "$TOOLS_DIR/smali.jar" "https://bitbucket.org/JesusFreke/smali/downloads/smali-2.5.2.jar"
fi

# --- 2. THE CORE FUNCTION (The "MT Manager" Logic) ---
patch_dex_logic() {
    local apk_path="$1"
    local target_smali_file="$2"
    local search_pattern="$3"
    local replacement_text="$4"
    
    echo "      🎯 Targeting: $(basename "$apk_path")"
    
    # Temp workspace
    local tmp_work="${apk_path}_work"
    rm -rf "$tmp_work"
    mkdir -p "$tmp_work/dex_out"
    
    # A. Extract ALL dex files
    unzip -q -j "$apk_path" "*.dex" -d "$tmp_work"
    
    # B. Find which DEX contains our target class
    local target_dex=""
    for dex in "$tmp_work"/*.dex; do
        # Disassemble quickly to check for class
        java -jar "$TOOLS_DIR/baksmali.jar" d "$dex" -o "$tmp_work/disasm_check"
        if [ -f "$tmp_work/disasm_check/$target_smali_file" ]; then
            target_dex="$dex"
            echo "          📍 Found target in $(basename "$dex")"
            break
        fi
        rm -rf "$tmp_work/disasm_check"
    done
    
    if [ -z "$target_dex" ]; then
        echo "          ⚠️ Class not found in any Dex. Skipping."
        rm -rf "$tmp_work"
        return
    fi

    # C. Full Disassemble of the target DEX
    echo "          🛠️  Disassembling..."
    rm -rf "$tmp_work/class_out"
    java -jar "$TOOLS_DIR/baksmali.jar" d "$target_dex" -o "$tmp_work/class_out"
    
    # D. Apply Patch (SED)
    local file_to_patch="$tmp_work/class_out/$target_smali_file"
    if [ -f "$file_to_patch" ]; then
        # Apply modification
        # Note: We use perl for multi-line or robust regex if needed, or simple sed
        # Here we use the generic sed command passed to function
        sed -i -E "$search_pattern" "$file_to_patch"
        
        # Or if replacement is complex, you can write to file directly here
        if [ ! -z "$replacement_text" ]; then
             echo "$replacement_text" > "$file_to_patch"
        fi
        
        echo "          💉 Patch Applied."
    else
        echo "          ❌ Error: Target file vanished."
        rm -rf "$tmp_work"
        return
    fi
    
    # E. Reassemble to DEX
    echo "          🏗️  Recompiling Dex..."
    java -jar "$TOOLS_DIR/smali.jar" a "$tmp_work/class_out" -o "$tmp_work/new_classes.dex"
    
    # F. Inject back into APK (Update Zip)
    if [ -f "$tmp_work/new_classes.dex" ]; then
        # We must put it back with the SAME NAME (e.g., classes2.dex)
        local dex_name=$(basename "$target_dex")
        mv "$tmp_work/new_classes.dex" "$tmp_work/$dex_name"
        
        cd "$tmp_work"
        zip -u -q "$apk_path" "$dex_name"
        cd ..
        
        # G. CRITICAL: Nuke old signature (The "Unsigned" part)
        # System will rely on CorePatch or platform keys match (if you resign)
        # For modified ROMs, deleting META-INF is standard if signature verification is disabled.
        zip -d -q "$apk_path" "META-INF/*" 2>/dev/null
        
        echo "          ✅ Done. (Manifest preserved)"
    else
        echo "          ❌ Smali Compilation Failed."
    fi
    
    rm -rf "$tmp_work"
}


# =========================================================
#  3. DEFINING THE MODS
# =========================================================

# --- MOD: PROVISION (International Bypass) ---
# Target: miui/os/Build.smali (Usually)
do_provision_mod() {
    local apk="$1"
    # We look for the file path relative to smali root
    local smali_file="miui/os/Build.smali"
    
    # Regex to find: sget-boolean ..., IS_INTERNATIONAL_BUILD
    # Replace with: const/4 ..., 0x1
    local pattern='s/sget-boolean ([vp][0-9]+), Lmiui\/os\/Build;->IS_INTERNATIONAL_BUILD:Z/const\/4 \1, 0x1/g'
    
    patch_dex_logic "$apk" "$smali_file" "$pattern" ""
}

# --- MOD: SETTINGS (Example: Disable verification or custom mod) ---
do_settings_mod() {
    local apk="$1"
    # Example: Patching 'MiuiDeviceInfo' to show custom text
    # local smali_file="com/android/settings/MiuiDeviceInfo.smali"
    # local pattern='s/const-string v0, "Xiaomi"/const-string v0, "NexDroid"/g'
    # patch_dex_logic "$apk" "$smali_file" "$pattern" ""
    
    echo "      ℹ️  Settings.apk found. Define your specific patch in 'do_settings_mod' function."
}


# =========================================================
#  4. MAIN EXECUTION LOOP
# =========================================================

if [ -z "$PARTITION_ROOT" ]; then
    echo "❌ Usage: ./patcher.sh <EXTRACTED_PARTITION_FOLDER>"
    exit 1
fi

echo "🔍 Scanning for targets in $PARTITION_ROOT..."

find "$PARTITION_ROOT" -name "*.apk" | while read apk_file; do
    apk_name=$(basename "$apk_file")
    
    case "$apk_name" in
        "Provision.apk")
            do_provision_mod "$apk_file"
            ;;
        "Settings.apk")
            do_settings_mod "$apk_file"
            ;;
        # Add "MiuiSystemUI.apk" etc here
    esac
done
