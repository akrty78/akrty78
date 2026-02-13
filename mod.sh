#!/bin/bash

# =========================================================
#  NEXDROID MANAGER - v58 (APK-124 FIXED)
#  All APK/JAR patching now routes through nexmod_apk.py
#  which guarantees STORE + 4B-aligned resources.arsc
#  → eliminates Android -124 install failure permanently
# =========================================================

set +e

# --- COLOR CODES ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; NC='\033[0m'

# --- LOGGING ---
log_info()    { echo -e "${CYAN}[INFO]${NC} $(date +"%H:%M:%S") - $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $(date +"%H:%M:%S") - $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $(date +"%H:%M:%S") - $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $(date +"%H:%M:%S") - $1"; }
log_step()    { echo -e "${MAGENTA}[STEP]${NC} $(date +"%H:%M:%S") - $1"; }

# --- INPUTS ---
ROM_URL="$1"

# =========================================================
#  1. METADATA EXTRACTION
# =========================================================
FILENAME=$(basename "$ROM_URL" | cut -d'?' -f1)
log_step "🔍 Analyzing OTA Link..."
DEVICE_CODE=$(echo "$FILENAME" | awk -F'-ota_full' '{print $1}')
OS_VER=$(echo "$FILENAME" | awk -F'ota_full-' '{print $2}' | awk -F'-user' '{print $1}')
ANDROID_VER=$(echo "$FILENAME" | awk -F'user-' '{print $2}' | cut -d'-' -f1)
[ -z "$DEVICE_CODE" ] && DEVICE_CODE="UnknownDevice"
[ -z "$OS_VER" ]      && OS_VER="UnknownOS"
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

# =========================================================
#  HELPER: GApps install
# =========================================================
install_gapp_logic() {
    local app_list="$1" target_root="$2"
    local installed_count=0
    local total_count=$(echo "$app_list" | wc -w)
    log_info "Installing $total_count GApps to $(basename "$target_root")..."
    for app in $app_list; do
        local src
        src=$(find "$GITHUB_WORKSPACE/gapps_src" -name "${app}.apk" -print -quit)
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
    log_success "GApps done: $installed_count/$total_count installed"
}

# =========================================================
#  2. SETUP
# =========================================================
log_step "🛠️  Setting up Environment..."
mkdir -p "$IMAGES_DIR" "$SUPER_DIR" "$TEMP_DIR" "$BIN_DIR"
export PATH="$BIN_DIR:$PATH"

log_info "Installing system dependencies..."
sudo apt-get update -qq
sudo apt-get install -y -qq \
    python3 python3-pip erofs-utils erofsfuse jq aria2 \
    zip unzip liblz4-tool p7zip-full aapt git openjdk-17-jre-headless > /dev/null 2>&1
pip3 install gdown --break-system-packages -q
log_success "System dependencies installed"

# =========================================================
#  3. DOWNLOAD & SETUP TOOLS
# =========================================================
log_step "📥 Downloading Required Resources..."

# ── Apktool ──────────────────────────────────────────────
if [ ! -f "$BIN_DIR/apktool.jar" ]; then
    log_info "Fetching Apktool v2.12.1..."
    wget -q -O "$BIN_DIR/apktool.jar" \
        "https://github.com/iBotPeaches/Apktool/releases/download/v2.12.1/apktool_2.12.1.jar"
    if [ -f "$BIN_DIR/apktool.jar" ]; then
        printf '#!/bin/bash\njava -Xmx8G -jar "%s/apktool.jar" "$@"\n' "$BIN_DIR" > "$BIN_DIR/apktool"
        chmod +x "$BIN_DIR/apktool"
        log_success "Apktool v2.12.1 installed"
    else
        log_error "Apktool download failed, falling back to apt..."
        sudo apt-get install -y apktool
    fi
else
    log_info "Apktool already installed"
fi

# ── payload-dumper-go ─────────────────────────────────────
if [ ! -f "$BIN_DIR/payload-dumper-go" ]; then
    log_info "Downloading payload-dumper-go..."
    wget -q -O pd.tar.gz \
        "https://github.com/ssut/payload-dumper-go/releases/download/1.2.2/payload-dumper-go_1.2.2_linux_amd64.tar.gz"
    tar -xzf pd.tar.gz
    find . -name "payload-dumper-go" -not -path "*/bin/*" -exec mv {} "$BIN_DIR/" \;
    chmod +x "$BIN_DIR/payload-dumper-go"
    rm -f pd.tar.gz
    log_success "payload-dumper-go installed"
else
    log_info "payload-dumper-go already installed"
fi

# ── baksmali + smali (from your Google Drive — no fallback needed) ──
BAKSMALI_GDRIVE="1RS_lmqeVoMO4-mnCQ-BOV5A9qoa_8VHu"
SMALI_GDRIVE="1KTMCWGOcLs-yeuLwHSoc53J0kpXTZht_"

_fetch_jar_gdrive() {
    local name="$1" gdrive_id="$2"
    local dest="$BIN_DIR/$name"
    local sz; sz=$(stat -c%s "$dest" 2>/dev/null || echo 0)
    if [ "$sz" -gt 500000 ]; then
        log_success "✓ $name already cached (${sz}B)"; return 0
    fi
    rm -f "$dest"
    log_info "Downloading $name from Google Drive..."
    gdown "$gdrive_id" -O "$dest" --fuzzy -q
    sz=$(stat -c%s "$dest" 2>/dev/null || echo 0)
    if [ "$sz" -gt 500000 ]; then
        log_success "✓ $name ready (${sz}B)"; return 0
    else
        log_error "✗ $name download failed (${sz}B)"; return 1
    fi
}

_fetch_jar_gdrive "baksmali.jar" "$BAKSMALI_GDRIVE"
_fetch_jar_gdrive "smali.jar"    "$SMALI_GDRIVE"

# ── Write nexmod_apk.py (THE APK ENGINE — fixes -124 permanently) ──
log_info "Writing nexmod_apk.py (APK alignment + DEX patch engine)..."
cat > "$BIN_DIR/nexmod_apk.py" <<'PYEOF'
#!/usr/bin/env python3
"""
nexmod_apk.py — NexDroid APK Engine v2.0
Fixes Android -124 (resources.arsc alignment) permanently.

COMMANDS:
  patch   <apk> <profile>  DEX-patch + fix alignment
  fix     <apk>             Fix alignment only (no DEX change)
  verify  <apk>             Audit STORE+align compliance
  inspect <apk>             Print entry map
  profiles                  List patch profiles
"""
import sys, os, re, io, struct, zlib, shutil, zipfile
import subprocess, tempfile, traceback
from pathlib import Path
from typing import Callable, Dict, List, Optional, Tuple

def _p(tag, msg): print(f"[{tag}] {msg}", flush=True)
info = lambda m: _p("INFO",    m)
ok   = lambda m: _p("SUCCESS", m)
warn = lambda m: _p("WARNING", m)
err  = lambda m: _p("ERROR",   m)

_BIN     = Path(os.environ.get("BIN_DIR", Path(__file__).parent))
BAKSMALI = _BIN / "baksmali.jar"
SMALI    = _BIN / "smali.jar"
API      = "35"

