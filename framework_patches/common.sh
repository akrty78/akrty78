#!/usr/bin/env bash
# framework_patches/common.sh
# Shared helpers for all Framework Patcher scripts — sourced by each patch script.
# All Python helpers are verbatim ports from FrameworkPatcher/patcher_a16.sh (Android 16).

# ── Logging (reuse mod.sh helpers if available, fallback to echo) ─────
_fp_log()     { if declare -f log_info    &>/dev/null; then log_info    "$1"; else echo "[FP] $1"; fi; }
_fp_success() { if declare -f log_success &>/dev/null; then log_success "$1"; else echo "[FP] ✓ $1"; fi; }
_fp_warn()    { if declare -f log_warning &>/dev/null; then log_warning "$1"; else echo "[FP] ⚠ $1"; fi; }
_fp_err()     { if declare -f log_error   &>/dev/null; then log_error   "$1"; else echo "[FP] ✗ $1" >&2; fi; }
_fp_step()    { if declare -f log_step    &>/dev/null; then log_step    "$1"; else echo "[FP] $1"; fi; }

# ── Decompile a JAR using system apktool (same pattern as MiuiBooster) ─
# Usage: local dec_dir; dec_dir=$(fp_decompile "$JAR_PATH")
fp_decompile() {
    local jar="$1"
    local name; name="$(basename "$jar" .jar)"
    local work="${TEMP_DIR:-/tmp}/fp_${name}_work"
    rm -rf "$work" && mkdir -p "$work"
    cd "$work"
    _fp_log "Decompiling $name.jar with apktool..."
    if timeout 10m apktool d -r -f "$jar" -o "decompiled" 2>&1 | tee apktool_decompile.log | grep -q "I: Baksmaling\|I: Copying"; then
        _fp_success "Decompiled $name.jar"
        echo "$work/decompiled"   # return path via stdout
    else
        _fp_err "apktool decompile failed for $name.jar"
        cat apktool_decompile.log | tail -10 | while IFS= read -r line; do _fp_err "   $line"; done
        cd "${GITHUB_WORKSPACE}"
        return 1
    fi
}

# ── Recompile decompiled dir back into JAR & replace original ─────────
# Usage: fp_recompile "$JAR_PATH" "$DECOMPILED_DIR"
fp_recompile() {
    local jar="$1"
    local src_dir="$2"
    local name; name="$(basename "$jar" .jar)"
    local work; work="$(dirname "$src_dir")"
    cd "$work"
    _fp_log "Rebuilding $name.jar with apktool..."
    if timeout 10m apktool b -c "$src_dir" -o "${name}_patched.jar" 2>&1 | tee apktool_build.log | grep -q "Built\|I: Building"; then
        if [ -f "${name}_patched.jar" ]; then
            mv "${name}_patched.jar" "$jar"
            _fp_success "$name.jar patched and replaced"
        else
            _fp_err "Patched JAR not found after build for $name"
            cp "${jar}.bak" "$jar" 2>/dev/null || true
            cd "${GITHUB_WORKSPACE}"
            return 1
        fi
    else
        _fp_err "apktool build failed for $name.jar"
        cat apktool_build.log | tail -10 | while IFS= read -r line; do _fp_err "   $line"; done
        cp "${jar}.bak" "$jar" 2>/dev/null || true
        cd "${GITHUB_WORKSPACE}"
        return 1
    fi
    cd "${GITHUB_WORKSPACE}"
    return 0
}

# ── Cleanup a framework patch work dir ─────────────────────────────────
fp_cleanup() {
    local name="$1"
    rm -rf "${TEMP_DIR:-/tmp}/fp_${name}_work"
}


# ── Find smali file containing a method ────────────────────────────────
find_smali_method_file() {
    local decompile_dir="$1"
    local method="$2"
    find "$decompile_dir" -type f -name "*.smali" -print0 |
        xargs -0 grep -s -l -- ".method" 2>/dev/null |
        xargs -r -I{} sh -c "grep -s -q \"[[:space:]]*\\.method.*${method}\" \"{}\" && printf '%s\n' \"{}\"" |
        head -n1
}

