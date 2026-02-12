#!/usr/bin/env python3
"""
mt_dex_patch.py  —  MT Manager style binary DEX patcher
========================================================

Workflow (identical to MT Manager DEX editor):
  1. Scan APK → find which classes*.dex contains the target class
  2. Extract ONLY that DEX (zip.read)
  3. Parse DEX binary → locate method's code_item
  4. Overwrite method body with new bytecodes (NOP-pad to original length)
  5. Fix DEX checksum + SHA1 in header
  6. zip -u → put ONLY that DEX back in the APK

Nothing else is touched: manifest, resources, other DEX files, signature — all untouched.

Usage:
  python3 mt_dex_patch.py patch-method \\
      --apk    Settings.apk \\
      --class  com/android/settings/InternalDeviceUtils \\
      --method isAiSupported \\
      --bytes  "12 10 0F 00"

  python3 mt_dex_patch.py patch-pattern \\
      --apk     MiuiSystemUI.apk \\
      --find    "Lmiui/os/Build;->getRegion()Ljava/lang/String;" \\
      --replace-move-result-with-true

Common --bytes values:
  return true  (boolean):   "12 10 0F 00"
  return false (boolean):   "12 00 0F 00"
  return 1     (int):       "12 10 0F 00"
  return 0     (int):       "12 00 0F 00"
  return-void:              "0E 00"
"""

import argparse, hashlib, os, re, shutil, struct, subprocess, sys, tempfile, zlib, zipfile

# ─────────────────────────────────────────────────────────────────────────────
# DEX header offsets  (all values little-endian)
# ─────────────────────────────────────────────────────────────────────────────
HDR_CHECKSUM        = 8    # u32  Adler32 of data[12:]
HDR_SHA1            = 12   # 20 bytes  SHA1 of data[32:]
HDR_FILE_SIZE       = 32   # u32
HDR_STRING_IDS_SIZE = 56   # u32
HDR_STRING_IDS_OFF  = 60   # u32
HDR_TYPE_IDS_SIZE   = 64   # u32
HDR_TYPE_IDS_OFF    = 68   # u32
HDR_PROTO_IDS_SIZE  = 72
HDR_PROTO_IDS_OFF   = 76
HDR_FIELD_IDS_SIZE  = 80
HDR_FIELD_IDS_OFF   = 84
HDR_METHOD_IDS_SIZE = 88   # u32
HDR_METHOD_IDS_OFF  = 92   # u32
HDR_CLASS_DEFS_SIZE = 96   # u32
HDR_CLASS_DEFS_OFF  = 100  # u32

# ─────────────────────────────────────────────────────────────────────────────
# Low-level helpers
# ─────────────────────────────────────────────────────────────────────────────

def u8(d, o):  return d[o]
def u16(d, o): return struct.unpack_from('<H', d, o)[0]
def u32(d, o): return struct.unpack_from('<I', d, o)[0]

def read_uleb128(d, o):
    v = s = 0
    while True:
        b = d[o]; o += 1
        v |= (b & 0x7F) << s; s += 7
        if not (b & 0x80): return v, o

def dex_string(d, idx):
    off  = u32(d, HDR_STRING_IDS_OFF) + idx * 4
    soff = u32(d, off)
    _len, data_off = read_uleb128(d, soff)
    end = data_off
    while d[end]: end += 1
    return d[data_off:end].decode('utf-8', errors='replace')

def dex_type(d, idx):
    si = u32(d, u32(d, HDR_TYPE_IDS_OFF) + idx * 4)
    return dex_string(d, si)

def dex_method_name(d, method_idx):
    mo = u32(d, HDR_METHOD_IDS_OFF) + method_idx * 8
    # method_id_item: class_idx(2) proto_idx(2) name_idx(4)
    name_si = u32(d, mo + 4)
    return dex_string(d, name_si)

def dex_method_class(d, method_idx):
    mo = u32(d, HDR_METHOD_IDS_OFF) + method_idx * 8
    return dex_type(d, u16(d, mo))

def dex_class_count(d):
    return u32(d, HDR_CLASS_DEFS_SIZE)