# ══════════════════════════════════════════════════════════════════
#  ZIP ALIGNER — the core fix for -124
#  Rebuilds ZIP from scratch controlling every byte offset.
#  resources.arsc and classes*.dex → STORE + 4-byte aligned.
# ══════════════════════════════════════════════════════════════════
class ZipAligner:
    _LFH  = b'PK\x03\x04'
    _CFH  = b'PK\x01\x02'
    _EOCD = b'PK\x05\x06'
    _FMT_LFH  = '<4sHHHHHIIIHH'
    _FMT_CFH  = '<4sHHHHHHIIIHHHHHII'
    _FMT_EOCD = '<4sHHHHIIH'
    _FORCE_STORE    = frozenset({'resources.arsc'})
    _FORCE_STORE_RE = re.compile(r'^classes\d*\.dex$')

    @classmethod
    def _must_store(cls, name):
        return name in cls._FORCE_STORE or bool(cls._FORCE_STORE_RE.match(name))

    @staticmethod
    def _dos_dt(dt):
        try:
            y,mo,d,h,mi,s = (int(x) for x in dt)
            return (h*2048+mi*32+s//2, (y-1980)*512+mo*32+d)
        except Exception:
            return (0,0)

    @classmethod
    def rebuild(cls, entries, dst, alignment=4):
        """
        Write fully aligned ZIP.
        entries = list of (ZipInfo, uncompressed_bytes)
        Alignment padding injected into Local File Header extra field so that
        data starts at offset % alignment == 0.
        """
        stats = {'aligned':[], 'kept':[], 'recompressed':[]}
        buf = io.BytesIO()
        cd  = []

        for zi, raw in entries:
            fname_b  = zi.filename.encode('utf-8')
            do_store = cls._must_store(zi.filename)

            if do_store:
                compress, out_data = zipfile.ZIP_STORED, raw
            elif zi.compress_type == zipfile.ZIP_DEFLATED:
                compress = zipfile.ZIP_DEFLATED
                c = zlib.compressobj(zlib.Z_DEFAULT_COMPRESSION, zlib.DEFLATED, -15)
                out_data = c.compress(raw) + c.flush()
                stats['recompressed'].append(zi.filename)
            else:
                compress, out_data = zipfile.ZIP_STORED, raw

            crc   = zlib.crc32(raw) & 0xFFFFFFFF
            extra = b''
            if compress == zipfile.ZIP_STORED:
                base  = buf.tell() + 30 + len(fname_b)
                rem   = base % alignment
                if rem:
                    extra = b'\x00' * (alignment - rem)
                    stats['aligned'].append(zi.filename)
                else:
                    stats['kept'].append(zi.filename)

            entry_off = buf.tell()
            dt, dd    = cls._dos_dt(zi.date_time)
            flags     = zi.flag_bits & ~0x08

            buf.write(struct.pack(cls._FMT_LFH,
                cls._LFH, 20, flags, compress, dt, dd,
                crc, len(out_data), len(raw), len(fname_b), len(extra)))
            buf.write(fname_b); buf.write(extra)

            if compress == zipfile.ZIP_STORED and raw:
                actual = buf.tell()
                assert actual % alignment == 0, \
                    f"ALIGNMENT BUG: {zi.filename!r} @ {actual} (% {alignment} = {actual%alignment})"

            buf.write(out_data)

            cd.append((struct.pack(cls._FMT_CFH,
                cls._CFH, (3<<8)|20, 20, flags, compress, dt, dd,
                crc, len(out_data), len(raw),
                len(fname_b), 0, 0, 0, 0, zi.external_attr, entry_off),
                fname_b))

        cd_start = buf.tell()
        for cfh_b, fn_b in cd:
            buf.write(cfh_b); buf.write(fn_b)
        cd_size = buf.tell() - cd_start
        buf.write(struct.pack(cls._FMT_EOCD,
            cls._EOCD, 0, 0, len(cd), len(cd), cd_size, cd_start, 0))

        dst.write_bytes(buf.getvalue())
        return stats

    @classmethod
    def fix_inplace(cls, apk, alignment=4):
        with zipfile.ZipFile(apk, 'r') as z:
            entries = [(zi, z.read(zi.filename)) for zi in z.infolist()]
        tmp = apk.with_suffix('.ztmp')
        stats = cls.rebuild(entries, tmp, alignment)
        tmp.rename(apk)
        return stats

    @classmethod
    def verify(cls, apk, alignment=4):
        raw    = apk.read_bytes()
        issues = []
        with zipfile.ZipFile(apk, 'r') as z:
            for zi in z.infolist():
                if not cls._must_store(zi.filename): continue
                if zi.compress_type != zipfile.ZIP_STORED:
                    issues.append(f"  ✗ {zi.filename}: DEFLATE (must be STORE)"); continue
                off  = zi.header_offset
                fl,el = struct.unpack_from('<HH', raw, off+26)
                data  = off + 30 + fl + el
                if data % alignment != 0:
                    issues.append(f"  ✗ {zi.filename}: data@{data} (% {alignment} = {data%alignment}  NOT aligned)")
                else:
                    ok(f"  ✓ {zi.filename}: STORE @ {data} (aligned)")
        for issue in issues: err(issue)
        if not issues: ok(f"  APK is Android R+ compliant (all STORE entries {alignment}B-aligned)")
        return not issues

# ══════════════════════════════════════════════════════════════════
#  SMALI PATCH HELPERS
# ══════════════════════════════════════════════════════════════════
def _safe(fn, *a):
    try: r = fn(*a); return r if r is not None else 0
    except Exception as e: warn(f"    {fn.__name__} skipped: {e}"); return 0

def force_return(d, key, val):
    stub = f"const/4 v0, 0x{val}"
    total = 0
    for f in d.rglob("*.smali"):
        lines = f.read_text(errors="replace").splitlines()
        i, chg = 0, False
        while i < len(lines):
            s = lines[i].lstrip()
            if s.startswith(".method") and key in s and ")V" not in s:
                j = i+1
                while j < len(lines) and not lines[j].lstrip().startswith(".end method"): j+=1
                if j >= len(lines): i+=1; continue
                body = lines[i:j+1]
                if len(body)>=4 and body[2].strip()==stub and body[3].strip().startswith("return"):
                    i=j+1; continue
                lines[i:j+1] = [lines[i],"    .registers 8",f"    {stub}","    return v0",".end method"]
                chg=True; total+=1; i+=5
            else: i+=1
        if chg: f.write_text("\n".join(lines)+"\n")
    (ok if total else warn)(f"    force_return({key!r}→{val}): {total}"); return total

def force_return_void(d, key):
    total = 0
    for f in d.rglob("*.smali"):
        lines = f.read_text(errors="replace").splitlines()
        i, chg = 0, False
        while i < len(lines):
            s = lines[i].lstrip()
            if s.startswith(".method") and key in s and ")V" in s:
                j = i+1
                while j < len(lines) and not lines[j].lstrip().startswith(".end method"): j+=1
                if j >= len(lines): i+=1; continue
                lines[i:j+1] = [lines[i],"    .registers 1","    return-void",".end method"]
                chg=True; total+=1; i+=4
            else: i+=1
        if chg: f.write_text("\n".join(lines)+"\n")
    (ok if total else warn)(f"    force_return_void({key!r}): {total}"); return total

def replace_move_result(d, invoke, replacement):
    total = 0
    for f in d.rglob("*.smali"):
        lines = f.read_text(errors="replace").splitlines()
        i, chg = 0, False
        while i < len(lines):
            if invoke in lines[i]:
                for j in range(i+1, min(i+6, len(lines))):
                    if lines[j].strip().startswith("move-result"):
                        ind = re.match(r"\s*", lines[j]).group(0)
                        nl  = f"{ind}{replacement}"
                        if lines[j] != nl: lines[j]=nl; chg=True; total+=1
                        break
            i+=1
        if chg: f.write_text("\n".join(lines)+"\n")
    (ok if total else warn)(f"    replace_move_result({invoke[-40:]!r}): {total}"); return total

def insert_before(d, pattern, new_line):
    total = 0
    for f in d.rglob("*.smali"):
        lines = f.read_text(errors="replace").splitlines()
        i, chg = 0, False
        while i < len(lines):
            if pattern in lines[i]:
                ind = re.match(r"\s*", lines[i]).group(0)
                cand = f"{ind}{new_line}"
                if i==0 or lines[i-1].strip() != new_line.strip():
                    lines.insert(i, cand); chg=True; total+=1; i+=2
                else: i+=1
            else: i+=1
        if chg: f.write_text("\n".join(lines)+"\n")
    (ok if total else warn)(f"    insert_before({pattern[-50:]!r}): {total}"); return total

def strip_if_eqz_after(d, pattern):
    total = 0
    for f in d.rglob("*.smali"):
        lines = f.read_text(errors="replace").splitlines()
        chg=False; i=0
        while i < len(lines):
            if pattern in lines[i]:
                j=i+1
                while j < min(i+12, len(lines)):
                    if re.match(r'\s*if-eqz\s', lines[j]):
                        del lines[j]; chg=True; total+=1; break
                    j+=1
            i+=1
        if chg: f.write_text("\n".join(lines)+"\n")
    (ok if total else warn)(f"    strip_if_eqz_after({pattern[-50:]!r}): {total}"); return total

def sed_all(d, find_re, replace):
    pat=re.compile(find_re); total=0
    for f in d.rglob("*.smali"):
        text=f.read_text(errors="replace"); new_text,n=pat.subn(replace,text)
        if n: f.write_text(new_text); total+=n
    (ok if total else warn)(f"    sed_all: {total}"); return total

# ══════════════════════════════════════════════════════════════════
#  PATCH PROFILES
# ══════════════════════════════════════════════════════════════════
def _p_framework_sig(d):
    n=0
    n+=_safe(insert_before,d,"ApkSignatureVerifier;->unsafeGetCertsWithoutVerification","const/4 v1, 0x1")
    n+=_safe(insert_before,d,"iput p1, p0, Landroid/content/pm/PackageParser$PackageParserException;->error:I","const/4 p1, 0x0")
    n+=_safe(force_return,d,"checkCapability","1")
    n+=_safe(force_return,d,"checkCapabilityRecover","1")
    n+=_safe(force_return,d,"hasAncestorOrSelf","1")
    n+=_safe(replace_move_result,d,"invoke-static {v8, v4}, Ljava/security/MessageDigest;->isEqual([B[B)Z","const/4 v0, 0x1")
    n+=_safe(replace_move_result,d,"invoke-static {v9, v3}, Ljava/security/MessageDigest;->isEqual([B[B)Z","const/4 v0, 0x1")
    n+=_safe(force_return,d,"getMinimumSignatureSchemeVersionForTargetSdk","0")
    n+=_safe(insert_before,d,"ApkSignatureVerifier;->verifyV1Signature","const p3, 0x0")
    n+=_safe(replace_move_result,d,"invoke-static {v5, v6}, Ljava/security/MessageDigest;->isEqual([B[B)Z","const/4 v7, 0x1")
    n+=_safe(force_return,d,"verifyMessageDigest","1")
    n+=_safe(strip_if_eqz_after,d,"Landroid/util/jar/StrictJarFile;->findEntry(Ljava/lang/String;)Ljava/util/zip/ZipEntry;")
    n+=_safe(insert_before,d,"manifest> specifies bad sharedUserId name","const/4 v4, 0x0")
    info(f"    Patches this DEX: {n}"); return n>0

def _p_intl_build(d):
    n=0
    n+=_safe(sed_all,d,r'(\s*)sget-boolean (v\d+), Lmiui/os/Build;->IS_INTERNATIONAL_BUILD:Z',r'\1const/4 \2, 0x1')
    n+=_safe(replace_move_result,d,"Lmiui/os/Build;->getRegion()Ljava/lang/String;","const/4 v0, 0x1")
    return n>0

def _p_settings_ai(d):
    AI_KEYS=("isAi","AiSupport","aiSupport","SupportAi","supportAi","isAiFeatureSupported","isAiSupportedDevice")
    total=0
    for f in d.rglob("*.smali"):
        if "InternalDeviceUtils" not in f.name and "AiUtils" not in f.name: continue
        lines=f.read_text(errors="replace").splitlines()
        i,chg=0,False
        while i<len(lines):
            s=lines[i].lstrip()
            is_t=(s.startswith(".method") and ")V" not in s and any(k in s for k in AI_KEYS))
            if is_t:
                j=i+1
                while j<len(lines) and not lines[j].lstrip().startswith(".end method"): j+=1
                if j>=len(lines): i+=1; continue
                name=s.split()[-1] if s.split() else "?"
                lines[i:j+1]=[lines[i],"    .registers 2","    const/4 v0, 0x1","    return v0",".end method"]
                chg=True; total+=1; ok(f"    Patched: {name}"); i+=5
            else: i+=1
        if chg: f.write_text("\n".join(lines)+"\n")
    if not total: warn("    InternalDeviceUtils/AiUtils not found in this DEX")
    return total>0

def _p_voice_recorder(d):
    n=0
    for key in ("isAiSupported","isPremium","isAiEnabled","isVipUser","hasAiFeature","isMiAiSupported"):
        n+=_safe(force_return,d,key,"1")
    n+=_safe(sed_all,d,r'(\s*)sget-boolean (v\d+), Lmiui/os/Build;->IS_INTERNATIONAL_BUILD:Z',r'\1const/4 \2, 0x1')
    return n>0

PROFILES = {
    "framework-sig":     (["ApkSignatureVerifier","SigningDetails","StrictJarVerifier",
                           "StrictJarFile","PackageParser","ApkSigningBlock","ParsingPackageUtils"],
                          _p_framework_sig),
    "settings-ai":       (["InternalDeviceUtils"], _p_settings_ai),
    "systemui-volte":    (["IS_INTERNATIONAL_BUILD","miui/os/Build"], _p_intl_build),
    "provision-gms":     (["IS_INTERNATIONAL_BUILD"], _p_intl_build),
    "miui-service":      (["IS_INTERNATIONAL_BUILD","miui/os/Build"], _p_intl_build),
    "voice-recorder-ai": (["IS_INTERNATIONAL_BUILD","isAiSupported","isPremium"], _p_voice_recorder),
}

# ══════════════════════════════════════════════════════════════════
#  DEX PATCHER
# ══════════════════════════════════════════════════════════════════
_DEX_RE = re.compile(r'^classes\d*\.dex$')

def _list_dexes(apk):
    with zipfile.ZipFile(apk) as z:
        dexes=[n for n in z.namelist() if _DEX_RE.match(n)]
    return sorted(dexes, key=lambda x:(0 if x=="classes.dex" else int(re.search(r'\d+',x).group())))

def _dex_has(apk, name, *needles):
    with zipfile.ZipFile(apk) as z: raw=z.read(name)
    return any(n.encode() in raw for n in needles)

def _patch_one_dex(apk, dex_name, patch_fn):
    """Decompile → patch → recompile. Returns new bytes or None on failure."""
    work=Path(tempfile.mkdtemp(prefix="nxm_"))
    try:
        dex=work/dex_name
        with zipfile.ZipFile(apk) as z: dex.write_bytes(z.read(dex_name))
        info(f"    {dex_name}: {dex.stat().st_size//1024}K")
        smali=work/"smali"; smali.mkdir()
        r=subprocess.run(["java","-jar",str(BAKSMALI),"d","-a",API,str(dex),"-o",str(smali)],
                         capture_output=True, text=True, timeout=600)
        if r.returncode!=0: err(f"    baksmali: {r.stderr[:300]}"); return None
        info(f"    baksmali: {sum(1 for _ in smali.rglob('*.smali'))} files")
        try: changed=patch_fn(smali)
        except Exception as e: err(f"    patch_fn: {e}"); traceback.print_exc(); return None
        if not changed: warn(f"    {dex_name}: no patches"); return None
        out=work/f"out_{dex_name}"
        r=subprocess.run(["java","-jar",str(SMALI),"a","-a",API,str(smali),"-o",str(out)],
                         capture_output=True, text=True, timeout=600)
        if r.returncode!=0: err(f"    smali: {r.stderr[:300]}"); return None
        info(f"    smali: {out.stat().st_size//1024}K")
        return out.read_bytes()
    except Exception as e: err(f"    crash: {e}"); traceback.print_exc(); return None
    finally: shutil.rmtree(work, ignore_errors=True)

# ══════════════════════════════════════════════════════════════════
#  APK PATCHER — orchestrates DEX patch + ZipAligner rebuild
# ══════════════════════════════════════════════════════════════════
class APKPatcher:
    @staticmethod
    def _bak(apk):
        b=Path(str(apk)+".bak")
        if not b.exists(): shutil.copy2(apk,b); ok(f"  Backup: {b.name}")
        return b
    @staticmethod
    def _restore(apk):
        b=Path(str(apk)+".bak")
        if b.exists(): shutil.copy2(b,apk); warn(f"  Restored from backup")

    @classmethod
    def fix(cls, apk):
        apk=apk.resolve()
        if not apk.exists(): err(f"Not found: {apk}"); return False
        info(f"Fixing alignment: {apk.name}  ({apk.stat().st_size//1024}K)")
        cls._bak(apk)
        try:
            stats=ZipAligner.fix_inplace(apk)
            ok(f"  Aligned:{len(stats['aligned'])} | OK:{len(stats['kept'])} | Recompressed:{len(stats['recompressed'])}")
            if ZipAligner.verify(apk): ok(f"  ✅ {apk.name} Android R+ compliant"); return True
            else: err("  Verify failed → restore"); cls._restore(apk); return False
        except Exception as e:
            err(f"  fix() crash: {e}"); traceback.print_exc(); cls._restore(apk); return False

    @classmethod
    def patch(cls, apk, profile_name):
        if profile_name not in PROFILES: err(f"Unknown profile: {profile_name!r}"); return False
        apk=apk.resolve()
        if not apk.exists(): err(f"Not found: {apk}"); return False
        needles, patch_fn = PROFILES[profile_name]
        info(f"Archive : {apk.name}  ({apk.stat().st_size//1024}K)")
        info(f"Profile : {profile_name}")
        bak=cls._bak(apk)

        # Step 1: collect patched DEX bytes (archive untouched until rebuild)
        patched={}
        for dex in _list_dexes(apk):
            if _dex_has(apk, dex, *needles):
                info(f"  → {dex} has target classes")
                nb=_patch_one_dex(apk, dex, patch_fn)
                if nb: patched[dex]=nb; ok(f"  ✓ {dex} patched ({len(nb)//1024}K)")
            else: info(f"  · {dex}: skip")

        if not patched: err(f"Profile {profile_name!r}: nothing patched → restore"); cls._restore(apk); return False

        # Step 2: ZipAligner.rebuild() — new ZIP with patched DEX + alignment
        info(f"  Rebuilding ZIP ({len(patched)} DEX replaced)...")
        tmp=apk.with_suffix('.nx_rebuild_tmp')
        try:
            with zipfile.ZipFile(apk,'r') as z:
                entries=[(zi, patched[zi.filename] if zi.filename in patched else z.read(zi.filename))
                         for zi in z.infolist()]
            stats=ZipAligner.rebuild(entries, tmp)
            tmp.rename(apk)
            ok(f"  ZIP rebuilt: {apk.stat().st_size//1024}K  "
               f"(aligned {len(stats['aligned'])}, kept {len(stats['kept'])})")
        except Exception as e:
            err(f"  Rebuild failed: {e}"); traceback.print_exc()
            if tmp.exists(): tmp.unlink()
            cls._restore(apk); return False

        # Step 3: Verify
        if ZipAligner.verify(apk): ok(f"  ✅ {apk.name}: patched + Android R+ compliant"); return True
        else: err("  Verify FAILED → restore"); cls._restore(apk); return False

    @classmethod
    def verify(cls, apk):
        apk=apk.resolve()
        if not apk.exists(): err(f"Not found: {apk}"); return False
        info(f"Verifying: {apk.name}")
        return ZipAligner.verify(apk)

    @classmethod
    def inspect(cls, apk):
        apk=apk.resolve()
        if not apk.exists(): err(f"Not found: {apk}"); return
        raw=apk.read_bytes()
        print(f"\n{'═'*65}\n  {apk.name}  ({apk.stat().st_size/1024/1024:.2f} MB)\n{'─'*65}")
        print(f"  {'Entry':<40} {'Comp':>8}  {'Aligned':>8}  {'Offset':>10}")
        print(f"{'─'*65}")
        with zipfile.ZipFile(apk,'r') as z:
            for zi in sorted(z.infolist(), key=lambda x:x.header_offset):
                off=zi.header_offset; fl,el=struct.unpack_from('<HH',raw,off+26)
                data=off+30+fl+el
                comp="STORE" if zi.compress_type==0 else "DEFLATE"
                must=ZipAligner._must_store(zi.filename)
                astr="✓" if (not must or data%4==0) else "✗ BAD"
                flag=" ◄" if must else ""
                print(f"  {zi.filename:<40} {comp:>8}  {astr:>8}  {data:>10}{flag}")
        print(f"{'═'*65}\n")

def main():
    if len(sys.argv)<2: print(__doc__); sys.exit(1)
    cmd=sys.argv[1].lower()
    if cmd=="profiles":
        for n,(needles,_) in PROFILES.items(): print(f"  {n:<22} triggers: {', '.join(needles[:2])}")
        sys.exit(0)
    if cmd in ("fix","verify","inspect") and len(sys.argv)>=3:
        apk=Path(sys.argv[2])
        r={"fix":lambda:APKPatcher.fix(apk),"verify":lambda:APKPatcher.verify(apk),
           "inspect":lambda:(APKPatcher.inspect(apk),True)[1]}[cmd]()
        sys.exit(0 if r else 1)
    if cmd=="patch" and len(sys.argv)>=4:
        sys.exit(0 if APKPatcher.patch(Path(sys.argv[2]),sys.argv[3]) else 1)
    print(__doc__); sys.exit(1)

if __name__=="__main__": main()
PYEOF
chmod +x "$BIN_DIR/nexmod_apk.py"
log_success "✓ nexmod_apk.py written to $BIN_DIR"

# ── Verify baksmali+smali are ready (needed by nexmod_apk.py) ────
APK_ENGINE_OK=0
log_info "Verifying APK engine tools..."
_bs_sz=$(stat -c%s "$BIN_DIR/baksmali.jar" 2>/dev/null || echo 0)
_sm_sz=$(stat -c%s "$BIN_DIR/smali.jar"    2>/dev/null || echo 0)
if [ "$_bs_sz" -gt 500000 ] && [ "$_sm_sz" -gt 500000 ]; then
    log_success "✓ baksmali.jar (${_bs_sz}B) and smali.jar (${_sm_sz}B) ready"
    APK_ENGINE_OK=1
else
    log_error "baksmali/smali not ready (bs:${_bs_sz}B sm:${_sm_sz}B) — DEX patches skipped"
fi

# ── Wrapper: DEX patch + alignment fix ───────────────────────────
_run_apk_patch() {
    # Usage: _run_apk_patch <LABEL> <profile> <apk_or_jar_path>
    local label="$1" profile="$2" archive="$3"
    if [ "${APK_ENGINE_OK:-0}" -ne 1 ]; then
        log_warning "APK engine not ready — skipping $label"; return 0
    fi
    if [ -z "$archive" ] || [ ! -f "$archive" ]; then
        log_warning "$label: file not found (${archive:-<empty>})"; return 0
    fi
    log_info "$label → $(basename "$archive")"
    python3 "$BIN_DIR/nexmod_apk.py" patch "$archive" "$profile" 2>&1 | \
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

# ── Wrapper: alignment-fix only (use after every apktool b call) ──
_run_apk_fix() {
    # Usage: _run_apk_fix <LABEL> <apk_or_jar_path>
    local label="$1" archive="$2"
    [ -z "$archive" ] || [ ! -f "$archive" ] && return 0
    log_info "Fixing APK alignment: $label"
    python3 "$BIN_DIR/nexmod_apk.py" fix "$archive" 2>&1 | \
    while IFS= read -r line; do
        case "$line" in
            "[SUCCESS]"*) log_success "${line#[SUCCESS] }" ;;
            "[WARNING]"*) log_warning "${line#[WARNING] }" ;;
            "[ERROR]"*)   log_error   "${line#[ERROR] }"   ;;
            "[INFO]"*)    log_info    "${line#[INFO] }"    ;;
        esac
    done
}

