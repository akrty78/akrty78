#!/bin/bash
# =========================================================
#  NEXDROID — BASH INTEGRATION PATCH
#  Drop-in replacement calls for the main manager script.
#
#  KEY CHANGES from old approach:
#    ✗ OLD: apktool b -c  →  broken alignment → -124 error
#    ✓ NEW: nexmod_apk.py patch/fix  →  guaranteed aligned output
#
#  HOW TO USE:
#    1. Copy nexmod_apk.py to $BIN_DIR
#    2. Replace the sections below in your main script
# =========================================================

# ─── After downloading tools, add this wrapper ────────────────────────────────
_run_apk_patch() {
    # _run_apk_patch <label> <profile> <apk_path>
    local label="$1" profile="$2" apk="$3"

    # Bail early if tools not ready
    if [ ! -f "$BIN_DIR/baksmali.jar" ] || [ ! -f "$BIN_DIR/smali.jar" ]; then
        log_warning "$label: baksmali/smali not ready — skipping"
        return 0
    fi
    [ -z "$apk" ] || [ ! -f "$apk" ] && {
        log_warning "$label: APK not found (${apk:-<empty>})"
        return 0
    }

    log_info "$label → $(basename "$apk")"
    python3 "$BIN_DIR/nexmod_apk.py" patch "$apk" "$profile" 2>&1 | \
    while IFS= read -r line; do
        case "$line" in
            "[SUCCESS]"*) log_success "${line#[SUCCESS] }" ;;
            "[WARNING]"*) log_warning "${line#[WARNING] }" ;;
            "[ERROR]"*)   log_error   "${line#[ERROR] }"   ;;
            "[INFO]"*)    log_info    "${line#[INFO] }"    ;;
            *)            [ -n "$line" ] && log_info "$line" ;;
        esac
    done
    local rc=${PIPESTATUS[0]}
    [ $rc -ne 0 ] && log_error "$label failed (exit $rc)"
    return $rc
}

_run_apk_fix() {
    # _run_apk_fix <label> <apk_path>
    # Use this after ANY apktool b call to fix alignment
    local label="$1" apk="$2"
    [ -z "$apk" ] || [ ! -f "$apk" ] && return 0
    log_info "Fixing APK alignment: $label"
    python3 "$BIN_DIR/nexmod_apk.py" fix "$apk" 2>&1 | \
    while IFS= read -r line; do
        case "$line" in
            "[SUCCESS]"*) log_success "${line#[SUCCESS] }" ;;
            "[WARNING]"*) log_warning "${line#[WARNING] }" ;;
            "[ERROR]"*)   log_error   "${line#[ERROR] }"   ;;
            "[INFO]"*)    log_info    "${line#[INFO] }"    ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════════════════════════
#  REPLACE SECTION D in the partition loop with these calls:
# ═══════════════════════════════════════════════════════════════════════════════

# SYSTEM partition — was using apktool b -c for some patches:
if [ "$part" == "system" ]; then

    # D1. Signature bypass (framework.jar)
    _run_apk_patch "SIGNATURE BYPASS" "framework-sig" \
        "$(find "$DUMP_DIR" -path "*/framework/framework.jar" | head -n1)"
    cd "$GITHUB_WORKSPACE"

    # D2. Voice Recorder AI
    _run_apk_patch "VOICE RECORDER AI" "voice-recorder-ai" \
        "$(find "$DUMP_DIR" \( -name "MIUISoundRecorder*.apk" -o -name "SoundRecorder.apk" \) | head -n1)"
    cd "$GITHUB_WORKSPACE"

fi

# SYSTEM_EXT partition
if [ "$part" == "system_ext" ]; then

    # D3. Settings AI
    _run_apk_patch "SETTINGS AI" "settings-ai" \
        "$(find "$DUMP_DIR" -name "Settings.apk" | head -n1)"
    cd "$GITHUB_WORKSPACE"

    # D4. Provision GMS
    _run_apk_patch "PROVISION GMS" "provision-gms" \
        "$(find "$DUMP_DIR" -name "Provision.apk" | head -n1)"
    cd "$GITHUB_WORKSPACE"

    # D5. MIUI service CN→Global
    _run_apk_patch "MIUI SERVICE" "miui-service" \
        "$(find "$DUMP_DIR" -name "miui-services.jar" | head -n1)"
    cd "$GITHUB_WORKSPACE"

    # D6. SystemUI VoLTE
    _run_apk_patch "SYSTEMUI VOLTE" "systemui-volte" \
        "$(find "$DUMP_DIR" \( -name "MiuiSystemUI.apk" -o -name "SystemUI.apk" \) | head -n1)"
    cd "$GITHUB_WORKSPACE"