# ─────────────────────────────────────────────────────────────────────────────
# Find method → code_item offset
# ─────────────────────────────────────────────────────────────────────────────

def find_class_data_off(d, descriptor):
    """Return class_data_off for the given class descriptor, or None."""
    n    = u32(d, HDR_CLASS_DEFS_SIZE)
    base = u32(d, HDR_CLASS_DEFS_OFF)
    for i in range(n):
        cdef = base + i * 32
        if dex_type(d, u32(d, cdef)) == descriptor:
            return u32(d, cdef + 24)   # class_data_off
    return None

def find_method_code_off(d, class_descriptor, method_name):
    """
    Return (code_off, orig_insns_size) for the named method in the class.
    Returns (None, None) if not found.
    """
    cd_off = find_class_data_off(d, class_descriptor)
    if not cd_off:
        return None, None

    off = cd_off
    sf,  off = read_uleb128(d, off)   # static_fields_size
    inf, off = read_uleb128(d, off)   # instance_fields_size
    dm,  off = read_uleb128(d, off)   # direct_methods_size
    vm,  off = read_uleb128(d, off)   # virtual_methods_size

    # skip encoded_fields
    for _ in range(sf + inf):
        _, off = read_uleb128(d, off)  # field_idx_diff
        _, off = read_uleb128(d, off)  # access_flags

    midx = 0
    for _ in range(dm + vm):
        diff, off = read_uleb128(d, off);  midx += diff
        _,    off = read_uleb128(d, off)   # access_flags
        code_off, off = read_uleb128(d, off)

        if dex_method_name(d, midx) == method_name and code_off != 0:
            insns_size = u32(d, code_off + 12)   # 16-bit code units
            return code_off, insns_size

    return None, None

# ─────────────────────────────────────────────────────────────────────────────
# Find method_idx by class+name (for invoke-static pattern search)
# ─────────────────────────────────────────────────────────────────────────────

def find_method_idx(d, class_descriptor, method_name):
    """Return method_idx int for the given method, or None."""
    mi_size = u32(d, HDR_METHOD_IDS_SIZE)
    mi_off  = u32(d, HDR_METHOD_IDS_OFF)
    for i in range(mi_size):
        mo = mi_off + i * 8
        if (dex_type(d, u16(d, mo)) == class_descriptor and
                dex_method_name(d, i) == method_name):
            return i
    return None

# ─────────────────────────────────────────────────────────────────────────────
# Binary patch operations
# ─────────────────────────────────────────────────────────────────────────────

def nop_inject(dex_bytes, code_off, new_insn_bytes):
    """
    Overwrite the method's instruction array with new_insn_bytes, NOP-padding
    the remainder. Does NOT change insns_size → file layout is identical.
    Also safely updates registers_size.
    Returns new dex bytearray.
    """
    d = bytearray(dex_bytes)
    orig_insns_size = u32(d, code_off + 12)   # 16-bit units
    orig_byte_len   = orig_insns_size * 2

    if len(new_insn_bytes) > orig_byte_len:
        raise ValueError(
            f"New bytecode ({len(new_insn_bytes)}B) > original "
            f"({orig_byte_len}B). Method body too small."
        )

    # registers_size: keep at least max(2, ins_size) so v0 is always valid
    ins_size = u16(d, code_off + 2)
    new_regs = max(2, ins_size)
    struct.pack_into('<H', d, code_off, new_regs)

    # Write new bytes, NOP-pad (0x00 0x00) the rest
    payload = bytearray(orig_byte_len)
    payload[:len(new_insn_bytes)] = new_insn_bytes
    d[code_off + 16 : code_off + 16 + orig_byte_len] = payload

    return bytes(d)


