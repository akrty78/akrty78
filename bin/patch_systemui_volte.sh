#!/bin/bash

# =========================================================
#  SYSTEMUI VOLTE ICON ENABLER
#  Patches SystemUI.apk to enable VoLTE icon display
# =========================================================

patch_systemui_volte() {
    local SYSTEM_EXT_DUMP="$1"
    
    # CRITICAL: Save workspace
    local WORKSPACE="$GITHUB_WORKSPACE"
    
    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_step "📶 SYSTEMUI VOLTE ICON PATCH"
    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Find SystemUI.apk (try multiple names)
    log_info "Searching for SystemUI..."
    
    SYSTEMUI_APK=""
    
    # Try MiuiSystemUI first (more common in MIUI)
    SYSTEMUI_APK=$(find "$SYSTEM_EXT_DUMP" -name "MiuiSystemUI.apk" -type f | head -n 1)
    
    if [ -z "$SYSTEMUI_APK" ]; then
        # Try standard SystemUI
        SYSTEMUI_APK=$(find "$SYSTEM_EXT_DUMP" -name "SystemUI.apk" -type f | head -n 1)
    fi
    
    if [ -z "$SYSTEMUI_APK" ]; then
        log_warning "⚠️  SystemUI.apk or MiuiSystemUI.apk not found"
        cd "$WORKSPACE"
        return 0
    fi
    
    log_success "✓ Found: $(basename "$SYSTEMUI_APK")"
    log_info "Located: $SYSTEMUI_APK"
    
    # Target classes
    TARGET_CLASSES=(
        "com/android/systemui/MiuiOperatorCustomizedPolicy"
        "com/android/systemui/statusbar/pipeline/mobile/ui/viewmodel/MiuiCellularIconVM\$special\$\$inlined\$combine\$1\$3"
        "com/android/systemui/statusbar/pipeline/mobile/ui/binder/MiuiMobileIconBinder\$bind\$1\$1\$10"
    )
    
    # Create patcher script
    PATCHER_SCRIPT="$TEMP_DIR/systemui_volte_patcher.py"
    cat > "$PATCHER_SCRIPT" <<'PYTHON_EOF'
#!/usr/bin/env python3
import sys
import re
import os

def patch_volte_class(filepath):
    """Patch VoLTE icon by adding const after IS_INTERNATIONAL_BUILD check"""
    
    filename = os.path.basename(filepath)
    
    print(f"[ACTION] Processing: {filename}")
    
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()
    
    original_content = content
    
    # Pattern: find sget-boolean vX, Lmiui/os/Build;->IS_INTERNATIONAL_BUILD:Z
    pattern = r'(sget-boolean\s+(v\d+),\s+Lmiui/os/Build;->IS_INTERNATIONAL_BUILD:Z)'
    
    matches = list(re.finditer(pattern, content))
    
    if not matches:
        print(f"[INFO] No IS_INTERNATIONAL_BUILD found in {filename}")
        return False
    
    print(f"[ACTION] Found {len(matches)} IS_INTERNATIONAL_BUILD reference(s)")
    
    # For each match, add const/4 vX, 0x1 on the next line
    offset = 0
    for match in matches:
        var = match.group(2)  # Extract variable (e.g., v0, v1, v2)
        match_end = match.end() + offset
        
        # Find the end of the line
        newline_pos = content.find('\n', match_end)
        if newline_pos == -1:
            newline_pos = len(content)
        
        # Insert const line after the sget-boolean line
        insert_line = f"\n    const/4 {var}, 0x1"
        content = content[:newline_pos] + insert_line + content[newline_pos:]
        offset += len(insert_line)
        
        print(f"[ACTION] Added: const/4 {var}, 0x1")
    
    if content != original_content:
        with open(filepath, 'w', encoding='utf-8') as f:
            f.write(content)
        print(f"[SUCCESS] Patched {filename}")
        return True
    
    return False

def main(smali_dir, target_classes):
    """Patch target classes in smali directory"""
    
    patched_count = 0
    not_found = []
    
    for target_class in target_classes:
        # Convert class path to file path
        class_file = target_class.replace('.', '/').replace('$', '$') + '.smali'
        
        # Search for the file
        filepath = None
        for root, dirs, files in os.walk(smali_dir):
            potential_path = os.path.join(root, os.path.basename(class_file))
            if os.path.exists(potential_path):
                filepath = potential_path
                break
        
        if filepath:
            if patch_volte_class(filepath):
                patched_count += 1
        else:
            not_found.append(os.path.basename(class_file))
            print(f"[INFO] Class not found (skipping): {os.path.basename(class_file)}")
    
    print(f"[SUCCESS] Patched {patched_count} class(es)")
    if not_found:
        print(f"[INFO] Not found: {', '.join(not_found)}")
    
    return patched_count > 0

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("[ERROR] Usage: systemui_volte_patcher.py <smali_dir> <class1> [class2] ...")
        sys.exit(1)
    
    smali_dir = sys.argv[1]
    target_classes = sys.argv[2:]
    
    success = main(smali_dir, target_classes)
    sys.exit(0 if success else 1)
PYTHON_EOF
    
    chmod +x "$PATCHER_SCRIPT"
    
    # Create work directory
    WORK_DIR="$TEMP_DIR/systemui_work"
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"
    
    cd "$WORK_DIR"
    
    # Extract DEX
    log_info "Extracting DEX files..."
    unzip -q "$SYSTEMUI_APK" "classes*.dex" 2>&1
    
    # Decompile (SystemUI usually has multiple DEX files)
    log_info "Decompiling all DEX files..."
    for dex in classes*.dex; do
        if [ -f "$dex" ]; then
            dex_num=$(echo "$dex" | sed 's/classes\([0-9]*\)\.dex/\1/')
            if [ -z "$dex_num" ]; then
                out_dir="smali"
            else
                out_dir="smali_classes${dex_num}"
            fi
            
            mkdir -p "$out_dir"
            java -jar "$BIN_DIR/baksmali.jar" d "$dex" -o "$out_dir" 2>&1 | tee -a baksmali.log
        fi
    done
    
    SMALI_COUNT=$(find smali* -name "*.smali" 2>/dev/null | wc -l)
    log_success "✓ Decompiled $SMALI_COUNT smali files"
    
    # Patch
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "PHASE 3: VOLTE PATCHING"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    if python3 "$PATCHER_SCRIPT" "." "${TARGET_CLASSES[@]}" 2>&1 | while IFS= read -r line; do
        if [[ "$line" == *"[ACTION]"* ]]; then
            log_info "${line#*[ACTION] }"
        elif [[ "$line" == *"[SUCCESS]"* ]]; then
            log_success "${line#*[SUCCESS] }"
        elif [[ "$line" == *"[INFO]"* ]]; then
            log_info "${line#*[INFO] }"
        elif [[ "$line" == *"[ERROR]"* ]]; then
            log_error "${line#*[ERROR] }"
        fi
    done; then
        
        # Recompile all DEX files
        log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_info "PHASE 4: RECOMPILATION"
        log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        for smali_dir in smali*; do
            if [ -d "$smali_dir" ]; then
                if [ "$smali_dir" == "smali" ]; then
                    out_dex="classes.dex"
                else
                    dex_num=$(echo "$smali_dir" | sed 's/smali_classes//')
                    out_dex="classes${dex_num}.dex"
                fi
                
                log_info "Recompiling $smali_dir → $out_dex..."
                java -jar "$BIN_DIR/smali.jar" a "$smali_dir" -o "${out_dex}.new" --api 35 2>&1 | tee -a smali.log
                
                if [ -f "${out_dex}.new" ]; then
                    mv "${out_dex}.new" "$out_dex"
                    log_success "✓ Recompiled $out_dex"
                fi
            fi
        done
        
        # Inject back
        log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_info "PHASE 5: DEX INJECTION"
        log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        cp "$SYSTEMUI_APK" "${SYSTEMUI_APK}.tmp"
        
        for dex in classes*.dex; do
            if [ -f "$dex" ]; then
                log_info "Injecting $dex..."
                zip -q -d "${SYSTEMUI_APK}.tmp" "$dex" 2>&1 || true
                zip -q -u "${SYSTEMUI_APK}.tmp" "$dex" 2>&1
            fi
        done
        
        mv "${SYSTEMUI_APK}.tmp" "$SYSTEMUI_APK"
        
        log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_success "✅ VOLTE ICON ENABLED"
        log_success "   Effect: VoLTE icon will display properly"
        log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    else
        log_error "✗ VoLTE patching failed"
        cp "${SYSTEMUI_APK}.bak" "$SYSTEMUI_APK"
    fi
    
    cd "$WORKSPACE"
    rm -rf "$WORK_DIR"
}

# Export function
export -f patch_systemui_volte
