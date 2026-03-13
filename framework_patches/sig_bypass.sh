#!/usr/bin/env bash
# framework_patches/sig_bypass.sh
# Disable Signature Verification — framework.jar + services.jar + miui-services.jar
# Ported from FrameworkPatcher/patcher_a16.sh (Android 16)

run_sig_bypass_framework() {
    local decompile_dir="$1"
    _fp_log "Applying signature verification patches to framework.jar (Android 16)..."

    # PackageParser.smali
    local pkg_parser_file
    pkg_parser_file=$(find "$decompile_dir" -type f -path "*/android/content/pm/PackageParser.smali" | head -n1)
    if [ -n "$pkg_parser_file" ]; then
        insert_line_before_all "$pkg_parser_file" "ApkSignatureVerifier;->unsafeGetCertsWithoutVerification" "const/4 v1, 0x1"
        insert_const_before_condition_near_string "$pkg_parser_file" '<manifest> specifies bad sharedUserId name' "if-nez v14, :" "v14" "1"
    else
        _fp_warn "PackageParser.smali not found"
    fi

    # PackageParserException.smali
    local pkg_parser_exception_file
    pkg_parser_exception_file=$(find "$decompile_dir" -type f -path '*/android/content/pm/PackageParser$PackageParserException.smali' | head -n1)
    if [ -n "$pkg_parser_exception_file" ]; then
        insert_line_before_all "$pkg_parser_exception_file" 'iput p1, p0, Landroid/content/pm/PackageParser$PackageParserException;->error:I' "const/4 p1, 0x0"
    else
        _fp_warn 'PackageParser$PackageParserException.smali not found'
    fi

    # SigningDetails.smali (PackageParser inner class)
    local pkg_signing_details_file
    pkg_signing_details_file=$(find "$decompile_dir" -type f -path '*/android/content/pm/PackageParser$SigningDetails.smali' | head -n1)
    if [ -n "$pkg_signing_details_file" ]; then
        force_methods_return_const "$pkg_signing_details_file" "checkCapability" "1"
    else
        _fp_warn 'PackageParser$SigningDetails.smali not found'
    fi

    # SigningDetails.smali (standalone)
    local signing_details_file
    signing_details_file=$(find "$decompile_dir" -type f -path "*/android/content/pm/SigningDetails.smali" | head -n1)
    if [ -n "$signing_details_file" ]; then
        force_methods_return_const "$signing_details_file" "checkCapability" "1"
        force_methods_return_const "$signing_details_file" "checkCapabilityRecover" "1"
        force_methods_return_const "$signing_details_file" "hasAncestorOrSelf" "1"
    else
        _fp_warn "SigningDetails.smali not found"
    fi

    # ApkSignatureSchemeV2Verifier.smali
    local apk_sig_v2_file
    apk_sig_v2_file=$(find "$decompile_dir" -type f -path "*/android/util/apk/ApkSignatureSchemeV2Verifier.smali" | head -n1)
    if [ -n "$apk_sig_v2_file" ]; then
        replace_move_result_after_invoke "$apk_sig_v2_file" "invoke-static {v8, v4}, Ljava/security/MessageDigest;->isEqual([B[B)Z" "const/4 v0, 0x1"
    else
        _fp_warn "ApkSignatureSchemeV2Verifier.smali not found"
    fi

    # ApkSignatureSchemeV3Verifier.smali
    local apk_sig_v3_file
    apk_sig_v3_file=$(find "$decompile_dir" -type f -path "*/android/util/apk/ApkSignatureSchemeV3Verifier.smali" | head -n1)
    if [ -n "$apk_sig_v3_file" ]; then
        replace_move_result_after_invoke "$apk_sig_v3_file" "invoke-static {v9, v3}, Ljava/security/MessageDigest;->isEqual([B[B)Z" "const/4 v0, 0x1"
    else
        _fp_warn "ApkSignatureSchemeV3Verifier.smali not found"
    fi

    # ApkSignatureVerifier.smali
    local apk_verifier_file
    apk_verifier_file=$(find "$decompile_dir" -type f -path "*/android/util/apk/ApkSignatureVerifier.smali" | head -n1)
    if [ -n "$apk_verifier_file" ]; then
        force_methods_return_const "$apk_verifier_file" "getMinimumSignatureSchemeVersionForTargetSdk" "0"
        insert_line_before_all "$apk_verifier_file" "ApkSignatureVerifier;->verifyV1Signature" "const p3, 0x0"
    else
        _fp_warn "ApkSignatureVerifier.smali not found"
    fi

    # ApkSigningBlockUtils.smali
    local apk_block_utils_file
    apk_block_utils_file=$(find "$decompile_dir" -type f -path "*/android/util/apk/ApkSigningBlockUtils.smali" | head -n1)
    if [ -n "$apk_block_utils_file" ]; then
        replace_move_result_after_invoke "$apk_block_utils_file" "invoke-static {v5, v6}, Ljava/security/MessageDigest;->isEqual([B[B)Z" "const/4 v7, 0x1"
    else
        _fp_warn "ApkSigningBlockUtils.smali not found"
    fi

    # StrictJarVerifier.smali
    local strict_jar_verifier_file
    strict_jar_verifier_file=$(find "$decompile_dir" -type f -path "*/android/util/jar/StrictJarVerifier.smali" | head -n1)
    if [ -n "$strict_jar_verifier_file" ]; then
        force_methods_return_const "$strict_jar_verifier_file" "verifyMessageDigest" "1"
    else
        _fp_warn "StrictJarVerifier.smali not found"
    fi

    # StrictJarFile.smali
    local strict_jar_file_file
    strict_jar_file_file=$(find "$decompile_dir" -type f -path "*/android/util/jar/StrictJarFile.smali" | head -n1)
    if [ -n "$strict_jar_file_file" ]; then
        replace_if_block_in_strict_jar_file "$strict_jar_file_file"
    else
        _fp_warn "StrictJarFile.smali not found"
    fi

    # ParsingPackageUtils.smali
    local parsing_pkg_utils_file
    parsing_pkg_utils_file=$(find "$decompile_dir" -type f -path "*/com/android/internal/pm/pkg/parsing/ParsingPackageUtils.smali" | head -n1)
    if [ -n "$parsing_pkg_utils_file" ]; then
        insert_const_before_condition_near_string "$parsing_pkg_utils_file" '<manifest> specifies bad sharedUserId name' "if-eqz v4, :" "v4" "0"
    else
        _fp_warn "ParsingPackageUtils.smali not found"
    fi

    _fp_success "Signature verification patches applied to framework.jar"
}