def patch_invoke_static_result(dex_bytes, method_idx, true_value=True):
    """
    Find every:
        invoke-static {}, <method_idx>
        move-result-object vX   (or move-result vX)
    and replace the move-result* with:
        const/4 vX, #1          (or #0 if true_value=False)
    Returns (new_dex_bytes, patch_count).
    """
    lo = method_idx & 0xFF
    hi = (method_idx >> 8) & 0xFF

    # invoke-static {}, method  — format 35c, 0 args: 71 00 LO HI 00 00
    invoke_bytes = bytes([0x71, 0x00, lo, hi, 0x00, 0x00])

    d = bytearray(dex_bytes)
    patches = 0
    start = 0

    while True:
        pos = bytes(d).find(invoke_bytes, start)
        if pos == -1:
            break
        start = pos + 1
        next_pos = pos + 6

        if next_pos + 1 >= len(d):
            continue

        opcode = d[next_pos]
        reg    = d[next_pos + 1]

        # 0x0C = move-result-object, 0x0A = move-result
        if opcode in (0x0A, 0x0C) and reg <= 15:
            literal = 0x1 if true_value else 0x0
            # const/4 format 11n: opcode=0x12, BA where A=dst_reg, B=literal
            d[next_pos]     = 0x12
            d[next_pos + 1] = ((literal & 0xF) << 4) | (reg & 0xF)
            patches += 1
            log('SUCCESS', f"  Patched 0x{next_pos:08X}: const/4 v{reg}, #{literal}")
        elif opcode in (0x0A, 0x0C) and reg > 15:
            log('WARNING', f"  Register v{reg} > 15 at 0x{next_pos:08X} — skipping")

    return bytes(d), patches

# ─────────────────────────────────────────────────────────────────────────────
# DEX checksum + SHA1 repair
# ─────────────────────────────────────────────────────────────────────────────

def fix_dex_checksums(dex_bytes):
    d = bytearray(dex_bytes)
    # SHA1 covers data from byte 32 (file_size field) to end
    sha1 = hashlib.sha1(bytes(d[32:])).digest()
    d[HDR_SHA1 : HDR_SHA1 + 20] = sha1
    # Adler32 covers data from byte 12 (sha1 field) to end
    cksum = zlib.adler32(bytes(d[12:])) & 0xFFFFFFFF
    struct.pack_into('<I', d, HDR_CHECKSUM, cksum)
    return bytes(d)

# ─────────────────────────────────────────────────────────────────────────────
# APK helpers
# ─────────────────────────────────────────────────────────────────────────────

def list_dex_in_apk(apk_path):
    with zipfile.ZipFile(apk_path, 'r') as zf:
        return sorted(
            [n for n in zf.namelist() if re.match(r'^classes\d*\.dex$', n)],
            key=lambda x: (len(x), x)
        )

def read_dex_from_apk(apk_path, dex_name):
    with zipfile.ZipFile(apk_path, 'r') as zf:
        return zf.read(dex_name)

def find_dex_with_class(apk_path, class_name):
    """Return the dex_name that contains the class, or None."""
    descriptor = ('L' + class_name + ';').encode()
    for dex_name in list_dex_in_apk(apk_path):
        raw = read_dex_from_apk(apk_path, dex_name)
        if descriptor in raw:
            return dex_name
    return None

def inject_dex_into_apk(apk_path, dex_name, dex_bytes):
    """Write dex_bytes to a temp file then zip -u it into the APK."""
    work = tempfile.mkdtemp(prefix='mt_dex_')
    try:
        tmp = os.path.join(work, dex_name)
        with open(tmp, 'wb') as f:
            f.write(dex_bytes)
        rc = subprocess.run(
            f'zip -u "{apk_path}" "{dex_name}"',
            shell=True, cwd=work,
            capture_output=True, text=True
        )
        # rc=0 → updated, rc=12 → nothing changed (already same), both fine
        if rc.returncode not in (0, 12):
            raise RuntimeError(f"zip -u failed (rc={rc.returncode}): {rc.stderr}")
    finally:
        shutil.rmtree(work, ignore_errors=True)

# ─────────────────────────────────────────────────────────────────────────────
# Logging
# ─────────────────────────────────────────────────────────────────────────────

