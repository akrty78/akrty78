#!/bin/bash

# =========================================================
#  PROVISION GMS SUPPORT ENABLER
#  Patches Provision.apk to enable Google services
# =========================================================

patch_provision_gms() {
    local SYSTEM_EXT_DUMP="$1"
    
    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_step "📱 PROVISION GMS SUPPORT PATCH"
    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Find Provision.apk
    PROVISION_APK=$(find "$SYSTEM_EXT_DUMP" -path "*/priv-app/Provision/Provision.apk" -type f | head -n 1)
    
    if [ -z "$PROVISION_APK" ]; then
        log_warning "⚠️  Provision.apk not found in system_ext/priv-app"
        return 0
    fi
    
    log_info "Located: $PROVISION_APK"
    
    # Create patcher script
    PATCHER_SCRIPT="$TEMP_DIR/provision_gms_patcher.py"
    cat > "$PATCHER_SCRIPT" <<'PYTHON_EOF'
#!/usr/bin/env python3
import sys
import re

def patch_provision_gms(smali_file):
    """Replace IS_INTERNATIONAL_BUILD check with const true in setGmsAppEnabledStateForCn"""
    
    print(f"[ACTION] Reading {smali_file}")
    with open(smali_file, 'r', encoding='utf-8') as f:
        content = f.read()
    
    original_length = len(content)
    print(f"[ACTION] Original file size: {original_length} bytes")
    
    # Find the method first
    print("[ACTION] Searching for setGmsAppEnabledStateForCn method...")
    method_pattern = r'\.method.*setGmsAppEnabledStateForCn.*?\.end\s+method'
    
    method_matches = re.findall(method_pattern, content, flags=re.DOTALL)
    if not method_matches:
        print("[ERROR] Method setGmsAppEnabledStateForCn not found!")
        return False
    
    print(f"[ACTION] Found method setGmsAppEnabledStateForCn")
    
    # Pattern to find and replace the IS_INTERNATIONAL_BUILD line
    pattern = r'sget-boolean\s+(v\d+),\s+Lmiui/os/Build;->IS_INTERNATIONAL_BUILD:Z'
    
    matches = list(re.finditer(pattern, content))
    if matches:
        print(f"[ACTION] Found {len(matches)} IS_INTERNATIONAL_BUILD reference(s)")
        
        # Replace all occurrences
        replacement_count = 0
        for match in matches:
            var = match.group(1)  # Extract variable name (e.g., v0, v1)
            print(f"[ACTION] Replacing with: const/4 {var}, 0x1")
            replacement_count += 1
        
        new_content = re.sub(pattern, r'const/4 \1, 0x1', content)
        
        new_length = len(new_content)
        print(f"[ACTION] Applied {replacement_count} replacement(s)")
        print(f"[ACTION] New file size: {new_length} bytes")
        
        print(f"[ACTION] Writing patched content")
        with open(smali_file, 'w', encoding='utf-8') as f:
            f.write(new_content)
        
        print("[SUCCESS] GMS support enabled!")
        return True
    else:
        print("[ERROR] IS_INTERNATIONAL_BUILD not found in method!")
        return False

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("[ERROR] Usage: provision_gms_patcher.py <smali_file>")
        sys.exit(1)
    
    smali_file = sys.argv[1]
    success = patch_provision_gms(smali_file)
    sys.exit(0 if success else 1)
PYTHON_EOF
    
    chmod +x "$PATCHER_SCRIPT"
    
    # Create work directory
    WORK_DIR="$TEMP_DIR/provision_work"
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"
    
    # Patch using library
    if patch_dex_file "$PROVISION_APK" "$WORK_DIR" "com/android/provision/Utils" "$PATCHER_SCRIPT" "false"; then
        log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_success "✅ GMS SUPPORT ENABLED"
        log_success "   Method: setGmsAppEnabledStateForCn patched"
        log_success "   Effect: Google services will work properly"
        log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    else
        log_error "✗ Provision GMS patching failed"
        log_info "Restoring original Provision.apk..."
        cp "${PROVISION_APK}.bak" "$PROVISION_APK"
        log_warning "Original restored"
    fi
    
    # Cleanup
    rm -rf "$WORK_DIR"
}

# Export function
export -f patch_provision_gms
