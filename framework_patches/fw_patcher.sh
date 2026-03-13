#!/usr/bin/env bash
# framework_patches/fw_patcher.sh
# Orchestrator — sourced by mod.sh. Call: run_framework_patches "$DUMP_DIR"
# Implements decompile-once optimization: shared JARs are decompiled once,
# all selected patches applied, then recompiled once.

FP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$FP_DIR/common.sh"
source "$FP_DIR/sig_bypass.sh"
source "$FP_DIR/cn_notif.sh"
source "$FP_DIR/secure_flag.sh"
source "$FP_DIR/kaorios.sh"

run_framework_patches() {
    local dump_dir="$1"

    # Guard: at least one FP feature must be selected
    local any=0
    for key in fw_sig_bypass fw_cn_notif fw_secure_flag fw_kaorios; do
        [[ ",$MODS_SELECTED," == *",$key,"* ]] && any=1
    done
    [ "$any" -eq 0 ] && return 0

    _fp_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    _fp_step "🔧 FRAMEWORK PATCHER"
    _fp_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    mkdir -p "$FP_WORK_DIR"

    # Feature flags
    local SIG=0 NOTIF=0 SEC=0 KAO=0
    [[ ",$MODS_SELECTED," == *",fw_sig_bypass,"*  ]] && SIG=1
    [[ ",$MODS_SELECTED," == *",fw_cn_notif,"*    ]] && NOTIF=1
    [[ ",$MODS_SELECTED," == *",fw_secure_flag,"* ]] && SEC=1
    [[ ",$MODS_SELECTED," == *",fw_kaorios,"*     ]] && KAO=1

    _fp_log "Selected features:"
    [ $SIG   -eq 1 ] && _fp_log "  ✓ Disable Signature Verification"
    [ $NOTIF -eq 1 ] && _fp_log "  ✓ CN Notification Fix"
    [ $SEC   -eq 1 ] && _fp_log "  ✓ Disable Secure Flag"
    [ $KAO   -eq 1 ] && _fp_log "  ✓ Kaorios Toolbox"

    # ── FRAMEWORK.JAR ────────────────────────────────────────────
    if [ $SIG -eq 1 ] || [ $KAO -eq 1 ]; then
        local fw_jar; fw_jar="$(find "$dump_dir" -path "*/framework/framework.jar" -type f | head -1)"
        if [ -n "$fw_jar" ]; then
            local fw_dir; fw_dir="$(fp_decompile "$fw_jar")" || { _fp_err "framework.jar decompile failed"; }
            if [ -n "$fw_dir" ] && [ -d "$fw_dir" ]; then
                modify_invoke_custom_methods "$fw_dir"
                [ $SIG -eq 1 ] && run_sig_bypass_framework "$fw_dir"
                [ $KAO -eq 1 ] && run_kaorios_framework "$fw_dir"
                fp_recompile "$fw_jar" "$fw_dir"
            fi
        else
            _fp_warn "framework.jar not found — skipping"
        fi
    fi

    # ── SERVICES.JAR ─────────────────────────────────────────────
    if [ $SIG -eq 1 ] || [ $SEC -eq 1 ]; then
        local svc_jar; svc_jar="$(find "$dump_dir" -path "*/framework/services.jar" -type f | head -1)"
        if [ -n "$svc_jar" ]; then
            local svc_dir; svc_dir="$(fp_decompile "$svc_jar")" || { _fp_err "services.jar decompile failed"; }
            if [ -n "$svc_dir" ] && [ -d "$svc_dir" ]; then
                modify_invoke_custom_methods "$svc_dir"
                [ $SIG -eq 1 ] && run_sig_bypass_services "$svc_dir"
                [ $SEC -eq 1 ] && run_secure_flag_services "$svc_dir"
                fp_recompile "$svc_jar" "$svc_dir"
            fi
        else
            _fp_warn "services.jar not found — skipping"
        fi
    fi

    # ── MIUI-SERVICES.JAR ────────────────────────────────────────
    if [ $SIG -eq 1 ] || [ $NOTIF -eq 1 ] || [ $SEC -eq 1 ]; then
        local miui_jar; miui_jar="$(find "$dump_dir" -name "miui-services.jar" -type f | head -1)"
        if [ -n "$miui_jar" ]; then
            local miui_dir; miui_dir="$(fp_decompile "$miui_jar")" || { _fp_err "miui-services.jar decompile failed"; }
            if [ -n "$miui_dir" ] && [ -d "$miui_dir" ]; then
                modify_invoke_custom_methods "$miui_dir"
                [ $SIG   -eq 1 ] && run_sig_bypass_miui_services "$miui_dir"
                [ $NOTIF -eq 1 ] && run_cn_notif_miui_services "$miui_dir"
                [ $SEC   -eq 1 ] && run_secure_flag_miui_services "$miui_dir"
                fp_recompile "$miui_jar" "$miui_dir"
            fi
        else
            _fp_warn "miui-services.jar not found — skipping"
        fi
    fi

    # ── KAORIOS: Place APK + permissions ─────────────────────────
    if [ $KAO -eq 1 ]; then
        run_kaorios_place_files "$dump_dir"
    fi

    rm -rf "$FP_WORK_DIR"
    _fp_success "✓ Framework patches complete"
}
