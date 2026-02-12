#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
#  smali_tools.sh  —  Shared DEX-level patching engine
#
#  Workflow (same as MT Manager DEX editor internally):
#    1. unzip <target.dex> from APK/JAR
#    2. java -jar baksmali.jar d <target.dex> -o smali_out/
#    3. python3 patches the specific .smali files
#    4. java -jar smali.jar a smali_out/ -o <target.dex>
#    5. zip -0 -u <APK/JAR> <target.dex>     ← STORE, manifest untouched
#
#  Why this works where apktool/binary failed:
#    - apktool rebuilds the WHOLE APK including manifest → crash
#    - Binary parsing had 3 bugs (wrong DEX, midx, zip compression)
#    - This approach: only the target DEX changes, manifest never read
# ═══════════════════════════════════════════════════════════════════

# ─── Tool readiness check ─────────────────────────────────────────
# Downloads happen once at manager startup (section 3.5).
# This is just a fast guard used inside each patcher function.
_smali_ensure_tools() {
    # Use pre-computed flag if available (set by manager startup)
    if [ "${SMALI_TOOLS_OK:-0}" -eq 1 ]; then
        return 0
    fi
    # Fallback check (when tools sourced standalone / outside manager)
    local ok=1
    for jar in baksmali.jar smali.jar; do
        local sz; sz=$(stat -c%s "$BIN_DIR/$jar" 2>/dev/null || echo 0)
        if [ "$sz" -lt 500000 ]; then
            log_error "$jar not ready (${sz}B)"
            ok=0
        fi
    done
    if [ "$ok" -eq 1 ]; then
        # Verify with Java
        if java -jar "$BIN_DIR/baksmali.jar" --version &>/dev/null && \
           java -jar "$BIN_DIR/smali.jar"    --version &>/dev/null; then
            SMALI_TOOLS_OK=1
            return 0
        fi
    fi
    log_error "smali tools not available — skipping patch"
    return 1
}

# ─── Core DEX-level patcher ───────────────────────────────────────
#
# _smali_patch_dex <archive> <dex_name> <api_level> <patcher_func>
#
#   archive      : path to .apk or .jar
#   dex_name     : e.g. "classes2.dex"
#   api_level    : e.g. 35
#   patcher_func : name of a bash function that receives the smali_out dir
#                  and performs sed/python edits on the smali files
#
_smali_patch_dex() {
    local archive="$1"
    local dex_name="$2"
    local api="$3"
    local patcher_func="$4"

    local work
    work=$(mktemp -d /tmp/smali_work_XXXXXX)
    trap "rm -rf '$work'" RETURN

    log_info "── DEX: $dex_name ──"
    log_info "  Extracting from $(basename "$archive")..."

    # 1. Extract DEX
    unzip -p "$archive" "$dex_name" > "$work/$dex_name" 2>/dev/null
    if [ ! -s "$work/$dex_name" ]; then
        log_warning "  $dex_name not found in $(basename "$archive")"
        return 1
    fi
    local orig_size
    orig_size=$(stat -c%s "$work/$dex_name")
    log_info "  Size: $((orig_size / 1024))K"

    # 2. baksmali decompile
    log_info "  Decompiling (baksmali)..."
    if ! java -jar "$BIN_DIR/baksmali.jar" d \
            -a "$api" \
            "$work/$dex_name" \
            -o "$work/smali_out" 2>/dev/null; then
        log_error "  baksmali failed on $dex_name"
        return 1
    fi
    local nsmali
    nsmali=$(find "$work/smali_out" -name "*.smali" | wc -l)
    log_info "  Decompiled: $nsmali smali files"

    # 3. Apply patcher function
    log_info "  Applying patches..."
    if ! "$patcher_func" "$work/smali_out"; then
        log_warning "  Patcher reported no changes for $dex_name"
        return 1
    fi

    # 4. smali recompile
    log_info "  Recompiling (smali)..."
    if ! java -jar "$BIN_DIR/smali.jar" a \
            -a "$api" \
            "$work/smali_out" \
            -o "$work/${dex_name%.dex}_new.dex" 2>/dev/null; then
        log_error "  smali recompile failed on $dex_name"
        return 1
    fi
    local new_size
    new_size=$(stat -c%s "$work/${dex_name%.dex}_new.dex")
    log_info "  Recompiled: $((new_size / 1024))K"

    # 5. Inject back — STORE only (zip -0), manifest untouched
    log_info "  Injecting back with zip -0 -u (manifest untouched)..."
    cp "$work/${dex_name%.dex}_new.dex" "$work/$dex_name"
    (cd "$work" && zip -0 -u "$archive" "$dex_name") >/dev/null 2>&1
    local rc=$?
    if [ $rc -ne 0 ] && [ $rc -ne 12 ]; then
        log_error "  zip -0 -u failed (rc=$rc)"
        return 1
    fi

    log_success "  ✓ $dex_name patched and injected"
    return 0
}

