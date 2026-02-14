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

# --- INPUTS ---
ROM_URL="$1"

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

        # skip fields
        for _ in range(sf + inf):
            try:
                _, pos = _uleb128(data, pos); _, pos = _uleb128(data, pos)
            except Exception: break

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


# ════════════════════════════════════════════════════════════════════
#  CHECKSUM REPAIR
# ════════════════════════════════════════════════════════════════════

def _fix_checksums(dex: bytearray):
    sha1  = hashlib.sha1(bytes(dex[32:])).digest()
    dex[12:32] = sha1
    adler = zlib.adler32(bytes(dex[12:])) & 0xFFFFFFFF
    struct.pack_into('<I', dex, 8, adler)


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

    # registers_size must be >= ins_size (parameter slots are always at top of frame)
    new_regs = max(stub_regs, orig_ins)

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
#  BINARY PATCH: sget-boolean field → const/16 1
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
        const/16 vAA, 0x1   →  15 AA 01 00   (format 21s, 4 bytes)

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
                        # const/16 vAA, 0x1  (21s)
                        raw[insns_off + i]     = 0x15
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

# ── framework.jar  ───────────────────────────────────────────────
def _fw_sig_patch(dex_name: str, dex: bytearray) -> bool:
    if b'ApkSignatureVerifier' not in bytes(dex): return False
    return binary_patch_method(dex,
        "android/util/apk/ApkSignatureVerifier",
        "getMinimumSignatureSchemeVersionForTargetSdk", 1, _STUB_TRUE)

# ── Settings.apk  ────────────────────────────────────────────────
def _settings_ai_patch(dex_name: str, dex: bytearray) -> bool:
    if b'InternalDeviceUtils' not in bytes(dex): return False
    return binary_patch_method(dex,
        "com/android/settings/InternalDeviceUtils",
        "isAiSupported", 1, _STUB_TRUE)

# ── SoundRecorder APK  ──────────────────────────────────────────
def _recorder_ai_patch(dex_name: str, dex: bytearray) -> bool:
    """
    STRICT SCOPE: AiDeviceUtil::isAiSupportedDevice → return true (const/4 v0,0x1; return v0).
    - Try known package paths first.
    - If AiDeviceUtil string present but path unknown, scan all class defs.
    - NO IS_INTERNATIONAL_BUILD fallback — do not touch unrelated instructions.
    - If class/method not found, report clearly and return False.
    """
    if b'AiDeviceUtil' not in bytes(dex):
        return False

    # Known package paths — try exact match first
    for cls in (
        "com/miui/soundrecorder/utils/AiDeviceUtil",
        "com/miui/soundrecorder/AiDeviceUtil",
        "com/miui/recorder/utils/AiDeviceUtil",
        "com/miui/recorder/AiDeviceUtil",
    ):
        if binary_patch_method(dex, cls, "isAiSupportedDevice",
                               stub_regs=1, stub_insns=_STUB_TRUE):
            return True

    # Class present but package path unknown — scan all class defs
    info("  AiDeviceUtil: known paths missed, scanning all class defs...")
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
            if 'AiDeviceUtil' in type_str and type_str.startswith('L') and type_str.endswith(';'):
                cls_path = type_str[1:-1]
                if binary_patch_method(dex, cls_path, "isAiSupportedDevice",
                                       stub_regs=1, stub_insns=_STUB_TRUE):
                    return True
        except Exception:
            continue

    warn("  AiDeviceUtil::isAiSupportedDevice not found in any DEX class")
    return False

# ── services.jar  ────────────────────────────────────────────────
def _services_jar_patch(dex_name: str, dex: bytearray) -> bool:
    """
    ActivityManagerService$$ExternalSyntheticLambda31::run()V → return-void.
    registers 2 → 1, body cleared.
    """
    if b'ExternalSyntheticLambda31' not in bytes(dex): return False
    return binary_patch_method(dex,
        "com/android/server/am/ActivityManagerService$$ExternalSyntheticLambda31",
        "run", 1, _STUB_VOID)

# ── IS_INTERNATIONAL_BUILD (Lmiui/os/Build;)  ────────────────────
def _intl_build_patch(dex_name: str, dex: bytearray) -> bool:
    if b'IS_INTERNATIONAL_BUILD' not in bytes(dex): return False
    n = binary_patch_sget_to_true(dex, 'Lmiui/os/Build;', 'IS_INTERNATIONAL_BUILD')
    return n > 0

