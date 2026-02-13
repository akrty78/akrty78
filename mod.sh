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
SMALI_GDRIVE="YOUR_SMALI_GDRIVE_ID"  # ← paste GDrive ID for smali-2.5.2.jar here

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
dex_patcher.py  ─  HyperOS ROM DEX patching engine  (production v5)
════════════════════════════════════════════════════════════════════
Pipeline (MT Manager DEX editor, scripted):

  1.  unzip <dex>       from APK/JAR        ← manifest NEVER touched
  2.  baksmali d        DEX → smali text
  3.  Python edits      smali text files     ← surgical, targeted
  4.  smali a           smali text → DEX
  5.  zip -0 -u         inject STORE DEX     ← ART requires uncompressed
  6.  zipalign -p 4     re-align APK         ← Android R+ hard requirement
                                               (resources.arsc must be
                                                STORE + 4-byte aligned)

WHY STEP 6 IS MANDATORY:
  zip -0 -u changes the DEX entry size, shifting all subsequent entries.
  resources.arsc that was previously 4-byte aligned is now misaligned.
  Android 11+ (targetSdk 30+) enforces this at install time:
    "Targeting R+ requires resources.arsc to be stored uncompressed
     and aligned on a 4-byte boundary"  [-124 / INSTALL_FAILED_INVALID_APK]

  zipalign -p 4 rebuilds the ZIP with every uncompressed entry 4-byte
  aligned by padding the local file extra field. Resources.arsc keeps
  its STORE compression, just gets a correct offset. Zero content change.

Commands:
  verify              check baksmali + smali + zipalign are functional
  framework-sig       disable signature verification in framework.jar
  settings-ai         enable AI features in Settings.apk
  systemui-volte      enable VoLTE icons in MiuiSystemUI.apk
  provision-gms       enable GMS in Provision.apk
  miui-service        CN→Global patch for miui-services.jar
  voice-recorder-ai   enable AI features in SoundRecorder APK
