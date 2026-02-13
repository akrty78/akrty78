#!/usr/bin/env python3
"""
dex_patcher.py  ─  HyperOS ROM DEX patching engine  (production v6)
════════════════════════════════════════════════════════════════════
Strategy per target:

  framework.jar / Settings.apk / SystemUI.apk
  ────────────────────────────────────────────
  BINARY in-place DEX patch — zero round-trip, zero baksmali/smali.
  Directly rewrites the method's code_item in the raw DEX bytes.
  Recalculates Adler-32 checksum + SHA1 signature.
  Then zip -0 -u + zipalign.

  WHY NOT baksmali/smali:
    Recompiling 8000+ smali files produces a structurally different DEX
    (different string pool ordering, type list layout, method ID table).
    ART's dexopt rejects the recompiled DEX even though the logic is correct.
    User confirmed: stock classes3.dex works, recompiled classes3.dex crashes.

Commands:
  verify              check tools (zipalign, java)
  framework-sig       framework.jar: patch getMinimumSignatureSchemeVersionForTargetSdk → return 1
  settings-ai         Settings.apk:  patch isAiSupported → return true
  systemui-volte      MiuiSystemUI.apk: binary-patch all IS_INTERNATIONAL_BUILD sget-boolean → const/4 1
  provision-gms       Provision.apk: same IS_INTERNATIONAL_BUILD patch
  miui-service        miui-services.jar: same IS_INTERNATIONAL_BUILD patch
  voice-recorder-ai   SoundRecorder APK: patch AI/premium feature flags
"""

import sys, os, re, struct, hashlib, zlib, shutil, zipfile, subprocess, tempfile, traceback
from pathlib import Path

# ── Tool locations ────────────────────────────────────────────────
_BIN     = Path(os.environ.get("BIN_DIR", Path(__file__).parent))
API      = "35"

# ── Logger ────────────────────────────────────────────────────────
def _p(tag, msg): print(f"[{tag}] {msg}", flush=True)
def info(m):  _p("INFO",    m)
def ok(m):    _p("SUCCESS", m)
def warn(m):  _p("WARNING", m)
def err(m):   _p("ERROR",   m)


# ════════════════════════════════════════════════════════════════════
#  ZIPALIGN
# ════════════════════════════════════════════════════════════════════

def _find_zipalign():
    found = shutil.which("zipalign")
    if found: return found
    sdk = _BIN / "android-sdk"
    for p in sorted(sdk.glob("build-tools/*/zipalign"), reverse=True):
        if p.exists(): return str(p)
    return None


def _zipalign(archive: Path) -> bool:
    za = _find_zipalign()
    if not za:
        warn("  zipalign not found — alignment skipped"); return False
    tmp = archive.with_name(f"_za_{archive.name}")
    try:
        r = subprocess.run([za, "-p", "-f", "4", str(archive), str(tmp)],
                           capture_output=True, text=True, timeout=120)
        if r.returncode != 0 or not tmp.exists() or tmp.stat().st_size < 1000:
            err(f"  zipalign failed: {r.stderr[:200]}")
            tmp.unlink(missing_ok=True); return False
        shutil.move(str(tmp), str(archive))
        ok("  ✓ zipalign applied (resources.arsc 4-byte aligned)")
        return True
    except Exception as exc:
        err(f"  zipalign crash: {exc}"); tmp.unlink(missing_ok=True); return False


# ════════════════════════════════════════════════════════════════════
#  VERIFY
# ════════════════════════════════════════════════════════════════════

def cmd_verify():
    all_ok = True
    za = _find_zipalign()
    if za: ok(f"zipalign  at {za}")
    else:  warn("zipalign not found — APK alignment will be skipped")
    r = subprocess.run(["java", "-version"], capture_output=True, text=True)
    if r.returncode == 0: ok(f"java OK")
    else: err("java not found"); all_ok = False
    sys.exit(0 if all_ok else 1)


