#!/usr/bin/env bash
# framework_patches/cn_notif.sh
# CN Notification Fix — miui-services.jar only
# Ported from FrameworkPatcher/patcher_a16.sh apply_miui_services_cn_notification_fix()

run_cn_notif_miui_services() {
    local decompile_dir="$1"
    _fp_log "Applying CN notification fix to miui-services.jar (Android 16)..."

    # BroadcastQueueModernStubImpl
    local file
    file=$(find "$decompile_dir" -type f -path "*/com/android/server/am/BroadcastQueueModernStubImpl.smali" | head -n 1)
    if [ -f "$file" ]; then
        sed -i 's/sget-boolean v2, Lmiui\/os\/Build;->IS_INTERNATIONAL_BUILD:Z/const\/4 v2, 0x1/g' "$file"
        _fp_success "IS_INTERNATIONAL_BUILD patched in BroadcastQueueModernStubImpl (v2)"
    else
        _fp_warn "BroadcastQueueModernStubImpl.smali not found"
    fi

    # ActivityManagerServiceImpl (has two occurrences: v1 and v4)
    file=$(find "$decompile_dir" -type f -path "*/com/android/server/am/ActivityManagerServiceImpl.smali" | head -n 1)
    if [ -f "$file" ]; then
        sed -i 's/sget-boolean v1, Lmiui\/os\/Build;->IS_INTERNATIONAL_BUILD:Z/const\/4 v1, 0x1/g' "$file"
        sed -i 's/sget-boolean v4, Lmiui\/os\/Build;->IS_INTERNATIONAL_BUILD:Z/const\/4 v4, 0x1/g' "$file"
        _fp_success "IS_INTERNATIONAL_BUILD patched in ActivityManagerServiceImpl (v1, v4)"
    else
        _fp_warn "ActivityManagerServiceImpl.smali not found"
    fi

    # ProcessManagerService
    file=$(find "$decompile_dir" -type f -path "*/com/android/server/am/ProcessManagerService.smali" | head -n 1)
    if [ -f "$file" ]; then
        sed -i 's/sget-boolean v0, Lmiui\/os\/Build;->IS_INTERNATIONAL_BUILD:Z/const\/4 v0, 0x1/g' "$file"
        _fp_success "IS_INTERNATIONAL_BUILD patched in ProcessManagerService (v0)"
    else
        _fp_warn "ProcessManagerService.smali not found"
    fi

    # ProcessSceneCleaner (guide shows find v4 but replace with v0)
    file=$(find "$decompile_dir" -type f -path "*/com/android/server/am/ProcessSceneCleaner.smali" | head -n 1)
    if [ -f "$file" ]; then
        sed -i 's/sget-boolean v4, Lmiui\/os\/Build;->IS_INTERNATIONAL_BUILD:Z/const\/4 v0, 0x1/g' "$file"
        _fp_success "IS_INTERNATIONAL_BUILD patched in ProcessSceneCleaner (v4 → v0)"
    else
        _fp_warn "ProcessSceneCleaner.smali not found"
    fi

    _fp_success "CN notification fix applied to miui-services.jar"
}
