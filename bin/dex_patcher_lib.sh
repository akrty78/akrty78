#!/bin/bash

# =========================================================
#  DEX PATCHER LIBRARY - Shared Functions
# =========================================================

# Global variables
export PATCHER_BIN_DIR="$BIN_DIR"
export PATCHER_TEMP_DIR="$TEMP_DIR"

# --- Logging Functions (inherit from main script) ---
# log_info, log_success, log_error, log_warning, log_step are inherited

# --- Extract DEX from APK/JAR ---
extract_dex() {
    local FILE_PATH="$1"
    local WORK_DIR="$2"
    
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "PHASE 1: DEX EXTRACTION"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Extracting DEX files from $(basename "$FILE_PATH")..."
    
    cd "$WORK_DIR"
    
    if unzip -q "$FILE_PATH" "classes*.dex" 2>&1; then
        DEX_COUNT=$(ls -1 classes*.dex 2>/dev/null | wc -l)
        
        if [ "$DEX_COUNT" -gt 0 ]; then
            log_success "✓ Extracted $DEX_COUNT DEX file(s)"
            
            for dex in classes*.dex; do
                DEX_SIZE=$(du -h "$dex" | cut -f1)
                log_info "  - $dex ($DEX_SIZE)"
            done
            
            echo "$DEX_COUNT"
            return 0
        else
            log_error "✗ No DEX files found in archive"
            return 1
        fi
    else
        log_error "✗ Failed to extract DEX files"
        return 1
    fi
}

# --- Decompile DEX with baksmali ---
decompile_dex() {
    local DEX_FILE="$1"
    local OUTPUT_DIR="$2"
    
    # Check if baksmali exists
    if [ ! -f "$PATCHER_BIN_DIR/baksmali.jar" ]; then
        log_error "baksmali.jar not found - cannot decompile"
        log_error "This usually means the download failed during setup"
        return 1
    fi
    
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "PHASE 2: DECOMPILATION (baksmali)"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Decompiling $DEX_FILE with baksmali..."
    
    START_TIME=$(date +%s)
    
    # Create output directory
    mkdir -p "$OUTPUT_DIR"
    
    if java -jar "$PATCHER_BIN_DIR/baksmali.jar" d "$DEX_FILE" -o "$OUTPUT_DIR" 2>&1 | tee baksmali.log; then
        END_TIME=$(date +%s)
        DECOMPILE_TIME=$((END_TIME - START_TIME))
        
        # Verify output
        if [ -d "$OUTPUT_DIR" ]; then
            SMALI_COUNT=$(find "$OUTPUT_DIR" -name "*.smali" 2>/dev/null | wc -l)
            
            if [ "$SMALI_COUNT" -gt 0 ]; then
                log_success "✓ Decompiled successfully in ${DECOMPILE_TIME}s"
                log_info "Generated $SMALI_COUNT smali files"
                echo "$SMALI_COUNT"
                return 0
            else
                log_error "✗ Decompilation produced no smali files"
                log_error "Baksmali output:"
                cat baksmali.log | tail -20 | while IFS= read -r line; do
                    log_error "   $line"
                done
                return 1
            fi
        else
            log_error "✗ Output directory not created"
            return 1
        fi
    else
        END_TIME=$(date +%s)
        DECOMPILE_TIME=$((END_TIME - START_TIME))
        log_error "✗ Baksmali failed (${DECOMPILE_TIME}s)"
        return 1
    fi
}

