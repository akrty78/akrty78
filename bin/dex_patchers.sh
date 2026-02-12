#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
#  dex_patchers.sh  —  APK/JAR patchers
#
#  Method: baksmali → sed/python patch smali → smali → zip -0 -u
#  Manifest: NEVER read or touched (only the DEX changes)
#
#  Think of it as "MT Manager in script form":
#    Open APK → pick DEX → edit method → save DEX → put back
# ═══════════════════════════════════════════════════════════════════

# Load smali_tools only if not already sourced
declare -f _smali_patch_dex &>/dev/null || source "$BIN_DIR/smali_tools.sh"

# ─────────────────────────────────────────────────────────────────
#  Helper: run _smali_patch_dex on EVERY DEX that references a class
# ─────────────────────────────────────────────────────────────────
_patch_all_dexes_with() {
    local archive="$1"
    local class_strings="$2"   # space-separated class name fragments
    local api="$3"
    local patcher_func="$4"

    local found_any=0
    for dex in $(unzip -l "$archive" 2>/dev/null | grep -oP 'classes\d*\.dex' | sort); do
        local tmp; tmp=$(mktemp)
        unzip -p "$archive" "$dex" > "$tmp" 2>/dev/null
        local relevant=0
        for cls in $class_strings; do
            if strings "$tmp" 2>/dev/null | grep -qF "$cls"; then
                relevant=1; break
            fi
        done
        rm -f "$tmp"
        if [ "$relevant" -eq 1 ]; then
            _smali_patch_dex "$archive" "$dex" "$api" "$patcher_func" && found_any=1 || true
        fi
    done
    [ "$found_any" -eq 1 ]
}


# ╔══════════════════════════════════════════════════════════════════╗
# ║  1. SETTINGS.APK — AI Support (isAiSupported → always true)      ║
# ╚══════════════════════════════════════════════════════════════════╝
#
#  What MT Manager modder does manually:
#    1. Open Settings.apk → find classes2.dex
#    2. Find InternalDeviceUtils class
#    3. Find isAiSupported method
#    4. Edit bytecode: const/4 v0, 0x1 ; return v0
#    5. Save
#
#  We do the same via baksmali smali → edit .smali text → smali
#

_settings_ai_patcher() {
    local smali_dir="$1"
    local patched=0

    # Find InternalDeviceUtils.smali
    local target
    target=$(find "$smali_dir" -name "InternalDeviceUtils.smali" 2>/dev/null | head -1)
    if [ -z "$target" ]; then
        log_warning "    InternalDeviceUtils.smali not in this DEX"
        return 1
    fi
    log_info "    Found: $target"

    # Force ALL non-void methods in this class that return boolean/int to return 1
    # This covers: isAiSupported, isAiPcSupported, isAiTabletSupported, etc.
    # (HyperOS 3 may name it differently across sub-versions)
    python3 - "$target" <<'PY'
import sys, re
from pathlib import Path

path = Path(sys.argv[1])
lines = path.read_text(errors="replace").splitlines()
changed = False
patched = 0

# Target: any method that looks like an "isXxx" boolean method
i = 0
while i < len(lines):
    stripped = lines[i].lstrip()
    if stripped.startswith(".method") and (
        "isAi" in stripped or
        "isSupportAi" in stripped or
        "AiSupport" in stripped or
        "aiSupport" in stripped
    ):
        # Skip void methods
        if ")V" in stripped:
            i += 1; continue
        j = i + 1
        while j < len(lines) and not lines[j].lstrip().startswith(".end method"):
            j += 1
        stub = [
            lines[i],
            "    .registers 2",
            "    const/4 v0, 0x1",
            "    return v0",
            ".end method"
        ]
        lines[i:j+1] = stub
        changed = True; patched += 1
        i += len(stub)
    else:
        i += 1

if changed:
    path.write_text("\n".join(lines) + "\n")
    print(f"patched {patched} AI method(s) in {path.name}")
    sys.exit(0)
else:
    print(f"no AI methods found in {path.name}")
    sys.exit(3)
PY

    local rc=$?
    [ $rc -eq 0 ] && patched=1 && log_success "    ✓ AI methods patched" || \
                     log_warning "    No isAi* methods found (may be in different DEX)"
    [ $patched -gt 0 ]
}

