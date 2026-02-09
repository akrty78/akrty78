#!/bin/bash

# =========================================================
#  AI VOICE RECORDER ENABLER
#  Patches voice recorder app to enable AI features
# =========================================================

patch_voice_recorder() {
    local SYSTEM_DUMP="$1"
    
    # CRITICAL: Save workspace
    local WORKSPACE="$GITHUB_WORKSPACE"
    
    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_step "🎙️  AI VOICE RECORDER PATCH"
    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Find voice recorder APK by package name
    log_info "Searching for voice recorder app (package: com.android.soundrecorder)..."
    
    RECORDER_APK=""
    
    # Search all APKs for the target package
    while IFS= read -r apk_file; do
        if [ -f "$apk_file" ]; then
            pkg_name=$(aapt dump badging "$apk_file" 2>/dev/null | grep "package: name=" | cut -d"'" -f2)
            if [ "$pkg_name" == "com.android.soundrecorder" ]; then
                RECORDER_APK="$apk_file"
                log_success "✓ Found: $(basename "$RECORDER_APK") (package: $pkg_name)"
                break
            fi
        fi
    done < <(find "$SYSTEM_DUMP" -name "*.apk" -type f)
    
    if [ -z "$RECORDER_APK" ]; then
        log_warning "⚠️  Voice recorder app not found (package: com.android.soundrecorder)"
        cd "$WORKSPACE"
        return 0
    fi
    
    log_info "Located: $RECORDER_APK"
    
    # Create patcher script
    PATCHER_SCRIPT="$TEMP_DIR/voice_recorder_patcher.py"
    cat > "$PATCHER_SCRIPT" <<'PYTHON_EOF'
#!/usr/bin/env python3
import sys
import re
import os

def find_and_patch_ai_record(smali_dir):
    """Find isAiRecordEnable method across all smali files and patch it"""
    
    print(f"[ACTION] Searching for isAiRecordEnable method...")
    
    patched = False
    
    for root, dirs, files in os.walk(smali_dir):
        for file in files:
            if not file.endswith('.smali'):
                continue
            
            filepath = os.path.join(root, file)
            
            with open(filepath, 'r', encoding='utf-8') as f:
                content = f.read()
            
            # Check if this file contains isAiRecordEnable
            if 'isAiRecordEnable' not in content:
                continue
            
            print(f"[ACTION] Found isAiRecordEnable in {file}")
            
            original_content = content
            
            # New method that always returns true
            new_method = """.method public static isAiRecordEnable()Z
    .registers 1

    const/4 v0, 0x1

    return v0
.end method"""
            
            # Pattern to match the method
            pattern = r'\.method\s+public\s+static\s+isAiRecordEnable\(\)Z.*?\.end\s+method'
            
            matches = re.findall(pattern, content, flags=re.DOTALL)
            if matches:
                orig_lines = matches[0].count('\n') + 1
                print(f"[ACTION] Found method ({orig_lines} lines)")
                
                # Replace
                new_content = re.sub(pattern, new_method, content, flags=re.DOTALL)
                
                if new_content != original_content:
                    with open(filepath, 'w', encoding='utf-8') as f:
                        f.write(new_content)
                    
                    print(f"[SUCCESS] Patched isAiRecordEnable in {file}")
                    patched = True
                    break
    
    if not patched:
        print("[ERROR] isAiRecordEnable method not found in any smali file")
        return False
    
    return True

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("[ERROR] Usage: voice_recorder_patcher.py <smali_dir>")
        sys.exit(1)
    
    smali_dir = sys.argv[1]
    success = find_and_patch_ai_record(smali_dir)
    sys.exit(0 if success else 1)
PYTHON_EOF
    
    chmod +x "$PATCHER_SCRIPT"
    
    # Create work directory
    WORK_DIR="$TEMP_DIR/recorder_work"
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"
    
    cd "$WORK_DIR"
    
    # Backup
    cp "$RECORDER_APK" "${RECORDER_APK}.bak"
    log_success "✓ Backup created"
    
    # Extract DEX
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "PHASE 1: DEX EXTRACTION"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    unzip -q "$RECORDER_APK" "classes*.dex" 2>&1
    DEX_COUNT=$(ls -1 classes*.dex 2>/dev/null | wc -l)
    
    if [ "$DEX_COUNT" -eq 0 ]; then
        log_error "✗ No DEX files found"
        return 1
    fi
    
    log_success "✓ Extracted $DEX_COUNT DEX file(s)"
    
    # Decompile
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "PHASE 2: DECOMPILATION"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    mkdir -p "smali_out"
    java -jar "$BIN_DIR/baksmali.jar" d "classes.dex" -o "smali_out" 2>&1 | tee baksmali.log
    
    SMALI_COUNT=$(find smali_out -name "*.smali" 2>/dev/null | wc -l)
    log_success "✓ Decompiled $SMALI_COUNT smali files"
    
    # Patch
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "PHASE 3: AI METHOD PATCHING"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    if python3 "$PATCHER_SCRIPT" "smali_out" 2>&1 | while IFS= read -r line; do
        if [[ "$line" == *"[ACTION]"* ]]; then
            log_info "${line#*[ACTION] }"
        elif [[ "$line" == *"[SUCCESS]"* ]]; then
            log_success "${line#*[SUCCESS] }"
        elif [[ "$line" == *"[ERROR]"* ]]; then
            log_error "${line#*[ERROR] }"
        fi
    done; then
        
        # Recompile
        log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_info "PHASE 4: RECOMPILATION"
        log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        if java -jar "$BIN_DIR/smali.jar" a "smali_out" -o "classes_patched.dex" 2>&1 | tee smali.log; then
            log_success "✓ Recompiled successfully"
            
            # Inject
            log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            log_info "PHASE 5: DEX INJECTION"
            log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            
            cp "$RECORDER_APK" "${RECORDER_APK}.tmp"
            zip -q -d "${RECORDER_APK}.tmp" "classes.dex"
            cp "classes_patched.dex" "classes.dex"
            zip -q -u "${RECORDER_APK}.tmp" "classes.dex"
            
            mv "${RECORDER_APK}.tmp" "$RECORDER_APK"
            
            log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            log_success "✅ AI VOICE RECORDER ENABLED"
            log_success "   Method: isAiRecordEnable() → Always True"
            log_success "   Effect: AI recording features unlocked"
            log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        else
            log_error "✗ Recompilation failed"
            cp "${RECORDER_APK}.bak" "$RECORDER_APK"
        fi
    else
        log_error "✗ Patching failed"
        cp "${RECORDER_APK}.bak" "$RECORDER_APK"
    fi
    
    cd "$WORKSPACE"
    rm -rf "$WORK_DIR"
}

# Export function
export -f patch_voice_recorder