# ── vbmeta patcher ────────────────────────────────────────────────
cat > "$BIN_DIR/vbmeta_patcher.py" <<'PYEOF'
#!/usr/bin/env python3
import sys, struct, os

AVB_MAGIC       = b'AVB0'
FLAGS_OFFSET    = 123
DISABLE_FLAGS   = 0x03   # verification_disabled | hashtree_disabled

def main():
    if len(sys.argv)!=2: print("[ERROR] Usage: vbmeta_patcher.py <img>"); sys.exit(1)
    fp=sys.argv[1]
    if not os.path.exists(fp): print(f"[ERROR] Not found: {fp}"); sys.exit(1)
    with open(fp,'rb') as f: data=bytearray(f.read())
    if data[:4]!=AVB_MAGIC: print(f"[ERROR] Invalid AVB magic"); sys.exit(1)
    print(f"[SUCCESS] Valid AVB magic")
    orig=data[FLAGS_OFFSET]
    print(f"[INFO] Current flags: 0x{orig:02X}")
    if orig==DISABLE_FLAGS: print("[INFO] Already disabled"); sys.exit(0)
    data[FLAGS_OFFSET]=DISABLE_FLAGS
    with open(fp,'wb') as f: f.write(data)
    patched=open(fp,'rb').read()[FLAGS_OFFSET]
    if patched==DISABLE_FLAGS: print("[SUCCESS] vbmeta patched 0x03"); sys.exit(0)
    else: print("[ERROR] Verify failed"); sys.exit(1)