# --- Recompile smali to DEX ---
recompile_dex() {
    local SMALI_DIR="$1"
    local OUTPUT_DEX="$2"
    
    # Check if smali.jar exists
    if [ ! -f "$PATCHER_BIN_DIR/smali.jar" ]; then
        log_error "smali.jar not found - cannot recompile"
        log_error "This usually means smali.jar was not uploaded to Google Drive"
        log_error "Please upload smali.jar and update SMALI_GDRIVE ID in script"
        return 1
    fi
    
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "PHASE 4: RECOMPILATION (smali)"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Recompiling smali to DEX..."
    
    START_TIME=$(date +%s)
    
    if java -jar "$PATCHER_BIN_DIR/smali.jar" a "$SMALI_DIR" -o "$OUTPUT_DEX" 2>&1 | tee smali.log; then
        END_TIME=$(date +%s)
        COMPILE_TIME=$((END_TIME - START_TIME))
        
        if [ -f "$OUTPUT_DEX" ]; then
            PATCHED_DEX_SIZE=$(du -h "$OUTPUT_DEX" | cut -f1)
            log_success "✓ Recompiled successfully in ${COMPILE_TIME}s"
            log_info "Patched DEX size: $PATCHED_DEX_SIZE"
            return 0
        else
            log_error "✗ Output DEX not created"
            return 1
        fi
    else
        END_TIME=$(date +%s)
        COMPILE_TIME=$((END_TIME - START_TIME))
        log_error "✗ Smali compilation failed (${COMPILE_TIME}s)"
        
        if [ -f "smali.log" ]; then
            log_error "Compilation errors:"
            tail -10 smali.log | while IFS= read -r line; do
                log_error "   $line"
            done
        fi
        return 1
    fi
}

# --- Inject DEX back into APK/JAR ---
inject_dex() {
    local ORIGINAL_FILE="$1"
    local DEX_FILE="$2"
    local TARGET_DEX_NAME="$3"  # e.g., "classes.dex"
    local IS_JAR="$4"           # "true" or "false"
    
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "PHASE 5: DEX INJECTION"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Injecting patched DEX into $(basename "$ORIGINAL_FILE")..."
    
    # Copy original
    local TEMP_FILE="${ORIGINAL_FILE}.tmp"
    cp "$ORIGINAL_FILE" "$TEMP_FILE"
    
    # Remove old DEX
    log_info "Removing original $TARGET_DEX_NAME..."
    zip -q -d "$TEMP_FILE" "$TARGET_DEX_NAME" 2>&1 || true
    
    # Inject new DEX
    log_info "Injecting patched $TARGET_DEX_NAME..."
    cp "$DEX_FILE" "$TARGET_DEX_NAME"
    zip -q -u "$TEMP_FILE" "$TARGET_DEX_NAME" 2>&1
    
    if [ -f "$TEMP_FILE" ]; then
        FINAL_SIZE=$(du -h "$TEMP_FILE" | cut -f1)
        log_success "✓ DEX injection completed"
        log_info "Final file size: $FINAL_SIZE"
        
        # Zipalign for JARs
        if [ "$IS_JAR" == "true" ]; then
            log_info "Optimizing JAR with zipalign..."
            
            if command -v zipalign &> /dev/null; then
                if zipalign -f -p 4 "$TEMP_FILE" "${TEMP_FILE}.aligned" 2>&1; then
                    mv "${TEMP_FILE}.aligned" "$TEMP_FILE"
                    log_success "✓ JAR optimized with zipalign"
                else
                    log_warning "Zipalign failed, using unaligned JAR"
                fi
            else
                log_info "zipalign not available, skipping optimization"
            fi
        fi
        
        # Replace original
        mv "$TEMP_FILE" "$ORIGINAL_FILE"
        return 0
    else
        log_error "✗ DEX injection failed"
        return 1
    fi
}

# --- Find smali file by class path ---
find_smali() {
    local SMALI_DIR="$1"
    local CLASS_PATH="$2"  # e.g., "com/android/settings/InternalDeviceUtils"
    
    local SMALI_FILE=$(find "$SMALI_DIR" -type f -path "*/${CLASS_PATH}.smali" 2>/dev/null | head -n 1)
    
    if [ -f "$SMALI_FILE" ]; then
        echo "$SMALI_FILE"
        return 0
    else
        return 1
    fi
}

# --- Run Python patcher script ---
run_python_patcher() {
    local PATCHER_SCRIPT="$1"
    local SMALI_FILE="$2"
    
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "PHASE 3: METHOD PATCHING"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Executing patcher..."
    
    if python3 "$PATCHER_SCRIPT" "$SMALI_FILE" 2>&1 | while IFS= read -r line; do
        if [[ "$line" == *"[ACTION]"* ]]; then
            log_info "${line#*[ACTION] }"
        elif [[ "$line" == *"[SUCCESS]"* ]]; then
            log_success "${line#*[SUCCESS] }"
        elif [[ "$line" == *"[ERROR]"* ]]; then
            log_error "${line#*[ERROR] }"
        else
            echo "         $line"
        fi
    done; then
        return 0
    else
        return 1
    fi
}

