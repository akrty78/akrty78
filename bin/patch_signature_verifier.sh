#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
#  patch_signature_verifier.sh  —  framework.jar signature bypass
#
#  Approach: baksmali → smali edits → smali recompile → zip -0 -u
#  (mirrors patcher_a16.sh apply_framework_signature_patches exactly)
#
#  Patches applied (per-DEX, all relevant DEXes processed):
#   1. PackageParser: force sig check parameter to 0x1
#   2. PackageParser$PackageParserException: swallow error codes
#   3. SigningDetails / PackageParser$SigningDetails: checkCapability* → 1
#   4. ApkSignatureSchemeV2Verifier: isEqual digest → 1
#   5. ApkSignatureSchemeV3Verifier: isEqual digest → 1
#   6. ApkSignatureVerifier: getMinimumSchemeVersion → 0, insert before V1 call
#   7. ApkSigningBlockUtils: isEqual digest → 1
#   8. StrictJarVerifier: verifyMessageDigest → 1
#   9. StrictJarFile: remove null-entry guard
#  10. ParsingPackageUtils: swallow sharedUserId error
# ═══════════════════════════════════════════════════════════════════

declare -f _smali_patch_dex &>/dev/null || source "$BIN_DIR/smali_tools.sh"

# ── All patches run inside the decompiled smali tree ─────────────
_fw_sig_patcher() {
    local smali_dir="$1"
    local n=0

    # 1. PackageParser: force cert-check register before verification call
    smali_insert_before "$smali_dir" \
        "ApkSignatureVerifier;->unsafeGetCertsWithoutVerification" \
        "const/4 v1, 0x1" && ((n++)) || true

    # 2. PackageParser$PackageParserException: zero out error code
    smali_insert_before "$smali_dir" \
        "iput p1, p0, Landroid/content/pm/PackageParser\$PackageParserException;->error:I" \
        "const/4 p1, 0x0" && ((n++)) || true

    # 3. SigningDetails: all capability checks → 1
    smali_force_return "$smali_dir" "checkCapability"        "1" && ((n++)) || true
    smali_force_return "$smali_dir" "checkCapabilityRecover" "1" && ((n++)) || true
    smali_force_return "$smali_dir" "hasAncestorOrSelf"      "1" && ((n++)) || true

    # 4. ApkSignatureSchemeV2Verifier: isEqual → 1
    smali_replace_move_result "$smali_dir" \
        "invoke-static {v8, v4}, Ljava/security/MessageDigest;->isEqual([B[B)Z" \
        "const/4 v0, 0x1" && ((n++)) || true

    # 5. ApkSignatureSchemeV3Verifier: isEqual → 1
    smali_replace_move_result "$smali_dir" \
        "invoke-static {v9, v3}, Ljava/security/MessageDigest;->isEqual([B[B)Z" \
        "const/4 v0, 0x1" && ((n++)) || true

    # 6a. ApkSignatureVerifier: getMinimumSignatureSchemeVersionForTargetSdk → 0
    smali_force_return "$smali_dir" "getMinimumSignatureSchemeVersionForTargetSdk" "0" && ((n++)) || true

    # 6b. Insert const p3=0 before every call to verifyV1Signature
    smali_insert_before "$smali_dir" \
        "ApkSignatureVerifier;->verifyV1Signature" \
        "const p3, 0x0" && ((n++)) || true

    # 7. ApkSigningBlockUtils: isEqual → 1
    smali_replace_move_result "$smali_dir" \
        "invoke-static {v5, v6}, Ljava/security/MessageDigest;->isEqual([B[B)Z" \
        "const/4 v7, 0x1" && ((n++)) || true

    # 8. StrictJarVerifier: verifyMessageDigest → 1
    smali_force_return "$smali_dir" "verifyMessageDigest" "1" && ((n++)) || true

    # 9. StrictJarFile: remove if-eqz null guard after findEntry
    smali_strip_if_eqz_after "$smali_dir" \
        "Landroid/util/jar/StrictJarFile;->findEntry(Ljava/lang/String;)Ljava/util/zip/ZipEntry;" \
        && ((n++)) || true

    # 10. ParsingPackageUtils: swallow sharedUserId validation error
    smali_insert_before "$smali_dir" \
        "manifest> specifies bad sharedUserId name" \
        "const/4 v4, 0x0" && ((n++)) || true

    log_info "    Patches applied this DEX: $n/10"
    [ "$n" -gt 0 ]
}

# ── Main ─────────────────────────────────────────────────────────
patch_signature_verification() {
    local DUMP="$1"

    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_step "🔓 SIGNATURE VERIFICATION DISABLER"
    log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    _smali_ensure_tools || return 0

    local JAR
    JAR=$(find "$DUMP" -path "*/framework/framework.jar" -type f | head -n 1)
    if [ -z "$JAR" ]; then
        log_warning "⚠  framework.jar not found"; return 0
    fi
    log_info "Located: $JAR"
    log_info "Size:    $(du -h "$JAR" | cut -f1)"

    cp "$JAR" "${JAR}.bak"
    log_success "✓ Backup created"

    local TARGET_CLASSES="ApkSignatureVerifier ApkSignatureScheme StrictJarVerifier StrictJarFile SigningDetails PackageParser ApkSigningBlock ParsingPackageUtils"

    local found_any=0
    for dex in $(unzip -l "$JAR" 2>/dev/null | grep -oP 'classes\d*\.dex' | sort); do
        local tmp; tmp=$(mktemp)
        unzip -p "$JAR" "$dex" > "$tmp" 2>/dev/null
        local relevant=0
        for cls in $TARGET_CLASSES; do
            if strings "$tmp" 2>/dev/null | grep -q "$cls"; then
                relevant=1; break
            fi
        done
        rm -f "$tmp"

        if [ "$relevant" -eq 1 ]; then
            log_info "Processing $dex..."
            _smali_patch_dex "$JAR" "$dex" "35" "_fw_sig_patcher" && found_any=1 || true
        else
            log_info "Skipping $dex (no relevant classes)"
        fi
    done

    if [ "$found_any" -eq 1 ]; then
        log_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_success "✅ SIGNATURE VERIFICATION DISABLED"
        log_success "   Patches applied across signature chain"
        log_success "   Size: $(du -h "$JAR" | cut -f1)"
    else
        log_error "✗ No patches applied — restoring backup"
        cp "${JAR}.bak" "$JAR"
    fi

    cd "$GITHUB_WORKSPACE"
}

[ "${BASH_SOURCE[0]}" -ef "$0" ] && patch_signature_verification "$@"
