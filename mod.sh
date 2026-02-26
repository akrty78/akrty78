#!/bin/bash

# =========================================================
#  NEXDROID MANAGER - OPTIMIZED v57
# =========================================================

set +e 

SCRIPT_START=$(date +%s)

# --- COLOR CODES FOR LOGGING ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# --- LOGGING FUNCTIONS ---
log_info() { echo -e "${CYAN}[INFO]${NC} $(date +"%H:%M:%S") - $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $(date +"%H:%M:%S") - $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $(date +"%H:%M:%S") - $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date +"%H:%M:%S") - $1"; }
log_step() { echo -e "${MAGENTA}[STEP]${NC} $(date +"%H:%M:%S") - $1"; }

# --- TELEGRAM PROGRESS STREAMING ---
TG_MSG_ID=""

tg_progress() {
    # Usage: tg_progress "Status Message"
    [ -z "$TELEGRAM_TOKEN" ] || [ -z "$CHAT_ID" ] && return

    local msg="$1"
    local timestamp=$(date +"%H:%M:%S")
    local full_text="🚀 *NexDroid Build Status*
\`$DEVICE_CODE | $OS_VER\`

$msg
_Last Update: $timestamp_"

    if [ -z "$TG_MSG_ID" ]; then
        # Send initial message
        local resp
        resp=$(curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage" \
            -d chat_id="$CHAT_ID" \
            -d parse_mode="Markdown" \
            -d text="$full_text")
        TG_MSG_ID=$(echo "$resp" | jq -r '.result.message_id')
    else
        # Edit existing message
        curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/editMessageText" \
            -d chat_id="$CHAT_ID" \
            -d message_id="$TG_MSG_ID" \
            -d parse_mode="Markdown" \
            -d text="$full_text" >/dev/null
    fi
}

# --- INPUTS ---
ROM_URL="$1"
MODS_SELECTED="${2:-}"   # comma-separated: launcher,thememanager,securitycenter
BUILD_MODE="${3:-mod}"   # "mod" = current behavior, "hybrid" = full fastboot-flashable package

# --- 1. INSTANT METADATA EXTRACTION ---
FILENAME=$(basename "$ROM_URL" | cut -d'?' -f1)
log_step "🔍 Analyzing OTA Link..."
DEVICE_CODE=$(echo "$FILENAME" | awk -F'-ota_full' '{print $1}')
OS_VER=$(echo "$FILENAME" | awk -F'ota_full-' '{print $2}' | awk -F'-user' '{print $1}')
ANDROID_VER=$(echo "$FILENAME" | awk -F'user-' '{print $2}' | cut -d'-' -f1)
[ -z "$DEVICE_CODE" ] && DEVICE_CODE="UnknownDevice"
[ -z "$OS_VER" ] && OS_VER="UnknownOS"
[ -z "$ANDROID_VER" ] && ANDROID_VER="0.0"
log_info "Target ROM: ota-nexdroid-${OS_VER}_${DEVICE_CODE}_${ANDROID_VER}.zip"
log_info "Device: $DEVICE_CODE | OS: $OS_VER | Android: $ANDROID_VER"

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
'

# --- FUNCTIONS ---
install_gapp_logic() {
    local app_list="$1"
    local target_root="$2"
    local installed_count=0
    local total_count=$(echo "$app_list" | wc -w)
    
    log_info "Installing $total_count GApps to $(basename $target_root)..."
    
    for app in $app_list; do
        local src=$(find "$GITHUB_WORKSPACE/gapps_src" -name "${app}.apk" -print -quit)
        if [ -f "$src" ]; then
            mkdir -p "$target_root/$app"
            cp "$src" "$target_root/$app/${app}.apk"
            chmod 644 "$target_root/$app/${app}.apk"
            installed_count=$((installed_count + 1))
            log_success "✓ Installed: $app"
        else
            log_warning "✗ Not found: $app"
        fi
    done
    
    log_success "GApps installation complete: $installed_count/$total_count installed"
}

# --- CREATE APK-MODDER.SH ---
cat <<'EOF' > "$GITHUB_WORKSPACE/apk-modder.sh"
#!/bin/bash
APK_PATH="$1"
TARGET_CLASS="$2"
TARGET_METHOD="$3"
RETURN_VAL="$4"
BIN_DIR="$(pwd)/bin"
TEMP_MOD="temp_modder"
export PATH="$BIN_DIR:$PATH"

if [ ! -f "$APK_PATH" ]; then exit 1; fi
echo "   [Modder] 💉 Patching $TARGET_METHOD..."

rm -rf "$TEMP_MOD"
apktool d -r -f "$APK_PATH" -o "$TEMP_MOD" >/dev/null 2>&1

CLASS_PATH=$(echo "$TARGET_CLASS" | sed 's/\./\//g')
SMALI_FILE=$(find "$TEMP_MOD" -type f -path "*/$CLASS_PATH.smali" | head -n 1)

if [ -z "$SMALI_FILE" ]; then
    echo "   [Modder] ⚠️ Class not found."
    rm -rf "$TEMP_MOD"; exit 0
fi

cat <<PY > "$BIN_DIR/wiper.py"
import sys, re
file_path = sys.argv[1]; method_name = sys.argv[2]; ret_type = sys.argv[3]

tpl_true = ".registers 1\n    const/4 v0, 0x1\n    return v0"
tpl_false = ".registers 1\n    const/4 v0, 0x0\n    return v0"
tpl_null = ".registers 1\n    const/4 v0, 0x0\n    return-object v0"
tpl_void = ".registers 0\n    return-void"

payload = tpl_void
if ret_type.lower() == 'true': payload = tpl_true
elif ret_type.lower() == 'false': payload = tpl_false
elif ret_type.lower() == 'null': payload = tpl_null

with open(file_path, 'r') as f: content = f.read()
pattern = r'(\.method.* ' + re.escape(method_name) + r'\(.*)(?s:.*?)(\.end method)'
new_content, count = re.subn(pattern, lambda m: m.group(1) + "\n" + payload + "\n" + m.group(2), content)

if count > 0:
    with open(file_path, 'w') as f: f.write(new_content)
    print("PATCHED")
PY

RESULT=$(python3 "$BIN_DIR/wiper.py" "$SMALI_FILE" "$TARGET_METHOD" "$RETURN_VAL")

if [ "$RESULT" == "PATCHED" ]; then
    apktool b -c "$TEMP_MOD" -o "$APK_PATH" >/dev/null 2>&1
    echo "   [Modder] ✅ Done."
fi
rm -rf "$TEMP_MOD" "$BIN_DIR/wiper.py"
EOF
chmod +x "$GITHUB_WORKSPACE/apk-modder.sh"

# =========================================================
#  2. SETUP & TOOLS
# =========================================================
log_step "🛠️  Setting up Environment..."
mkdir -p "$IMAGES_DIR" "$SUPER_DIR" "$TEMP_DIR" "$BIN_DIR"
export PATH="$BIN_DIR:$PATH"

log_info "Installing system dependencies..."
sudo apt-get update -qq
sudo apt-get install -y -qq python3 python3-pip erofs-utils erofsfuse jq aria2 zip unzip liblz4-tool p7zip-full aapt git openjdk-17-jre-headless > /dev/null 2>&1
pip3 install gdown --break-system-packages -q
log_success "System dependencies installed"

if [ -f "apk-modder.sh" ]; then
    chmod +x apk-modder.sh
fi

# =========================================================
#  3. DOWNLOAD RESOURCES
# =========================================================
log_step "📥 Downloading Required Resources..."

# 1. SETUP APKTOOL 2.12.1
if [ ! -f "$BIN_DIR/apktool.jar" ]; then
    log_info "Fetching Apktool v2.12.1..."
    APKTOOL_URL="https://github.com/iBotPeaches/Apktool/releases/download/v2.12.1/apktool_2.12.1.jar"
    wget -q -O "$BIN_DIR/apktool.jar" "$APKTOOL_URL"
    
    if [ -f "$BIN_DIR/apktool.jar" ]; then
        log_success "Installed Apktool v2.12.1"
        echo '#!/bin/bash' > "$BIN_DIR/apktool"
        echo 'java -Xmx8G -jar "'"$BIN_DIR"'/apktool.jar" "$@"' >> "$BIN_DIR/apktool"
        chmod +x "$BIN_DIR/apktool"
    else
        log_error "Failed to download Apktool! Falling back to apt..."
        sudo apt-get install -y apktool
    fi
else
    log_info "Apktool already installed"
fi

# Payload Dumper
if [ ! -f "$BIN_DIR/payload-dumper-go" ]; then
    log_info "Downloading payload-dumper-go..."
    wget -q -O pd.tar.gz https://github.com/ssut/payload-dumper-go/releases/download/1.2.2/payload-dumper-go_1.2.2_linux_amd64.tar.gz
    tar -xzf pd.tar.gz
    find . -type f -name "payload-dumper-go" -not -path "*/bin/*" -exec mv {} "$BIN_DIR/" \;
    chmod +x "$BIN_DIR/payload-dumper-go"
    rm pd.tar.gz
    log_success "payload-dumper-go installed"
else
    log_info "payload-dumper-go already installed"
fi

# Android SDK Tools (for dexdump)
log_info "Installing Android SDK build tools..."

# Create SDK directory
mkdir -p "$BIN_DIR/android-sdk"
cd "$BIN_DIR/android-sdk"

# Download minimal Android SDK command-line tools
SDK_TOOLS_URL="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
if wget -q "$SDK_TOOLS_URL" -O cmdline-tools.zip; then
    unzip -q cmdline-tools.zip
    rm cmdline-tools.zip
    
    # Install build-tools (contains dexdump)
    yes | ./cmdline-tools/bin/sdkmanager --sdk_root="$BIN_DIR/android-sdk" "build-tools;34.0.0" 2>&1 | grep -v "=" || true
    
    # Add to PATH
    export PATH="$BIN_DIR/android-sdk/build-tools/34.0.0:$PATH"
    
    # Verify dexdump is available
    if command -v dexdump &>/dev/null; then
        log_success "✓ dexdump installed and available"
    else
        log_warning "dexdump installation may have failed"
    fi
else
    log_warning "Could not download Android SDK tools"
    log_warning "Class count verification will not be available"
fi

cd "$GITHUB_WORKSPACE"
# ═════════════════════════════════════════════════════════════════
#  DEX PATCHING SETUP
#  Tools: baksmali (decompile) + smali (recompile)
#  Engine: dex_patcher.py  (written inline below)
#
#  Download sources tried in order:
#    1. Google Drive  (set BAKSMALI_GDRIVE / SMALI_GDRIVE below)
#    2. Maven Central (reliable in GH Actions, no rate-limit)
#    3. GitHub releases (last resort)
# ═════════════════════════════════════════════════════════════════
log_info "Setting up DEX patching tools..."

BAKSMALI_GDRIVE="1RS_lmqeVoMO4-mnCQ-BOV5A9qoa_8VHu"
SMALI_GDRIVE="1KTMCWGOcLs-yeuLwHSoc53J0kpXTZht_"

_fetch_jar() {
    # _fetch_jar <filename> <gdrive_id> <maven_url> <github_url>
    local name="$1" gdrive="$2" maven="$3" github="$4"
    local dest="$BIN_DIR/$name"
    local sz; sz=$(stat -c%s "$dest" 2>/dev/null || echo 0)
    [ "$sz" -gt 500000 ] && { log_success "✓ $name cached (${sz}B)"; return 0; }
    rm -f "$dest"

    # 1. Google Drive
    if [ "$gdrive" != "YOUR_SMALI_GDRIVE_ID" ] && command -v gdown &>/dev/null; then
        log_info "  $name ← Google Drive..."
        gdown "$gdrive" -O "$dest" --fuzzy -q 2>/dev/null || true
    fi

    # 2. Maven Central (works in GH Actions, no rate-limit)
    sz=$(stat -c%s "$dest" 2>/dev/null || echo 0)
    if [ "$sz" -lt 500000 ]; then
        log_info "  $name ← Maven Central..."
        curl -fsSL --retry 3 --connect-timeout 30 -o "$dest" "$maven" 2>/dev/null || true
    fi

    # 3. GitHub releases
    sz=$(stat -c%s "$dest" 2>/dev/null || echo 0)
    if [ "$sz" -lt 500000 ]; then
        log_info "  $name ← GitHub releases..."
        curl -fsSL --retry 2 --connect-timeout 30 -o "$dest" "$github" 2>/dev/null || true
    fi

    sz=$(stat -c%s "$dest" 2>/dev/null || echo 0)
    if [ "$sz" -gt 500000 ]; then
        log_success "✓ $name ready (${sz}B)"; return 0
    else
        log_error "✗ $name unavailable after all sources (${sz}B)"; return 1
    fi
}

_fetch_jar "baksmali.jar" \
    "$BAKSMALI_GDRIVE" \
    "https://repo1.maven.org/maven2/com/android/tools/smali/smali-baksmali/3.0.3/smali-baksmali-3.0.3.jar" \
    "https://github.com/google/smali/releases/download/v2.5.2/baksmali-2.5.2.jar"

_fetch_jar "smali.jar" \
    "$SMALI_GDRIVE" \
    "https://repo1.maven.org/maven2/com/android/tools/smali/smali-cli/3.0.3/smali-cli-3.0.3.jar" \
    "https://github.com/google/smali/releases/download/v2.5.2/smali-2.5.2.jar"

# ─────────────────────────────────────────────────────────────────
#  Write dex_patcher.py inline (same pattern as vbmeta_patcher.py)
#  This is the single Python engine for ALL DEX patching operations.
# ─────────────────────────────────────────────────────────────────
cat > "$BIN_DIR/dex_patcher.py" <<'PYTHON_EOF'
#!/usr/bin/env python3
"""
dex_patcher.py  ─  NexDroid HyperOS DEX patching engine  (v7 / NexBinaryPatch)
═══════════════════════════════════════════════════════════════════════════════
TECHNIQUE: NexBinaryPatch  — binary in-place DEX patch, zero baksmali/smali.
  • Parses DEX header → string/type/field/class tables.
  • Iterates only real code_item instruction arrays (avoids false positives from
    index tables that happen to contain sget-boolean opcode 0x60).
  • Patches code_item header + instruction bytes in-place.
  • NOP-pads remainder to preserve DEX layout byte-identically.
  • Recalculates Adler-32 checksum and SHA-1 signature.

  WHY NOT baksmali/smali:
    Recompiling 8000+ smali files produces a structurally different DEX
    (different string pool ordering, type list layout, method ID table).
    ART dexopt rejects it. Stock DEX ✓, recompiled DEX ✗ — confirmed by user.

Commands:
  verify              check zipalign + java
  settings-ai         InternalDeviceUtils  → isAiSupported = true
  voice-recorder-ai   SoundRecorder        → isAiRecordEnable = true
  services-jar        ActivityManagerService$$ExternalSyntheticLambda31 → run() = void
  provision-gms       Provision.apk        → IS_INTERNATIONAL_BUILD (Lmiui/os/Build;) = 1
  miui-service        miui-services.jar    → IS_INTERNATIONAL_BUILD (Lmiui/os/Build;) = 1
  systemui-volte      MiuiSystemUI.apk     → IS_INTERNATIONAL_BUILD + QuickShare + WA-notif
  miui-framework      miui-framework.jar   → validateTheme = void  +  IS_GLOBAL_BUILD = 1
  settings-region     Settings.apk         → IS_GLOBAL_BUILD = 1 (locale classes)
"""

import sys, os, re, struct, hashlib, zlib, shutil, zipfile, subprocess, tempfile, traceback
from pathlib import Path
from typing import Optional

_BIN = Path(os.environ.get("BIN_DIR", Path(__file__).parent))

def _p(tag, msg): print(f"[{tag}] {msg}", flush=True)
def info(m):  _p("INFO",    m)
def ok(m):    _p("SUCCESS", m)
def warn(m):  _p("WARNING", m)
def err(m):   _p("ERROR",   m)

# ── Instruction stubs ─────────────────────────────────────────────
# const/4 v0, 0x1 ; return v0   (format 11n + 11x = 2 code-units = 4 bytes)
_STUB_TRUE = bytes([0x12, 0x10, 0x0F, 0x00])
# return-void                    (format 10x = 1 code-unit = 2 bytes)
_STUB_VOID = bytes([0x0E, 0x00])


# ════════════════════════════════════════════════════════════════════
#  ZIPALIGN
# ════════════════════════════════════════════════════════════════════

def _find_zipalign():
    found = shutil.which("zipalign")
    if found: return found
    for p in sorted((_BIN / "android-sdk").glob("build-tools/*/zipalign"), reverse=True):
        if p.exists(): return str(p)
    return None

def _zipalign(archive: Path) -> bool:
    za = _find_zipalign()
    if not za: warn("  zipalign not found — alignment skipped"); return False
    tmp = archive.with_name(f"_za_{archive.name}")
    try:
        r = subprocess.run([za, "-p", "-f", "4", str(archive), str(tmp)],
                           capture_output=True, text=True, timeout=120)
        if r.returncode != 0 or not tmp.exists() or tmp.stat().st_size < 1000:
            err(f"  zipalign failed: {r.stderr[:200]}")
            tmp.unlink(missing_ok=True); return False
        shutil.move(str(tmp), str(archive))
        ok("  ✓ zipalign applied (resources.arsc 4-byte aligned)"); return True
    except Exception as exc:
        err(f"  zipalign crash: {exc}"); tmp.unlink(missing_ok=True); return False

def cmd_verify():
    za = _find_zipalign()
    ok(f"zipalign at {za}") if za else warn("zipalign not found — APK alignment will be skipped")
    r = subprocess.run(["java", "-version"], capture_output=True, text=True)
    ok("java OK") if r.returncode == 0 else err("java not found")
    sys.exit(0)


# ════════════════════════════════════════════════════════════════════
#  DEX HEADER PARSER
# ════════════════════════════════════════════════════════════════════

def _parse_header(data: bytes) -> Optional[dict]:
    if data[:4] not in (b'dex\n', b'dey\n'): return None
    si, so, ti, to, pi, po, fi, fo, mi, mo, ci, co = struct.unpack_from('<IIIIIIIIIIII', data, 0x38)
    return dict(string_ids_size=si, string_ids_off=so,
                type_ids_size=ti,   type_ids_off=to,
                field_ids_size=fi,  field_ids_off=fo,
                method_ids_size=mi, method_ids_off=mo,
                class_defs_size=ci, class_defs_off=co)

def _uleb128(data: bytes, off: int):
    result = shift = 0
    while True:
        b = data[off]; off += 1
        result |= (b & 0x7F) << shift
        if not (b & 0x80): break
        shift += 7
    return result, off

def _skip_uleb128(data: bytes, off: int) -> int:
    """Advance past one ULEB128 value without decoding it. Never throws."""
    while off < len(data) and (data[off] & 0x80):
        off += 1
    return off + 1  # skip the final byte (high bit clear)

def _get_str(data: bytes, hdr: dict, idx: int) -> str:
    off = struct.unpack_from('<I', data, hdr['string_ids_off'] + idx * 4)[0]
    _, co = _uleb128(data, off)
    end = data.index(0, co)
    return data[co:end].decode('utf-8', errors='replace')

def _get_type_str(data: bytes, hdr: dict, tidx: int) -> str:
    sidx = struct.unpack_from('<I', data, hdr['type_ids_off'] + tidx * 4)[0]
    return _get_str(data, hdr, sidx)


# ════════════════════════════════════════════════════════════════════
#  CODE-ITEM ITERATOR  (THE FIX for sget-boolean false-positives)
#
#  Previous approach scanned raw DEX bytes from offset 0x70 linearly.
#  When a 0x60 byte appears in string/type/field index tables and the
#  next two bytes happen to match a target field index, the scanner
#  advances 4 bytes instead of 2 — misaligning all subsequent scans
#  and missing real sget-boolean instructions in code sections.
#
#  Correct approach: iterate only over verified code_item instruction
#  arrays by walking class_defs → class_data_item → encoded_method.
#  Each insns array IS a valid aligned instruction stream.
# ════════════════════════════════════════════════════════════════════

def _iter_code_items(data: bytes, hdr: dict):
    """
    Yield (insns_off, insns_len_bytes, type_str, method_name) for every
    non-abstract method in the DEX.
    """
    for i in range(hdr['class_defs_size']):
        base           = hdr['class_defs_off'] + i * 32
        cls_idx        = struct.unpack_from('<I', data, base + 0)[0]
        class_data_off = struct.unpack_from('<I', data, base + 24)[0]
        if class_data_off == 0: continue
        try:
            sidx     = struct.unpack_from('<I', data, hdr['type_ids_off'] + cls_idx * 4)[0]
            type_str = _get_str(data, hdr, sidx)
        except Exception: continue

        pos = class_data_off
        try:
            sf,  pos = _uleb128(data, pos); inf, pos = _uleb128(data, pos)
            dm,  pos = _uleb128(data, pos); vm,  pos = _uleb128(data, pos)
        except Exception: continue

        # skip fields: _uleb128 + break is intentional.
        # _skip_uleb128 mis-advances pos for classes like OtherPersonalSettings
        # whose class_data has variable-width ULEB128 field entries.
        # The original _uleb128+break was verified to work for all Settings classes.
        # Kotlin inner/coroutine classes in SystemUI are handled by _raw_sget_scan.
        for _ in range(sf + inf):
            try:
                _, pos = _uleb128(data, pos)   # field_idx_diff
                _, pos = _uleb128(data, pos)   # access_flags
            except Exception:
                break

        midx = 0
        for _ in range(dm + vm):
            try:
                d, pos   = _uleb128(data, pos); midx += d
                _,  pos  = _uleb128(data, pos)          # access_flags
                code_off, pos = _uleb128(data, pos)
            except Exception: break
            if code_off == 0: continue
            try:
                mid_base  = hdr['method_ids_off'] + midx * 8
                name_sidx = struct.unpack_from('<I', data, mid_base + 4)[0]
                mname     = _get_str(data, hdr, name_sidx)
                insns_size = struct.unpack_from('<I', data, code_off + 12)[0]
                yield code_off + 16, insns_size * 2, type_str, mname
            except Exception:
                continue


# ════════════════════════════════════════════════════════════════════
#  FIELD LOOKUP
# ════════════════════════════════════════════════════════════════════

def _find_field_ids(data: bytes, hdr: dict, field_class: str, field_name: str) -> set:
    """Return set of field_id indices matching class descriptor + name."""
    result = set()
    for fi in range(hdr['field_ids_size']):
        fbase   = hdr['field_ids_off'] + fi * 8
        try:
            cls_idx = struct.unpack_from('<H', data, fbase + 0)[0]
            nam_idx = struct.unpack_from('<I', data, fbase + 4)[0]
            if (_get_type_str(data, hdr, cls_idx) == field_class and
                    _get_str(data, hdr, nam_idx)    == field_name):
                result.add(fi)
        except Exception:
            continue
    return result


def _find_method_ids_by_name(data: bytes, hdr: dict, method_name: str) -> set:
    """Return set of method_id indices whose name matches method_name."""
    result = set()
    for mi in range(hdr['method_ids_size']):
        base = hdr['method_ids_off'] + mi * 8
        try:
            name_sidx = struct.unpack_from('<I', data, base + 4)[0]
            if _get_str(data, hdr, name_sidx) == method_name:
                result.add(mi)
        except Exception:
            continue
    return result


# ════════════════════════════════════════════════════════════════════
#  RAW BYTE SCANNER  (second-pass fallback)
#
#  _iter_code_items can miss code_items when class_data ULEB128 parsing
#  goes wrong for Kotlin inner/coroutine classes (e.g., $bind$1$1$10).
#  Those classes have many synthetic captured fields; if even one ULEB128
#  read is mis-stepped, pos ends up wrong and method code_offs are garbage,
#  silently skipping the whole class.
#
#  This scanner bypasses class_data entirely: it scans raw DEX bytes in
#  2-byte steps (code-unit aligned) starting after all static tables,
#  looking for [SGET_OPCODE] [reg] [field_lo] [field_hi].
#  Already-patched slots are 0x12/0x13 — not in SGET_OPCODES — so it
#  never double-patches and is safe to call after the normal sweep.
# ════════════════════════════════════════════════════════════════════

def _raw_sget_scan(dex: bytearray, field_class: str, field_name: str,
                   use_const4: bool = False) -> int:
    """
    Raw second-pass: scan DEX bytes 2 bytes at a time from the data section
    start for sget-* instructions referencing field_class->field_name.
    Returns count of additional replacements (those missed by _iter_code_items).
    """
    data = bytes(dex)
    hdr  = _parse_header(data)
    if not hdr: return 0

    fids = _find_field_ids(data, hdr, field_class, field_name)
    if not fids: return 0

    SGET_OPCODES = frozenset([0x60, 0x63, 0x64, 0x65, 0x66])

    # Scan start: right after class_defs table (last static table before data)
    scan_start = hdr['class_defs_off'] + hdr['class_defs_size'] * 32
    # Round up to 4-byte boundary (code_items are 4-byte aligned)
    if scan_start & 3:
        scan_start = (scan_start | 3) + 1

    raw   = bytearray(dex)
    count = 0
    limit = len(raw) - 3
    i     = scan_start

    while i < limit:
        op = raw[i]
        if op in SGET_OPCODES:
            field_lo = struct.unpack_from('<H', raw, i + 2)[0]
            if field_lo in fids:
                reg = raw[i + 1]
                if use_const4 and reg <= 15:
                    raw[i]     = 0x12
                    raw[i + 1] = (0x1 << 4) | reg
                    raw[i + 2] = 0x00
                    raw[i + 3] = 0x00
                else:
                    # const/16 vAA, 0x1  (opcode 0x13, format 21s)
                    raw[i]     = 0x13
                    raw[i + 1] = reg
                    raw[i + 2] = 0x01
                    raw[i + 3] = 0x00
                count += 1
                i += 4
                continue
        i += 2   # step by one code unit (2 bytes), instruction-aligned

    if count:
        mode = "const/4" if use_const4 else "const/16"
        ok(f"  ✓ [raw-scan] {field_name}: {count} missed sget → {mode} 1")
        _fix_checksums(raw)
        dex[:] = raw
    return count


# ════════════════════════════════════════════════════════════════════
#  CHECKSUM REPAIR
# ════════════════════════════════════════════════════════════════════

def _fix_checksums(dex: bytearray):
    sha1  = hashlib.sha1(bytes(dex[32:])).digest()
    dex[12:32] = sha1
    adler = zlib.adler32(bytes(dex[12:])) & 0xFFFFFFFF
    struct.pack_into('<I', dex, 8, adler)

def _clear_method_annotations(dex: bytearray, class_desc: str, method_name: str) -> bool:
    """
    Zero the annotations_off entry for a specific method inside the DEX
    annotations_directory_item. This stops baksmali from emitting Signature
    (or any other) annotation blocks for that method.

    class_def_item layout (32 bytes):
      +0  class_idx
      +4  access_flags
      +8  superclass_idx
      +12 interfaces_off
      +16 source_file_idx
      +20 annotations_off   ← annotations_directory_item
      +24 class_data_off
      +28 static_values_off
    """
    data = bytes(dex)
    hdr  = _parse_header(data)
    if not hdr: return False

    target_type = f'L{class_desc};'

    # 1. Find class_def row for target class
    class_def_base = None
    for i in range(hdr['class_defs_size']):
        base    = hdr['class_defs_off'] + i * 32
        cls_idx = struct.unpack_from('<I', data, base)[0]
        try:
            sidx = struct.unpack_from('<I', data, hdr['type_ids_off'] + cls_idx * 4)[0]
            if _get_str(data, hdr, sidx) == target_type:
                class_def_base = base
                break
        except Exception:
            continue

    if class_def_base is None: return False

    annotations_off  = struct.unpack_from('<I', data, class_def_base + 20)[0]
    class_data_off   = struct.unpack_from('<I', data, class_def_base + 24)[0]
    if annotations_off == 0 or class_data_off == 0: return False

    # 2. Walk class_data_item to find the absolute method_idx for method_name
    target_midx = None
    pos = class_data_off
    sf, pos  = _uleb128(data, pos)
    inf, pos = _uleb128(data, pos)
    dm, pos  = _uleb128(data, pos)
    vm, pos  = _uleb128(data, pos)
    for _ in range(sf + inf):
        _, pos = _uleb128(data, pos); _, pos = _uleb128(data, pos)
    midx = 0
    for _ in range(dm + vm):
        d,   pos = _uleb128(data, pos); midx += d
        _,   pos = _uleb128(data, pos)   # access_flags
        _,   pos = _uleb128(data, pos)   # code_off
        try:
            mid_base  = hdr['method_ids_off'] + midx * 8
            name_sidx = struct.unpack_from('<I', data, mid_base + 4)[0]
            if _get_str(data, hdr, name_sidx) == method_name:
                target_midx = midx
                break
        except Exception:
            continue

    if target_midx is None: return False

    # 3. Parse annotations_directory_item to locate this method's entry
    #    Header: class_annotations_off(4), fields_size(4),
    #            annotated_methods_size(4), annotated_parameters_size(4)
    pos = annotations_off
    pos += 4                                                    # skip class_annotations_off
    fields_sz   = struct.unpack_from('<I', data, pos)[0]; pos += 4
    methods_sz  = struct.unpack_from('<I', data, pos)[0]; pos += 4
    pos += 4                                                    # skip annotated_parameters_size
    pos += fields_sz * 8                                        # skip field_annotation entries

    # method_annotation entries: { uint method_idx, uint annotations_off }
    for j in range(methods_sz):
        entry = pos + j * 8
        m_idx = struct.unpack_from('<I', data, entry)[0]
        if m_idx == target_midx:
            struct.pack_into('<I', dex, entry + 4, 0)   # zero the annotations_off
            _fix_checksums(dex)
            ok(f"  Cleared Signature annotation for {method_name}")
            return True

    return False


# ════════════════════════════════════════════════════════════════════
#  BINARY PATCH: single method → stub
# ════════════════════════════════════════════════════════════════════

def binary_patch_method(dex: bytearray, class_desc: str, method_name: str,
                        stub_regs: int, stub_insns: bytes,
                        trim: bool = False) -> bool:
    """
    In-place patch: find method by exact class + name, replace code_item with stub.

    trim=False (default): NOP-pads remainder → keeps insns_size, layout unchanged.
    trim=True: shrinks insns_size in the header to stub length.
      → Clean baksmali output (no nop flood, no spurious annotations).
      → Use for validateTheme and any method where baksmali output matters.
    """
    data = bytes(dex)
    hdr  = _parse_header(data)
    if not hdr: err("  Not a DEX"); return False

    target_type = f'L{class_desc};'
    info(f"  Searching {target_type} → {method_name}")

    # Find class_data_off
    class_data_off = None
    for i in range(hdr['class_defs_size']):
        base    = hdr['class_defs_off'] + i * 32
        cls_idx = struct.unpack_from('<I', data, base)[0]
        try:
            sidx = struct.unpack_from('<I', data, hdr['type_ids_off'] + cls_idx * 4)[0]
            if _get_str(data, hdr, sidx) == target_type:
                class_data_off = struct.unpack_from('<I', data, base + 24)[0]
                break
        except Exception:
            continue

    if class_data_off is None:
        warn(f"  Class {target_type} not in this DEX"); return False
    if class_data_off == 0:
        warn(f"  Class {target_type} has no class_data"); return False

    # Walk methods to find code_item
    pos = class_data_off
    sf, pos = _uleb128(data, pos);  inf, pos = _uleb128(data, pos)
    dm, pos = _uleb128(data, pos);  vm,  pos = _uleb128(data, pos)
    for _ in range(sf + inf):
        _, pos = _uleb128(data, pos); _, pos = _uleb128(data, pos)

    code_off = None
    midx = 0
    for _ in range(dm + vm):
        d, pos = _uleb128(data, pos); midx += d
        _, pos = _uleb128(data, pos)
        c_off, pos = _uleb128(data, pos)
        if c_off == 0: continue
        try:
            mid_base  = hdr['method_ids_off'] + midx * 8
            name_sidx = struct.unpack_from('<I', data, mid_base + 4)[0]
            if _get_str(data, hdr, name_sidx) == method_name:
                code_off = c_off; break
        except Exception:
            continue

    if code_off is None:
        warn(f"  Method {method_name} not found"); return False

    orig_regs  = struct.unpack_from('<H', data, code_off + 0)[0]
    orig_ins   = struct.unpack_from('<H', data, code_off + 2)[0]
    insns_size = struct.unpack_from('<I', data, code_off + 12)[0]
    insns_off  = code_off + 16
    stub_units = len(stub_insns) // 2

    ok(f"  code_item @ 0x{code_off:X}: insns={insns_size} cu ({insns_size*2}B)")

    if stub_units > insns_size:
        err(f"  Stub {stub_units} cu > original {insns_size} cu — cannot patch in-place")
        return False

    # registers_size = stub_regs + orig_ins
    #   Dalvik frame layout: locals occupy BOTTOM (v0..v(stub_regs-1)),
    #   parameter registers occupy TOP (v(stub_regs)..v(stub_regs+orig_ins-1)).
    #   Using max() instead of addition is WRONG when orig_ins > 0:
    #     max(1,1)=1 → registers_size=1, ins_size=1 → v0 IS p0 (no local slots).
    #     With const/4 v0, 0x1 / return v0, that writes the param reg, not a local.
    #   Correct: stub_regs + orig_ins = 1+1 = 2 → v0=local, v1=p0. Clean separation.
    new_regs = stub_regs + orig_ins

    # ── Patch code_item header ────────────────────────────────────────
    struct.pack_into('<H', dex, code_off + 0, new_regs)   # registers_size
    struct.pack_into('<H', dex, code_off + 4, 0)           # outs_size = 0
    struct.pack_into('<H', dex, code_off + 6, 0)           # tries_size = 0
    struct.pack_into('<I', dex, code_off + 8, 0)           # debug_info_off = 0
    if trim:
        # Shrink insns_size → stub length. No NOP padding written.
        # Safe: ART locates code_items by offset (class_data_item), not by sequential scan.
        struct.pack_into('<I', dex, code_off + 12, stub_units)

    # ── Write stub + optional NOP padding ────────────────────────────
    for i, b in enumerate(stub_insns):
        dex[insns_off + i] = b
    if not trim:
        for i in range(len(stub_insns), insns_size * 2):
            dex[insns_off + i] = 0x00   # NOP pad

    _fix_checksums(dex)
    nops = 0 if trim else (insns_size - stub_units)
    mode = "trimmed" if trim else f"{nops} nop pad"
    ok(f"  ✓ {method_name} → stub ({stub_units} cu, {mode}, regs {orig_regs}→{new_regs})")
    return True


# ════════════════════════════════════════════════════════════════════
#  BINARY PATCH: sget-boolean field → const/4 1 (or const/16 with opcode 0x13)
#  Scans ONLY within verified code_item instruction arrays.
# ════════════════════════════════════════════════════════════════════

def binary_patch_sget_to_true(dex: bytearray,
                               field_class: str, field_name: str,
                               only_class:  str = None,
                               only_method: str = None,
                               use_const4:  bool = False) -> int:
    """
    Within every code_item instruction array (never raw DEX tables), find:
      sget-boolean vAA, <field_class>-><field_name>:Z   opcode 0x63, 4 bytes
    Replace with const/4 or const/16 (both 4 bytes total in the stream):

      use_const4=False (default):
        const/16 vAA, 0x1   →  13 AA 01 00   (format 21s, 4 bytes)

      use_const4=True (when user specifies const/4 explicitly):
        const/4  vAA, 0x1   →  12 (0x10|AA) 00 00   (format 11n, 2 bytes + NOP NOP)
        Only valid for register AA ≤ 15 (always true for low boolean regs).

    Covers all sget variants (0x60/0x63/0x64/0x65/0x66 = format 21c, 4 bytes).
    Optionally restrict to only_class (substring) and only_method.
    Returns count of replacements.
    """
    data = bytes(dex)
    hdr  = _parse_header(data)
    if not hdr: return 0

    fids = _find_field_ids(data, hdr, field_class, field_name)
    if not fids:
        warn(f"  Field {field_class}->{field_name} not in this DEX"); return 0
    for fi in fids:
        info(f"  Found field: {field_class}->{field_name} @ field_id[{fi}] = 0x{fi:04X}")

    # All sget variants (format 21c, 4 bytes): boolean=0x63, plain=0x60, byte=0x64, char=0x65, short=0x66
    SGET_OPCODES = frozenset([0x60, 0x63, 0x64, 0x65, 0x66])

    raw   = bytearray(dex)
    count = 0

    for insns_off, insns_len, type_str, mname in _iter_code_items(data, hdr):
        if only_class  and only_class  not in type_str: continue
        if only_method and mname != only_method:        continue
        i = 0
        while i < insns_len - 3:
            op = raw[insns_off + i]
            if op in SGET_OPCODES:
                reg      = raw[insns_off + i + 1]
                field_lo = struct.unpack_from('<H', raw, insns_off + i + 2)[0]
                if field_lo in fids:
                    if use_const4 and reg <= 15:
                        # const/4 vAA, 0x1  (11n: opcode=0x12, byte1=(value<<4)|reg)
                        raw[insns_off + i]     = 0x12
                        raw[insns_off + i + 1] = (0x1 << 4) | reg
                        raw[insns_off + i + 2] = 0x00   # NOP
                        raw[insns_off + i + 3] = 0x00   # NOP
                    else:
                        # const/16 vAA, 0x1  (opcode 0x13, format 21s: 4 bytes)
                        # 0x13 = const/16. NOT 0x15 which is const/high16 (shifts value <<16)
                        raw[insns_off + i]     = 0x13
                        raw[insns_off + i + 1] = reg
                        raw[insns_off + i + 2] = 0x01
                        raw[insns_off + i + 3] = 0x00
                    count += 1
                i += 4
            else:
                i += 2

    mode = "const/4" if use_const4 else "const/16"
    if count:
        _fix_checksums(raw); dex[:] = raw
        ok(f"  ✓ {field_name}: {count} sget → {mode} 1")
    else:
        warn(f"  {field_name}: no matching sget found"
             + (f" in {only_class}::{only_method}" if only_class else ""))
    return count


# ════════════════════════════════════════════════════════════════════
#  BINARY PATCH: swap field reference in a specific method
#  Used for: NotificationUtil::isEmptySummary
#    IS_INTERNATIONAL_BUILD  →  IS_ALPHA_BUILD
# ════════════════════════════════════════════════════════════════════

def binary_swap_field_ref(dex: bytearray,
                          class_desc:      str, method_name:    str,
                          old_field_class: str, old_field_name: str,
                          new_field_class: str, new_field_name: str) -> bool:
    data = bytes(dex)
    hdr  = _parse_header(data)
    if not hdr: return False

    old_fids = _find_field_ids(data, hdr, old_field_class, old_field_name)
    new_fids = _find_field_ids(data, hdr, new_field_class, new_field_name)

    if not old_fids:
        warn(f"  Old field {old_field_name} not in DEX"); return False
    if not new_fids:
        warn(f"  New field {new_field_name} not in DEX"); return False

    new_fi = next(iter(new_fids))
    if new_fi > 0xFFFF:
        err(f"  New field index 0x{new_fi:X} > 0xFFFF, cannot encode in 21c"); return False

    # All sget variants (0x60–0x66) share format 21c — swap field index in any of them
    SGET_OPCODES = frozenset([0x60, 0x63, 0x64, 0x65, 0x66])

    raw = bytearray(dex)
    count = 0
    target_type = f'L{class_desc};'

    for insns_off, insns_len, type_str, mname in _iter_code_items(data, hdr):
        if target_type not in type_str: continue
        if mname != method_name:       continue
        i = 0
        while i < insns_len - 3:
            if raw[insns_off + i] in SGET_OPCODES:
                field_lo = struct.unpack_from('<H', raw, insns_off + i + 2)[0]
                if field_lo in old_fids:
                    struct.pack_into('<H', raw, insns_off + i + 2, new_fi)
                    count += 1
                i += 4
            else:
                i += 2

    if count:
        _fix_checksums(raw); dex[:] = raw
        ok(f"  ✓ {method_name}: {count} × {old_field_name} → {new_field_name}")
        return True
    else:
        warn(f"  {method_name}: field ref {old_field_name} not found")
        return False


# ════════════════════════════════════════════════════════════════════
#  BINARY PATCH: swap string literal reference
#  Used for: MIUIFrequentPhrase Gboard redirect (no apktool, no timeout)
#    const-string/const-string-jumbo that reference old_str → new_str
# ════════════════════════════════════════════════════════════════════

def _find_string_idx(data: bytes, hdr: dict, target: str) -> Optional[int]:
    """Binary search the sorted DEX string pool. Returns index or None."""
    lo, hi = 0, hdr['string_ids_size'] - 1
    while lo <= hi:
        mid = (lo + hi) // 2
        s   = _get_str(data, hdr, mid)
        if s == target: return mid
        if s < target:  lo = mid + 1
        else:           hi = mid - 1
    return None

def binary_swap_string(dex: bytearray, old_str: str, new_str: str,
                       only_class: str = None) -> int:
    """
    Replace const-string / const-string-jumbo instructions that reference
    old_str with ones that reference new_str.
    new_str must already exist in the DEX string pool (not injected).
    Only scans verified code_item instruction arrays.
    Returns count of replacements.
    """
    data = bytes(dex)
    hdr  = _parse_header(data)
    if not hdr: return 0

    old_idx = _find_string_idx(data, hdr, old_str)
    if old_idx is None:
        warn(f"  String '{old_str}' not in DEX pool — skip"); return 0
    new_idx = _find_string_idx(data, hdr, new_str)
    if new_idx is None:
        warn(f"  String '{new_str}' not in DEX pool — cannot swap"); return 0

    info(f"  String swap: idx[{old_idx}] '{old_str}' → idx[{new_idx}] '{new_str}'")
    raw   = bytearray(dex)
    count = 0

    for insns_off, insns_len, type_str, mname in _iter_code_items(data, hdr):
        if only_class and only_class not in type_str: continue
        i = 0
        while i < insns_len - 3:
            op = raw[insns_off + i]
            if op == 0x1A and i + 3 < insns_len:    # const-string (21c, 4 bytes)
                sidx = struct.unpack_from('<H', raw, insns_off + i + 2)[0]
                if sidx == old_idx:
                    struct.pack_into('<H', raw, insns_off + i + 2, new_idx & 0xFFFF)
                    count += 1
                i += 4
            elif op == 0x1B and i + 5 < insns_len:  # const-string/jumbo (31c, 6 bytes)
                sidx = struct.unpack_from('<I', raw, insns_off + i + 2)[0]
                if sidx == old_idx:
                    struct.pack_into('<I', raw, insns_off + i + 2, new_idx)
                    count += 1
                i += 6
            else:
                i += 2

    if count:
        _fix_checksums(raw); dex[:] = raw
        ok(f"  ✓ '{old_str}' → '{new_str}': {count} ref(s) swapped")
    else:
        warn(f"  No const-string refs to '{old_str}' found"
             + (f" in {only_class}" if only_class else ""))
    return count


# ════════════════════════════════════════════════════════════════════
#  ARCHIVE PIPELINE
# ════════════════════════════════════════════════════════════════════

def list_dexes(archive: Path) -> list:
    with zipfile.ZipFile(archive) as z:
        names = [n for n in z.namelist() if re.match(r'^classes\d*\.dex$', n)]
    return sorted(names, key=lambda x: 0 if x == "classes.dex"
                                       else int(re.search(r'\d+', x).group()))

def _inject_dex(archive: Path, dex_name: str, dex_bytes: bytes) -> bool:
    work = Path(tempfile.mkdtemp(prefix="dp_"))
    try:
        (work / dex_name).write_bytes(dex_bytes)
        r = subprocess.run(["zip", "-0", "-u", str(archive), dex_name],
                           cwd=str(work), capture_output=True, text=True)
        if r.returncode not in (0, 12):
            err(f"  zip failed rc={r.returncode}: {r.stderr[:200]}"); return False
        return True
    except Exception as exc:
        err(f"  inject crash: {exc}"); return False
    finally:
        shutil.rmtree(work, ignore_errors=True)

def run_patches(archive: Path, patch_fn, label: str) -> int:
    """
    Run patch_fn(dex_name, dex_bytearray) on every DEX.
    ALWAYS exits 0 — graceful skip when nothing found (user requirement).
    """
    archive = archive.resolve()
    if not archive.exists():
        warn(f"Archive not found: {archive}"); return 0

    info(f"Archive: {archive.name}  ({archive.stat().st_size // 1024}K)")
    bak = Path(str(archive) + ".bak")
    if not bak.exists(): shutil.copy2(archive, bak); ok("✓ Backup created")

    is_apk = archive.suffix.lower() == '.apk'
    count  = 0

    for dex_name in list_dexes(archive):
        with zipfile.ZipFile(archive) as z:
            raw = bytearray(z.read(dex_name))
        info(f"→ {dex_name} ({len(raw)//1024}K)")
        try:
            patched = patch_fn(dex_name, raw)
        except Exception as exc:
            err(f"  patch_fn crash: {exc}"); traceback.print_exc(); continue
        if not patched: continue
        if not _inject_dex(archive, dex_name, bytes(raw)):
            err(f"  Failed to inject {dex_name}"); continue
        count += 1

    if count > 0:
        if is_apk: _zipalign(archive)
        ok(f"✅ {label}: {count} DEX(es) patched  ({archive.stat().st_size//1024}K)")
    else:
        # Graceful skip — archive unchanged (backup exists but nothing was written)
        warn(f"⚠ {label}: no patches applied — archive unchanged")
    return count   # caller always exits 0


# ════════════════════════════════════════════════════════════════════
#  PATCH PROFILES
# ════════════════════════════════════════════════════════════════════

# ── Settings.apk  ────────────────────────────────────────────────
def _settings_ai_patch(dex_name: str, dex: bytearray) -> bool:
    if b'InternalDeviceUtils' not in bytes(dex): return False
    return binary_patch_method(dex,
        "com/android/settings/InternalDeviceUtils",
        "isAiSupported", 1, _STUB_TRUE)

# ── SoundRecorder APK  ──────────────────────────────────────────
def _recorder_ai_patch(dex_name: str, dex: bytearray) -> bool:
    """
    Two-pass:
    1. AiDeviceUtil::isAiSupportedDevice → return true.
       Tries known paths; if class present but path differs, scans all class defs.
    2. IS_INTERNATIONAL_BUILD (Lmiui/os/Build;) → const/16 1 across entire DEX.
       Handles region gating that exists alongside the AI method gate.
    Returns True if either pass patched anything.
    """
    patched = False
    raw = bytes(dex)

    # Pass 1 — AiDeviceUtil::isAiSupportedDevice
    if b'AiDeviceUtil' in raw:
        for cls in (
            "com/miui/soundrecorder/utils/AiDeviceUtil",
            "com/miui/soundrecorder/AiDeviceUtil",
            "com/miui/recorder/utils/AiDeviceUtil",
            "com/miui/recorder/AiDeviceUtil",
        ):
            if binary_patch_method(dex, cls, "isAiSupportedDevice",
                                   stub_regs=1, stub_insns=_STUB_TRUE):
                patched = True
                raw = bytes(dex)
                break

        if not patched:
            # Package path unknown — scan every class def for AiDeviceUtil
            info("  AiDeviceUtil: scanning all class defs...")
            data = bytes(dex)
            hdr  = _parse_header(data)
            if hdr:
                for i in range(hdr['class_defs_size']):
                    base = hdr['class_defs_off'] + i * 32
                    if struct.unpack_from('<I', data, base + 24)[0] == 0:
                        continue
                    cls_idx = struct.unpack_from('<I', data, base)[0]
                    try:
                        sidx     = struct.unpack_from('<I', data, hdr['type_ids_off'] + cls_idx * 4)[0]
                        type_str = _get_str(data, hdr, sidx)
                        if ('AiDeviceUtil' in type_str
                                and type_str.startswith('L')
                                and type_str.endswith(';')):
                            if binary_patch_method(dex, type_str[1:-1], "isAiSupportedDevice",
                                                   stub_regs=1, stub_insns=_STUB_TRUE):
                                patched = True
                                raw = bytes(dex)
                                break
                    except Exception:
                        continue

    # Pass 2 — IS_INTERNATIONAL_BUILD region gate
    if b'IS_INTERNATIONAL_BUILD' in raw:
        if binary_patch_sget_to_true(dex, 'Lmiui/os/Build;', 'IS_INTERNATIONAL_BUILD') > 0:
            patched = True

    return patched

# ── services.jar  ────────────────────────────────────────────────
def _services_jar_patch(dex_name: str, dex: bytearray) -> bool:
    """
    Suppress showSystemReadyErrorDialogsIfNeeded by patching the CALL SITE.

    WHY CALL-SITE NOT METHOD STUB:
      Stubbing ANY concrete implementation (Case B previously) patches classes
      like PanningScalingHandler that legitimately implement the interface method
      for their own purposes — breaking unrelated functionality.
      The correct approach is to find the invoke-virtual instruction that dispatches
      through ActivityTaskManagerInternal and NOP it, leaving all implementations
      untouched.

    TARGET INSTRUCTION:
      invoke-virtual {vX}, Lcom/android/server/wm/ActivityTaskManagerInternal;
          ->showSystemReadyErrorDialogsIfNeeded()V
      opcode: any invoke-* (0x6E-0x72, 0x74-0x78), format 35c or 3rc, 6 bytes
      ActivityTaskManagerInternal is abstract → call is usually invoke-interface (0x72)

    PATCH:
      Replace the 6 bytes of the invoke instruction with 0x00 0x00 0x00 0x00 0x00 0x00
      (3 × NOP code units). Method is void so no move-result follows.

    IDENTIFICATION:
      The method_id for ActivityTaskManagerInternal::showSystemReadyErrorDialogsIfNeeded
      is identified by matching BOTH the class type string AND the method name in the
      method_ids table — not just the name, which would also match implementations in
      PanningScalingHandler, ActivityTaskManagerService, etc.

    SAFETY:
      - All 10 invoke-* opcodes (0x6E-0x72, 0x74-0x78) checked; only exact method_id matches NOP'd.
      - Only exact method_id matches are patched.
      - All code_item boundaries are respected — scan uses _iter_code_items.
      - If no call site found: returns False (graceful skip), does not abort build.
    """
    raw = bytes(dex)
    METHOD   = 'showSystemReadyErrorDialogsIfNeeded'
    TARGET_C = 'Lcom/android/server/wm/ActivityTaskManagerInternal;'

    if b'showSystemReadyErrorDialogsIfNeeded' not in raw: return False
    if b'ActivityTaskManagerInternal' not in raw:        return False

    hdr = _parse_header(raw)
    if not hdr: return False

    # Step 1: find the specific method_id for ActivityTaskManagerInternal::METHOD
    #   Must match BOTH class type AND method name.
    #   Walking all method_ids: method_id_item = { class_idx:H, proto_idx:H, name_idx:I }
    target_mid = None
    for mi in range(hdr['method_ids_size']):
        base = hdr['method_ids_off'] + mi * 8
        try:
            cls_idx   = struct.unpack_from('<H', raw, base + 0)[0]
            name_sidx = struct.unpack_from('<I', raw, base + 4)[0]
            # Resolve class type
            type_sidx = struct.unpack_from('<I', raw, hdr['type_ids_off'] + cls_idx * 4)[0]
            cls_str   = _get_str(raw, hdr, type_sidx)
            if cls_str != TARGET_C: continue
            # Resolve method name
            mname = _get_str(raw, hdr, name_sidx)
            if mname != METHOD: continue
            target_mid = mi
            info(f"  Found method_id[{mi}]: {TARGET_C}->{METHOD}()")
            break
        except Exception:
            continue

    if target_mid is None:
        warn(f"  method_id for {TARGET_C}->{METHOD}() not found in this DEX")
        return False

    # Step 2: scan all code_items for invoke-virtual / invoke-virtual/range
    #   with this exact method_id and NOP them (6 bytes → 6 × 0x00).
    # All invoke-* opcodes that embed a method_ref at bytes +2,+3 (LE uint16).
    # Format 35c (3 code-units, 6 bytes): virtual/super/direct/static/interface
    # Format 3rc (3 code-units, 6 bytes): same five, range variant
    # ActivityTaskManagerInternal is abstract, so the call is invoke-interface (0x72).
    # We catch all variants to be build-agnostic.
    INVOKE_OPS_ALL = {
        0x6E: 'invoke-virtual',       0x6F: 'invoke-super',
        0x70: 'invoke-direct',        0x71: 'invoke-static',
        0x72: 'invoke-interface',
        0x74: 'invoke-virtual/range', 0x75: 'invoke-super/range',
        0x76: 'invoke-direct/range',  0x77: 'invoke-static/range',
        0x78: 'invoke-interface/range',
    }
    raw_w = bytearray(dex)
    count = 0

    for insns_off, insns_len, type_str, mname in _iter_code_items(raw, hdr):
        i = 0
        while i <= insns_len * 2 - 6:   # need 6 bytes ahead
            op = raw[insns_off + i]
            if op in INVOKE_OPS_ALL:
                mid_ref = struct.unpack_from('<H', raw, insns_off + i + 2)[0]
                if mid_ref == target_mid:
                    op_name = INVOKE_OPS_ALL[op]
                    # NOP out the 6-byte invoke instruction (3 code-units × 0x00)
                    for b in range(6):
                        raw_w[insns_off + i + b] = 0x00
                    ok(f"  NOP'd [{op_name}] call in {type_str}::{mname} @ +{i}")
                    count += 1
                    i += 6
                    continue
            i += 2

    if count == 0:
        warn(f"  No invoke-virtual call site for {METHOD} found — DEX unchanged")
        return False

    _fix_checksums(raw_w)
    dex[:] = raw_w
    ok(f"  ✓ {METHOD}: {count} call site(s) NOP'd")
    return True

# ── Provision.apk: Utils::setGmsAppEnabledStateForCn  ──────────────
def _provision_gms_patch(dex_name: str, dex: bytearray) -> bool:
    """
    STRICT SCOPE: patch exactly ONE sget-boolean of IS_INTERNATIONAL_BUILD
    inside Utils::setGmsAppEnabledStateForCn — no other class, no other method.

    Encoding used:  const/16 v0, 0x1  →  bytes 13 00 01 00
      opcode 0x13 (const/16, format 21s), exactly 4 bytes — same width as sget-boolean.
      No NOP padding needed. Clean single-instruction replacement.

      WHY NOT const/4 (use_const4=True):
        const/4 is only 2 bytes (1 code unit). Replacing a 4-byte sget leaves 2 bytes
        that must be padded with a NOP code unit (0x00 0x00), producing a spurious
        "nop" line in baksmali output. const/16 fills all 4 bytes cleanly.

    Constraints enforced:
      - class filter: 'Utils' must be in type_str (catches com/android/provision/Utils)
      - method filter: exact name 'setGmsAppEnabledStateForCn'
      - first-occurrence only: count is tracked; abort if 0 matches
      - use_const4=False: uses opcode 0x13 (const/16), no NOP padding
    """
    raw = bytes(dex)
    if b'IS_INTERNATIONAL_BUILD' not in raw: return False
    if b'setGmsAppEnabledStateForCn' not in raw: return False

    n = binary_patch_sget_to_true(dex,
            'Lmiui/os/Build;', 'IS_INTERNATIONAL_BUILD',
            only_class='Utils',
            only_method='setGmsAppEnabledStateForCn',
            use_const4=False)
    if n == 0:
        warn("  Provision: setGmsAppEnabledStateForCn not found or no IS_INTERNATIONAL_BUILD sget")
        return False
    ok(f"  ✓ Provision Utils::setGmsAppEnabledStateForCn → const/16 v0, 0x1 ({n} sget, no NOP)")
    return True


# ── miui-services.jar: global IS_INTERNATIONAL_BUILD sweep  ──────────
def _miui_service_patch(dex_name: str, dex: bytearray) -> bool:
    """
    Global sweep of Lmiui/os/Build;->IS_INTERNATIONAL_BUILD in miui-services.jar.
    No class filter — flips all region gates in the service jar.
    Uses const/4 (opcode 0x12) which is safe for all boolean registers (always ≤ 15).
    Replaces the deleted _intl_build_patch which was using 0x15 (const/high16, wrong).
    """
    raw = bytes(dex)
    if b'IS_INTERNATIONAL_BUILD' not in raw: return False
    n  = binary_patch_sget_to_true(dex, 'Lmiui/os/Build;', 'IS_INTERNATIONAL_BUILD',
                                    use_const4=True)
    n += _raw_sget_scan(dex, 'Lmiui/os/Build;', 'IS_INTERNATIONAL_BUILD',
                        use_const4=True)
    return n > 0

# ── SystemUI combined: VoLTE + QuickShare + WA notification  ─────
def _systemui_all_patch(dex_name: str, dex: bytearray) -> bool:
    """
    Patch 1 — VoLTE: GLOBAL sweep of Lmiui/os/Build;->IS_INTERNATIONAL_BUILD.
      No class filter. Targets like MiuiOperatorCustomizedPolicy,
      MiuiCarrierTextController, MiuiCellularIconVM, MiuiMobileIconBinder
      and their inner/anonymous classes read this flag via synthetic accessors —
      the actual sget bytecode lives in those generated accessors, not the named
      class body. A global sweep catches all of them regardless of which class
      the compiler emitted the sget into. Uses const/4 vX, 0x1 (fallback const/16
      if register > 15).

    Patch 2 — QuickShare: Lcom/miui/utils/configs/MiuiConfigs;->IS_INTERNATIONAL_BUILD
      → const/4 pX, 0x1. Class CurrentTilesInteractorImpl, all methods.

    Patch 3 — WA notification: same MiuiConfigs field → const/4 vX, 0x1.
      Scoped to NotificationUtil::isEmptySummary.
    """
    patched = False
    raw = bytes(dex)

    # Patch 1 — VoLTE: global sweep + raw-scan fallback, Lmiui/os/Build, const/4
    #   Two passes guarantee MiuiMobileIconBinder$bind$1$1$10::invokeSuspend
    #   and any other Kotlin coroutine class whose code_item _iter_code_items
    #   mis-steps due to synthetic captured fields in class_data.
    if b'IS_INTERNATIONAL_BUILD' in raw and b'miui/os/Build' in raw:
        n1 = binary_patch_sget_to_true(dex,
                'Lmiui/os/Build;', 'IS_INTERNATIONAL_BUILD',
                use_const4=True)
        n2 = _raw_sget_scan(dex,
                'Lmiui/os/Build;', 'IS_INTERNATIONAL_BUILD',
                use_const4=True)
        if n1 + n2 > 0:
            patched = True
            raw = bytes(dex)

    # Patch 2 — QuickShare: CurrentTilesInteractorImpl only, all methods, const/4
    if b'CurrentTilesInteractorImpl' in raw and b'MiuiConfigs' in raw:
        if binary_patch_sget_to_true(dex,
                'Lcom/miui/utils/configs/MiuiConfigs;', 'IS_INTERNATIONAL_BUILD',
                only_class='CurrentTilesInteractorImpl',
                use_const4=True) > 0:
            patched = True
            raw = bytes(dex)

    # Patch 3 — WA notification: NotificationUtil::isEmptySummary, const/4
    if b'NotificationUtil' in raw and b'MiuiConfigs' in raw:
        if binary_patch_sget_to_true(dex,
                'Lcom/miui/utils/configs/MiuiConfigs;', 'IS_INTERNATIONAL_BUILD',
                only_class='NotificationUtil',
                only_method='isEmptySummary',
                use_const4=True) > 0:
            patched = True

    return patched

# ── miui-framework.jar  ─────────────────────────────────────────
# Target classes for IS_INTERNATIONAL_BUILD in miui-framework
_FW_INTL_CLASSES = [
    'AppOpsManagerInjector',   'NearbyUtils',             'ShortcutFunctionManager',
    'MiInputShortcutFeature',  'MiInputShortcutUtil',     'FeatureConfiguration',
    'InputFeature',            'TelephonyManagerEx',       'SystemServiceRegistryImpl',
    'PackageManagerImpl',      'PackageParserImpl',        'LocaleComparator',
    'MiuiSignalStrengthImpl',
]

def _miui_framework_patch(dex_name: str, dex: bytearray) -> bool:
    """
    miui-framework.jar — two binary passes:

    Pass 1 — IS_INTERNATIONAL_BUILD → const/4 1
      Scoped to 13 specific classes only. These are the framework-side gating
      classes that block international features. A global sweep is intentionally
      avoided — it would flip IS_GLOBAL_BUILD-adjacent paths that crash Settings.

    Pass 2 — showSystemReadyErrorDialogsIfNeeded → return-void
      Scan all classes for ActivityTaskManagerInternal (or any class that defines
      the method) and stub it. Prevents AMS from showing system-ready error dialogs
      on CN ROMs running in global mode.

    NOTE: IS_GLOBAL_BUILD is NOT patched here (Settings crash risk).
          Gboard IME swap is done via apktool in manager (string not in DEX pool).
    """
    raw = bytes(dex)
    patched = False

    # Pass 1a — IS_INTERNATIONAL_BUILD in 13 framework classes
    if b'IS_INTERNATIONAL_BUILD' in raw:
        n = 0
        for cls in _FW_INTL_CLASSES:
            n += binary_patch_sget_to_true(dex, 'Lmiui/os/Build;', 'IS_INTERNATIONAL_BUILD',
                                            only_class=cls, use_const4=True)
        if n > 0:
            patched = True
            raw = bytes(dex)

    # Pass 2 — showSystemReadyErrohhhfffrDialogsIfNeeded in ActivityTghaskManagerInternal
    if b'ActivityTaskManagerIntkkhernal' in raw:
        hdr = _parse_header(raw)
        if hdr:
            for i in range(hdr['class_defs_size']):
                base = hdr['class_defs_off'] + i * 32
                if struct.unpack_from('<I', raw, base + 24)[0] == 0: continue
                cls_idx = struct.unpack_from('<I', raw, base)[0]
                try:
                    sidx     = struct.unpack_from('<I', raw, hdr['type_ids_off'] + cls_idx * 4)[0]
                    type_str = _get_str(raw, hdr, sidx)
                    if 'ActivityTaskManagerInternal' not in type_str: continue
                    cls_path = type_str[1:-1]
                    if binary_patch_method(dex, cls_path,
                            'showSystemReadyErrorDialogsIfNeeded', 1, _STUB_VOID):
                        patched = True
                        raw = bytes(dex)
                except Exception:
                    continue

    return patched

# ── Settings.apk region unlock  ─────────────────────────────────
def _settings_region_patch(dex_name: str, dex: bytearray) -> bool:
    """
    Patch IS_GLOBAL_BUILD → const/4 pX, 0x1 scoped to exactly 3 classes.
    NO global sweep. NO raw scan. Patching only:

      LocaleController      — all methods (no method filter; the sget may be
                               in a method other than getAvailabilityStatus)
      LocaleSettingsTree    — all methods
      OtherPersonalSettings — all methods (has 2 IS_GLOBAL_BUILD lines in onCreate)

    Global sweep was used previously and patched 57 sgets in Settings.apk,
    flipping region flags in unrelated classes and crashing the app.
    Class-filtered approach patches only the 3 intended classes.

    The improved _iter_code_items (using _skip_uleb128 instead of break in
    the field-skip loop) ensures OtherPersonalSettings::onCreate is not
    silently skipped due to ULEB128 mis-stepping on its instance fields.
    """
    if b'IS_GLOBAL_BUILD' not in bytes(dex): return False
    n = 0
    n += binary_patch_sget_to_true(dex, 'Lmiui/os/Build;', 'IS_GLOBAL_BUILD',
                                    only_class='LocaleController',
                                    use_const4=True)
    n += binary_patch_sget_to_true(dex, 'Lmiui/os/Build;', 'IS_GLOBAL_BUILD',
                                    only_class='LocaleSettingsTree',
                                    use_const4=True)
    n += binary_patch_sget_to_true(dex, 'Lmiui/os/Build;', 'IS_GLOBAL_BUILD',
                                    only_class='OtherPersonalSettings',
                                    use_const4=True)
    return n > 0


# ── Settings.apk Fold-Pager  ─────────────────────────────────────
def _settings_foldpager_patch(dex_name: str, dex: bytearray) -> bool:
    """
    Fold-Pager: two binary method stubs in Settings.apk.

    Patch 1 — SettingsFeatures::isSupportFoldScreenSettings → return true
      Class: com/android/settings/utils/SettingsFeatures
      Makes the fold screen settings page accessible.

    Patch 2 — MiuiFoldScreenSettings::displayResourceTilesToScreen → return void
      Class: com/android/settings/foldSettings/MiuiFoldScreenSettings
      Suppresses the default tile display, allowing custom XML layout.
    """
    patched = False
    raw = bytes(dex)

    # Patch 1: isSupportFoldScreenSettings → return true (0x1)
    if b'SettingsFeatures' in raw:
        if binary_patch_method(dex,
                "com/android/settings/utils/SettingsFeatures",
                "isSupportFoldScreenSettings", 1, _STUB_TRUE,
                trim=True):
            patched = True
            raw = bytes(dex)

    # Patch 2: displayResourceTilesToScreen → return void
    if b'MiuiFoldScreenSettings' in raw:
        if binary_patch_method(dex,
                "com/android/settings/foldSettings/MiuiFoldScreenSettings",
                "displayResourceTilesToScreen", 0, _STUB_VOID,
                trim=True):
            patched = True

    return patched


# ── InCallUI.apk  ────────────────────────────────────────────────
def _incallui_patch(dex_name: str, dex: bytearray) -> bool:
    """
    STRICT SCOPE: RecorderUtils::isAiRecordEnable → return true.
    - Try known package first; if not found, scan all class defs for any class
      whose simple name is 'RecorderUtils' (package may differ between builds).
    - Do NOT touch other classes or instructions.
    """
    if b'RecorderUtils' not in bytes(dex):
        return False

    # Try known path first
    if binary_patch_method(dex,
            "com/android/incallui/RecorderUtils",
            "isAiRecordEnable",
            stub_regs=1, stub_insns=_STUB_TRUE):
        return True

    # Package path unknown — scan all class defs
    info("  RecorderUtils: scanning all class defs for exact class name...")
    data = bytes(dex)
    hdr  = _parse_header(data)
    if not hdr:
        warn("  Cannot parse DEX header"); return False

    for i in range(hdr['class_defs_size']):
        base = hdr['class_defs_off'] + i * 32
        if struct.unpack_from('<I', data, base + 24)[0] == 0:
            continue
        cls_idx = struct.unpack_from('<I', data, base)[0]
        try:
            sidx     = struct.unpack_from('<I', data, hdr['type_ids_off'] + cls_idx * 4)[0]
            type_str = _get_str(data, hdr, sidx)
            # Match exact simple class name: ends with /RecorderUtils;
            if type_str.endswith('/RecorderUtils;') and type_str.startswith('L'):
                cls_path = type_str[1:-1]
                info(f"  Found: {type_str} — trying isAiRecordEnable")
                if binary_patch_method(dex, cls_path, "isAiRecordEnable",
                                       stub_regs=1, stub_insns=_STUB_TRUE):
                    return True
        except Exception:
            continue

    warn("  RecorderUtils::isAiRecordEnable not found in any class")
    return False


# ════════════════════════════════════════════════════════════════════
#  COMMAND TABLE  +  ENTRY POINT
# ════════════════════════════════════════════════════════════════════

PROFILES = {
    "settings-ai":       _settings_ai_patch,
    "settings-region":   _settings_region_patch,   # exact 3 classes only
    "voice-recorder-ai": _recorder_ai_patch,        # AiDeviceUtil::isAiSupportedDevice
    "services-jar":      _services_jar_patch,
    "provision-gms":     _provision_gms_patch,    # Utils::setGmsAppEnabledStateForCn only
    "miui-service":      _miui_service_patch,    # global IS_INTERNATIONAL_BUILD sweep
    "systemui-volte":    _systemui_all_patch,       # VoLTE + QuickShare(const/4) + WA-notif
    "miui-framework":    _miui_framework_patch,     # validateTheme(trim) + IS_GLOBAL_BUILD
    "incallui-ai":       _incallui_patch,           # RecorderUtils::isAiRecordEnable
    "settings-foldpager": _settings_foldpager_patch,  # Fold-Pager: fold screen + tile display
}

def main():
    CMDS = sorted(PROFILES.keys()) + ["verify"]
    if len(sys.argv) < 2 or sys.argv[1] not in CMDS:
        print(f"Usage: dex_patcher.py <{'|'.join(CMDS)}> [archive]", file=sys.stderr)
        sys.exit(1)
    cmd = sys.argv[1]
    if cmd == "verify": cmd_verify(); return
    if len(sys.argv) < 3:
        err(f"Usage: dex_patcher.py {cmd} <archive>"); sys.exit(1)
    run_patches(Path(sys.argv[2]), PROFILES[cmd], cmd)
    sys.exit(0)   # ALWAYS exit 0 — graceful skip when nothing found

if __name__ == "__main__":
    main()
PYTHON_EOF
chmod +x "$BIN_DIR/dex_patcher.py"
SMALI_TOOLS_OK=1
log_success "✓ DEX patcher ready (binary in-place, no baksmali/smali required)"
# Verify zipalign is available
python3 "$BIN_DIR/dex_patcher.py" verify 2>&1 | while IFS= read -r l; do
    case "$l" in
        "[SUCCESS]"*) log_success "${l#[SUCCESS] }" ;;
        "[WARNING]"*) log_warning "${l#[WARNING] }" ;;
        "[ERROR]"*)   log_error   "${l#[ERROR] }"   ;;
        *)            [ -n "$l" ] && log_info "$l"   ;;
    esac
done

# GApps
if [ ! -d "gapps_src" ]; then
    log_info "Downloading GApps package..."
    gdown "$GAPPS_LINK" -O gapps.zip --fuzzy -q
    unzip -qq gapps.zip -d gapps_src && rm gapps.zip
    log_success "GApps package downloaded and extracted"
else
    log_info "GApps package already present"
fi

# NexPackage
if [ ! -d "nex_pkg" ]; then
    log_info "Downloading NexPackage..."
    gdown "$NEX_PACKAGE_LINK" -O nex.zip --fuzzy -q
    unzip -qq nex.zip -d nex_pkg && rm nex.zip
    log_success "NexPackage downloaded and extracted"
else
    log_info "NexPackage already present"
fi

# Launcher
if [ ! -f "$TEMP_DIR/MiuiHome_Latest.apk" ]; then
    log_info "Downloading HyperOS Launcher..."
    LAUNCHER_URL=$(curl -s "https://api.github.com/repos/$LAUNCHER_REPO/releases/latest" | jq -r '.assets[] | select(.name | endswith(".zip")) | .browser_download_url' | head -n 1)
    if [ ! -z "$LAUNCHER_URL" ] && [ "$LAUNCHER_URL" != "null" ]; then
        wget -q -O l.zip "$LAUNCHER_URL"
        unzip -qq l.zip -d l_ext
        FOUND=$(find l_ext -name "MiuiHome.apk" -type f | head -n 1)
        [ ! -z "$FOUND" ] && mv "$FOUND" "$TEMP_DIR/MiuiHome_Latest.apk" && log_success "Launcher downloaded"
        rm -rf l_ext l.zip
    else
        log_warning "Launcher download failed - URL not found"
    fi
else
    log_info "Launcher already present"
fi

log_success "All resources downloaded successfully"

# =========================================================
#  3b. MIUI MOD INJECTION SYSTEM
#  Triggered by MODS_SELECTED (comma-separated list from bot)
#  Each mod: GitHub API → download zip → extract → inject → permissions → cleanup
# =========================================================

# Generic helper: fetch latest release zip from a GitHub repo
# Usage: inject_miui_mod <owner/repo> <label>
# Sets MOD_EXTRACT_DIR on success, returns 1 on failure
inject_miui_mod() {
    local repo="$1" label="$2"
    MOD_EXTRACT_DIR="$TEMP_DIR/mod_${label}"
    rm -rf "$MOD_EXTRACT_DIR"
    mkdir -p "$MOD_EXTRACT_DIR"

    log_info "🧩 [$label] Fetching latest release from $repo..."
    local api_resp
    api_resp=$(curl -sfL --retry 3 --connect-timeout 30 \
        "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null)
    if [ -z "$api_resp" ]; then
        log_error "[$label] GitHub API request failed — aborting mod"
        rm -rf "$MOD_EXTRACT_DIR"
        return 1
    fi

    local zip_url
    zip_url=$(echo "$api_resp" | jq -r \
        '.assets[] | select(.name | endswith(".zip")) | .browser_download_url' | head -n 1)
    if [ -z "$zip_url" ] || [ "$zip_url" == "null" ]; then
        log_error "[$label] No .zip asset found in latest release — aborting mod"
        rm -rf "$MOD_EXTRACT_DIR"
        return 1
    fi

    local zip_path="$TEMP_DIR/mod_${label}.zip"
    log_info "[$label] Downloading: $(basename "$zip_url")"
    if ! wget -q -O "$zip_path" "$zip_url"; then
        log_error "[$label] Download failed — aborting mod"
        rm -f "$zip_path"
        rm -rf "$MOD_EXTRACT_DIR"
        return 1
    fi

    log_info "[$label] Extracting..."
    log_info "[$label] Extracting..."
    # tg_progress removed as per user request
    unzip -qq -o "$zip_path" -d "$MOD_EXTRACT_DIR"
    rm -f "$zip_path"

    # If the zip contains a single top-level folder, descend into it
    local top_dirs
    top_dirs=$(find "$MOD_EXTRACT_DIR" -mindepth 1 -maxdepth 1 -type d)
    local dir_count
    dir_count=$(echo "$top_dirs" | grep -c .)
    if [ "$dir_count" -eq 1 ]; then
        local inner_dir="$top_dirs"
        # Move contents up one level
        mv "$inner_dir"/* "$MOD_EXTRACT_DIR/" 2>/dev/null
        mv "$inner_dir"/.* "$MOD_EXTRACT_DIR/" 2>/dev/null
        rmdir "$inner_dir" 2>/dev/null
    fi

    log_success "[$label] Extraction complete"
    return 0
}

# Post-injection: fix permissions and cleanup
mod_finalize() {
    local target_dir="$1" label="$2"
    # APK permissions: 0644, directory permissions: 0755
    find "$target_dir" -type f -name "*.apk" -exec chmod 0644 {} +
    find "$target_dir" -type d -exec chmod 0755 {} +
    # Cleanup extraction dir
    rm -rf "$TEMP_DIR/mod_${label}"
    log_success "[$label] Permissions set and temp cleaned"
}

# ── Mod 1: HyperOS Launcher ──────────────────────────────────
inject_launcher_mod() {
    local dump_dir="$1"
    if ! inject_miui_mod "Mods-Center/HyperOS-Launcher" "launcher"; then
        return 1
    fi

    local src="$MOD_EXTRACT_DIR"

    # MiuiHome.apk → product/priv-app/MiuiHome/
    local home_apk=$(find "$src" -name "MiuiHome.apk" -type f | head -n 1)
    if [ -z "$home_apk" ]; then
        log_error "[launcher] MiuiHome.apk not found in module — aborting"
        rm -rf "$TEMP_DIR/mod_launcher"
        return 1
    fi
    mkdir -p "$dump_dir/priv-app/MiuiHome"
    cp -f "$home_apk" "$dump_dir/priv-app/MiuiHome/MiuiHome.apk"
    log_success "[launcher] ✓ MiuiHome.apk injected"

    # XiaomiEUExt.apk → product/priv-app/XiaomiEUExt/
    local ext_apk=$(find "$src" -name "XiaomiEUExt.apk" -type f | head -n 1)
    if [ -n "$ext_apk" ]; then
        mkdir -p "$dump_dir/priv-app/XiaomiEUExt"
        cp -f "$ext_apk" "$dump_dir/priv-app/XiaomiEUExt/XiaomiEUExt.apk"
        log_success "[launcher] ✓ XiaomiEUExt.apk injected"
    else
        log_info "[launcher] XiaomiEUExt.apk not present in module — skipping"
    fi

    # Permissions XMLs → product/etc/permissions/
    local perm_src=$(find "$src" -type d -name "permissions" | head -n 1)
    if [ -n "$perm_src" ]; then
        mkdir -p "$dump_dir/etc/permissions"
        cp -f "$perm_src"/*.xml "$dump_dir/etc/permissions/" 2>/dev/null
        log_success "[launcher] ✓ Permission XMLs injected"
    fi

    mod_finalize "$dump_dir/priv-app/MiuiHome" "launcher"
    log_success "✅ HyperOS Launcher mod injected successfully"
}

# ── Mod 2: HyperOS Theme Manager ─────────────────────────────
inject_theme_mod() {
    local dump_dir="$1"
    if ! inject_miui_mod "Mods-Center/HyperOS-Theme-Manager" "thememanager"; then
        return 1
    fi

    local src="$MOD_EXTRACT_DIR"

    # Delete existing ThemeManager directory first
    if [ -d "$dump_dir/app/MIUIThemeManager" ]; then
        rm -rf "$dump_dir/app/MIUIThemeManager"/*
        log_info "[thememanager] Cleared existing MIUIThemeManager directory"
    fi
    mkdir -p "$dump_dir/app/MIUIThemeManager"

    # MIUIThemeManager.apk
    local theme_apk=$(find "$src" -name "MIUIThemeManager.apk" -type f | head -n 1)
    if [ -z "$theme_apk" ]; then
        log_error "[thememanager] MIUIThemeManager.apk not found in module — aborting"
        rm -rf "$TEMP_DIR/mod_thememanager"
        return 1
    fi
    cp -f "$theme_apk" "$dump_dir/app/MIUIThemeManager/MIUIThemeManager.apk"
    log_success "[thememanager] ✓ MIUIThemeManager.apk injected"

    # lib/ directory
    local lib_src=$(find "$src" -type d -name "lib" | head -n 1)
    if [ -n "$lib_src" ]; then
        cp -rf "$lib_src" "$dump_dir/app/MIUIThemeManager/"
        log_success "[thememanager] ✓ lib/ directory injected"
    else
        log_info "[thememanager] No lib/ directory in module"
    fi

    mod_finalize "$dump_dir/app/MIUIThemeManager" "thememanager"
    log_success "✅ HyperOS Theme Manager mod injected successfully"
}

# ── Mod 3: HyperOS Security Center ───────────────────────────
inject_security_mod() {
    local dump_dir="$1"
    if ! inject_miui_mod "Mods-Center/HyperOS-Security-Center" "securitycenter"; then
        return 1
    fi

    local src="$MOD_EXTRACT_DIR"

    # SecurityCenter.apk → rename to MIUISecurityCenter.apk, replace dir
    local sec_apk=$(find "$src" -name "SecurityCenter.apk" -type f | head -n 1)
    if [ -z "$sec_apk" ]; then
        log_error "[securitycenter] SecurityCenter.apk not found in module — aborting"
        rm -rf "$TEMP_DIR/mod_securitycenter"
        return 1
    fi

    # Replace entire target directory
    rm -rf "$dump_dir/priv-app/MIUISecurityCenter"
    mkdir -p "$dump_dir/priv-app/MIUISecurityCenter"
    cp -f "$sec_apk" "$dump_dir/priv-app/MIUISecurityCenter/MIUISecurityCenter.apk"
    log_success "[securitycenter] ✓ MIUISecurityCenter.apk injected (renamed from SecurityCenter.apk)"

    # Permissions XMLs → product/etc/permissions/
    local perm_src=$(find "$src" -type d -name "permissions" | head -n 1)
    if [ -n "$perm_src" ]; then
        mkdir -p "$dump_dir/etc/permissions"
        cp -f "$perm_src"/*.xml "$dump_dir/etc/permissions/" 2>/dev/null
        log_success "[securitycenter] ✓ Permission XMLs injected"
    fi

    mod_finalize "$dump_dir/priv-app/MIUISecurityCenter" "securitycenter"
    log_success "✅ HyperOS Security Center mod injected successfully"
}

# ── Mod 4: Multi-Language Overlays ───────────────────────────
push_multilang() {
    # Downloads the multilang ZIP from the same private repo's Multilang tag,
    # extracts it, and installs ALL .apk files found under any overlay/ directory
    # strictly into product/overlay/ (no other partition).
    local dump_dir="$1"   # must be the product dump dir
    local overlay_dst="$dump_dir/overlay"

    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_step "🌐 MULTI-LANGUAGE OVERLAY PUSH"
    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Resolve asset URL from the same repo via GitHub API ($GITHUB_REPOSITORY is auto-set by Actions)
    local api_url="https://api.github.com/repos/${GITHUB_REPOSITORY}/releases/tags/Multilang"
    local asset_url
    asset_url=$(curl -sSf -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github.v3+json" "$api_url" \
        | jq -r '.assets[] | select(.name | endswith(".zip")) | .url' | head -n 1)

    if [ -z "$asset_url" ] || [ "$asset_url" == "null" ]; then
        log_error "[multilang] Could not resolve Multilang release asset — skipping"
        return 1
    fi
    log_info "[multilang] Asset API URL: $asset_url"

    # Download (use asset API URL with Accept header for private repo binary download)
    local ml_work="$TEMP_DIR/multilang"
    rm -rf "$ml_work" && mkdir -p "$ml_work"
    curl -sSfL -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Accept: application/octet-stream" \
        -o "$ml_work/multilang.zip" "$asset_url"
    if [ $? -ne 0 ] || [ ! -s "$ml_work/multilang.zip" ]; then
        log_error "[multilang] Download failed — skipping"
        return 1
    fi

    # Extract
    unzip -qq -o "$ml_work/multilang.zip" -d "$ml_work/extracted"
    log_info "[multilang] Extracted $(find "$ml_work/extracted" -name "*.apk" | wc -l) APKs"

    # Push all .apk from any overlay/ subdirectory → product/overlay/
    mkdir -p "$overlay_dst"
    local pushed=0
    while IFS= read -r -d '' apk; do
        # Only install APKs that live inside a directory named 'overlay'
        local parent_dir
        parent_dir=$(basename "$(dirname "$apk")")
        if [ "$parent_dir" == "overlay" ]; then
            cp -f "$apk" "$overlay_dst/"
            log_success "[multilang] ✓ $(basename "$apk")"
            pushed=$((pushed + 1))
        fi
    done < <(find "$ml_work/extracted" -name "*.apk" -print0)

    rm -rf "$ml_work"

    if [ "$pushed" -eq 0 ]; then
        log_warning "[multilang] No overlay APKs found in archive"
        return 1
    fi

    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_success "✅ Multi-Language: $pushed overlay APK(s) → product/overlay/"
    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    return 0
}

# ── Mod 5: Personal Assistant (com.miui.personalassistant) ───
push_personal_assistant() {
    local dump_dir="$1"   # must be the product dump dir

    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_step "📱 PERSONAL ASSISTANT APK PUSH"
    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Detect existing folder in product/priv-app that contains com.miui.personalassistant
    local existing_dir=""
    local existing_apk_name=""
    for dir in "$dump_dir"/priv-app/*/; do
        [ ! -d "$dir" ] && continue
        local apk_file
        apk_file=$(find "$dir" -maxdepth 1 -name "*.apk" -type f | head -n 1)
        if [ -n "$apk_file" ]; then
            # Check if APK package name matches com.miui.personalassistant
            if unzip -p "$apk_file" AndroidManifest.xml 2>/dev/null | \
               strings | grep -q "com.miui.personalassistant"; then
                existing_dir="$dir"
                existing_apk_name=$(basename "$apk_file")
                break
            fi
        fi
    done

    # Fallback: look for known folder names
    if [ -z "$existing_dir" ]; then
        for candidate in MIUIPersonalAssistant MIUIPersonalAssistantPhoneOS3 PersonalAssistant; do
            if [ -d "$dump_dir/priv-app/$candidate" ]; then
                existing_dir="$dump_dir/priv-app/$candidate/"
                existing_apk_name=$(find "$existing_dir" -maxdepth 1 -name "*.apk" -type f -printf '%f\n' | head -n 1)
                break
            fi
        done
    fi

    if [ -z "$existing_dir" ]; then
        log_warning "[personalassistant] No existing Personal Assistant folder found in priv-app — creating default"
        existing_dir="$dump_dir/priv-app/MIUIPersonalAssistant/"
        mkdir -p "$existing_dir"
        existing_apk_name="MIUIPersonalAssistant.apk"
    fi

    local folder_name
    folder_name=$(basename "${existing_dir%/}")
    log_info "[personalassistant] Target folder: priv-app/$folder_name/"
    log_info "[personalassistant] Target APK name: $existing_apk_name"

    # Download from the same repo's Multilang tag ($GITHUB_REPOSITORY is auto-set by Actions)
    local api_url="https://api.github.com/repos/${GITHUB_REPOSITORY}/releases/tags/Multilang"
    local asset_url
    asset_url=$(curl -sSf -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github.v3+json" "$api_url" \
        | jq -r '.assets[] | select(.name | test("[Pp]ersonal[Aa]ssistant")) | .url' | head -n 1)

    if [ -z "$asset_url" ] || [ "$asset_url" == "null" ]; then
        log_error "[personalassistant] Could not find Personal Assistant APK in release — skipping"
        return 1
    fi
    log_info "[personalassistant] Asset API URL: $asset_url"

    # Download the APK (private repo → use asset API with octet-stream)
    local pa_work="$TEMP_DIR/personalassistant"
    rm -rf "$pa_work" && mkdir -p "$pa_work"
    curl -sSfL -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Accept: application/octet-stream" \
        -o "$pa_work/personalassistant.apk" "$asset_url"
    if [ $? -ne 0 ] || [ ! -s "$pa_work/personalassistant.apk" ]; then
        log_error "[personalassistant] Download failed — skipping"
        return 1
    fi

    # Rename to match existing APK name and push to priv-app
    mkdir -p "$existing_dir"
    cp -f "$pa_work/personalassistant.apk" "${existing_dir}${existing_apk_name}"
    chmod 0644 "${existing_dir}${existing_apk_name}"
    log_success "[personalassistant] ✓ ${existing_apk_name} → priv-app/$folder_name/"

    rm -rf "$pa_work"

    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_success "✅ Personal Assistant APK pushed successfully"
    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    return 0
}

# =========================================================
#  4. DOWNLOAD & EXTRACT ROM
# =========================================================
# =========================================================
#  4. DOWNLOAD & EXTRACT ROM
# =========================================================
tg_progress "⬇️ **Downloading ROM...**"
log_step "📦 Downloading ROM..."
cd "$TEMP_DIR"
START_TIME=$(date +%s)
aria2c -x 16 -s 16 --file-allocation=none -o "rom.zip" "$ROM_URL" 2>&1 | grep -E "download completed|ERROR"
END_TIME=$(date +%s)
DOWNLOAD_TIME=$((END_TIME - START_TIME))
log_info "Download completed in ${DOWNLOAD_TIME}s"

if [ ! -f "rom.zip" ]; then 
    log_error "ROM download failed!"
    exit 1
fi

log_step "📂 Extracting ROM payload..."
unzip -qq -o "rom.zip" payload.bin && rm "rom.zip" 
log_success "Payload extracted"

log_success "Payload extracted"

tg_progress "📂 **Extracting Firmware...**"
log_step "🔍 Extracting firmware images..."
START_TIME=$(date +%s)
payload-dumper-go -o "$IMAGES_DIR" payload.bin > /dev/null 2>&1
END_TIME=$(date +%s)
EXTRACT_TIME=$((END_TIME - START_TIME))
rm payload.bin
log_success "Firmware extracted in ${EXTRACT_TIME}s"

# =========================================================
#  4.1. FIRMWARE LOGIC ENGINE
#  Classifies all extracted images into categories and generates
#  a partition manifest for dynamic flashing script generation.
# =========================================================
log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_step "🧠 FIRMWARE LOGIC ENGINE"
log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Super (logical) partitions — these get mounted, modified, repacked
SUPER_PARTITIONS="system system_ext product mi_ext vendor odm system_dlkm vendor_dlkm"

# Special partitions that do NOT use _ab suffix when flashing
NO_AB_PARTITIONS="cust super userdata persist"

# Partition manifest: <filename> <category> <flash_target> <size_bytes>
MANIFEST_FILE="$TEMP_DIR/partition_manifest.txt"
FIRMWARE_LIST=""
SUPER_LIST=""
> "$MANIFEST_FILE"

for img_file in "$IMAGES_DIR"/*.img; do
    [ ! -f "$img_file" ] && continue
    img_name=$(basename "$img_file" .img)
    img_size=$(stat -c%s "$img_file" 2>/dev/null || echo 0)
    img_size_mb=$((img_size / 1024 / 1024))

    # Classify
    is_super=0
    for sp in $SUPER_PARTITIONS; do
        [ "$img_name" == "$sp" ] && is_super=1 && break
    done

    if [ "$is_super" -eq 1 ]; then
        category="super"
        flash_target="$img_name"
        SUPER_LIST="$SUPER_LIST $img_name"
    else
        category="firmware"
        # Determine flash target name (most partitions use _ab suffix for VAB)
        is_no_ab=0
        for nab in $NO_AB_PARTITIONS; do
            [ "$img_name" == "$nab" ] && is_no_ab=1 && break
        done
        if [ "$is_no_ab" -eq 1 ]; then
            flash_target="$img_name"
        else
            flash_target="${img_name}_ab"
        fi
        FIRMWARE_LIST="$FIRMWARE_LIST $img_name"
    fi

    echo "$img_name $category $flash_target $img_size" >> "$MANIFEST_FILE"

    if [ "$category" == "super" ]; then
        log_info "  📦 ${img_name}.img → [SUPER]  (${img_size_mb}MB)"
    else
        log_info "  ⚡ ${img_name}.img → [FIRMWARE] flash as ${flash_target}  (${img_size_mb}MB)"
    fi
done

TOTAL_FW=$(echo $FIRMWARE_LIST | wc -w)
TOTAL_SP=$(echo $SUPER_LIST | wc -w)
log_success "✓ Classified $TOTAL_FW firmware + $TOTAL_SP super partitions"
log_info "Build mode: $BUILD_MODE"
log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# =========================================================
#  4.5. VBMETA VERIFICATION DISABLER (PROFESSIONAL)
# =========================================================
log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_step "🔓 VBMETA VERIFICATION DISABLER"
log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Create professional vbmeta patcher
cat > "$BIN_DIR/vbmeta_patcher.py" <<'PYTHON_EOF'
#!/usr/bin/env python3
import sys
import struct
import os

class VBMetaPatcher:
    """Professional AVB vbmeta image patcher"""
    
    AVB_MAGIC = b'AVB0'
    AVB_VERSION_MAJOR = 1
    AVB_VERSION_MINOR = 0
    
    # AVB Header offsets
    MAGIC_OFFSET = 0
    VERSION_MAJOR_OFFSET = 4
    VERSION_MINOR_OFFSET = 8
    FLAGS_OFFSET = 123  # Critical: flags field location
    
    # Flags to disable verification
    FLAG_VERIFICATION_DISABLED = 0x01
    FLAG_HASHTREE_DISABLED = 0x02
    DISABLE_FLAGS = FLAG_VERIFICATION_DISABLED | FLAG_HASHTREE_DISABLED  # 0x03
    
    def __init__(self, filepath):
        self.filepath = filepath
        self.original_size = os.path.getsize(filepath)
        
    def read_header(self):
        """Read and validate AVB header"""
        print(f"[ACTION] Reading vbmeta header from {os.path.basename(self.filepath)}")
        
        with open(self.filepath, 'rb') as f:
            # Read magic
            f.seek(self.MAGIC_OFFSET)
            magic = f.read(4)
            
            if magic != self.AVB_MAGIC:
                print(f"[ERROR] Invalid AVB magic: {magic.hex()} (expected: {self.AVB_MAGIC.hex()})")
                return False
            
            print(f"[SUCCESS] Valid AVB magic found: {magic.decode('ascii')}")
            
            # Read version
            f.seek(self.VERSION_MAJOR_OFFSET)
            major = struct.unpack('>I', f.read(4))[0]
            minor = struct.unpack('>I', f.read(4))[0]
            
            print(f"[INFO] AVB Version: {major}.{minor}")
            
            # Read current flags
            f.seek(self.FLAGS_OFFSET)
            current_flags = struct.unpack('B', f.read(1))[0]
            
            print(f"[INFO] Current flags at offset {self.FLAGS_OFFSET}: 0x{current_flags:02X}")
            
            if current_flags == self.DISABLE_FLAGS:
                print("[INFO] Verification already disabled")
                return True
            
            return True
    
    def patch(self):
        """Patch vbmeta to disable verification"""
        print(f"[ACTION] Patching flags at offset {self.FLAGS_OFFSET}")
        
        try:
            # Read entire file
            with open(self.filepath, 'rb') as f:
                data = bytearray(f.read())
            
            original_flag = data[self.FLAGS_OFFSET]
            print(f"[INFO] Original flag value: 0x{original_flag:02X}")
            
            # Set disable flags
            data[self.FLAGS_OFFSET] = self.DISABLE_FLAGS
            
            print(f"[ACTION] Setting new flag value: 0x{self.DISABLE_FLAGS:02X}")
            print(f"[INFO] Verification Disabled: {'YES' if self.DISABLE_FLAGS & 0x01 else 'NO'}")
            print(f"[INFO] Hashtree Disabled: {'YES' if self.DISABLE_FLAGS & 0x02 else 'NO'}")
            
            # Write back
            with open(self.filepath, 'wb') as f:
                f.write(data)
            
            print(f"[SUCCESS] Flags patched successfully")
            
            return True
            
        except Exception as e:
            print(f"[ERROR] Patching failed: {str(e)}")
            return False
    
    def verify(self):
        """Verify the patch was applied correctly"""
        print(f"[ACTION] Verifying patch...")
        
        with open(self.filepath, 'rb') as f:
            f.seek(self.FLAGS_OFFSET)
            patched_flag = struct.unpack('B', f.read(1))[0]
        
        if patched_flag == self.DISABLE_FLAGS:
            print(f"[SUCCESS] Verification complete: Flags = 0x{patched_flag:02X}")
            return True
        else:
            print(f"[ERROR] Verification failed: Flags = 0x{patched_flag:02X} (expected: 0x{self.DISABLE_FLAGS:02X})")
            return False
    
    def get_info(self):
        """Get image information"""
        size_kb = self.original_size / 1024
        size_mb = size_kb / 1024
        
        if size_mb >= 1:
            return f"{size_mb:.2f}M"
        else:
            return f"{size_kb:.2f}K"

def main():
    if len(sys.argv) != 2:
        print("[ERROR] Usage: vbmeta_patcher.py <vbmeta_image>")
        sys.exit(1)
    
    filepath = sys.argv[1]
    
    if not os.path.exists(filepath):
        print(f"[ERROR] File not found: {filepath}")
        sys.exit(1)
    
    patcher = VBMetaPatcher(filepath)
    
    # Show file info
    print(f"[INFO] File: {os.path.basename(filepath)}")
    print(f"[INFO] Size: {patcher.get_info()}")
    
    # Read and validate header
    if not patcher.read_header():
        print("[ERROR] Invalid vbmeta image")
        sys.exit(1)
    
    # Patch
    if not patcher.patch():
        print("[ERROR] Patching failed")
        sys.exit(1)
    
    # Verify
    if not patcher.verify():
        print("[ERROR] Verification failed")
        sys.exit(1)
    
    print("[SUCCESS] vbmeta patching completed successfully!")
    sys.exit(0)

if __name__ == "__main__":
    main()
PYTHON_EOF

chmod +x "$BIN_DIR/vbmeta_patcher.py"
log_success "✓ Professional vbmeta patcher ready"

# Patch vbmeta.img
tg_progress "🔓 **Disabling Verification...**"
VBMETA_IMG="$IMAGES_DIR/vbmeta.img"
if [ -f "$VBMETA_IMG" ]; then
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Patching vbmeta.img..."
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    if python3 "$BIN_DIR/vbmeta_patcher.py" "$VBMETA_IMG" 2>&1 | while IFS= read -r line; do
        if [[ "$line" == *"[ACTION]"* ]]; then
            log_info "${line#*[ACTION] }"
        elif [[ "$line" == *"[SUCCESS]"* ]]; then
            log_success "${line#*[SUCCESS] }"
        elif [[ "$line" == *"[ERROR]"* ]]; then
            log_error "${line#*[ERROR] }"
        elif [[ "$line" == *"[INFO]"* ]]; then
            log_info "${line#*[INFO] }"
        fi
    done; then
        log_success "✓ vbmeta.img patched successfully"
    else
        log_error "✗ vbmeta.img patching failed"
    fi
else
    log_warning "⚠️  vbmeta.img not found"
fi

# Patch vbmeta_system.img
VBMETA_SYSTEM_IMG="$IMAGES_DIR/vbmeta_system.img"
if [ -f "$VBMETA_SYSTEM_IMG" ]; then
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Patching vbmeta_system.img..."
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    if python3 "$BIN_DIR/vbmeta_patcher.py" "$VBMETA_SYSTEM_IMG" 2>&1 | while IFS= read -r line; do
        if [[ "$line" == *"[ACTION]"* ]]; then
            log_info "${line#*[ACTION] }"
        elif [[ "$line" == *"[SUCCESS]"* ]]; then
            log_success "${line#*[SUCCESS] }"
        elif [[ "$line" == *"[ERROR]"* ]]; then
            log_error "${line#*[ERROR] }"
        elif [[ "$line" == *"[INFO]"* ]]; then
            log_info "${line#*[INFO] }"
        fi
    done; then
        log_success "✓ vbmeta_system.img patched successfully"
    else
        log_error "✗ vbmeta_system.img patching failed"
    fi
else
    log_info "ℹ️  vbmeta_system.img not found (may not exist in this ROM)"
fi

log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_success "✅ AVB VERIFICATION DISABLED"
log_success "   Effect: Device will boot modified system partitions"
log_success "   Status: Secure Boot bypassed"
log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# =========================================================
#  5. PARTITION MODIFICATION LOOP
# =========================================================
# =========================================================
#  5. PARTITION MODIFICATION LOOP
# =========================================================
tg_progress "🔄 **Processing Partitions...**"
log_step "🔄 Processing Partitions..."
LOGICALS="system system_ext product mi_ext vendor odm"

for part in $LOGICALS; do
    if [ -f "$IMAGES_DIR/${part}.img" ]; then
        log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_step "Processing partition: ${part^^}"
        log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        DUMP_DIR="$GITHUB_WORKSPACE/${part}_dump"
        MNT_DIR="$GITHUB_WORKSPACE/mnt"
        
        # Ensure directories exist
        mkdir -p "$DUMP_DIR"
        mkdir -p "$MNT_DIR"
        
        # Ensure we're in workspace
        cd "$GITHUB_WORKSPACE"
        
        log_info "Mounting ${part}.img..."
        sudo erofsfuse "$IMAGES_DIR/${part}.img" "$MNT_DIR"
        if [ -z "$(sudo ls -A "$MNT_DIR")" ]; then
            log_error "Mount failed for ${part}!"
            sudo fusermount -uz "$MNT_DIR"
            continue
        fi
        log_success "Mounted successfully"
        
        log_info "Copying partition contents..."
        START_TIME=$(date +%s)
        sudo cp -a "$MNT_DIR/." "$DUMP_DIR/"
        sudo chown -R $(whoami) "$DUMP_DIR"
        END_TIME=$(date +%s)
        COPY_TIME=$((END_TIME - START_TIME))
        log_success "Contents copied in ${COPY_TIME}s"
        
        sudo fusermount -uz "$MNT_DIR"
        rm "$IMAGES_DIR/${part}.img"

        # A. DEBLOATER
        log_info "🗑️  Running debloater..."
        echo "$BLOAT_LIST" | tr ' ' '\n' | grep -v "^\s*$" > "$TEMP_DIR/bloat_target_list.txt"
        # Touch log first so wc -l never fails on missing file
        touch "$TEMP_DIR/removed_bloat.log"
        find "$DUMP_DIR" -type f -name "*.apk" | while read apk_file; do
            pkg_name=$(aapt dump badging "$apk_file" 2>/dev/null | grep "package: name=" | cut -d"'" -f2)
            if [ ! -z "$pkg_name" ]; then
                if grep -Fxq "$pkg_name" "$TEMP_DIR/bloat_target_list.txt"; then
                    rm -rf "$(dirname "$apk_file")"
                    echo "$pkg_name" >> "$TEMP_DIR/removed_bloat.log"
                    log_success "✓ Removed: $pkg_name"
                fi
            fi
        done
        REMOVED_COUNT=$(wc -l < "$TEMP_DIR/removed_bloat.log")
        log_success "Debloat complete: $REMOVED_COUNT apps removed"

        # B. GAPPS INJECTION
        if [ "$part" == "product" ] && [ -d "$GITHUB_WORKSPACE/gapps_src" ]; then
            log_info "🔵 Injecting GApps..."
            APP_ROOT="$DUMP_DIR/app"
            PRIV_ROOT="$DUMP_DIR/priv-app"
            mkdir -p "$APP_ROOT" "$PRIV_ROOT"
            
            P_APP="SoundPickerGoogle MiuiBiometric LatinImeGoogle GoogleTTS GooglePartnerSetup GeminiShell"
            P_PRIV="Velvet Phonesky MIUIPackageInstaller GoogleRestore GooglePartnerSetup Assistant AndroidAutoStub"
            
            install_gapp_logic "$P_PRIV" "$PRIV_ROOT"
            install_gapp_logic "$P_APP" "$APP_ROOT"
        fi

        # B2. MIUI MOD INJECTION (optional, triggered by MODS_SELECTED, product only)
        if [ "$part" == "product" ] && [ -n "$MODS_SELECTED" ]; then
            log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            log_step "🧩 MIUI MOD INJECTION"
            log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            log_info "Selected mods: $MODS_SELECTED"

            if [[ ",$MODS_SELECTED," == *",launcher,"* ]]; then
                inject_launcher_mod "$DUMP_DIR"
            fi
            if [[ ",$MODS_SELECTED," == *",thememanager,"* ]]; then
                inject_theme_mod "$DUMP_DIR"
            fi
            if [[ ",$MODS_SELECTED," == *",securitycenter,"* ]]; then
                inject_security_mod "$DUMP_DIR"
            fi
            if [[ ",$MODS_SELECTED," == *",multilang,"* ]]; then
                push_multilang "$DUMP_DIR"
            fi
            # Personal Assistant APK — always push when multilang is selected
            if [[ ",$MODS_SELECTED," == *",multilang,"* ]]; then
                push_personal_assistant "$DUMP_DIR"
            fi

            log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            log_success "✅ MOD INJECTION COMPLETE"
            log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        fi

        # C. MIUI BOOSTER - DEVICE LEVEL OVERRIDE (COMPLETE METHOD REPLACEMENT)
        if [ "$part" == "system_ext" ]; then
            log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            log_step "🚀 MIUIBOOSTER PERFORMANCE PATCH"
            log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            
            BOOST_JAR=$(find "$DUMP_DIR" -name "MiuiBooster.jar" -type f | head -n 1)
            
            if [ ! -z "$BOOST_JAR" ]; then
                log_info "Located: $BOOST_JAR"
                JAR_SIZE=$(du -h "$BOOST_JAR" | cut -f1)
                log_info "Original size: $JAR_SIZE"
                
                # Create backup
                log_info "Creating backup..."
                cp "$BOOST_JAR" "${BOOST_JAR}.bak"
                log_success "✓ Backup created: ${BOOST_JAR}.bak"
                
                # Setup working directory
                rm -rf "$TEMP_DIR/boost_work"
                mkdir -p "$TEMP_DIR/boost_work"
                cd "$TEMP_DIR/boost_work"
                
                # Decompile JAR
                log_info "Decompiling MiuiBooster.jar with apktool..."
                START_TIME=$(date +%s)
                
                if timeout 3m apktool d -r -f "$BOOST_JAR" -o "decompiled" 2>&1 | tee apktool_decompile.log | grep -q "I: Baksmaling"; then
                    END_TIME=$(date +%s)
                    DECOMPILE_TIME=$((END_TIME - START_TIME))
                    log_success "✓ Decompiled successfully in ${DECOMPILE_TIME}s"
                    
                    # Find target smali file
                    log_info "Searching for DeviceLevelUtils.smali..."
                    SMALI_FILE=$(find "decompiled" -type f -path "*/com/miui/performance/DeviceLevelUtils.smali" | head -n 1)
                    
                    if [ -f "$SMALI_FILE" ]; then
                        SMALI_REL_PATH=$(echo "$SMALI_FILE" | sed "s|decompiled/||")
                        log_success "✓ Found: $SMALI_REL_PATH"
                        
                        # Show original method preview
                        log_info "Extracting original method signature..."
                        ORIG_METHOD=$(grep -A 2 "\.method public initDeviceLevel()V" "$SMALI_FILE" | head -n 3)
                        if [ ! -z "$ORIG_METHOD" ]; then
                            log_info "Original method found:"
                            echo "$ORIG_METHOD" | while IFS= read -r line; do
                                log_info "  $line"
                            done
                        fi
                        
                        # Create Python patcher
                        log_info "Preparing method replacement patcher..."
                        cat > "patcher.py" <<'PYTHON_EOF'
import sys
import re

def patch_device_level(smali_file):
    """Replace initDeviceLevel method with performance-optimized version"""
    
    print(f"[ACTION] Reading {smali_file}")
    with open(smali_file, 'r', encoding='utf-8') as f:
        content = f.read()
    
    original_length = len(content)
    print(f"[ACTION] Original file size: {original_length} bytes")
    
    # New optimized method
    new_method = """.method public initDeviceLevel()V
    .registers 2

    const-string v0, "v:1,c:3,g:3"

    .line 130
    invoke-direct {p0, v0}, Lcom/miui/performance/DeviceLevelUtils;->parseDeviceLevelList(Ljava/lang/String;)V

    .line 140
    return-void
.end method"""
    
    # Pattern to match the entire initDeviceLevel method
    print("[ACTION] Searching for initDeviceLevel()V method...")
    pattern = r'\.method\s+public\s+initDeviceLevel\(\)V.*?\.end\s+method'
    
    matches = re.findall(pattern, content, flags=re.DOTALL)
    if matches:
        print(f"[ACTION] Found method (length: {len(matches[0])} bytes)")
        print("[ACTION] Original method structure:")
        # Show first few lines of original
        orig_lines = matches[0].split('\n')[:5]
        for line in orig_lines:
            print(f"         {line}")
        if len(matches[0].split('\n')) > 5:
            print(f"         ... (+{len(matches[0].split('\n')) - 5} more lines)")
    else:
        print("[ERROR] Method not found!")
        return False
    
    # Perform replacement
    print("[ACTION] Replacing method with optimized version...")
    new_content = re.sub(pattern, new_method, content, flags=re.DOTALL)
    
    if new_content != content:
        new_length = len(new_content)
        size_diff = original_length - new_length
        print(f"[ACTION] New file size: {new_length} bytes (reduced by {size_diff} bytes)")
        
        # Show new method preview
        print("[ACTION] New method structure:")
        for line in new_method.split('\n')[:8]:
            if line.strip():
                print(f"         {line}")
        
        print(f"[ACTION] Writing patched content to {smali_file}")
        with open(smali_file, 'w', encoding='utf-8') as f:
            f.write(new_content)
        
        print("[SUCCESS] Method replacement completed!")
        return True
    else:
        print("[ERROR] No changes made - pattern didn't match")
        return False

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("[ERROR] Usage: python3 patcher.py <smali_file>")
        sys.exit(1)
    
    smali_file = sys.argv[1]
    success = patch_device_level(smali_file)
    sys.exit(0 if success else 1)
PYTHON_EOF
                        
                        log_success "✓ Patcher ready"
                        
                        # Execute patcher
                        log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                        log_info "Executing method replacement..."
                        log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                        
                        if python3 "patcher.py" "$SMALI_FILE" 2>&1 | while IFS= read -r line; do
                            if [[ "$line" == *"[ACTION]"* ]]; then
                                log_info "${line#*[ACTION] }"
                            elif [[ "$line" == *"[SUCCESS]"* ]]; then
                                log_success "${line#*[SUCCESS] }"
                            elif [[ "$line" == *"[ERROR]"* ]]; then
                                log_error "${line#*[ERROR] }"
                            else
                                echo "         $line"
                            fi
                        done; then
                            PATCH_SUCCESS=true
                        else
                            PATCH_SUCCESS=false
                        fi
                        
                        if [ "$PATCH_SUCCESS" = true ]; then
                            log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                            log_success "✓ Method patched successfully!"
                            
                            # Verify the patch
                            log_info "Verifying patch..."
                            if grep -q 'const-string v0, "v:1,c:3,g:3"' "$SMALI_FILE"; then
                                log_success "✓ Verification passed: Device level string found"
                            else
                                log_error "✗ Verification failed: Device level string not found"
                            fi
                            
                            # Rebuild JAR
                            log_info "Rebuilding MiuiBooster.jar with apktool..."
                            START_TIME=$(date +%s)
                            
                            if timeout 3m apktool b -c "decompiled" -o "MiuiBooster_patched.jar" 2>&1 | tee apktool_build.log | grep -q "Built"; then
                                END_TIME=$(date +%s)
                                BUILD_TIME=$((END_TIME - START_TIME))
                                log_success "✓ Rebuild completed in ${BUILD_TIME}s"
                                
                                if [ -f "MiuiBooster_patched.jar" ]; then
                                    PATCHED_SIZE=$(du -h "MiuiBooster_patched.jar" | cut -f1)
                                    log_info "Patched JAR size: $PATCHED_SIZE"
                                    
                                    # Replace original
                                    log_info "Installing patched JAR..."
                                    mv "MiuiBooster_patched.jar" "$BOOST_JAR"
                                    log_success "✓ MiuiBooster.jar successfully patched!"
                                    
                                    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                                    log_success "✅ PERFORMANCE BOOST APPLIED"
                                    log_success "   Device Level: v:1 (Version 1)"
                                    log_success "   CPU Level: c:3 (High Performance)"
                                    log_success "   GPU Level: g:3 (High Performance)"
                                    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                                else
                                    log_error "✗ Patched JAR not found after build"
                                    log_info "Restoring original from backup..."
                                    cp "${BOOST_JAR}.bak" "$BOOST_JAR"
                                    log_warning "Original restored"
                                fi
                            else
                                log_error "✗ apktool build failed"
                                cat apktool_build.log | tail -20 | while IFS= read -r line; do
                                    log_error "   $line"
                                    done
                                log_info "Restoring original from backup..."
                                cp "${BOOST_JAR}.bak" "$BOOST_JAR"
                                log_warning "Original restored"
                            fi
                        else
                            log_error "✗ Method patching failed"
                            log_info "Restoring original from backup..."
                            cp "${BOOST_JAR}.bak" "$BOOST_JAR"
                            log_warning "Original restored"
                        fi
                    else
                        log_error "✗ DeviceLevelUtils.smali not found in JAR"
                        log_info "Expected path: */com/miui/performance/DeviceLevelUtils.smali"
                    fi
                else
                    END_TIME=$(date +%s)
                    DECOMPILE_TIME=$((END_TIME - START_TIME))
                    log_error "✗ Decompile failed or timed out (${DECOMPILE_TIME}s)"
                    
                    if [ -f "apktool_decompile.log" ]; then
                        log_error "Decompile errors:"
                        tail -10 apktool_decompile.log | while IFS= read -r line; do
                            log_error "   $line"
                        done
                    fi
                fi
                
                # Cleanup
                cd "$GITHUB_WORKSPACE"
                rm -rf "$TEMP_DIR/boost_work"
            else
                log_warning "⚠️  MiuiBooster.jar not found in system_ext partition"
                log_info "This may be normal for some ROM versions"
            fi
        fi


        # ═════════════════════════════════════════════════════════
        #  DEX PATCHING  (via dex_patcher.py)
        #  All calls: python3 $BIN_DIR/dex_patcher.py <cmd> <file>
        #  Output forwarded through the manager logger.
        # ═════════════════════════════════════════════════════════

        _run_dex_patch() {
            # _run_dex_patch <label> <command> <archive_path>
            local label="$1" cmd="$2" archive="$3"
            if [ "${SMALI_TOOLS_OK:-0}" -ne 1 ]; then
                log_warning "DEX patcher not ready — skipping $label"
                return 0
            fi
            if [ -z "$archive" ] || [ ! -f "$archive" ]; then
                log_warning "$label: archive not found (${archive:-<empty>})"
                return 0
            fi
            log_info "$label → $(basename "$archive")"
            # tg_progress removed as per user request
            python3 "$BIN_DIR/dex_patcher.py" "$cmd" "$archive" 2>&1 | \
            while IFS= read -r line; do
                case "$line" in
                    "[SUCCESS]"*) log_success "${line#[SUCCESS] }" ;;
                    "[WARNING]"*) log_warning "${line#[WARNING] }" ;;
                    "[ERROR]"*)   log_error   "${line#[ERROR] }"   ;;
                    "[INFO]"*)    log_info    "${line#[INFO] }"    ;;
                    *)            [ -n "$line" ] && log_info "$line" ;;
                esac
            done
            local rc=${PIPESTATUS[0]}
            [ $rc -ne 0 ] && log_error "$label failed (exit $rc)"
            return $rc
        }

        # ── system partition ──────────────────────────────────────
        if [ "$part" == "system" ]; then

            # D1. services.jar — suppress error dialogs
            #   Dynamic: scans ALL ActivityManagerService$$ExternalSyntheticLambda* classes
            #   for the one that calls showSystemReadyErrorDialogsIfNeeded and stubs its run().
            #   Falls back to stubbing showSystemReadyErrorDialogsIfNeeded directly in
            #   ActivityTaskManagerInternal if no lambda match found.
            _run_dex_patch "SERVICES DIALOGS" "services-jar" \
                "$(find "$DUMP_DIR" -path "*/framework/services.jar" -type f | head -n1)"
            cd "$GITHUB_WORKSPACE"

        fi

        # ── product partition ────────────────────────────────────────
        if [ "$part" == "product" ]; then

            # D2. AI Voice Recorder — exact path: product/data-app/...
            _RECORDER_APK=$(find "$DUMP_DIR" \
                -path "*/data-app/MIUISoundRecorderTargetSdk30/MIUISoundRecorderTargetSdk30.apk" \
                -type f | head -n1)
            if [ -z "$_RECORDER_APK" ]; then
                _RECORDER_APK=$(find "$DUMP_DIR" \
                    \( -name "MIUISoundRecorder*.apk" -o -name "SoundRecorder.apk" \) \
                    -type f | head -n1)
            fi
            _run_dex_patch "VOICE RECORDER AI" "voice-recorder-ai" "$_RECORDER_APK"
            cd "$GITHUB_WORKSPACE"

            # D3b. InCallUI — AI recording gate: RecorderUtils::isAiRecordEnable → true
            _run_dex_patch "INCALLUI AI" "incallui-ai" \
                "$(find "$DUMP_DIR" -path "*/priv-app/InCallUI/InCallUI.apk" -type f | head -n1)"
            cd "$GITHUB_WORKSPACE"

        fi

        # ── system_ext partition ──────────────────────────────────
        if [ "$part" == "system_ext" ]; then

            # B3. WIZARD APK — must live in system_ext/priv-app (not product)
            if [ -d "$GITHUB_WORKSPACE/gapps_src" ]; then
                _WIZ_SRC=$(find "$GITHUB_WORKSPACE/gapps_src" -name "Wizard.apk" -print -quit)
                if [ -f "$_WIZ_SRC" ]; then
                    mkdir -p "$DUMP_DIR/priv-app/Wizard"
                    cp "$_WIZ_SRC" "$DUMP_DIR/priv-app/Wizard/Wizard.apk"
                    chmod 644 "$DUMP_DIR/priv-app/Wizard/Wizard.apk"
                    log_success "✓ Wizard.apk → system_ext/priv-app/Wizard/"
                else
                    log_warning "Wizard.apk not found in gapps_src — skipping"
                fi
            fi

            # D3. Settings AI + Region unlock (IS_GLOBAL_BUILD in locale classes)
            _SETTINGS_APK="$(find "$DUMP_DIR" -name "Settings.apk" -type f | head -n1)"
            _run_dex_patch "SETTINGS AI"     "settings-ai"     "$_SETTINGS_APK"
            cd "$GITHUB_WORKSPACE"
            _run_dex_patch "SETTINGS REGION" "settings-region" "$_SETTINGS_APK"
            cd "$GITHUB_WORKSPACE"

            # D3c. Fold-Pager (optional — DEX + XML patches for fold screen settings)
            if [[ ",$MODS_SELECTED," == *",foldpager,"* ]]; then
                log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                log_step "📐 FOLD-PAGER: Settings.apk XML + DEX"
                log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

                # Step 1: Binary DEX patches (isSupportFoldScreenSettings + displayResourceTilesToScreen)
                _run_dex_patch "SETTINGS FOLDPAGER" "settings-foldpager" "$_SETTINGS_APK"
                cd "$GITHUB_WORKSPACE"

                # Step 2: Download individual XML assets from Multilang release by exact name
                _FP_WORK="$TEMP_DIR/foldpager_work"
                _FP_ASSETS="$TEMP_DIR/foldpager_assets"
                rm -rf "$_FP_WORK" "$_FP_ASSETS"
                mkdir -p "$_FP_ASSETS"
                _FP_OK=0

                log_info "[foldpager] Fetching XML assets from Multilang release..."
                _FP_API="https://api.github.com/repos/${GITHUB_REPOSITORY}/releases/tags/Multilang"
                _FP_RELEASE_JSON=$(curl -sSf -H "Authorization: token ${GITHUB_TOKEN}" \
                    -H "Accept: application/vnd.github.v3+json" "$_FP_API" 2>/dev/null)

                if [ -n "$_FP_RELEASE_JSON" ]; then
                    # Helper: download a single asset by exact filename
                    _fp_dl_asset() {
                        local asset_name="$1" dest="$2"
                        local asset_url
                        asset_url=$(echo "$_FP_RELEASE_JSON" | jq -r \
                            --arg name "$asset_name" \
                            '.assets[] | select(.name == $name) | .url' | head -n 1)
                        if [ -n "$asset_url" ] && [ "$asset_url" != "null" ]; then
                            curl -sSfL -H "Authorization: token ${GITHUB_TOKEN}" \
                                -H "Accept: application/octet-stream" \
                                -o "$dest" "$asset_url"
                            if [ -s "$dest" ]; then
                                log_success "[foldpager] ✓ Downloaded: $asset_name"
                                return 0
                            fi
                        fi
                        log_warning "[foldpager] Asset '$asset_name' not found or download failed"
                        return 1
                    }

                    # Download both XML files
                    _fp_dl_asset "fold_screen_settings.xml" "$_FP_ASSETS/fold_screen_settings.xml" && _FP_OK=1
                    _fp_dl_asset "ic_tablet_screen_settings.xml" "$_FP_ASSETS/ic_tablet_screen_settings.xml"
                else
                    log_error "[foldpager] Multilang release API request failed"
                fi

                # Step 3: Full apktool decode → XML replacement + editing → rebuild → inject
                if [ "$_FP_OK" -eq 1 ] && [ -n "$_SETTINGS_APK" ] && [ -f "$_SETTINGS_APK" ]; then
                    log_info "[foldpager] Decompiling Settings.apk (full resource decode)..."
                    rm -rf "$_FP_WORK"
                    if timeout 25m apktool d -f "$_SETTINGS_APK" -o "$_FP_WORK" >/dev/null 2>&1; then
                        log_success "[foldpager] ✓ Settings.apk decompiled"

                        # (Moved XML replacement to Step 4 post-rebuild because they are binary AXML)

                        # 3a. Edit settings_headers.xml — replace android:title on MiuiFoldSettings → "Nyxdroid"
                        _FP_HEADERS=$(find "$_FP_WORK" -name "settings_headers.xml" -path "*/res/xml/*" -type f | head -1)
                        if [ -n "$_FP_HEADERS" ]; then
                            python3 - "$_FP_HEADERS" <<'FP_EDIT_PY'
import sys, re

path = sys.argv[1]
with open(path, 'r', encoding='utf-8') as f:
    content = f.read()

# Find the element block containing MiuiFoldScreenSettings / MiuiFoldSettings
# and replace the existing android:title="@string/..." (or any value) with "Nyxdroid"

pat = re.compile(
    r'android:fragment="com\.android\.settings\.foldSettings\.MiuiFold(?:Screen)?Settings"',
)

if not pat.search(content):
    print("[INFO] MiuiFoldSettings fragment not found in settings_headers.xml")
    sys.exit(0)

lines = content.split('\n')
in_target_block = False
modified = False
result_lines = []

for line in lines:
    if 'MiuiFold' in line and 'fragment=' in line:
        in_target_block = True
    # Replace android:title on same line as fragment ref
    if 'MiuiFold' in line and 'android:title=' in line:
        line = re.sub(r'android:title="[^"]*"', 'android:title="Nyxdroid"', line)
        modified = True
        in_target_block = False
    # Replace android:title on a separate line within the same element block
    elif in_target_block and 'android:title=' in line:
        line = re.sub(r'android:title="[^"]*"', 'android:title="Nyxdroid"', line)
        modified = True
        in_target_block = False
    # Reset block tracking on element close
    if in_target_block and ('/>' in line or '</header>' in line or '</preference' in line):
        in_target_block = False
    result_lines.append(line)

if modified:
    with open(path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(result_lines))
    print("[SUCCESS] ✓ settings_headers.xml: android:title → \"Nyxdroid\"")
else:
    print("[WARNING] android:title not found near MiuiFoldSettings fragment")
FP_EDIT_PY
                            # Log output from Python editor
                            [ $? -eq 0 ] && log_success "[foldpager] settings_headers.xml edit complete" \
                                          || log_warning "[foldpager] settings_headers.xml edit returned non-zero"
                        else
                            log_warning "[foldpager] settings_headers.xml not found in decoded Settings.apk"
                        fi

                        # 3d. Download classes.dex from release and merge smali into Settings.apk
                        log_info "[foldpager] Fetching classes.dex from Multilang release..."
                        _FP_DEX_URL=$(echo "$_FP_RELEASE_JSON" | jq -r \
                            '.assets[] | select(.name == "classes.dex") | .url' | head -n 1)

                        if [ -n "$_FP_DEX_URL" ] && [ "$_FP_DEX_URL" != "null" ]; then
                            curl -sSfL -H "Authorization: token ${GITHUB_TOKEN}" \
                                -H "Accept: application/octet-stream" \
                                -o "$_FP_ASSETS/foldpager_classes.dex" "$_FP_DEX_URL"
                            if [ -s "$_FP_ASSETS/foldpager_classes.dex" ]; then
                                log_success "[foldpager] ✓ Downloaded: classes.dex"
                                
                                # Decode classes.dex to smali using a dummy APK
                                _FP_DUMMY="$TEMP_DIR/fp_dummy"
                                rm -rf "$_FP_DUMMY" && mkdir -p "$_FP_DUMMY"
                                cd "$_FP_DUMMY"
                                
                                unzip -q -j "$_SETTINGS_APK" AndroidManifest.xml -d . 2>/dev/null
                                cp -f "$_FP_ASSETS/foldpager_classes.dex" classes.dex
                                zip -q0 dummy.apk AndroidManifest.xml classes.dex 2>/dev/null
                                
                                log_info "[foldpager] Decompiling downloaded classes.dex to smali..."
                                if timeout 5m apktool d -r -f dummy.apk -o decoded >/dev/null 2>&1; then
                                    if [ -d "decoded/smali" ]; then
                                        log_info "[foldpager] Removing existing duplicate smali files across all smali* dirs..."
                                        find decoded/smali -name "*.smali" -type f | while read -r _new_smali; do
                                            _rel_path="${_new_smali#decoded/smali/}"
                                            # Find matching existing paths in all smali* dirs and remove them
                                            for _target_smali_dir in "$_FP_WORK"/smali*; do
                                                [ ! -d "$_target_smali_dir" ] && continue
                                                if [ -f "$_target_smali_dir/$_rel_path" ]; then
                                                    rm -f "$_target_smali_dir/$_rel_path"
                                                fi
                                            done
                                        done

                                        mkdir -p "$_FP_WORK/smali"
                                        cp -rf decoded/smali/* "$_FP_WORK/smali/" 2>/dev/null
                                        _SM_COUNT=$(find decoded/smali -name "*.smali" -type f | wc -l)
                                        log_success "[foldpager] ✓ smali/ — $_SM_COUNT smali files imported from classes.dex (duplicates removed)"
                                    else
                                        log_warning "[foldpager] No smali directory produced from classes.dex"
                                    fi
                                else
                                    log_warning "[foldpager] apktool failed to decompile classes.dex"
                                fi
                                cd "$GITHUB_WORKSPACE"
                            else
                                log_error "[foldpager] classes.dex download failed — zero bytes"
                                rm -f "$_FP_ASSETS/foldpager_classes.dex"
                            fi
                        else
                            log_info "[foldpager] classes.dex not found in release — skipping smali import"
                        fi

                        # Step 4: Rebuild and inject resources + DEX into original APK
                        log_info "[foldpager] Rebuilding Settings.apk..."
                        _FP_BUILD_LOG="$TEMP_DIR/fp_apktool_build.log"
                        rm -f "$_FP_BUILD_LOG"
                        if timeout 25m apktool b "$_FP_WORK" -o "${_SETTINGS_APK}.fp_build" >"$_FP_BUILD_LOG" 2>&1; then
                            if [ -f "${_SETTINGS_APK}.fp_build" ]; then
                                _FP_INJ="$TEMP_DIR/fp_inject"
                                rm -rf "$_FP_INJ" && mkdir -p "$_FP_INJ"
                                cd "$_FP_INJ"

                                # Extract DEX + resources from rebuilt APK
                                unzip -o "${_SETTINGS_APK}.fp_build" 'classes*.dex' 'res/*' 'resources.arsc' >/dev/null 2>&1



                                # Inject into original APK (resources.arsc + res/ + DEX)
                                _INJ_COUNT=0
                                if ls classes*.dex >/dev/null 2>&1; then
                                    zip -0 -u "$_SETTINGS_APK" classes*.dex >/dev/null 2>&1
                                    _INJ_COUNT=$((_INJ_COUNT + 1))
                                fi
                                if [ -f "resources.arsc" ]; then
                                    zip -0 -u "$_SETTINGS_APK" resources.arsc >/dev/null 2>&1
                                    _INJ_COUNT=$((_INJ_COUNT + 1))
                                fi
                                if [ -d "res" ]; then
                                    # Add all res entries built by apktool
                                    find res -type f | while read -r _rf; do
                                        zip -0 -u "$_SETTINGS_APK" "$_rf" >/dev/null 2>&1
                                    done
                                    _INJ_COUNT=$((_INJ_COUNT + 1))
                                fi

                                cd "$GITHUB_WORKSPACE"

                                # Inject binary AXML assets directly into the rebuilt APK
                                if [ -f "$_FP_ASSETS/fold_screen_settings.xml" ]; then
                                    # We need to zip it with relative path res/xml/...
                                    _TMP_RES="$TEMP_DIR/fp_res_xml"
                                    rm -rf "$_TMP_RES" && mkdir -p "$_TMP_RES/res/xml"
                                    cp -f "$_FP_ASSETS/fold_screen_settings.xml" "$_TMP_RES/res/xml/"
                                    cd "$_TMP_RES"
                                    zip -0 -u "$_SETTINGS_APK" res/xml/fold_screen_settings.xml >/dev/null 2>&1
                                    cd "$GITHUB_WORKSPACE"
                                    rm -rf "$_TMP_RES"
                                    log_success "[foldpager] ✓ Injected binary fold_screen_settings.xml"
                                fi
                                if [ -f "$_FP_ASSETS/ic_tablet_screen_settings.xml" ]; then
                                    _TMP_RES="$TEMP_DIR/fp_res_draw"
                                    rm -rf "$_TMP_RES" && mkdir -p "$_TMP_RES/res/drawable" "$_TMP_RES/res/drawable-night-v8"
                                    cp -f "$_FP_ASSETS/ic_tablet_screen_settings.xml" "$_TMP_RES/res/drawable/"
                                    cp -f "$_FP_ASSETS/ic_tablet_screen_settings.xml" "$_TMP_RES/res/drawable-night-v8/"
                                    cd "$_TMP_RES"
                                    zip -0 -u "$_SETTINGS_APK" res/drawable/ic_tablet_screen_settings.xml >/dev/null 2>&1
                                    zip -0 -u "$_SETTINGS_APK" res/drawable-night-v8/ic_tablet_screen_settings.xml >/dev/null 2>&1
                                    cd "$GITHUB_WORKSPACE"
                                    rm -rf "$_TMP_RES"
                                    log_success "[foldpager] ✓ Injected binary ic_tablet_screen_settings.xml"
                                fi
                                if [ -d "res" ]; then
                                    # Add all res entries
                                    find res -type f | while read _rf; do
                                        zip -0 -u "$_SETTINGS_APK" "$_rf" >/dev/null 2>&1
                                    done
                                    _INJ_COUNT=$((_INJ_COUNT + 1))
                                fi

                                cd "$GITHUB_WORKSPACE"

                                # Zipalign
                                _ZA=$(which zipalign 2>/dev/null || \
                                      find "$BIN_DIR/android-sdk" -name zipalign 2>/dev/null | head -1)
                                if [ -n "$_ZA" ]; then
                                    "$_ZA" -p -f 4 "$_SETTINGS_APK" "${_SETTINGS_APK}.aligned" \
                                        && mv "${_SETTINGS_APK}.aligned" "$_SETTINGS_APK" \
                                        && log_success "[foldpager] ✓ zipalign applied"
                                fi

                                rm -rf "$_FP_INJ"
                                log_success "[foldpager] ✓ Resources + DEX injected into Settings.apk"
                            else
                                log_error "[foldpager] Rebuilt APK not found"
                            fi
                            rm -f "${_SETTINGS_APK}.fp_build"
                        else
                            log_warning "[foldpager] apktool rebuild failed — XML patches skipped"
                            [ -s "$_FP_BUILD_LOG" ] && cat "$_FP_BUILD_LOG"
                            rm -f "${_SETTINGS_APK}.fp_build"
                        fi
                    else
                        log_warning "[foldpager] apktool decompile failed — XML patches skipped"
                    fi
                fi

                rm -rf "$_FP_WORK" "$_FP_ASSETS"
                cd "$GITHUB_WORKSPACE"

                log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                log_success "✅ FOLD-PAGER COMPLETE"
                log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            fi

            # D4b. OtherPersonalSettings — IS_GLOBAL_BUILD smali patch
            #   Binary walker mis-steps on this class's class_data → apktool smali sed.
            #   CRITICAL: after apktool b, inject ONLY patched DEX back into the
            #   original APK (zip -0 -u). Avoids apktool re-compressing resources.arsc
            #   which breaks the R+ 4-byte alignment requirement (error -124).
            log_info "🔧 OtherPersonalSettings: patching IS_GLOBAL_BUILD..."
            _OPS_WORK="$TEMP_DIR/ops_work"
            _OPS_DEX="$TEMP_DIR/ops_dex"
            rm -rf "$_OPS_WORK" "$_OPS_DEX"
            if timeout 25m apktool d -r -f "$_SETTINGS_APK" -o "$_OPS_WORK" >/dev/null 2>&1; then
                _OPS_FILES=$(find "$_OPS_WORK" -name "OtherPersonalSettings.smali" -type f)
                _OPS_NEED=0
                for _f in $_OPS_FILES; do
                    grep -q "IS_GLOBAL_BUILD" "$_f" && _OPS_NEED=1 && break
                done
                if [ "$_OPS_NEED" -eq 1 ]; then
                    for _f in $_OPS_FILES; do
                        sed -i                             's|sget-boolean p1, Lmiui/os/Build;->IS_GLOBAL_BUILD:Z|const/4 p1, 0x1|g'                             "$_f"
                    done
                    log_success "  ✓ IS_GLOBAL_BUILD replaced in OtherPersonalSettings.smali"
                    if timeout 25m apktool b -c "$_OPS_WORK" -o "${_SETTINGS_APK}.apkbuild" >/dev/null 2>&1; then
                        # Extract ONLY the patched DEX files from apktool output
                        mkdir -p "$_OPS_DEX"
                        cd "$_OPS_DEX"
                        unzip -o "${_SETTINGS_APK}.apkbuild" 'classes*.dex' >/dev/null 2>&1
                        _DEX_COUNT=$(ls classes*.dex 2>/dev/null | wc -l)
                        if [ "$_DEX_COUNT" -gt 0 ]; then
                            # Inject DEX-only into original APK — resources.arsc untouched
                            zip -0 -u "$_SETTINGS_APK" classes*.dex >/dev/null 2>&1
                            cd "$GITHUB_WORKSPACE"
                            # Re-align after DEX injection (DEX entries may shift offsets)
                            _ZA=$(which zipalign 2>/dev/null ||                                   find "$BIN_DIR/android-sdk" -name zipalign 2>/dev/null | head -1)
                            if [ -n "$_ZA" ]; then
                                "$_ZA" -p -f 4 "$_SETTINGS_APK" "${_SETTINGS_APK}.aligned"                                     && mv "${_SETTINGS_APK}.aligned" "$_SETTINGS_APK"                                     && log_success "  ✓ zipalign applied"
                            fi
                            log_success "✓ OtherPersonalSettings: DEX injected, resources.arsc preserved"
                        else
                            cd "$GITHUB_WORKSPACE"
                            log_warning "No DEX found in apktool output — OtherPersonalSettings skipped"
                        fi
                        rm -f "${_SETTINGS_APK}.apkbuild"
                    else
                        rm -f "${_SETTINGS_APK}.apkbuild"
                        log_warning "apktool rebuild failed — OtherPersonalSettings patch skipped"
                    fi
                else
                    log_info "  OtherPersonalSettings: IS_GLOBAL_BUILD not present"
                fi
            else
                log_warning "apktool decompile failed — OtherPersonalSettings skipped"
            fi
            rm -rf "$_OPS_WORK" "$_OPS_DEX"
            cd "$GITHUB_WORKSPACE"

            # D4. Provision GMS support
            _run_dex_patch "PROVISION GMS" "provision-gms" \
                "$(find "$DUMP_DIR" -name "Provision.apk" -type f | head -n1)"
            cd "$GITHUB_WORKSPACE"

            # D5. MIUI service CN→Global
            _run_dex_patch "MIUI SERVICE CN→GLOBAL" "miui-service" \
                "$(find "$DUMP_DIR" -name "miui-services.jar" -type f | head -n1)"
            cd "$GITHUB_WORKSPACE"

            # D6. SystemUI: VoLTE + QuickShare + WhatsApp notification fix
            _run_dex_patch "SYSTEMUI ALL" "systemui-volte" \
                "$(find "$DUMP_DIR" \( -name "MiuiSystemUI.apk" -o -name "SystemUI.apk" \) -type f | head -n1)"
            cd "$GITHUB_WORKSPACE"

            # D7. miui-framework: IS_INTERNATIONAL_BUILD(13 classes) + showSystemReadyErrorDialogsIfNeeded
            _FW_JAR="$(find "$DUMP_DIR" -name "miui-framework.jar" -type f | head -n1)"
            _run_dex_patch "MIUI FRAMEWORK" "miui-framework" "$_FW_JAR"
            cd "$GITHUB_WORKSPACE"

            # D8b. miui-framework: Gboard IME swap via apktool
            #   binary_swap_string can't inject a new string — Gboard package name is
            #   longer than Baidu's and not in the DEX string pool. apktool smali sed
            #   is the only reliable approach.
            if [ -n "$_FW_JAR" ]; then
                log_info "🎹 miui-framework: Gboard IME swap..."
                _FW_WORK="$TEMP_DIR/fw_smali"
                rm -rf "$_FW_WORK"
                _FW_APPLIED=0
                if timeout 20m apktool d -r -f "$_FW_JAR" -o "$_FW_WORK" >/dev/null 2>&1; then
                    # Patch 1a: InputMethodServiceInjector — Baidu → Gboard
                    _IMSI=$(find "$_FW_WORK" -name "InputMethodServiceInjector.smali" -type f | head -1)
                    if [ -n "$_IMSI" ] && grep -q "com\.baidu\.input_mi" "$_IMSI"; then
                        sed -i 's|com\.baidu\.input_mi|com.google.android.inputmethod.latin|g' "$_IMSI"
                        log_success "  ✓ Gboard swap in InputMethodServiceInjector"
                        _FW_APPLIED=1
                    else
                        log_info "  InputMethodServiceInjector: com.baidu.input_mi not present"
                    fi
                    # Patch 1b: InputMethodManagerStubImpl — Baidu → Gboard
                    #   Separate class from 1a; may or may not exist depending on build.
                    _IMMS=$(find "$_FW_WORK" -name "InputMethodManagerStubImpl.smali" -type f | head -1)
                    if [ -n "$_IMMS" ] && grep -q "com\.baidu\.input_mi" "$_IMMS"; then
                        sed -i 's|com\.baidu\.input_mi|com.google.android.inputmethod.latin|g' "$_IMMS"
                        log_success "  ✓ Gboard swap in InputMethodManagerStubImpl"
                        _FW_APPLIED=1
                    else
                        log_info "  InputMethodManagerStubImpl: com.baidu.input_mi not present"
                    fi
                    # Patch 2: showSystemReadyErrorDialogsIfNeeded → return-void
                    #   apktool fallback for builds where binary_patch_method misses it
                    #   (abstract base class with code_off=0 in ActivityTaskManagerInternal)
                    _SRED_FILE=$(grep -rl "showSystemReadyErrorDialogsIfNeeded" "$_FW_WORK"/smali* 2>/dev/null | head -1)
                    if [ -n "$_SRED_FILE" ]; then
                        python3 - "$_SRED_FILE" "showSystemReadyErrorDialogsIfNeeded" <<'SRED_PY'
import re, sys
path, method = sys.argv[1], sys.argv[2]
text = open(path).read()
pat = rf'(\.method[^
]*{re.escape(method)}[^
]*
).*?(\.end method)'
def stub(m):
    return m.group(1) + "    .registers 1
    return-void
" + m.group(2)
new = re.sub(pat, stub, text, flags=re.DOTALL)
if new != text:
    open(path,'w').write(new)
    print(f"[SUCCESS] ✓ {method} stubbed in {path}")
    sys.exit(0)
print(f"[INFO] {method} not found in {path}")
sys.exit(1)
SRED_PY
                        [ $? -eq 0 ] && _FW_APPLIED=1
                    fi
                    if [ "$_FW_APPLIED" -eq 1 ]; then
                        if timeout 20m apktool b -c "$_FW_WORK" -o "${_FW_JAR}.fwTmp" >/dev/null 2>&1; then
                            mv "${_FW_JAR}.fwTmp" "$_FW_JAR"
                            log_success "✓ miui-framework apktool patches applied"
                        else
                            rm -f "${_FW_JAR}.fwTmp"
                            log_warning "apktool build failed — miui-framework apktool patches skipped"
                        fi
                    else
                        log_info "  miui-framework: no apktool patches needed"
                    fi
                else
                    log_warning "apktool decompile failed — miui-framework apktool patches skipped"
                fi
                rm -rf "$_FW_WORK"
                cd "$GITHUB_WORKSPACE"
            fi

            # D8. nexdroid.rc — bootloader spoof init script
            log_info "💉 Writing nexdroid.rc bootloader spoof..."
            _INIT_DIR="$DUMP_DIR/etc/init"
            mkdir -p "$_INIT_DIR"
            cat > "$_INIT_DIR/nexdroid.rc" <<'NEXRC'
on init
    setprop ro.secureboot.devicelock "1"
    setprop ro.boot.veritymode "enforcing"
    setprop ro.boot.verifiedbootstate "green"
    setprop ro.vendor.boot.verifiedbootstate "green"
    setprop ro.boot.vbmeta.device_state "locked"
    setprop ro.boot.flash.locked "1"
    setprop ro.secureboot.lockstate "locked"
    setprop ro.vendor.boot.vbmeta.device_state "locked"
    setprop ro.boot.selinux "enforcing"
    setprop ro.build.tags "release-keys"
    setprop ro.boot.warranty_bit "0"
    setprop ro.vendor.boot.warranty_bit "0"
    setprop ro.vendor.warranty_bit "0"
    setprop ro.warranty_bit "0"
    setprop ro.is_ever_orange "0"
    setprop ro.build.type "user"
    setprop ro.debuggable "0"
    setprop ro.secure "1"
    setprop ro.crypto.state "encrypted"
    setprop ro.oem_unlock_supported "0"
    setprop ro.miui.support_miui_ime_bottom "1"
    setprop ro.opa.eligible_device "true"
    setprop ro.androidboot.flash.locked "1"
NEXRC
            log_success "✓ nexdroid.rc written to system_ext/etc/init/"

            # D10. cust_prop_white_keys_list — append allowlisted props
            _CUST_KEYS="$DUMP_DIR/etc/cust_prop_white_keys_list"
            if [ -f "$_CUST_KEYS" ]; then
                cat >> "$_CUST_KEYS" <<'CUSTKEYS'
ro.boot.vbmeta.device_state
ro.boot.verifiedbootstate
ro.boot.flash.locked
vendor.boot.verifiedbootstate
ro.boot.veritymode
vendor.boot.vbmeta.device_state
ro.boot.hwc
ro.secureboot.devicelock
ro.oem_unlock_supported
CUSTKEYS
                log_success "✓ cust_prop_white_keys_list updated"
            else
                log_warning "cust_prop_white_keys_list not found — skipping"
            fi

            # D10b. init.miui.ext.rc — launcher property fix
            #   Replace globallauncher (CN POCO launcher) with com.miui.home
            _MIUI_EXT_RC=$(find "$DUMP_DIR" -name "init.miui.ext.rc" -type f | head -1)
            if [ -n "$_MIUI_EXT_RC" ]; then
                if grep -q "com.mi.android.globallauncher" "$_MIUI_EXT_RC"; then
                    sed -i \
                        's|com\.mi\.android\.globallauncher|com.miui.home|g' \
                        "$_MIUI_EXT_RC"
                    log_success "✓ init.miui.ext.rc: launcher → com.miui.home"
                else
                    log_info "  init.miui.ext.rc: globallauncher not present (skip)"
                fi
            else
                log_warning "init.miui.ext.rc not found — launcher fix skipped"
            fi

            # D11. Region settings extra files (GDrive: locale XMLs → system_ext/cust)
            log_info "⬇ Downloading region settings files..."
            REGION_GD_ID="14fD0DMOzcN2hWSWDQas577wu7POoXv3c"
            if gdown "$REGION_GD_ID" -O "$TEMP_DIR/region_files.zip" --fuzzy -q 2>/dev/null; then
                mkdir -p "$DUMP_DIR/cust"
                unzip -qq -o "$TEMP_DIR/region_files.zip" -d "$DUMP_DIR/cust"
                rm -f "$TEMP_DIR/region_files.zip"
                log_success "✓ Region files pushed to system_ext/cust"
            else
                log_warning "Region files download failed — skipping"
            fi

        fi

        # G. NEXPACKAGE
        if [ "$part" == "product" ]; then
            log_info "📦 Injecting NexPackage assets..."
            PERM_DIR="$DUMP_DIR/etc/permissions"
            DEF_PERM_DIR="$DUMP_DIR/etc/default-permissions"
            OVERLAY_DIR="$DUMP_DIR/overlay"
            MEDIA_DIR="$DUMP_DIR/media"
            THEME_DIR="$DUMP_DIR/media/theme/default"
            
            mkdir -p "$PERM_DIR" "$DEF_PERM_DIR" "$OVERLAY_DIR" "$MEDIA_DIR" "$THEME_DIR"
            
            if [ -d "$GITHUB_WORKSPACE/nex_pkg" ]; then
                # Permissions
                DEF_XML="default-permissions-google.xml"
                if [ -f "$GITHUB_WORKSPACE/nex_pkg/$DEF_XML" ]; then
                    cp "$GITHUB_WORKSPACE/nex_pkg/$DEF_XML" "$DEF_PERM_DIR/"
                    chmod 644 "$DEF_PERM_DIR/$DEF_XML"
                    log_success "✓ Installed: $DEF_XML"
                fi
                
                PERM_COUNT=$(find "$GITHUB_WORKSPACE/nex_pkg" -maxdepth 1 -name "*.xml" ! -name "$DEF_XML" -exec cp {} "$PERM_DIR/" \; -print | wc -l)
                log_success "✓ Installed $PERM_COUNT permission files"
                
                # Overlays
                OVERLAY_COUNT=$(find "$GITHUB_WORKSPACE/nex_pkg" -maxdepth 1 -name "*.apk" -exec cp {} "$OVERLAY_DIR/" \; -print | wc -l)
                log_success "✓ Installed $OVERLAY_COUNT overlay APKs"
                
                # Boot animation
                if [ -f "$GITHUB_WORKSPACE/nex_pkg/bootanimation.zip" ]; then
                    cp "$GITHUB_WORKSPACE/nex_pkg/bootanimation.zip" "$MEDIA_DIR/"
                    log_success "✓ Installed: bootanimation.zip"
                fi
                
                # Lock wallpaper
                if [ -f "$GITHUB_WORKSPACE/nex_pkg/lock_wallpaper" ]; then
                    cp "$GITHUB_WORKSPACE/nex_pkg/lock_wallpaper" "$THEME_DIR/"
                    log_success "✓ Installed: lock_wallpaper"
                fi
                
                log_success "NexPackage assets injection complete"
            else
                log_warning "NexPackage directory not found"
            fi

            # H2. MIUI Uninstall Patcher (feb-x1.jar + feb-x1.xml + APK moves)
            log_info "🔧 Downloading MIUI uninstall patcher assets..."
            UNINSTALL_GD_ID="1lxkPJe5yn79Cb7YeoM3ScwjBD9TRWbYP"
            if gdown "$UNINSTALL_GD_ID" -O "$TEMP_DIR/uninstall_patch.zip" --fuzzy -q 2>/dev/null; then
                # Push feb-x1.jar → product/framework
                mkdir -p "$DUMP_DIR/framework"
                unzip -qq -p "$TEMP_DIR/uninstall_patch.zip" "feb-x1.jar"                     > "$DUMP_DIR/framework/feb-x1.jar" 2>/dev/null &&                     log_success "✓ feb-x1.jar → product/framework" ||                     log_warning "feb-x1.jar not found in zip"

                # Push feb-x1.xml → product/etc/permissions
                mkdir -p "$DUMP_DIR/etc/permissions"
                unzip -qq -p "$TEMP_DIR/uninstall_patch.zip" "feb-x1.xml"                     > "$DUMP_DIR/etc/permissions/feb-x1.xml" 2>/dev/null &&                     log_success "✓ feb-x1.xml → product/etc/permissions" ||                     log_warning "feb-x1.xml not found in zip"

                rm -f "$TEMP_DIR/uninstall_patch.zip"
            else
                log_warning "Uninstall patcher download failed — skipping"
            fi

            # Move MIUISecurityManager + MIUIThemeStore from data-app → app
            for _APK_NAME in MIUISecurityManager MIUIThemeStore; do
                _SRC_DIR="$DUMP_DIR/data-app/$_APK_NAME"
                _DST_DIR="$DUMP_DIR/app/$_APK_NAME"
                if [ -d "$_SRC_DIR" ]; then
                    mkdir -p "$DUMP_DIR/app"
                    mv "$_SRC_DIR" "$_DST_DIR"
                    log_success "✓ Moved: data-app/$_APK_NAME → app/"
                else
                    log_warning "$_APK_NAME not found in data-app — skipping move"
                fi
            done
        fi

        # H. BUILD PROPS — ONLY /product/build.prop (never vendor/odm/system/system_ext)
        log_info "📝 Adding custom build properties..."
        if [ "$part" == "product" ]; then
            PRODUCT_PROP="$DUMP_DIR/etc/build.prop"
            # Standard location is etc/build.prop inside the product partition dump
            if [ ! -f "$PRODUCT_PROP" ]; then
                PRODUCT_PROP="$DUMP_DIR/build.prop"
            fi
            if [ -f "$PRODUCT_PROP" ]; then
                echo "$PROPS_CONTENT" >> "$PRODUCT_PROP"
                log_success "✓ Updated: $PRODUCT_PROP"
            else
                log_error "✗ /product/build.prop not found — skipping props (will NOT fall back to other partitions)"
            fi
        else
            log_info "Skipping build.prop for partition '${part}' — only product partition is allowed"
        fi

        # H2. FSTAB PATCH (vendor only — AVB removal + ext4 fallback)
        if [ "$part" == "vendor" ]; then
            log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            log_step "🔧 VENDOR FSTAB PATCH (AVB + ext4 fallback)"
            log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            FSTAB_FOUND=0
            while IFS= read -r -d '' fstab_file; do
                FSTAB_FOUND=$((FSTAB_FOUND + 1))
                log_info "Patching: $(basename "$fstab_file")"
                python3 - "$fstab_file" << 'FSTAB_PATCH_PY'
import sys, re, os

fstab_path = sys.argv[1]
try:
    with open(fstab_path, 'r', encoding='utf-8') as f:
        lines = f.readlines()
except UnicodeDecodeError:
    with open(fstab_path, 'r', encoding='latin-1') as f:
        lines = f.readlines()

# Pre-scan: build set of (mount_point, fstype) pairs already in file
existing_pairs = set()
for line in lines:
    s = line.strip()
    if not s or s.startswith('#'):
        continue
    cols = s.split()
    if len(cols) >= 3:
        existing_pairs.add((cols[1], cols[2]))

# AVB flag patterns to remove from fs_mgr_flags
AVB_PATTERNS = [
    re.compile(r',?avb=vbmeta_system'),
    re.compile(r',?avb=vbmeta\b'),
    re.compile(r',?avb_keys=[^,]*'),
    re.compile(r',?(?<![a-z_])verify(?![a-z_])'),
    re.compile(r',?(?<![a-z_])avb(?![a-z_=])'),
]

output = []
changes = 0

for line in lines:
    stripped = line.strip()

    # Pass through comments, empty lines unchanged
    if not stripped or stripped.startswith('#'):
        output.append(line)
        continue

    all_tokens = stripped.split()
    if len(all_tokens) < 5:
        output.append(line)
        continue

    # Lines with >5 tokens can't be safely parsed (overlay, long firmware)
    # Pass through completely unchanged
    if len(all_tokens) > 5:
        output.append(line)
        continue

    # Exactly 5 tokens: src, mnt, fstype, mntopts, fsmgr
    src, mnt, fstype = all_tokens[0], all_tokens[1], all_tokens[2]
    fsmgr = all_tokens[4]

    # Only remove AVB from logical partition lines
    is_logical = 'logical' in fsmgr.split(',')

    # OP1: Remove AVB flags
    new_fsmgr = fsmgr
    for pat in AVB_PATTERNS:
        new_fsmgr = pat.sub('', new_fsmgr)

    new_fsmgr = re.sub(r'^,+', '', new_fsmgr)
    new_fsmgr = re.sub(r',+$', '', new_fsmgr)
    new_fsmgr = re.sub(r',{2,}', ',', new_fsmgr)
    if not new_fsmgr:
        new_fsmgr = 'defaults'

    modified = (new_fsmgr != fsmgr)

    if modified:
        # Replace only the last token in-place, preserving all whitespace
        last_start = stripped.rfind(fsmgr)
        if last_start >= 0:
            reconstructed = stripped[:last_start] + new_fsmgr
        else:
            reconstructed = stripped[:-len(fsmgr)] + new_fsmgr
        trailing = line[len(line.rstrip()):]
        if not trailing:
            trailing = '\n'
        output.append(reconstructed + trailing)
        changes += 1
    else:
        # NO changes — pass through original line EXACTLY
        output.append(line)

    # OP2: ext4 fallback for erofs logical partitions (only if no ext4 exists)
    if fstype == 'erofs' and is_logical:
        if (mnt, 'ext4') not in existing_pairs:
            ext4_fsmgr = new_fsmgr if modified else fsmgr
            ext4_line = f"{src:<56}{mnt:<23}{'ext4':<8}{'ro,barrier=1,discard':<53}{ext4_fsmgr}\n"
            output.append(ext4_line)
            changes += 1

if changes > 0:
    with open(fstab_path, 'w', encoding='utf-8', newline='\n') as f:
        f.writelines(output)
    print(f"PATCHED {changes} entries in {os.path.basename(fstab_path)}")
else:
    print(f"No changes in {os.path.basename(fstab_path)}")
FSTAB_PATCH_PY
            done < <(find "$DUMP_DIR" -name "fstab*" -type f -print0 2>/dev/null)

            if [ "$FSTAB_FOUND" -gt 0 ]; then
                log_success "✓ Vendor fstab patch: $FSTAB_FOUND files processed"
            else
                log_warning "⚠️ No fstab files found in vendor dump"
            fi
            log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        fi

        # I. REPACK
        log_info "📦 Repacking ${part} partition..."
        START_TIME=$(date +%s)
        sudo mkfs.erofs -zlz4hc,7 "$SUPER_DIR/${part}.img" "$DUMP_DIR" 2>&1 | grep -E "Build.*completed|ERROR"
        END_TIME=$(date +%s)
        REPACK_TIME=$((END_TIME - START_TIME))
        
        if [ -f "$SUPER_DIR/${part}.img" ]; then
            IMG_SIZE=$(du -h "$SUPER_DIR/${part}.img" | cut -f1)
            log_success "✓ Repacked ${part}.img (${IMG_SIZE}) in ${REPACK_TIME}s"
        else
            log_error "Failed to repack ${part}.img"
        fi
        
        sudo rm -rf "$DUMP_DIR"
    fi
done

# =========================================================
#  6. PACKAGING & UPLOAD
# =========================================================
log_step "📦 Creating Final Package..."
tg_progress "🗜️ **Packing ROM...**"
PACK_DIR="$OUTPUT_DIR/Final_Pack"

if [ "$BUILD_MODE" == "hybrid" ]; then
    # ─────────────────────────────────────────────────────────
    #  HYBRID ROM BUILD — Full fastboot-flashable package
    # ─────────────────────────────────────────────────────────
    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_step "🔧 HYBRID ROM BUILDER"
    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    mkdir -p "$PACK_DIR/images"

    # ── 6a. BUILD SUPER.IMG ──────────────────────────────────
    log_step "🔨 Building super.img..."
    tg_progress "🔨 **Building super.img (lpmake)...**"

    # Ensure lpmake + lpdump are available — download AOSP 15 prebuilt binaries
    if ! command -v lpmake &>/dev/null; then
        log_info "Installing lpmake + lpdump (AOSP 15 prebuilt)..."
        TOOLS_BASE_URL="https://raw.githubusercontent.com/Rprop/aosp15_partition_tools/main/linux_glibc_x86_64"
        LPMAKE_URL="$TOOLS_BASE_URL/lpmake"
        LPDUMP_URL="$TOOLS_BASE_URL/lpdump"
        IMG2SIMG_URL="$TOOLS_BASE_URL/img2simg"
        if curl -fsSL --retry 3 --connect-timeout 30 -o "$BIN_DIR/lpmake" "$LPMAKE_URL"; then
            chmod +x "$BIN_DIR/lpmake"
            sudo cp "$BIN_DIR/lpmake" /usr/local/bin/lpmake
            log_success "✓ lpmake installed to /usr/local/bin/"
        else
            log_error "✗ Failed to download lpmake binary"
            exit 1
        fi
        # lpdump — for post-build validation
        if curl -fsSL --retry 3 --connect-timeout 30 -o "$BIN_DIR/lpdump" "$LPDUMP_URL"; then
            chmod +x "$BIN_DIR/lpdump"
            sudo cp "$BIN_DIR/lpdump" /usr/local/bin/lpdump
            log_success "✓ lpdump installed to /usr/local/bin/"
        else
            log_warning "⚠️ lpdump download failed — post-build validation will be skipped"
        fi
        # Also grab img2simg as utility
        curl -fsSL --retry 3 -o "$BIN_DIR/img2simg" "$IMG2SIMG_URL" 2>/dev/null && \
            chmod +x "$BIN_DIR/img2simg" && sudo cp "$BIN_DIR/img2simg" /usr/local/bin/img2simg || true
    fi
    # Verify lpmake is functional (invoke without args — prints usage, returns non-zero but doesn't crash)
    if ! lpmake 2>&1 | grep -qi "usage\|option\|partition\|device"; then
        log_error "✗ lpmake binary is not functional on this system"
        exit 1
    fi
    log_success "✓ lpmake ready"

    SUPER_BUILD_DIR="$TEMP_DIR/super_build"
    mkdir -p "$SUPER_BUILD_DIR"

    # ── SMART SUPER.IMG SIZE CALCULATION ENGINE ──────────────
    # Each partition inside super.img is 4096-byte (block) aligned.
    # Exact sizing = sum of aligned partitions + geometry + metadata + safety buffer.
    BLOCK_SIZE=4096
    GEOMETRY_SIZE=4096     # LP_METADATA_GEOMETRY_SIZE — one block
    METADATA_SIZE=65536    # lpmake default
    # metadata is stored: primary(slot0) + primary(slot1) + backup(slot0) + backup(slot1)
    METADATA_TOTAL=$((METADATA_SIZE * 2 * 2))  # = 262144

    TOTAL_ALIGNED_SIZE=0
    LPMAKE_PARTS=""
    LPMAKE_IMAGES=""
    SUPER_PART_COUNT=0

    SUPER_TARGETS="system system_ext product mi_ext vendor odm system_dlkm vendor_dlkm"
    for sp in $SUPER_TARGETS; do
        sp_img=""
        if [ -f "$SUPER_DIR/${sp}.img" ]; then
            sp_img="$SUPER_DIR/${sp}.img"
        elif [ -f "$IMAGES_DIR/${sp}.img" ]; then
            sp_img="$IMAGES_DIR/${sp}.img"
        fi
        [ -z "$sp_img" ] && continue

        sp_size=$(stat -c%s "$sp_img" 2>/dev/null || echo 0)
        # Align each partition size up to BLOCK_SIZE
        sp_aligned=$(( (sp_size + BLOCK_SIZE - 1) / BLOCK_SIZE * BLOCK_SIZE ))
        sp_size_mb=$((sp_size / 1024 / 1024))
        TOTAL_ALIGNED_SIZE=$((TOTAL_ALIGNED_SIZE + sp_aligned))
        SUPER_PART_COUNT=$((SUPER_PART_COUNT + 1))

        # VAB: partition_a gets the image, partition_b is empty (size=0)
        LPMAKE_PARTS="$LPMAKE_PARTS --partition ${sp}_a:readonly:${sp_size}:main_a"
        LPMAKE_PARTS="$LPMAKE_PARTS --partition ${sp}_b:readonly:0:main_b"
        LPMAKE_IMAGES="$LPMAKE_IMAGES --image ${sp}_a=$sp_img"

        log_info "  📦 ${sp}.img → ${sp_size_mb}MB (aligned: ${sp_aligned})"
    done

    if [ "$SUPER_PART_COUNT" -eq 0 ]; then
        log_error "No super partitions found — cannot build super.img"
        exit 1
    fi

    # GROUP_SIZE: exact aligned total + 4MB overhead for internal lpmake bookkeeping
    GROUP_SIZE=$((TOTAL_ALIGNED_SIZE + 4 * 1024 * 1024))

    # DEVICE_SIZE: geometry + metadata + group data + 8MB safety buffer
    DEVICE_SIZE=$((GEOMETRY_SIZE + METADATA_TOTAL + GROUP_SIZE + 8 * 1024 * 1024))
    # Align device size to BLOCK_SIZE boundary
    DEVICE_SIZE=$(( (DEVICE_SIZE + BLOCK_SIZE - 1) / BLOCK_SIZE * BLOCK_SIZE ))

    TOTAL_MB=$((TOTAL_ALIGNED_SIZE / 1024 / 1024))
    GROUP_MB=$((GROUP_SIZE / 1024 / 1024))
    DEVICE_MB=$((DEVICE_SIZE / 1024 / 1024))
    log_info "Super Layout: ${SUPER_PART_COUNT} partitions | Data: ${TOTAL_MB}MB | Group: ${GROUP_MB}MB | Device: ${DEVICE_MB}MB"

    SUPER_RAW="$SUPER_BUILD_DIR/super.img"

    START_TIME=$(date +%s)
    LPMAKE_LOG="$TEMP_DIR/lpmake.log"
    lpmake \
        --metadata-size $METADATA_SIZE \
        --metadata-slots 2 \
        --device "super:${DEVICE_SIZE}" \
        --group "main_a:${GROUP_SIZE}" \
        --group "main_b:0" \
        $LPMAKE_PARTS \
        $LPMAKE_IMAGES \
        --sparse \
        --output "$SUPER_RAW" > "$LPMAKE_LOG" 2>&1
    LPMAKE_RC=$?

    # Show lpmake output
    while IFS= read -r line; do
        log_info "  lpmake: $line"
    done < "$LPMAKE_LOG"

    if [ $LPMAKE_RC -ne 0 ] || [ ! -f "$SUPER_RAW" ]; then
        log_error "✗ lpmake failed! (exit code: $LPMAKE_RC)"
        [ -f "$LPMAKE_LOG" ] && tail -5 "$LPMAKE_LOG" | while IFS= read -r l; do log_error "  $l"; done
        exit 1
    fi

    END_TIME=$(date +%s)
    BUILD_TIME=$((END_TIME - START_TIME))
    SUPER_SIZE=$(du -h "$SUPER_RAW" | cut -f1)
    log_success "✓ super.img built (${SUPER_SIZE}) in ${BUILD_TIME}s"

    # ── POST-BUILD VALIDATION WITH LPDUMP ────────────────────
    if command -v lpdump &>/dev/null; then
        log_info "Validating super.img with lpdump..."
        LPDUMP_LOG="$TEMP_DIR/lpdump.log"
        if lpdump "$SUPER_RAW" > "$LPDUMP_LOG" 2>&1; then
            DUMP_PARTS=$(grep -c "Name:" "$LPDUMP_LOG" 2>/dev/null || echo 0)
            DUMP_SIZE=$(grep "Super partition size:" "$LPDUMP_LOG" 2>/dev/null | head -1 || echo "")
            log_success "✓ lpdump validation passed ($DUMP_PARTS partitions found)"
            [ -n "$DUMP_SIZE" ] && log_info "  $DUMP_SIZE"
        else
            log_error "✗ lpdump validation FAILED — super.img may be corrupt!"
            log_error "  lpdump output:"
            tail -5 "$LPDUMP_LOG" | while IFS= read -r l; do log_error "    $l"; done
            rm -f "$SUPER_RAW"
            rm -f "$LPDUMP_LOG"
            tg_progress "❌ **super.img validation failed — aborting**"
            exit 1
        fi
        rm -f "$LPDUMP_LOG"
    else
        log_warning "⚠️ lpdump not available — skipping post-build validation"
    fi

    # Move raw super.img to images directory (no chunking)
    log_info "Moving super.img to package..."
    mv "$SUPER_RAW" "$PACK_DIR/images/super.img"
    log_success "✓ super.img → images/super.img"

    cd "$GITHUB_WORKSPACE"
    rm -rf "$SUPER_BUILD_DIR"

    # ── 6b. MOVE FIRMWARE IMAGES ─────────────────────────────
    log_info "Organizing firmware images..."
    FW_COUNT=0
    while IFS=' ' read -r img_name img_cat img_target img_sz; do
        [ "$img_cat" != "firmware" ] && continue
        if [ -f "$IMAGES_DIR/${img_name}.img" ]; then
            mv "$IMAGES_DIR/${img_name}.img" "$PACK_DIR/images/"
            FW_COUNT=$((FW_COUNT + 1))
        fi
    done < "$MANIFEST_FILE"
    log_success "✓ Moved $FW_COUNT firmware images"

    # ── 6c. DOWNLOAD PLATFORM TOOLS (bin/) ───────────────────
    log_step "⬇️  Downloading platform tools..."
    tg_progress "⬇️ **Downloading platform tools...**"
    TOOLS_DIR="$PACK_DIR/bin"
    mkdir -p "$TOOLS_DIR/windows" "$TOOLS_DIR/linux" "$TOOLS_DIR/macos"

    _download_platform_tools() {
        local os_name="$1" url="$2" subdir="$3"
        local zip_path="$TEMP_DIR/pt_${os_name}.zip"
        log_info "  $os_name → downloading..."
        if curl -fsSL --retry 3 --connect-timeout 30 -o "$zip_path" "$url" 2>/dev/null; then
            local extract_dir="$TEMP_DIR/pt_${os_name}"
            mkdir -p "$extract_dir"
            unzip -qq -o "$zip_path" -d "$extract_dir"
            # Find and copy fastboot + adb
            find "$extract_dir" -name "fastboot*" -type f -exec cp {} "$TOOLS_DIR/$subdir/" \;
            find "$extract_dir" -name "adb*" -type f -exec cp {} "$TOOLS_DIR/$subdir/" \;
            # Copy required shared libraries
            find "$extract_dir" \( -name "*.dll" -o -name "*.so" -o -name "*.dylib" \) -type f -exec cp {} "$TOOLS_DIR/$subdir/" \;
            chmod +x "$TOOLS_DIR/$subdir/"* 2>/dev/null
            rm -rf "$extract_dir" "$zip_path"
            log_success "  ✓ $os_name platform tools ready"
        else
            log_error "  ✗ $os_name platform tools download failed"
        fi
    }

    _download_platform_tools "windows" \
        "https://dl.google.com/android/repository/platform-tools-latest-windows.zip" "windows"
    _download_platform_tools "linux" \
        "https://dl.google.com/android/repository/platform-tools-latest-linux.zip" "linux"
    _download_platform_tools "macos" \
        "https://dl.google.com/android/repository/platform-tools-latest-darwin.zip" "macos"

    # ── 6d. GENERATE FLASHING SCRIPTS ────────────────────────
    log_step "📝 Generating flashing scripts..."
    tg_progress "📝 **Generating flashing scripts...**"

    # Collect firmware image flash commands from manifest
    FW_FLASH_LINES_BAT=""
    FW_FLASH_LINES_SH=""
    while IFS=' ' read -r img_name img_cat img_target img_sz; do
        [ "$img_cat" != "firmware" ] && continue
        # Skip super chunks — handled separately
        [ "$img_name" == "super" ] && continue
        FW_FLASH_LINES_BAT="${FW_FLASH_LINES_BAT}
echo   %%PB%%  Flashing ${img_name}...
%%fastboot%% flash ${img_target} images\\${img_name}.img || goto :error"
        FW_FLASH_LINES_SH="${FW_FLASH_LINES_SH}
echo \"   ⚡  Flashing ${img_name}...\"
\$FASTBOOT flash ${img_target} images/${img_name}.img || exit_error \"Failed to flash ${img_name}\""
    done < "$MANIFEST_FILE"

    # Single super.img flash command (no chunks)
    SUPER_FLASH_BAT="
echo   %%PB%%  Flashing super.img...
%%fastboot%% flash super images\\super.img || goto :error"
    SUPER_FLASH_SH="
echo \"   ⚡  Flashing super.img...\"
\$FASTBOOT flash super images/super.img || exit_error \"Failed to flash super.img\""

    # ═══════════════════════════════════════════════════════════
    # WINDOWS SCRIPTS
    # ═══════════════════════════════════════════════════════════

    # --- Windows Clean Flash ---
    cat > "$PACK_DIR/windows_clean_flash.bat" << 'WINCLEAN_EOF'
@echo off
setlocal enabledelayedexpansion
cd /d %~dp0
title nexdroid.build // Clean Flash
color 0B

echo.
echo  ╔══════════════════════════════════════════════════════════════╗
echo  ║                                                              ║
echo  ║     ███╗   ██╗███████╗██╗  ██╗██████╗ ██████╗  ██████╗ ██╗██████╗  ║
echo  ║     ████╗  ██║██╔════╝╚██╗██╔╝██╔══██╗██╔══██╗██╔═══██╗██║██╔══██╗ ║
echo  ║     ██╔██╗ ██║█████╗   ╚███╔╝ ██║  ██║██████╔╝██║   ██║██║██║  ██║ ║
echo  ║     ██║╚██╗██║██╔══╝   ██╔██╗ ██║  ██║██╔══██╗██║   ██║██║██║  ██║ ║
echo  ║     ██║ ╚████║███████╗██╔╝ ██╗██████╔╝██║  ██║╚██████╔╝██║██████╔╝ ║
echo  ║     ╚═╝  ╚═══╝╚══════╝╚═╝  ╚═╝╚═════╝ ╚═╝  ╚═╝ ╚═════╝ ╚═╝╚═════╝  ║
echo  ║                                                              ║
echo  ║  ─────────────────── nexdroid.build ───────────────────────  ║
echo  ║                     CLEAN FLASH MODE                         ║
echo  ║  ────────────────────────────────────────────────────────── ║
echo  ╚══════════════════════════════════════════════════════════════╝
echo.

set PB=^>^>
set fastboot=bin\windows\fastboot.exe
if not exist %fastboot% (
    echo  [ERROR] %fastboot% not found!
    echo  Make sure the bin folder is intact.
    pause
    exit /B 1
)

echo  [*] Waiting for device in fastboot mode...
%fastboot% devices 2>nul | findstr /r "." >nul
if errorlevel 1 (
    echo  [!] No device found. Please connect your device in fastboot mode.
    pause
    exit /B 1
)

set device=
for /f "tokens=2" %%A in ('%fastboot% getvar product 2^>^&1 ^| findstr "\<product:"') do set device=%%A
if "%device%" equ "" (
    echo  [!] Could not detect device codename.
    pause
    exit /B 1
)
echo  [*] Device detected: %device%

WINCLEAN_EOF

    # Inject device check
    echo "if \"%device%\" neq \"$DEVICE_CODE\" (" >> "$PACK_DIR/windows_clean_flash.bat"
    cat >> "$PACK_DIR/windows_clean_flash.bat" << WINCLEAN2_EOF
    echo  [!] Incompatible device! Expected: $DEVICE_CODE
    pause
    exit /B 1
)

echo.
echo  ╔══════════════════════════════════════════════════════════════╗
echo  ║  WARNING: CLEAN FLASH will erase ALL data on your device!    ║
echo  ║  This includes apps, settings, and internal storage.         ║
echo  ║  Make sure you have a backup before continuing.              ║
echo  ╚══════════════════════════════════════════════════════════════╝
echo.
set /p choice=  Do you want to continue? [y/N] 
if /i "%choice%" neq "y" exit /B 0

echo.
echo  ══════════════════════════════════════════════════════════════
echo   nexdroid.build // Flashing in progress — DO NOT DISCONNECT
echo  ══════════════════════════════════════════════════════════════
echo.

%fastboot% set_active a
echo   %PB%  Slot A activated
$FW_FLASH_LINES_BAT
$SUPER_FLASH_BAT

echo.
echo   %PB%  Erasing metadata...
%fastboot% erase metadata
echo   %PB%  Erasing userdata...
%fastboot% erase userdata

echo.
echo  ══════════════════════════════════════════════════════════════
echo   nexdroid.build // Flash complete — rebooting device...
echo  ══════════════════════════════════════════════════════════════
%fastboot% reboot
echo.
echo   [DONE] Your device will now reboot. First boot may take a while.
pause
exit /B 0

:error
echo.
echo  [ERROR] Flashing failed! Please check the error above.
pause
exit /B 1
WINCLEAN2_EOF
    log_success "✓ windows_clean_flash.bat"

    # --- Windows Dirty Flash ---
    cat > "$PACK_DIR/windows_dirty_flash_upgrade.bat" << 'WINDIRTY_EOF'
@echo off
setlocal enabledelayedexpansion
cd /d %~dp0
title nexdroid.build // Dirty Flash Upgrade
color 0A

echo.
echo  ╔══════════════════════════════════════════════════════════════╗
echo  ║                                                              ║
echo  ║     ███╗   ██╗███████╗██╗  ██╗██████╗ ██████╗  ██████╗ ██╗██████╗  ║
echo  ║     ████╗  ██║██╔════╝╚██╗██╔╝██╔══██╗██╔══██╗██╔═══██╗██║██╔══██╗ ║
echo  ║     ██╔██╗ ██║█████╗   ╚███╔╝ ██║  ██║██████╔╝██║   ██║██║██║  ██║ ║
echo  ║     ██║╚██╗██║██╔══╝   ██╔██╗ ██║  ██║██╔══██╗██║   ██║██║██║  ██║ ║
echo  ║     ██║ ╚████║███████╗██╔╝ ██╗██████╔╝██║  ██║╚██████╔╝██║██████╔╝ ║
echo  ║     ╚═╝  ╚═══╝╚══════╝╚═╝  ╚═╝╚═════╝ ╚═╝  ╚═╝ ╚═════╝ ╚═╝╚═════╝  ║
echo  ║                                                              ║
echo  ║  ─────────────────── nexdroid.build ───────────────────────  ║
echo  ║                  DIRTY FLASH / UPGRADE MODE                  ║
echo  ║  ────────────────────────────────────────────────────────── ║
echo  ╚══════════════════════════════════════════════════════════════╝
echo.

set PB=^>^>
set fastboot=bin\windows\fastboot.exe
if not exist %fastboot% (
    echo  [ERROR] %fastboot% not found!
    pause
    exit /B 1
)

echo  [*] Waiting for device in fastboot mode...
%fastboot% devices 2>nul | findstr /r "." >nul
if errorlevel 1 (
    echo  [!] No device found. Please connect your device in fastboot mode.
    pause
    exit /B 1
)

set device=
for /f "tokens=2" %%A in ('%fastboot% getvar product 2^>^&1 ^| findstr "\<product:"') do set device=%%A
if "%device%" equ "" (
    echo  [!] Could not detect device codename.
    pause
    exit /B 1
)
echo  [*] Device detected: %device%

WINDIRTY_EOF

    echo "if \"%device%\" neq \"$DEVICE_CODE\" (" >> "$PACK_DIR/windows_dirty_flash_upgrade.bat"
    cat >> "$PACK_DIR/windows_dirty_flash_upgrade.bat" << WINDIRTY2_EOF
    echo  [!] Incompatible device! Expected: $DEVICE_CODE
    pause
    exit /B 1
)

echo.
echo  ╔══════════════════════════════════════════════════════════════╗
echo  ║  DIRTY FLASH: Your data, apps, and settings will be kept.    ║
echo  ║  Use this when upgrading from a previous nexdroid build.     ║
echo  ╚══════════════════════════════════════════════════════════════╝
echo.
set /p choice=  Do you want to continue? [y/N] 
if /i "%choice%" neq "y" exit /B 0

echo.
echo  ══════════════════════════════════════════════════════════════
echo   nexdroid.build // Flashing in progress — DO NOT DISCONNECT
echo  ══════════════════════════════════════════════════════════════
echo.

%fastboot% set_active a
echo   %PB%  Slot A activated
$FW_FLASH_LINES_BAT
$SUPER_FLASH_BAT

echo.
echo  ══════════════════════════════════════════════════════════════
echo   nexdroid.build // Flash complete — rebooting device...
echo  ══════════════════════════════════════════════════════════════
%fastboot% reboot
echo.
echo   [DONE] Your device will now reboot. First boot may take a while.
pause
exit /B 0

:error
echo.
echo  [ERROR] Flashing failed! Please check the error above.
pause
exit /B 1
WINDIRTY2_EOF
    log_success "✓ windows_dirty_flash_upgrade.bat"

    # ═══════════════════════════════════════════════════════════
    # LINUX SCRIPTS
    # ═══════════════════════════════════════════════════════════

    _generate_unix_script() {
        local filepath="$1" mode_label="$2" is_clean="$3" os_label="$4" fb_path="$5"

        cat > "$filepath" << 'UNIX_HEADER'
#!/bin/bash
# ═══════════════════════════════════════════════════════════
#  nexdroid.build — Fastboot Flasher
# ═══════════════════════════════════════════════════════════
set -e

cd "$(dirname "$0")"

# ── Colors ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

banner() {
    echo -e "${CYAN}"
    echo "  ╔══════════════════════════════════════════════════════════╗"
    echo "  ║                                                          ║"
    echo "  ║   ███╗   ██╗███████╗██╗  ██╗██████╗ ██████╗  ██████╗    ║"
    echo "  ║   ████╗  ██║██╔════╝╚██╗██╔╝██╔══██╗██╔══██╗██╔═══██╗   ║"
    echo "  ║   ██╔██╗ ██║█████╗   ╚███╔╝ ██║  ██║██████╔╝██║   ██║   ║"
    echo "  ║   ██║╚██╗██║██╔══╝   ██╔██╗ ██║  ██║██╔══██╗██║   ██║   ║"
    echo "  ║   ██║ ╚████║███████╗██╔╝ ██╗██████╔╝██║  ██║╚██████╔╝   ║"
    echo "  ║   ╚═╝  ╚═══╝╚══════╝╚═╝  ╚═╝╚═════╝ ╚═╝  ╚═╝ ╚═════╝    ║"
    echo "  ║                                                          ║"
    echo "  ║  ───────────────── nexdroid.build ─────────────────────  ║"
UNIX_HEADER

        if [ "$is_clean" == "1" ]; then
            echo '    echo "  ║                   CLEAN FLASH MODE                      ║"' >> "$filepath"
        else
            echo '    echo "  ║               DIRTY FLASH / UPGRADE MODE                ║"' >> "$filepath"
        fi

        cat >> "$filepath" << 'UNIX_HEADER2'
    echo "  ║  ────────────────────────────────────────────────────  ║"
    echo "  ╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

exit_error() {
    echo -e "${RED}  [ERROR] $1${NC}"
    exit 1
}

banner
UNIX_HEADER2

        # Fastboot path and device detection
        cat >> "$filepath" << UNIX_DETECT
FASTBOOT="$fb_path"
if [ ! -f "\$FASTBOOT" ]; then
    # Fallback to system fastboot
    FASTBOOT=\$(which fastboot 2>/dev/null || true)
    [ -z "\$FASTBOOT" ] && exit_error "fastboot not found! Make sure the bin folder is intact."
fi
chmod +x "\$FASTBOOT" 2>/dev/null

echo -e "\${CYAN}  [*] Waiting for device in fastboot mode...\${NC}"
if ! \$FASTBOOT devices 2>/dev/null | grep -q "fastboot"; then
    exit_error "No device found. Please connect your device in fastboot mode."
fi

DEVICE=\$(\$FASTBOOT getvar product 2>&1 | grep "product:" | awk '{print \$2}')
[ -z "\$DEVICE" ] && exit_error "Could not detect device codename."
echo -e "\${GREEN}  [*] Device detected: \${BOLD}\$DEVICE\${NC}"

if [ "\$DEVICE" != "$DEVICE_CODE" ]; then
    exit_error "Incompatible device! Expected: $DEVICE_CODE, Got: \$DEVICE"
fi

UNIX_DETECT

        # Mode-specific warning
        if [ "$is_clean" == "1" ]; then
            cat >> "$filepath" << 'UNIX_WARN_CLEAN'
echo ""
echo -e "${YELLOW}  ╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}  ║  WARNING: CLEAN FLASH will erase ALL data!               ║${NC}"
echo -e "${YELLOW}  ║  This includes apps, settings, and internal storage.      ║${NC}"
echo -e "${YELLOW}  ╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
read -p "  Do you want to continue? [y/N] " choice
[[ ! "$choice" =~ ^[Yy]$ ]] && exit 0
UNIX_WARN_CLEAN
        else
            cat >> "$filepath" << 'UNIX_WARN_DIRTY'
echo ""
echo -e "${GREEN}  ╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}  ║  DIRTY FLASH: Your data, apps, and settings will be kept.║${NC}"
echo -e "${GREEN}  ║  Use this when upgrading from a previous nexdroid build.  ║${NC}"
echo -e "${GREEN}  ╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
read -p "  Do you want to continue? [y/N] " choice
[[ ! "$choice" =~ ^[Yy]$ ]] && exit 0
UNIX_WARN_DIRTY
        fi

        # Flashing body
        cat >> "$filepath" << 'UNIX_FLASH_START'
echo ""
echo -e "${MAGENTA}  ══════════════════════════════════════════════════════════${NC}"
echo -e "${MAGENTA}   nexdroid.build // Flashing — DO NOT DISCONNECT${NC}"
echo -e "${MAGENTA}  ══════════════════════════════════════════════════════════${NC}"
echo ""

$FASTBOOT set_active a
echo -e "${GREEN}   ⚡  Slot A activated${NC}"
UNIX_FLASH_START

        # Firmware flash lines
        echo "$FW_FLASH_LINES_SH" >> "$filepath"
        # Super chunk flash lines
        echo "$SUPER_FLASH_SH" >> "$filepath"

        # Post-flash
        if [ "$is_clean" == "1" ]; then
            cat >> "$filepath" << 'UNIX_CLEAN_POST'

echo ""
echo -e "${YELLOW}   ⚡  Erasing metadata...${NC}"
$FASTBOOT erase metadata
echo -e "${YELLOW}   ⚡  Erasing userdata...${NC}"
$FASTBOOT erase userdata
UNIX_CLEAN_POST
        fi

        cat >> "$filepath" << 'UNIX_FOOTER'

echo ""
echo -e "${GREEN}  ══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}   nexdroid.build // Flash complete — rebooting device...${NC}"
echo -e "${GREEN}  ══════════════════════════════════════════════════════════${NC}"
$FASTBOOT reboot
echo ""
echo -e "${GREEN}   [DONE] Your device will now reboot. First boot may take a while.${NC}"
UNIX_FOOTER

        chmod +x "$filepath"
    }

    _generate_unix_script "$PACK_DIR/linux_clean_flash.sh" "Clean Flash" "1" "Linux" "bin/linux/fastboot"
    log_success "✓ linux_clean_flash.sh"
    _generate_unix_script "$PACK_DIR/linux_dirty_flash_upgrade.sh" "Dirty Flash" "0" "Linux" "bin/linux/fastboot"
    log_success "✓ linux_dirty_flash_upgrade.sh"
    _generate_unix_script "$PACK_DIR/macos_clean_flash.sh" "Clean Flash" "1" "macOS" "bin/macos/fastboot"
    log_success "✓ macos_clean_flash.sh"
    _generate_unix_script "$PACK_DIR/macos_dirty_flash_upgrade.sh" "Dirty Flash" "0" "macOS" "bin/macos/fastboot"
    log_success "✓ macos_dirty_flash_upgrade.sh"

    # ── 6e. META-INF (Recovery Flashing) ─────────────────────
    log_step "📜 Generating META-INF recovery scripts..."
    tg_progress "📜 **Generating recovery scripts...**"
    META_GOOGLE="$PACK_DIR/META-INF/com/google/android"
    META_ANDROID="$PACK_DIR/META-INF/com/android"
    mkdir -p "$META_GOOGLE" "$META_ANDROID"

    # update-binary (self-contained shell script — standard for custom ROMs)
    # This is the entry point called by TWRP/OrangeFox/SHRP recovery.
    # It handles all flashing logic directly — no external EDIFY binary needed.
    cat > "$META_GOOGLE/update-binary" << 'UPDATE_BINARY_EOF'
#!/sbin/sh
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  nexdroid.build — Recovery Installer
#  Shell-based update-binary (no EDIFY needed)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

OUTFD="/proc/self/fd/$2"
ZIPFILE="$3"

# ── Output helpers ──
ui_print() { echo -e "ui_print $1\nui_print" >> "$OUTFD"; }
set_progress() { echo "set_progress $1" >> "$OUTFD"; }
abort() { ui_print ""; ui_print "❌ ERROR: $1"; ui_print ""; exit 1; }

# ── Banner ──
ui_print ""
ui_print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ui_print "    ✦ nexdroid.build ✦"
ui_print "    Recovery ROM Installer"
ui_print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ui_print ""

DEVICE=$(getprop ro.product.device 2>/dev/null)
ui_print "  📱 Device: $DEVICE"
ui_print ""
set_progress 0.0

# ── Extract images to tmp ──
TMP="/tmp/nexdroid_install"
rm -rf "$TMP" && mkdir -p "$TMP"

ui_print "  📦 Extracting images from zip..."
set_progress 0.05
unzip -o -q "$ZIPFILE" "images/*" -d "$TMP" 2>/dev/null || abort "Failed to extract images from zip!"

IMG_DIR="$TMP/images"
[ ! -d "$IMG_DIR" ] && abort "images/ directory not found in zip!"

# Count total images
TOTAL=$(find "$IMG_DIR" -maxdepth 1 -name "*.img" -type f | wc -l)
[ "$TOTAL" -eq 0 ] && abort "No .img files found in images/ directory!"
ui_print "  Found $TOTAL image(s) to flash"
ui_print ""

# ── Determine block device path ──
# Try common paths used by Xiaomi/Qualcomm devices
if [ -d "/dev/block/bootdevice/by-name" ]; then
    BLOCK_PATH="/dev/block/bootdevice/by-name"
elif [ -d "/dev/block/by-name" ]; then
    BLOCK_PATH="/dev/block/by-name"
else
    abort "Could not find block device path!"
fi
ui_print "  🔧 Block path: $BLOCK_PATH"
ui_print ""

# ── Logical partitions (inside super — skip these) ──
SKIP_LIST="system system_ext product vendor odm mi_ext system_dlkm vendor_dlkm"

is_logical() {
    for s in $SKIP_LIST; do
        [ "$1" = "$s" ] && return 0
    done
    return 1
}

# ── Flash all images ──
ui_print "  ⚡ Flashing partitions..."
ui_print "  ─────────────────────────"
CURRENT=0
for img in "$IMG_DIR"/*.img; do
    [ ! -f "$img" ] && continue
    IMGNAME=$(basename "$img" .img)
    CURRENT=$((CURRENT + 1))

    # Calculate progress (0.1 to 0.6 range for firmware)
    PROG=$(awk "BEGIN {printf \"%.2f\", 0.1 + ($CURRENT / $TOTAL) * 0.5}")
    set_progress "$PROG"

    # Skip super.img (handled separately below)
    [ "$IMGNAME" = "super" ] && continue

    # Skip logical partitions (they live inside super)
    if is_logical "$IMGNAME"; then
        ui_print "  [$CURRENT/$TOTAL] ⏭ $IMGNAME (inside super)"
        continue
    fi

    # Determine flash target
    case "$IMGNAME" in
        cust|persist)
            # No A/B slot
            TARGET="$BLOCK_PATH/$IMGNAME"
            ui_print "  [$CURRENT/$TOTAL] ⚡ $IMGNAME → $IMGNAME"
            dd if="$img" of="$TARGET" bs=4096 2>/dev/null || \
                ui_print "  [WARN] Failed to flash $IMGNAME"
            ;;
        *)
            # A/B partition — flash to both slots
            for slot in _a _b; do
                TARGET="$BLOCK_PATH/${IMGNAME}${slot}"
                if [ -e "$TARGET" ]; then
                    dd if="$img" of="$TARGET" bs=4096 2>/dev/null || \
                        ui_print "  [WARN] Failed to flash ${IMGNAME}${slot}"
                fi
            done
            ui_print "  [$CURRENT/$TOTAL] ⚡ $IMGNAME → ${IMGNAME}_a/b"
            ;;
    esac
done

# ── Flash super.img ──
SUPER_IMG="$IMG_DIR/super.img"
if [ -f "$SUPER_IMG" ]; then
    ui_print ""
    ui_print "  ─────────────────────────"
    ui_print "  🔷 Flashing super partition..."
    set_progress 0.65

    SUPER_TARGET="$BLOCK_PATH/super"
    if [ -e "$SUPER_TARGET" ]; then
        # Check if sparse — sparse images start with magic 0xED26FF3A
        MAGIC=$(xxd -l 4 -p "$SUPER_IMG" 2>/dev/null)
        if [ "$MAGIC" = "3aff26ed" ]; then
            # Sparse image → try simg2img if available, else dd raw
            if command -v simg2img >/dev/null 2>&1; then
                ui_print "  Converting sparse → raw and flashing..."
                simg2img "$SUPER_IMG" "$SUPER_TARGET" 2>/dev/null || \
                    abort "Failed to flash super.img (simg2img error)"
            else
                ui_print "  Flashing sparse super.img directly..."
                dd if="$SUPER_IMG" of="$SUPER_TARGET" bs=4096 2>/dev/null || \
                    abort "Failed to flash super.img"
            fi
        else
            # Raw image → direct dd
            ui_print "  Flashing raw super.img..."
            dd if="$SUPER_IMG" of="$SUPER_TARGET" bs=4096 2>/dev/null || \
                abort "Failed to flash super.img"
        fi
        SUPER_SIZE=$(du -h "$SUPER_IMG" | cut -f1)
        ui_print "  ✓ super.img flashed (${SUPER_SIZE})"
    else
        ui_print "  [WARN] super partition not found on device!"
    fi
fi
set_progress 0.90

# ── Set active slot to A ──
ui_print ""
ui_print "  🔄 Setting active slot to A..."
if command -v bootctl >/dev/null 2>&1; then
    bootctl set-active-boot-slot 0 2>/dev/null
elif [ -f "/system/bin/bootctl" ]; then
    /system/bin/bootctl set-active-boot-slot 0 2>/dev/null
fi

# ── Cleanup ──
set_progress 0.95
rm -rf "$TMP"

ui_print ""
ui_print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ui_print "  ✅ nexdroid.build — Install Complete!"
ui_print "  Reboot your device to start."
ui_print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ui_print ""
set_progress 1.0
exit 0
UPDATE_BINARY_EOF
    chmod +x "$META_GOOGLE/update-binary"
    log_success "✓ META-INF/com/google/android/update-binary (shell-based)"

    # updater-script (required to exist — must not be empty for some recoveries)
    echo '# Dummy updater-script — update-binary handles everything' \
        > "$META_GOOGLE/updater-script"
    log_success "✓ META-INF/com/google/android/updater-script"

    # metadata
    BUILD_TIMESTAMP=$(date +%s)
    cat > "$META_ANDROID/metadata" << META_EOF
ota-type=BLOCK
post-build=${DEVICE_CODE}/${OS_VER}/${ANDROID_VER}
post-build-incremental=${OS_VER}
post-sdk-level=${ANDROID_VER%%.*}
post-timestamp=${BUILD_TIMESTAMP}
pre-device=${DEVICE_CODE}
META_EOF
    log_success "✓ META-INF/com/android/metadata"

    # metadata.pb (minimal valid protobuf — field 1: type=0 (BLOCK))
    printf '\x08\x00' > "$META_ANDROID/metadata.pb"
    log_success "✓ META-INF/com/android/metadata.pb"

    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_success "✅ HYBRID ROM BUILD COMPLETE"
    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

else
    # ─────────────────────────────────────────────────────────
    #  MOD ONLY BUILD — Same as original behavior
    # ─────────────────────────────────────────────────────────
    mkdir -p "$PACK_DIR/super" "$PACK_DIR/images"

    log_info "Organizing super partitions..."
    SUPER_TARGETS="system system_ext product mi_ext vendor odm system_dlkm vendor_dlkm"
    SUPER_COUNT=0
    for img in $SUPER_TARGETS; do
        if [ -f "$SUPER_DIR/${img}.img" ]; then
            mv "$SUPER_DIR/${img}.img" "$PACK_DIR/super/"
            SUPER_COUNT=$((SUPER_COUNT + 1))
            log_success "✓ Added to package: ${img}.img"
        elif [ -f "$IMAGES_DIR/${img}.img" ]; then
            mv "$IMAGES_DIR/${img}.img" "$PACK_DIR/super/"
            SUPER_COUNT=$((SUPER_COUNT + 1))
            log_success "✓ Added to package: ${img}.img"
        fi
    done
    log_info "Total super partitions: $SUPER_COUNT"

    log_info "Organizing firmware images..."
    IMAGES_COUNT=$(find "$IMAGES_DIR" -maxdepth 1 -type f -name "*.img" -exec mv {} "$PACK_DIR/images/" \; -print | wc -l)
    log_success "✓ Moved $IMAGES_COUNT firmware images"

    log_info "Creating flash script..."
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
    log_success "✓ Created flash_rom.bat"
fi

# ── COMPRESS & UPLOAD ────────────────────────────────────────
log_step "🗜️  Compressing package..."
cd "$PACK_DIR"
if [ "$BUILD_MODE" == "hybrid" ]; then
    SUPER_ZIP="nexdroid.build-${OS_VER}_${DEVICE_CODE}_${ANDROID_VER}_hybrid.zip"
else
    SUPER_ZIP="ota-nexdroid-${OS_VER}_${DEVICE_CODE}_${ANDROID_VER}.zip"
fi
log_info "Target: $SUPER_ZIP"

START_TIME=$(date +%s)
7z a -tzip -mx1 -mmt=$(nproc) "$SUPER_ZIP" . > /dev/null
END_TIME=$(date +%s)
ZIP_TIME=$((END_TIME - START_TIME))

if [ -f "$SUPER_ZIP" ]; then
    ZIP_SIZE=$(du -h "$SUPER_ZIP" | cut -f1)
    log_success "✓ Package created: $SUPER_ZIP (${ZIP_SIZE}) in ${ZIP_TIME}s"
    mv "$SUPER_ZIP" "$OUTPUT_DIR/"
else
    log_error "Failed to create package!"
    exit 1
fi

log_step "☁️  Uploading to PixelDrain..."
tg_progress "☁️ **Uploading to PixelDrain...**"
cd "$OUTPUT_DIR"

upload() {
    local file=$1
    [ ! -f "$file" ] && return
    log_info "Uploading $file..." >&2
    if [ -z "$PIXELDRAIN_KEY" ]; then
        curl -s -T "$file" "https://pixeldrain.com/api/file/" | jq -r '"https://pixeldrain.com/u/" + .id'
    else
        curl -s -T "$file" -u :$PIXELDRAIN_KEY "https://pixeldrain.com/api/file/" | jq -r '"https://pixeldrain.com/u/" + .id'
    fi
}

LINK_ZIP=$(upload "$SUPER_ZIP")

if [ -z "$LINK_ZIP" ] || [ "$LINK_ZIP" == "null" ]; then
    log_error "Upload failed!"
    LINK_ZIP="https://pixeldrain.com"
    BTN_TEXT="Upload Failed"
else
    log_success "✓ Upload successful!"
    log_success "Download link: $LINK_ZIP"
    BTN_TEXT="Download ROM"
fi

# =========================================================
#  7. TELEGRAM NOTIFICATION
# =========================================================
# =========================================================
#  7. TELEGRAM NOTIFICATION
# =========================================================
if [ ! -z "$TELEGRAM_TOKEN" ] && [ ! -z "$CHAT_ID" ]; then
    log_step "📣 Sending Telegram notification..."
    tg_progress "✅ **Build Complete! Sending report...**"
    
    # Delete the progress message so the final report is fresh
    curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/deleteMessage" \
        -d chat_id="$CHAT_ID" \
        -d message_id="$TG_MSG_ID" >/dev/null

    # ── Region detection from OS version suffix ──
    # e.g. WPCCNXM → CN = China, WPCINXM → IN = India
    OS_SUFFIX=$(echo "$OS_VER" | grep -oE '[A-Z]+$' || echo "")
    REGION_CODE=$(echo "$OS_SUFFIX" | sed -E 's/^.{3}([A-Z]{2}).*/\1/' || echo "")
    case "$REGION_CODE" in
        CN) REGION_LABEL="CN (China)" ;;
        IN) REGION_LABEL="IN (India)" ;;
        GL) REGION_LABEL="GL (Global)" ;;
        EU) REGION_LABEL="EU (Europe)" ;;
        RU) REGION_LABEL="RU (Russia)" ;;
        ID) REGION_LABEL="ID (Indonesia)" ;;
        TW) REGION_LABEL="TW (Taiwan)" ;;
        JP) REGION_LABEL="JP (Japan)" ;;
        KR) REGION_LABEL="KR (Korea)" ;;
        TR) REGION_LABEL="TR (Turkey)" ;;
        TH) REGION_LABEL="TH (Thailand)" ;;
        MI) REGION_LABEL="MI (MIUI Global)" ;;
        *)  REGION_LABEL="$REGION_CODE" ;;
    esac

    # ── Compile time ──
    SCRIPT_END=$(date +%s)
    COMPILE_SECS=$((SCRIPT_END - SCRIPT_START))
    COMPILE_MINS=$((COMPILE_SECS / 60))
    COMPILE_REM=$((COMPILE_SECS % 60))
    COMPILE_TIME=$(printf "%02dm %02ds" "$COMPILE_MINS" "$COMPILE_REM")
    BUILD_DATE=$(date +"%H:%M")

    # ── Build type label ──
    if [ "$BUILD_MODE" == "hybrid" ]; then
        BUILD_TYPE_LABEL="Hybrid"
    else
        BUILD_TYPE_LABEL="Mod Pack"
    fi

    # ── Mods list (one per line with dash prefix) ──
    MODS_LIST=""
    if [ ! -z "$MODS_SELECTED" ] && [ "$MODS_SELECTED" != "none" ]; then
        MODS_LIST=$(echo "$MODS_SELECTED" | tr ',' '\n' | sed 's/^/- /')
    else
        MODS_LIST="- None"
    fi

    # ── Use REQUESTER_CHAT_ID if available, else fallback to CHAT_ID ──
    NOTIFY_CHAT="${REQUESTER_CHAT_ID:-$CHAT_ID}"

    SAFE_TEXT="✦ *nexdroid.build | Compiled Successfully*

\`\`\`
Compiled Build Info
Device: $DEVICE_CODE
Android: $ANDROID_VER
OS: $OS_VER
Region: $REGION_LABEL
\`\`\`
*Build Type:*
—  $BUILD_TYPE_LABEL
*Mods / Features Applied:*
\`\`\`
$MODS_LIST
\`\`\`

Total Size : \`$ZIP_SIZE\`
Compiled Time: \`$COMPILE_TIME\`
Built at: \`$BUILD_DATE\`"

    JSON_PAYLOAD=$(jq -n \
        --arg chat_id "$NOTIFY_CHAT" \
        --arg text "$SAFE_TEXT" \
        --arg url "$LINK_ZIP" \
        --arg btn "Download" \
        '{
            chat_id: $chat_id,
            parse_mode: "Markdown",
            text: $text,
            disable_web_page_preview: true,
            reply_markup: {
                inline_keyboard: [
                    [{text: $btn, url: $url}]
                ]
            }
        }') 

    # Send with error capture
    HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage" \
        -H "Content-Type: application/json" \
        -d "$JSON_PAYLOAD")
    
    if [ "$HTTP_CODE" -eq 200 ]; then
        log_success "✓ Telegram notification sent to $NOTIFY_CHAT"
    else
        log_warning "Telegram notification failed (HTTP $HTTP_CODE), output:"
        cat response.json
        log_warning "Trying fallback..."
        curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage" \
            -d chat_id="$NOTIFY_CHAT" \
            -d text="✅ Build Done: $LINK_ZIP" >/dev/null
    fi
else
    log_warning "Skipping Telegram notification (Missing TOKEN/CHAT_ID)"
fi


# =========================================================
#  8. BUILD SUMMARY
# =========================================================
log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_step "           BUILD SUMMARY"
log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_success "Device: $DEVICE_CODE"
log_success "OS Version: $OS_VER"
log_success "Android: $ANDROID_VER"
log_success "Package: $SUPER_ZIP"
log_success "Download: $LINK_ZIP"
log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

exit 0
