#!/bin/bash

# =========================================================
#  NEXDROID MODDER - METHOD WIPER (MT MANAGER STYLE)
#  Usage: ./modder.sh <APK> <Class> <Method> <Result>
#  Example: ./modder.sh "Settings.apk" "com/android/settings/Utils" "isAiSupported" "true"
# =========================================================

APK_PATH="$1"
TARGET_CLASS="$2"  # e.g. com/android/settings/InternalDeviceUtils
TARGET_METHOD="$3" # e.g. isAiSupported
RETURN_VAL="$4"    # true | false | null | void

# --- 1. SETUP ---
BIN_DIR="$(pwd)/bin"
TEMP_MOD="temp_modder"
export PATH="$BIN_DIR:$PATH"

if [ ! -f "$APK_PATH" ]; then
    echo "   [Modder] ❌ File not found: $APK_PATH"
    exit 1
fi

echo "   [Modder] 💉 Patching: $TARGET_METHOD -> $RETURN_VAL"

# --- 2. DECOMPILE ---
rm -rf "$TEMP_MOD"
apktool d -r -f "$APK_PATH" -o "$TEMP_MOD" >/dev/null 2>&1

# --- 3. LOCATE SMALI ---
# Convert dot notation to path if needed (com.android -> com/android)
CLASS_PATH=$(echo "$TARGET_CLASS" | sed 's/\./\//g')
SMALI_FILE=$(find "$TEMP_MOD" -type f -path "*/$CLASS_PATH.smali" | head -n 1)

if [ -z "$SMALI_FILE" ]; then
    echo "   [Modder] ⚠️ Class not found: $CLASS_PATH"
    rm -rf "$TEMP_MOD"
    exit 0
fi

# --- 4. PYTHON SURGEON (THE WIPER) ---
cat <<EOF > "$BIN_DIR/wiper.py"
import sys
import re

file_path = sys.argv[1]
method_name = sys.argv[2]
ret_type = sys.argv[3]

# Templates (MT Manager Style - Minimal Registers)
tpl_true = """    .registers 1
    const/4 v0, 0x1
    return v0"""

tpl_false = """    .registers 1
    const/4 v0, 0x0
    return v0"""

tpl_null = """    .registers 1
    const/4 v0, 0x0
    return-object v0"""

tpl_void = """    .registers 0
    return-void"""

# Select Template
payload = tpl_void
if ret_type.lower() == 'true': payload = tpl_true
elif ret_type.lower() == 'false': payload = tpl_false
elif ret_type.lower() == 'null': payload = tpl_null

with open(file_path, 'r') as f:
    content = f.read()

# Regex to find the method block (Start to End)
# Matches: .method [flags] methodName(...)RetType
pattern = r'(\.method.* ' + re.escape(method_name) + r'\(.*)(?s:.*?)(\.end method)'

def replacer(match):
    header = match.group(1)
    footer = match.group(2)
    # WIPE BODY, INSERT PAYLOAD
    return header + "\n" + payload + "\n" + footer

new_content, count = re.subn(pattern, replacer, content)

if count > 0:
    with open(file_path, 'w') as f:
        f.write(new_content)
    print("PATCHED")
else:
    print("MISSING")
EOF

# Execute Patch
RESULT=$(python3 "$BIN_DIR/wiper.py" "$SMALI_FILE" "$TARGET_METHOD" "$RETURN_VAL")

if [ "$RESULT" == "PATCHED" ]; then
    # --- 5. RECOMPILE ---
    apktool b -c "$TEMP_MOD" -o "$APK_PATH" >/dev/null 2>&1
    echo "   [Modder] ✅ Success! Method wiped & forced."
else
    echo "   [Modder] ⚠️ Method '$TARGET_METHOD' not found in class."
fi

# Cleanup
rm -rf "$TEMP_MOD" "$BIN_DIR/wiper.py"