# ─── Python smali helpers ─────────────────────────────────────────
#
# These mirror the force_methods_return_const / replace_move_result
# helpers from patcher_a16.sh exactly.
#

# smali_force_return  <smali_dir> <method_substring> <return_val>
#   Forces every non-void method containing the substring to
#   return const/4 v0, 0x<return_val>
smali_force_return() {
    local smali_dir="$1"
    local method_key="$2"
    local ret_val="$3"

    python3 - "$smali_dir" "$method_key" "$ret_val" <<'PY'
import sys, re
from pathlib import Path

smali_dir = Path(sys.argv[1])
method_key = sys.argv[2]
ret_val = sys.argv[3]
const_line = f"const/4 v0, 0x{ret_val}"

total_modified = 0
for path in smali_dir.rglob("*.smali"):
    lines = path.read_text(errors="replace").splitlines()
    changed = False
    i = 0
    while i < len(lines):
        stripped = lines[i].lstrip()
        if stripped.startswith(".method") and method_key in stripped:
            if ")V" in stripped:   # void return — skip
                i += 1; continue
            j = i + 1
            while j < len(lines) and not lines[j].lstrip().startswith(".end method"):
                j += 1
            body = lines[i:j+1]
            # Already stubbed?
            if (len(body) >= 4 and body[2].strip() == const_line
                    and body[3].strip().startswith("return")):
                i = j + 1; continue
            stub = [
                lines[i],
                "    .registers 8",
                f"    {const_line}",
                "    return v0",
                ".end method"
            ]
            lines[i:j+1] = stub
            changed = True
            total_modified += 1
            i = i + len(stub)
        else:
            i += 1
    if changed:
        path.write_text("\n".join(lines) + "\n")

print(f"smali_force_return({method_key!r}={ret_val}): {total_modified} method(s) modified")
sys.exit(0 if total_modified > 0 else 3)
PY
    local rc=$?
    if [ $rc -eq 3 ]; then
        log_warning "    smali_force_return: no methods matching '$method_key' found"
    elif [ $rc -eq 0 ]; then
        log_success "    ✓ force_return $method_key → 0x$ret_val"
    fi
}

# smali_force_return_void  <smali_dir> <method_substring>
smali_force_return_void() {
    local smali_dir="$1"
    local method_key="$2"

    python3 - "$smali_dir" "$method_key" <<'PY'
import sys
from pathlib import Path

smali_dir = Path(sys.argv[1])
method_key = sys.argv[2]
total = 0
for path in smali_dir.rglob("*.smali"):
    lines = path.read_text(errors="replace").splitlines()
    changed = False
    i = 0
    while i < len(lines):
        stripped = lines[i].lstrip()
        if stripped.startswith(".method") and method_key in stripped:
            if ")V" not in stripped:   # non-void — skip
                i += 1; continue
            j = i + 1
            while j < len(lines) and not lines[j].lstrip().startswith(".end method"):
                j += 1
            stub = [lines[i], "    .registers 1", "    return-void", ".end method"]
            if lines[i:j+1] == stub:
                i = j + 1; continue
            lines[i:j+1] = stub
            changed = True; total += 1
            i += len(stub)
        else:
            i += 1
    if changed:
        path.write_text("\n".join(lines) + "\n")

print(f"smali_force_return_void({method_key!r}): {total} method(s) stubbed")
sys.exit(0 if total > 0 else 3)
PY
    local rc=$?
    if [ $rc -eq 3 ]; then
        log_warning "    smali_force_return_void: no void methods matching '$method_key' found"
    elif [ $rc -eq 0 ]; then
        log_success "    ✓ force_return_void $method_key"
    fi
}

