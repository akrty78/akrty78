#!/usr/bin/env bash
# framework_patches/secure_flag.sh
# Disable Secure Flag — services.jar + miui-services.jar
# Ported from FrameworkPatcher/patcher_a16.sh (Android 16)

run_secure_flag_services() {
    local decompile_dir="$1"
    _fp_log "Applying disable secure flag patches to services.jar (Android 16)..."

    # Android 16: Patch WindowState.isSecureLocked()
    local method_body="    .registers 6\n\n    const/4 v0, 0x0\n\n    return v0"
    replace_entire_method "isSecureLocked()Z" "$decompile_dir" "$method_body" "com/android/server/wm/WindowState"

    _fp_success "Disable secure flag patches applied to services.jar"
}

run_secure_flag_miui_services() {
    local decompile_dir="$1"
    _fp_log "Applying disable secure flag patches to miui-services.jar (Android 16)..."

    # Android 16: Patch WindowManagerServiceImpl.notAllowCaptureDisplay()
    local method_body="    .registers 9\n\n    const/4 v0, 0x0\n\n    return v0"
    replace_entire_method "notAllowCaptureDisplay(Lcom/android/server/wm/RootWindowContainer;I)Z" "$decompile_dir" "$method_body" "com/android/server/wm/WindowManagerServiceImpl"

    _fp_success "Disable secure flag patches applied to miui-services.jar"
}