if __name__=="__main__": main()
PYEOF
chmod +x "$BIN_DIR/vbmeta_patcher.py"
log_success "✓ vbmeta_patcher.py ready"

# ── GApps ─────────────────────────────────────────────────────────
if [ ! -d "gapps_src" ]; then
    log_info "Downloading GApps..."
    gdown "$GAPPS_LINK" -O gapps.zip --fuzzy -q
    unzip -qq gapps.zip -d gapps_src && rm gapps.zip
    log_success "GApps extracted"
else
    log_info "GApps already present"
fi

# ── NexPackage ────────────────────────────────────────────────────
if [ ! -d "nex_pkg" ]; then
    log_info "Downloading NexPackage..."
    gdown "$NEX_PACKAGE_LINK" -O nex.zip --fuzzy -q
    unzip -qq nex.zip -d nex_pkg && rm nex.zip
    log_success "NexPackage extracted"
else
    log_info "NexPackage already present"
fi

# ── Launcher ──────────────────────────────────────────────────────
if [ ! -f "$TEMP_DIR/MiuiHome_Latest.apk" ]; then
    log_info "Downloading HyperOS Launcher..."
    LAUNCHER_URL=$(curl -s "https://api.github.com/repos/$LAUNCHER_REPO/releases/latest" \
        | jq -r '.assets[] | select(.name | endswith(".zip")) | .browser_download_url' | head -n1)
    if [ -n "$LAUNCHER_URL" ] && [ "$LAUNCHER_URL" != "null" ]; then
        wget -q -O l.zip "$LAUNCHER_URL"
        unzip -qq l.zip -d l_ext
        FOUND=$(find l_ext -name "MiuiHome.apk" -type f | head -n1)
        [ -n "$FOUND" ] && mv "$FOUND" "$TEMP_DIR/MiuiHome_Latest.apk" && log_success "Launcher downloaded"
        rm -rf l_ext l.zip
    else
        log_warning "Launcher download failed"
    fi
