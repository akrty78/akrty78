#!/usr/bin/env python3
"""
dex_patcher.py  ─  HyperOS ROM DEX patching engine
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Workflow (identical to MT Manager DEX editor):
  1. unzip <dex> from APK/JAR
  2. java -jar baksmali.jar  d  <dex>  -o  smali_out/
  3. Python edits .smali text files  (no binary parsing)
  4. java -jar smali.jar     a  smali_out/  -o  <dex>
  5. zip -0 -u  <APK/JAR>  <dex>     ← STORE, manifest untouched

Usage:
  python3 dex_patcher.py verify
  python3 dex_patcher.py framework-sig  <framework.jar>
  python3 dex_patcher.py settings-ai    <Settings.apk>
  python3 dex_patcher.py systemui-volte <MiuiSystemUI.apk>
  python3 dex_patcher.py provision-gms  <Provision.apk>
  python3 dex_patcher.py miui-service   <miui-services.jar>
"""

import sys, os, re, subprocess, tempfile, shutil, zipfile
from pathlib import Path

# ── Locate tool JARs ──────────────────────────────────────────────
_BIN_DIR = Path(os.environ.get("BIN_DIR", Path(__file__).parent))
BAKSMALI  = _BIN_DIR / "baksmali.jar"
SMALI     = _BIN_DIR / "smali.jar"
API_LEVEL = "35"

# ── Logging helpers ───────────────────────────────────────────────
def _log(tag, msg):
    print(f"[{tag}] {msg}", flush=True)

def info(msg):    _log("INFO",    msg)
def success(msg): _log("SUCCESS", msg)
def warn(msg):    _log("WARNING", msg)
def error(msg):   _log("ERROR",   msg)

# ─────────────────────────────────────────────────────────────────
#  TOOL VERIFY
# ─────────────────────────────────────────────────────────────────
def cmd_verify():
    ok = True
    for jar in (BAKSMALI, SMALI):
        if not jar.exists():
            error(f"{jar.name} not found at {jar}"); ok = False; continue
        sz = jar.stat().st_size
        if sz < 500_000:
            error(f"{jar.name} too small ({sz}B) — download failed"); ok = False; continue
        result = subprocess.run(
            ["java", "-jar", str(jar), "--version"],
            capture_output=True, text=True)
        if result.returncode not in (0, 1):   # smali --version exits 1 on some versions
            error(f"{jar.name} failed to run: {result.stderr[:100]}"); ok = False; continue
        success(f"{jar.name} OK ({sz:,}B)")
    sys.exit(0 if ok else 1)

# ─────────────────────────────────────────────────────────────────
#  DEX PIPELINE: decompile → patch → recompile → inject
# ─────────────────────────────────────────────────────────────────
def list_dexes(archive: Path) -> list[str]:
    with zipfile.ZipFile(archive) as z:
        dexes = sorted(
            [n for n in z.namelist() if re.match(r'^classes\d*\.dex$', n)],
            key=lambda x: (0 if x == "classes.dex"
                           else int(re.search(r'\d+', x).group()))
        )
    return dexes

def dex_has_string(archive: Path, dex_name: str, *needles) -> bool:
    """Quick check: does this DEX contain any of the string literals?"""
    with zipfile.ZipFile(archive) as z:
        raw = z.read(dex_name)
    # strings are stored as MUTF-8; a simple bytes scan is sufficient for ASCII names
    for needle in needles:
        if needle.encode() in raw:
            return True
    return False

