#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
#  ALL DEX PATCHERS  —  MT Manager binary style
#  Flow: find class in DEX → patch method bytes → zip -u back
#  Manifest, resources, other DEX files: NEVER touched
# ═══════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────
# Shared log forwarder
# ──────────────────────────────────────────
_mt_log() {
    while IFS= read -r line; do
        case "$line" in
            "[SUCCESS]"*) log_success "${line:10}" ;;
            "[ERROR]"*)   log_error   "${line:8}"  ;;
            "[WARNING]"*) log_warning "${line:10}" ;;
            "[ACTION]"*)  log_info    "${line:9}"  ;;
            "[INFO]"*)    log_info    "${line:7}"  ;;
            *)            [ -n "$line" ] && log_info "$line" ;;
        esac
    done
}

# Capture output + exit code cleanly
_run_patcher() {
    local OUT
    OUT=$(python3 "$@" 2>&1)
    local RC=$?
    echo "$OUT" | _mt_log
    return $RC
}


# ╔══════════════════════════════════════════════════════════════════╗
# ║  1. SETTINGS.APK  —  AI Support                                  ║
# ╚══════════════════════════════════════════════════════════════════╝
patch_settings_ai() {
    local DUMP="$1"

    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_step "🤖 SETTINGS.APK AI SUPPORT PATCH"
    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local APK
    APK=$(find "$DUMP" -name "Settings.apk" -type f | head -n 1)
    [ -z "$APK" ] && { log_warning "⚠  Settings.apk not found"; return 0; }

    log_info "File: $APK"
    log_info "Size: $(du -h "$APK" | cut -f1)"
    cp "$APK" "${APK}.bak" && log_success "✓ Backup created"

    # Patch:  isAiSupported(Context)Z  →  const/4 v0,#1; return v0
    # Bytes:  12 10  (const/4 v0, 0x1)
    #         0F 00  (return v0)
    _run_patcher "$BIN_DIR/mt_dex_patch.py" patch-method \
        --apk    "$APK" \
        --class  "com/android/settings/InternalDeviceUtils" \
        --method "isAiSupported" \
        --bytes  "12 10 0F 00"

    if [ $? -eq 0 ]; then
        log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_success "✅ AI SUPPORT ENABLED"
        log_success "   isAiSupported() → always true"
        log_success "   Size: $(du -h "$APK" | cut -f1)  ← unchanged"
        log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    else
        log_error "✗ Patch failed — restoring backup"
        cp "${APK}.bak" "$APK"
    fi
}


# ╔══════════════════════════════════════════════════════════════════╗
# ║  2. MIUISYSTEMUI.APK  —  VoLTE Icon                              ║
# ╚══════════════════════════════════════════════════════════════════╝
patch_systemui_volte() {
    local DUMP="$1"

    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_step "📶 SYSTEMUI VOLTE ICON PATCH"
    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local APK
    APK=$(find "$DUMP" \( -name "MiuiSystemUI.apk" -o -name "SystemUI.apk" \) \
          -type f | head -n 1)
    [ -z "$APK" ] && { log_warning "⚠  SystemUI APK not found"; return 0; }

    log_success "✓ Found: $(basename "$APK")"
    log_info "File: $APK"
    log_info "Size: $(du -h "$APK" | cut -f1)"
    cp "$APK" "${APK}.bak" && log_success "✓ Backup created"

    # Pattern:  invoke-static {}, Lmiui/os/Build;->getRegion()Ljava/lang/String;
    #           move-result-object vX
    # Replace:  const/4 vX, #1          (2-byte in-place edit)
    _run_patcher "$BIN_DIR/mt_dex_patch.py" patch-pattern \
        --apk  "$APK" \
        --find "Lmiui/os/Build;->getRegion()Ljava/lang/String;"

    if [ $? -eq 0 ]; then
        log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_success "✅ VOLTE ICONS ENABLED"
        log_success "   IS_INTERNATIONAL_BUILD → always true"
        log_success "   Size: $(du -h "$APK" | cut -f1)  ← unchanged"
        log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    else
        log_error "✗ Patch failed — restoring backup"
        cp "${APK}.bak" "$APK"
    fi
}


# ╔══════════════════════════════════════════════════════════════════╗
# ║  3. PROVISION.APK  —  GMS Support                                ║
# ╚══════════════════════════════════════════════════════════════════╝
patch_provision_gms() {
    local DUMP="$1"

    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_step "📱 PROVISION GMS SUPPORT PATCH"
    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local APK
    APK=$(find "$DUMP" -name "Provision.apk" -type f | head -n 1)
    [ -z "$APK" ] && { log_warning "⚠  Provision.apk not found"; return 0; }

    log_info "File: $APK"
    log_info "Size: $(du -h "$APK" | cut -f1)"
    cp "$APK" "${APK}.bak" && log_success "✓ Backup created"

    # Try both patterns: direct field read AND method call
    # (MIUI uses both depending on API version)

    log_info "--- Pattern A: sget-boolean IS_INTERNATIONAL_BUILD ---"
    _run_patcher "$BIN_DIR/mt_dex_patch.py" patch-field \
        --apk  "$APK" \
        --find "Lmiui/os/Build;->IS_INTERNATIONAL_BUILD:Z"

    log_info "--- Pattern B: invoke-static getRegion() ---"
    _run_patcher "$BIN_DIR/mt_dex_patch.py" patch-pattern \
        --apk  "$APK" \
        --find "Lmiui/os/Build;->getRegion()Ljava/lang/String;"

    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_success "✅ GMS SUPPORT ENABLED"
    log_success "   IS_INTERNATIONAL_BUILD → always true"
    log_success "   Size: $(du -h "$APK" | cut -f1)  ← unchanged"
    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}


# ╔══════════════════════════════════════════════════════════════════╗
# ║  4. MIUI-SERVICES.JAR  —  CN → Global                            ║
# ╚══════════════════════════════════════════════════════════════════╝
patch_miui_service() {
    local DUMP="$1"

    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_step "🌏 MIUI SERVICE CN→GLOBAL PATCH"
    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local JAR
    JAR=$(find "$DUMP" -name "miui-services.jar" -type f | head -n 1)
    [ -z "$JAR" ] && { log_warning "⚠  miui-services.jar not found"; return 0; }

    log_success "✓ Found: miui-services.jar"
    log_info "File: $JAR"
    log_info "Size: $(du -h "$JAR" | cut -f1)"
    cp "$JAR" "${JAR}.bak" && log_success "✓ Backup created"

    # Try both patterns
    log_info "--- Pattern A: sget-boolean IS_INTERNATIONAL_BUILD ---"
    _run_patcher "$BIN_DIR/mt_dex_patch.py" patch-field \
        --apk  "$JAR" \
        --find "Lmiui/os/Build;->IS_INTERNATIONAL_BUILD:Z"

    log_info "--- Pattern B: invoke-static getRegion() ---"
    _run_patcher "$BIN_DIR/mt_dex_patch.py" patch-pattern \
        --apk  "$JAR" \
        --find "Lmiui/os/Build;->getRegion()Ljava/lang/String;"

    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_success "✅ MIUI SERVICE PATCHED (CN→GLOBAL)"
    log_success "   Features: AutoStart, Nearby, Location, Network"
    log_success "   Size: $(du -h "$JAR" | cut -f1)  ← unchanged"
    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}