def log(level, msg):
    tags = {
        'INFO':    '[INFO]',
        'SUCCESS': '[SUCCESS]',
        'ERROR':   '[ERROR]',
        'WARNING': '[WARNING]',
        'ACTION':  '[ACTION]',
    }
    print(f"{tags.get(level,'[INFO]')} {msg}", flush=True)

# ─────────────────────────────────────────────────────────────────────────────
# Command: patch-method
#   Find a method by class+name and overwrite its body with new bytecodes.
# ─────────────────────────────────────────────────────────────────────────────

def cmd_patch_method(args):
    apk        = args.apk
    class_name = args.cls            # e.g.  com/android/settings/InternalDeviceUtils
    method     = args.method         # e.g.  isAiSupported
    new_bytes  = bytes.fromhex(args.bytes.replace(' ', ''))
    descriptor = 'L' + class_name + ';'

    log('ACTION', f"APK:     {apk}")
    log('ACTION', f"Class:   {class_name}")
    log('ACTION', f"Method:  {method}")
    log('ACTION', f"Bytes:   {' '.join(f'{b:02X}' for b in new_bytes)}")
    log('INFO', '')

    # 1. Find DEX
    log('INFO', f"Scanning APK for class...")
    dex_list = list_dex_in_apk(apk)
    log('INFO', f"DEX files in APK: {', '.join(dex_list)}")

    dex_name = find_dex_with_class(apk, class_name)
    if not dex_name:
        log('ERROR', f"Class not found in any DEX: {class_name}")
        return False
    log('SUCCESS', f"Found in: {dex_name}")

    # 2. Read DEX
    dex = read_dex_from_apk(apk, dex_name)
    orig_class_count = dex_class_count(dex)
    orig_size        = len(dex)
    log('INFO', f"DEX: {dex_name}  {orig_class_count} classes  {orig_size:,} bytes")

    # 3. Find method
    code_off, orig_insns_size = find_method_code_off(dex, descriptor, method)
    if code_off is None:
        log('ERROR', f"Method not found: {descriptor}->{method}")
        # List available methods to help debug
        cd_off = find_class_data_off(dex, descriptor)
        if cd_off:
            log('INFO', "Methods in this class:")
            off = cd_off
            sf, off = read_uleb128(dex, off)
            inf, off = read_uleb128(dex, off)
            dm, off = read_uleb128(dex, off)
            vm, off = read_uleb128(dex, off)
            for _ in range(sf + inf):
                _, off = read_uleb128(dex, off)
                _, off = read_uleb128(dex, off)
            midx = 0
            for _ in range(dm + vm):
                d2, off = read_uleb128(dex, off); midx += d2
                _, off  = read_uleb128(dex, off)
                _, off  = read_uleb128(dex, off)
                log('INFO', f"  → {dex_method_name(dex, midx)}")
        return False

    log('SUCCESS', f"Method found:  code_off=0x{code_off:08X}  insns={orig_insns_size} units ({orig_insns_size*2}B)")

    new_units = (len(new_bytes) + 1) // 2
    if len(new_bytes) > orig_insns_size * 2:
        log('ERROR', f"New code ({len(new_bytes)}B) > original ({orig_insns_size*2}B). Cannot NOP-pad.")
        return False
    log('INFO', f"Injection:  {new_units} active units + {orig_insns_size - new_units} NOP units")

    # 4. Patch
    log('ACTION', "Patching method body...")
    patched_dex = nop_inject(dex, code_off, new_bytes)

    # 5. Fix checksums
    log('ACTION', "Fixing DEX checksums (SHA1 + Adler32)...")
    patched_dex = fix_dex_checksums(patched_dex)

    # 6. Verify — class count and size must be identical
    if len(patched_dex) != orig_size:
        log('ERROR', f"DEX size changed: {orig_size} → {len(patched_dex)}.  BUG!")
        return False
    if dex_class_count(patched_dex) != orig_class_count:
        log('ERROR', f"Class count changed!  BUG!")
        return False
    log('SUCCESS', f"Integrity: {orig_class_count} classes, {orig_size:,} bytes — IDENTICAL")

    # 7. zip -u
    log('ACTION', f"Injecting {dex_name} back with zip -u (manifest untouched)...")
    inject_dex_into_apk(apk, dex_name, patched_dex)
    log('SUCCESS', f"Done!  APK: {os.path.getsize(apk)/1024/1024:.1f}M")
    return True

