#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
#  SIGNATURE VERIFICATION DISABLER  (Binary, v3)
#  Uses mt_dex_patch.py — no baksmali, no smali.jar, no full recompile
#
#  Target:
#    File:   system/framework/framework.jar
#    Class:  android/util/apk/ApkSignatureVerifier
#    Method: getMinimumSignatureSchemeVersionForTargetSdk
#    Patch:  const/4 v0, #1  ;  return v0   →  always returns 1 (V1 sig)
#    Bytes:  12 10 0F 00
# ═══════════════════════════════════════════════════════════════════

patch_signature_verification() {
    local DUMP="$1"

    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_step "🔓 SIGNATURE VERIFICATION DISABLER"
    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local JAR
    JAR=$(find "$DUMP" -path "*/framework/framework.jar" -type f | head -n 1)
    if [ -z "$JAR" ]; then
        log_warning "⚠  framework.jar not found"
        return 0
    fi

    log_info "Located: $JAR"
    log_info "File: framework.jar"
    log_info "Size: $(du -h "$JAR" | cut -f1)"

    log_info "Creating backup..."
    cp "$JAR" "${JAR}.bak"
    log_success "✓ Backup created"

    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "METHOD: Binary DEX patch (no smali.jar needed)"
    log_info "  Class:  android/util/apk/ApkSignatureVerifier"
    log_info "  Method: getMinimumSignatureSchemeVersionForTargetSdk"
    log_info "  Patch:  const/4 v0,#1 → return v0  (always returns 1)"
    log_info "  Bytes:  12 10 0F 00"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local OUT
    OUT=$(python3 "$BIN_DIR/mt_dex_patch.py" patch-method \
        --apk    "$JAR" \
        --class  "android/util/apk/ApkSignatureVerifier" \
        --method "getMinimumSignatureSchemeVersionForTargetSdk" \
        --bytes  "12 10 0F 00" 2>&1)
    local RC=$?

    # Forward output to logger
    while IFS= read -r line; do
        case "$line" in
            "[SUCCESS]"*) log_success "${line:10}" ;;
            "[ERROR]"*)   log_error   "${line:8}"  ;;
            "[WARNING]"*) log_warning "${line:10}" ;;
            "[ACTION]"*)  log_info    "${line:9}"  ;;
            "[INFO]"*)    log_info    "${line:7}"  ;;
            *)            [ -n "$line" ] && log_info "$line" ;;
        esac
    done <<< "$OUT"

    if [ "$RC" -eq 0 ]; then
        log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_success "✅ SIGNATURE VERIFICATION DISABLED"
        log_success "   getMinimumSignatureSchemeVersionForTargetSdk() → always 1"
        log_success "   Effect: V1/V2/V3 signatures all accepted"
        log_success "   Size: $(du -h "$JAR" | cut -f1)  ← unchanged"
        log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    else
        log_error "✗ Signature verification patching failed"
        log_info "Restoring original framework.jar..."
        cp "${JAR}.bak" "$JAR"
        log_warning "Original restored"
    fi

    cd "$GITHUB_WORKSPACE"
}

[ "${BASH_SOURCE[0]}" -ef "$0" ] && patch_signature_verification "$@"
