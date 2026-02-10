#!/bin/bash

# =========================================================
#  SIGNATURE VERIFICATION DISABLER (APKTOOL VERSION)
#  Uses apktool like MiuiBooster - NO DATA LOSS!
# =========================================================

source "$(dirname "$0")/apktool_patcher_lib.sh"

patch_signature_verification() {
    local SYSTEM_DUMP="$1"
    
    # CRITICAL: Save workspace
    local WORKSPACE="$GITHUB_WORKSPACE"
    
    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_step "🔓 SIGNATURE VERIFICATION DISABLER"
    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Find framework.jar
    FRAMEWORK_JAR=$(find "$SYSTEM_DUMP" -name "framework.jar" -path "*/framework/*" -type f | head -n 1)
    
    if [ -z "$FRAMEWORK_JAR" ]; then
        log_warning "⚠️  framework.jar not found"
        cd "$WORKSPACE"
        return 0
    fi
    
    log_info "Located: $FRAMEWORK_JAR"
    
    # Create Python patcher script
    PATCHER_SCRIPT="$TEMP_DIR/signature_verifier_patcher.py"
    cat > "$PATCHER_SCRIPT" <<'PYTHON_EOF'
#!/usr/bin/env python3
import sys
import re

def patch_signature_verifier(smali_file):
    """Disable signature verification by always returning version 1"""
    
    print(f"[ACTION] Reading {smali_file}")
    with open(smali_file, 'r', encoding='utf-8') as f:
        content = f.read()
    
    original_length = len(content)
    print(f"[ACTION] Original file size: {original_length} bytes")
    
    # Find the method
    print("[ACTION] Searching for getMinimumSignatureSchemeVersionForTargetSdk method...")
    
    pattern = r'\.method\s+public\s+static\s+\w+\s+getMinimumSignatureSchemeVersionForTargetSdk\(I\)I.*?\.end\s+method'
    matches = re.findall(pattern, content, flags=re.DOTALL)
    
    if not matches:
        print("[ERROR] Method not found!")
        return False
    
    print(f"[ACTION] Found method ({len(matches[0])} bytes)")
    
    # Show preview
    orig_lines = matches[0].split('\n')[:5]
    print("[ACTION] Original method preview:")
    for line in orig_lines:
        print(f"         {line}")
    if len(matches[0].split('\n')) > 5:
        print(f"         ... (+{len(matches[0].split('\n')) - 5} more lines)")
    
    # Create new method that always returns 1
    new_method = """.method public static blacklist getMinimumSignatureSchemeVersionForTargetSdk(I)I
    .registers 1

    const/4 v0, 0x1
    return v0
.end method"""
    
    print("[ACTION] Replacing with signature bypass version...")
    
    new_content = re.sub(pattern, new_method, content, flags=re.DOTALL)
    
    if new_content != content:
        new_length = len(new_content)
        size_diff = original_length - new_length
        print(f"[ACTION] New file size: {new_length} bytes (reduced by {size_diff} bytes)")
        
        print("[ACTION] New method structure:")
        for line in new_method.split('\n')[:6]:
            if line.strip():
                print(f"         {line}")
        
        print(f"[ACTION] Writing patched content")
        with open(smali_file, 'w', encoding='utf-8') as f:
            f.write(new_content)
        
        print("[SUCCESS] Method replacement completed!")
        return True
    else:
        print("[ERROR] No changes made - pattern didn't match")
        return False

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("[ERROR] Usage: python3 patcher.py <smali_file>")
        sys.exit(1)
    
    success = patch_signature_verifier(sys.argv[1])
    sys.exit(0 if success else 1)
PYTHON_EOF
    
    # Patch using apktool
    if patch_apk_with_apktool "$FRAMEWORK_JAR" \
                              "android/util/apk/ApkSignatureVerifier" \
                              "$PATCHER_SCRIPT"; then
        log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_success "✅ SIGNATURE VERIFICATION DISABLED"
        log_success "   Method: getMinimumSignatureSchemeVersionForTargetSdk() → Always returns 1"
        log_success "   Effect: All APKs accepted regardless of signature"
        log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    else
        log_error "✗ Signature verification patching failed"
        log_info "Restoring original framework.jar..."
        if [ -f "${FRAMEWORK_JAR}.bak" ]; then
            cp "${FRAMEWORK_JAR}.bak" "$FRAMEWORK_JAR"
            log_warning "Original restored"
        fi
    fi
    
    cd "$WORKSPACE"
    return 0
}

# If running standalone
if [ "${BASH_SOURCE[0]}" -ef "$0" ]; then
    patch_signature_verification "$@"
fi