# ─────────────────────────────────────────────────────────────────────────────
# Command: patch-pattern
#   Find all invoke-static <target_method> + move-result* patterns
#   and replace the move-result* with const/4 vX, #1
# ─────────────────────────────────────────────────────────────────────────────

def cmd_patch_pattern(args):
    apk         = args.apk
    # --find accepts "Lmiui/os/Build;->getRegion()Ljava/lang/String;"
    find_str    = args.find
    true_value  = not getattr(args, 'false_value', False)

    # Parse "Lclass;->method()sig" into class descriptor + method name
    m = re.match(r'^(L[^;]+;)->(\w+)\(', find_str)
    if not m:
        log('ERROR', f"Cannot parse --find value: {find_str}")
        return False
    class_desc  = m.group(1)                        # e.g. Lmiui/os/Build;
    method_name = m.group(2)                        # e.g. getRegion

    log('ACTION', f"APK:     {apk}")
    log('ACTION', f"Target:  {class_desc}->{method_name}()")
    log('ACTION', f"Pattern: invoke-static + move-result → const/4 v?, #{1 if true_value else 0}")
    log('INFO', '')

    dex_list = list_dex_in_apk(apk)
    log('INFO', f"DEX files: {', '.join(dex_list)}")

    total_patches = 0
    patched_dexes = {}

    for dex_name in dex_list:
        dex = read_dex_from_apk(apk, dex_name)
        orig_count = dex_class_count(dex)
        orig_size  = len(dex)

        # Fast check: does this DEX even reference the class?
        if class_desc.encode() not in dex:
            log('INFO', f"{dex_name}: class not referenced, skipping")
            continue

        # Find method_idx
        mid = find_method_idx(dex, class_desc, method_name)
        if mid is None:
            log('INFO', f"{dex_name}: method not in method table, skipping")
            continue

        log('ACTION', f"{dex_name}: method_idx=0x{mid:04X}, scanning for invoke-static pattern...")
        patched, count = patch_invoke_static_result(dex, mid, true_value)

        if count == 0:
            log('INFO', f"{dex_name}: no invoke-static patterns found")
            continue

        patched = fix_dex_checksums(patched)

        # Safety checks
        if len(patched) != orig_size:
            log('ERROR', f"{dex_name}: size changed! Skipping.")
            continue
        if dex_class_count(patched) != orig_count:
            log('ERROR', f"{dex_name}: class count changed! Skipping.")
            continue

        log('SUCCESS', f"{dex_name}: {count} site(s) patched, integrity OK")
        patched_dexes[dex_name] = patched
        total_patches += count

    if not patched_dexes:
        log('WARNING', "Pattern not found in any DEX — nothing patched")
        log('INFO', "(This is OK if this ROM version doesn't need this patch)")
        return True

    # Inject all patched DEX files
    for dex_name, data in patched_dexes.items():
        log('ACTION', f"Injecting {dex_name} with zip -u (manifest untouched)...")
        inject_dex_into_apk(apk, dex_name, data)
        log('SUCCESS', f"✓ {dex_name} injected")

    log('SUCCESS', f"Total: {total_patches} pattern(s) patched across {len(patched_dexes)} DEX file(s)")
    log('SUCCESS', f"APK final size: {os.path.getsize(apk)/1024/1024:.1f}M")
    return True

# ─────────────────────────────────────────────────────────────────────────────
# Command: patch-field
#   Find all  sget-boolean vX, <class>;-><field>:Z
#   and replace with  const/4 vX, #1  +  nop
#   (sget-boolean is 4 bytes; const/4 is 2 bytes → pad with nop 2 bytes)
# ─────────────────────────────────────────────────────────────────────────────