# ── Python: force all overloads of a method to return a constant ───────
force_methods_return_const() {
    local file="$1"
    local method_substring="$2"
    local ret_val="$3"

    [ -z "$file" ] && { _fp_warn "force_methods_return_const: skipped empty file path for '${method_substring}'"; return 0; }
    [ ! -f "$file" ] && { _fp_warn "force_methods_return_const: file not found $file"; return 0; }

    python3 - "$file" "$method_substring" "$ret_val" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
method_key = sys.argv[2]
ret_val = sys.argv[3]

if not path.exists():
    sys.exit(4)

lines = path.read_text().splitlines()
found = 0
modified = 0
const_line = f"const/4 v0, 0x{ret_val}"

i = 0
while i < len(lines):
    stripped = lines[i].lstrip()
    if stripped.startswith('.method') and method_key in stripped:
        if ')V' in stripped:
            i += 1
            continue
        found += 1
        j = i + 1
        while j < len(lines) and not lines[j].lstrip().startswith('.end method'):
            j += 1
        if j >= len(lines):
            break
        body = lines[i:j+1]
        already = (
            len(body) >= 4
            and body[1].strip() == '.registers 8'
            and body[2].strip() == const_line
            and body[3].strip().startswith('return')
        )
        if already:
            i = j + 1
            continue
        stub = [
            lines[i],
            '    .registers 8',
            f'    {const_line}',
            '    return v0',
            '.end method'
        ]
        lines[i:j+1] = stub
        modified += 1
        i = i + len(stub)
    else:
        i += 1

if modified:
    path.write_text('\n'.join(lines) + '\n')

if found == 0:
    sys.exit(3)
PY

    local status=$?
    case "$status" in
        0) _fp_success "Set return 0x${ret_val} for '${method_substring}' in $(basename "$file")" ;;
        3) _fp_warn "No methods containing '${method_substring}' found in $(basename "$file")" ;;
        4) _fp_warn "File not found: $file" ;;
        *) _fp_err "Failed to rewrite '${method_substring}' in $file (status $status)"; return 1 ;;
    esac
    return 0
}

# ── Stub ALL overloads of a void method across all smali files ─────────
patch_return_void_methods_all() {
    local method_name="$1"
    local decompile_dir="$2"

    [ -z "$decompile_dir" ] && { _fp_err "patch_return_void_methods_all: missing decompile_dir"; return 1; }

    local files
    files=$(find "$decompile_dir" -type f -name "*.smali" -exec grep -s -l "^[[:space:]]*\\.method.*${method_name}" {} + 2>/dev/null || true)
    [ -z "$files" ] && { _fp_warn "No occurrences of ${method_name} found"; return 0; }

    local file
    for file in $files; do
        local starts
        starts=$(grep -n "^[[:space:]]*\\.method.*${method_name}" "$file" | cut -d: -f1 | sort -nr)
        [ -z "$starts" ] && continue

        local start end total_lines i line method_head method_head_escaped
        total_lines=$(wc -l <"$file")

        for start in $starts; do
            end=0; i="$start"
            while [ "$i" -le "$total_lines" ]; do
                line=$(sed -n "${i}p" "$file")
                [[ "$line" == *".end method"* ]] && { end=$i; break; }
                i=$((i + 1))
            done
            [ "$end" -eq 0 ] && continue

            method_head=$(sed -n "${start}p" "$file")
            method_head_escaped=$(printf "%s\n" "$method_head" | sed 's/\\/\\\\/g')

            sed -i "${start},${end}c\\
${method_head_escaped}\\
    .registers 8\\
    return-void\\
.end method" "$file"
        done
        _fp_success "Patched all ${method_name} overloads in $(basename "$file") to return-void"
    done
    return 0
}

