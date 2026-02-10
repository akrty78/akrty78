#!/bin/bash

# =========================================================
#  SYSTEMUI VOLTE ICON ENABLER (APKTOOL VERSION)
#  Uses apktool - NO 20MB DATA LOSS!
# =========================================================

source "$(dirname "$0")/apktool_patcher_lib.sh"

patch_systemui_volte() {
    local SYSTEM_EXT_DUMP="$1"
    
    # CRITICAL: Save workspace
    local WORKSPACE="$GITHUB_WORKSPACE"
    
    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_step "📶 SYSTEMUI VOLTE ICON PATCH"
    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Find SystemUI
    log_info "Searching for SystemUI..."
    
    SYSTEMUI_APK=$(find "$SYSTEM_EXT_DUMP" -name "MiuiSystemUI.apk" -o -name "SystemUI.apk" | head -n 1)
    
    if [ -z "$SYSTEMUI_APK" ]; then
        log_warning "⚠️  SystemUI not found"
        cd "$WORKSPACE"
        return 0
    fi
    
    log_success "✓ Found: $(basename "$SYSTEMUI_APK")"
    log_info "Located: $SYSTEMUI_APK"
    
    # Create Python patcher for VoLTE
    PATCHER_SCRIPT="$TEMP_DIR/systemui_volte_patcher.py"
    cat > "$PATCHER_SCRIPT" <<'PYTHON_EOF'
#!/usr/bin/env python3
import sys
import re
import os

def patch_volte_icons(smali_dir):
    """Enable VoLTE icons by patching IS_INTERNATIONAL_BUILD checks"""
    
    # Target files
    target_files = [
        "com/android/systemui/statusbar/pipeline/mobile/data/repository/prod/MiuiOperatorCustomizedPolicy.smali",
        "com/android/systemui/statusbar/pipeline/mobile/ui/viewmodel/MiuiCellularIconVM\$special\$\$inlined\$combine\$1\$3.smali",
        "com/android/systemui/statusbar/pipeline/mobile/ui/MiuiMobileIconBinder\$bind\$1\$1\$10.smali"
    ]
    
    patched_count = 0
    
    for target_file in target_files:
        full_path = os.path.join(smali_dir, target_file)
        
        if not os.path.exists(full_path):
            print(f"[INFO] File not found (skipping): {os.path.basename(target_file)}")
            continue
        
        print(f"[ACTION] Processing: {os.path.basename(target_file)}")
        
        with open(full_path, 'r', encoding='utf-8') as f:
            content = f.read()
        
        # Find and replace IS_INTERNATIONAL_BUILD checks
        pattern = r'invoke-static\s+\{\},\s+Lmiui/os/Build;->getRegion\(\)Ljava/lang/String;'
        
        matches = re.findall(pattern, content)
        
        if matches:
            print(f"[ACTION] Found {len(matches)} IS_INTERNATIONAL_BUILD reference(s)")
            
            # Replace with const/4 vX, 0x1 (always return true)
            # Need to find the register being used
            # Pattern: invoke-static {}, Lmiui/os/Build;->getRegion()Ljava/lang/String;
            #          move-result-object vX
            
            new_content = content
            replaced = 0
            
            # Find all IS_INTERNATIONAL_BUILD usage patterns
            full_pattern = r'(invoke-static\s+\{\},\s+Lmiui/os/Build;->getRegion\(\)Ljava/lang/String;\s+move-result-object\s+(v\d+))'
            
            for match in re.finditer(full_pattern, content):
                full_match = match.group(1)
                register = match.group(2)
                
                # Replace with const/4 vX, 0x1
                replacement = f'const/4 {register}, 0x1'
                new_content = new_content.replace(full_match, replacement, 1)
                replaced += 1
                print(f"[ACTION] Replaced with: const/4 {register}, 0x1")
            
            if replaced > 0:
                with open(full_path, 'w', encoding='utf-8') as f:
                    f.write(new_content)
                print(f"[SUCCESS] Patched {os.path.basename(target_file)}: {replaced} change(s)")
                patched_count += 1
            else:
                print(f"[INFO] No changes made to {os.path.basename(target_file)}")
        else:
            print(f"[INFO] No IS_INTERNATIONAL_BUILD found in {os.path.basename(target_file)}")
    
    if patched_count > 0:
        print(f"[SUCCESS] Patched {patched_count} file(s) total")
        return True
    else:
        print("[ERROR] No files were patched")
        return False

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("[ERROR] Usage: python3 patcher.py <decompiled_dir>")
        sys.exit(1)
    
    smali_dir = sys.argv[1]
    success = patch_volte_icons(smali_dir)
    sys.exit(0 if success else 1)
PYTHON_EOF
    
    # Special handling for SystemUI - need to patch the decompiled directory, not a single file
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "APKTOOL PATCHING: $(basename "$SYSTEMUI_APK")"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "File: $(basename "$SYSTEMUI_APK")"
    log_info "Size: $(du -h "$SYSTEMUI_APK" | cut -f1)"
    
    # Backup
    log_info "Creating backup..."
    cp "$SYSTEMUI_APK" "${SYSTEMUI_APK}.bak"
    log_success "✓ Backup created"
    
    # Setup working directory
    WORK_DIR="$TEMP_DIR/systemui_work_$$"
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"
    
    # PHASE 1: DECOMPILE
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "PHASE 1: APKTOOL DECOMPILATION"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    START_TIME=$(date +%s)
    
    if timeout 10m apktool d -r -f "$SYSTEMUI_APK" -o "decompiled" 2>&1 | tee apktool_decompile.log | grep -q "I: Baksmaling"; then
        END_TIME=$(date +%s)
        DECOMPILE_TIME=$((END_TIME - START_TIME))
        log_success "✓ Decompiled successfully in ${DECOMPILE_TIME}s"
        
        SMALI_COUNT=$(find "decompiled" -name "*.smali" | wc -l)
        log_info "Decompiled $SMALI_COUNT smali files"
    else
        log_error "✗ Apktool decompilation failed"
        cd "$WORKSPACE"
        return 1
    fi
    
    # PHASE 2: PATCH
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "PHASE 2: VOLTE PATCHING"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    if python3 "$PATCHER_SCRIPT" "decompiled" 2>&1 | while IFS= read -r line; do
        if [[ "$line" == *"[ACTION]"* ]]; then
            log_info "${line#*[ACTION] }"
        elif [[ "$line" == *"[SUCCESS]"* ]]; then
            log_success "${line#*[SUCCESS] }"
        elif [[ "$line" == *"[ERROR]"* ]]; then
            log_error "${line#*[ERROR] }"
        elif [[ "$line" == *"[INFO]"* ]]; then
            log_info "${line#*[INFO] }"
        fi
    done; then
        PATCH_SUCCESS=true
    else
        PATCH_SUCCESS=false
    fi
    
    if [ "$PATCH_SUCCESS" != true ]; then
        log_error "✗ Patching failed"
        cp "${SYSTEMUI_APK}.bak" "$SYSTEMUI_APK"
        cd "$WORKSPACE"
        return 1
    fi
    
    # PHASE 3: REBUILD
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "PHASE 3: APKTOOL REBUILD"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Rebuilding $(basename "$SYSTEMUI_APK")..."
    
    START_TIME=$(date +%s)
    
    if timeout 15m apktool b -c "decompiled" -o "SystemUI_patched.apk" 2>&1 | tee apktool_build.log | grep -q "Built"; then
        END_TIME=$(date +%s)
        BUILD_TIME=$((END_TIME - START_TIME))
        log_success "✓ Rebuild completed in ${BUILD_TIME}s"
        
        if [ -f "SystemUI_patched.apk" ]; then
            PATCHED_SIZE=$(du -h "SystemUI_patched.apk" | cut -f1)
            log_info "Patched APK size: $PATCHED_SIZE"
            
            # Verify size
            ORIG_SIZE=$(stat -c%s "$SYSTEMUI_APK" 2>/dev/null || echo "0")
            NEW_SIZE=$(stat -c%s "SystemUI_patched.apk" 2>/dev/null || echo "0")
            
            if [ "$ORIG_SIZE" -gt 0 ] && [ "$NEW_SIZE" -gt 0 ]; then
                SIZE_DIFF=$((ORIG_SIZE - NEW_SIZE))
                SIZE_PERCENT=$((SIZE_DIFF * 100 / ORIG_SIZE))
                
                log_info "Size check: Original ${ORIG_SIZE} bytes, New ${NEW_SIZE} bytes (${SIZE_PERCENT}% diff)"
                
                if [ "$SIZE_PERCENT" -gt 10 ]; then
                    log_error "✗ File size dropped ${SIZE_PERCENT}% - DATA LOSS!"
                    log_error "ABORTING to prevent corruption"
                    cp "${SYSTEMUI_APK}.bak" "$SYSTEMUI_APK"
                    cd "$WORKSPACE"
                    return 1
                fi
            fi
            
            # Remove signature
            log_info "Removing old signature..."
            zip -q -d "SystemUI_patched.apk" "META-INF/*" 2>&1 || true
            
            # Replace original
            log_info "Installing patched APK..."
            mv "SystemUI_patched.apk" "$SYSTEMUI_APK"
            log_success "✓ Successfully patched!"
            
            log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            log_success "✅ VOLTE ICON ENABLED"
            log_success "   Effect: VoLTE icon will display properly"
            log_success "   Size: $PATCHED_SIZE (preserved!)"
            log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        else
            log_error "✗ Patched APK not created"
            cp "${SYSTEMUI_APK}.bak" "$SYSTEMUI_APK"
        fi
    else
        log_error "✗ Apktool rebuild failed"
        cat apktool_build.log | tail -20 | while read line; do
            log_error "   $line"
        done
        cp "${SYSTEMUI_APK}.bak" "$SYSTEMUI_APK"
    fi
    
    cd "$WORKSPACE"
    return 0
}

# If running standalone
if [ "${BASH_SOURCE[0]}" -ef "$0" ]; then
    patch_systemui_volte "$@"
fi
