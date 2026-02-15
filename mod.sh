#!/bin/bash

# =========================================================
#  NEXDROID MANAGER - OPTIMIZED v57
# =========================================================

set +e 

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
  framework-sig       ApkSignatureVerifier → getMinimumSignatureSchemeVersionForTargetSdk = 1
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
# ════════════════════════════════════════════════════════════════════

def _raw_sget_scan(dex: bytearray, field_class: str, field_name: str,
                   use_const4: bool = False) -> int:
    data = bytes(dex)
    hdr  = _parse_header(data)
    if not hdr: return 0

    fids = _find_field_ids(data, hdr, field_class, field_name)
    if not fids: return 0

    SGET_OPCODES = frozenset([0x60, 0x63, 0x64, 0x65, 0x66])

    scan_start = hdr['class_defs_off'] + hdr['class_defs_size'] * 32
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
                    raw[i]     = 0x13
                    raw[i + 1] = reg
                    raw[i + 2] = 0x01
                    raw[i + 3] = 0x00
                count += 1
                i += 4
                continue
        i += 2

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
    data = bytes(dex)
    hdr  = _parse_header(data)
    if not hdr: return False

    target_type = f'L{class_desc};'

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
        _,   pos = _uleb128(data, pos)
        _,   pos = _uleb128(data, pos)
        try:
            mid_base  = hdr['method_ids_off'] + midx * 8
            name_sidx = struct.unpack_from('<I', data, mid_base + 4)[0]
            if _get_str(data, hdr, name_sidx) == method_name:
                target_midx = midx
                break
        except Exception:
            continue

    if target_midx is None: return False

    pos = annotations_off
    pos += 4
    fields_sz   = struct.unpack_from('<I', data, pos)[0]; pos += 4
    methods_sz  = struct.unpack_from('<I', data, pos)[0]; pos += 4
    pos += 4
    pos += fields_sz * 8

    for j in range(methods_sz):
        entry = pos + j * 8
        m_idx = struct.unpack_from('<I', data, entry)[0]
        if m_idx == target_midx:
            struct.pack_into('<I', dex, entry + 4, 0)
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
    data = bytes(dex)
    hdr  = _parse_header(data)
    if not hdr: err("  Not a DEX"); return False

    target_type = f'L{class_desc};'
    info(f"  Searching {target_type} → {method_name}")

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

    new_regs = stub_regs + orig_ins

    struct.pack_into('<H', dex, code_off + 0, new_regs)
    struct.pack_into('<H', dex, code_off + 4, 0)
    struct.pack_into('<H', dex, code_off + 6, 0)
    struct.pack_into('<I', dex, code_off + 8, 0)
    if trim:
        struct.pack_into('<I', dex, code_off + 12, stub_units)

    for i, b in enumerate(stub_insns):
        dex[insns_off + i] = b
    if not trim:
        for i in range(len(stub_insns), insns_size * 2):
            dex[insns_off + i] = 0x00

    _fix_checksums(dex)
    nops = 0 if trim else (insns_size - stub_units)
    mode = "trimmed" if trim else f"{nops} nop pad"
    ok(f"  ✓ {method_name} → stub ({stub_units} cu, {mode}, regs {orig_regs}→{new_regs})")
    return True


# ════════════════════════════════════════════════════════════════════
#  BINARY PATCH: sget-boolean field → const/4 1 (or const/16 with opcode 0x13)
# ════════════════════════════════════════════════════════════════════

def binary_patch_sget_to_true(dex: bytearray,
                               field_class: str, field_name: str,
                               only_class:  str = None,
                               only_method: str = None,
                               use_const4:  bool = False) -> int:
    data = bytes(dex)
    hdr  = _parse_header(data)
    if not hdr: return 0

    fids = _find_field_ids(data, hdr, field_class, field_name)
    if not fids:
        warn(f"  Field {field_class}->{field_name} not in this DEX"); return 0
    for fi in fids:
        info(f"  Found field: {field_class}->{field_name} @ field_id[{fi}] = 0x{fi:04X}")

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
                        raw[insns_off + i]     = 0x12
                        raw[insns_off + i + 1] = (0x1 << 4) | reg
                        raw[insns_off + i + 2] = 0x00
                        raw[insns_off + i + 3] = 0x00
                    else:
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
# ════════════════════════════════════════════════════════════════════

_BAIDU_IME  = "com.baidu.input_mi"
_GBOARD_IME = "com.google.android.inputmethod.latin"

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
            if op == 0x1A and i + 3 < insns_len:
                sidx = struct.unpack_from('<H', raw, insns_off + i + 2)[0]
                if sidx == old_idx:
                    struct.pack_into('<H', raw, insns_off + i + 2, new_idx & 0xFFFF)
                    count += 1
                i += 4
            elif op == 0x1B and i + 5 < insns_len:
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
        warn(f"⚠ {label}: no patches applied — archive unchanged")
    return count


# ════════════════════════════════════════════════════════════════════
#  PATCH PROFILES
# ════════════════════════════════════════════════════════════════════