else
    log_info "Launcher already present"
fi

log_success "All resources ready"

# =========================================================
#  4. DOWNLOAD & EXTRACT ROM
# =========================================================
log_step "📦 Downloading ROM..."
cd "$TEMP_DIR"
START_TIME=$(date +%s)
aria2c -x 16 -s 16 --file-allocation=none -o "rom.zip" "$ROM_URL" 2>&1 | grep -E "download completed|ERROR"
END_TIME=$(date +%s)
log_info "Download completed in $((END_TIME-START_TIME))s"
[ ! -f "rom.zip" ] && { log_error "ROM download failed!"; exit 1; }

log_step "📂 Extracting payload..."
unzip -qq -o "rom.zip" payload.bin && rm "rom.zip"
log_success "Payload extracted"

log_step "🔍 Dumping firmware images..."
START_TIME=$(date +%s)
payload-dumper-go -o "$IMAGES_DIR" payload.bin > /dev/null 2>&1
log_success "Firmware extracted in $(($(date +%s)-START_TIME))s"
rm payload.bin

# =========================================================
#  4.5. VBMETA
# =========================================================
log_step "🔓 Patching vbmeta..."
for img in "$IMAGES_DIR/vbmeta.img" "$IMAGES_DIR/vbmeta_system.img"; do
    [ ! -f "$img" ] && continue
    log_info "Patching $(basename "$img")..."
    python3 "$BIN_DIR/vbmeta_patcher.py" "$img" 2>&1 | while IFS= read -r line; do
        case "$line" in
            "[SUCCESS]"*) log_success "${line#[SUCCESS] }" ;;
            "[ERROR]"*)   log_error   "${line#[ERROR] }"   ;;
            "[INFO]"*)    log_info    "${line#[INFO] }"    ;;
        esac
    done