# ════════════════════════════════════════════════════════════════════
#  DEX BINARY PARSER + IN-PLACE PATCHER
#
#  Reads the DEX format directly:
#   header → string_ids → type_ids → class_defs → class_data_item →
#   encoded_method → code_item → instruction bytes
#
#  Patches the code_item in-place:
#   - registers_size  ← new_regs
#   - ins_size        ← kept (parameter count unchanged)
#   - outs_size       ← 0 (stub makes no calls)
#   - tries_size      ← 0 (no exception handlers)
#   - debug_info_off  ← 0 (strip line numbers; fine for system libs)
#   - insns[0..1]     ← stub (const/4 v0, val; return v0)
#   - insns[2..]      ← nop (00 00) padding to fill original size
#
#  Then recalculates Adler-32 checksum and SHA-1 signature.
# ════════════════════════════════════════════════════════════════════

def _uleb128_decode(data: bytes, off: int):
    """Decode unsigned LEB128. Returns (value, new_offset)."""
    result = shift = 0
    while True:
        b = data[off]; off += 1
        result |= (b & 0x7F) << shift
        if not (b & 0x80): break
        shift += 7
    return result, off


def _dex_get_string(data: bytes, string_ids_off: int, idx: int) -> str:
    """Return the string at string_ids[idx]."""
    str_data_off = struct.unpack_from('<I', data, string_ids_off + idx * 4)[0]
    _length, chars_off = _uleb128_decode(data, str_data_off)
    end = data.index(0, chars_off)
    return data[chars_off:end].decode('utf-8', errors='replace')


def _dex_find_class_data_off(data: bytes, class_defs_off: int, class_defs_size: int,
                              type_ids_off: int, string_ids_off: int,
                              target_type: str):
    """Find class_data_item offset for a given type descriptor like 'Lcom/foo/Bar;'."""
    for i in range(class_defs_size):
        base = class_defs_off + i * 32
        class_idx = struct.unpack_from('<I', data, base)[0]
        str_idx   = struct.unpack_from('<I', data, type_ids_off + class_idx * 4)[0]
        type_str  = _dex_get_string(data, string_ids_off, str_idx)
        if type_str == target_type:
            return struct.unpack_from('<I', data, base + 24)[0]  # class_data_off
    return None


def _dex_find_code_item_off(data: bytes, class_data_off: int,
                             method_ids_off: int, string_ids_off: int,
                             target_method: str):
    """
    Parse class_data_item to find code_item offset for target_method name.
    Returns (code_item_off, ins_size) or (None, None).
    """
    pos = class_data_off
    static_fields,   pos = _uleb128_decode(data, pos)
    instance_fields, pos = _uleb128_decode(data, pos)
    direct_methods,  pos = _uleb128_decode(data, pos)
    virtual_methods, pos = _uleb128_decode(data, pos)

    # Skip fields
    for _ in range(static_fields + instance_fields):
        _, pos = _uleb128_decode(data, pos)   # field_idx_diff
        _, pos = _uleb128_decode(data, pos)   # access_flags

    # Scan all methods (direct + virtual)
    method_idx = 0
    for _ in range(direct_methods + virtual_methods):
        idx_diff,   pos = _uleb128_decode(data, pos)
        method_idx += idx_diff
        _access,    pos = _uleb128_decode(data, pos)
        code_off,   pos = _uleb128_decode(data, pos)

        # method_id_item layout: class_idx(u16), proto_idx(u16), name_idx(u32)
        mid_base  = method_ids_off + method_idx * 8
        name_sidx = struct.unpack_from('<I', data, mid_base + 4)[0]
        mname     = _dex_get_string(data, string_ids_off, name_sidx)

        if mname == target_method and code_off != 0:
            ins_size = struct.unpack_from('<H', data, code_off + 2)[0]
            return code_off, ins_size

    return None, None


