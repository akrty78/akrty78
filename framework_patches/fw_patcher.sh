#!/usr/bin/env bash
# framework_patches/fw_patcher.sh
# Orchestrator — sourced by mod.sh.
# Provides TWO partition-aware functions:
#   run_fw_patches_system     "$DUMP_DIR"  — patches framework.jar + services.jar
#   run_fw_patches_system_ext "$DUMP_DIR"  — patches miui-services.jar + places Kaorios APK
#
# Each function uses find "$DUMP_DIR" to locate JARs (same pattern as MiuiBooster).
# Decompile-once optimization: shared JARs decompiled once even if multiple features target them.

FP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$FP_DIR/common.sh"
source "$FP_DIR/sig_bypass.sh"
source "$FP_DIR/cn_notif.sh"
source "$FP_DIR/secure_flag.sh"
source "$FP_DIR/kaorios.sh"

# ── Helper: patch a single JAR (decompile → apply patches → recompile) ──
_fp_patch_jar() {
    local jar_path="$1"
    shift
    # Remaining args are function names to call with the decompiled dir

    local name; name="$(basename "$jar_path" .jar)"

    # Backup
    cp "$jar_path" "${jar_path}.bak"
    _fp_log "Backup: ${name}.jar.bak"

    # Decompile
    local dec_dir
    dec_dir=$(fp_decompile "$jar_path") || {
        _fp_err "Failed to decompile ${name}.jar — restoring backup"
        cp "${jar_path}.bak" "$jar_path"
        fp_cleanup "$name"
        return 1
    }

    # Clean invoke-custom (prerequisite for all patches)
    modify_invoke_custom_methods "$dec_dir"

    # Apply all requested patch functions
    local func
    for func in "$@"; do
        _fp_log "Running $func on $name..."
        "$func" "$dec_dir"
    done

    # Recompile
    fp_recompile "$jar_path" "$dec_dir" || {
        _fp_err "Failed to rebuild ${name}.jar — restoring backup"
        cp "${jar_path}.bak" "$jar_path"
        fp_cleanup "$name"
        return 1
    }

    # Cleanup
    rm -f "${jar_path}.bak"
    fp_cleanup "$name"
    _fp_success "${name}.jar fully patched ✓"
    return 0
}

# ══════════════════════════════════════════════════════════════════
# SYSTEM PARTITION — framework.jar + services.jar
# Called from: mod.sh → if [ "$part" == "system" ]
# DUMP_DIR = $GITHUB_WORKSPACE/system_dump
# ══════════════════════════════════════════════════════════════════
run_fw_patches_system() {
    local DUMP_DIR="$1"

    # Feature flags from MODS_SELECTED
    local SIG=0 SEC=0 KAO=0
    [[ ",$MODS_SELECTED," == *",fw_sig_bypass,"*  ]] && SIG=1
    [[ ",$MODS_SELECTED," == *",fw_secure_flag,"* ]] && SEC=1
    [[ ",$MODS_SELECTED," == *",fw_kaorios,"*     ]] && KAO=1

    # Guard: nothing to do in system?
    [ $SIG -eq 0 ] && [ $SEC -eq 0 ] && [ $KAO -eq 0 ] && return 0

    _fp_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    _fp_step "🔧 FRAMEWORK PATCHER — system partition"
    _fp_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # ── FRAMEWORK.JAR ────────────────────────────────────────────
    if [ $SIG -eq 1 ] || [ $KAO -eq 1 ]; then
        local fw_jar
        fw_jar=$(find "$DUMP_DIR" -name "framework.jar" -path "*/framework/*" -type f | head -1)
        if [ -n "$fw_jar" ] && [ -f "$fw_jar" ]; then
            _fp_log "Located: $fw_jar"
            local patch_funcs=()
            [ $SIG -eq 1 ] && patch_funcs+=("run_sig_bypass_framework")
            [ $KAO -eq 1 ] && patch_funcs+=("run_kaorios_framework")
            _fp_patch_jar "$fw_jar" "${patch_funcs[@]}"
        else
            _fp_warn "framework.jar not found in system partition"
        fi
    fi

    # ── SERVICES.JAR ─────────────────────────────────────────────
    if [ $SIG -eq 1 ] || [ $SEC -eq 1 ]; then
        local svc_jar
        svc_jar=$(find "$DUMP_DIR" -name "services.jar" -path "*/framework/*" -type f | head -1)
        if [ -n "$svc_jar" ] && [ -f "$svc_jar" ]; then
            _fp_log "Located: $svc_jar"
            local patch_funcs=()
            [ $SIG -eq 1 ] && patch_funcs+=("run_sig_bypass_services")
            [ $SEC -eq 1 ] && patch_funcs+=("run_secure_flag_services")
            _fp_patch_jar "$svc_jar" "${patch_funcs[@]}"
        else
            _fp_warn "services.jar not found in system partition"
        fi
    fi

    _fp_success "✓ Framework patches (system) complete"
}

# ══════════════════════════════════════════════════════════════════
# SYSTEM_EXT PARTITION — miui-services.jar + Kaorios APK placement
# Called from: mod.sh → if [ "$part" == "system_ext" ]
# DUMP_DIR = $GITHUB_WORKSPACE/system_ext_dump
# ══════════════════════════════════════════════════════════════════
run_fw_patches_system_ext() {
    local DUMP_DIR="$1"

    # Feature flags from MODS_SELECTED
    local SIG=0 NOTIF=0 SEC=0 KAO=0
    [[ ",$MODS_SELECTED," == *",fw_sig_bypass,"*  ]] && SIG=1
    [[ ",$MODS_SELECTED," == *",fw_cn_notif,"*    ]] && NOTIF=1
    [[ ",$MODS_SELECTED," == *",fw_secure_flag,"* ]] && SEC=1
    [[ ",$MODS_SELECTED," == *",fw_kaorios,"*     ]] && KAO=1

    # Guard: nothing to do in system_ext?
    [ $SIG -eq 0 ] && [ $NOTIF -eq 0 ] && [ $SEC -eq 0 ] && [ $KAO -eq 0 ] && return 0

    _fp_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    _fp_step "🔧 FRAMEWORK PATCHER — system_ext partition"
    _fp_step "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # ── MIUI-SERVICES.JAR ────────────────────────────────────────
    if [ $SIG -eq 1 ] || [ $NOTIF -eq 1 ] || [ $SEC -eq 1 ]; then
        local miui_jar
        miui_jar=$(find "$DUMP_DIR" -name "miui-services.jar" -type f | head -1)
        if [ -n "$miui_jar" ] && [ -f "$miui_jar" ]; then
            _fp_log "Located: $miui_jar"
            local patch_funcs=()
            [ $SIG   -eq 1 ] && patch_funcs+=("run_sig_bypass_miui_services")
            [ $NOTIF -eq 1 ] && patch_funcs+=("run_cn_notif_miui_services")
            [ $SEC   -eq 1 ] && patch_funcs+=("run_secure_flag_miui_services")
            _fp_patch_jar "$miui_jar" "${patch_funcs[@]}"
        else
            _fp_warn "miui-services.jar not found in system_ext partition"
        fi
    fi

    # ── KAORIOS: Place APK + permissions into system_ext ──────────
    if [ $KAO -eq 1 ]; then
        run_kaorios_place_files "$DUMP_DIR"
    fi

    _fp_success "✓ Framework patches (system_ext) complete"
}
