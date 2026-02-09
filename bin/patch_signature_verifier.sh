#!/bin/bash

# =========================================================
#  SIGNATURE VERIFICATION DISABLER
#  Patches framework.jar to bypass APK signature checks
# =========================================================

patch_signature_verification() {
    local SYSTEM_DUMP="$1"
    
    # CRITICAL: Save workspace
    local WORKSPACE="$GITHUB_WORKSPACE"
    
    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_step "🔓 SIGNATURE VERIFICATION DISABLER"
    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Find framework.jar
    FRAMEWORK_JAR=$(find "$SYSTEM_DUMP" -name "framework.jar" -type f | head -n 1)
    
    if [ -z "$FRAMEWORK_JAR" ]; then
        log_warning "⚠️  framework.jar not found in system partition"
        return 0
    fi
    
    log_info "Located: $FRAMEWORK_JAR"
    
    # Create patcher script
    PATCHER_SCRIPT="$TEMP_DIR/sig_verifier_patcher.py"
    cat > "$PATCHER_SCRIPT" <<'PYTHON_EOF'
#!/usr/bin/env python3
import sys
import re

def patch_signature_verifier(smali_file):
    """Patch getMinimumSignatureSchemeVersionForTargetSdk to always return 1"""
    
    print(f"[ACTION] Reading {smali_file}")
    with open(smali_file, 'r', encoding='utf-8') as f:
        content = f.read()
    
    original_length = len(content)
    print(f"[ACTION] Original file size: {original_length} bytes")
    
    # New method that always returns 1
    new_method = """.method public static blacklist getMinimumSignatureSchemeVersionForTargetSdk(I)I
    .registers 1

    const/4 v0, 0x1

    return v0
.end method"""
    
    # Pattern to match the entire method
    print("[ACTION] Searching for getMinimumSignatureSchemeVersionForTargetSdk method...")
    pattern = r'\.method\s+public\s+static\s+blacklist\s+getMinimumSignatureSchemeVersionForTargetSdk\(I\)I.*?\.end\s+method'
    
    matches = re.findall(pattern, content, flags=re.DOTALL)
    if matches:
        orig_lines = matches[0].count('\n') + 1
        print(f"[ACTION] Found method ({orig_lines} lines)")
        print("[ACTION] Original method preview:")
        preview = matches[0].split('\n')[:5]
        for line in preview:
            if line.strip():
                print(f"         {line}")
        if orig_lines > 5:
            print(f"         ... (+{orig_lines - 5} more lines)")
    else:
        print("[ERROR] Method not found!")
        return False
    
    # Replace
    print("[ACTION] Replacing with signature bypass version...")
    new_content = re.sub(pattern, new_method, content, flags=re.DOTALL)
    
    if new_content != content:
        new_length = len(new_content)
        size_diff = original_length - new_length
        print(f"[ACTION] New file size: {new_length} bytes (reduced by {size_diff} bytes)")
        
        print("[ACTION] New method structure:")
        for line in new_method.split('\n'):
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
        print("[ERROR] Usage: sig_verifier_patcher.py <smali_file>")
        sys.exit(1)
    
    smali_file = sys.argv[1]
    success = patch_signature_verifier(smali_file)
    sys.exit(0 if success else 1)
PYTHON_EOF
    
    chmod +x "$PATCHER_SCRIPT"
    
    # Create work directory
    WORK_DIR="$TEMP_DIR/framework_work"
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"
    
    # Patch using library
    if patch_dex_file "$FRAMEWORK_JAR" "$WORK_DIR" "android/util/apk/ApkSignatureVerifier" "$PATCHER_SCRIPT" "true"; then
        log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_success "✅ SIGNATURE VERIFICATION DISABLED"
        log_success "   Effect: Modified APKs can install without signature errors"
        log_success "   Status: All signature checks bypassed"
        log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    else
        log_error "✗ Signature verification patching failed"
        log_info "Restoring original framework.jar..."
        cp "${FRAMEWORK_JAR}.bak" "$FRAMEWORK_JAR"
        log_warning "Original restored"
    fi
    
    # Cleanup
    cd "$WORKSPACE"
    rm -rf "$WORK_DIR"
}

# Export function
export -f patch_signature_verification