"""

import sys, os, re, subprocess, tempfile, shutil, zipfile, traceback
from pathlib import Path
from typing import Callable

# ── Tool locations ────────────────────────────────────────────────
_BIN = Path(os.environ.get("BIN_DIR", Path(__file__).parent))
BAKSMALI = _BIN / "baksmali.jar"
SMALI    = _BIN / "smali.jar"
API      = "35"

# ── Logger ────────────────────────────────────────────────────────
def _p(tag: str, msg: str) -> None:
    print(f"[{tag}] {msg}", flush=True)

def info(m):  _p("INFO",    m)
def ok(m):    _p("SUCCESS", m)
def warn(m):  _p("WARNING", m)
def err(m):   _p("ERROR",   m)


# ════════════════════════════════════════════════════════════════════
#  TOOL VERIFY
# ════════════════════════════════════════════════════════════════════

def _find_zipalign() -> str | None:
    """Return path to zipalign, or None if not available."""
    # 1. PATH (manager adds build-tools/34.0.0 to PATH)
    found = shutil.which("zipalign")
    if found:
        return found
    # 2. Explicit build-tools paths (in case PATH isn't set)
    sdk = _BIN / "android-sdk"
    for bt in sorted(sdk.glob("build-tools/*/zipalign"), reverse=True):
        if bt.exists():
            return str(bt)
    return None

def cmd_verify() -> None:
    all_ok = True
    for jar in (BAKSMALI, SMALI):
        if not jar.exists():
            err(f"{jar.name} not found at {jar}"); all_ok = False; continue
        sz = jar.stat().st_size
        if sz < 500_000:
            err(f"{jar.name} too small ({sz}B)"); all_ok = False; continue
        r = subprocess.run(["java", "-jar", str(jar)],
                           capture_output=True, text=True, timeout=15)
        if "ClassNotFoundException" in r.stderr:
            err(f"{jar.name} broken: {r.stderr[:100]}"); all_ok = False; continue
        ok(f"{jar.name} ({sz:,}B)")
    za = _find_zipalign()
    if za:
        ok(f"zipalign at {za}")
    else:
        warn("zipalign not found — APK alignment step will be skipped (JARs unaffected)")
    sys.exit(0 if all_ok else 1)


# ════════════════════════════════════════════════════════════════════
#  ALIGNMENT HELPERS
# ════════════════════════════════════════════════════════════════════

def _check_resources_arsc(archive: Path) -> dict:
    """
    Return info about resources.arsc in the ZIP:
      {'exists': bool, 'compressed': bool, 'aligned': bool, 'offset': int}
    """
    result = {'exists': False, 'compressed': False, 'aligned': True, 'offset': 0}
    try:
        with zipfile.ZipFile(archive) as z:
            if 'resources.arsc' not in z.namelist():
                return result
            info_obj = z.getinfo('resources.arsc')
            result['exists'] = True
            result['compressed'] = info_obj.compress_type != zipfile.ZIP_STORED
            # header_offset + 30 (fixed header) + len(filename) + len(extra)
            data_offset = (info_obj.header_offset + 30
                           + len(info_obj.filename.encode()) + len(info_obj.extra))
            result['offset'] = data_offset
            result['aligned'] = (data_offset % 4) == 0
    except Exception as exc:
        warn(f"  resources.arsc check failed: {exc}")
    return result


def _zipalign(archive: Path) -> bool:
    """
    Run zipalign -p 4 to align all uncompressed entries to 4-byte boundaries.
    This is the only correct way to fix resources.arsc alignment after zip modification.
    Returns True on success.
    """
    za = _find_zipalign()
    if not za:
        warn("  zipalign not found — skipping alignment (APK may fail to install)")
        return False

    tmp = archive.with_name(f"_za_{archive.name}")
    try:
        r = subprocess.run(
            [za, "-p", "-f", "4", str(archive), str(tmp)],
            capture_output=True, text=True, timeout=120)
        if r.returncode != 0:
            err(f"  zipalign failed: {r.stderr[:200]}")
            tmp.unlink(missing_ok=True)
            return False
        if not tmp.exists() or tmp.stat().st_size < 1000:
            err("  zipalign produced empty output")
            tmp.unlink(missing_ok=True)
            return False
        shutil.move(str(tmp), str(archive))

        # Verify alignment was actually applied
        arsc = _check_resources_arsc(archive)
        if arsc['exists']:
            if arsc['compressed']:
                err("  resources.arsc still compressed after zipalign!")
                return False
            if not arsc['aligned']:
                err(f"  resources.arsc still misaligned (offset={arsc['offset']})")
                return False
            ok(f"  ✓ resources.arsc: STORE, aligned at offset {arsc['offset']}")
        else:
            ok("  ✓ zipalign applied (no resources.arsc in this archive)")
        return True

    except Exception as exc:
        err(f"  zipalign crashed: {exc}")
        tmp.unlink(missing_ok=True)
        return False


def _python_ensure_arsc_stored(archive: Path) -> bool:
    """
    Fallback when zipalign is unavailable:
    Rebuild ZIP ensuring resources.arsc uses STORE compression.
    NOTE: This does NOT fix 4-byte alignment — alignment requires zipalign
    or manual extra-field padding. Use this only as a last resort.
    """
    try:
        tmp = archive.with_name(f"_tmp_{archive.name}")
        with zipfile.ZipFile(archive, 'r') as zin, \
             zipfile.ZipFile(tmp, 'w', allowZip64=True) as zout:
            for item in zin.infolist():
                data = zin.read(item.filename)
                if (item.filename.endswith('.dex') or
                        item.filename == 'resources.arsc'):
                    zout.writestr(item.filename, data,
                                  compress_type=zipfile.ZIP_STORED)
                else:
                    zout.writestr(item, data,
                                  compress_type=item.compress_type)
        shutil.move(str(tmp), str(archive))
        warn("  resources.arsc stored uncompressed (no zipalign — alignment not guaranteed)")
        return True
    except Exception as exc:
        err(f"  python arsc fallback failed: {exc}")
        return False


# ════════════════════════════════════════════════════════════════════
#  CORE PIPELINE
# ════════════════════════════════════════════════════════════════════

def list_dexes(archive: Path) -> list:
    with zipfile.ZipFile(archive) as z:
        names = [n for n in z.namelist() if re.match(r'^classes\d*\.dex$', n)]
    return sorted(names, key=lambda x: 0 if x == "classes.dex"
                                       else int(re.search(r'\d+', x).group()))


def dex_has(archive: Path, dex_name: str, *needles: str) -> bool:
    with zipfile.ZipFile(archive) as z:
        raw = z.read(dex_name)
    return any(n.encode() in raw for n in needles)


def patch_dex(archive: Path, dex_name: str,
              patch_fn: Callable[[Path], bool]) -> bool:
    """
    Full pipeline for one DEX inside an archive.
    Returns True on success, False on any failure.
    """
    is_apk = archive.suffix.lower() == '.apk'
    work = Path(tempfile.mkdtemp(prefix="dp_"))

    try:
        # 1. Extract DEX
        dex = work / dex_name
        with zipfile.ZipFile(archive) as z:
            dex.write_bytes(z.read(dex_name))
        info(f"  {dex_name}: {dex.stat().st_size // 1024}K extracted")

        # 2. baksmali decompile
        smali_out = work / "smali"
        smali_out.mkdir()
        r = subprocess.run(
            ["java", "-jar", str(BAKSMALI), "d", "-a", API,
             str(dex), "-o", str(smali_out)],
            capture_output=True, text=True, timeout=600)
        if r.returncode != 0:
            err(f"  baksmali failed: {r.stderr[:400]}"); return False
        info(f"  baksmali: {sum(1 for _ in smali_out.rglob('*.smali'))} smali files")

        # 3. Apply patch function
        try:
            changed = patch_fn(smali_out)
        except Exception as exc:
            err(f"  patch_fn raised: {exc}"); traceback.print_exc(); return False

        if not changed:
            warn(f"  {dex_name}: no patches applied in this DEX")
            return False

        # 4. smali recompile
        new_dex = work / f"_out_{dex_name}"
        r = subprocess.run(
            ["java", "-jar", str(SMALI), "a", "-a", API,
             str(smali_out), "-o", str(new_dex)],
            capture_output=True, text=True, timeout=600)
        if r.returncode != 0:
            err(f"  smali failed: {r.stderr[:400]}"); return False
        info(f"  smali:    {new_dex.stat().st_size // 1024}K recompiled")

        # 5. zip -0 -u → inject DEX as STORE (ART requires uncompressed DEX)
        shutil.copy2(new_dex, work / dex_name)
        r = subprocess.run(
            ["zip", "-0", "-u", str(archive), dex_name],
            cwd=str(work), capture_output=True, text=True)
        # rc=12 means "nothing to update" (bytes identical) — fine
        if r.returncode not in (0, 12):
            err(f"  zip failed (rc={r.returncode}): {r.stderr}"); return False

        # 6. zipalign → fix resources.arsc alignment broken by zip modification
        #    MANDATORY for APKs targeting SDK 30+ (Android R+)
        #    Not needed for JARs (no resources.arsc)
        if is_apk:
            info("  Checking resources.arsc alignment...")
            arsc = _check_resources_arsc(archive)
            if arsc['exists']:
                status = []
                if arsc['compressed']:  status.append("COMPRESSED ← must fix")
                if not arsc['aligned']: status.append(f"misaligned at {arsc['offset']} ← must fix")
                if status:
                    warn(f"  resources.arsc: {', '.join(status)}")
                    if not _zipalign(archive):
                        # Last resort: at least ensure STORE compression
                        _python_ensure_arsc_stored(archive)
                else:
                    ok(f"  resources.arsc already OK (STORE, aligned at {arsc['offset']})")
            else:
                info("  No resources.arsc in APK (DEX-only APK)")

        ok(f"  ✓ {dex_name} patched")
        return True

    except Exception as exc:
        err(f"  patch_dex crash: {exc}"); traceback.print_exc(); return False
    finally:
        shutil.rmtree(work, ignore_errors=True)


def run_on_archive(archive: Path, needles: list,
                   patch_fn: Callable[[Path], bool], label: str) -> int:
    archive = archive.resolve()
    if not archive.exists():
        err(f"Not found: {archive}"); return 0
    info(f"Archive: {archive.name}  ({archive.stat().st_size // 1024}K)")

    bak = Path(str(archive) + ".bak")
    if not bak.exists():
        shutil.copy2(archive, bak); ok("✓ Backup created")

    count = 0
    for dex in list_dexes(archive):
        if dex_has(archive, dex, *needles):
            info(f"→ {dex} contains target classes")
            if patch_dex(archive, dex, patch_fn):
                count += 1
        else:
            info(f"  {dex} – no relevant classes, skip")

    if count:
        ok(f"✅ {label}: {count} DEX(es) patched  ({archive.stat().st_size // 1024}K)")
    else:
        err(f"✗ {label}: nothing patched – restoring backup")
        shutil.copy2(bak, archive)
    return count


# ════════════════════════════════════════════════════════════════════
#  SMALI TEXT HELPERS
#  All use while-loops for line iteration — safe against del/insert.
# ════════════════════════════════════════════════════════════════════

def _p_safe(fn, *args) -> int:
    try:
        return fn(*args)
    except Exception as exc:
        warn(f"    {fn.__name__} failed: {exc}")
        return 0


def force_return(d: Path, key: str, val: str) -> int:
    """All non-void methods containing key → const/4 v0, 0x{val}; return v0"""
    stub_const = f"const/4 v0, 0x{val}"
    total = 0
    for f in d.rglob("*.smali"):
        lines = f.read_text(errors="replace").splitlines()
        i, chg = 0, False
        while i < len(lines):
            s = lines[i].lstrip()
            if s.startswith(".method") and key in s and ")V" not in s:
                j = i + 1
                while j < len(lines) and not lines[j].lstrip().startswith(".end method"):
                    j += 1
                if j >= len(lines): i += 1; continue
                body = lines[i:j+1]
                if (len(body) >= 4 and body[2].strip() == stub_const
                        and body[3].strip().startswith("return")):
                    i = j + 1; continue
                lines[i:j+1] = [lines[i], "    .registers 8",
                                 f"    {stub_const}", "    return v0", ".end method"]
                chg = True; total += 1; i += 5
            else:
                i += 1
        if chg: f.write_text("\n".join(lines) + "\n")
    if total: ok(   f"    force_return({key!r} → 0x{val}): {total}")
    else:     warn(  f"    force_return({key!r}): not found")
    return total


def force_return_void(d: Path, key: str) -> int:
    """All void methods containing key → return-void immediately."""
    total = 0
    for f in d.rglob("*.smali"):
        lines = f.read_text(errors="replace").splitlines()
        i, chg = 0, False
        while i < len(lines):
            s = lines[i].lstrip()
            if s.startswith(".method") and key in s and ")V" in s:
                j = i + 1
                while j < len(lines) and not lines[j].lstrip().startswith(".end method"):
                    j += 1
                if j >= len(lines): i += 1; continue
                lines[i:j+1] = [lines[i], "    .registers 1",
                                 "    return-void", ".end method"]
                chg = True; total += 1; i += 4
            else:
                i += 1
        if chg: f.write_text("\n".join(lines) + "\n")
    if total: ok(   f"    force_return_void({key!r}): {total}")
    else:     warn(  f"    force_return_void({key!r}): not found")
    return total


def replace_move_result(d: Path, invoke: str, replacement: str) -> int:
    """Replace move-result* after any line containing invoke."""
    total = 0
    for f in d.rglob("*.smali"):
        lines = f.read_text(errors="replace").splitlines()
        i, chg = 0, False
        while i < len(lines):
            if invoke in lines[i]:
                for j in range(i + 1, min(i + 6, len(lines))):
                    if lines[j].strip().startswith("move-result"):
                        ind = re.match(r"\s*", lines[j]).group(0)
                        nl = f"{ind}{replacement}"
                        if lines[j] != nl:
                            lines[j] = nl; chg = True; total += 1
                        break
            i += 1
        if chg: f.write_text("\n".join(lines) + "\n")
    if total: ok(   f"    replace_move_result: {total} site(s)")
    else:     warn(  f"    replace_move_result({invoke[-40:]!r}): not found")
    return total


def insert_before(d: Path, pattern: str, new_line: str) -> int:
    """Insert new_line (with matching indent) before every line containing pattern."""
    total = 0
    for f in d.rglob("*.smali"):
        lines = f.read_text(errors="replace").splitlines()
        i, chg = 0, False
        while i < len(lines):
            if pattern in lines[i]:
                ind = re.match(r"\s*", lines[i]).group(0)
                cand = f"{ind}{new_line}"
                if i == 0 or lines[i - 1].strip() != new_line.strip():
                    lines.insert(i, cand); chg = True; total += 1; i += 2
                else:
                    i += 1
            else:
                i += 1
        if chg: f.write_text("\n".join(lines) + "\n")
    if total: ok(   f"    insert_before({pattern!r}): {total}")
    else:     warn(  f"    insert_before({pattern!r}): not found")
    return total


def strip_if_eqz_after(d: Path, pattern: str) -> int:
    """
    Remove the first if-eqz guard following any line containing pattern.
    Uses while-loop — safe when lines are deleted during traversal.
    """
    total = 0
    for f in d.rglob("*.smali"):
        lines = f.read_text(errors="replace").splitlines()
        chg = False
        i = 0
        while i < len(lines):
            if pattern in lines[i]:
                j = i + 1
                while j < min(i + 12, len(lines)):
                    if re.match(r'\s*if-eqz\s', lines[j]):
                        del lines[j]
                        chg = True; total += 1
                        break
                    j += 1
            i += 1
        if chg: f.write_text("\n".join(lines) + "\n")
    if total: ok(   f"    strip_if_eqz_after({pattern[-50:]!r}): {total}")
    else:     warn(  f"    strip_if_eqz_after: not found")
    return total


def sed_all(d: Path, find_re: str, replace: str) -> int:
    """Regex substitution across all smali files."""
    pat = re.compile(find_re)
    total = 0
    for f in d.rglob("*.smali"):
        t = f.read_text(errors="replace")
        new_t, n = pat.subn(replace, t)
        if n: f.write_text(new_t); total += n
    if total: ok(   f"    sed_all: {total} match(es)")
    else:     warn(  f"    sed_all: not found")
    return total


# ════════════════════════════════════════════════════════════════════
#  PATCH PROFILES
# ════════════════════════════════════════════════════════════════════

def _sig_patch(d: Path) -> bool:
    n = 0
    n += _p_safe(insert_before, d,
        "ApkSignatureVerifier;->unsafeGetCertsWithoutVerification", "const/4 v1, 0x1")
    n += _p_safe(insert_before, d,
        "iput p1, p0, Landroid/content/pm/PackageParser$PackageParserException;->error:I",
        "const/4 p1, 0x0")
    n += _p_safe(force_return, d, "checkCapability",        "1")
    n += _p_safe(force_return, d, "checkCapabilityRecover", "1")
    n += _p_safe(force_return, d, "hasAncestorOrSelf",      "1")
    n += _p_safe(replace_move_result, d,
        "invoke-static {v8, v4}, Ljava/security/MessageDigest;->isEqual([B[B)Z",
        "const/4 v0, 0x1")
    n += _p_safe(replace_move_result, d,
        "invoke-static {v9, v3}, Ljava/security/MessageDigest;->isEqual([B[B)Z",
        "const/4 v0, 0x1")
    n += _p_safe(force_return, d, "getMinimumSignatureSchemeVersionForTargetSdk", "0")
    n += _p_safe(insert_before, d,
        "ApkSignatureVerifier;->verifyV1Signature", "const p3, 0x0")
    n += _p_safe(replace_move_result, d,
        "invoke-static {v5, v6}, Ljava/security/MessageDigest;->isEqual([B[B)Z",
        "const/4 v7, 0x1")
    n += _p_safe(force_return, d, "verifyMessageDigest", "1")
    n += _p_safe(strip_if_eqz_after, d,
        "Landroid/util/jar/StrictJarFile;->findEntry(Ljava/lang/String;)Ljava/util/zip/ZipEntry;")
    n += _p_safe(insert_before, d,
        "manifest> specifies bad sharedUserId name", "const/4 v4, 0x0")
    info(f"    Patches applied this DEX: {n}")
    return n > 0


def _intl_build_patch(d: Path) -> bool:
    n = 0
    n += _p_safe(sed_all, d,
        r'(\s*)sget-boolean (v\d+), Lmiui/os/Build;->IS_INTERNATIONAL_BUILD:Z',
        r'\1const/4 \2, 0x1')
    n += _p_safe(replace_move_result, d,
        "Lmiui/os/Build;->getRegion()Ljava/lang/String;",
        "const/4 v0, 0x1")
    return n > 0


def _ai_patch(d: Path) -> bool:
    total = 0
    for f in d.rglob("*.smali"):
        if "InternalDeviceUtils" not in f.name:
            continue
        lines = f.read_text(errors="replace").splitlines()
        i, chg = 0, False
        while i < len(lines):
            s = lines[i].lstrip()
            is_ai = (s.startswith(".method") and ")V" not in s and
                     any(k in s for k in ("isAi", "AiSupport", "aiSupport",
                                          "SupportAi", "supportAi")))
            if is_ai:
                j = i + 1
                while j < len(lines) and not lines[j].lstrip().startswith(".end method"):
                    j += 1
                if j >= len(lines): i += 1; continue
                name = s.split()[-1] if s.split() else "?"
                lines[i:j+1] = [lines[i], "    .registers 2",
                                 "    const/4 v0, 0x1", "    return v0", ".end method"]
                chg = True; total += 1; ok(f"    Patched: {name}"); i += 5
            else:
                i += 1
        if chg: f.write_text("\n".join(lines) + "\n")
    if total == 0:
        warn("    InternalDeviceUtils not in this DEX")
    return total > 0


def _voice_recorder_patch(d: Path) -> bool:
    n = 0
    for key in ("isAiSupported", "isPremium", "isAiEnabled", "isVipUser",
                "hasAiFeature", "isMiAiSupported"):
        n += _p_safe(force_return, d, key, "1")
    n += _p_safe(sed_all, d,
        r'(\s*)sget-boolean (v\d+), Lmiui/os/Build;->IS_INTERNATIONAL_BUILD:Z',
        r'\1const/4 \2, 0x1')
    return n > 0


# ════════════════════════════════════════════════════════════════════
#  COMMAND TABLE
# ════════════════════════════════════════════════════════════════════

NEEDLES: dict = {
    "framework-sig":    ["ApkSignatureVerifier", "SigningDetails", "StrictJarVerifier",
                         "StrictJarFile", "PackageParser", "ApkSigningBlock",
                         "ParsingPackageUtils"],
    "settings-ai":      ["InternalDeviceUtils"],
    "systemui-volte":   ["IS_INTERNATIONAL_BUILD", "miui/os/Build"],
    "provision-gms":    ["IS_INTERNATIONAL_BUILD"],
    "miui-service":     ["IS_INTERNATIONAL_BUILD", "miui/os/Build"],
    "voice-recorder-ai":["IS_INTERNATIONAL_BUILD", "isAiSupported", "isPremium",
                         "hasAiFeature"],
}

PATCHERS: dict = {
    "framework-sig":    _sig_patch,
    "settings-ai":      _ai_patch,
    "systemui-volte":   _intl_build_patch,
    "provision-gms":    _intl_build_patch,
    "miui-service":     _intl_build_patch,
    "voice-recorder-ai":_voice_recorder_patch,
}


# ════════════════════════════════════════════════════════════════════
#  ENTRY POINT
# ════════════════════════════════════════════════════════════════════

def main() -> None:
    CMDS = sorted(NEEDLES.keys()) + ["verify"]
    if len(sys.argv) < 2 or sys.argv[1] not in CMDS:
        print(f"Usage: dex_patcher.py <{'|'.join(CMDS)}> [archive]", file=sys.stderr)
        sys.exit(1)
    cmd = sys.argv[1]
    if cmd == "verify":
        cmd_verify(); return
    if len(sys.argv) < 3:
        err(f"Usage: dex_patcher.py {cmd} <archive>"); sys.exit(1)
    count = run_on_archive(Path(sys.argv[2]), NEEDLES[cmd], PATCHERS[cmd], cmd)
    sys.exit(0 if count > 0 else 1)

if __name__ == "__main__":
    main()
PYTHON_EOF
chmod +x "$BIN_DIR/dex_patcher.py"
log_success "✓ dex_patcher.py written"

# ── Verify everything works together ────────────────────────────
SMALI_TOOLS_OK=0
if python3 "$BIN_DIR/dex_patcher.py" verify 2>&1 | while IFS= read -r l; do
    case "$l" in
        "[SUCCESS]"*) log_success "${l#[SUCCESS] }" ;;
        "[ERROR]"*)   log_error   "${l#[ERROR] }"   ;;
        *)            [ -n "$l" ] && log_info "$l"   ;;
    esac
done; then
    SMALI_TOOLS_OK=1
    log_success "✓ DEX patcher fully operational"
else
    log_error "DEX patcher verification failed — signature/APK patches will be skipped"
fi

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

            # D2. AI Voice Recorder — hardcoded path per user requirement
            _RECORDER_APK=$(find "$DUMP_DIR" \
                -path "*/product/data-app/MIUISoundRecorderTargetSdk30/MIUISoundRecorderTargetSdk30.apk" \
                -type f | head -n1)
            if [ -z "$_RECORDER_APK" ]; then
                # Fallback: broad search if path changes
                _RECORDER_APK=$(find "$DUMP_DIR" \
                    \( -name "MIUISoundRecorder*.apk" -o -name "SoundRecorder.apk" \) \
                    -type f | head -n1)
            fi
            _run_dex_patch "VOICE RECORDER AI" "voice-recorder-ai" "$_RECORDER_APK"
            cd "$GITHUB_WORKSPACE" 

        fi

        # ── system_ext partition ──────────────────────────────────
        if [ "$part" == "system_ext" ]; then

            # D3. Settings AI support
            _run_dex_patch "SETTINGS AI" "settings-ai" \
                "$(find "$DUMP_DIR" -name "Settings.apk" -type f | head -n1)"
            cd "$GITHUB_WORKSPACE"

            # D4. Provision GMS support
            _run_dex_patch "PROVISION GMS" "provision-gms" \
                "$(find "$DUMP_DIR" -name "Provision.apk" -type f | head -n1)"
            cd "$GITHUB_WORKSPACE"

            # D5. MIUI service CN→Global
            _run_dex_patch "MIUI SERVICE CN→GLOBAL" "miui-service" \
                "$(find "$DUMP_DIR" -name "miui-services.jar" -type f | head -n1)"
            cd "$GITHUB_WORKSPACE"

            # D6. SystemUI VoLTE icons
            _run_dex_patch "SYSTEMUI VOLTE" "systemui-volte" \
                "$(find "$DUMP_DIR" \( -name "MiuiSystemUI.apk" -o -name "SystemUI.apk" \) -type f | head -n1)"
            cd "$GITHUB_WORKSPACE"

        fi



        # E. MIUI-FRAMEWORK (BAIDU->GBOARD)
        if [ "$part" == "system_ext" ]; then
            log_info "⌨️  Redirecting Baidu IME to Gboard..."
            MF_JAR=$(find "$DUMP_DIR" -name "miui-framework.jar" -type f | head -n 1)
            if [ ! -z "$MF_JAR" ]; then
                cp "$MF_JAR" "${MF_JAR}.bak"
                rm -rf "$TEMP_DIR/mf.jar" "$TEMP_DIR/mf_src"
                cp "$MF_JAR" "$TEMP_DIR/mf.jar"
                cd "$TEMP_DIR"
                if timeout 3m apktool d -r -f "mf.jar" -o "mf_src" >/dev/null 2>&1; then
                    PATCHED_FILES=0
                    grep -rl "com.baidu.input_mi" "mf_src" | while read f; do
                        if [[ "$f" == *"InputMethodServiceInjector.smali"* ]]; then
                            sed -i 's/com.baidu.input_mi/com.google.android.inputmethod.latin/g' "$f"
                            PATCHED_FILES=$((PATCHED_FILES + 1))
                            log_success "✓ Patched: InputMethodServiceInjector.smali"
                        fi
                    done
                    apktool b -c "mf_src" -o "mf_patched.jar" >/dev/null 2>&1
                    if [ -f "mf_patched.jar" ]; then
                        mv "mf_patched.jar" "$MF_JAR"
                        log_success "✓ miui-framework.jar patched successfully"
                    fi
                else
                    log_warning "miui-framework decompile timeout - skipping"
                fi
                cd "$GITHUB_WORKSPACE"
            else
                log_warning "miui-framework.jar not found"
            fi
        fi

        # F. MIUI FREQUENT PHRASE (COLORS + GBOARD)
        MFP_APK=$(find "$DUMP_DIR" -name "MIUIFrequentPhrase.apk" -type f -print -quit)
        if [ ! -z "$MFP_APK" ]; then
            log_info "🎨 Modding MIUIFrequentPhrase..."
            rm -rf "$TEMP_DIR/mfp.apk" "$TEMP_DIR/mfp_src"
            cp "$MFP_APK" "$TEMP_DIR/mfp.apk"
            cd "$TEMP_DIR"
            if timeout 3m apktool d -f "mfp.apk" -o "mfp_src" >/dev/null 2>&1; then
                # Redirect to Gboard
                find "mfp_src" -name "InputMethodBottomManager.smali" -exec sed -i 's/com.baidu.input_mi/com.google.android.inputmethod.latin/g' {} +
                log_success "✓ Redirected IME to Gboard"
                
                # Update colors
                if [ -f "mfp_src/res/values/colors.xml" ]; then
                    sed -i 's|<color name="input_bottom_background_color">.*</color>|<color name="input_bottom_background_color">@android:color/system_neutral1_50</color>|g' "mfp_src/res/values/colors.xml"
                    log_success "✓ Updated light theme colors"
                fi
                if [ -f "mfp_src/res/values-night/colors.xml" ]; then
                    sed -i 's|<color name="input_bottom_background_color">.*</color>|<color name="input_bottom_background_color">@android:color/system_neutral1_900</color>|g' "mfp_src/res/values-night/colors.xml"
                    log_success "✓ Updated dark theme colors"
                fi
                
                apktool b -c "mfp_src" -o "mfp_patched.apk" >/dev/null 2>&1
                if [ -f "mfp_patched.apk" ]; then
                    mv "mfp_patched.apk" "$MFP_APK"
                    log_success "✓ MIUIFrequentPhrase patched successfully"
                fi
            else
                log_warning "MIUIFrequentPhrase decompile timeout - skipping"
            fi
            cd "$GITHUB_WORKSPACE"
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
        fi

        # H. BUILD PROPS
        log_info "📝 Adding custom build properties..."
        PROPS_ADDED=0
        find "$DUMP_DIR" -name "build.prop" | while read prop; do
            echo "$PROPS_CONTENT" >> "$prop"
            PROPS_ADDED=$((PROPS_ADDED + 1))
            log_success "✓ Updated: $prop"
        done

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
