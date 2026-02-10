#!/bin/bash

# =========================================================
#  SIGNATURE VERIFICATION DISABLER (APKTOOL VERSION)
#  Standalone - uses apktool like MiuiBooster - NO DATA LOSS!
# =========================================================

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
    JAR_SIZE=$(du -h "$FRAMEWORK_JAR" | cut -f1)
    log_info "Original size: $JAR_SIZE"
    
    # Create backup
    log_info "Creating backup..."
    cp "$FRAMEWORK_JAR" "${FRAMEWORK_JAR}.bak"
    log_success "✓ Backup created"
    
    # Setup working directory
    WORK_DIR="$TEMP_DIR/framework_work_$$"
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"
    
    # PHASE 1: DECOMPILE WITH APKTOOL
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "PHASE 1: APKTOOL DECOMPILATION"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Decompiling framework.jar with apktool..."
    
    START_TIME=$(date +%s)
    
    if timeout 5m apktool d -r -f "$FRAMEWORK_JAR" -o "decompiled" 2>&1 | tee apktool_decompile.log | grep -q "I: Baksmaling"; then
        END_TIME=$(date +%s)
        DECOMPILE_TIME=$((END_TIME - START_TIME))
        log_success "✓ Decompiled successfully in ${DECOMPILE_TIME}s"
        
        SMALI_COUNT=$(find "decompiled" -name "*.smali" | wc -l)
        log_info "Decompiled $SMALI_COUNT smali files"
    else
        log_error "✗ Apktool decompilation failed"
        cat apktool_decompile.log | tail -20 | while read line; do
            log_error "   $line"
        done
        cd "$WORKSPACE"
        return 1
    fi
    
    # PHASE 2: FIND TARGET CLASS
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "PHASE 2: LOCATING TARGET CLASS"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Searching for: ApkSignatureVerifier.smali"
    
    SMALI_FILE=$(find "decompiled" -type f -path "*/android/util/apk/ApkSignatureVerifier.smali" | head -n 1)
    
    if [ ! -f "$SMALI_FILE" ]; then
        log_error "✗ Class not found: android/util/apk/ApkSignatureVerifier"
        cd "$WORKSPACE"
        return 1
    fi
    
    SMALI_REL_PATH=$(echo "$SMALI_FILE" | sed "s|decompiled/||")
    log_success "✓ Found: $SMALI_REL_PATH"
    
    # PHASE 3: PATCH SMALI
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "PHASE 3: PATCHING SMALI"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Create Python patcher
    cat > "patcher.py" <<'PYTHON_EOF'
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
    
    # Execute patcher
    if python3 "patcher.py" "$SMALI_FILE" 2>&1 | while IFS= read -r line; do
        if [[ "$line" == *"[ACTION]"* ]]; then
            log_info "${line#*[ACTION] }"
        elif [[ "$line" == *"[SUCCESS]"* ]]; then
            log_success "${line#*[SUCCESS] }"
        elif [[ "$line" == *"[ERROR]"* ]]; then
            log_error "${line#*[ERROR] }"
        fi
    done; then
        PATCH_SUCCESS=true
    else
        PATCH_SUCCESS=false
    fi
    
    if [ "$PATCH_SUCCESS" != true ]; then
        log_error "✗ Patching failed"
        cp "${FRAMEWORK_JAR}.bak" "$FRAMEWORK_JAR"
        cd "$WORKSPACE"
        return 1
    fi
    
    # PHASE 4: REBUILD WITH APKTOOL
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "PHASE 4: APKTOOL REBUILD"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Rebuilding framework.jar..."
    
    START_TIME=$(date +%s)
    
    if timeout 10m apktool b -c "decompiled" -o "framework_patched.jar" 2>&1 | tee apktool_build.log | grep -q "Built"; then
        END_TIME=$(date +%s)
        BUILD_TIME=$((END_TIME - START_TIME))
        log_success "✓ Rebuild completed in ${BUILD_TIME}s"
        
        if [ -f "framework_patched.jar" ]; then
            PATCHED_SIZE=$(du -h "framework_patched.jar" | cut -f1)
            log_info "Patched JAR size: $PATCHED_SIZE"
            
            # Verify size hasn't dropped significantly
            ORIG_SIZE=$(stat -c%s "$FRAMEWORK_JAR" 2>/dev/null || echo "0")
            NEW_SIZE=$(stat -c%s "framework_patched.jar" 2>/dev/null || echo "0")
            
            if [ "$ORIG_SIZE" -gt 0 ] && [ "$NEW_SIZE" -gt 0 ]; then
                SIZE_DIFF=$((ORIG_SIZE - NEW_SIZE))
                SIZE_PERCENT=$((SIZE_DIFF * 100 / ORIG_SIZE))
                
                log_info "Size check: Original ${ORIG_SIZE} bytes, New ${NEW_SIZE} bytes (${SIZE_PERCENT}% diff)"
                
                # Only reject if size DROPPED >10%
                if [ "$SIZE_DIFF" -gt 0 ] && [ "$SIZE_PERCENT" -gt 10 ]; then
                    log_error "✗ File size DROPPED ${SIZE_PERCENT}% - DATA LOSS!"
                    log_error "ABORTING to prevent corruption"
                    cp "${FRAMEWORK_JAR}.bak" "$FRAMEWORK_JAR"
                    cd "$WORKSPACE"
                    return 1
                fi
            fi
            
            # Remove old signature
            log_info "Removing old signature..."
            zip -q -d "framework_patched.jar" "META-INF/*" 2>&1 || true
            
            # Replace original
            log_info "Installing patched JAR..."
            mv "framework_patched.jar" "$FRAMEWORK_JAR"
            log_success "✓ Successfully patched!"
            
            log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            log_success "✅ SIGNATURE VERIFICATION DISABLED"
            log_success "   Method: getMinimumSignatureSchemeVersionForTargetSdk() → Always returns 1"
            log_success "   Effect: All APKs accepted regardless of signature"
            log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        else
            log_error "✗ Patched JAR not created"
            cp "${FRAMEWORK_JAR}.bak" "$FRAMEWORK_JAR"
        fi
    else
        log_error "✗ Apktool rebuild failed"
        cat apktool_build.log | tail -20 | while read line; do
            log_error "   $line"
        done
        cp "${FRAMEWORK_JAR}.bak" "$FRAMEWORK_JAR"
    fi
    
    cd "$WORKSPACE"
    return 0
}

# If running standalone
if [ "${BASH_SOURCE[0]}" -ef "$0" ]; then
    patch_signature_verification "$@"
fi