# smali_replace_move_result  <smali_dir> <invoke_pattern> <replacement>
#   Replaces move-result* after any line matching invoke_pattern
smali_replace_move_result() {
    local smali_dir="$1"
    local pattern="$2"
    local replacement="$3"

    python3 - "$smali_dir" "$pattern" "$replacement" <<'PY'
import sys, re
from pathlib import Path

smali_dir = Path(sys.argv[1])
pattern   = sys.argv[2]
replacement = sys.argv[3]
total = 0
for path in smali_dir.rglob("*.smali"):
    lines = path.read_text(errors="replace").splitlines()
    changed = False
    i = 0
    while i < len(lines):
        if pattern in lines[i]:
            for j in range(i+1, min(i+6, len(lines))):
                stripped = lines[j].strip()
                if stripped.startswith("move-result"):
                    indent = re.match(r"\s*", lines[j]).group(0)
                    new_line = f"{indent}{replacement}"
                    if lines[j] != new_line:
                        lines[j] = new_line
                        changed = True; total += 1
                    break
        i += 1
    if changed:
        path.write_text("\n".join(lines) + "\n")

print(f"smali_replace_move_result({pattern!r}): {total} site(s) replaced")
sys.exit(0 if total > 0 else 3)
PY
    local rc=$?
    if [ $rc -eq 3 ]; then
        log_warning "    smali_replace_move_result: pattern not found"
    elif [ $rc -eq 0 ]; then
        log_success "    ✓ replace_move_result after '$pattern'"
    fi
}

# smali_sed_all  <smali_dir> <find_pattern> <replace_pattern>
#   Run sed across all smali files
smali_sed_all() {
    local smali_dir="$1"
    local find_p="$2"
    local repl_p="$3"
    local count
    count=$(grep -rl "$find_p" "$smali_dir" --include="*.smali" 2>/dev/null | wc -l)
    if [ "$count" -gt 0 ]; then
        find "$smali_dir" -name "*.smali" -exec \
            sed -i "s|${find_p}|${repl_p}|g" {} +
        log_success "    ✓ sed_all: replaced in $count file(s)"
    else
        log_warning "    sed_all: pattern not found: $find_p"
    fi
}

# smali_insert_before  <smali_dir> <pattern> <new_line>
#   Inserts new_line (with matching indent) before every line containing pattern.
#   Mirrors patcher_a16.sh insert_line_before_all.
smali_insert_before() {
    local smali_dir="$1"
    local pattern="$2"
    local new_line="$3"

    python3 - "$smali_dir" "$pattern" "$new_line" <<'PY'
import sys, re
from pathlib import Path

smali_dir = Path(sys.argv[1])
pattern   = sys.argv[2]
new_line  = sys.argv[3]
total = 0

for path in smali_dir.rglob("*.smali"):
    lines = path.read_text(errors="replace").splitlines()
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
        path.write_text("\n".join(lines) + "\n")

print(f"smali_insert_before: {total} insertion(s) for pattern '{pattern}'")
sys.exit(0 if total > 0 else 3)
PY
    local rc=$?
    [ $rc -eq 3 ] && log_warning "    smali_insert_before: pattern '$pattern' not found" || \
                     log_success "    ✓ insert_before '$pattern'"
}

# smali_strip_if_eqz_after  <smali_dir> <after_pattern>
#   Removes the first if-eqz guard that follows a line matching after_pattern.
#   Used to bypass null checks and security gates.
smali_strip_if_eqz_after() {
    local smali_dir="$1"
    local after_pattern="$2"

    python3 - "$smali_dir" "$after_pattern" <<'PY'
import sys, re
from pathlib import Path

smali_dir = Path(sys.argv[1])
after_pat = sys.argv[2]
total = 0

for path in smali_dir.rglob("*.smali"):
    lines = path.read_text(errors="replace").splitlines()
    changed = False
    for idx, line in enumerate(lines):
        if after_pat in line:
            for j in range(idx+1, min(idx+12, len(lines))):
                if re.match(r'\s*if-eqz\s+v\d+', lines[j]):
                    del lines[j]
                    changed = True; total += 1
                    break
    if changed:
        path.write_text("\n".join(lines) + "\n")

print(f"smali_strip_if_eqz_after: {total} removal(s)")
sys.exit(0 if total > 0 else 3)
PY
    local rc=$?
    [ $rc -eq 3 ] && log_warning "    smali_strip_if_eqz_after: pattern not found" || \
                     log_success "    ✓ strip_if_eqz after '$after_pattern'"
}

# ─── Find which DEX in APK/JAR contains a class (by text in smali sense) ─────
_smali_find_dex_for_class() {
    local archive="$1"
    local class_slash="$2"   # e.g. android/util/apk/ApkSignatureVerifier
    # Binary scan each DEX for the class descriptor
    local descriptor
    descriptor="L${class_slash};"
    for dex in $(unzip -l "$archive" 2>/dev/null | grep -oP 'classes\d*\.dex' | sort -t x -k1,1 -k2,2n -u); do
        local tmp
        tmp=$(mktemp)
        unzip -p "$archive" "$dex" > "$tmp" 2>/dev/null
        if strings "$tmp" | grep -qF "$descriptor"; then
            rm -f "$tmp"
            echo "$dex"
            return
        fi
        rm -f "$tmp"
    done
}