# ── Replace entire method body with custom implementation ──────────────
replace_entire_method() {
    local method_signature="$1"
    local decompile_dir="$2"
    local new_method_body="$3"
    local specific_class="$4"
    local file

    if [ -n "$specific_class" ]; then
        file=$(find "$decompile_dir" -type f -path "*/${specific_class}.smali" | head -n 1)
        [ -z "$file" ] && { _fp_warn "Class file $specific_class.smali not found"; return 0; }
        grep -s -q "\.method.* ${method_signature}" "$file" 2>/dev/null || {
            _fp_warn "Method $method_signature not found in $specific_class"; return 0;
        }
    else
        file=$(find "$decompile_dir" -type f -name "*.smali" -exec grep -s -l "\.method.* ${method_signature}" {} + 2>/dev/null | head -n 1)
    fi

    [ -z "$file" ] && { _fp_warn "Method $method_signature not found"; return 0; }

    local start
    start=$(grep -n "^[[:space:]]*\.method.* ${method_signature}" "$file" | cut -d: -f1 | head -n1)
    [ -z "$start" ] && { _fp_warn "Method $method_signature start not found in $(basename "$file")"; return 0; }

    local total_lines end=0 i="$start" line
    total_lines=$(wc -l <"$file")
    while [ "$i" -le "$total_lines" ]; do
        line=$(sed -n "${i}p" "$file")
        [[ "$line" == *".end method"* ]] && { end="$i"; break; }
        i=$((i + 1))
    done
    [ "$end" -eq 0 ] && { _fp_warn "Method $method_signature end not found in $(basename "$file")"; return 0; }

    local method_head
    method_head=$(sed -n "${start}p" "$file")
    method_head_escaped=$(printf "%s\n" "$method_head" | sed 's/\\/\\\\/g')

    sed -i "${start},${end}c\\
$method_head_escaped\\
$new_method_body\\
.end method" "$file"

    _fp_success "Replaced method $method_signature in $(basename "$file")"
    return 0
}

# ── Python: insert a line before ALL occurrences of a pattern ──────────
insert_line_before_all() {
    local file="$1"
    local pattern="$2"
    local new_line="$3"

    python3 - "$file" "$pattern" "$new_line" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
pattern = sys.argv[2]
new_line = sys.argv[3]

if not path.exists():
    sys.exit(4)

lines = path.read_text().splitlines()
matched = False
changed = False

i = 0
while i < len(lines):
    line = lines[i]
    if pattern in line:
        matched = True
        indent = re.match(r"\s*", line).group(0)
        candidate = f"{indent}{new_line}"
        if i > 0 and lines[i - 1].strip() == new_line.strip():
            i += 1
            continue
        lines.insert(i, candidate)
        changed = True
        i += 2
    else:
        i += 1

if not matched:
    sys.exit(3)

if changed:
    path.write_text("\n".join(lines) + "\n")
PY

    local status=$?
    case "$status" in
        0) _fp_success "Inserted '${new_line}' before pattern in $(basename "$file")" ;;
        3) _fp_warn "Pattern '${pattern}' not found in $(basename "$file")" ;;
        4) _fp_warn "File not found: $file" ;;
        *) _fp_err "Failed to insert in $file (status $status)"; return 1 ;;
    esac
    return 0
}

# ── Python: insert const before a condition near a search string ───────
insert_const_before_condition_near_string() {
    local file="$1"
    local search_string="$2"
    local condition_prefix="$3"
    local register="$4"
    local value="$5"

    python3 - "$file" "$search_string" "$condition_prefix" "$register" "$value" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
search_string = sys.argv[2]
condition_prefix = sys.argv[3]
register = sys.argv[4]
value = sys.argv[5]

if not path.exists():
    sys.exit(4)

lines = path.read_text().splitlines()
matched = False
changed = False

for idx, line in enumerate(lines):
    if search_string in line:
        matched = True
        start = max(0, idx - 20)
        for j in range(idx - 1, start - 1, -1):
            stripped = lines[j].strip()
            if stripped.startswith(condition_prefix):
                indent = re.match(r"\s*", lines[j]).group(0)
                insert_line = f"{indent}const/4 {register}, 0x{value}"
                if j == 0 or lines[j - 1].strip() != f"const/4 {register}, 0x{value}":
                    lines.insert(j, insert_line)
                    changed = True
                break

if not matched:
    sys.exit(3)

if changed:
    path.write_text("\n".join(lines) + "\n")
PY

    local status=$?
    case "$status" in
        0) _fp_success "Inserted const for ${register} near '${condition_prefix}' in $(basename "$file")" ;;
        3) _fp_warn "Search string '${search_string}' not found in $(basename "$file")" ;;
        4) _fp_warn "File not found: $file" ;;
        *) _fp_err "Failed to patch condition in $file (status $status)"; return 1 ;;
    esac
    return 0
}

