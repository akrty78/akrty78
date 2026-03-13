#!/usr/bin/env bash
# framework_patches/kaorios.sh
# Kaorios Toolbox — inject smali classes + patch framework.jar
# Ported from FrameworkPatcher/scripts/core/kaorios_patches.sh

FP_KAORIOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/kaorios_toolbox"

# ── Inject ~156 Kaorios utility .smali classes into highest smali_classesN ──
_kaorios_inject_utility_classes() {
    local decompile_dir="$1"
    local kaorios_source="$FP_KAORIOS_DIR/utils/kaorios"

    if [ ! -d "$kaorios_source" ]; then
        _fp_err "Kaorios utility classes not found at $kaorios_source"
        return 1
    fi

    _fp_log "Injecting Kaorios utility classes into framework..."

    # Find the highest numbered smali_classes directory
    local target_smali_dir="smali"
    local max_num=0
    for dir in "$decompile_dir"/smali_classes*; do
        [ -d "$dir" ] || continue
        local num; num="$(basename "$dir" | sed 's/smali_classes//')"
        [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -gt "$max_num" ] && {
            max_num=$num
            target_smali_dir="smali_classes${num}"
        }
    done

    _fp_log "Injecting into last existing directory: $target_smali_dir"

    local target_dir="$decompile_dir/$target_smali_dir/com/android/internal/util/kaorios"
    mkdir -p "$target_dir"

    if ! cp -r "$kaorios_source"/* "$target_dir/"; then
        _fp_err "Failed to copy Kaorios utility classes"
        return 1
    fi

    local copied_count; copied_count=$(find "$target_dir" -name "*.smali" | wc -l)
    _fp_success "Injected $copied_count Kaorios utility classes into $target_smali_dir"
    return 0
}

# ── Patch hasSystemFeature(String;I)Z — inject KaoriFeatureOverrides ──
_kaorios_patch_has_system_feature() {
    local decompile_dir="$1"
    _fp_log "Patching ApplicationPackageManager.hasSystemFeature"

    local target_file
    target_file=$(find "$decompile_dir" -type f -path "*/android/app/ApplicationPackageManager.smali" | head -n1)
    [ -z "$target_file" ] && { _fp_warn "ApplicationPackageManager.smali not found"; return 0; }

    # Relocate to last smali dir to avoid DEX limit
    local current_smali_dir; current_smali_dir=$(echo "$target_file" | sed -E 's|(.*/smali(_classes[0-9]*)?)/.*|\1|')
    local last_smali_dir="smali"
    local max_num=0
    for dir in "$decompile_dir"/smali_classes*; do
        [ -d "$dir" ] || continue
        local num; num="$(basename "$dir" | sed 's/smali_classes//')"
        [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -gt "$max_num" ] && {
            max_num=$num
            last_smali_dir="smali_classes${num}"
        }
    done

    local target_root="$decompile_dir/$last_smali_dir"

    if [ "$current_smali_dir" != "$target_root" ]; then
        _fp_log "Relocating ApplicationPackageManager to $last_smali_dir..."
        local new_dir="$target_root/android/app"
        mkdir -p "$new_dir"
        mv "$(dirname "$target_file")"/ApplicationPackageManager*.smali "$new_dir/" 2>/dev/null || true
        target_file="$new_dir/ApplicationPackageManager.smali"
        _fp_success "Relocated ApplicationPackageManager and inner classes to $last_smali_dir"
    fi

    python3 - "$target_file" <<'PYTHON'
import sys
import re
from pathlib import Path

target_file = Path(sys.argv[1])

if not target_file.exists():
    sys.exit(1)

lines = target_file.read_text().splitlines()
modified = False

kaorios_block = """
    invoke-static {}, Landroid/app/ActivityThread;->currentPackageName()Ljava/lang/String;

    move-result-object v0

    :try_start_kaori_override
    iget-object v1, p0, Landroid/app/ApplicationPackageManager;->mContext:Landroid/app/ContextImpl;

    invoke-static {v1, p1, v0}, Lcom/android/internal/util/kaorios/KaoriFeatureOverrides;->getOverride(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;)Ljava/lang/Boolean;

    move-result-object v0
    :try_end_kaori_override
    .catchall {:try_start_kaori_override .. :try_end_kaori_override} :catchall_kaori_override

    goto :goto_kaori_override

    :catchall_kaori_override
    const/4 v0, 0x0

    :goto_kaori_override
    if-eqz v0, :cond_kaori_override

    invoke-virtual {v0}, Ljava/lang/Boolean;->booleanValue()Z

    move-result p0

    return p0

    :cond_kaori_override
""".splitlines()

method_start = None
for i, line in enumerate(lines):
    if '.method ' in line and 'hasSystemFeature(Ljava/lang/String;I)Z' in line:
        method_start = i
        break

if method_start is not None:
    registers_line = None
    for i in range(method_start, min(method_start + 15, len(lines))):
        if '.locals' in lines[i] or '.registers' in lines[i]:
            registers_line = i
            break

    if registers_line:
        already_patched = False
        for i in range(method_start, min(method_start + 30, len(lines))):
            if 'KaoriFeatureOverrides' in lines[i]:
                already_patched = True
                break

        if not already_patched:
            for j, block_line in enumerate(reversed(kaorios_block)):
                lines.insert(registers_line + 1, block_line)
            print("✓ Inserted KaoriFeatureOverrides block")
            modified = True
        else:
            print("Already patched with KaoriFeatureOverrides")
else:
    print("hasSystemFeature(String, int) method not found")

if modified:
    target_file.write_text('\n'.join(lines) + '\n')
    print("✓ Successfully patched ApplicationPackageManager.smali")
else:
    print("No changes needed or already patched")
PYTHON

    [ $? -eq 0 ] && _fp_success "Patched ApplicationPackageManager.hasSystemFeature" \
                  || _fp_warn "ApplicationPackageManager patch failed"
    return 0
}

