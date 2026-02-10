#!/bin/bash

# =========================================================
#  APKTOOL-BASED PATCHER LIBRARY
#  Like MiuiBooster - NO DATA LOSS!
# =========================================================

# This library uses apktool for ALL patching operations
# Unlike baksmali/smali which loses data, apktool preserves EVERYTHING

# --- Patch APK/JAR using apktool (NO DATA LOSS) ---
patch_apk_with_apktool() {
    local FILE_PATH="$1"          # APK or JAR to patch
    local TARGET_CLASS="$2"        # e.g., "com/android/settings/InternalDeviceUtils"
    local PATCHER_SCRIPT="$3"      # Python script to patch the smali
    local WORK_DIR="${4:-$TEMP_DIR/apktool_work_$$}"
    
    # CRITICAL: Save original directory
    local ORIGINAL_DIR="$PWD"
    
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "APKTOOL PATCHING: $(basename "$FILE_PATH")"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "File: $(basename "$FILE_PATH")"
    log_info "Size: $(du -h "$FILE_PATH" | cut -f1)"
    
    # Backup
    log_info "Creating backup..."
    cp "$FILE_PATH" "${FILE_PATH}.bak"
    log_success "✓ Backup created"
    
    # Setup working directory
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"
    
    # PHASE 1: DECOMPILE WITH APKTOOL
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "PHASE 1: APKTOOL DECOMPILATION"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    START_TIME=$(date +%s)
    
    # -r = no resources decoding (faster, we only need smali)
    # -f = force overwrite
    if timeout 5m apktool d -r -f "$FILE_PATH" -o "decompiled" 2>&1 | tee apktool_decompile.log | grep -q "I: Baksmaling"; then
        END_TIME=$(date +%s)
        DECOMPILE_TIME=$((END_TIME - START_TIME))
        log_success "✓ Decompiled successfully in ${DECOMPILE_TIME}s"
        
        # Count smali files
        SMALI_COUNT=$(find "decompiled" -name "*.smali" | wc -l)
        log_info "Decompiled $SMALI_COUNT smali files"
    else
        log_error "✗ Apktool decompilation failed"
        cat apktool_decompile.log | tail -20 | while read line; do
            log_error "   $line"
        done
        cd "$ORIGINAL_DIR"
        return 1
    fi
    
    # PHASE 2: FIND TARGET CLASS
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "PHASE 2: LOCATING TARGET CLASS"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Searching for: $TARGET_CLASS"
    
    SMALI_FILE=$(find "decompiled" -type f -path "*/${TARGET_CLASS}.smali" | head -n 1)
    
    if [ ! -f "$SMALI_FILE" ]; then
        log_error "✗ Class not found: $TARGET_CLASS"
        log_info "Searched in: decompiled/"
        cd "$ORIGINAL_DIR"
        return 1
    fi
    
    SMALI_REL_PATH=$(echo "$SMALI_FILE" | sed "s|decompiled/||")
    log_success "✓ Found: $SMALI_REL_PATH"
    
    # PHASE 3: PATCH SMALI
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "PHASE 3: PATCHING SMALI"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    if python3 "$PATCHER_SCRIPT" "$SMALI_FILE" 2>&1 | while IFS= read -r line; do
        if [[ "$line" == *"[ACTION]"* ]]; then
            log_info "${line#*[ACTION] }"
        elif [[ "$line" == *"[SUCCESS]"* ]]; then
            log_success "${line#*[SUCCESS] }"
        elif [[ "$line" == *"[ERROR]"* ]]; then
            log_error "${line#*[ERROR] }"
        fi
    done; then
        log_success "✓ Patching completed"
    else
        log_error "✗ Patching failed"
        cd "$ORIGINAL_DIR"
        return 1
    fi
    
    # PHASE 4: REBUILD WITH APKTOOL
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "PHASE 4: APKTOOL REBUILD"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Rebuilding $(basename "$FILE_PATH")..."
    
    START_TIME=$(date +%s)
    
    # -c = copy original files (META-INF, resources, etc.)
    if timeout 10m apktool b -c "decompiled" -o "$(basename "$FILE_PATH").new" 2>&1 | tee apktool_build.log | grep -q "Built"; then
        END_TIME=$(date +%s)
        BUILD_TIME=$((END_TIME - START_TIME))
        log_success "✓ Rebuild completed in ${BUILD_TIME}s"
        
        if [ -f "$(basename "$FILE_PATH").new" ]; then
            PATCHED_SIZE=$(du -h "$(basename "$FILE_PATH").new" | cut -f1)
            log_info "Patched file size: $PATCHED_SIZE"
            
            # CRITICAL: Verify size hasn't dropped significantly
            ORIG_SIZE=$(stat -c%s "$FILE_PATH" 2>/dev/null || echo "0")
            NEW_SIZE=$(stat -c%s "$(basename "$FILE_PATH").new" 2>/dev/null || echo "0")
            
            if [ "$ORIG_SIZE" -gt 0 ] && [ "$NEW_SIZE" -gt 0 ]; then
                SIZE_DIFF=$((ORIG_SIZE - NEW_SIZE))
                SIZE_PERCENT=$((SIZE_DIFF * 100 / ORIG_SIZE))
                
                if [ "$SIZE_PERCENT" -gt 5 ]; then
                    log_warning "File size changed by ${SIZE_PERCENT}%"
                    log_warning "Original: $ORIG_SIZE bytes, New: $NEW_SIZE bytes"
                    
                    if [ "$SIZE_PERCENT" -gt 10 ]; then
                        log_error "✗ File size dropped >10% - possible data loss!"
                        log_error "ABORTING to prevent corruption"
                        cd "$ORIGINAL_DIR"
                        return 1
                    fi
                fi
            fi
            
            # Remove old signature (prevents "verified failed by V1" error)
            log_info "Removing old signature..."
            zip -q -d "$(basename "$FILE_PATH").new" "META-INF/*" 2>&1 || true
            
            # Replace original
            log_info "Installing patched file..."
            mv "$(basename "$FILE_PATH").new" "$FILE_PATH"
            log_success "✓ Successfully patched!"
            
            cd "$ORIGINAL_DIR"
            return 0
        else
            log_error "✗ Patched file not created"
            cd "$ORIGINAL_DIR"
            return 1
        fi
    else
        log_error "✗ Apktool rebuild failed"
        cat apktool_build.log | tail -20 | while read line; do
            log_error "   $line"
        done
        cd "$ORIGINAL_DIR"
        return 1
    fi
}

export -f patch_apk_with_apktool