done
log_success "✅ AVB verification disabled"

# =========================================================
#  5. PARTITION LOOP
# =========================================================
log_step "🔄 Processing Partitions..."
LOGICALS="system system_ext product mi_ext vendor odm"

for part in $LOGICALS; do
    [ ! -f "$IMAGES_DIR/${part}.img" ] && continue

    log_step "━━━ Partition: ${part^^} ━━━"
    DUMP_DIR="$GITHUB_WORKSPACE/${part}_dump"
    MNT_DIR="$GITHUB_WORKSPACE/mnt"
    mkdir -p "$DUMP_DIR" "$MNT_DIR"
    cd "$GITHUB_WORKSPACE"

    # Mount
    log_info "Mounting ${part}.img..."
    sudo erofsfuse "$IMAGES_DIR/${part}.img" "$MNT_DIR"
    if [ -z "$(sudo ls -A "$MNT_DIR")" ]; then
        log_error "Mount failed for ${part}!"; sudo fusermount -uz "$MNT_DIR"; continue
    fi
    log_success "Mounted"

    # Copy + unmount
    START_TIME=$(date +%s)
    sudo cp -a "$MNT_DIR/." "$DUMP_DIR/"
    sudo chown -R "$(whoami)" "$DUMP_DIR"
    log_success "Copied in $(($(date +%s)-START_TIME))s"
    sudo fusermount -uz "$MNT_DIR"
    rm "$IMAGES_DIR/${part}.img"

    # ─────────────────────────────────────────────────────
    #  A. DEBLOAT
    # ─────────────────────────────────────────────────────
    log_info "🗑️  Debloating..."
    echo "$BLOAT_LIST" | tr ' ' '\n' | grep -v "^\s*$" > "$TEMP_DIR/bloat_list.txt"
    touch "$TEMP_DIR/removed_bloat.log"
    find "$DUMP_DIR" -type f -name "*.apk" | while read apk_file; do
        pkg=$(aapt dump badging "$apk_file" 2>/dev/null | grep "package: name=" | cut -d"'" -f2)
        if [ -n "$pkg" ] && grep -Fxq "$pkg" "$TEMP_DIR/bloat_list.txt"; then
            rm -rf "$(dirname "$apk_file")"
            echo "$pkg" >> "$TEMP_DIR/removed_bloat.log"
            log_success "✓ Removed: $pkg"
        fi
    done
    log_success "Debloat done: $(wc -l < "$TEMP_DIR/removed_bloat.log") removed"

    # ─────────────────────────────────────────────────────
    #  B. GAPPS (product only)
    # ─────────────────────────────────────────────────────
    if [ "$part" == "product" ] && [ -d "$GITHUB_WORKSPACE/gapps_src" ]; then
        log_info "🔵 Injecting GApps..."
        mkdir -p "$DUMP_DIR/app" "$DUMP_DIR/priv-app"
        P_APP="SoundPickerGoogle MiuiBiometric LatinImeGoogle GoogleTTS GooglePartnerSetup GeminiShell"
        P_PRIV="Wizard Velvet Phonesky MIUIPackageInstaller GoogleRestore GooglePartnerSetup Assistant AndroidAutoStub"
        install_gapp_logic "$P_PRIV" "$DUMP_DIR/priv-app"
        install_gapp_logic "$P_APP"  "$DUMP_DIR/app"
    fi

    # ─────────────────────────────────────────────────────
    #  C. MIUI BOOSTER (system_ext only)
    #     Uses apktool d/b for smali method replacement.
    #     CRITICAL: _run_apk_fix called after apktool b.
    # ─────────────────────────────────────────────────────
    if [ "$part" == "system_ext" ]; then
        log_step "🚀 MiuiBooster Performance Patch"
        BOOST_JAR=$(find "$DUMP_DIR" -name "MiuiBooster.jar" -type f | head -n1)

        if [ -n "$BOOST_JAR" ]; then
            log_info "Found: $BOOST_JAR ($(du -h "$BOOST_JAR" | cut -f1))"
            cp "$BOOST_JAR" "${BOOST_JAR}.bak"
            rm -rf "$TEMP_DIR/boost_work" && mkdir -p "$TEMP_DIR/boost_work"
            cd "$TEMP_DIR/boost_work"

            if timeout 3m apktool d -r -f "$BOOST_JAR" -o "decompiled" >/dev/null 2>&1; then
                SMALI_FILE=$(find "decompiled" -path "*/com/miui/performance/DeviceLevelUtils.smali" | head -n1)
                if [ -f "$SMALI_FILE" ]; then
                    python3 - "$SMALI_FILE" <<'PYEOF'
import sys, re
path = sys.argv[1]
content = open(path).read()
new_method = '''.method public initDeviceLevel()V
    .registers 2
    const-string v0, "v:1,c:3,g:3"
    .line 130
    invoke-direct {p0, v0}, Lcom/miui/performance/DeviceLevelUtils;->parseDeviceLevelList(Ljava/lang/String;)V
    .line 140
    return-void
.end method'''
pat = r'\.method\s+public\s+initDeviceLevel\(\)V.*?\.end\s+method'
new_content = re.sub(pat, new_method, content, flags=re.DOTALL)
if new_content != content:
    open(path,'w').write(new_content)
    print("[SUCCESS] initDeviceLevel patched")
    sys.exit(0)