patch_settings_ai() {
    local DUMP="$1"

    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_step "🤖 SETTINGS.APK AI SUPPORT PATCH"
    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local APK
    APK=$(find "$DUMP" -name "Settings.apk" -type f | head -n 1)
    [ -z "$APK" ] && { log_warning "⚠  Settings.apk not found"; return 0; }

    log_info "File: $APK"
    log_info "Size: $(du -h "$APK" | cut -f1)"

    _smali_ensure_tools || { log_error "smali tools unavailable"; return 0; }

    cp "$APK" "${APK}.bak"
    log_success "✓ Backup created"

    # Find and patch every DEX containing InternalDeviceUtils
    if _patch_all_dexes_with "$APK" "InternalDeviceUtils" "35" "_settings_ai_patcher"; then
        log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_success "✅ AI SUPPORT ENABLED"
        log_success "   isAi*() methods → always true"
        log_success "   Size: $(du -h "$APK" | cut -f1)  (unchanged)"
        log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    else
        log_error "✗ Patch failed — restoring backup"
        cp "${APK}.bak" "$APK"
    fi
    cd "$GITHUB_WORKSPACE"
}


# ╔══════════════════════════════════════════════════════════════════╗
# ║  2. MIUISYSTEMUI.APK — VoLTE Icons (IS_INTERNATIONAL_BUILD=1)    ║
# ╚══════════════════════════════════════════════════════════════════╝
#
#  What MT Manager modder does:
#    1. Open MiuiSystemUI.apk → classes.dex
#    2. Search for IS_INTERNATIONAL_BUILD references
#    3. In each method: replace sget-boolean/getRegion result with const 1
#    4. Save
#
#  Via smali: sed replace sget-boolean → const/4, and replace
#  move-result after getRegion() invoke
#

_systemui_volte_patcher() {
    local smali_dir="$1"
    local patched=0

    # Pattern A: sget-boolean vX, Lmiui/os/Build;->IS_INTERNATIONAL_BUILD:Z
    # Replace with: const/4 vX, 0x1
    python3 - "$smali_dir" <<'PY'
import sys, re
from pathlib import Path

smali_dir = Path(sys.argv[1])
pattern = re.compile(
    r'(\s*)sget-boolean (v\d+), Lmiui/os/Build;->IS_INTERNATIONAL_BUILD:Z'
)
total = 0
for path in smali_dir.rglob("*.smali"):
    text = path.read_text(errors="replace")
    new_text, n = pattern.subn(r'\1const/4 \2, 0x1', text)
    if n > 0:
        path.write_text(new_text)
        total += n
        print(f"  sget-boolean: {n} replacement(s) in {path.name}")

# Pattern B: after invoke-static getRegion(), find move-result-object vX → const/4 vX, 0x1
# (For check: IS_INTERNATIONAL_BUILD via method call comparison)
invoke_pat = re.compile(
    r'invoke-static \{[^}]*\}, Lmiui/os/Build;->getRegion\(\)Ljava/lang/String;'
)
for path in smali_dir.rglob("*.smali"):
    lines = path.read_text(errors="replace").splitlines()
    changed = False
    i = 0
    while i < len(lines):
        if invoke_pat.search(lines[i]):
            for j in range(i+1, min(i+6, len(lines))):
                stripped = lines[j].strip()
                if stripped.startswith("move-result"):
                    reg = stripped.split()[-1] if " " in stripped else "v0"
                    indent = re.match(r"\s*", lines[j]).group(0)
                    lines[j] = f"{indent}const/4 {reg}, 0x1"
                    changed = True; total += 1
                    print(f"  getRegion→const/4: replaced in {path.name}")
                    break
        i += 1
    if changed:
        path.write_text("\n".join(lines) + "\n")

print(f"systemui_volte_patcher: {total} total replacement(s)")
sys.exit(0 if total > 0 else 3)
PY

    local rc=$?
    [ $rc -eq 0 ] && patched=1 && log_success "    ✓ VoLTE patterns patched" || \
                     log_warning "    No VoLTE patterns in this DEX"
    [ $patched -gt 0 ]
}