def binary_patch_method(dex: bytearray, class_desc: str, method_name: str,
                        stub_regs: int, stub_insns: bytes) -> bool:
    """
    In-place binary patch of a single method in a DEX bytearray.
    stub_insns: raw instruction bytes (must be <= original insns_size * 2 bytes)
    stub_regs:  new registers_size value for the code_item
    Returns True on success.
    """
    magic = bytes(dex[0:8])
    if not (magic.startswith(b'dex\n') or magic.startswith(b'dey\n')):
        err(f"  Not a DEX file (magic={magic!r})"); return False

    (string_ids_size, string_ids_off,
     type_ids_size,   type_ids_off,
     _proto_ids_size, _proto_ids_off,
     _field_ids_size, _field_ids_off,
     method_ids_size, method_ids_off,
     class_defs_size, class_defs_off) = struct.unpack_from('<IIIIIIIIIIII', dex, 0x38)

    # Build full type descriptor
    target_type = f'L{class_desc};'
    info(f"  Searching for {target_type} → {method_name}")

    # Find class
    class_data_off = _dex_find_class_data_off(
        bytes(dex), class_defs_off, class_defs_size,
        type_ids_off, string_ids_off, target_type)
    if class_data_off is None:
        warn(f"  Class {target_type} not in this DEX"); return False
    if class_data_off == 0:
        warn(f"  Class {target_type} has no class_data"); return False

    # Find method code_item
    code_off, ins_size = _dex_find_code_item_off(
        bytes(dex), class_data_off,
        method_ids_off, string_ids_off, method_name)
    if code_off is None:
        warn(f"  Method {method_name} not found in class_data"); return False

    # Read current code_item header
    (orig_regs, orig_ins, orig_outs, orig_tries,
     orig_debug, insns_size) = struct.unpack_from('<HHHHii', dex, code_off)
    # insns_size is uint (4 bytes), re-read correctly
    insns_size = struct.unpack_from('<I', dex, code_off + 12)[0]
    insns_off  = code_off + 16

    ok(f"  Found code_item @ 0x{code_off:X}: regs={orig_regs}, ins={orig_ins}, "
       f"insns={insns_size} code-units ({insns_size*2} bytes)")

    stub_units = len(stub_insns) // 2  # stub size in 16-bit code units
    if stub_units > insns_size:
        err(f"  Stub ({stub_units} cu) is larger than original ({insns_size} cu) — cannot patch in-place")
        return False

    # ── Patch code_item header ──────────────────────────────────
    # registers_size
    struct.pack_into('<H', dex, code_off + 0, stub_regs)
    # ins_size: keep original (parameter registers unchanged — method signature unchanged)
    # struct.pack_into('<H', dex, code_off + 2, orig_ins)  ← leave as-is
    # outs_size: 0 (stub makes no calls)
    struct.pack_into('<H', dex, code_off + 4, 0)
    # tries_size: 0 (no exception handlers)
    struct.pack_into('<H', dex, code_off + 6, 0)
    # debug_info_off: 0 (strip line numbers — fine for system library)
    struct.pack_into('<I', dex, code_off + 8, 0)
    # insns_size: keep original (we nop-pad to fill, keeps DEX layout intact)

    # ── Patch instruction bytes ──────────────────────────────────
    # Write stub instructions
    for i, b in enumerate(stub_insns):
        dex[insns_off + i] = b
    # NOP-pad the rest (00 00 per code unit)
    for i in range(len(stub_insns), insns_size * 2):
        dex[insns_off + i] = 0x00

    # ── Recalculate checksum and SHA1 ────────────────────────────
    _dex_fix_checksums(dex)

    ok(f"  ✓ {method_name} patched in-place "
       f"(regs {orig_regs}→{stub_regs}, insns={insns_size} cu kept, "
       f"stub={stub_units} cu + {insns_size - stub_units} nop padding)")
    return True


def _dex_fix_checksums(dex: bytearray) -> None:
    """Recalculate Adler-32 checksum (offset 8) and SHA1 signature (offset 12)."""
    # SHA1 = SHA1(dex[32:])
    sha1 = hashlib.sha1(bytes(dex[32:])).digest()
    dex[12:32] = sha1

    # Adler-32 = adler32(dex[12:])
    adler = zlib.adler32(bytes(dex[12:])) & 0xFFFFFFFF
    struct.pack_into('<I', dex, 8, adler)