def _fw_sig_patch(dex_name: str, dex: bytearray) -> bool:
    if b'ApkSignatureVerifier' not in bytes(dex): return False
    return binary_patch_method(dex,
        "android/util/apk/ApkSignatureVerifier",
        "getMinimumSignatureSchemeVersionForTargetSdk", 1, _STUB_TRUE,
        trim=True)

def _settings_ai_patch(dex_name: str, dex: bytearray) -> bool:
    if b'InternalDeviceUtils' not in bytes(dex): return False
    return binary_patch_method(dex,
        "com/android/settings/InternalDeviceUtils",
        "isAiSupported", 1, _STUB_TRUE)

def _recorder_ai_patch(dex_name: str, dex: bytearray) -> bool:
    patched = False
    raw = bytes(dex)

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

    if b'IS_INTERNATIONAL_BUILD' in raw:
        if binary_patch_sget_to_true(dex, 'Lmiui/os/Build;', 'IS_INTERNATIONAL_BUILD') > 0:
            patched = True

    return patched

def _services_jar_patch(dex_name: str, dex: bytearray) -> bool:
    raw = bytes(dex)
    METHOD   = 'showSystemReadyErrorDialogsIfNeeded'
    TARGET_C = 'Lcom/android/server/wm/ActivityTaskManagerInternal;'

    if b'showSystemReadyErrorDialogsIfNeeded' not in raw: return False
    if b'ActivityTaskManagerInternal' not in raw:        return False

    hdr = _parse_header(raw)
    if not hdr: return False

    target_mid = None
    for mi in range(hdr['method_ids_size']):
        base = hdr['method_ids_off'] + mi * 8
        try:
            cls_idx   = struct.unpack_from('<H', raw, base + 0)[0]
            name_sidx = struct.unpack_from('<I', raw, base + 4)[0]
            type_sidx = struct.unpack_from('<I', raw, hdr['type_ids_off'] + cls_idx * 4)[0]
            cls_str   = _get_str(raw, hdr, type_sidx)
            if cls_str != TARGET_C: continue
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
        while i <= insns_len * 2 - 6:
            op = raw[insns_off + i]
            if op in INVOKE_OPS_ALL:
                mid_ref = struct.unpack_from('<H', raw, insns_off + i + 2)[0]
                if mid_ref == target_mid:
                    op_name = INVOKE_OPS_ALL[op]
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

def _provision_gms_patch(dex_name: str, dex: bytearray) -> bool:
    raw = bytes(dex)
    if b'IS_INTERNATIONAL_BUILD' not in raw: return False
    if b'setGmsAppEnabledStateForCn' not in raw: return False

    n = binary_patch_sget_to_true(dex,
            'Lmiui/os/Build;', 'IS_INTERNATIONAL_BUILD',
            only_class='Utils',
            only_method='setGmsAppEnabledStateForCn',
            use_const4=True)
    if n == 0:
        warn("  Provision: setGmsAppEnabledStateForCn not found or no IS_INTERNATIONAL_BUILD sget")
        return False
    ok(f"  ✓ Provision Utils::setGmsAppEnabledStateForCn → const/4 v0, 0x1 ({n} sget)")
    return True


def _miui_service_patch(dex_name: str, dex: bytearray) -> bool:
    raw = bytes(dex)
    if b'IS_INTERNATIONAL_BUILD' not in raw: return False
    n  = binary_patch_sget_to_true(dex, 'Lmiui/os/Build;', 'IS_INTERNATIONAL_BUILD',
                                    use_const4=True)
    n += _raw_sget_scan(dex, 'Lmiui/os/Build;', 'IS_INTERNATIONAL_BUILD',
                        use_const4=True)
    return n > 0

def _systemui_all_patch(dex_name: str, dex: bytearray) -> bool:
    patched = False
    raw = bytes(dex)

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

    if b'CurrentTilesInteractorImpl' in raw and b'MiuiConfigs' in raw:
        if binary_patch_sget_to_true(dex,
                'Lcom/miui/utils/configs/MiuiConfigs;', 'IS_INTERNATIONAL_BUILD',
                only_class='CurrentTilesInteractorImpl',
                use_const4=True) > 0:
            patched = True
            raw = bytes(dex)

    if b'NotificationUtil' in raw and b'MiuiConfigs' in raw:
        if binary_patch_sget_to_true(dex,
                'Lcom/miui/utils/configs/MiuiConfigs;', 'IS_INTERNATIONAL_BUILD',
                only_class='NotificationUtil',
                only_method='isEmptySummary',
                use_const4=True) > 0:
            patched = True

    return patched

_FW_INTL_CLASSES = [
    'AppOpsManagerInjector',   'NearbyUtils',             'ShortcutFunctionManager',
    'MiInputShortcutFeature',  'MiInputShortcutUtil',     'FeatureConfiguration',
    'InputFeature',            'TelephonyManagerEx',       'SystemServiceRegistryImpl',
    'PackageManagerImpl',      'PackageParserImpl',        'LocaleComparator',
    'MiuiSignalStrengthImpl',
]