def find_field_idx(d, class_descriptor, field_name):
    """Return field_idx for class.field or None."""
    fi_size = u32(d, HDR_FIELD_IDS_SIZE)
    fi_off  = u32(d, HDR_FIELD_IDS_OFF)
    for i in range(fi_size):
        fo = fi_off + i * 8
        # field_id_item: class_idx(u16) type_idx(u16) name_idx(u32)
        if (dex_type(d, u16(d, fo)) == class_descriptor and
                dex_string(d, u32(d, fo + 4)) == field_name):
            return i
    return None

def patch_sget_boolean_field(dex_bytes, field_idx, true_value=True):
    """
    Find all  sget-boolean vX, field_idx  and replace with
    const/4 vX, #(1|0)  +  nop  (same 4 bytes, different content).
    Returns (new_dex_bytes, patch_count).
    """
    lo = field_idx & 0xFF
    hi = (field_idx >> 8) & 0xFF
    literal = 0x1 if true_value else 0x0

    d = bytearray(dex_bytes)
    patches = 0
    pos = 0

    while pos < len(d) - 3:
        # sget-boolean: opcode=0x60, dst_reg, lo_field, hi_field
        if d[pos] == 0x60 and d[pos+2] == lo and d[pos+3] == hi:
            reg = d[pos + 1]
            if reg <= 15:
                # const/4 vX, #1  (2 bytes) + nop (2 bytes)
                d[pos]     = 0x12
                d[pos + 1] = ((literal & 0xF) << 4) | (reg & 0xF)
                d[pos + 2] = 0x00   # nop
                d[pos + 3] = 0x00   # nop
                patches += 1
                log('SUCCESS', f"  Patched sget-boolean at 0x{pos:08X}: const/4 v{reg}, #{literal}")
            else:
                log('WARNING', f"  v{reg} > 15 at 0x{pos:08X}, skipping")
        pos += 1

    return bytes(d), patches


def cmd_patch_field(args):
    apk         = args.apk
    find_str    = args.find   # e.g. "Lmiui/os/Build;->IS_INTERNATIONAL_BUILD:Z"
    true_value  = not getattr(args, 'false_value', False)

    # Parse "Lclass;->field:type"
    m = re.match(r'^(L[^;]+;)->(\w+):', find_str)
    if not m:
        log('ERROR', f"Cannot parse --find: {find_str}")
        return False
    class_desc = m.group(1)
    field_name = m.group(2)

    log('ACTION', f"APK:     {apk}")
    log('ACTION', f"Field:   {class_desc}->{field_name}")
    log('ACTION', f"Replace: sget-boolean → const/4 v?, #{1 if true_value else 0}")
    log('INFO', '')

    dex_list = list_dex_in_apk(apk)
    log('INFO', f"DEX files: {', '.join(dex_list)}")

    total_patches = 0
    patched_dexes = {}

    for dex_name in dex_list:
        dex = read_dex_from_apk(apk, dex_name)
        orig_count = dex_class_count(dex)
        orig_size  = len(dex)

        if class_desc.encode() not in dex:
            log('INFO', f"{dex_name}: class not referenced, skipping")
            continue

        fid = find_field_idx(dex, class_desc, field_name)
        if fid is None:
            log('INFO', f"{dex_name}: field not in field table, skipping")
            continue

        log('ACTION', f"{dex_name}: field_idx=0x{fid:04X}, scanning sget-boolean...")
        patched, count = patch_sget_boolean_field(dex, fid, true_value)

        if count == 0:
            log('INFO', f"{dex_name}: no sget-boolean patterns found")
            continue

        patched = fix_dex_checksums(patched)

        if len(patched) != orig_size or dex_class_count(patched) != orig_count:
            log('ERROR', f"{dex_name}: integrity check failed! Skipping.")
            continue

        log('SUCCESS', f"{dex_name}: {count} sget-boolean(s) patched, integrity OK")
        patched_dexes[dex_name] = patched
        total_patches += count

    if not patched_dexes:
        log('WARNING', "Field pattern not found in any DEX — nothing patched")
        return True

    for dex_name, data in patched_dexes.items():
        log('ACTION', f"Injecting {dex_name} with zip -u (manifest untouched)...")
        inject_dex_into_apk(apk, dex_name, data)
        log('SUCCESS', f"✓ {dex_name} injected")

    log('SUCCESS', f"Total: {total_patches} sget-boolean(s) patched across {len(patched_dexes)} DEX(s)")
    log('SUCCESS', f"APK size: {os.path.getsize(apk)/1024/1024:.1f}M")
    return True