# ════════════════════════════════════════════════════════════════════
#  IS_INTERNATIONAL_BUILD — binary sget-boolean → const/16 patch
#
#  Instead of baksmali/smali round-trip, scan raw DEX bytes for the
#  sget-boolean instruction targeting IS_INTERNATIONAL_BUILD and
#  replace with const/16 vAA, #+1.
#
#  sget-boolean: opcode 0x60, format 21c (4 bytes: 60 AA FF FF)
#                AA = destination register, FFFF = field index
#  const/16:     opcode 0x15, format 21s (4 bytes: 15 AA 01 00)
#                AA = register, 0x0001 = literal 1
#
#  Both instructions are exactly 2 code units (4 bytes) — perfect in-place swap.
#  We identify the IS_INTERNATIONAL_BUILD field index by scanning the string/field
#  tables for "IS_INTERNATIONAL_BUILD" in class Lmiui/os/Build;
# ════════════════════════════════════════════════════════════════════

def binary_patch_intl_build(dex: bytearray) -> int:
    """
    Scan DEX instruction stream for:
      sget-boolean vAA, Lmiui/os/Build;->IS_INTERNATIONAL_BUILD:Z  (opcode 0x60)
    Replace with:
      const/16 vAA, 0x1  (opcode 0x15)

    Returns count of replacements.
    """
    data = bytes(dex)
    magic = data[0:8]
    if not (magic.startswith(b'dex\n') or magic.startswith(b'dey\n')):
        return 0

    (string_ids_size, string_ids_off,
     type_ids_size,   type_ids_off,
     _proto_ids_size, _proto_ids_off,
     field_ids_size,  field_ids_off,
     method_ids_size, method_ids_off,
     class_defs_size, class_defs_off) = struct.unpack_from('<IIIIIIIIIIII', data, 0x38)

    # Build a quick string→index lookup for known strings
    def get_str(idx):
        off = struct.unpack_from('<I', data, string_ids_off + idx * 4)[0]
        _, co = _uleb128_decode(data, off)
        end = data.index(0, co)
        return data[co:end].decode('utf-8', errors='replace')

    def get_type_str(tidx):
        sidx = struct.unpack_from('<I', data, type_ids_off + tidx * 4)[0]
        return get_str(sidx)

    # Find the field_id for Lmiui/os/Build;->IS_INTERNATIONAL_BUILD:Z
    # field_id_item: class_idx(u16), type_idx(u16), name_idx(u32)
    # So struct is: 2 + 2 + 4 = 8 bytes
    target_field_indices = set()
    for fi in range(field_ids_size):
        fbase     = field_ids_off + fi * 8
        cls_idx   = struct.unpack_from('<H', data, fbase + 0)[0]
        name_idx  = struct.unpack_from('<I', data, fbase + 4)[0]
        cls_str   = get_type_str(cls_idx)
        fname     = get_str(name_idx)
        if cls_str == 'Lmiui/os/Build;' and fname == 'IS_INTERNATIONAL_BUILD':
            target_field_indices.add(fi)
            info(f"  Found field: {cls_str}->{fname} @ field_id[{fi}] = index 0x{fi:04X}")

    if not target_field_indices:
        warn("  IS_INTERNATIONAL_BUILD field not in this DEX"); return 0

    # Scan the entire DEX for sget-boolean (0x60) instructions referencing target fields
    # DEX instructions are 16-bit aligned. Scan data section.
    header_size = struct.unpack_from('<I', data, 0x24)[0]  # always 0x70
    data_off    = struct.unpack_from('<I', data, 0x68)[0]
    # Actually scan from after header to end of file
    # sget-boolean format: [60 AA] [lo hi]  (4 bytes, little-endian 16-bit units)
    # code unit 0: 0x??60 where low byte=opcode=0x60, high byte=register
    # code unit 1: field_idx as u16 (truncated — only low 16 bits of field index used)

    count = 0
    i = 0x70  # start after header
    raw = bytearray(dex)  # work on mutable copy (same as dex)
    while i < len(raw) - 3:
        if raw[i] == 0x60:  # sget-boolean opcode
            reg      = raw[i + 1]
            field_lo = struct.unpack_from('<H', raw, i + 2)[0]
            # field indices that fit in 16 bits; for >65535 fields we'd need a different check
            # but HyperOS framework never has that many fields
            if field_lo in target_field_indices:
                info(f"  Patching sget-boolean v{reg} @ offset 0x{i:X} → const/16")
                # Replace: 60 AA FF FF  →  15 AA 01 00
                raw[i]     = 0x15        # const/16 opcode
                raw[i + 1] = reg         # same destination register
                raw[i + 2] = 0x01        # literal low byte = 1
                raw[i + 3] = 0x00        # literal high byte = 0
                count += 1
            i += 4  # advance past this 4-byte instruction
        else:
            i += 2  # advance by one 16-bit code unit
    if count:
        # Update checksums after all replacements
        _dex_fix_checksums(raw)
        dex[:] = raw
        ok(f"  ✓ IS_INTERNATIONAL_BUILD: {count} sget-boolean → const/16 patched")
    else:
        warn("  IS_INTERNATIONAL_BUILD: no matching sget-boolean instructions found")
    return count