print("[ERROR] method not found"); sys.exit(1)
PYEOF
                    PATCH_RC=$?
                    if [ $PATCH_RC -eq 0 ]; then
                        if timeout 3m apktool b -c "decompiled" -o "MiuiBooster_patched.jar" >/dev/null 2>&1 \
                                && [ -f "MiuiBooster_patched.jar" ]; then
                            mv "MiuiBooster_patched.jar" "$BOOST_JAR"
                            log_success "✓ MiuiBooster.jar rebuilt"
                            # ★ FIX ALIGNMENT after apktool b ★
                            _run_apk_fix "MiuiBooster.jar" "$BOOST_JAR"
                            log_success "✅ Performance boost: v:1 c:3 g:3"
                        else
                            log_error "apktool b failed → restoring"
                            cp "${BOOST_JAR}.bak" "$BOOST_JAR"
                        fi
                    else
                        log_error "smali patch failed → restoring"
                        cp "${BOOST_JAR}.bak" "$BOOST_JAR"
                    fi
                else
                    log_warning "DeviceLevelUtils.smali not found in JAR"
                fi
            else
                log_warning "apktool decompile timeout — skipping MiuiBooster"
                cp "${BOOST_JAR}.bak" "$BOOST_JAR"
            fi
            cd "$GITHUB_WORKSPACE"
            rm -rf "$TEMP_DIR/boost_work"
        else
            log_warning "MiuiBooster.jar not found"
        fi
    fi

    # ─────────────────────────────────────────────────────
    #  D. DEX PATCHES via nexmod_apk.py
    #     Each call: baksmali → patch → smali → ZipAligner
    #     Output is guaranteed STORE + 4B-aligned → no -124
    # ─────────────────────────────────────────────────────

    if [ "$part" == "system" ]; then
        # D1. Framework signature bypass
        _run_apk_patch "SIGNATURE BYPASS" "framework-sig" \
            "$(find "$DUMP_DIR" -path "*/framework/framework.jar" -type f | head -n1)"
        cd "$GITHUB_WORKSPACE"

        # D2. Voice Recorder AI features
        _RECORDER=$(find "$DUMP_DIR" \
            -path "*/product/data-app/MIUISoundRecorderTargetSdk30/MIUISoundRecorderTargetSdk30.apk" \
            -type f | head -n1)
        [ -z "$_RECORDER" ] && _RECORDER=$(find "$DUMP_DIR" \
            \( -name "MIUISoundRecorder*.apk" -o -name "SoundRecorder.apk" \) -type f | head -n1)
        _run_apk_patch "VOICE RECORDER AI" "voice-recorder-ai" "$_RECORDER"
        cd "$GITHUB_WORKSPACE"
    fi

    if [ "$part" == "system_ext" ]; then
        # D3. Settings AI
        _run_apk_patch "SETTINGS AI" "settings-ai" \
            "$(find "$DUMP_DIR" -name "Settings.apk" -type f | head -n1)"
        cd "$GITHUB_WORKSPACE"

        # D4. Provision GMS
        _run_apk_patch "PROVISION GMS" "provision-gms" \
            "$(find "$DUMP_DIR" -name "Provision.apk" -type f | head -n1)"
        cd "$GITHUB_WORKSPACE"

        # D5. MIUI service CN→Global
        _run_apk_patch "MIUI SERVICE" "miui-service" \
            "$(find "$DUMP_DIR" -name "miui-services.jar" -type f | head -n1)"
        cd "$GITHUB_WORKSPACE"

        # D6. SystemUI VoLTE icons
        _run_apk_patch "SYSTEMUI VOLTE" "systemui-volte" \
            "$(find "$DUMP_DIR" \( -name "MiuiSystemUI.apk" -o -name "SystemUI.apk" \) -type f | head -n1)"
        cd "$GITHUB_WORKSPACE"
    fi

    # ─────────────────────────────────────────────────────
    #  E. MIUI-FRAMEWORK: Baidu → Gboard redirect
    #     Uses apktool b (resource + smali change).
    #     CRITICAL: _run_apk_fix called after apktool b.
    # ─────────────────────────────────────────────────────
    if [ "$part" == "system_ext" ]; then
        log_info "⌨️  Baidu IME → Gboard redirect..."
        MF_JAR=$(find "$DUMP_DIR" -name "miui-framework.jar" -type f | head -n1)
        if [ -n "$MF_JAR" ]; then
            cp "$MF_JAR" "${MF_JAR}.bak"
            cd "$TEMP_DIR"
            rm -rf mf_src
            if timeout 3m apktool d -r -f "$MF_JAR" -o "mf_src" >/dev/null 2>&1; then
                grep -rl "com.baidu.input_mi" "mf_src" | grep "InputMethodServiceInjector.smali" | \
                while read f; do
                    sed -i 's/com.baidu.input_mi/com.google.android.inputmethod.latin/g' "$f"
                    log_success "✓ IME redirect patched"
                done
                if apktool b -c "mf_src" -o "mf_out.jar" >/dev/null 2>&1 && [ -f "mf_out.jar" ]; then
                    mv "mf_out.jar" "$MF_JAR"
                    log_success "✓ miui-framework.jar rebuilt"
                    # ★ FIX ALIGNMENT after apktool b ★
                    _run_apk_fix "miui-framework.jar" "$MF_JAR"
                else
                    log_warning "miui-framework rebuild failed → restoring"
                    cp "${MF_JAR}.bak" "$MF_JAR"
                fi
            else
                log_warning "miui-framework decompile timeout"
            fi
            rm -rf mf_src
            cd "$GITHUB_WORKSPACE"
        else
            log_warning "miui-framework.jar not found"
        fi
    fi

    # ─────────────────────────────────────────────────────
    #  F. MIUI FREQUENT PHRASE: Colors + Gboard redirect
    #     Uses apktool b (res/values/colors.xml change).
    #     CRITICAL: _run_apk_fix called after apktool b.
    # ─────────────────────────────────────────────────────
    MFP_APK=$(find "$DUMP_DIR" -name "MIUIFrequentPhrase.apk" -type f -print -quit)
    if [ -n "$MFP_APK" ]; then
        log_info "🎨 Patching MIUIFrequentPhrase..."
        cp "$MFP_APK" "${MFP_APK}.bak"
        cd "$TEMP_DIR"; rm -rf mfp_src
        if timeout 3m apktool d -f "$MFP_APK" -o "mfp_src" >/dev/null 2>&1; then
            find "mfp_src" -name "InputMethodBottomManager.smali" \
                -exec sed -i 's/com.baidu.input_mi/com.google.android.inputmethod.latin/g' {} +
            log_success "✓ Gboard redirect"
            [ -f "mfp_src/res/values/colors.xml" ] && \
                sed -i 's|<color name="input_bottom_background_color">.*</color>|<color name="input_bottom_background_color">@android:color/system_neutral1_50</color>|g' \
                    "mfp_src/res/values/colors.xml" && log_success "✓ Light theme colors"
            [ -f "mfp_src/res/values-night/colors.xml" ] && \
                sed -i 's|<color name="input_bottom_background_color">.*</color>|<color name="input_bottom_background_color">@android:color/system_neutral1_900</color>|g' \
                    "mfp_src/res/values-night/colors.xml" && log_success "✓ Dark theme colors"
            if apktool b -c "mfp_src" -o "mfp_out.apk" >/dev/null 2>&1 && [ -f "mfp_out.apk" ]; then
                mv "mfp_out.apk" "$MFP_APK"
                log_success "✓ MIUIFrequentPhrase rebuilt"
                # ★ FIX ALIGNMENT after apktool b ★
                _run_apk_fix "MIUIFrequentPhrase.apk" "$MFP_APK"
            else
                log_warning "MIUIFrequentPhrase rebuild failed → restoring"
                cp "${MFP_APK}.bak" "$MFP_APK"
            fi
        else
            log_warning "MIUIFrequentPhrase decompile timeout"
        fi
        rm -rf mfp_src
        cd "$GITHUB_WORKSPACE"
    fi

    # ─────────────────────────────────────────────────────
    #  G. NEXPACKAGE (product only)
    # ─────────────────────────────────────────────────────
    if [ "$part" == "product" ] && [ -d "$GITHUB_WORKSPACE/nex_pkg" ]; then
        log_info "📦 Injecting NexPackage..."
        mkdir -p "$DUMP_DIR/etc/permissions" "$DUMP_DIR/etc/default-permissions" \
                 "$DUMP_DIR/overlay" "$DUMP_DIR/media" "$DUMP_DIR/media/theme/default"
        DEF_XML="default-permissions-google.xml"
        [ -f "$GITHUB_WORKSPACE/nex_pkg/$DEF_XML" ] && \
            cp "$GITHUB_WORKSPACE/nex_pkg/$DEF_XML" "$DUMP_DIR/etc/default-permissions/" && \
            log_success "✓ $DEF_XML"
        find "$GITHUB_WORKSPACE/nex_pkg" -maxdepth 1 -name "*.xml" ! -name "$DEF_XML" \
            -exec cp {} "$DUMP_DIR/etc/permissions/" \; && log_success "✓ Permission XMLs"
        find "$GITHUB_WORKSPACE/nex_pkg" -maxdepth 1 -name "*.apk" \
            -exec cp {} "$DUMP_DIR/overlay/" \; && log_success "✓ Overlay APKs"
        [ -f "$GITHUB_WORKSPACE/nex_pkg/bootanimation.zip" ] && \
            cp "$GITHUB_WORKSPACE/nex_pkg/bootanimation.zip" "$DUMP_DIR/media/" && \
            log_success "✓ bootanimation.zip"
        [ -f "$GITHUB_WORKSPACE/nex_pkg/lock_wallpaper" ] && \
            cp "$GITHUB_WORKSPACE/nex_pkg/lock_wallpaper" "$DUMP_DIR/media/theme/default/" && \
            log_success "✓ lock_wallpaper"
        log_success "NexPackage injection complete"
    fi

    # ─────────────────────────────────────────────────────
    #  H. BUILD PROPS
    # ─────────────────────────────────────────────────────
    log_info "📝 Writing build.prop additions..."
    find "$DUMP_DIR" -name "build.prop" | while read prop; do
        echo "$PROPS_CONTENT" >> "$prop"
        log_success "✓ Updated: $prop"
    done

    # ─────────────────────────────────────────────────────
    #  I. REPACK → EROFS
    # ─────────────────────────────────────────────────────
    log_info "📦 Repacking ${part}..."
    START_TIME=$(date +%s)
    sudo mkfs.erofs -zlz4 "$SUPER_DIR/${part}.img" "$DUMP_DIR" 2>&1 | grep -E "Build.*completed|ERROR"
    REPACK_TIME=$(($(date +%s)-START_TIME))
    if [ -f "$SUPER_DIR/${part}.img" ]; then
        log_success "✓ ${part}.img ($(du -h "$SUPER_DIR/${part}.img" | cut -f1)) in ${REPACK_TIME}s"
    else
        log_error "Failed to repack ${part}.img"
    fi
    sudo rm -rf "$DUMP_DIR"