# ── Patch Instrumentation.newApplication methods ──────────────────────
_kaorios_patch_instrumentation() {
    local decompile_dir="$1"
    _fp_log "Patching Instrumentation.newApplication methods..."

    local target_file
    target_file=$(find "$decompile_dir" -type f -path "*/android/app/Instrumentation.smali" | head -n1)
    [ -z "$target_file" ] && { _fp_warn "Instrumentation.smali not found"; return 0; }

    python3 - "$target_file" <<'PYTHON'
import sys
import re
from pathlib import Path

target_file = Path(sys.argv[1])
if not target_file.exists():
    sys.exit(1)

lines = target_file.read_text().splitlines()
modified = False
in_new_app_method = False
method_param = None
i = 0

while i < len(lines):
    line = lines[i]

    if '.method ' in line and 'newApplication' in line:
        if 'Ljava/lang/Class;Landroid/content/Context;' in line:
            in_new_app_method = True
            method_param = 'p1'
        elif 'Ljava/lang/ClassLoader;Ljava/lang/String;Landroid/content/Context;' in line:
            in_new_app_method = True
            method_param = 'p3'

    if in_new_app_method and 'return-object v0' in line:
        if i + 1 < len(lines) and '.end method' in lines[i+1]:
            if i > 0 and 'KaoriPropsUtils;->KaoriProps' in lines[i-1]:
                in_new_app_method = False
                i += 1
                continue
            indent = re.match(r'^\s*', line).group(0)
            patch_line = f'{indent}invoke-static {{{method_param}}}, Lcom/android/internal/util/kaorios/KaoriPropsUtils;->KaoriProps(Landroid/content/Context;)V'
            lines.insert(i, '')
            lines.insert(i, patch_line)
            modified = True
            i += 2
            in_new_app_method = False
            method_param = None
            continue

    if '.end method' in line:
        in_new_app_method = False
        method_param = None

    i += 1

if modified:
    target_file.write_text('\n'.join(lines) + '\n')
    print("✓ Patched Instrumentation.newApplication methods")
else:
    print("No changes needed or patch already applied")
PYTHON

    [ $? -eq 0 ] && _fp_success "Patched Instrumentation.newApplication methods" \
                  || _fp_warn "Failed to patch Instrumentation.newApplication methods"
    return 0
}

# ── Patch KeyStore2.getKeyEntry ────────────────────────────────────────
_kaorios_patch_keystore2() {
    local decompile_dir="$1"
    _fp_log "Patching KeyStore2.getKeyEntry..."

    local target_file
    target_file=$(find "$decompile_dir" -type f -path "*/android/security/KeyStore2.smali" | head -n1)
    [ -z "$target_file" ] && { _fp_warn "KeyStore2.smali not found"; return 0; }

    python3 - "$target_file" <<'PYTHON'
import sys
import re
from pathlib import Path

target_file = Path(sys.argv[1])
if not target_file.exists():
    sys.exit(1)

lines = target_file.read_text().splitlines()
modified = False
in_method = False
i = 0

while i < len(lines):
    line = lines[i]
    if '.method ' in line and 'getKeyEntry' in line and 'KeyDescriptor' in line and 'lambda' not in line:
        in_method = True

    if in_method and 'return-object v0' in line:
        if i + 1 < len(lines) and '.end method' in lines[i+1]:
            if i > 0 and 'KaoriKeyboxHooks;->KaoriGetKeyEntry' in lines[i-1]:
                in_method = False
                i += 1
                continue
            indent = re.match(r'^\s*', line).group(0)
            patch_lines = [
                '',
                f'{indent}invoke-static {{v0}}, Lcom/android/internal/util/kaorios/KaoriKeyboxHooks;->KaoriGetKeyEntry(Landroid/system/keystore2/KeyEntryResponse;)Landroid/system/keystore2/KeyEntryResponse;',
                f'{indent}move-result-object v0'
            ]
            for j, patch_line in enumerate(patch_lines):
                lines.insert(i + j, patch_line)
            modified = True
            i += len(patch_lines)
            in_method = False
            continue

    if '.end method' in line:
        in_method = False
    i += 1

if modified:
    target_file.write_text('\n'.join(lines) + '\n')
    print("✓ Patched KeyStore2.getKeyEntry")
else:
    print("No changes needed or patch already applied")
PYTHON

    [ $? -eq 0 ] && _fp_success "Patched KeyStore2.getKeyEntry" \
                  || _fp_warn "Failed to patch KeyStore2.getKeyEntry"
    return 0
}