# ── SystemUI combined: VoLTE (MiuiMobileIconBinder family) + QuickShare + WA ──
def _systemui_all_patch(dex_name: str, dex: bytearray) -> bool:
    """
    STRICT SCOPE — three independent targets, each class+method pinned:

    1. VoLTE icons: Lmiui/os/Build;->IS_INTERNATIONAL_BUILD
       ONLY inside MiuiMobileIconBinder and its inner classes
       (substring 'MiuiMobileIconBinder' catches $bind$1$1$1 … $bind$1$1$10 etc.)

    2. QuickShare: Lcom/miui/utils/configs/MiuiConfigs;->IS_INTERNATIONAL_BUILD
       ONLY inside CurrentTilesInteractorImpl::createTileSync
       Replace with const/4 pX, 0x1 (keep register)

    3. WA notification: Lcom/miui/utils/configs/MiuiConfigs;->IS_INTERNATIONAL_BUILD
       ONLY inside NotificationUtil::isEmptySummary
       Replace with const/4 v3, 0x1 (keep register v3)
    """
    patched = False
    raw = bytes(dex)

    # 1. VoLTE — MiuiMobileIconBinder family ONLY
    if b'MiuiMobileIconBinder' in raw and b'IS_INTERNATIONAL_BUILD' in raw and b'miui/os/Build' in raw:
        if binary_patch_sget_to_true(dex,
                'Lmiui/os/Build;', 'IS_INTERNATIONAL_BUILD',
                only_class='MiuiMobileIconBinder') > 0:
            patched = True
            raw = bytes(dex)

    # 2. QuickShare — CurrentTilesInteractorImpl::createTileSync ONLY, const/4
    if b'CurrentTilesInteractorImpl' in raw and b'MiuiConfigs' in raw:
        if binary_patch_sget_to_true(dex,
                'Lcom/miui/utils/configs/MiuiConfigs;', 'IS_INTERNATIONAL_BUILD',
                only_class='CurrentTilesInteractorImpl',
                only_method='createTileSync',
                use_const4=True) > 0:
            patched = True
            raw = bytes(dex)

    # 3. WA notification — NotificationUtil::isEmptySummary ONLY, const/4, keep v3
    if b'NotificationUtil' in raw and b'MiuiConfigs' in raw:
        if binary_patch_sget_to_true(dex,
                'Lcom/miui/utils/configs/MiuiConfigs;', 'IS_INTERNATIONAL_BUILD',
                only_class='NotificationUtil',
                only_method='isEmptySummary',
                use_const4=True) > 0:
            patched = True

    return patched

# ── miui-framework.jar  ─────────────────────────────────────────
def _miui_framework_patch(dex_name: str, dex: bytearray) -> bool:
    patched = False
    # (1) ThemeReceiver::validateTheme → return-void
    #     trim=True: insns_size shrinks to 1 cu. baksmali sees exactly:
    #       .registers 5
    #       return-void
    #     No nop, no annotations added.
    if b'ThemeReceiver' in bytes(dex):
        if binary_patch_method(dex,
                "miui/drm/ThemeReceiver", "validateTheme",
                stub_regs=5, stub_insns=_STUB_VOID, trim=True):
            patched = True
    # (2) IS_GLOBAL_BUILD: no class filter — only jar in scope is miui-framework itself
    if b'IS_GLOBAL_BUILD' in bytes(dex):
        if binary_patch_sget_to_true(dex, 'Lmiui/os/Build;', 'IS_GLOBAL_BUILD') > 0:
            patched = True
    return patched

# ── Settings.apk region unlock  ─────────────────────────────────
def _settings_region_patch(dex_name: str, dex: bytearray) -> bool:
    """
    STRICT SCOPE: ONLY class OtherPersonalSettings, both IS_GLOBAL_BUILD lines.
    Do NOT patch LocaleController, LocaleSettingsTree, or any other class.
    """
    if b'IS_GLOBAL_BUILD' not in bytes(dex): return False
    if b'OtherPersonalSettings' not in bytes(dex): return False
    # Both IS_GLOBAL_BUILD sget instructions inside OtherPersonalSettings get patched.
    n = binary_patch_sget_to_true(dex, 'Lmiui/os/Build;', 'IS_GLOBAL_BUILD',
                                   only_class='OtherPersonalSettings')
    return n > 0


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

# ── MIUIFrequentPhrase.apk — Gboard redirect  ────────────────────
_BAIDU_IME  = "com.baidu.input_mi"
_GBOARD_IME = "com.google.android.inputmethod.latin"

def _miuifreqphrase_patch(dex_name: str, dex: bytearray) -> bool:
    """
    Binary const-string swap inside two classes:
      InputMethodBottomManager  (com/miui/inputmethod/)
      InputProvider             (com/miui/provider/)
    Only the string literal reference is changed — no method restructuring,
    no register changes, no class renames. Zero apktool, zero timeout risk.
    """
    if _BAIDU_IME.encode() not in bytes(dex): return False
    n = 0
    n += binary_swap_string(dex, _BAIDU_IME, _GBOARD_IME,
                            only_class='InputMethodBottomManager')
    n += binary_swap_string(dex, _BAIDU_IME, _GBOARD_IME,
                            only_class='InputProvider')
    if n == 0:
        # Fallback: swap all refs in DEX (covers different packaging)
        n += binary_swap_string(dex, _BAIDU_IME, _GBOARD_IME)
    return n > 0