def patch_dex(archive: Path, dex_name: str, patch_fn, label="patch") -> bool:
    """
    Core pipeline: extract dex → baksmali → patch_fn(smali_dir) → smali → zip -0 -u
    Returns True on success.
    """
    work = Path(tempfile.mkdtemp(prefix="dexpatch_"))
    try:
        dex_path = work / dex_name

        # 1. Extract DEX
        with zipfile.ZipFile(archive) as z:
            dex_path.write_bytes(z.read(dex_name))
        orig_sz = dex_path.stat().st_size
        info(f"  {dex_name}: {orig_sz//1024}K")

        # 2. baksmali decompile
        smali_out = work / "smali_out"
        smali_out.mkdir()
        r = subprocess.run(
            ["java", "-jar", str(BAKSMALI), "d", "-a", API_LEVEL,
             str(dex_path), "-o", str(smali_out)],
            capture_output=True, text=True)
        if r.returncode != 0:
            error(f"  baksmali failed: {r.stderr[:200]}"); return False
        n_smali = sum(1 for _ in smali_out.rglob("*.smali"))
        info(f"  baksmali: {n_smali} smali files")

        # 3. Apply patches
        changed = patch_fn(smali_out)
        if not changed:
            warn(f"  {dex_name}: no patches applied (class not in this DEX)")
            return False

        # 4. smali recompile
        out_dex = work / f"{dex_name[:-4]}_patched.dex"
        r = subprocess.run(
            ["java", "-jar", str(SMALI), "a", "-a", API_LEVEL,
             str(smali_out), "-o", str(out_dex)],
            capture_output=True, text=True)
        if r.returncode != 0:
            error(f"  smali failed: {r.stderr[:200]}"); return False
        new_sz = out_dex.stat().st_size
        info(f"  smali: {new_sz//1024}K")

        # 5. zip -0 -u (STORE, no compression — ART mmaps DEX directly)
        shutil.copy2(out_dex, work / dex_name)
        r = subprocess.run(
            ["zip", "-0", "-u", str(archive), dex_name],
            cwd=str(work), capture_output=True, text=True)
        if r.returncode not in (0, 12):   # 12 = nothing changed
            error(f"  zip failed (rc={r.returncode}): {r.stderr}"); return False

        success(f"  ✓ {dex_name} patched and injected")
        return True

    finally:
        shutil.rmtree(work, ignore_errors=True)

def patch_archive(archive: Path, needle_strings: list[str], patch_fn, label="") -> int:
    """Run patch_dex on every DEX in archive that contains any needle string."""
    archive = archive.resolve()
    if not archive.exists():
        error(f"File not found: {archive}"); return 0
    patched = 0
    for dex in list_dexes(archive):
        if dex_has_string(archive, dex, *needle_strings):
            info(f"Processing {dex}...")
            if patch_dex(archive, dex, patch_fn, label):
                patched += 1
        else:
            info(f"Skipping  {dex} (no relevant classes)")
    return patched

# ─────────────────────────────────────────────────────────────────
#  SMALI TEXT MANIPULATION HELPERS
#  (pure Python — no regex on bytecode, only on smali text)
# ─────────────────────────────────────────────────────────────────

def force_return(smali_dir: Path, method_key: str, ret_val: str) -> int:
    """Force every non-void method containing method_key to return const ret_val."""
    const_line = f"const/4 v0, 0x{ret_val}"
    total = 0
    for f in smali_dir.rglob("*.smali"):
        lines = f.read_text(errors="replace").splitlines()
        changed = False
        i = 0
        while i < len(lines):
            s = lines[i].lstrip()
            if s.startswith(".method") and method_key in s and ")V" not in s:
                j = i + 1
                while j < len(lines) and not lines[j].lstrip().startswith(".end method"):
                    j += 1
                body = lines[i:j+1]
                if (len(body) >= 4 and body[2].strip() == const_line
                        and body[3].strip().startswith("return")):
                    i = j + 1; continue
                stub = [lines[i], "    .registers 8",
                        f"    {const_line}", "    return v0", ".end method"]
                lines[i:j+1] = stub
                changed = True; total += 1
                i += len(stub)
            else:
                i += 1
        if changed:
            f.write_text("\n".join(lines) + "\n")
    if total: success(f"    force_return({method_key!r} → 0x{ret_val}): {total} method(s)")
    else:     warn(   f"    force_return({method_key!r}): not found")
    return total

