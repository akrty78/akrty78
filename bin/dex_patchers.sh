#!/usr/bin/env python3
"""
dex_patcher.py  ─  HyperOS ROM DEX patching engine  (production v4)
════════════════════════════════════════════════════════════════════
Pipeline (MT Manager DEX editor internals, scripted):

  1.  unzip <dex>       from APK/JAR        ← manifest NEVER touched
  2.  baksmali d        DEX → smali text
  3.  Python edits      smali text files     ← surgical, targeted
  4.  smali a           smali text → DEX
  5.  zip -0 -u         inject STORE DEX     ← ART requires uncompressed

WHY THIS WORKS WHERE apktool/binary FAILED:
  • apktool rebuilds the whole APK including manifest → crash at load
  • Binary DEX parsing had 3 bugs (wrong DEX, midx, compression)
  • This approach: one DEX changes, everything else byte-identical

COMMANDS:
  verify              check baksmali + smali are functional
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
BAKSMALI  = _BIN / "baksmali.jar"
SMALI     = _BIN / "smali.jar"
API       = "35"

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
    sys.exit(0 if all_ok else 1)


# ════════════════════════════════════════════════════════════════════
#  CORE PIPELINE
# ════════════════════════════════════════════════════════════════════

def list_dexes(archive: Path) -> list:
    """Return DEX names in canonical order: classes.dex, classes2.dex, ..."""
    with zipfile.ZipFile(archive) as z:
        names = [n for n in z.namelist() if re.match(r'^classes\d*\.dex$', n)]
    return sorted(names, key=lambda x: 0 if x == "classes.dex"
                                       else int(re.search(r'\d+', x).group()))

def dex_has(archive: Path, dex_name: str, *needles: str) -> bool:
    """Binary scan: does this DEX contain any of the string literals?"""
    with zipfile.ZipFile(archive) as z:
        raw = z.read(dex_name)
    return any(n.encode() in raw for n in needles)

def patch_dex(archive: Path, dex_name: str,
              patch_fn: Callable[[Path], bool]) -> bool:
    """
    Full pipeline for one DEX inside an archive.
    Returns True on success, False on any failure (caller restores backup).
    Never raises — all exceptions caught and logged.
    """
    work = Path(tempfile.mkdtemp(prefix="dp_"))
    try:
        # 1. Extract
        dex = work / dex_name
        with zipfile.ZipFile(archive) as z:
            dex.write_bytes(z.read(dex_name))
        info(f"  {dex_name}: {dex.stat().st_size // 1024}K extracted")

        # 2. baksmali decompile
        smali_out = work / "smali"
        smali_out.mkdir()
        r = subprocess.run(
            ["java", "-jar", str(BAKSMALI), "d", "-a", API, str(dex), "-o", str(smali_out)],
            capture_output=True, text=True, timeout=600)
        if r.returncode != 0:
            err(f"  baksmali failed: {r.stderr[:400]}"); return False
        n_smali = sum(1 for _ in smali_out.rglob("*.smali"))
        info(f"  baksmali: {n_smali} smali files")

        # 3. Apply patch function — isolated, never crashes outer loop
        try:
            changed = patch_fn(smali_out)
        except Exception as exc:
            err(f"  patch_fn raised: {exc}")
            traceback.print_exc()
            return False

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

        # 5. zip -0 -u  →  STORE (no compression) — ART mmaps DEX directly
        shutil.copy2(new_dex, work / dex_name)
        r = subprocess.run(
            ["zip", "-0", "-u", str(archive), dex_name],
            cwd=str(work), capture_output=True, text=True)
        # zip rc=12 means "nothing to update" (DEX bytes unchanged) — treat as success
        if r.returncode not in (0, 12):
            err(f"  zip failed (rc={r.returncode}): {r.stderr}"); return False

        ok(f"  ✓ {dex_name} patched")
        return True

    except Exception as exc:
        err(f"  patch_dex crash: {exc}")
        traceback.print_exc()
        return False
    finally:
        shutil.rmtree(work, ignore_errors=True)

def run_on_archive(archive: Path, needles: list,
                   patch_fn: Callable[[Path], bool], label: str) -> int:
    """
    Scan all DEXes in archive, run patch_dex on those matching needles.
    Takes backup before first change, restores on total failure.
    Returns count of successfully patched DEXes.
    """
    archive = archive.resolve()
    if not archive.exists():
        err(f"Not found: {archive}"); return 0
    info(f"Archive: {archive.name}  ({archive.stat().st_size // 1024}K)")

    bak = Path(str(archive) + ".bak")
    if not bak.exists():
        shutil.copy2(archive, bak)
        ok("✓ Backup created")

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
#  Each helper returns int (count of changes) and NEVER raises.
#  Uses while-loops for all line iteration to avoid IndexError
#  when lines are inserted or deleted during traversal.
# ════════════════════════════════════════════════════════════════════

def force_return(d: Path, key: str, val: str) -> int:
    """
    All non-void methods containing `key` → const/4 v0, 0x{val}; return v0
    Skips already-stubbed methods.
    """
    stub_const = f"const/4 v0, 0x{val}"
    total = 0
    for f in d.rglob("*.smali"):
        lines = f.read_text(errors="replace").splitlines()
        i, chg = 0, False
        while i < len(lines):
            s = lines[i].lstrip()
            if s.startswith(".method") and key in s and ")V" not in s:
                # Find matching .end method
                j = i + 1
                while j < len(lines) and not lines[j].lstrip().startswith(".end method"):
                    j += 1
                if j >= len(lines):
                    i += 1; continue
                # Check if already stubbed
                body = lines[i:j+1]
                if (len(body) >= 4 and body[2].strip() == stub_const
                        and body[3].strip().startswith("return")):
                    i = j + 1; continue
                # Replace
                lines[i:j+1] = [lines[i], "    .registers 8",
                                 f"    {stub_const}", "    return v0", ".end method"]
                chg = True; total += 1
                i += 5
            else:
                i += 1
        if chg:
            f.write_text("\n".join(lines) + "\n")
    if total: ok(   f"    force_return({key!r} → 0x{val}): {total}")
    else:     warn(  f"    force_return({key!r}): not found")
    return total


def force_return_void(d: Path, key: str) -> int:
    """All void methods containing `key` → return-void immediately."""
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
                if j >= len(lines):
                    i += 1; continue
                lines[i:j+1] = [lines[i], "    .registers 1",
                                 "    return-void", ".end method"]
                chg = True; total += 1
                i += 4
            else:
                i += 1
        if chg:
            f.write_text("\n".join(lines) + "\n")
    if total: ok(   f"    force_return_void({key!r}): {total}")
    else:     warn(  f"    force_return_void({key!r}): not found")
    return total


def replace_move_result(d: Path, invoke: str, replacement: str) -> int:
    """Replace move-result* after any line containing `invoke`."""
    total = 0
    for f in d.rglob("*.smali"):
        lines = f.read_text(errors="replace").splitlines()
        i, chg = 0, False
        while i < len(lines):
            if invoke in lines[i]:
                for j in range(i + 1, min(i + 6, len(lines))):
                    if lines[j].strip().startswith("move-result"):
                        ind = re.match(r"\s*", lines[j]).group(0)
                        new_line = f"{ind}{replacement}"
                        if lines[j] != new_line:
                            lines[j] = new_line; chg = True; total += 1
                        break
            i += 1
        if chg:
            f.write_text("\n".join(lines) + "\n")
    if total: ok(   f"    replace_move_result({invoke[-40:]!r}): {total} site(s)")
    else:     warn(  f"    replace_move_result({invoke[-40:]!r}): not found")
    return total


def insert_before(d: Path, pattern: str, new_line: str) -> int:
    """Insert `new_line` (with matching indent) before every line containing `pattern`."""
    total = 0
    for f in d.rglob("*.smali"):
        lines = f.read_text(errors="replace").splitlines()
        i, chg = 0, False
        while i < len(lines):
            if pattern in lines[i]:
                ind = re.match(r"\s*", lines[i]).group(0)
                candidate = f"{ind}{new_line}"
                # Deduplicate: don't insert twice
                if i == 0 or lines[i - 1].strip() != new_line.strip():
                    lines.insert(i, candidate)
                    chg = True; total += 1
                    i += 2   # skip the newly inserted line + original
                else:
                    i += 1
            else:
                i += 1
        if chg:
            f.write_text("\n".join(lines) + "\n")
    if total: ok(   f"    insert_before({pattern!r}): {total}")
    else:     warn(  f"    insert_before({pattern!r}): not found")
    return total


def strip_if_eqz_after(d: Path, pattern: str) -> int:
    """
    Remove the first if-eqz guard following any line containing `pattern`.
    Uses while-loop to avoid IndexError when lines are deleted.
    BUG FIX: 'for idx in range(len(lines))' caused IndexError after del lines[j]
             because range was computed from the original (now-stale) length.
    """
    total = 0
    for f in d.rglob("*.smali"):
        lines = f.read_text(errors="replace").splitlines()
        chg = False
        i = 0
        while i < len(lines):          # ← while, not for-range → safe after del
            if pattern in lines[i]:
                j = i + 1
                while j < min(i + 12, len(lines)):
                    if re.match(r'\s*if-eqz\s', lines[j]):
                        del lines[j]   # ← list shrinks here; while handles it
                        chg = True; total += 1
                        break          # ← stop inner scan after one deletion
                    j += 1
            i += 1
        if chg:
            f.write_text("\n".join(lines) + "\n")
    if total: ok(   f"    strip_if_eqz_after({pattern[-50:]!r}): {total}")
    else:     warn(  f"    strip_if_eqz_after: not found")
    return total


def sed_all(d: Path, find_re: str, replace: str) -> int:
    """Regex substitution across all smali files."""
    pat = re.compile(find_re)
    total = 0
    for f in d.rglob("*.smali"):
        text = f.read_text(errors="replace")
        new_text, n = pat.subn(replace, text)
        if n:
            f.write_text(new_text); total += n
    if total: ok(   f"    sed_all: {total} match(es)")
    else:     warn(  f"    sed_all: not found")
    return total


# ════════════════════════════════════════════════════════════════════
#  PATCH PROFILES
#  Each profile function takes a smali_dir Path, returns bool.
#  Individual patch failures log warnings but never crash the profile.
# ════════════════════════════════════════════════════════════════════

def _p_safe(fn, *args) -> int:
    """Run a patch helper, return 0 on exception instead of crashing."""
    try:
        return fn(*args)
    except Exception as exc:
        warn(f"    patch step failed ({fn.__name__}): {exc}")
        return 0


def _sig_patch(d: Path) -> bool:
    """
    framework.jar — full signature verification bypass.
    Mirrors patcher_a16.sh apply_framework_signature_patches exactly.
    10 patch targets, spread across classes.dex and classes4.dex.
    Any individual miss logs a WARNING but never crashes.
    """
    n = 0
    # ── classes.dex targets ──
    # 1. PackageParser: force cert-check register before verification call
    n += _p_safe(insert_before, d,
        "ApkSignatureVerifier;->unsafeGetCertsWithoutVerification",
        "const/4 v1, 0x1")

    # 2. PackageParser$PackageParserException: zero out error code
    n += _p_safe(insert_before, d,
        "iput p1, p0, Landroid/content/pm/PackageParser$PackageParserException;->error:I",
        "const/4 p1, 0x0")

    # 3. SigningDetails.checkCapability* → always true
    n += _p_safe(force_return, d, "checkCapability",        "1")
    n += _p_safe(force_return, d, "checkCapabilityRecover", "1")
    n += _p_safe(force_return, d, "hasAncestorOrSelf",      "1")

    # ── classes4.dex targets ──
    # 4. ApkSignatureSchemeV2Verifier: digest equality → true
    n += _p_safe(replace_move_result, d,
        "invoke-static {v8, v4}, Ljava/security/MessageDigest;->isEqual([B[B)Z",
        "const/4 v0, 0x1")

    # 5. ApkSignatureSchemeV3Verifier: digest equality → true
    n += _p_safe(replace_move_result, d,
        "invoke-static {v9, v3}, Ljava/security/MessageDigest;->isEqual([B[B)Z",
        "const/4 v0, 0x1")

    # 6a. getMinimumSignatureSchemeVersionForTargetSdk → 0 (V1 acceptable)
    n += _p_safe(force_return, d, "getMinimumSignatureSchemeVersionForTargetSdk", "0")

    # 6b. Force scheme=0 at every V1 verify call site
    n += _p_safe(insert_before, d,
        "ApkSignatureVerifier;->verifyV1Signature",
        "const p3, 0x0")

    # 7. ApkSigningBlockUtils: digest equality → true
    n += _p_safe(replace_move_result, d,
        "invoke-static {v5, v6}, Ljava/security/MessageDigest;->isEqual([B[B)Z",
        "const/4 v7, 0x1")

    # 8. StrictJarVerifier.verifyMessageDigest → always true
    n += _p_safe(force_return, d, "verifyMessageDigest", "1")

    # 9. StrictJarFile: remove null-entry guard after findEntry()
    n += _p_safe(strip_if_eqz_after, d,
        "Landroid/util/jar/StrictJarFile;->findEntry(Ljava/lang/String;)Ljava/util/zip/ZipEntry;")

    # 10. ParsingPackageUtils: swallow sharedUserId validation
    n += _p_safe(insert_before, d,
        "manifest> specifies bad sharedUserId name",
        "const/4 v4, 0x0")

    info(f"    Patches applied this DEX: {n}")
    return n > 0


def _intl_build_patch(d: Path) -> bool:
    """
    IS_INTERNATIONAL_BUILD → 1.
    Used by: Settings AI, SystemUI VoLTE, Provision GMS, miui-service.
    Two patterns covered:
      A. sget-boolean vX, Lmiui/os/Build;->IS_INTERNATIONAL_BUILD:Z
      B. invoke getRegion() → move-result-object → const/4
    """
    n = 0
    n += _p_safe(sed_all, d,
        r'(\s*)sget-boolean (v\d+), Lmiui/os/Build;->IS_INTERNATIONAL_BUILD:Z',
        r'\1const/4 \2, 0x1')
    n += _p_safe(replace_move_result, d,
        "Lmiui/os/Build;->getRegion()Ljava/lang/String;",
        "const/4 v0, 0x1")
    return n > 0


def _ai_patch(d: Path) -> bool:
    """
    Settings.apk — InternalDeviceUtils.isAiSupported() and all variants → true.
    Handles name variations across HyperOS 3 sub-versions.
    """
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
                if j >= len(lines):
                    i += 1; continue
                name = s.split()[-1] if s.split() else "?"
                lines[i:j+1] = [lines[i], "    .registers 2",
                                 "    const/4 v0, 0x1", "    return v0", ".end method"]
                chg = True; total += 1
                ok(f"    Patched: {name}")
                i += 5
            else:
                i += 1
        if chg:
            f.write_text("\n".join(lines) + "\n")
    if total == 0:
        warn("    InternalDeviceUtils not in this DEX")
    return total > 0


def _voice_recorder_patch(d: Path) -> bool:
    """
    SoundRecorder AI features — enable premium/AI flags.
    Patches:
      • isAiSupported*, isPremium*, isAiEnabled* → return true
      • IS_INTERNATIONAL_BUILD references → const/4 1
    """
    n = 0
    # Premium / AI method stubs
    for key in ("isAiSupported", "isPremium", "isAiEnabled", "isVipUser",
                "hasAiFeature", "isMiAiSupported"):
        n += _p_safe(force_return, d, key, "1")
    # IS_INTERNATIONAL_BUILD pattern (same as other apps)
    n += _p_safe(sed_all, d,
        r'(\s*)sget-boolean (v\d+), Lmiui/os/Build;->IS_INTERNATIONAL_BUILD:Z',
        r'\1const/4 \2, 0x1')
    return n > 0


# ════════════════════════════════════════════════════════════════════
#  COMMAND TABLE
# ════════════════════════════════════════════════════════════════════

# needle strings → which DEXes to process
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
        cmd_verify()
        return

    if len(sys.argv) < 3:
        err(f"Usage: dex_patcher.py {cmd} <archive.apk|.jar>"); sys.exit(1)

    count = run_on_archive(
        Path(sys.argv[2]),
        NEEDLES[cmd],
        PATCHERS[cmd],
        cmd)
    sys.exit(0 if count > 0 else 1)


if __name__ == "__main__":
    main()