# ── Python: replace move-result after an invoke pattern ────────────────
replace_move_result_after_invoke() {
    local file="$1"
    local invoke_pattern="$2"
    local replacement="$3"

    python3 - "$file" "$invoke_pattern" "$replacement" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
invoke_pattern = sys.argv[2]
replacement = sys.argv[3]

if not path.exists():
    sys.exit(4)

lines = path.read_text().splitlines()
matched = False
changed = False

i = 0
while i < len(lines):
    line = lines[i]
    if invoke_pattern in line:
        matched = True
        for j in range(i + 1, min(i + 6, len(lines))):
            target = lines[j].strip()
            if target.startswith('move-result'):
                indent = re.match(r"\s*", lines[j]).group(0)
                desired = f"{indent}{replacement}"
                if target == replacement:
                    break
                if lines[j].strip() == replacement:
                    break
                lines[j] = desired
                changed = True
                break
        i = i + 1
    else:
        i += 1

if not matched:
    sys.exit(3)

if changed:
    path.write_text("\n".join(lines) + "\n")
PY

    local status=$?
    case "$status" in
        0) _fp_success "Replaced move-result after invoke in $(basename "$file")" ;;
        3) _fp_warn "Invoke pattern not found in $(basename "$file")" ;;
        4) _fp_warn "File not found: $file" ;;
        *) _fp_err "Failed to replace move-result in $file (status $status)"; return 1 ;;
    esac
    return 0
}

# ── Python: remove if-eqz guard in StrictJarFile ──────────────────────
replace_if_block_in_strict_jar_file() {
    local file="$1"

    python3 - "$file" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
if not path.exists():
    sys.exit(4)

lines = path.read_text().splitlines()
changed = False

for idx, line in enumerate(lines):
    if 'invoke-virtual {p0, v5}, Landroid/util/jar/StrictJarFile;->findEntry(Ljava/lang/String;)Ljava/util/zip/ZipEntry;' in line:
        if_idx = None
        for j in range(idx + 1, min(idx + 12, len(lines))):
            stripped = lines[j].strip()
            if stripped.startswith('if-eqz v6, :cond_'):
                if_idx = j
                break
        if if_idx is not None:
            del lines[if_idx]
            changed = True
        for j in range(idx + 1, min(idx + 20, len(lines))):
            stripped = lines[j].strip()
            if re.match(r':cond_[0-9a-zA-Z_]+', stripped):
                indent = re.match(r'\s*', lines[j]).group(0)
                label = stripped
                if j + 1 < len(lines) and lines[j + 1].strip() == 'nop':
                    break
                lines.insert(j + 1, f'{indent}nop')
                lines[j] = f'{indent}{label}'
                changed = True
                break
        break

if changed:
    path.write_text('\n'.join(lines) + '\n')
PY

    local status=$?
    case "$status" in
        0) _fp_success "Removed if-eqz guard in $(basename "$file")" ;;
        4) _fp_warn "StrictJarFile.smali not found" ;;
        *) _fp_err "Failed to adjust StrictJarFile (status $status)"; return 1 ;;
    esac
    return 0
}