def force_return_void(smali_dir: Path, method_key: str) -> int:
    """Force every void method containing method_key to return-void immediately."""
    total = 0
    for f in smali_dir.rglob("*.smali"):
        lines = f.read_text(errors="replace").splitlines()
        changed = False
        i = 0
        while i < len(lines):
            s = lines[i].lstrip()
            if s.startswith(".method") and method_key in s and ")V" in s:
                j = i + 1
                while j < len(lines) and not lines[j].lstrip().startswith(".end method"):
                    j += 1
                stub = [lines[i], "    .registers 1", "    return-void", ".end method"]
                lines[i:j+1] = stub
                changed = True; total += 1
                i += len(stub)
            else:
                i += 1
        if changed:
            f.write_text("\n".join(lines) + "\n")
    if total: success(f"    force_return_void({method_key!r}): {total} method(s)")
    else:     warn(   f"    force_return_void({method_key!r}): not found")
    return total

def replace_move_result(smali_dir: Path, invoke_pattern: str, replacement: str) -> int:
    """Replace move-result* after any invoke matching invoke_pattern."""
    total = 0
    for f in smali_dir.rglob("*.smali"):
        lines = f.read_text(errors="replace").splitlines()
        changed = False
        i = 0
        while i < len(lines):
            if invoke_pattern in lines[i]:
                for j in range(i+1, min(i+6, len(lines))):
                    s = lines[j].strip()
                    if s.startswith("move-result"):
                        indent = re.match(r"\s*", lines[j]).group(0)
                        new = f"{indent}{replacement}"
                        if lines[j] != new:
                            lines[j] = new; changed = True; total += 1
                        break
            i += 1
        if changed:
            f.write_text("\n".join(lines) + "\n")
    if total: success(f"    replace_move_result({invoke_pattern!r}): {total} site(s)")
    else:     warn(   f"    replace_move_result: pattern not found")
    return total

def insert_before(smali_dir: Path, pattern: str, new_line: str) -> int:
    """Insert new_line (with matching indent) before every line containing pattern."""
    total = 0
    for f in smali_dir.rglob("*.smali"):
        lines = f.read_text(errors="replace").splitlines()
        changed = False
        i = 0
        while i < len(lines):
            if pattern in lines[i]:
                indent = re.match(r"\s*", lines[i]).group(0)
                candidate = f"{indent}{new_line}"
                if i == 0 or lines[i-1].strip() != new_line.strip():
                    lines.insert(i, candidate)
                    changed = True; total += 1
                    i += 2
                else:
                    i += 1
            else:
                i += 1
        if changed:
            f.write_text("\n".join(lines) + "\n")
    if total: success(f"    insert_before({pattern!r}): {total} insertion(s)")
    else:     warn(   f"    insert_before({pattern!r}): not found")
    return total

def strip_if_eqz_after(smali_dir: Path, after_pattern: str) -> int:
    """Remove the if-eqz guard that immediately follows after_pattern."""
    total = 0
    for f in smali_dir.rglob("*.smali"):
        lines = f.read_text(errors="replace").splitlines()
        changed = False
        for idx in range(len(lines)):
            if after_pattern in lines[idx]:
                for j in range(idx+1, min(idx+12, len(lines))):
                    if re.match(r'\s*if-eqz\s', lines[j]):
                        del lines[j]; changed = True; total += 1; break
        if changed:
            f.write_text("\n".join(lines) + "\n")
    if total: success(f"    strip_if_eqz_after({after_pattern!r}): {total} removal(s)")
    else:     warn(   f"    strip_if_eqz_after: pattern not found")
    return total

def sed_replace(smali_dir: Path, find_re: str, replace: str) -> int:
    """Regex replace across all smali files."""
    pat = re.compile(find_re)
    total = 0
    for f in smali_dir.rglob("*.smali"):
        text = f.read_text(errors="replace")
        new_text, n = pat.subn(replace, text)
        if n:
            f.write_text(new_text); total += n
    if total: success(f"    sed_replace({find_re!r}): {total} match(es)")
    else:     warn(   f"    sed_replace({find_re!r}): not found")
    return total

