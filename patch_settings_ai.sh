#!/bin/bash

# =========================================================
#  SETTINGS AI SUPPORT ENABLER (FIXED)
#  Patches Settings.apk to enable Xiaomi AI features
# =========================================================

patch_settings_ai_support() {
    local SYSTEM_EXT_DUMP="$1"
    
    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_step "🤖 SETTINGS.APK AI SUPPORT PATCH"
    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Find Settings.apk
    SETTINGS_APK=$(find "$SYSTEM_EXT_DUMP" -path "*/priv-app/Settings/Settings.apk" -type f | head -n 1)
    
    if [ -z "$SETTINGS_APK" ]; then
        log_warning "⚠️  Settings.apk not found in system_ext/priv-app"
        return 0
    fi
    
    log_info "Located: $SETTINGS_APK"
    
    # Create patcher script
    PATCHER_SCRIPT="$TEMP_DIR/settings_ai_patcher.py"
    cat > "$PATCHER_SCRIPT" <<'PYTHON_EOF'
#!/usr/bin/env python3
import sys
import re

def patch_ai_support(smali_file):
    """Replace isAiSupported method to always return true"""
    
    print(f"[ACTION] Reading {smali_file}")
    with open(smali_file, 'r', encoding='utf-8') as f:
        content = f.read()
    
    original_length = len(content)
    print(f"[ACTION] Original file size: {original_length} bytes")
    
    # New method that always returns true
    new_method = """.method public static isAiSupported(Landroid/content/Context;)Z
    .registers 1

    const/4 v0, 0x1

    return v0
.end method"""
    
    # Pattern to match the entire isAiSupported method
    print("[ACTION] Searching for isAiSupported method...")
    pattern = r'\.method\s+public\s+static\s+isAiSupported\(Landroid/content/Context;\)Z.*?\.end\s+method'
    
    matches = re.findall(pattern, content, flags=re.DOTALL)
    if matches:
        orig_lines = matches[0].count('\n') + 1
        print(f"[ACTION] Found method ({orig_lines} lines)")
        print("[ACTION] Original method preview:")
        preview = matches[0].split('\n')[:6]
        for line in preview:
            if line.strip():
                print(f"         {line}")
        if orig_lines > 6:
            print(f"         ... (+{orig_lines - 6} more lines)")
    else:
        print("[ERROR] Method not found!")
        return False
    
    # Replace
    print("[ACTION] Replacing with AI-enabled version...")
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
        print("[ERROR] Usage: settings_ai_patcher.py <smali_file>")
        sys.exit(1)
    
    smali_file = sys.argv[1]
    success = patch_ai_support(smali_file)
    sys.exit(0 if success else 1)
PYTHON_EOF
    
    chmod +x "$PATCHER_SCRIPT"
    
    # Create work directory
    WORK_DIR="$TEMP_DIR/settings_work"
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"
    
    # Patch using library
    if patch_dex_file "$SETTINGS_APK" "$WORK_DIR" "com/android/settings/InternalDeviceUtils" "$PATCHER_SCRIPT" "false"; then
        log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_success "✅ AI SUPPORT ENABLED"
        log_success "   Method: isAiSupported() → Always True"
        log_success "   Effect: Xiaomi AI features unlocked"
        log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    else
        log_error "✗ Settings AI patching failed"
        log_info "Restoring original Settings.apk..."
        cp "${SETTINGS_APK}.bak" "$SETTINGS_APK"
        log_warning "Original restored"
    fi
    
    # Cleanup
    rm -rf "$WORK_DIR"
}

# Export function
export -f patch_settings_ai_support