# ─────────────────────────────────────────────────────────────────────────────
# Command: list-methods   (debug helper)
# ─────────────────────────────────────────────────────────────────────────────

def cmd_list_methods(args):
    """Print all methods for a class — useful for finding correct method name."""
    apk        = args.apk
    class_name = args.cls
    descriptor = 'L' + class_name + ';'

    dex_name = find_dex_with_class(apk, class_name)
    if not dex_name:
        log('ERROR', f"Class not found: {class_name}"); return False

    dex    = read_dex_from_apk(apk, dex_name)
    cd_off = find_class_data_off(dex, descriptor)
    if not cd_off:
        log('ERROR', f"No class_data for {descriptor}"); return False

    log('INFO', f"Class:   {descriptor}")
    log('INFO', f"DEX:     {dex_name}")
    log('INFO', "Methods:")

    off = cd_off
    sf,  off = read_uleb128(dex, off)
    inf, off = read_uleb128(dex, off)
    dm,  off = read_uleb128(dex, off)
    vm,  off = read_uleb128(dex, off)
    for _ in range(sf + inf):
        _, off = read_uleb128(dex, off)
        _, off = read_uleb128(dex, off)

    midx = 0
    for _ in range(dm + vm):
        d2,      off = read_uleb128(dex, off); midx += d2
        flags,   off = read_uleb128(dex, off)
        code_off,off = read_uleb128(dex, off)
        name = dex_method_name(dex, midx)
        insns = u32(dex, code_off + 12) if code_off else 0
        log('INFO', f"  {name:60s}  code_off=0x{code_off:08X}  insns={insns} units")
    return True


# ─────────────────────────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────────────────────────

def main():
    p = argparse.ArgumentParser(description='MT Manager style DEX patcher')
    sub = p.add_subparsers(dest='cmd')

    pm = sub.add_parser('patch-method', help='Overwrite one method body with new bytecode')
    pm.add_argument('--apk',    required=True)
    pm.add_argument('--class',  required=True, dest='cls')
    pm.add_argument('--method', required=True)
    pm.add_argument('--bytes',  required=True, help='Hex bytecodes e.g. "12 10 0F 00"')

    pp = sub.add_parser('patch-pattern',
                        help='Replace invoke-static+move-result pattern (e.g. getRegion())')
    pp.add_argument('--apk',         required=True)
    pp.add_argument('--find',        required=True,
                    help='e.g. "Lmiui/os/Build;->getRegion()Ljava/lang/String;"')
    pp.add_argument('--false-value', action='store_true')

    pf = sub.add_parser('patch-field',
                        help='Replace sget-boolean field with const/4 (e.g. IS_INTERNATIONAL_BUILD)')
    pf.add_argument('--apk',         required=True)
    pf.add_argument('--find',        required=True,
                    help='e.g. "Lmiui/os/Build;->IS_INTERNATIONAL_BUILD:Z"')
    pf.add_argument('--false-value', action='store_true')

    lm = sub.add_parser('list-methods', help='Debug: list all methods in a class')
    lm.add_argument('--apk',   required=True)
    lm.add_argument('--class', required=True, dest='cls')

    args = p.parse_args()
    if not args.cmd:
        p.print_help(); sys.exit(1)
    if not os.path.exists(args.apk):
        log('ERROR', f"APK not found: {args.apk}"); sys.exit(1)

    dispatch = {
        'patch-method':  cmd_patch_method,
        'patch-pattern': cmd_patch_pattern,
        'patch-field':   cmd_patch_field,
        'list-methods':  cmd_list_methods,
    }
    ok = dispatch[args.cmd](args)
    sys.exit(0 if ok else 1)

if __name__ == '__main__':
    main()
