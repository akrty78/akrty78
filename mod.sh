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

# ── framework.jar  ───────────────────────────────────────────────
def _fw_sig_patch(dex_name: str, dex: bytearray) -> bool:
    """
    Patch getMinimumSignatureSchemeVersionForTargetSdk → return 1 (const/4 v0, 0x1).

    MUST use trim=True:
      trim=False (default) leaves the original insns_size in the code_item header
      and NOP-pads the remainder, producing:
          const/4 v0, 0x1 ; return v0 ; nop ; nop ; ...
      trim=True shrinks insns_size to exactly 2 code-units (4 bytes), giving the
      clean output the verifier and baksmali both expect:
          const/4 v0, 0x1
          return v0
    """
    if b'ApkSignatureVerifier' not in bytes(dex): return False
    return binary_patch_method(dex,
        "android/util/apk/ApkSignatureVerifier",
        "getMinimumSignatureSchemeVersionForTargetSdk", 1, _STUB_TRUE,
        trim=True)

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
      opcode: 0x6E (invoke-virtual, format 35c, 3 code-units = 6 bytes)
      or:     0x74 (invoke-virtual/range, format 3rc, 3 code-units = 6 bytes)

    PATCH:
      Replace the 6 bytes of the invoke instruction with 0x00 0x00 0x00 0x00 0x00 0x00
      (3 × NOP code units). Method is void so no move-result follows.

    IDENTIFICATION:
      The method_id for ActivityTaskManagerInternal::showSystemReadyErrorDialogsIfNeeded
      is identified by matching BOTH the class type string AND the method name in the
      method_ids table — not just the name, which would also match implementations in
      PanningScalingHandler, ActivityTaskManagerService, etc.

    SAFETY:
      - Only 0x6E / 0x74 opcodes are touched (invoke-virtual / invoke-virtual/range).
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
    INVOKE_VIRTUAL       = 0x6E   # format 35c,  3 code-units (6 bytes)
    INVOKE_VIRTUAL_RANGE = 0x74   # format 3rc,  3 code-units (6 bytes)
    raw_w = bytearray(dex)
    count = 0

    for insns_off, insns_len, type_str, mname in _iter_code_items(raw, hdr):
        i = 0
        while i <= insns_len * 2 - 6:   # need 6 bytes ahead
            op = raw[insns_off + i]
            if op in (INVOKE_VIRTUAL, INVOKE_VIRTUAL_RANGE):
                mid_ref = struct.unpack_from('<H', raw, insns_off + i + 2)[0]
                if mid_ref == target_mid:
                    # NOP out the 6-byte invoke instruction
                    for b in range(6):
                        raw_w[insns_off + i + b] = 0x00
                    op_name = ('invoke-virtual' if op == 0x6E else 'invoke-virtual/range')
                    ok(f"  NOP'd {op_name} call in {type_str}::{mname} @ +{i}")
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

    Correct encoding:  const/4 v0, 0x1   →   bytes 12 10
      opcode 0x12, second byte = (value<<4)|reg = (1<<4)|0 = 0x10
    Wrong encoding from old _intl_build_patch (no use_const4):
      const/16 v0, 0x1  →  bytes 13 00 01 00  (opcode 0x13, not 0x15 which is const/high16)

    Constraints enforced:
      - class filter: 'Utils' must be in type_str (catches com/android/provision/Utils)
      - method filter: exact name 'setGmsAppEnabledStateForCn'
      - first-occurrence only: count is tracked; abort if 0 matches
      - use_const4=True: guarantees opcode 0x12 output (const/4)
    """
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

    # Pass 1b — Gboard swap in InputMethodManagerStubImpl (binary, no-op if string absent)
    #   binary_swap_string requires "com.google.android.inputmethod.latin" in DEX pool.
    #   If pool doesn't have it, apktool D8b smali sed handles it as fallback.
    if _BAIDU_IME.encode() in raw:
        n = binary_swap_string(dex, _BAIDU_IME, _GBOARD_IME,
                               only_class='InputMethodManagerStubImpl')
        if n > 0:
            patched = True
            raw = bytes(dex)

    # Pass 2 — showSystemReadyErrorDialogsIfNeeded in ActivityTaskManagerInternal
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
    "provision-gms":     _provision_gms_patch,    # Utils::setGmsAppEnabledStateForCn only
    "miui-service":      _miui_service_patch,    # global IS_INTERNATIONAL_BUILD sweep
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
