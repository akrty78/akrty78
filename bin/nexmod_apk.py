#!/usr/bin/env python3
"""
nexmod_apk.py  ─  NexDroid Surgical APK Engine  v2.0
═══════════════════════════════════════════════════════════════════════════════
ROOT CAUSE ANALYSIS — Android -124 Error:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  "Targeting R+ (version 30+) requires the resources.arsc of installed APKs
   to be stored uncompressed and aligned on a 4-byte boundary"

  Why apktool b -c ALWAYS breaks it:
    ┌──────────────────────────────────────────────────────────────────┐
    │ apktool creates a BRAND NEW zip container. Even with -c (copy   │
    │ resources), it writes entries without alignment padding. The    │
    │ resources.arsc ends up at a non-4-byte-aligned offset → -124.  │
    └──────────────────────────────────────────────────────────────────┘

  Why "zip -0 -u classes.dex" STILL breaks alignment:
    When zip updates an entry, it rewrites the Central Directory and
    may compact the archive, SHIFTING the offset of every subsequent
    entry — including resources.arsc. Even one shifted byte can
    misalign it and cause -124 on the next boot.

THE FIX — ZipAligner (pure Python, zero external deps):
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Rebuilds the entire ZIP from scratch, controlling every byte.
  Alignment is achieved by padding the extra field in the Local
  File Header so that data starts at a 4-byte-aligned offset:

    [LFH 30B][filename nB][extra ← WE PAD THIS][DATA ← must be % 4 == 0]

PIPELINE (replaces all apktool b calls):
  ① Read all entries from original APK
  ② Replace target DEX bytes with patched version (baksmali→smali)
  ③ ZipAligner.rebuild() writes new ZIP:
       resources.arsc  → STORE + 4B-aligned
       classes*.dex    → STORE + 4B-aligned
       everything else → original compression, not touched
  ④ ZipAligner.verify() — catches misalignment before deployment

COMMANDS:
  nexmod_apk.py patch   <apk> <profile>   DEX-patch + fix alignment
  nexmod_apk.py fix     <apk>             Fix alignment only (no DEX change)
  nexmod_apk.py verify  <apk>             Audit STORE+align compliance
  nexmod_apk.py inspect <apk>             Print entry map
  nexmod_apk.py profiles                  List patch profiles

PATCH PROFILES:
  framework-sig       Disable APK signature verification (framework.jar)
  settings-ai         Enable Xiaomi AI features (Settings.apk)
  systemui-volte      Enable VoLTE icons (MiuiSystemUI.apk)
  provision-gms       Enable GMS (Provision.apk)
  miui-service        CN→Global patch (miui-services.jar)
  voice-recorder-ai   Enable AI recorder features (SoundRecorder*.apk)
"""

import sys, os, re, io, struct, zlib, shutil, zipfile
import subprocess, tempfile, traceback
from pathlib import Path
from typing import Callable, Dict, List, Optional, Tuple

# ─── Logging ──────────────────────────────────────────────────────────────────
def _p(tag: str, msg: str) -> None: print(f"[{tag}] {msg}", flush=True)
info  = lambda m: _p("INFO",    m)
ok    = lambda m: _p("SUCCESS", m)
warn  = lambda m: _p("WARNING", m)
err   = lambda m: _p("ERROR",   m)

# ─── Tool paths ───────────────────────────────────────────────────────────────
_BIN     = Path(os.environ.get("BIN_DIR", Path(__file__).parent))
BAKSMALI = _BIN / "baksmali.jar"
SMALI    = _BIN / "smali.jar"
API      = "35"