# ── Patch AndroidKeyStoreSpi.engineGetCertificateChain ────────────────
_kaorios_patch_keystore_spi() {
    local decompile_dir="$1"
    _fp_log "Patching AndroidKeyStoreSpi.engineGetCertificateChain..."

    local target_file
    target_file=$(find "$decompile_dir" -type f -path "*/android/security/keystore2/AndroidKeyStoreSpi.smali" | head -n1)
    [ -z "$target_file" ] && { _fp_warn "AndroidKeyStoreSpi.smali not found"; return 0; }

    python3 - "$target_file" <<'PYTHON'
import sys
import re
from pathlib import Path

target_file = Path(sys.argv[1])
if not target_file.exists():
    sys.exit(1)

lines = target_file.read_text().splitlines()
modified = False
in_method = False
i = 0

while i < len(lines):
    line = lines[i]
    if '.method ' in line and 'engineGetCertificateChain' in line:
        in_method = True

    if in_method:
        if ('.registers' in line or '.locals' in line):
            patch_exists = False
            for k in range(1, 5):
                if i + k < len(lines) and 'KaoriPropsUtils;->KaoriGetCertificateChain' in lines[i+k]:
                    patch_exists = True
                    break
            if not patch_exists:
                indent = re.match(r'^\s*', line).group(0)
                patch_lines = [
                    '',
                    f'{indent}invoke-static {{}}, Lcom/android/internal/util/kaorios/KaoriPropsUtils;->KaoriGetCertificateChain()V'
                ]
                for j, patch_line in enumerate(patch_lines):
                    lines.insert(i + 1 + j, patch_line)
                modified = True
                i += len(patch_lines)

        if 'const/4 v4, 0x0' in line:
            found_aput_idx = -1
            for k in range(1, 10):
                if i + k < len(lines):
                    check_line = lines[i+k].strip()
                    if check_line == 'aput-object v2, v3, v4':
                        found_aput_idx = i + k
                        break
            if found_aput_idx != -1:
                patch_exists = False
                for k in range(1, 5):
                    if found_aput_idx + k < len(lines) and 'KaoriKeyboxHooks;->KaoriGetCertificateChain' in lines[found_aput_idx+k]:
                        patch_exists = True
                        break
                if not patch_exists:
                    indent = re.match(r'^\s*', lines[found_aput_idx]).group(0)
                    patch_lines = [
                        '',
                        f'{indent}invoke-static {{v3}}, Lcom/android/internal/util/kaorios/KaoriKeyboxHooks;->KaoriGetCertificateChain([Ljava/security/cert/Certificate;)[Ljava/security/cert/Certificate;',
                        f'{indent}move-result-object v3'
                    ]
                    for j, patch_line in enumerate(patch_lines):
                        lines.insert(found_aput_idx + 1 + j, patch_line)
                    modified = True
                    i = found_aput_idx + len(patch_lines) + 1
                    continue

    if '.end method' in line:
        in_method = False
    i += 1

if modified:
    target_file.write_text('\n'.join(lines) + '\n')
    print("✓ Patched AndroidKeyStoreSpi.engineGetCertificateChain")
else:
    print("No changes needed or patch already applied")
PYTHON

    [ $? -eq 0 ] && _fp_success "Patched AndroidKeyStoreSpi.engineGetCertificateChain" \
                  || _fp_warn "Failed to patch AndroidKeyStoreSpi.engineGetCertificateChain"
    return 0
}

# ── Main entry: apply all Kaorios patches to a decompiled framework.jar ──
run_kaorios_framework() {
    local decompile_dir="$1"
    _fp_step "═══════════════════════════════════════════"
    _fp_step "Applying Kaorios Toolbox Patches"
    _fp_step "═══════════════════════════════════════════"

    _kaorios_inject_utility_classes "$decompile_dir" || return 1
    _kaorios_patch_has_system_feature "$decompile_dir"
    _kaorios_patch_instrumentation "$decompile_dir"
    _kaorios_patch_keystore2 "$decompile_dir"
    _kaorios_patch_keystore_spi "$decompile_dir"

    _fp_success "Kaorios Toolbox patches applied (5/5 core patches)"
}

# ── Place KaoriosToolbox APK + permissions into ROM dump ──────────────
run_kaorios_place_files() {
    local dump_dir="$1"
    local priv_app="$dump_dir/system_ext/priv-app/KaoriosToolbox"
    local perms_dir="$dump_dir/system_ext/etc/permissions"
    mkdir -p "$priv_app" "$perms_dir"
    cp "$FP_KAORIOS_DIR/KaoriosToolbox.apk" "$priv_app/"
    cp "$FP_KAORIOS_DIR/privapp_whitelist_com.kousei.kaorios.xml" "$perms_dir/"
    _fp_success "KaoriosToolbox.apk + whitelist placed in system_ext"
}
