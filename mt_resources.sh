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
    local json_dir="$GITHUB_WORKSPACE/mt_resources"

    log_info "[MTCli] Processing MT-Resources pipeline..."

    # Check if a custom config directory exists
    if [ ! -d "$json_dir" ]; then
        log_warning "[MTCli] No mt_resources directory found at $json_dir. Skipping."
        return 0
    fi

    # Execute all JSON files placed by the bot
    for config_json in "$json_dir"/*.json; do
        if [ -f "$config_json" ]; then
            log_info "[MTCli] Triggering MTCli for: $(basename "$config_json")"
            mtcli_run "$config_json" || {
                log_error "[MTCli] Pipeline failed for $config_json"
                return 1
            }
        fi
    done

    log_info "[MTCli] MT-Resources injection completed."
    return 0
}