# ═══════════════════════════════════════════════════════════════════════════════
#  ①  Z I P   A L I G N E R
#     The single class that permanently kills -124.
# ═══════════════════════════════════════════════════════════════════════════════
class ZipAligner:
    """
    Pure-Python ZIP aligner — NO zipalign, NO aapt2, NO apktool.

    Alignment formula (per entry):
        base_data_offset = archive_position + 30 + len(filename)
        pad = (alignment - base_data_offset % alignment) % alignment
        extra_field = b'\\x00' * pad          # injected into LFH
        actual_data_offset = base_data_offset + pad   ← guaranteed % alignment == 0
    """

    # ZIP magic bytes
    _LFH  = b'PK\x03\x04'   # Local File Header
    _CFH  = b'PK\x01\x02'   # Central Directory Header
    _EOCD = b'PK\x05\x06'   # End of Central Directory

    # struct formats  (all little-endian)
    #  LFH  30 bytes: sig(4) ver(2) flag(2) comp(2) time(2) date(2) crc(4) csz(4) usz(4) fnl(2) exl(2)
    _FMT_LFH  = '<4sHHHHHIIIHH'
    #  CFH  46 bytes: sig(4) vmade(2) vneed(2) flag(2) comp(2) time(2) date(2)
    #                 crc(4) csz(4) usz(4) fnl(2) exl(2) cml(2) dsk(2) iat(2) eat(4) off(4)
    _FMT_CFH  = '<4sHHHHHHIIIHHHHHII'
    # EOCD 22 bytes: sig(4) dsk(2) dsk_cd(2) ent(2) tot(2) cdsz(4) cdoff(4) cml(2)
    _FMT_EOCD = '<4sHHHHIIH'

    # Entries that MUST be STORED + 4B-aligned (Android R+ / API 30+ mandate)
    _FORCE_STORE = frozenset({'resources.arsc'})
    _FORCE_STORE_RE = re.compile(r'^classes\d*\.dex$')

    @classmethod
    def _must_store(cls, name: str) -> bool:
        return name in cls._FORCE_STORE or bool(cls._FORCE_STORE_RE.match(name))

    @staticmethod
    def _dos_datetime(dt) -> Tuple[int, int]:
        """ZipInfo.date_time → (dos_time, dos_date)."""
        try:
            y, mo, d, h, mi, s = (int(x) for x in dt)
            return (h * 2048 + mi * 32 + s // 2, (y - 1980) * 512 + mo * 32 + d)
        except Exception:
            return (0, 0)

    @classmethod
    def rebuild(cls,
                entries: List[Tuple[zipfile.ZipInfo, bytes]],
                dst: Path,
                alignment: int = 4) -> Dict:
        """
        Write a new, fully aligned ZIP from a list of (ZipInfo, raw_bytes) pairs.
        raw_bytes is always the UNCOMPRESSED content.
        Returns {'aligned': [names], 'kept': [names]}.
        """
        stats: Dict = {'aligned': [], 'kept': [], 'recompressed': []}
        buf = io.BytesIO()
        cd_entries: List[Tuple[bytes, bytes]] = []   # (cfh_bytes, fname_bytes)

        for info, raw in entries:
            fname_b  = info.filename.encode('utf-8')
            do_store = cls._must_store(info.filename)

            # ── compression decision ─────────────────────────────────────
            if do_store:
                compress = zipfile.ZIP_STORED
                out_data = raw
            elif info.compress_type == zipfile.ZIP_DEFLATED:
                compress = zipfile.ZIP_DEFLATED
                c = zlib.compressobj(zlib.Z_DEFAULT_COMPRESSION, zlib.DEFLATED, -15)
                out_data = c.compress(raw) + c.flush()
                stats['recompressed'].append(info.filename)
            else:
                compress = zipfile.ZIP_STORED
                out_data = raw

            crc = zlib.crc32(raw) & 0xFFFFFFFF

            # ── alignment padding (STORE entries only) ───────────────────
            extra = b''
            if compress == zipfile.ZIP_STORED:
                pos           = buf.tell()
                base_data_off = pos + 30 + len(fname_b)   # with zero extra
                rem           = base_data_off % alignment
                if rem:
                    extra = b'\x00' * (alignment - rem)
                    stats['aligned'].append(info.filename)
                else:
                    stats['kept'].append(info.filename)

            entry_offset = buf.tell()
            dt, dd       = cls._dos_datetime(info.date_time)
            # Clear data-descriptor bit (3); preserve UTF-8 flag (11)
            flags = info.flag_bits & ~0x08

            # ── Local File Header ─────────────────────────────────────────
            lfh = struct.pack(cls._FMT_LFH,
                cls._LFH, 20, flags, compress, dt, dd,
                crc, len(out_data), len(raw), len(fname_b), len(extra))
            buf.write(lfh)
            buf.write(fname_b)
            buf.write(extra)

            # ── Safety assertion — catch any alignment bug immediately ────
            if compress == zipfile.ZIP_STORED and raw:
                actual = buf.tell()
                assert actual % alignment == 0, (
                    f"ALIGNMENT BUG: {info.filename!r} data lands at "
                    f"unaligned offset {actual} (wanted % {alignment} == 0)")

            buf.write(out_data)

            # ── Central Directory record (written after all entries) ──────
            cfh = struct.pack(cls._FMT_CFH,
                cls._CFH,
                (3 << 8) | 20,   # version made by: Unix host, v2.0
                20,              # version needed: 2.0
                flags, compress, dt, dd,
                crc, len(out_data), len(raw),
                len(fname_b), 0, 0,    # fname_len, extra_len(CD), comment_len
                0, 0,                  # disk_start, internal_attr
                info.external_attr,    # preserves Unix permissions (rwxr-xr-x etc.)
                entry_offset)
            cd_entries.append((cfh, fname_b))

        # ── Central Directory ─────────────────────────────────────────────
        cd_start = buf.tell()
        for cfh_b, fname_b in cd_entries:
            buf.write(cfh_b)
            buf.write(fname_b)
        cd_size = buf.tell() - cd_start
        n = len(cd_entries)

        # ── End of Central Directory ──────────────────────────────────────
        buf.write(struct.pack(cls._FMT_EOCD,
            cls._EOCD, 0, 0, n, n, cd_size, cd_start, 0))

        dst.write_bytes(buf.getvalue())
        return stats

    @classmethod
    def fix_inplace(cls, apk: Path, alignment: int = 4) -> Dict:
        """Read APK, rebuild with alignment, replace in-place."""
        with zipfile.ZipFile(apk, 'r') as z:
            entries = [(info, z.read(info.filename)) for info in z.infolist()]
        tmp = apk.with_suffix('.ztmp_align')
        stats = cls.rebuild(entries, tmp, alignment)
        tmp.rename(apk)
        return stats

    @classmethod
    def verify(cls, apk: Path, alignment: int = 4) -> bool:
        """
        Verify resources.arsc + all DEX are STORE + properly aligned.
        Reads raw ZIP bytes to find actual data offsets (not trusting Python's
        header_offset which can be stale after in-place updates).
        """
        raw    = apk.read_bytes()
        issues = []

        with zipfile.ZipFile(apk, 'r') as z:
            for info in z.infolist():
                if not cls._must_store(info.filename):
                    continue

                # Check compression method
                if info.compress_type != zipfile.ZIP_STORED:
                    issues.append(f"  ✗ {info.filename}: DEFLATE (must be STORE)")
                    continue

                # Parse raw LFH at info.header_offset to get true data offset
                off = info.header_offset
                if off + 30 > len(raw):
                    issues.append(f"  ✗ {info.filename}: header_offset out of bounds")
                    continue
                fname_len, extra_len = struct.unpack_from('<HH', raw, off + 26)
                data_off = off + 30 + fname_len + extra_len

                if data_off % alignment != 0:
                    issues.append(
                        f"  ✗ {info.filename}: data@{data_off} "
                        f"(offset % {alignment} = {data_off % alignment}  ← NOT aligned)")
                else:
                    ok(f"  ✓ {info.filename}: STORE @ offset {data_off} (aligned)")

        for issue in issues:
            err(issue)

        if not issues:
            ok(f"  APK is Android R+ compliant (all STORE entries {alignment}B-aligned)")
        return not issues


# ═══════════════════════════════════════════════════════════════════════════════
#  ②  S M A L I   P A T C H   H E L P E R S
#     Surgical line-level smali edits. Every helper uses while-loops
#     (not for-range) to avoid IndexError when list size changes mid-loop.
# ═══════════════════════════════════════════════════════════════════════════════

def _safe(fn, *a) -> int:
    """Run a patch helper; return 0 instead of crashing on exception."""
    try:
        result = fn(*a)
        return result if result is not None else 0
    except Exception as exc:
        warn(f"    patch step skipped ({fn.__name__}): {exc}")
        return 0


def force_return(d: Path, key: str, val: str) -> int:
    """
    Stub all non-void methods whose name contains `key` to:
        .registers 8
        const/4 v0, 0x{val}
        return v0
    """
    stub = f"const/4 v0, 0x{val}"
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
                # Skip if already stubbed
                body = lines[i:j+1]
                if len(body) >= 4 and body[2].strip() == stub and body[3].strip().startswith("return"):
                    i = j + 1; continue
                lines[i:j+1] = [lines[i], "    .registers 8",
                                 f"    {stub}", "    return v0", ".end method"]
                chg = True; total += 1; i += 5
            else:
                i += 1
        if chg: f.write_text("\n".join(lines) + "\n")
    (ok if total else warn)(f"    force_return({key!r} → {val}): {total}")
    return total


def force_return_void(d: Path, key: str) -> int:
    """Stub all void methods containing `key` to return-void immediately."""
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
    (ok if total else warn)(f"    force_return_void({key!r}): {total}")
    return total


def replace_move_result(d: Path, invoke: str, replacement: str) -> int:
    """Replace move-result* immediately after any line containing `invoke`."""
    total = 0
    for f in d.rglob("*.smali"):
        lines = f.read_text(errors="replace").splitlines()
        i, chg = 0, False
        while i < len(lines):
            if invoke in lines[i]:
                for j in range(i + 1, min(i + 6, len(lines))):
                    if lines[j].strip().startswith("move-result"):
                        ind     = re.match(r"\s*", lines[j]).group(0)
                        new_ln  = f"{ind}{replacement}"
                        if lines[j] != new_ln:
                            lines[j] = new_ln; chg = True; total += 1
                        break
            i += 1
        if chg: f.write_text("\n".join(lines) + "\n")
    (ok if total else warn)(f"    replace_move_result({invoke[-50:]!r}): {total}")
    return total


def insert_before(d: Path, pattern: str, new_line: str) -> int:
    """Insert `new_line` (with matching indent) before every line matching `pattern`. Deduplicates."""
    total = 0
    for f in d.rglob("*.smali"):
        lines = f.read_text(errors="replace").splitlines()
        i, chg = 0, False
        while i < len(lines):
            if pattern in lines[i]:
                ind = re.match(r"\s*", lines[i]).group(0)
                candidate = f"{ind}{new_line}"
                if i == 0 or lines[i - 1].strip() != new_line.strip():
                    lines.insert(i, candidate); chg = True; total += 1; i += 2
                else:
                    i += 1
            else:
                i += 1
        if chg: f.write_text("\n".join(lines) + "\n")
    (ok if total else warn)(f"    insert_before({pattern[-50:]!r}): {total}")
    return total


def strip_if_eqz_after(d: Path, pattern: str) -> int:
    """Remove the first if-eqz guard following any line containing `pattern`."""
    total = 0
    for f in d.rglob("*.smali"):
        lines = f.read_text(errors="replace").splitlines()
        chg = False; i = 0
        while i < len(lines):                  # while-loop: safe after del
            if pattern in lines[i]:
                j = i + 1
                while j < min(i + 12, len(lines)):
                    if re.match(r'\s*if-eqz\s', lines[j]):
                        del lines[j]; chg = True; total += 1; break
                    j += 1
            i += 1
        if chg: f.write_text("\n".join(lines) + "\n")
    (ok if total else warn)(f"    strip_if_eqz_after({pattern[-50:]!r}): {total}")
    return total


def sed_all(d: Path, find_re: str, replace: str) -> int:
    """Regex substitution across ALL smali files in directory tree."""
    pat = re.compile(find_re)
    total = 0
    for f in d.rglob("*.smali"):
        text = f.read_text(errors="replace")
        new_text, n = pat.subn(replace, text)
        if n:
            f.write_text(new_text); total += n
    (ok if total else warn)(f"    sed_all({find_re!r}): {total}")
    return total


# ═══════════════════════════════════════════════════════════════════════════════
#  ③  P A T C H   P R O F I L E S
# ═══════════════════════════════════════════════════════════════════════════════

def _profile_framework_sig(d: Path) -> bool:
    """
    framework.jar — Complete APK signature verification bypass.
    Patches both classes.dex and classes4.dex targets.
    """
    n = 0
    # cert-check register force-set before verification call
    n += _safe(insert_before, d,
        "ApkSignatureVerifier;->unsafeGetCertsWithoutVerification",
        "const/4 v1, 0x1")
    # zero out PackageParserException error code
    n += _safe(insert_before, d,
        "iput p1, p0, Landroid/content/pm/PackageParser$PackageParserException;->error:I",
        "const/4 p1, 0x0")
    # capability checks → always true
    n += _safe(force_return, d, "checkCapability",        "1")
    n += _safe(force_return, d, "checkCapabilityRecover", "1")
    n += _safe(force_return, d, "hasAncestorOrSelf",      "1")
    # digest equality checks → always true (V2/V3 verifiers)
    n += _safe(replace_move_result, d,
        "invoke-static {v8, v4}, Ljava/security/MessageDigest;->isEqual([B[B)Z",
        "const/4 v0, 0x1")
    n += _safe(replace_move_result, d,
        "invoke-static {v9, v3}, Ljava/security/MessageDigest;->isEqual([B[B)Z",
        "const/4 v0, 0x1")
    n += _safe(replace_move_result, d,
        "invoke-static {v5, v6}, Ljava/security/MessageDigest;->isEqual([B[B)Z",
        "const/4 v7, 0x1")
    # minimum scheme version → 0 (V1 always acceptable)
    n += _safe(force_return, d, "getMinimumSignatureSchemeVersionForTargetSdk", "0")
    # force scheme=0 at V1 verify call sites
    n += _safe(insert_before, d,
        "ApkSignatureVerifier;->verifyV1Signature",
        "const p3, 0x0")
    # StrictJarVerifier: message digest bypass
    n += _safe(force_return, d, "verifyMessageDigest", "1")
    # StrictJarFile: remove null-entry guard
    n += _safe(strip_if_eqz_after, d,
        "Landroid/util/jar/StrictJarFile;->findEntry(Ljava/lang/String;)Ljava/util/zip/ZipEntry;")
    # ParsingPackageUtils: swallow sharedUserId validation
    n += _safe(insert_before, d,
        "manifest> specifies bad sharedUserId name",
        "const/4 v4, 0x0")
    info(f"    Total patches applied this DEX: {n}")
    return n > 0


def _profile_intl_build(d: Path) -> bool:
    """
    IS_INTERNATIONAL_BUILD → 1.
    Used by: Settings AI, SystemUI VoLTE, Provision GMS, miui-service.
    """
    n = 0
    n += _safe(sed_all, d,
        r'(\s*)sget-boolean (v\d+), Lmiui/os/Build;->IS_INTERNATIONAL_BUILD:Z',
        r'\1const/4 \2, 0x1')
    n += _safe(replace_move_result, d,
        "Lmiui/os/Build;->getRegion()Ljava/lang/String;",
        "const/4 v0, 0x1")
    return n > 0


def _profile_settings_ai(d: Path) -> bool:
    """
    Settings.apk — Force ALL AI-support check methods to return true.
    Handles name variations across HyperOS 2/3 sub-versions.
    """
    AI_KEYS = ("isAi", "AiSupport", "aiSupport", "SupportAi", "supportAi",
               "isAiS", "isAiFeatureSupported", "isAiSupportedDevice")
    total = 0
    for f in d.rglob("*.smali"):
        if "InternalDeviceUtils" not in f.name and "AiUtils" not in f.name:
            continue
        lines = f.read_text(errors="replace").splitlines()
        i, chg = 0, False
        while i < len(lines):
            s = lines[i].lstrip()
            is_tgt = (s.startswith(".method") and ")V" not in s and
                      any(k in s for k in AI_KEYS))
            if is_tgt:
                j = i + 1
                while j < len(lines) and not lines[j].lstrip().startswith(".end method"):
                    j += 1
                if j >= len(lines): i += 1; continue
                name = s.split()[-1] if s.split() else "?"
                lines[i:j+1] = [lines[i], "    .registers 2",
                                 "    const/4 v0, 0x1", "    return v0", ".end method"]
                chg = True; total += 1
                ok(f"    Patched: {name}")
                i += 5
            else:
                i += 1
        if chg: f.write_text("\n".join(lines) + "\n")
    if total == 0:
        warn("    InternalDeviceUtils/AiUtils not found in this DEX")
    return total > 0


def _profile_voice_recorder(d: Path) -> bool:
    """SoundRecorder — enable all AI / premium / VIP feature gates."""
    n = 0
    for key in ("isAiSupported", "isPremium", "isAiEnabled",
                "isVipUser", "hasAiFeature", "isMiAiSupported"):
        n += _safe(force_return, d, key, "1")
    n += _safe(sed_all, d,
        r'(\s*)sget-boolean (v\d+), Lmiui/os/Build;->IS_INTERNATIONAL_BUILD:Z',
        r'\1const/4 \2, 0x1')
    return n > 0


# Profile registry: name → (needle strings, patch_fn)
PROFILES: Dict = {
    "framework-sig":     (
        ["ApkSignatureVerifier", "SigningDetails", "StrictJarVerifier",
         "StrictJarFile", "PackageParser", "ApkSigningBlock",
         "ParsingPackageUtils"],
        _profile_framework_sig),
    "settings-ai":       (["InternalDeviceUtils"], _profile_settings_ai),
    "systemui-volte":    (["IS_INTERNATIONAL_BUILD", "miui/os/Build"], _profile_intl_build),
    "provision-gms":     (["IS_INTERNATIONAL_BUILD"], _profile_intl_build),
    "miui-service":      (["IS_INTERNATIONAL_BUILD", "miui/os/Build"], _profile_intl_build),
    "voice-recorder-ai": (["IS_INTERNATIONAL_BUILD", "isAiSupported", "isPremium"],
                          _profile_voice_recorder),
}


# ═══════════════════════════════════════════════════════════════════════════════
#  ④  D E X   P A T C H E R
#     Handles baksmali decompile → patch → smali recompile.
#     Returns new DEX bytes (not a modified archive — ZipAligner handles that).
# ═══════════════════════════════════════════════════════════════════════════════
class DEXPatcher:
    DEX_RE = re.compile(r'^classes\d*\.dex$')

    @classmethod
    def list_dexes(cls, archive: Path) -> List[str]:
        with zipfile.ZipFile(archive) as z:
            dexes = [n for n in z.namelist() if cls.DEX_RE.match(n)]
        return sorted(dexes, key=lambda x: (0 if x == "classes.dex"
                                            else int(re.search(r'\d+', x).group())))

    @classmethod
    def dex_has(cls, archive: Path, dex_name: str, *needles: str) -> bool:
        with zipfile.ZipFile(archive) as z:
            raw = z.read(dex_name)
        return any(n.encode() in raw for n in needles)

    @classmethod
    def patch_dex(cls,
                  archive: Path,
                  dex_name: str,
                  patch_fn: Callable[[Path], bool]) -> Optional[bytes]:
        """
        Decompile `dex_name` from `archive`, run `patch_fn(smali_dir)`,
        recompile, and return the new DEX bytes.
        Returns None on any failure (caller keeps original).
        """
        work = Path(tempfile.mkdtemp(prefix="nexmod_dex_"))
        try:
            # Extract target DEX
            dex_path = work / dex_name
            with zipfile.ZipFile(archive) as z:
                dex_path.write_bytes(z.read(dex_name))
            info(f"    {dex_name}: {dex_path.stat().st_size // 1024}K extracted")

            # baksmali decompile
            smali_dir = work / "smali"
            smali_dir.mkdir()
            r = subprocess.run(
                ["java", "-jar", str(BAKSMALI), "d", "-a", API,
                 str(dex_path), "-o", str(smali_dir)],
                capture_output=True, text=True, timeout=600)
            if r.returncode != 0:
                err(f"    baksmali failed:\n{r.stderr[:400]}"); return None
            n_smali = sum(1 for _ in smali_dir.rglob("*.smali"))
            info(f"    baksmali: {n_smali} smali files")

            # Apply patch function
            try:
                changed = patch_fn(smali_dir)
            except Exception as exc:
                err(f"    patch_fn raised: {exc}"); traceback.print_exc(); return None
            if not changed:
                warn(f"    {dex_name}: no patches applied"); return None

            # smali recompile
            new_dex = work / f"out_{dex_name}"
            r = subprocess.run(
                ["java", "-jar", str(SMALI), "a", "-a", API,
                 str(smali_dir), "-o", str(new_dex)],
                capture_output=True, text=True, timeout=600)
            if r.returncode != 0:
                err(f"    smali failed:\n{r.stderr[:400]}"); return None
            info(f"    smali output: {new_dex.stat().st_size // 1024}K")
            return new_dex.read_bytes()

        except Exception as exc:
            err(f"    patch_dex crash: {exc}"); traceback.print_exc(); return None
        finally:
            shutil.rmtree(work, ignore_errors=True)


# ═══════════════════════════════════════════════════════════════════════════════
#  ⑤  A P K   P A T C H E R  (orchestrator)
# ═══════════════════════════════════════════════════════════════════════════════
class APKPatcher:
    """
    Combines DEXPatcher + ZipAligner into a single safe pipeline:
      1. Create .bak backup (once, never overwritten)
      2. Patch DEX bytes in memory
      3. ZipAligner.rebuild() with patched DEX + STORE alignment
      4. ZipAligner.verify() → restore backup on failure
    """

    @staticmethod
    def _backup(apk: Path) -> Path:
        bak = Path(str(apk) + ".bak")
        if not bak.exists():
            shutil.copy2(apk, bak)
            ok(f"  Backup: {bak.name}")
        return bak

    @staticmethod
    def _restore(apk: Path) -> None:
        bak = Path(str(apk) + ".bak")
        if bak.exists():
            shutil.copy2(bak, apk)
            warn(f"  Restored from backup: {apk.name}")

    # ── fix: alignment only, no DEX change ────────────────────────────────────
    @classmethod
    def fix(cls, apk: Path) -> bool:
        """Fix resources.arsc and DEX alignment/compression. No smali changes."""
        apk = apk.resolve()
        if not apk.exists():
            err(f"Not found: {apk}"); return False
        info(f"Fixing: {apk.name}  ({apk.stat().st_size // 1024}K)")
        bak = cls._backup(apk)
        try:
            stats = ZipAligner.fix_inplace(apk)
            ok(f"  Aligned: {len(stats['aligned'])} entries  "
               f"| Already OK: {len(stats['kept'])} "
               f"| Recompressed: {len(stats['recompressed'])}")
            info("  Verifying...")
            if ZipAligner.verify(apk):
                ok(f"  ✅ {apk.name} is Android R+ compliant")
                return True
            else:
                err("  Verify failed → restoring backup")
                cls._restore(apk); return False
        except Exception as exc:
            err(f"  fix() crashed: {exc}"); traceback.print_exc()
            cls._restore(apk); return False

    # ── patch: DEX surgical patch + alignment fix ──────────────────────────────
    @classmethod
    def patch(cls, apk: Path, profile_name: str) -> bool:
        """
        Full pipeline:
          ① Find DEX files matching profile needles
          ② baksmali → patch smali → smali (in temp dir, no archive touched yet)
          ③ ZipAligner.rebuild() with patched DEX injected, STORE+align all entries
          ④ ZipAligner.verify() — if fails, restore backup
        """
        if profile_name not in PROFILES:
            err(f"Unknown profile: {profile_name!r}. Run 'profiles' to list.")
            return False
        apk = apk.resolve()
        if not apk.exists():
            err(f"Not found: {apk}"); return False

        needles, patch_fn = PROFILES[profile_name]
        info(f"Archive : {apk.name}  ({apk.stat().st_size // 1024}K)")
        info(f"Profile : {profile_name}")
        bak = cls._backup(apk)

        # Step ①+② — collect patched DEX bytes without touching the archive yet
        patched_dexes: Dict[str, bytes] = {}
        for dex_name in DEXPatcher.list_dexes(apk):
            if DEXPatcher.dex_has(apk, dex_name, *needles):
                info(f"  → {dex_name} contains target classes")
                new_bytes = DEXPatcher.patch_dex(apk, dex_name, patch_fn)
                if new_bytes:
                    patched_dexes[dex_name] = new_bytes
                    ok(f"  ✓ {dex_name} patched ({len(new_bytes) // 1024}K)")
            else:
                info(f"  · {dex_name}: skip (no target classes)")

        if not patched_dexes:
            err(f"Profile '{profile_name}': nothing patched — restoring backup")
            cls._restore(apk); return False

        # Step ③ — rebuild entire ZIP with patched DEXes + proper alignment
        info(f"  Rebuilding ZIP ({len(patched_dexes)} DEX replaced, alignment fixed)...")
        tmp = apk.with_suffix('.patch_rebuild_tmp')
        try:
            with zipfile.ZipFile(apk, 'r') as z:
                entries = []
                for zi in z.infolist():
                    if zi.filename in patched_dexes:
                        entries.append((zi, patched_dexes[zi.filename]))
                    else:
                        entries.append((zi, z.read(zi.filename)))

            stats = ZipAligner.rebuild(entries, tmp)
            tmp.rename(apk)
            ok(f"  ZIP rebuilt: {apk.stat().st_size // 1024}K  "
               f"(aligned {len(stats['aligned'])}, kept {len(stats['kept'])})")
        except Exception as exc:
            err(f"  ZIP rebuild failed: {exc}"); traceback.print_exc()
            if tmp.exists(): tmp.unlink()
            cls._restore(apk); return False

        # Step ④ — verify
        info("  Verifying...")
        if ZipAligner.verify(apk):
            ok(f"  ✅ {apk.name}: DEX patched + Android R+ compliant")
            return True
        else:
            err("  Post-patch verify FAILED → restoring backup")
            cls._restore(apk); return False

    # ── verify: audit only ────────────────────────────────────────────────────
    @classmethod
    def verify(cls, apk: Path) -> bool:
        apk = apk.resolve()
        if not apk.exists():
            err(f"Not found: {apk}"); return False
        info(f"Verifying: {apk.name}")
        return ZipAligner.verify(apk)

    # ── inspect: human-readable entry map ─────────────────────────────────────
    @classmethod
    def inspect(cls, apk: Path) -> None:
        apk = apk.resolve()
        if not apk.exists():
            err(f"Not found: {apk}"); return
        raw = apk.read_bytes()
        print(f"\n{'═'*65}")
        print(f"  APK  : {apk.name}")
        print(f"  Size : {apk.stat().st_size / 1024 / 1024:.2f} MB")
        print(f"{'─'*65}")
        print(f"  {'Entry':<40} {'Comp':>8}  {'Aligned':>8}  {'Data Offset':>12}")
        print(f"{'─'*65}")
        with zipfile.ZipFile(apk, 'r') as z:
            for info_zi in sorted(z.infolist(), key=lambda x: x.header_offset):
                off = info_zi.header_offset
                fname_len, extra_len = struct.unpack_from('<HH', raw, off + 26)
                data_off = off + 30 + fname_len + extra_len
                comp_str = "STORE" if info_zi.compress_type == 0 else "DEFLATE"
                aligned  = (data_off % 4 == 0)
                important = ZipAligner._must_store(info_zi.filename)
                flag = " ◄ MUST-STORE" if important else ""
                align_str = "✓" if (not important or aligned) else "✗ NOT-ALIGNED"
                print(f"  {info_zi.filename:<40} {comp_str:>8}  {align_str:>8}  {data_off:>12}{flag}")
        print(f"{'═'*65}\n")


# ═══════════════════════════════════════════════════════════════════════════════
#  ENTRY POINT
# ═══════════════════════════════════════════════════════════════════════════════
def _usage():
    print(__doc__)
    print("\nAvailable profiles:")
    for name, (needles, _) in PROFILES.items():
        print(f"  {name:<22} (needles: {needles[0]}...)")
    sys.exit(1)

def main():
    if len(sys.argv) < 2:
        _usage()

    cmd = sys.argv[1].lower()

    if cmd == "profiles":
        for name, (needles, _) in PROFILES.items():
            print(f"  {name:<22} triggers on: {', '.join(needles[:2])}")
        sys.exit(0)

    if cmd in ("fix", "verify", "inspect") and len(sys.argv) >= 3:
        apk = Path(sys.argv[2])
        result = {
            "fix":     lambda: APKPatcher.fix(apk),
            "verify":  lambda: APKPatcher.verify(apk),
            "inspect": lambda: (APKPatcher.inspect(apk), True)[1],
        }[cmd]()
        sys.exit(0 if result else 1)

    if cmd == "patch" and len(sys.argv) >= 4:
        apk, profile = Path(sys.argv[2]), sys.argv[3]
        sys.exit(0 if APKPatcher.patch(apk, profile) else 1)

    _usage()


if __name__ == "__main__":
    main()