# ── Python: flip <clinit> const from 0x0 to 0x1 in ReconcilePackageUtils ──
patch_reconcile_clinit() {
    local file="$1"

    python3 - "$file" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
if not path.exists():
    sys.exit(4)

lines = path.read_text().splitlines()
changed = False

for idx, line in enumerate(lines):
    if '.method static constructor <clinit>()V' in line:
        for j in range(idx + 1, len(lines)):
            stripped = lines[j].strip()
            if stripped == '.end method':
                break
            if stripped == 'const/4 v0, 0x0':
                lines[j] = lines[j].replace('0x0', '0x1')
                changed = True
                break
        break

if changed:
    path.write_text('\n'.join(lines) + '\n')
PY

    local status=$?
    case "$status" in
        0) _fp_success "Updated <clinit> constant in $(basename "$file")" ;;
        4) _fp_warn "File not found: $file" ;;
        *) _fp_err "Failed to patch <clinit> in $file (status $status)"; return 1 ;;
    esac
    return 0
}

# ── Python: force register value before a condition ────────────────────
ensure_const_before_if_for_register() {
    local file="$1"
    local invoke_pattern="$2"
    local condition_prefix="$3"
    local register="$4"
    local value="$5"

    python3 - "$file" "$invoke_pattern" "$condition_prefix" "$register" "$value" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
invoke_pattern = sys.argv[2]
condition_prefix = sys.argv[3]
register = sys.argv[4]
value = sys.argv[5]

if not path.exists():
    sys.exit(4)

lines = path.read_text().splitlines()
matched = False
changed = False

for idx, line in enumerate(lines):
    if invoke_pattern in line:
        matched = True
        for j in range(max(0, idx - 1), max(0, idx - 10), -1):
            stripped = lines[j].strip()
            if stripped.startswith(condition_prefix):
                indent = re.match(r'\s*', lines[j]).group(0)
                insert_line = f'{indent}const/4 {register}, 0x{value}'
                if j == 0 or lines[j - 1].strip() != f'const/4 {register}, 0x{value}':
                    lines.insert(j, insert_line)
                    changed = True
                break

if not matched:
    sys.exit(3)

if changed:
    path.write_text('\n'.join(lines) + '\n')
PY

    local status=$?
    case "$status" in
        0) _fp_success "Forced ${register} to 0x${value} before '${condition_prefix}' in $(basename "$file")" ;;
        3) _fp_warn "Invoke pattern not found in $(basename "$file")" ;;
        4) _fp_warn "File not found: $file" ;;
        *) _fp_err "Failed to enforce const on ${register} in $file (status $status)"; return 1 ;;
    esac
    return 0
}

# ── Clean invoke-custom in equals/hashCode/toString (prerequisite) ─────
modify_invoke_custom_methods() {
    local decompile_dir="$1"
    _fp_log "Checking for invoke-custom in $(basename "$decompile_dir")..."

    local smali_files
    smali_files=$(find "$decompile_dir" -type f -name "*.smali" 2>/dev/null | while read -r f; do
        if [ -f "$f" ] && grep -s -q "invoke-custom" "$f" 2>/dev/null; then
            echo "$f"
        fi
    done)

    [ -z "$smali_files" ] && { _fp_log "No invoke-custom found"; return 0; }

    local count=0
    while IFS= read -r smali_file; do
        [ ! -f "$smali_file" ] && continue
        count=$((count + 1))

        # equals
        sed -i "/.method.*equals(/,/^.end method$/ {
            /^    .registers/c\\    .registers 2
            /^    invoke-custom/d
            /^    move-result/d
            /^    return/c\\    const/4 v0, 0x0\n\n    return v0
        }" "$smali_file" 2>/dev/null || true

        # hashCode
        sed -i "/.method.*hashCode(/,/^.end method$/ {
            /^    .registers/c\\    .registers 2
            /^    invoke-custom/d
            /^    move-result/d
            /^    return/c\\    const/4 v0, 0x0\n\n    return v0
        }" "$smali_file" 2>/dev/null || true

        # toString
        sed -i "/.method.*toString(/,/^.end method$/ {
            s/^[[:space:]]*\\.registers.*/    .registers 1/
            /^    invoke-custom/d
            /^    move-result.*/d
            /^    return.*/c\\    const/4 v0, 0x0\n\n    return-object v0
        }" "$smali_file" 2>/dev/null || true
    done <<<"$smali_files"

    [ "$count" -gt 0 ] && _fp_success "Modified $count files with invoke-custom"
}