run_sig_bypass_services() {
    local decompile_dir="$1"
    _fp_log "Applying signature verification patches to services.jar (Android 16)..."

    # Resolve smali files across classes*/
    _resolve_smali() {
        local rel="$1"
        for d in "$decompile_dir/classes" "$decompile_dir/classes2" "$decompile_dir/classes3" "$decompile_dir/classes4"; do
            [ -f "$d/$rel" ] && { printf "%s\n" "$d/$rel"; return 0; }
        done
        find "$decompile_dir" -type f -path "*/$rel" | head -n1
    }

    local pms_utils_file; pms_utils_file=$(_resolve_smali "com/android/server/pm/PackageManagerServiceUtils.smali")
    local install_pkg_helper_file; install_pkg_helper_file=$(_resolve_smali "com/android/server/pm/InstallPackageHelper.smali")
    local reconcile_pkg_utils_file; reconcile_pkg_utils_file=$(_resolve_smali "com/android/server/pm/ReconcilePackageUtils.smali")

    # checkDowngrade → return-void (all overloads)
    if [ -n "$pms_utils_file" ] && [ -f "$pms_utils_file" ]; then
        patch_return_void_methods_all "checkDowngrade" "$decompile_dir"
        force_methods_return_const "$pms_utils_file" "verifySignatures" "0"
        force_methods_return_const "$pms_utils_file" "matchSignaturesCompat" "1"
    else
        _fp_warn "PackageManagerServiceUtils.smali not found"
    fi

    # shouldCheckUpgradeKeySetLocked
    local should_check_file
    should_check_file=$(_resolve_smali "com/android/server/pm/KeySetManagerService.smali")
    if [ -n "$should_check_file" ] && [ -f "$should_check_file" ]; then
        force_methods_return_const "$should_check_file" "shouldCheckUpgradeKeySetLocked" "0"
    else
        local method_file
        method_file=$(find_smali_method_file "$decompile_dir" "shouldCheckUpgradeKeySetLocked")
        [ -n "$method_file" ] && force_methods_return_const "$method_file" "shouldCheckUpgradeKeySetLocked" "0" \
            || _fp_warn "shouldCheckUpgradeKeySetLocked not found"
    fi

    # InstallPackageHelper shared-user guard
    local invoke_pattern="invoke-interface {p5}, Lcom/android/server/pm/pkg/AndroidPackage;->isLeavingSharedUser()Z"
    if [ -n "$install_pkg_helper_file" ] && [ -f "$install_pkg_helper_file" ]; then
        ensure_const_before_if_for_register "$install_pkg_helper_file" "$invoke_pattern" "if-eqz v3, :" "v3" "1"
    else
        local fallback_file
        fallback_file=$(grep -s -rl --include='*.smali' "$invoke_pattern" "$decompile_dir" 2>/dev/null | head -n1)
        [ -n "$fallback_file" ] && ensure_const_before_if_for_register "$fallback_file" "$invoke_pattern" "if-eqz v3, :" "v3" "1" \
            || _fp_warn "InstallPackageHelper.smali not found and pattern not located"
    fi

    # ReconcilePackageUtils <clinit>
    if [ -n "$reconcile_pkg_utils_file" ] && [ -f "$reconcile_pkg_utils_file" ]; then
        patch_reconcile_clinit "$reconcile_pkg_utils_file"
    else
        _fp_warn "ReconcilePackageUtils.smali not found"
    fi

    _fp_success "Signature verification patches applied to services.jar"
}

run_sig_bypass_miui_services() {
    local decompile_dir="$1"
    _fp_log "Applying signature verification patches to miui-services.jar (Android 16)..."

    patch_return_void_methods_all "verifyIsolationViolation" "$decompile_dir"
    patch_return_void_methods_all "canBeUpdate" "$decompile_dir"

    _fp_success "Signature verification patches applied to miui-services.jar"
}