# ─────────────────────────────────────────────────────────────────
#  PATCH PROFILES
# ─────────────────────────────────────────────────────────────────

def _patch_framework_sig(smali_dir: Path) -> bool:
    """
    Mirror of patcher_a16.sh apply_framework_signature_patches.
    All 10 patches from the reference script.
    """
    n = 0
    # 1. PackageParser: force cert-check register
    n += insert_before(smali_dir,
        "ApkSignatureVerifier;->unsafeGetCertsWithoutVerification",
        "const/4 v1, 0x1")
    # 2. PackageParser$PackageParserException: zero error code
    n += insert_before(smali_dir,
        r"iput p1, p0, Landroid/content/pm/PackageParser$PackageParserException;->error:I",
        "const/4 p1, 0x0")
    # 3a-3c. SigningDetails capability checks → always true
    n += force_return(smali_dir, "checkCapability",        "1")
    n += force_return(smali_dir, "checkCapabilityRecover", "1")
    n += force_return(smali_dir, "hasAncestorOrSelf",      "1")
    # 4. V2 digest compare → true
    n += replace_move_result(smali_dir,
        "invoke-static {v8, v4}, Ljava/security/MessageDigest;->isEqual([B[B)Z",
        "const/4 v0, 0x1")
    # 5. V3 digest compare → true
    n += replace_move_result(smali_dir,
        "invoke-static {v9, v3}, Ljava/security/MessageDigest;->isEqual([B[B)Z",
        "const/4 v0, 0x1")
    # 6a. Minimum scheme version → 0 (V1 acceptable)
    n += force_return(smali_dir, "getMinimumSignatureSchemeVersionForTargetSdk", "0")
    # 6b. Force min scheme=0 before every V1 verify call
    n += insert_before(smali_dir,
        "ApkSignatureVerifier;->verifyV1Signature",
        "const p3, 0x0")
    # 7. ApkSigningBlockUtils digest compare → true
    n += replace_move_result(smali_dir,
        "invoke-static {v5, v6}, Ljava/security/MessageDigest;->isEqual([B[B)Z",
        "const/4 v7, 0x1")
    # 8. StrictJarVerifier: verifyMessageDigest → true
    n += force_return(smali_dir, "verifyMessageDigest", "1")
    # 9. StrictJarFile: remove null-entry guard after findEntry
    n += strip_if_eqz_after(smali_dir,
        "Landroid/util/jar/StrictJarFile;->findEntry(Ljava/lang/String;)Ljava/util/zip/ZipEntry;")
    # 10. ParsingPackageUtils: swallow sharedUserId error
    n += insert_before(smali_dir,
        "manifest> specifies bad sharedUserId name",
        "const/4 v4, 0x0")
    info(f"    Total patches applied: {n}/10+")
    return n > 0

def _patch_intl_build(smali_dir: Path) -> bool:
    """
    Shared patcher for IS_INTERNATIONAL_BUILD checks.
    Used by: Settings AI, SystemUI VoLTE, Provision GMS, miui-service.
    Covers both sget-boolean and getRegion() method call patterns.
    """
    n = 0
    # Pattern A: sget-boolean vX, Lmiui/os/Build;->IS_INTERNATIONAL_BUILD:Z
    # → const/4 vX, 0x1
    n += sed_replace(smali_dir,
        r'(\s*)sget-boolean (v\d+), Lmiui/os/Build;->IS_INTERNATIONAL_BUILD:Z',
        r'\1const/4 \2, 0x1')
    # Pattern B: invoke-static getRegion() → move-result-object vX → const/4 vX, 0x1
    n += replace_move_result(smali_dir,
        "Lmiui/os/Build;->getRegion()Ljava/lang/String;",
        "const/4 v0, 0x1")
    return n > 0

