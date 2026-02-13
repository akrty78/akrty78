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