def _miui_framework_patch(dex_name: str, dex: bytearray) -> bool:
    raw = bytes(dex)
    patched = False

    if b'IS_INTERNATIONAL_BUILD' in raw:
        n = 0
        for cls in _FW_INTL_CLASSES:
            n += binary_patch_sget_to_true(dex, 'Lmiui/os/Build;', 'IS_INTERNATIONAL_BUILD',
                                            only_class=cls, use_const4=True)
        if n > 0:
            patched = True
            raw = bytes(dex)

    if _BAIDU_IME.encode() in raw:
        n = binary_swap_string(dex, _BAIDU_IME, _GBOARD_IME,
                               only_class='InputMethodManagerStubImpl')
        if n > 0:
            patched = True
            raw = bytes(dex)

    if b'ActivityTaskManagerInternal' in raw:
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

def _settings_region_patch(dex_name: str, dex: bytearray) -> bool:
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


def _incallui_patch(dex_name: str, dex: bytearray) -> bool:
    if b'RecorderUtils' not in bytes(dex):
        return False

    if binary_patch_method(dex,
            "com/android/incallui/RecorderUtils",
            "isAiRecordEnable",
            stub_regs=1, stub_insns=_STUB_TRUE):
        return True

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
    "framework-sig":     _fw_sig_patch,
    "settings-ai":       _settings_ai_patch,
    "settings-region":   _settings_region_patch,
    "voice-recorder-ai": _recorder_ai_patch,
    "services-jar":      _services_jar_patch,
    "provision-gms":     _provision_gms_patch,
    "miui-service":      _miui_service_patch,
    "systemui-volte":    _systemui_all_patch,
    "miui-framework":    _miui_framework_patch,
    "incallui-ai":       _incallui_patch,
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
    sys.exit(0)

if __name__ == "__main__":
    main()
