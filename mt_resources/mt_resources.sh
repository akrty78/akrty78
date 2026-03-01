#!/bin/bash

# ==============================================================================
# MT-RESOURCES ENGINE INTEGRATION SCRIPT
# Acts as a bridge between the HyperOS Modder script (mod.sh) and MTCli (Java).
# Automatically maps MT-Resources commands to the mtcli execution pipeline.
# ==============================================================================

# Ensure mtcli is available
MTCli_JAR="$BIN_DIR/mtcli.jar"

if [ ! -f "$MTCli_JAR" ]; then
    log_error "[MTCli] mtcli.jar not found in $BIN_DIR. Aborting MT-Resources module."
    return 1
fi

mtcli_run() {
    local config_json="$1"
    log_info "[MTCli] Running pipeline: $config_json"
    java -jar "$MTCli_JAR" run --config "$config_json" --verbose
    return $?
}

# MT-Resources dynamic processing handler (called by mod.sh)
process_mt_resources() {
    local DUMP_DIR="$1"
    local json_dir="$(dirname "${BASH_SOURCE[0]}")"
    local part_name=$(basename "$DUMP_DIR" | sed 's/_dump//')

    log_info "[MTCli] Processing MT-Resources for partition: $part_name"

    # Check if a custom config directory exists
    if [ ! -d "$json_dir" ]; then
        log_warning "[MTCli] No mt_resources directory found at $json_dir. Skipping."
        return 0
    fi

    # Create a temporary symlink in the workspace so MTCli can resolve paths like "product/app/..."
    cd "$GITHUB_WORKSPACE" || return 1
    ln -sfn "$DUMP_DIR" "$part_name"

    local processed_any=0

    # Execute JSON files placed by the bot, but only if their target APK exists in this partition
    for config_json in "$json_dir"/*.json; do
        if [ -f "$config_json" ]; then
            # Extract apk_path and out_apk_path from JSON (strictly matching the exact keys)
            local target_apk=$(grep -oP '"apk_path"\s*:\s*"\K[^"]+' "$config_json")
            local out_apk=$(grep -oP '"out_apk_path"\s*:\s*"\K[^"]+' "$config_json")
            
            if [ -n "$target_apk" ] && [ -f "$GITHUB_WORKSPACE/$target_apk" ]; then
                log_info "[MTCli] Found target $target_apk. Triggering MTCli for: $(basename "$config_json")"
                mtcli_run "$config_json" || {
                    log_error "[MTCli] Pipeline failed for $config_json"
                    rm -f "$part_name"
                    return 1
                }
                
                # If out_apk_path was specified and generated, overwrite the original APK
                if [ -n "$out_apk" ] && [ -f "$GITHUB_WORKSPACE/$out_apk" ]; then
                    mv -f "$GITHUB_WORKSPACE/$out_apk" "$GITHUB_WORKSPACE/$target_apk"
                    log_success "[MTCli] Applied MTCli patches to $target_apk"
                fi
                
                processed_any=1
            fi
        fi
    done

    # Clean up symlink
    rm -f "$part_name"

    if [ "$processed_any" -eq 1 ]; then
        log_info "[MTCli] MT-Resources injection strictly completed for $part_name."
    fi
    return 0
}