fi

# ═══════════════════════════════════════════════════════════════════════════════
#  SECTION E — miui-framework (Baidu → Gboard redirect)
#  apktool b -c is still used here for smali text replacement.
#  ADD _run_apk_fix IMMEDIATELY after apktool b to prevent -124.
# ═══════════════════════════════════════════════════════════════════════════════
if [ "$part" == "system_ext" ]; then
    MF_JAR=$(find "$DUMP_DIR" -name "miui-framework.jar" | head -n1)
    if [ -n "$MF_JAR" ]; then
        log_info "⌨️  Redirecting Baidu IME → Gboard in miui-framework.jar..."
        cp "$MF_JAR" "${MF_JAR}.bak"
        cd "$TEMP_DIR"
        if timeout 3m apktool d -r -f "$MF_JAR" -o "mf_src" >/dev/null 2>&1; then
            grep -rl "com.baidu.input_mi" "mf_src" | grep "InputMethodServiceInjector.smali" | \
            while read f; do
                sed -i 's/com.baidu.input_mi/com.google.android.inputmethod.latin/g' "$f"
                log_success "✓ Patched: $(basename "$f")"
            done
            if apktool b -c "mf_src" -o "$MF_JAR" >/dev/null 2>&1; then
                log_success "✓ miui-framework.jar rebuilt"
                # ─── CRITICAL: fix alignment after every apktool b ─────────
                _run_apk_fix "miui-framework.jar" "$MF_JAR"
            fi
        fi
        cd "$GITHUB_WORKSPACE"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
#  SECTION F — MIUIFrequentPhrase (color changes + Gboard redirect)
#  Same pattern: apktool b -c, then MUST call _run_apk_fix.
# ═══════════════════════════════════════════════════════════════════════════════
MFP_APK=$(find "$DUMP_DIR" -name "MIUIFrequentPhrase.apk" -print -quit)
if [ -n "$MFP_APK" ]; then
    log_info "🎨 Modding MIUIFrequentPhrase..."
    cp "$MFP_APK" "${MFP_APK}.bak"
    cd "$TEMP_DIR"
    if timeout 3m apktool d -f "$MFP_APK" -o "mfp_src" >/dev/null 2>&1; then
        find "mfp_src" -name "InputMethodBottomManager.smali" \
            -exec sed -i 's/com.baidu.input_mi/com.google.android.inputmethod.latin/g' {} +
        [ -f "mfp_src/res/values/colors.xml" ] && \
            sed -i 's|<color name="input_bottom_background_color">.*</color>|<color name="input_bottom_background_color">@android:color/system_neutral1_50</color>|g' \
                "mfp_src/res/values/colors.xml"
        [ -f "mfp_src/res/values-night/colors.xml" ] && \
            sed -i 's|<color name="input_bottom_background_color">.*</color>|<color name="input_bottom_background_color">@android:color/system_neutral1_900</color>|g' \
                "mfp_src/res/values-night/colors.xml"
        if apktool b -c "mfp_src" -o "mfp_patched.apk" >/dev/null 2>&1 && \
           [ -f "mfp_patched.apk" ]; then
            mv "mfp_patched.apk" "$MFP_APK"
            log_success "✓ MIUIFrequentPhrase rebuilt"
            # ─── CRITICAL: fix alignment after every apktool b ─────────────
            _run_apk_fix "MIUIFrequentPhrase.apk" "$MFP_APK"
        fi
    fi
    cd "$GITHUB_WORKSPACE"
fi

# ═══════════════════════════════════════════════════════════════════════════════
#  MiuiBooster patch — same fix needed after apktool b -c
#  In section C, after: mv "MiuiBooster_patched.jar" "$BOOST_JAR"
#  Add immediately:
# ═══════════════════════════════════════════════════════════════════════════════
# _run_apk_fix "MiuiBooster.jar" "$BOOST_JAR"   # ← add this line

# ═══════════════════════════════════════════════════════════════════════════════
#  INSTALL nexmod_apk.py — add this to SECTION 3 (Download Resources)
# ═══════════════════════════════════════════════════════════════════════════════
# Copy nexmod_apk.py to $BIN_DIR and make executable
# cp /path/to/nexmod_apk.py "$BIN_DIR/nexmod_apk.py"
# chmod +x "$BIN_DIR/nexmod_apk.py"
# log_success "✓ nexmod_apk.py ready"