PYTHON_EOF
chmod +x "$BIN_DIR/dex_patcher.py"
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
# =========================================================

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
    unzip -qq -o "$zip_path" -d "$MOD_EXTRACT_DIR"
    rm -f "$zip_path"

    local top_dirs
    top_dirs=$(find "$MOD_EXTRACT_DIR" -mindepth 1 -maxdepth 1 -type d)
    local dir_count
    dir_count=$(echo "$top_dirs" | grep -c .)
    if [ "$dir_count" -eq 1 ]; then
        local inner_dir="$top_dirs"
        mv "$inner_dir"/* "$MOD_EXTRACT_DIR/" 2>/dev/null
        mv "$inner_dir"/.* "$MOD_EXTRACT_DIR/" 2>/dev/null
        rmdir "$inner_dir" 2>/dev/null
    fi

    log_success "[$label] Extraction complete"
    return 0
}

mod_finalize() {
    local target_dir="$1" label="$2"
    find "$target_dir" -type f -name "*.apk" -exec chmod 0644 {} +
    find "$target_dir" -type d -exec chmod 0755 {} +
    rm -rf "$TEMP_DIR/mod_${label}"
    log_success "[$label] Permissions set and temp cleaned"
}

inject_launcher_mod() {
    local dump_dir="$1"
    if ! inject_miui_mod "Mods-Center/HyperOS-Launcher" "launcher"; then
        return 1
    fi

    local src="$MOD_EXTRACT_DIR"

    local home_apk=$(find "$src" -name "MiuiHome.apk" -type f | head -n 1)
    if [ -z "$home_apk" ]; then
        log_error "[launcher] MiuiHome.apk not found in module — aborting"
        rm -rf "$TEMP_DIR/mod_launcher"
        return 1
    fi
    mkdir -p "$dump_dir/priv-app/MiuiHome"
    cp -f "$home_apk" "$dump_dir/priv-app/MiuiHome/MiuiHome.apk"
    log_success "[launcher] ✓ MiuiHome.apk injected"

    local ext_apk=$(find "$src" -name "XiaomiEUExt.apk" -type f | head -n 1)
    if [ -n "$ext_apk" ]; then
        mkdir -p "$dump_dir/priv-app/XiaomiEUExt"
        cp -f "$ext_apk" "$dump_dir/priv-app/XiaomiEUExt/XiaomiEUExt.apk"
        log_success "[launcher] ✓ XiaomiEUExt.apk injected"
    else
        log_info "[launcher] XiaomiEUExt.apk not present in module — skipping"
    fi

    local perm_src=$(find "$src" -type d -name "permissions" | head -n 1)
    if [ -n "$perm_src" ]; then
        mkdir -p "$dump_dir/etc/permissions"
        cp -f "$perm_src"/*.xml "$dump_dir/etc/permissions/" 2>/dev/null
        log_success "[launcher] ✓ Permission XMLs injected"
    fi

    mod_finalize "$dump_dir/priv-app/MiuiHome" "launcher"
    log_success "✅ HyperOS Launcher mod injected successfully"
}

inject_theme_mod() {
    local dump_dir="$1"
    if ! inject_miui_mod "Mods-Center/HyperOS-Theme-Manager" "thememanager"; then
        return 1
    fi

    local src="$MOD_EXTRACT_DIR"

    if [ -d "$dump_dir/app/MIUIThemeManager" ]; then
        rm -rf "$dump_dir/app/MIUIThemeManager"/*
        log_info "[thememanager] Cleared existing MIUIThemeManager directory"
    fi
    mkdir -p "$dump_dir/app/MIUIThemeManager"

    local theme_apk=$(find "$src" -name "MIUIThemeManager.apk" -type f | head -n 1)
    if [ -z "$theme_apk" ]; then
        log_error "[thememanager] MIUIThemeManager.apk not found in module — aborting"
        rm -rf "$TEMP_DIR/mod_thememanager"
        return 1
    fi
    cp -f "$theme_apk" "$dump_dir/app/MIUIThemeManager/MIUIThemeManager.apk"
    log_success "[thememanager] ✓ MIUIThemeManager.apk injected"

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

inject_security_mod() {
    local dump_dir="$1"
    if ! inject_miui_mod "Mods-Center/HyperOS-Security-Center" "securitycenter"; then
        return 1
    fi

    local src="$MOD_EXTRACT_DIR"

    local sec_apk=$(find "$src" -name "SecurityCenter.apk" -type f | head -n 1)
    if [ -z "$sec_apk" ]; then
        log_error "[securitycenter] SecurityCenter.apk not found in module — aborting"
        rm -rf "$TEMP_DIR/mod_securitycenter"
        return 1
    fi

    rm -rf "$dump_dir/priv-app/MIUISecurityCenter"
    mkdir -p "$dump_dir/priv-app/MIUISecurityCenter"
    cp -f "$sec_apk" "$dump_dir/priv-app/MIUISecurityCenter/MIUISecurityCenter.apk"
    log_success "[securitycenter] ✓ MIUISecurityCenter.apk injected (renamed from SecurityCenter.apk)"

    local perm_src=$(find "$src" -type d -name "permissions" | head -n 1)
    if [ -n "$perm_src" ]; then
        mkdir -p "$dump_dir/etc/permissions"
        cp -f "$perm_src"/*.xml "$dump_dir/etc/permissions/" 2>/dev/null
        log_success "[securitycenter] ✓ Permission XMLs injected"
    fi

    mod_finalize "$dump_dir/priv-app/MIUISecurityCenter" "securitycenter"
    log_success "✅ HyperOS Security Center mod injected successfully"
}

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

tg_progress "📂 **Extracting Firmware...**"
log_step "🔍 Extracting firmware images..."
START_TIME=$(date +%s)
payload-dumper-go -o "$IMAGES_DIR" payload.bin > /dev/null 2>&1
END_TIME=$(date +%s)
EXTRACT_TIME=$((END_TIME - START_TIME))
rm payload.bin
log_success "Firmware extracted in ${EXTRACT_TIME}s"

# =========================================================
#  4.5. VBMETA VERIFICATION DISABLER (PROFESSIONAL)
# =========================================================
log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_step "🔓 VBMETA VERIFICATION DISABLER"
log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

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
    
    MAGIC_OFFSET = 0
    VERSION_MAJOR_OFFSET = 4
    VERSION_MINOR_OFFSET = 8
    FLAGS_OFFSET = 123
    
    FLAG_VERIFICATION_DISABLED = 0x01
    FLAG_HASHTREE_DISABLED = 0x02
    DISABLE_FLAGS = FLAG_VERIFICATION_DISABLED | FLAG_HASHTREE_DISABLED
    
    def __init__(self, filepath):
        self.filepath = filepath
        self.original_size = os.path.getsize(filepath)
        
    def read_header(self):
        print(f"[ACTION] Reading vbmeta header from {os.path.basename(self.filepath)}")
        
        with open(self.filepath, 'rb') as f:
            f.seek(self.MAGIC_OFFSET)
            magic = f.read(4)
            
            if magic != self.AVB_MAGIC:
                print(f"[ERROR] Invalid AVB magic: {magic.hex()} (expected: {self.AVB_MAGIC.hex()})")
                return False
            
            print(f"[SUCCESS] Valid AVB magic found: {magic.decode('ascii')}")
            
            f.seek(self.VERSION_MAJOR_OFFSET)
            major = struct.unpack('>I', f.read(4))[0]
            minor = struct.unpack('>I', f.read(4))[0]
            
            print(f"[INFO] AVB Version: {major}.{minor}")
            
            f.seek(self.FLAGS_OFFSET)
            current_flags = struct.unpack('B', f.read(1))[0]
            
            print(f"[INFO] Current flags at offset {self.FLAGS_OFFSET}: 0x{current_flags:02X}")
            
            if current_flags == self.DISABLE_FLAGS:
                print("[INFO] Verification already disabled")
                return True
            
            return True
    
    def patch(self):
        print(f"[ACTION] Patching flags at offset {self.FLAGS_OFFSET}")
        
        try:
            with open(self.filepath, 'rb') as f:
                data = bytearray(f.read())
            
            original_flag = data[self.FLAGS_OFFSET]
            print(f"[INFO] Original flag value: 0x{original_flag:02X}")
            
            data[self.FLAGS_OFFSET] = self.DISABLE_FLAGS
            
            print(f"[ACTION] Setting new flag value: 0x{self.DISABLE_FLAGS:02X}")
            print(f"[INFO] Verification Disabled: {'YES' if self.DISABLE_FLAGS & 0x01 else 'NO'}")
            print(f"[INFO] Hashtree Disabled: {'YES' if self.DISABLE_FLAGS & 0x02 else 'NO'}")
            
            with open(self.filepath, 'wb') as f:
                f.write(data)
            
            print(f"[SUCCESS] Flags patched successfully")
            
            return True
            
        except Exception as e:
            print(f"[ERROR] Patching failed: {str(e)}")
            return False
    
    def verify(self):
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
    
    print(f"[INFO] File: {os.path.basename(filepath)}")
    print(f"[INFO] Size: {patcher.get_info()}")
    
    if not patcher.read_header():
        print("[ERROR] Invalid vbmeta image")
        sys.exit(1)
    
    if not patcher.patch():
        print("[ERROR] Patching failed")
        sys.exit(1)
    
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
        
        mkdir -p "$DUMP_DIR"
        mkdir -p "$MNT_DIR"
        
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
            P_PRIV="Wizard Velvet Phonesky MIUIPackageInstaller GoogleRestore GooglePartnerSetup Assistant AndroidAutoStub"
            
            install_gapp_logic "$P_PRIV" "$PRIV_ROOT"
            install_gapp_logic "$P_APP" "$APP_ROOT"
        fi

        # B2. MIUI MOD INJECTION (optional, triggered by MODS_SELECTED)
        if [ -n "$MODS_SELECTED" ]; then
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

            log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            log_success "✅ MOD INJECTION COMPLETE"
            log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        fi

        # C. MIUI BOOSTER
        if [ "$part" == "system_ext" ]; then
            log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            log_step "🚀 MIUIBOOSTER PERFORMANCE PATCH"
            log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            
            BOOST_JAR=$(find "$DUMP_DIR" -name "MiuiBooster.jar" -type f | head -n 1)
            
            if [ ! -z "$BOOST_JAR" ]; then
                log_info "Located: $BOOST_JAR"
                JAR_SIZE=$(du -h "$BOOST_JAR" | cut -f1)
                log_info "Original size: $JAR_SIZE"
                
                cp "$BOOST_JAR" "${BOOST_JAR}.bak"
                log_success "✓ Backup created: ${BOOST_JAR}.bak"
                
                rm -rf "$TEMP_DIR/boost_work"
                mkdir -p "$TEMP_DIR/boost_work"
                cd "$TEMP_DIR/boost_work"
                
                log_info "Decompiling MiuiBooster.jar with apktool..."
                START_TIME=$(date +%s)
                
                if timeout 3m apktool d -r -f "$BOOST_JAR" -o "decompiled" 2>&1 | tee apktool_decompile.log | grep -q "I: Baksmaling"; then
                    END_TIME=$(date +%s)
                    DECOMPILE_TIME=$((END_TIME - START_TIME))
                    log_success "✓ Decompiled successfully in ${DECOMPILE_TIME}s"
                    
                    log_info "Searching for DeviceLevelUtils.smali..."
                    SMALI_FILE=$(find "decompiled" -type f -path "*/com/miui/performance/DeviceLevelUtils.smali" | head -n 1)
                    
                    if [ -f "$SMALI_FILE" ]; then
                        SMALI_REL_PATH=$(echo "$SMALI_FILE" | sed "s|decompiled/||")
                        log_success "✓ Found: $SMALI_REL_PATH"
                        
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
    
    new_method = """.method public initDeviceLevel()V
    .registers 2

    const-string v0, "v:1,c:3,g:3"

    .line 130
    invoke-direct {p0, v0}, Lcom/miui/performance/DeviceLevelUtils;->parseDeviceLevelList(Ljava/lang/String;)V

    .line 140
    return-void
.end method"""
    
    print("[ACTION] Searching for initDeviceLevel()V method...")
    pattern = r'\.method\s+public\s+initDeviceLevel\(\)V.*?\.end\s+method'
    
    matches = re.findall(pattern, content, flags=re.DOTALL)
    if matches:
        print(f"[ACTION] Found method (length: {len(matches[0])} bytes)")
        orig_lines = matches[0].split('\n')[:5]
        for line in orig_lines:
            print(f"         {line}")
        if len(matches[0].split('\n')) > 5:
            print(f"         ... (+{len(matches[0].split(chr(10))) - 5} more lines)")
    else:
        print("[ERROR] Method not found!")
        return False
    
    print("[ACTION] Replacing method with optimized version...")
    new_content = re.sub(pattern, new_method, content, flags=re.DOTALL)
    
    if new_content != content:
        new_length = len(new_content)
        size_diff = original_length - new_length
        print(f"[ACTION] New file size: {new_length} bytes (reduced by {size_diff} bytes)")
        
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
                            
                            log_info "Verifying patch..."
                            if grep -q 'const-string v0, "v:1,c:3,g:3"' "$SMALI_FILE"; then
                                log_success "✓ Verification passed: Device level string found"
                            else
                                log_error "✗ Verification failed: Device level string not found"
                            fi
                            
                            log_info "Rebuilding MiuiBooster.jar with apktool..."
                            START_TIME=$(date +%s)
                            
                            if timeout 3m apktool b -c "decompiled" -o "MiuiBooster_patched.jar" 2>&1 | tee apktool_build.log | grep -q "Built"; then
                                END_TIME=$(date +%s)
                                BUILD_TIME=$((END_TIME - START_TIME))
                                log_success "✓ Rebuild completed in ${BUILD_TIME}s"
                                
                                if [ -f "MiuiBooster_patched.jar" ]; then
                                    PATCHED_SIZE=$(du -h "MiuiBooster_patched.jar" | cut -f1)
                                    log_info "Patched JAR size: $PATCHED_SIZE"
                                    
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
                                    cp "${BOOST_JAR}.bak" "$BOOST_JAR"
                                    log_warning "Original restored"
                                fi
                            else
                                log_error "✗ apktool build failed"
                                cp "${BOOST_JAR}.bak" "$BOOST_JAR"
                                log_warning "Original restored"
                            fi
                        else
                            log_error "✗ Method patching failed"
                            cp "${BOOST_JAR}.bak" "$BOOST_JAR"
                            log_warning "Original restored"
                        fi
                    else
                        log_error "✗ DeviceLevelUtils.smali not found in JAR"
                    fi
                else
                    END_TIME=$(date +%s)
                    DECOMPILE_TIME=$((END_TIME - START_TIME))
                    log_error "✗ Decompile failed or timed out (${DECOMPILE_TIME}s)"
                fi
                
                cd "$GITHUB_WORKSPACE"
                rm -rf "$TEMP_DIR/boost_work"
            else
                log_warning "⚠️  MiuiBooster.jar not found in system_ext partition"
            fi
        fi


        # ═══════════════════════════════════════════════════════════
        #  DEX PATCHING  (via dex_patcher.py)
        # ═══════════════════════════════════════════════════════════

        _run_dex_patch() {
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

            _run_dex_patch "SIGNATURE BYPASS" "framework-sig" \
                "$(find "$DUMP_DIR" -path "*/framework/framework.jar" -type f | head -n1)"
            cd "$GITHUB_WORKSPACE"

            _run_dex_patch "SERVICES DIALOGS" "services-jar" \
                "$(find "$DUMP_DIR" -path "*/framework/services.jar" -type f | head -n1)"
            cd "$GITHUB_WORKSPACE"

        fi

        # ── product partition ────────────────────────────────────────
        if [ "$part" == "product" ]; then

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

            _run_dex_patch "INCALLUI AI" "incallui-ai" \
                "$(find "$DUMP_DIR" -path "*/priv-app/InCallUI/InCallUI.apk" -type f | head -n1)"
            cd "$GITHUB_WORKSPACE"

        fi

        # ── system_ext partition ──────────────────────────────────
        if [ "$part" == "system_ext" ]; then

            _SETTINGS_APK="$(find "$DUMP_DIR" -name "Settings.apk" -type f | head -n1)"
            _run_dex_patch "SETTINGS AI"     "settings-ai"     "$_SETTINGS_APK"
            cd "$GITHUB_WORKSPACE"
            _run_dex_patch "SETTINGS REGION" "settings-region" "$_SETTINGS_APK"
            cd "$GITHUB_WORKSPACE"

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
                        sed -i \
                            's|sget-boolean p1, Lmiui/os/Build;->IS_GLOBAL_BUILD:Z|const/4 p1, 0x1|g' \
                            "$_f"
                    done
                    log_success "  ✓ IS_GLOBAL_BUILD replaced in OtherPersonalSettings.smali"
                    if timeout 25m apktool b -c "$_OPS_WORK" -o "${_SETTINGS_APK}.apkbuild" >/dev/null 2>&1; then
                        mkdir -p "$_OPS_DEX"
                        cd "$_OPS_DEX"
                        unzip -o "${_SETTINGS_APK}.apkbuild" 'classes*.dex' >/dev/null 2>&1
                        _DEX_COUNT=$(ls classes*.dex 2>/dev/null | wc -l)
                        if [ "$_DEX_COUNT" -gt 0 ]; then
                            zip -0 -u "$_SETTINGS_APK" classes*.dex >/dev/null 2>&1
                            cd "$GITHUB_WORKSPACE"
                            _ZA=$(which zipalign 2>/dev/null || \
                                  find "$BIN_DIR/android-sdk" -name zipalign 2>/dev/null | head -1)
                            if [ -n "$_ZA" ]; then
                                "$_ZA" -p -f 4 "$_SETTINGS_APK" "${_SETTINGS_APK}.aligned" \
                                    && mv "${_SETTINGS_APK}.aligned" "$_SETTINGS_APK" \
                                    && log_success "  ✓ zipalign applied"
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

            _run_dex_patch "PROVISION GMS" "provision-gms" \
                "$(find "$DUMP_DIR" -name "Provision.apk" -type f | head -n1)"
            cd "$GITHUB_WORKSPACE"

            _run_dex_patch "MIUI SERVICE CN→GLOBAL" "miui-service" \
                "$(find "$DUMP_DIR" -name "miui-services.jar" -type f | head -n1)"
            cd "$GITHUB_WORKSPACE"

            _run_dex_patch "SYSTEMUI ALL" "systemui-volte" \
                "$(find "$DUMP_DIR" \( -name "MiuiSystemUI.apk" -o -name "SystemUI.apk" \) -type f | head -n1)"
            cd "$GITHUB_WORKSPACE"

            _FW_JAR="$(find "$DUMP_DIR" -name "miui-framework.jar" -type f | head -n1)"
            _run_dex_patch "MIUI FRAMEWORK" "miui-framework" "$_FW_JAR"
            cd "$GITHUB_WORKSPACE"

            if [ -n "$_FW_JAR" ]; then
                log_info "🎹 miui-framework: Gboard IME swap..."
                _FW_WORK="$TEMP_DIR/fw_smali"
                rm -rf "$_FW_WORK"
                _FW_APPLIED=0
                if timeout 20m apktool d -r -f "$_FW_JAR" -o "$_FW_WORK" >/dev/null 2>&1; then
                    _IMSI=$(find "$_FW_WORK" -name "InputMethodServiceInjector.smali" -type f | head -1)
                    if [ -n "$_IMSI" ] && grep -q "com\.baidu\.input_mi" "$_IMSI"; then
                        sed -i 's|com\.baidu\.input_mi|com.google.android.inputmethod.latin|g' "$_IMSI"
                        log_success "  ✓ Gboard swap in InputMethodServiceInjector"
                        _FW_APPLIED=1
                    else
                        log_info "  InputMethodServiceInjector: com.baidu.input_mi not present"
                    fi
                    _IMMS=$(find "$_FW_WORK" -name "InputMethodManagerStubImpl.smali" -type f | head -1)
                    if [ -n "$_IMMS" ] && grep -q "com\.baidu\.input_mi" "$_IMMS"; then
                        sed -i 's|com\.baidu\.input_mi|com.google.android.inputmethod.latin|g' "$_IMMS"
                        log_success "  ✓ Gboard swap in InputMethodManagerStubImpl"
                        _FW_APPLIED=1
                    else
                        log_info "  InputMethodManagerStubImpl: com.baidu.input_mi not present"
                    fi
                    _SRED_FILE=$(grep -rl "showSystemReadyErrorDialogsIfNeeded" "$_FW_WORK"/smali* 2>/dev/null | head -1)
                    if [ -n "$_SRED_FILE" ]; then
                        python3 - "$_SRED_FILE" "showSystemReadyErrorDialogsIfNeeded" <<'SRED_PY'
import re, sys
path, method = sys.argv[1], sys.argv[2]
text = open(path).read()
pat = rf'(\.method[^\n]*{re.escape(method)}[^\n]*\n).*?(\.end method)'
def stub(m):
    return m.group(1) + "    .registers 1\n    return-void\n" + m.group(2)
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

        # E. MIUI-FRAMEWORK (handled via dex_patcher.py miui-framework profile above)
        #    ThemeReceiver bypass + IS_GLOBAL_BUILD already done in D8 above.

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
                DEF_XML="default-permissions-google.xml"
                if [ -f "$GITHUB_WORKSPACE/nex_pkg/$DEF_XML" ]; then
                    cp "$GITHUB_WORKSPACE/nex_pkg/$DEF_XML" "$DEF_PERM_DIR/"
                    chmod 644 "$DEF_PERM_DIR/$DEF_XML"
                    log_success "✓ Installed: $DEF_XML"
                fi
                
                PERM_COUNT=$(find "$GITHUB_WORKSPACE/nex_pkg" -maxdepth 1 -name "*.xml" ! -name "$DEF_XML" -exec cp {} "$PERM_DIR/" \; -print | wc -l)
                log_success "✓ Installed $PERM_COUNT permission files"
                
                OVERLAY_COUNT=$(find "$GITHUB_WORKSPACE/nex_pkg" -maxdepth 1 -name "*.apk" -exec cp {} "$OVERLAY_DIR/" \; -print | wc -l)
                log_success "✓ Installed $OVERLAY_COUNT overlay APKs"
                
                if [ -f "$GITHUB_WORKSPACE/nex_pkg/bootanimation.zip" ]; then
                    cp "$GITHUB_WORKSPACE/nex_pkg/bootanimation.zip" "$MEDIA_DIR/"
                    log_success "✓ Installed: bootanimation.zip"
                fi
                
                if [ -f "$GITHUB_WORKSPACE/nex_pkg/lock_wallpaper" ]; then
                    cp "$GITHUB_WORKSPACE/nex_pkg/lock_wallpaper" "$THEME_DIR/"
                    log_success "✓ Installed: lock_wallpaper"
                fi
                
                log_success "NexPackage assets injection complete"
            else
                log_warning "NexPackage directory not found"
            fi

            log_info "🔧 Downloading MIUI uninstall patcher assets..."
            UNINSTALL_GD_ID="1lxkPJe5yn79Cb7YeoM3ScwjBD9TRWbYP"
            if gdown "$UNINSTALL_GD_ID" -O "$TEMP_DIR/uninstall_patch.zip" --fuzzy -q 2>/dev/null; then
                mkdir -p "$DUMP_DIR/framework"
                unzip -qq -p "$TEMP_DIR/uninstall_patch.zip" "feb-x1.jar" \
                    > "$DUMP_DIR/framework/feb-x1.jar" 2>/dev/null && \
                    log_success "✓ feb-x1.jar → product/framework" || \
                    log_warning "feb-x1.jar not found in zip"

                mkdir -p "$DUMP_DIR/etc/permissions"
                unzip -qq -p "$TEMP_DIR/uninstall_patch.zip" "feb-x1.xml" \
                    > "$DUMP_DIR/etc/permissions/feb-x1.xml" 2>/dev/null && \
                    log_success "✓ feb-x1.xml → product/etc/permissions" || \
                    log_warning "feb-x1.xml not found in zip"

                rm -f "$TEMP_DIR/uninstall_patch.zip"
            else
                log_warning "Uninstall patcher download failed — skipping"
            fi

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

        # H. BUILD PROPS
        log_info "📝 Adding custom build properties..."
        if [ "$part" == "product" ]; then
            PRODUCT_PROP="$DUMP_DIR/etc/build.prop"
            if [ ! -f "$PRODUCT_PROP" ]; then
                PRODUCT_PROP="$DUMP_DIR/build.prop"
            fi
            if [ -f "$PRODUCT_PROP" ]; then
                echo "$PROPS_CONTENT" >> "$PRODUCT_PROP"
                log_success "✓ Updated: $PRODUCT_PROP"
            else
                log_error "✗ /product/build.prop not found — skipping props"
            fi
        else
            log_info "Skipping build.prop for partition '${part}' — only product partition is allowed"
        fi

        # I. REPACK
        log_info "📦 Repacking ${part} partition..."
        START_TIME=$(date +%s)
        sudo mkfs.erofs -zlz4 "$SUPER_DIR/${part}.img" "$DUMP_DIR" 2>&1 | grep -E "Build.*completed|ERROR"
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

log_step "🗜️  Compressing package..."
cd "$PACK_DIR"
SUPER_ZIP="ota-nexdroid-${OS_VER}_${DEVICE_CODE}_${ANDROID_VER}.zip"
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
if [ ! -z "$TELEGRAM_TOKEN" ] && [ ! -z "$CHAT_ID" ]; then
    log_step "📣 Sending Telegram notification..."
    tg_progress "✅ **Build Complete! Sending report...**"
    
    BUILD_DATE=$(date +"%Y-%m-%d %H:%M")
    
    curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/deleteMessage" \
        -d chat_id="$CHAT_ID" \
        -d message_id="$TG_MSG_ID" >/dev/null

    SAFE_TEXT="NEXDROID BUILD COMPLETE
---------------------------
\`in quotes\`
Device  : $DEVICE_CODE
Version : $OS_VER
Android : $ANDROID_VER
Built   : $BUILD_DATE

\`work done\`
All patches applied successfully.
Mods: \`$MODS_SELECTED\`

\`error\`
No critical errors.

_Click the button below to download._"

    JSON_PAYLOAD=$(jq -n \
        --arg chat_id "$CHAT_ID" \
        --arg text "$SAFE_TEXT" \
        --arg url "$LINK_ZIP" \
        --arg btn "⬇️ Download ROM" \
        '{
            chat_id: $chat_id,
            parse_mode: "Markdown",
            text: $text,
            reply_markup: {
                inline_keyboard: [
                    [{text: $btn, url: $url}],
                    [{text: "☁️ Save to Cloud", url: $url}]
                ]
            }
        }') 

    HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage" \
        -H "Content-Type: application/json" \
        -d "$JSON_PAYLOAD")
    
    if [ "$HTTP_CODE" -eq 200 ]; then
        log_success "✓ Telegram notification sent"
    else
        log_warning "Telegram notification failed (HTTP $HTTP_CODE), output:"
        cat response.json
        log_warning "Trying fallback..."
        curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage" \
            -d chat_id="$CHAT_ID" \
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