done

# =========================================================
#  6. PACKAGE
# =========================================================
log_step "📦 Creating Final Package..."
PACK_DIR="$OUTPUT_DIR/Final_Pack"
mkdir -p "$PACK_DIR/super" "$PACK_DIR/images"

for img in system system_ext product mi_ext vendor odm system_dlkm vendor_dlkm; do
    for src in "$SUPER_DIR/${img}.img" "$IMAGES_DIR/${img}.img"; do
        [ -f "$src" ] && mv "$src" "$PACK_DIR/super/" && log_success "✓ $img.img" && break
    done
done

find "$IMAGES_DIR" -maxdepth 1 -name "*.img" -exec mv {} "$PACK_DIR/images/" \;
log_success "✓ Firmware images moved"

cat <<'EOF' > "$PACK_DIR/flash_rom.bat"
@echo off
echo ===== NEXDROID FLASHER =====
fastboot set_active a
echo Flashing firmware...
for %%f in (images\*.img) do fastboot flash %%~nf "%%f"
echo Flashing super partitions...
for %%f in (super\*.img) do fastboot flash %%~nf "%%f"
echo Wiping data...
fastboot erase userdata
fastboot reboot
pause
EOF

log_step "🗜️  Compressing..."
cd "$PACK_DIR"
SUPER_ZIP="ota-nexdroid-${OS_VER}_${DEVICE_CODE}_${ANDROID_VER}.zip"
START_TIME=$(date +%s)
7z a -tzip -mx1 -mmt="$(nproc)" "$SUPER_ZIP" . > /dev/null
ZIP_TIME=$(($(date +%s)-START_TIME))
[ ! -f "$SUPER_ZIP" ] && { log_error "Compression failed!"; exit 1; }
ZIP_SIZE=$(du -h "$SUPER_ZIP" | cut -f1)
log_success "✓ $SUPER_ZIP ($ZIP_SIZE) in ${ZIP_TIME}s"
mv "$SUPER_ZIP" "$OUTPUT_DIR/"

# =========================================================
#  7. UPLOAD
# =========================================================
log_step "☁️  Uploading to PixelDrain..."
cd "$OUTPUT_DIR"

upload() {
    local file="$1"
    [ ! -f "$file" ] && return
    log_info "Uploading $(basename "$file")..."
    if [ -z "$PIXELDRAIN_KEY" ]; then
        curl -s -T "$file" "https://pixeldrain.com/api/file/" | jq -r '"https://pixeldrain.com/u/" + .id'
    else
        curl -s -T "$file" -u ":$PIXELDRAIN_KEY" "https://pixeldrain.com/api/file/" | jq -r '"https://pixeldrain.com/u/" + .id'
    fi
}

LINK_ZIP=$(upload "$SUPER_ZIP")
if [ -z "$LINK_ZIP" ] || [ "$LINK_ZIP" == "null" ]; then
    log_error "Upload failed!"; LINK_ZIP="https://pixeldrain.com"; BTN_TEXT="Upload Failed"
else
    log_success "✓ $LINK_ZIP"; BTN_TEXT="Download ROM"
fi

# =========================================================
#  8. TELEGRAM
# =========================================================
if [ -n "$TELEGRAM_TOKEN" ] && [ -n "$CHAT_ID" ]; then
    log_step "📣 Telegram notification..."
    JSON_PAYLOAD=$(jq -n \
        --arg cid  "$CHAT_ID" \
        --arg txt  "**NEXDROID BUILD COMPLETE**\n\`Device  : $DEVICE_CODE\`\n\`Version : $OS_VER\`\n\`Android : $ANDROID_VER\`\n\`Built   : $(date +"%Y-%m-%d %H:%M")\`" \
        --arg url  "$LINK_ZIP" \
        --arg btn  "$BTN_TEXT" \
        '{chat_id:$cid,parse_mode:"Markdown",text:$txt,reply_markup:{inline_keyboard:[[{text:$btn,url:$url}]]}}')
    RESP=$(curl -s -w "\n%{http_code}" -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage" \
        -H "Content-Type: application/json" -d "$JSON_PAYLOAD")
    [[ "$RESP" == *"200"* ]] && log_success "✓ Notification sent" || \
        log_warning "Notification failed"
else
    log_warning "Skipping Telegram (no TOKEN/CHAT_ID)"
fi

# =========================================================
#  9. SUMMARY
# =========================================================
log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_step "          BUILD SUMMARY"
log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_success "Device  : $DEVICE_CODE"
log_success "OS Ver  : $OS_VER"
log_success "Android : $ANDROID_VER"
log_success "Package : $SUPER_ZIP"
log_success "Link    : $LINK_ZIP"
log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
exit 0