# ════════════════════════════════════════════════════════════════════
#  ARCHIVE PIPELINE
#  For each target DEX in the archive:
#    extract → patch bytearray in memory → zip -0 -u → zipalign
# ════════════════════════════════════════════════════════════════════

def list_dexes(archive: Path) -> list:
    with zipfile.ZipFile(archive) as z:
        names = [n for n in z.namelist() if re.match(r'^classes\d*\.dex$', n)]
    return sorted(names, key=lambda x: 0 if x == "classes.dex"
                                       else int(re.search(r'\d+', x).group()))


def _inject_dex(archive: Path, dex_name: str, dex_bytes: bytes) -> bool:
    """Write dex_bytes back into archive as STORE (uncompressed). Then zipalign."""
    work = Path(tempfile.mkdtemp(prefix="dp_inj_"))
    try:
        out_dex = work / dex_name
        out_dex.write_bytes(dex_bytes)
        r = subprocess.run(["zip", "-0", "-u", str(archive), dex_name],
                           cwd=str(work), capture_output=True, text=True)
        if r.returncode not in (0, 12):
            err(f"  zip failed (rc={r.returncode}): {r.stderr}"); return False
        return True
    except Exception as exc:
        err(f"  inject crash: {exc}"); return False
    finally:
        shutil.rmtree(work, ignore_errors=True)


def run_patches(archive: Path, patch_fn, label: str) -> int:
    """
    patch_fn(dex_name, dex_bytearray) → bool  (True = patched, mutates bytearray)
    Runs for every DEX in archive. Returns count of patched DEXes.
    """
    archive = archive.resolve()
    if not archive.exists():
        err(f"Not found: {archive}"); return 0

    info(f"Archive: {archive.name}  ({archive.stat().st_size // 1024}K)")
    bak = Path(str(archive) + ".bak")
    if not bak.exists():
        shutil.copy2(archive, bak); ok("✓ Backup created")

    is_apk = archive.suffix.lower() == '.apk'
    count   = 0
    aligned = False  # only zipalign once after all DEX injections

    for dex_name in list_dexes(archive):
        with zipfile.ZipFile(archive) as z:
            raw = bytearray(z.read(dex_name))
        info(f"→ {dex_name} ({len(raw) // 1024}K)")

        try:
            patched = patch_fn(dex_name, raw)
        except Exception as exc:
            err(f"  patch_fn crash: {exc}"); traceback.print_exc(); continue

        if not patched:
            continue

        if not _inject_dex(archive, dex_name, bytes(raw)):
            err(f"  Failed to inject {dex_name}"); continue

        count += 1
        aligned = False  # need realign after each injection

    if count > 0:
        if is_apk:
            _zipalign(archive)
        ok(f"✅ {label}: {count} DEX(es) patched  ({archive.stat().st_size // 1024}K)")
    else:
        err(f"✗ {label}: nothing patched — restoring backup")
        shutil.copy2(bak, archive)
    return count