# --- Complete DEX patching workflow ---
patch_dex_file() {
    local FILE_PATH="$1"
    local WORK_DIR="$2"
    local TARGET_CLASS="$3"
    local PATCHER_SCRIPT="$4"
    local IS_JAR="${5:-false}"
    
    # CRITICAL: Save current directory
    local ORIGINAL_DIR="$PWD"
    
    log_info "File: $(basename "$FILE_PATH")"
    log_info "Size: $(du -h "$FILE_PATH" | cut -f1)"
    
    # Backup
    log_info "Creating backup..."
    cp "$FILE_PATH" "${FILE_PATH}.bak"
    log_success "✓ Backup created"
    
    cd "$WORK_DIR"
    
    # Extract DEX
    if ! extract_dex "$FILE_PATH" "$WORK_DIR"; then
        cd "$ORIGINAL_DIR"
        return 1
    fi
    
    # Search ALL DEX files for target class
    log_info "Searching for target class across all DEX files..."
    TARGET_DEX=""
    CLASS_SMALI_PATH="${TARGET_CLASS}.smali"
    
    for dex in classes*.dex; do
        if [ ! -f "$dex" ]; then
            continue
        fi
        
        log_info "Checking $dex..."
        
        # Quick decompile to test
        rm -rf "smali_test" 2>/dev/null
        if java -jar "$PATCHER_BIN_DIR/baksmali.jar" d "$dex" -o "smali_test" &>/dev/null; then
            # Check if target class exists (handle both / and filesystem paths)
            FOUND=$(find "smali_test" -name "$(basename "$CLASS_SMALI_PATH")" -path "*${TARGET_CLASS}.smali" 2>/dev/null | head -n 1)
            
            if [ ! -z "$FOUND" ]; then
                TARGET_DEX="$dex"
                log_success "✓ Target class found in $dex"
                rm -rf "smali_test"
                break
            fi
            rm -rf "smali_test"
        fi
    done
    
    if [ -z "$TARGET_DEX" ]; then
        log_error "✗ Class $TARGET_CLASS not found in any DEX file"
        cd "$ORIGINAL_DIR"
        return 1
    fi
    
    # Decompile the correct DEX
    if ! decompile_dex "$TARGET_DEX" "smali_out"; then
        cd "$ORIGINAL_DIR"
        return 1
    fi
    
    # Find target smali
    log_info "Searching for target class..."
    SMALI_FILE=$(find_smali "smali_out" "$TARGET_CLASS")
    
    if [ -z "$SMALI_FILE" ]; then
        log_error "✗ Class not found: $TARGET_CLASS"
        cd "$ORIGINAL_DIR"
        return 1
    fi
    
    SMALI_REL_PATH=$(echo "$SMALI_FILE" | sed "s|smali_out/||")
    log_success "✓ Found: $SMALI_REL_PATH"
    
    # Patch
    if ! run_python_patcher "$PATCHER_SCRIPT" "$SMALI_FILE"; then
        cd "$ORIGINAL_DIR"
        return 1
    fi
    
    # Recompile
    if ! recompile_dex "smali_out" "classes_patched.dex"; then
        cd "$ORIGINAL_DIR"
        return 1
    fi
    
    # Inject
    if ! inject_dex "$FILE_PATH" "classes_patched.dex" "$TARGET_DEX" "$IS_JAR"; then
        cd "$ORIGINAL_DIR"
        return 1
    fi
    
    log_success "✓ Patching completed successfully!"
    
    # CRITICAL: Return to original directory
    cd "$ORIGINAL_DIR"
    
    return 0
}

export -f extract_dex
export -f decompile_dex
export -f recompile_dex
export -f inject_dex
export -f find_smali
export -f run_python_patcher
export -f patch_dex_file