patch_systemui_volte() {
    local DUMP="$1"

    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_step "📶 SYSTEMUI VOLTE ICON PATCH"
    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local APK
    APK=$(find "$DUMP" \( -name "MiuiSystemUI.apk" -o -name "SystemUI.apk" \) -type f | head -n 1)
    [ -z "$APK" ] && { log_warning "⚠  SystemUI APK not found"; return 0; }

    log_success "✓ Found: $(basename "$APK")"
    log_info "File: $APK"
    log_info "Size: $(du -h "$APK" | cut -f1)"

    _smali_ensure_tools || { log_error "smali tools unavailable"; return 0; }

    cp "$APK" "${APK}.bak"
    log_success "✓ Backup created"

    if _patch_all_dexes_with "$APK" "IS_INTERNATIONAL_BUILD miui/os/Build" "35" "_systemui_volte_patcher"; then
        log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_success "✅ VOLTE ICONS ENABLED"
        log_success "   IS_INTERNATIONAL_BUILD → always true"
        log_success "   Size: $(du -h "$APK" | cut -f1)  (unchanged)"
        log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    else
        log_error "✗ Patch failed — restoring backup"
        cp "${APK}.bak" "$APK"
    fi
    cd "$GITHUB_WORKSPACE"
}


# ╔══════════════════════════════════════════════════════════════════╗
# ║  3. PROVISION.APK — GMS Support                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

_provision_gms_patcher() {
    local smali_dir="$1"
    local patched=0

    # Same IS_INTERNATIONAL_BUILD pattern as SystemUI
    python3 - "$smali_dir" <<'PY'
import sys, re
from pathlib import Path

smali_dir = Path(sys.argv[1])
total = 0

# sget-boolean IS_INTERNATIONAL_BUILD → const/4 vX, 0x1
pat = re.compile(
    r'(\s*)sget-boolean (v\d+), Lmiui/os/Build;->IS_INTERNATIONAL_BUILD:Z'
)
for path in smali_dir.rglob("*.smali"):
    text = path.read_text(errors="replace")
    new_text, n = pat.subn(r'\1const/4 \2, 0x1', text)
    if n:
        path.write_text(new_text); total += n

# invoke getRegion → move-result → const/4
invoke_pat = re.compile(
    r'invoke-static \{[^}]*\}, Lmiui/os/Build;->getRegion\(\)Ljava/lang/String;'
)
for path in smali_dir.rglob("*.smali"):
    lines = path.read_text(errors="replace").splitlines()
    changed = False
    i = 0
    while i < len(lines):
        if invoke_pat.search(lines[i]):
            for j in range(i+1, min(i+6, len(lines))):
                if lines[j].strip().startswith("move-result"):
                    reg = lines[j].strip().split()[-1]
                    indent = re.match(r"\s*", lines[j]).group(0)
                    lines[j] = f"{indent}const/4 {reg}, 0x1"
                    changed = True; total += 1; break
        i += 1
    if changed:
        path.write_text("\n".join(lines) + "\n")

print(f"provision_gms_patcher: {total} replacement(s)")
sys.exit(0 if total > 0 else 3)
PY

    local rc=$?
    [ $rc -eq 0 ] && patched=1 && log_success "    ✓ GMS check patterns patched" || \
                     log_warning "    No GMS check patterns in this DEX"
    [ $patched -gt 0 ]
}