def _patch_settings_ai(smali_dir: Path) -> bool:
    """
    Settings.apk: InternalDeviceUtils.isAiSupported() and related → always true.
    Also handles all isAi*/AiSupport* variants across sub-versions of HyperOS 3.
    """
    n = 0
    for f in smali_dir.rglob("*.smali"):
        if "InternalDeviceUtils" not in f.name:
            continue
        lines = f.read_text(errors="replace").splitlines()
        changed = False
        i = 0
        while i < len(lines):
            s = lines[i].lstrip()
            if (s.startswith(".method") and ")V" not in s and (
                    "isAi" in s or "AiSupport" in s or
                    "aiSupport" in s or "SupportAi" in s or
                    "supportAi" in s)):
                j = i + 1
                while j < len(lines) and not lines[j].lstrip().startswith(".end method"):
                    j += 1
                stub = [lines[i], "    .registers 2",
                        "    const/4 v0, 0x1", "    return v0", ".end method"]
                lines[i:j+1] = stub
                changed = True; n += 1
                i += len(stub)
                success(f"    Patched AI method: {s.split()[-1] if s.split() else '?'}")
            else:
                i += 1
        if changed:
            f.write_text("\n".join(lines) + "\n")
    if n == 0:
        warn("    InternalDeviceUtils.smali not found in this DEX")
    return n > 0

# ─────────────────────────────────────────────────────────────────
#  COMMANDS
# ─────────────────────────────────────────────────────────────────
NEEDLE_FW  = ["ApkSignatureVerifier", "SigningDetails", "StrictJarVerifier",
              "StrictJarFile", "PackageParser", "ApkSigningBlock", "ParsingPackageUtils"]
NEEDLE_AI  = ["InternalDeviceUtils"]
NEEDLE_IB  = ["IS_INTERNATIONAL_BUILD", "miui/os/Build"]

def _run(cmd_label: str, archive_path: str, needles: list[str], patch_fn):
    archive = Path(archive_path)
    if not archive.exists():
        error(f"{archive.name} not found: {archive}"); sys.exit(1)
    sz = archive.stat().st_size // 1024
    info(f"Archive: {archive}")
    info(f"Size:    {sz}K")
    # backup
    bak = archive.with_suffix(archive.suffix + ".bak")
    if not bak.exists():
        shutil.copy2(archive, bak)
        success("✓ Backup created")
    n = patch_archive(archive, needles, patch_fn, cmd_label)
    if n > 0:
        success(f"✅ {cmd_label}: {n} DEX(es) patched")
        success(f"   Final size: {archive.stat().st_size//1024}K")
    else:
        error(f"✗ {cmd_label}: no patches applied — restoring backup")
        shutil.copy2(bak, archive)
        sys.exit(1)

COMMANDS = {
    "verify":         (cmd_verify,),
    "framework-sig":  (lambda p: _run("framework-sig",  p, NEEDLE_FW, _patch_framework_sig),),
    "settings-ai":    (lambda p: _run("settings-ai",    p, NEEDLE_AI, _patch_settings_ai),),
    "systemui-volte": (lambda p: _run("systemui-volte", p, NEEDLE_IB, _patch_intl_build),),
    "provision-gms":  (lambda p: _run("provision-gms",  p, NEEDLE_IB, _patch_intl_build),),
    "miui-service":   (lambda p: _run("miui-service",   p, NEEDLE_IB, _patch_intl_build),),
}

def main():
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        print(f"Usage: dex_patcher.py <{'|'.join(COMMANDS)}> [archive]")
        sys.exit(1)
    cmd = sys.argv[1]
    if cmd == "verify":
        cmd_verify()
    else:
        if len(sys.argv) < 3:
            error(f"Usage: dex_patcher.py {cmd} <archive>"); sys.exit(1)
        COMMANDS[cmd][0](sys.argv[2])

if __name__ == "__main__":
    main()