# ════════════════════════════════════════════════════════════════════
#  PATCH PROFILES
# ════════════════════════════════════════════════════════════════════

# Stub: const/4 v0, 0x1 ; return v0  (2 code units = 4 bytes)
_STUB_TRUE  = bytes([0x12, 0x10, 0x0F, 0x00])   # returns boolean/int 1
_STUB_ZERO  = bytes([0x12, 0x00, 0x0F, 0x00])   # returns 0 (unused here)


def _fw_sig_patch(dex_name: str, dex: bytearray) -> bool:
    """
    framework.jar: ONLY patch getMinimumSignatureSchemeVersionForTargetSdk → return 1
    Class: android/util/apk/ApkSignatureVerifier
    """
    return binary_patch_method(
        dex,
        class_desc  = "android/util/apk/ApkSignatureVerifier",
        method_name = "getMinimumSignatureSchemeVersionForTargetSdk",
        stub_regs   = 1,
        stub_insns  = _STUB_TRUE)


def _settings_ai_patch(dex_name: str, dex: bytearray) -> bool:
    """
    Settings.apk: patch isAiSupported in com/android/settings/InternalDeviceUtils → return true
    Only processes the DEX that contains InternalDeviceUtils (classes3.dex typically).
    """
    # Quick binary string scan before attempting full DEX parse
    if b'InternalDeviceUtils' not in bytes(dex):
        return False
    return binary_patch_method(
        dex,
        class_desc  = "com/android/settings/InternalDeviceUtils",
        method_name = "isAiSupported",
        stub_regs   = 1,
        stub_insns  = _STUB_TRUE)


def _intl_build_patch(dex_name: str, dex: bytearray) -> bool:
    """
    Binary patch all IS_INTERNATIONAL_BUILD sget-boolean → const/16 1.
    Used for: SystemUI, Provision, miui-service.
    """
    if b'IS_INTERNATIONAL_BUILD' not in bytes(dex):
        return False
    count = binary_patch_intl_build(dex)
    return count > 0


def _voice_recorder_patch(dex_name: str, dex: bytearray) -> bool:
    """SoundRecorder: patch isAiSupported and IS_INTERNATIONAL_BUILD."""
    patched = False
    if b'isAiSupported' in bytes(dex):
        # Try common class paths for voice recorder AI
        for cls in ("com/miui/soundrecorder/utils/FeatureUtils",
                    "com/miui/soundrecorder/FeatureUtils",
                    "com/android/soundrecorder/utils/FeatureUtils"):
            if binary_patch_method(dex, cls, "isAiSupported", 1, _STUB_TRUE):
                patched = True; break
    if b'IS_INTERNATIONAL_BUILD' in bytes(dex):
        if binary_patch_intl_build(dex) > 0:
            patched = True
    return patched


# ════════════════════════════════════════════════════════════════════
#  ENTRY POINT
# ════════════════════════════════════════════════════════════════════

PROFILES = {
    "framework-sig":    _fw_sig_patch,
    "settings-ai":      _settings_ai_patch,
    "systemui-volte":   _intl_build_patch,
    "provision-gms":    _intl_build_patch,
    "miui-service":     _intl_build_patch,
    "voice-recorder-ai":_voice_recorder_patch,
}

def main():
    CMDS = sorted(PROFILES.keys()) + ["verify"]
    if len(sys.argv) < 2 or sys.argv[1] not in CMDS:
        print(f"Usage: dex_patcher.py <{'|'.join(CMDS)}> [archive]", file=sys.stderr)
        sys.exit(1)
    cmd = sys.argv[1]
    if cmd == "verify":
        cmd_verify(); return
    if len(sys.argv) < 3:
        err(f"Usage: dex_patcher.py {cmd} <archive>"); sys.exit(1)
    count = run_patches(Path(sys.argv[2]), PROFILES[cmd], cmd)
    sys.exit(0 if count > 0 else 1)

if __name__ == "__main__":
    main()