patch_provision_gms() {
    local DUMP="$1"

    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_step "📱 PROVISION GMS SUPPORT PATCH"
    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local APK
    APK=$(find "$DUMP" -name "Provision.apk" -type f | head -n 1)
    [ -z "$APK" ] && { log_warning "⚠  Provision.apk not found"; return 0; }

    log_info "File: $APK"
    log_info "Size: $(du -h "$APK" | cut -f1)"

    _smali_ensure_tools || { log_error "smali tools unavailable"; return 0; }

    cp "$APK" "${APK}.bak"
    log_success "✓ Backup created"

    if _patch_all_dexes_with "$APK" "IS_INTERNATIONAL_BUILD" "35" "_provision_gms_patcher"; then
        log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_success "✅ GMS SUPPORT ENABLED"
        log_success "   IS_INTERNATIONAL_BUILD → always true"
        log_success "   Size: $(du -h "$APK" | cut -f1)  (unchanged)"
        log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    else
        log_error "✗ Patch failed — restoring backup"
        cp "${APK}.bak" "$APK"
    fi
    cd "$GITHUB_WORKSPACE"
}


# ╔══════════════════════════════════════════════════════════════════╗
# ║  4. MIUI-SERVICES.JAR — CN→Global                                ║
# ╚══════════════════════════════════════════════════════════════════╝

_miui_service_patcher() {
    local smali_dir="$1"
    local patched=0

    # Same patterns — IS_INTERNATIONAL_BUILD + getRegion()
    python3 - "$smali_dir" <<'PY'
import sys, re
from pathlib import Path

smali_dir = Path(sys.argv[1])
total = 0

pat = re.compile(
    r'(\s*)sget-boolean (v\d+), Lmiui/os/Build;->IS_INTERNATIONAL_BUILD:Z'
)
for path in smali_dir.rglob("*.smali"):
    text = path.read_text(errors="replace")
    new_text, n = pat.subn(r'\1const/4 \2, 0x1', text)
    if n:
        path.write_text(new_text); total += n

invoke_pat = re.compile(
    r'invoke-static \{[^}]*\}, Lmiui/os/Build;->getRegion\(\)Ljava/lang/String;'
)
for path in smali_dir.rglob("*.smali"):
    lines = path.read_text(errors="replace").splitlines()
    changed = False
    i = 0
    while i < len(lines):
        if invoke_pat.search(lines[i]):
            for j in range(i+1, min(i+6, len(lines))):
                if lines[j].strip().startswith("move-result"):
                    reg = lines[j].strip().split()[-1]
                    indent = re.match(r"\s*", lines[j]).group(0)
                    lines[j] = f"{indent}const/4 {reg}, 0x1"
                    changed = True; total += 1; break
        i += 1
    if changed:
        path.write_text("\n".join(lines) + "\n")

print(f"miui_service_patcher: {total} replacement(s)")
sys.exit(0 if total > 0 else 3)
PY

    local rc=$?
    [ $rc -eq 0 ] && patched=1 && log_success "    ✓ CN→Global patterns patched" || \
                     log_warning "    No CN check patterns in this DEX"
    [ $patched -gt 0 ]
}

patch_miui_service() {
    local DUMP="$1"

    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_step "🌏 MIUI SERVICE CN→GLOBAL PATCH"
    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local JAR
    JAR=$(find "$DUMP" -name "miui-services.jar" -type f | head -n 1)
    [ -z "$JAR" ] && { log_warning "⚠  miui-services.jar not found"; return 0; }

    log_success "✓ Found: miui-services.jar"
    log_info "File: $JAR"
    log_info "Size: $(du -h "$JAR" | cut -f1)"

    _smali_ensure_tools || { log_error "smali tools unavailable"; return 0; }

    cp "$JAR" "${JAR}.bak"
    log_success "✓ Backup created"

    if _patch_all_dexes_with "$JAR" "IS_INTERNATIONAL_BUILD miui/os/Build" "35" "_miui_service_patcher"; then
        log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_success "✅ MIUI SERVICE PATCHED (CN→GLOBAL)"
        log_success "   IS_INTERNATIONAL_BUILD → always true"
        log_success "   Size: $(du -h "$JAR" | cut -f1)  (unchanged)"
        log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    else
        log_error "✗ Patch failed — restoring backup"
        cp "${JAR}.bak" "$JAR"
    fi
    cd "$GITHUB_WORKSPACE"
}