# ════════════════════════════════════════════════════════════════════
#  COMMAND TABLE  +  ENTRY POINT
# ════════════════════════════════════════════════════════════════════

PROFILES = {
    "framework-sig":     _fw_sig_patch,
    "settings-ai":       _settings_ai_patch,
    "settings-region":   _settings_region_patch,   # exact 3 classes only
    "voice-recorder-ai": _recorder_ai_patch,        # AiDeviceUtil::isAiSupportedDevice
    "services-jar":      _services_jar_patch,
    "provision-gms":     _intl_build_patch,
    "miui-service":      _intl_build_patch,
    "systemui-volte":    _systemui_all_patch,       # VoLTE + QuickShare(const/4) + WA-notif
    "miui-framework":    _miui_framework_patch,     # validateTheme(trim) + IS_GLOBAL_BUILD
    "incallui-ai":       _incallui_patch,           # RecorderUtils::isAiRecordEnable
    "miuifreqphrase":    _miuifreqphrase_patch,     # Baidu→Gboard binary string swap
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
log_success "✓ dex_patcher.py written"

# ── dex_patcher.py is self-contained (no baksmali/smali needed) ──
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
#  4. DOWNLOAD & EXTRACT ROM
# =========================================================
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
            P_PRIV="Wizard Velvet Phonesky MIUIPackageInstaller GoogleRestore GooglePartnerSetup Assistant AndroidAutoStub"
            
            install_gapp_logic "$P_PRIV" "$PRIV_ROOT"
            install_gapp_logic "$P_APP" "$APP_ROOT"
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

            # D1. Signature verification bypass (framework.jar)
            _run_dex_patch "SIGNATURE BYPASS" "framework-sig" \
                "$(find "$DUMP_DIR" -path "*/framework/framework.jar" -type f | head -n1)"
            cd "$GITHUB_WORKSPACE"

            # D2. services.jar — suppress error dialogs (Lambda31.run → return-void)
            _run_dex_patch "SERVICES DIALOGS" "services-jar" \
                "$(find "$DUMP_DIR" -path "*/framework/services.jar" -type f | head -n1)"
            cd "$GITHUB_WORKSPACE"

        fi

        # ── product partition ────────────────────────────────────────
        if [ "$part" == "product" ]; then

            # D3. AI Voice Recorder — exact path: product/data-app/...
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

            # D4. Settings AI + Region unlock (IS_GLOBAL_BUILD in locale classes)
            _SETTINGS_APK="$(find "$DUMP_DIR" -name "Settings.apk" -type f | head -n1)"
            _run_dex_patch "SETTINGS AI"     "settings-ai"     "$_SETTINGS_APK"
            cd "$GITHUB_WORKSPACE"
            _run_dex_patch "SETTINGS REGION" "settings-region" "$_SETTINGS_APK"
            cd "$GITHUB_WORKSPACE"

            # D5. Provision GMS support
            _run_dex_patch "PROVISION GMS" "provision-gms" \
                "$(find "$DUMP_DIR" -name "Provision.apk" -type f | head -n1)"
            cd "$GITHUB_WORKSPACE"

            # D6. MIUI service CN→Global
            _run_dex_patch "MIUI SERVICE CN→GLOBAL" "miui-service" \
                "$(find "$DUMP_DIR" -name "miui-services.jar" -type f | head -n1)"
            cd "$GITHUB_WORKSPACE"

            # D7. SystemUI: VoLTE + QuickShare + WhatsApp notification fix
            _run_dex_patch "SYSTEMUI ALL" "systemui-volte" \
                "$(find "$DUMP_DIR" \( -name "MiuiSystemUI.apk" -o -name "SystemUI.apk" \) -type f | head -n1)"
            cd "$GITHUB_WORKSPACE"

            # D8. miui-framework: ThemeReceiver bypass + IS_GLOBAL_BUILD
            _run_dex_patch "MIUI FRAMEWORK" "miui-framework" \
                "$(find "$DUMP_DIR" -name "miui-framework.jar" -type f | head -n1)"
            cd "$GITHUB_WORKSPACE"

            # D9. nexdroid.rc — bootloader spoof init script
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



        # E. MIUI-FRAMEWORK (handled via dex_patcher.py miui-framework profile above)
        #    ThemeReceiver bypass + IS_GLOBAL_BUILD already done in D8 above.

        # F. MIUI FREQUENT PHRASE — Gboard redirect
        MFP_APK=$(find "$DUMP_DIR" -name "MIUIFrequentPhrase.apk" -type f -print -quit)
        if [ -n "$MFP_APK" ]; then
            log_info "🎨 Modding MIUIFrequentPhrase..."

            # ── Pass 1: binary const-string swap (zero timeout risk) ──────────
            # Works only if "com.google.android.inputmethod.latin" already exists
            # in the DEX string pool. Graceful skip if it doesn't.
            _run_dex_patch "MIUIFREQPHRASE GBOARD" "miuifreqphrase" "$MFP_APK"

            # ── Pass 2: verify — if Baidu string still present, use apktool -r ─
            if python3 -c "
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    for n in z.namelist():
        if n.startswith('classes') and n.endswith('.dex'):
            if b'com.baidu.input_mi' in z.read(n):
                sys.exit(1)
sys.exit(0)
" "$MFP_APK" 2>/dev/null; then
                log_success "✓ MIUIFrequentPhrase Gboard redirect confirmed (binary swap)"
            else
                log_warning "Binary swap incomplete — trying apktool -r fallback (no-res, fast)"
                MFP_WORK="$TEMP_DIR/mfp_work"
                rm -rf "$MFP_WORK"
                MFP_OK=0
                if timeout 10m apktool d -r -f "$MFP_APK" -o "$MFP_WORK" >/dev/null 2>&1; then
                    # Only patch the two target smali files — no method restructure
                    find "$MFP_WORK/smali" \
                        \( -name "InputMethodBottomManager.smali" -o -name "InputProvider.smali" \) \
                        -exec sed -i 's|com\.baidu\.input_mi|com.google.android.inputmethod.latin|g' {} +
                    log_success "✓ String replaced in smali target classes"
                    if timeout 8m apktool b -c "$MFP_WORK" -o "${MFP_APK}.tmp" >/dev/null 2>&1; then
                        mv "${MFP_APK}.tmp" "$MFP_APK"
                        log_success "✓ MIUIFrequentPhrase patched via apktool fallback"
                        MFP_OK=1
                    else
                        rm -f "${MFP_APK}.tmp"
                        log_warning "apktool build failed — MIUIFrequentPhrase unchanged"
                    fi
                else
                    log_warning "apktool -r timed out (10m) — MIUIFrequentPhrase unchanged"
                fi
                rm -rf "$MFP_WORK"
                [ "$MFP_OK" -eq 0 ] && log_warning "⚠ MIUIFrequentPhrase Gboard redirect skipped"
            fi

            cd "$GITHUB_WORKSPACE"

            # Colors XML update (resource-only, safe to do via zipfile sed)
            python3 - "$MFP_APK" <<'COLORS_PY' 2>&1 | while IFS= read -r l; do [ -n "$l" ] && echo "[INFO] $l"; done
import sys, zipfile, shutil, tempfile, pathlib, re

apk = pathlib.Path(sys.argv[1])
tmp = apk.with_name("_colors_" + apk.name)
patched = 0
with zipfile.ZipFile(apk, 'r') as zin, zipfile.ZipFile(tmp, 'w', zipfile.ZIP_DEFLATED) as zout:
    for item in zin.infolist():
        data = zin.read(item.filename)
        if item.filename in ('res/values/colors.xml', 'res/values-night/colors.xml'):
            txt = data.decode('utf-8', errors='replace')
            replacement = ('@android:color/system_neutral1_50' if 'night' not in item.filename
                           else '@android:color/system_neutral1_900')
            new_txt = re.sub(
                r'(<color name="input_bottom_background_color">)[^<]*(</color>)',
                rf'\g<1>{replacement}\g<2>', txt)
            if new_txt != txt:
                data = new_txt.encode('utf-8')
                patched += 1
                print(f"[SUCCESS] ✓ Colors patched: {item.filename}")
        zout.writestr(item, data)
if patched:
    shutil.move(str(tmp), str(apk))
    print(f"[SUCCESS] ✓ MIUIFrequentPhrase colors updated ({patched} file(s))")
else:
    tmp.unlink(missing_ok=True)
    print("[INFO] colors.xml not found in APK — colors step skipped")
COLORS_PY
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
cd "$OUTPUT_DIR"

upload() {
    local file=$1
    [ ! -f "$file" ] && return
    log_info "Uploading $file..."
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
    BUILD_DATE=$(date +"%Y-%m-%d %H:%M")
    
    MSG_TEXT="**NEXDROID BUILD COMPLETE**
---------------------------
\`Device  : $DEVICE_CODE\`
\`Version : $OS_VER\`
\`Android : $ANDROID_VER\`
\`Built   : $BUILD_DATE\`"

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

    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage" \
        -H "Content-Type: application/json" \
        -d "$JSON_PAYLOAD")
    
    if [[ "$RESPONSE" == *"200"* ]]; then
        log_success "✓ Telegram notification sent"
    else
        log_warning "Telegram notification failed, trying fallback..."
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
