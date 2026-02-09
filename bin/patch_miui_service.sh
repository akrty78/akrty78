#!/bin/bash

# =========================================================
#  MIUI SERVICE CN→GLOBAL PATCHER
#  Complex multi-class/method patcher for MIUI features
# =========================================================

patch_miui_service() {
    local SYSTEM_EXT_DUMP="$1"
    
    # CRITICAL: Save workspace
    local WORKSPACE="$GITHUB_WORKSPACE"
    
    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_step "🌏 MIUI SERVICE CN→GLOBAL PATCH"
    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Find miui-service.jar (search in multiple locations)
    log_info "Searching for miui-service.jar..."
    
    MIUI_SERVICE_JAR=$(find "$SYSTEM_EXT_DUMP" -name "miui-service*.jar" -type f | head -n 1)
    
    if [ -z "$MIUI_SERVICE_JAR" ]; then
        log_warning "⚠️  miui-service.jar not found in system_ext"
        log_info "This may be normal for some ROM versions"
        cd "$WORKSPACE"
        return 0
    fi
    
    log_success "✓ Found: $(basename "$MIUI_SERVICE_JAR")"
    log_info "Located: $MIUI_SERVICE_JAR"
    
    # Create complex multi-patcher script
    PATCHER_SCRIPT="$TEMP_DIR/miui_service_patcher.py"
    cat > "$PATCHER_SCRIPT" <<'PYTHON_EOF'
#!/usr/bin/env python3
import sys
import re
import os

def patch_is_international_build(content):
    """Replace sget-boolean vX, Lmiui/os/Build;->IS_INTERNATIONAL_BUILD:Z with const/4 vX, 0x1"""
    pattern = r'sget-boolean\s+(v\d+),\s+Lmiui/os/Build;->IS_INTERNATIONAL_BUILD:Z'
    count = len(re.findall(pattern, content))
    if count > 0:
        print(f"[ACTION] Patching {count} IS_INTERNATIONAL_BUILD reference(s)")
        content = re.sub(pattern, r'const/4 \1, 0x1', content)
    return content, count

def patch_is_tablet(content):
    """Replace sget-boolean vX, Lmiui/os/Build;->IS_TABLET:Z with const/4 vX, 0x1"""
    pattern = r'sget-boolean\s+(v\d+),\s+Lmiui/os/Build;->IS_TABLET:Z'
    count = len(re.findall(pattern, content))
    if count > 0:
        print(f"[ACTION] Patching {count} IS_TABLET reference(s)")
        content = re.sub(pattern, r'const/4 \1, 0x1', content)
    return content, count

def make_method_return_true(content, method_name):
    """Make a method return true (0x1)"""
    new_method = f""".method public static {method_name}
    .registers 1

    const/4 v0, 0x1

    return v0
.end method"""
    
    pattern = rf'\.method\s+public\s+static\s+{re.escape(method_name)}.*?\.end\s+method'
    matches = re.findall(pattern, content, flags=re.DOTALL)
    
    if matches:
        print(f"[ACTION] Making {method_name} return true")
        content = re.sub(pattern, new_method, content, flags=re.DOTALL)
        return content, 1
    return content, 0

def patch_smali_file(filepath):
    """Patch a single smali file with all applicable patches"""
    
    filename = os.path.basename(filepath)
    
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()
    
    original_content = content
    total_patches = 0
    
    # Apply all patches
    content, count = patch_is_international_build(content)
    total_patches += count
    
    content, count = patch_is_tablet(content)
    total_patches += count
    
    # Check for specific methods
    if 'isAutoStartRestriction' in content:
        content, count = make_method_return_true(content, 'isAutoStartRestriction\(.*?\)Z')
        total_patches += count
    
    if 'supportNearby' in content:
        content, count = make_method_return_true(content, 'supportNearby\(.*?\)Z')
        total_patches += count
    
    if 'isPreciseLocationMode' in content:
        content, count = make_method_return_true(content, 'isPreciseLocationMode\(.*?\)Z')
        total_patches += count
    
    if 'isHideFiveGAndNetwork' in content:
        content, count = make_method_return_true(content, 'isHideFiveGAndNetwork\(.*?\)Z')
        total_patches += count
    
    # Write back if changed
    if content != original_content:
        with open(filepath, 'w', encoding='utf-8') as f:
            f.write(content)
        print(f"[SUCCESS] Patched {filename}: {total_patches} change(s)")
        return True
    
    return False

def main(smali_dir):
    """Recursively patch all smali files"""
    
    print(f"[ACTION] Scanning smali directory: {smali_dir}")
    
    total_files_patched = 0
    
    for root, dirs, files in os.walk(smali_dir):
        for file in files:
            if file.endswith('.smali'):
                filepath = os.path.join(root, file)
                
                # Only process relevant files
                if any(keyword in filepath for keyword in [
                    'AppOpsManager',
                    'InputFeature',
                    'FeatureConfiguration',
                    'AutoStart',
                    'Nearby',
                    'Location',
                    'Network'
                ]):
                    if patch_smali_file(filepath):
                        total_files_patched += 1
    
    print(f"[SUCCESS] Patched {total_files_patched} file(s) total")
    return total_files_patched > 0

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("[ERROR] Usage: miui_service_patcher.py <smali_dir>")
        sys.exit(1)
    
    smali_dir = sys.argv[1]
    success = main(smali_dir)
    sys.exit(0 if success else 1)
PYTHON_EOF
    
    chmod +x "$PATCHER_SCRIPT"
    
    # Create work directory
    WORK_DIR="$TEMP_DIR/miui_service_work"
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"
    
    cd "$WORK_DIR"
    
    log_info "Extracting and decompiling miui-service.jar..."
    
    # Extract DEX
    unzip -q "$MIUI_SERVICE_JAR" "classes*.dex" 2>&1
    
    if [ ! -f "classes.dex" ]; then
        log_error "✗ Failed to extract DEX"
        return 1
    fi
    
    # Decompile
    mkdir -p "smali_out"
    if ! java -jar "$BIN_DIR/baksmali.jar" d "classes.dex" -o "smali_out" 2>&1 | tee baksmali.log; then
        log_error "✗ Baksmali decompilation failed"
        return 1
    fi
    
    SMALI_COUNT=$(find smali_out -name "*.smali" 2>/dev/null | wc -l)
    log_success "✓ Decompiled $SMALI_COUNT smali files"
    
    # Patch all files
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "PHASE 3: MULTI-CLASS PATCHING"
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
            
            # Inject back
            log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            log_info "PHASE 5: INJECTION & OPTIMIZATION"
            log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            
            cp "$MIUI_SERVICE_JAR" "${MIUI_SERVICE_JAR}.tmp"
            zip -q -d "${MIUI_SERVICE_JAR}.tmp" "classes.dex"
            cp "classes_patched.dex" "classes.dex"
            zip -q -u "${MIUI_SERVICE_JAR}.tmp" "classes.dex"
            
            # Zipalign
            if command -v zipalign &> /dev/null; then
                if zipalign -f -p 4 "${MIUI_SERVICE_JAR}.tmp" "${MIUI_SERVICE_JAR}.aligned" 2>&1; then
                    mv "${MIUI_SERVICE_JAR}.aligned" "${MIUI_SERVICE_JAR}.tmp"
                    log_success "✓ JAR optimized with zipalign"
                fi
            fi
            
            mv "${MIUI_SERVICE_JAR}.tmp" "$MIUI_SERVICE_JAR"
            
            log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            log_success "✅ MIUI SERVICE PATCHED (CN→GLOBAL)"
            log_success "   Features: AutoStart, Nearby, Location, Network"
            log_success "   Effect: Global ROM features enabled"
            log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        else
            log_error "✗ Smali recompilation failed"
            cp "${MIUI_SERVICE_JAR}.bak" "$MIUI_SERVICE_JAR"
        fi
    else
        log_error "✗ Patching failed"
        cp "${MIUI_SERVICE_JAR}.bak" "$MIUI_SERVICE_JAR"
    fi
    
    cd "$WORKSPACE"
    rm -rf "$WORK_DIR"
}

# Export function
export -f patch_miui_service
