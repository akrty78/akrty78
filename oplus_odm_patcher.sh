#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  OPLUS-ODM-BUILDER v4.0 — no loop mount, no stdout capture bugs
#  Uses debugfs/fsck.erofs. Paths passed via state files, never $()
# ═══════════════════════════════════════════════════════════════

set +e
SCRIPT_START=$(date +%s)
WORK_DIR="${ODM_WORK_DIR:-/mnt/oplus_odm_builder_$$}"
TOTAL_STEPS=13
OPLUS_OTA_URL="$1"
XIAOMI_OTA_URL="$2"

# ─── All log output goes to stderr. Stdout is NEVER used inside functions. ───
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; MAGENTA='\033[0;35m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC}  $*" >&2; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*" >&2; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*" >&2; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()  { printf '\n%b[%s/%s] %s%b\n%s\n' "$MAGENTA" "$1" "$TOTAL_STEPS" "$2" "$NC" \
               "$(printf '─%.0s' $(seq 1 60))" >&2; }
die()   { err "$*"; exit 1; }

# ─── Telegram: one message, edited in place ───────────────────
TG_ID=""
tg() {
    [ -z "$TELEGRAM_TOKEN" ] || [ -z "$CHAT_ID" ] && return
    local ts; ts=$(date +"%H:%M:%S")
    local payload; payload=$(jq -n \
        --arg c  "$CHAT_ID" \
        --arg id "$TG_ID" \
        --arg t  "$(printf '⚙️ *OPLUS-ODM-BUILDER*\n\n%s\n_%s_' "$1" "$ts")" \
        'if $id == "" then
            {chat_id:$c, text:$t, parse_mode:"Markdown"}
         else
            {chat_id:$c, message_id:($id|tonumber), text:$t, parse_mode:"Markdown"}
         end')
    local endpoint="sendMessage"
    [ -n "$TG_ID" ] && endpoint="editMessageText"
    local resp; resp=$(curl -s -X POST \
        "https://api.telegram.org/bot${TELEGRAM_TOKEN}/${endpoint}" \
        -H "Content-Type: application/json" -d "$payload")
    [ -z "$TG_ID" ] && TG_ID=$(jq -r '.result.message_id // empty' <<< "$resp")
}

trap 'for m in "$WORK_DIR"/mnt_*; do
    mountpoint -q "$m" 2>/dev/null && umount -l "$m" 2>/dev/null; done' EXIT

[ -z "$OPLUS_OTA_URL" ] || [ -z "$XIAOMI_OTA_URL" ] && \
    die "Usage: $0 <OPLUS_OTA_URL> <XIAOMI_OTA_URL>"
mkdir -p "$WORK_DIR"

# State files — paths are written here, never passed via stdout
STATE_OPLUS_IMG="$WORK_DIR/state.oplus_img"
STATE_XIAOMI_IMG="$WORK_DIR/state.xiaomi_img"
STATE_OPLUS_DIR="$WORK_DIR/state.oplus_dir"
STATE_XIAOMI_DIR="$WORK_DIR/state.xiaomi_dir"

# ═══════════════════════════════════════════════════════════════
#  1. PRE-FLIGHT
# ═══════════════════════════════════════════════════════════════
preflight() {
    step 1 "Pre-flight checks"
    tg "🔍 *[1/13] Pre-flight checks...*"

    local missing=0
    for t in wget unzip jq curl mkfs.ext4 e2fsck resize2fs debugfs payload-dumper-go; do
        if command -v "$t" &>/dev/null; then
            ok "$t ✓"
        else
            err "Missing required tool: $t"
            missing=1
        fi
    done
    [ "$missing" -eq 1 ] && die "Install missing tools and retry"

    command -v simg2img   &>/dev/null && ok "simg2img ✓"   || warn "simg2img not found (needed for sparse images)"
    command -v fsck.erofs &>/dev/null && ok "fsck.erofs ✓" || warn "fsck.erofs not found (needed for EROFS images)"
    command -v xxd        &>/dev/null && ok "xxd ✓"        || warn "xxd not found (od will be used as fallback)"

    local free_gb
    free_gb=$(df --output=avail -BG "$WORK_DIR" 2>/dev/null | tail -1 | tr -d 'G ')
    [ "${free_gb:-0}" -lt 20 ] && \
        die "Need ≥20GB free in $WORK_DIR, have ${free_gb}GB. Set ODM_WORK_DIR to a larger partition."
    ok "Disk: ${free_gb}GB free in $WORK_DIR"
}

# ═══════════════════════════════════════════════════════════════
#  2-3. DOWNLOAD OTA
# ═══════════════════════════════════════════════════════════════
download_ota() {
    local url="$1" out="$2" label="$3"
    info "Downloading $label..."
    local attempt
    for attempt in 1 2 3; do
        rm -f "$out"
        if command -v aria2c &>/dev/null; then
            aria2c -x16 -s16 -k1M \
                --console-log-level=error --summary-interval=10 --download-result=hide \
                -d "$(dirname "$out")" -o "$(basename "$out")" "$url" >&2
        else
            curl -L --progress-bar -o "$out" "$url" >&2
        fi
        [ -f "$out" ] && [ -s "$out" ] && break
        warn "Download attempt $attempt failed, retrying in 5s..."
        sleep 5
    done
    [ -f "$out" ] && [ -s "$out" ] || die "Failed to download $label after 3 attempts"
    ok "$label downloaded: $(du -h "$out" | cut -f1)"
}

# ═══════════════════════════════════════════════════════════════
#  4-5. EXTRACT ODM.IMG FROM OTA
#  Path is written to a state file — NO stdout return value
# ═══════════════════════════════════════════════════════════════
extract_odm_img() {
    local ota="$1" outdir="$2" label="$3" state_file="$4"
    mkdir -p "$outdir"

    info "Extracting payload.bin from $label OTA..."
    # All tool output goes to stderr — unzip stdout → stderr
    unzip -j -o "$ota" "payload.bin" -d "$outdir" >&2
    [ -f "$outdir/payload.bin" ] || die "payload.bin not found in $label OTA"

    info "Dumping odm partition from $label payload..."
    # payload-dumper-go stdout → stderr
    payload-dumper-go -p odm -o "$outdir" "$outdir/payload.bin" >&2
    rm -f "$outdir/payload.bin"

    [ -f "$outdir/odm.img" ] || die "odm.img not extracted from $label payload"
    ok "$label odm.img ready: $(du -h "$outdir/odm.img" | cut -f1)"

    # Write path to state file — never echo to stdout
    echo "$outdir/odm.img" > "$state_file"
}

# ═══════════════════════════════════════════════════════════════
#  6-7. ODM IMAGE → PLAIN DIRECTORY (no loop mount)
#
#  Reads image type from first 4 bytes written to a temp file.
#  Does NOT use $() anywhere. Path written to state file.
#
#  Strategy A: EROFS  → fsck.erofs --extract
#  Strategy B: Sparse → simg2img + debugfs rdump
#  Strategy C: Raw    → debugfs rdump directly
# ═══════════════════════════════════════════════════════════════
img_to_dir() {
    local img="$1" destdir="$2" label="$3" state_file="$4"
    mkdir -p "$destdir"

    # ── Read magic bytes into a temp binary file ──────────────
    # Using a temp file avoids any shell variable encoding issues with binary data
    local magic_bin="$WORK_DIR/.magic_${label}"
    dd if="$img" bs=4 count=1 of="$magic_bin" 2>/dev/null

    # Convert to hex string using xxd or od
    local magic=""
    if command -v xxd &>/dev/null; then
        magic=$(xxd -p "$magic_bin" 2>/dev/null | tr -d '\n')
    else
        magic=$(od -A n -t x1 -N 4 "$magic_bin" 2>/dev/null | tr -d ' \n')
    fi
    rm -f "$magic_bin"

    info "$label image magic: '$magic'"

    # ── EROFS: magic = e2e1f5e0 ───────────────────────────────
    if [ "${magic:0:8}" = "e2e1f5e0" ]; then
        info "$label is EROFS"
        command -v fsck.erofs &>/dev/null || die "fsck.erofs required for EROFS images (install erofs-utils)"
        fsck.erofs --extract="$destdir" "$img" >&2 || die "fsck.erofs extraction failed for $label"
        ok "$label EROFS → $(find "$destdir" -type f | wc -l) files"
        echo "$destdir" > "$state_file"
        return
    fi

    local workimg="$img"

    # ── Sparse ext4: magic = ed26ff3a ─────────────────────────
    if [ "${magic:0:8}" = "ed26ff3a" ]; then
        info "$label is Android sparse — converting with simg2img..."
        command -v simg2img &>/dev/null || \
            die "simg2img required for sparse images (install android-sdk-libsparse-utils)"

        # Check disk space before expanding
        local sparse_bytes raw_estimate free_bytes
        sparse_bytes=$(stat -c%s "$img")
        raw_estimate=$(( sparse_bytes * 4 ))  # sparse typically expands ~3-4x
        free_bytes=$(df --output=avail -B1 "$WORK_DIR" 2>/dev/null | tail -1 | tr -d ' ')
        if [ "${free_bytes:-0}" -lt "$raw_estimate" ]; then
            die "$label sparse→raw needs ~$((raw_estimate/1024/1024/1024))GB, only $((free_bytes/1024/1024/1024))GB free in $WORK_DIR"
        fi

        workimg="${img%.img}_raw.img"
        simg2img "$img" "$workimg" >&2 || die "simg2img conversion failed for $label"
        ok "Sparse→raw: $(du -h "$workimg" | cut -f1)"
    else
        info "$label image is raw (magic=$magic) — proceeding with debugfs"
    fi

    # ── EXT4: extract with debugfs (no mount needed) ──────────
    info "Extracting $label contents via debugfs..."
    debugfs -R "rdump / $destdir" "$workimg" >&2
    local rc=$?

    # Clean up raw temp file if we created it
    [ "$workimg" != "$img" ] && rm -f "$workimg"

    # Verify extraction worked by checking for etc/ or lib/ directories
    if [ $rc -ne 0 ] && [ ! -d "$destdir/etc" ] && [ ! -d "$destdir/lib" ]; then
        die "debugfs extraction failed for $label (exit $rc, no etc/ or lib/ found)"
    fi

    ok "$label extracted: $(find "$destdir" -maxdepth 1 -mindepth 1 | wc -l) top-level entries"
    echo "$destdir" > "$state_file"
}

# ═══════════════════════════════════════════════════════════════
#  8. EXTRACT OPLUS HAL COMPONENTS
# ═══════════════════════════════════════════════════════════════
extract_oplus() {
    local src="$1" dst="$2"
    mkdir -p "$dst"/{bin/hw,lib,lib64,etc/init,etc/permissions,etc/vintf/manifest}
    local perm="$dst/.permissions"
    > "$perm"

    # Record file permissions for replay during injection
    _rec() {
        printf '%s\t%s\t%s:%s\n' "$2" \
            "$(stat -c '%a' "$1" 2>/dev/null || echo 644)" \
            "$(stat -c '%u' "$1" 2>/dev/null || echo 0)" \
            "$(stat -c '%g' "$1" 2>/dev/null || echo 2000)" >> "$perm"
    }

    local bins=0 libs=0 cfgs=0

    # ── /odm/bin/ ─────────────────────────────────────────────
    for f in "$src"/bin/*; do
        [ -f "$f" ] || continue
        local n; n=$(basename "$f")
        case "$n" in
            *oplus*|vendor.oplus.*|vendor-oplus-*|oplus_performance*)
                cp -a "$f" "$dst/bin/"
                _rec "$f" "/odm/bin/$n"
                bins=$((bins+1))
                ;;
        esac
    done

    # ── /odm/bin/hw/ ──────────────────────────────────────────
    for f in "$src"/bin/hw/*; do
        [ -f "$f" ] || continue
        local n; n=$(basename "$f")
        case "$n" in
            *oplus*|*charger*|*stability*|*performance*|*powermonitor*|*olc2*|*power.stats*)
                cp -a "$f" "$dst/bin/hw/"
                _rec "$f" "/odm/bin/hw/$n"
                bins=$((bins+1))
                ;;
        esac
    done

    # ── /odm/lib/ and /odm/lib64/ ─────────────────────────────
    for ld in lib lib64; do
        [ -d "$src/$ld" ] || continue
        for f in "$src/$ld"/*.so; do
            [ -f "$f" ] || continue
            local n; n=$(basename "$f")
            case "$n" in
                vendor.oplus.*|libGaiaClient*|libosense*|libosensenativeproxy*|\
                *oplus*|*performance*|*charger*|*olc2*|*powermonitor*|\
                *handlefactory*|*power.stats*|*osense*)
                    cp -a "$f" "$dst/$ld/"
                    _rec "$f" "/odm/$ld/$n"
                    libs=$((libs+1))
                    ;;
            esac
        done
    done

    # ── /odm/etc/init/*.rc ────────────────────────────────────
    for f in "$src"/etc/init/*.rc; do
        [ -f "$f" ] || continue
        local n; n=$(basename "$f")
        case "$n" in
            *oplus*|*charger*|*stability*|*performance*|*powermonitor*|*olc2*|*power.stats*)
                cp -a "$f" "$dst/etc/init/"
                _rec "$f" "/odm/etc/init/$n"
                cfgs=$((cfgs+1))
                ;;
        esac
    done

    # ── /odm/etc/permissions/*.xml ────────────────────────────
    for f in "$src"/etc/permissions/*.xml; do
        [ -f "$f" ] || continue
        local n; n=$(basename "$f")
        case "$n" in
            *oplus*|*charger*|*stability*|*performance*|*olc2*|*power*)
                cp -a "$f" "$dst/etc/permissions/"
                _rec "$f" "/odm/etc/permissions/$n"
                cfgs=$((cfgs+1))
                ;;
        esac
    done

    # ── /odm/etc/vintf/manifest/*.xml ─────────────────────────
    for f in "$src"/etc/vintf/manifest/*.xml; do
        [ -f "$f" ] || continue
        local n; n=$(basename "$f")
        case "$n" in
            *oplus*|*charger*|*stability*|*performance*|*powermonitor*|*olc2*|*power*)
                cp -a "$f" "$dst/etc/vintf/manifest/"
                _rec "$f" "/odm/etc/vintf/manifest/$n"
                cfgs=$((cfgs+1))
                ;;
        esac
    done

    # ── Whole config directories ───────────────────────────────
    for d in power_profile power_save temperature_profile ThermalServiceConfig; do
        [ -d "$src/etc/$d" ] || continue
        cp -a "$src/etc/$d" "$dst/etc/"
        while IFS= read -r f; do
            _rec "$f" "/odm/etc/${f#$src/etc/}"
        done < <(find "$src/etc/$d" -type f)
        cfgs=$((cfgs + $(find "$src/etc/$d" -type f | wc -l)))
    done

    # ── Standalone config files ────────────────────────────────
    for sc in custom_power.cfg power_stats_config.xml; do
        [ -f "$src/etc/$sc" ] || continue
        cp -a "$src/etc/$sc" "$dst/etc/"
        _rec "$src/etc/$sc" "/odm/etc/$sc"
        cfgs=$((cfgs+1))
    done

    # ── build.prop ────────────────────────────────────────────
    [ -f "$src/build.prop" ] && cp -a "$src/build.prop" "$dst/"

    ok "Extracted OPLUS: $bins binaries, $libs libraries, $cfgs configs"
}

# ═══════════════════════════════════════════════════════════════
#  9. SELinux CONTEXT GENERATION
# ═══════════════════════════════════════════════════════════════
gen_contexts() {
    local oplus_fc="$1" comp_dir="$2" out="$3"
    > "$out"

    # Context transformation rules
    _xform() {
        local ctx="$1" path="$2"
        # All OPLUS HAL exec types → hal_allocator_default_exec
        if echo "$ctx" | grep -qiE \
'oplus.*_exec|oppo.*_exec|hal_oplus|hal_charger|hal_project|hal_fingerprint_oppo|\
hal_face_oplus|oplus_performance|oplus_sensor|oplus_touch|hal_fido|hal_cryptoeng|\
hal_gameopt|transmessage|hal_esim|oplus_osml|oplus_misc|oplus_sensor_aidl|\
oplus_nfc|oplus_rpmh|oplus_wifi|oplus_location|hal_vibrator|hal_urcc|\
nfcextns|displaypanelfeature|dvs_aidl|riskdetect|fingerprintpay'; then
            echo "u:object_r:hal_allocator_default_exec:s0"; return
        fi
        # Any binary in /odm/bin/ with an _exec context
        if echo "$path" | grep -qE '^/odm/bin/' && echo "$ctx" | grep -qE '_exec:s0$'; then
            echo "u:object_r:hal_allocator_default_exec:s0"; return
        fi
        # Preserve these as-is
        echo "$ctx" | grep -q 'same_process_hal_file' && { echo "$ctx"; return; }
        echo "$ctx" | grep -q 'vendor_configs_file'   && { echo "$ctx"; return; }
        echo "$ctx" | grep -q 'vendor_file'            && { echo "$ctx"; return; }
        # Fallback by path type
        echo "$path" | grep -qE '\.so'       && { echo "u:object_r:vendor_file:s0"; return; }
        echo "$path" | grep -qE '^/odm/etc/' && { echo "u:object_r:vendor_configs_file:s0"; return; }
        echo "u:object_r:vendor_file:s0"
    }

    # Build list of injected file paths
    local inj="$WORK_DIR/.injected_files"
    find "$comp_dir" -type f | sed "s|^$comp_dir|/odm|" > "$inj"

    local count=0

    # Pass 1: match from OPLUS's own file_contexts
    if [ -f "$oplus_fc" ]; then
        while IFS= read -r line; do
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${line//[[:space:]]/}" ]] && continue
            local fc_path fc_ctx
            fc_path=$(awk '{print $1}' <<< "$line")
            fc_ctx=$(awk  '{print $2}' <<< "$line")
            [ -z "$fc_path" ] || [ -z "$fc_ctx" ] && continue

            # Normalise path prefix for matching
            local norm_path
            norm_path=$(sed 's|/(vendor|odm)/|/odm/|g; s|\\\.|\.|g' <<< "$fc_path")

            # Check if any injected file matches this regex
            if grep -qE "$(sed 's|/(vendor|odm)/|/odm/|g' <<< "$fc_path")" "$inj" 2>/dev/null; then
                local new_path new_ctx
                new_path=$(sed 's|/(vendor|odm)/|/odm/|g' <<< "$fc_path")
                new_ctx=$(_xform "$fc_ctx" "$norm_path")
                echo "$new_path $new_ctx" >> "$out"
                count=$((count+1))
            fi
        done < "$oplus_fc"
    fi

    # Pass 2: auto-generate for any injected file not already covered
    while IFS= read -r f; do
        grep -qF "$f" "$out" 2>/dev/null && continue
        local esc_path ctx
        esc_path=$(sed 's/\./\\./g; s/+/\\+/g' <<< "$f")
        if   echo "$f" | grep -qE '^/odm/bin/';                       then ctx="u:object_r:hal_allocator_default_exec:s0"
        elif echo "$f" | grep -qE '^/odm/lib(64)?/.*osense.*\.so$';   then ctx="u:object_r:same_process_hal_file:s0"
        elif echo "$f" | grep -qE '^/odm/lib(64)?/.*\.so$';           then ctx="u:object_r:vendor_file:s0"
        elif echo "$f" | grep -qE '^/odm/etc/';                       then ctx="u:object_r:vendor_configs_file:s0"
        else                                                                 ctx="u:object_r:vendor_file:s0"
        fi
        echo "$esc_path $ctx" >> "$out"
        count=$((count+1))
    done < "$inj"

    # Standard directory context entries
    cat >> "$out" << 'DIREOF'
/odm/etc u:object_r:vendor_configs_file:s0
/odm/etc/init u:object_r:vendor_configs_file:s0
/odm/etc/permissions u:object_r:vendor_configs_file:s0
/odm/etc/vintf u:object_r:vendor_configs_file:s0
/odm/etc/vintf/manifest u:object_r:vendor_configs_file:s0
/odm/etc/power_profile u:object_r:vendor_configs_file:s0
/odm/etc/power_save u:object_r:vendor_configs_file:s0
/odm/etc/temperature_profile u:object_r:vendor_configs_file:s0
/odm/etc/ThermalServiceConfig u:object_r:vendor_configs_file:s0
/odm/lib u:object_r:vendor_file:s0
/odm/lib64 u:object_r:vendor_file:s0
DIREOF

    sort -u -o "$out" "$out"
    ok "Generated $count SELinux context entries"
}

# ═══════════════════════════════════════════════════════════════
#  10. INJECT OPLUS INTO XIAOMI DIRECTORY
#      SELinux contexts are injected BEFORE repacking
# ═══════════════════════════════════════════════════════════════
inject_oplus() {
    local src="$1" dst="$2" ctx_file="$3"
    local bins=0 libs=0 cfgs=0

    # Binaries
    for d in bin bin/hw; do
        [ -d "$src/$d" ] || continue
        mkdir -p "$dst/$d"
        for f in "$src/$d"/*; do
            [ -f "$f" ] && cp -a "$f" "$dst/$d/" && bins=$((bins+1))
        done
    done

    # Libraries
    for ld in lib lib64; do
        [ -d "$src/$ld" ] || continue
        mkdir -p "$dst/$ld"
        for f in "$src/$ld"/*.so; do
            [ -f "$f" ] && cp -a "$f" "$dst/$ld/" && libs=$((libs+1))
        done
    done

    # Config files (recursive, preserving structure)
    for cdir in etc/init etc/permissions etc/vintf/manifest \
                etc/power_profile etc/power_save etc/temperature_profile etc/ThermalServiceConfig; do
        [ -d "$src/$cdir" ] || continue
        mkdir -p "$dst/$cdir"
        while IFS= read -r f; do
            local rel="${f#$src/}"
            mkdir -p "$dst/$(dirname "$rel")"
            cp -a "$f" "$dst/$rel"
        done < <(find "$src/$cdir" -type f)
        cfgs=$((cfgs + $(find "$src/$cdir" -type f 2>/dev/null | wc -l)))
    done

    # Standalone configs
    for sc in etc/custom_power.cfg etc/power_stats_config.xml; do
        [ -f "$src/$sc" ] && cp -a "$src/$sc" "$dst/$sc" && cfgs=$((cfgs+1))
    done

    # Replay saved permissions
    if [ -f "$src/.permissions" ]; then
        while IFS=$'\t' read -r rel mode own; do
            local target="$dst${rel#/odm}"
            [ -f "$target" ] && chmod "$mode" "$target" 2>/dev/null
            [ -f "$target" ] && chown "$own"  "$target" 2>/dev/null
        done < "$src/.permissions"
    fi

    # ─── Inject SELinux contexts BEFORE repacking ──────────────────────
    # Find Xiaomi's existing context file (or create one)
    local fc_target=""
    for c in "$dst/etc/selinux/odm_file_contexts" \
             "$dst/etc/selinux/plat_file_contexts"; do
        [ -f "$c" ] && fc_target="$c" && break
    done
    if [ -z "$fc_target" ]; then
        mkdir -p "$dst/etc/selinux"
        fc_target="$dst/etc/selinux/odm_file_contexts"
        warn "Xiaomi had no odm_file_contexts — creating one"
    fi

    printf '\n# ── OPLUS HAL Contexts (OPLUS-ODM-BUILDER) ──\n' >> "$fc_target"
    cat "$ctx_file" >> "$fc_target"
    ok "SELinux contexts appended to $(basename "$fc_target") (before repack)"
    ok "Injected: $bins binaries, $libs libraries, $cfgs configs"
}

# ═══════════════════════════════════════════════════════════════
#  BUILD PROPERTIES
# ═══════════════════════════════════════════════════════════════
inject_props() {
    local oplus_prop="$1" xiaomi_prop="$2" xiaomi_etc_prop="$3"

    if [ -f "$oplus_prop" ] && [ -f "$xiaomi_prop" ]; then
        {
            printf '\n##############################################\n'
            printf '# OPLUS Properties — OPLUS-ODM-BUILDER\n'
            printf '##############################################\n'
            grep -v '^#' "$oplus_prop" | grep -v '^[[:space:]]*$'
        } >> "$xiaomi_prop"
        ok "OPLUS properties merged into build.prop"
    fi

    mkdir -p "$(dirname "$xiaomi_etc_prop")"
    [ -f "$xiaomi_etc_prop" ] || touch "$xiaomi_etc_prop"

    # Single-quoted heredoc: ${...} literals preserved verbatim
    cat >> "$xiaomi_etc_prop" << 'IMPORTS'

# ── OPLUS Imports (OPLUS-ODM-BUILDER) ──
import /odm/nexdroid.prop
import /odm/etc/${ro.boot.prjname}/build.gsi.prop
import /odm/etc/${ro.boot.prjname}/build.${ro.boot.flag}.prop
import /mnt/vendor/my_product/etc/${ro.boot.prjname}/build.${ro.boot.flag}.prop
import /my_bigball/build.prop
import /my_carrier/build.prop
import /my_company/build.prop
import /my_engineering/build.prop
import /my_heytap/build.prop
import /my_manifest/build.prop
import /my_preload/build.prop
import /my_product/build.prop
import /my_region/build.prop
import /my_stock/build.prop
IMPORTS
    ok "OPLUS import statements added to etc/build.prop"
}

# ═══════════════════════════════════════════════════════════════
#  11. REPACK DIRECTORY → EXT4 IMAGE
# ═══════════════════════════════════════════════════════════════
repack_odm() {
    local srcdir="$1" outimg="$2" fc="$3"

    local used_bytes
    used_bytes=$(du -sb "$srcdir" | cut -f1)
    local img_bytes=$(( (used_bytes * 115) / 100 ))
    [ "$img_bytes" -lt 268435456 ] && img_bytes=268435456
    info "Repacking: $(( used_bytes/1024/1024 ))MB content → $(( img_bytes/1024/1024 ))MB image"

    # Strategy 1: make_ext4fs (best — embeds SELinux natively)
    if command -v make_ext4fs &>/dev/null; then
        info "Trying make_ext4fs..."
        if [ -f "$fc" ]; then
            make_ext4fs -l "$img_bytes" -L odm -a odm -S "$fc" "$outimg" "$srcdir" >&2
        else
            make_ext4fs -l "$img_bytes" -L odm -a odm "$outimg" "$srcdir" >&2
        fi
        if [ -f "$outimg" ] && [ -s "$outimg" ]; then
            ok "Repacked with make_ext4fs"
        else
            warn "make_ext4fs failed, falling back to mkfs.ext4"
            rm -f "$outimg"
        fi
    fi

    # Strategy 2: mkfs.ext4 + mount + copy
    if [ ! -s "$outimg" ]; then
        info "Creating ext4 image with mkfs.ext4..."
        dd if=/dev/zero of="$outimg" bs=1 count=0 seek="$img_bytes" 2>/dev/null
        mkfs.ext4 -q -L odm -b 4096 "$outimg" >&2

        local mnt="$WORK_DIR/mnt_repack"
        mkdir -p "$mnt"
        mount -o loop "$outimg" "$mnt" || die "Cannot mount new ext4 image for fill"
        cp -a "$srcdir"/. "$mnt/" >&2 || true
        sync
        umount "$mnt"
        rmdir "$mnt"

        # Apply SELinux contexts if e2fsdroid is available
        if command -v e2fsdroid &>/dev/null && [ -f "$fc" ]; then
            info "Applying SELinux contexts via e2fsdroid..."
            e2fsdroid -e -S "$fc" -a /odm "$outimg" >&2 && \
                ok "e2fsdroid contexts applied" || warn "e2fsdroid returned non-zero"
        fi
        ok "Repacked with mkfs.ext4"
    fi

    # Finalise
    e2fsck -fy "$outimg" >/dev/null 2>&1 || true
    resize2fs -M "$outimg" >/dev/null 2>&1 || true
    ok "Final image: $(du -h "$outimg" | cut -f1)"
}

# ═══════════════════════════════════════════════════════════════
#  12. UPLOAD TO PIXELDRAIN
# ═══════════════════════════════════════════════════════════════
upload_pixeldrain() {
    local file="$1"
    info "Uploading to PixelDrain..."
    local resp
    if [ -n "$PIXELDRAIN_KEY" ]; then
        resp=$(curl -s -T "$file" -u ":$PIXELDRAIN_KEY" "https://pixeldrain.com/api/file/")
    else
        resp=$(curl -s -T "$file" "https://pixeldrain.com/api/file/")
    fi
    local id; id=$(jq -r '.id // empty' <<< "$resp")
    [ -z "$id" ] && die "PixelDrain upload failed: $resp"
    DOWNLOAD_LINK="https://pixeldrain.com/u/$id"
    ok "Uploaded: $DOWNLOAD_LINK"
}

notify_done() {
    local link="$1" sz="$2" elapsed="$3"
    local target="${REQUESTER_CHAT_ID:-$CHAT_ID}"
    [ -z "$TELEGRAM_TOKEN" ] || [ -z "$target" ] && return

    # Delete the progress message
    [ -n "$TG_ID" ] && curl -s -X POST \
        "https://api.telegram.org/bot${TELEGRAM_TOKEN}/deleteMessage" \
        -d chat_id="$target" -d message_id="$TG_ID" >/dev/null

    local msg; msg=$(jq -n \
        --arg c  "$target" \
        --arg u  "$link" \
        --arg s  "$sz" \
        --arg t  "$elapsed" \
        --arg d  "$(date +'%H:%M')" \
        '{
            chat_id:$c,
            parse_mode:"Markdown",
            disable_web_page_preview:true,
            text:("⚙️ *OPLUS-ODM-BUILDER*\n\n```\nODM Patched Successfully\n```\n\n*Injected:*\n— OPLUS HALs \\& Binaries\n— Shared Libraries (lib/lib64)\n— Init Scripts \\& RC files\n— VINTF Manifests\n— SELinux Contexts\n— Build Properties\n\n📦 Size: `"+$s+"`\n⏱ Time: `"+$t+"`\n🕐 Built: `"+$d+"`"),
            reply_markup:{inline_keyboard:[[{text:"⬇️ Download ODM",url:$u}]]}
        }')
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" -d "$msg" >/dev/null
    ok "Telegram notification sent"
}

# ═══════════════════════════════════════════════════════════════
#  MAIN PIPELINE
# ═══════════════════════════════════════════════════════════════
main() {
    printf '\n%b══════════════════════════════════════\n  OPLUS-ODM-BUILDER v4.0\n══════════════════════════════════════%b\n\n' \
        "$MAGENTA" "$NC" >&2

    preflight

    # Step 2 — Download OPLUS OTA
    step 2 "Downloading OPLUS OTA"
    tg "📥 *[2/13] Downloading OPLUS OTA...*"
    download_ota "$OPLUS_OTA_URL" "$WORK_DIR/oplus_ota.zip" "OPLUS OTA"

    # Step 3 — Download Xiaomi OTA
    step 3 "Downloading Xiaomi OTA"
    tg "📥 *[3/13] Downloading Xiaomi OTA...*"
    download_ota "$XIAOMI_OTA_URL" "$WORK_DIR/xiaomi_ota.zip" "Xiaomi OTA"

    # Step 4 — Extract OPLUS ODM image (path written to state file)
    step 4 "Extracting OPLUS ODM image"
    tg "📦 *[4/13] Extracting OPLUS ODM image...*"
    extract_odm_img "$WORK_DIR/oplus_ota.zip" "$WORK_DIR/oplus_extracted" "OPLUS" "$STATE_OPLUS_IMG"
    rm -f "$WORK_DIR/oplus_ota.zip"
    local OPLUS_IMG; OPLUS_IMG=$(cat "$STATE_OPLUS_IMG")

    # Step 5 — Extract Xiaomi ODM image
    step 5 "Extracting Xiaomi ODM image"
    tg "📦 *[5/13] Extracting Xiaomi ODM image...*"
    extract_odm_img "$WORK_DIR/xiaomi_ota.zip" "$WORK_DIR/xiaomi_extracted" "Xiaomi" "$STATE_XIAOMI_IMG"
    rm -f "$WORK_DIR/xiaomi_ota.zip"
    local XIAOMI_IMG; XIAOMI_IMG=$(cat "$STATE_XIAOMI_IMG")

    # Step 6 — Unpack OPLUS image to directory
    step 6 "Unpacking OPLUS ODM"
    tg "🔓 *[6/13] Unpacking OPLUS ODM...*"
    img_to_dir "$OPLUS_IMG" "$WORK_DIR/oplus_dir" "OPLUS" "$STATE_OPLUS_DIR"
    local OPLUS_DIR; OPLUS_DIR=$(cat "$STATE_OPLUS_DIR")

    # Step 7 — Unpack Xiaomi image to directory
    step 7 "Unpacking Xiaomi ODM"
    tg "🔓 *[7/13] Unpacking Xiaomi ODM...*"
    img_to_dir "$XIAOMI_IMG" "$WORK_DIR/xiaomi_dir" "Xiaomi" "$STATE_XIAOMI_DIR"
    local XIAOMI_DIR; XIAOMI_DIR=$(cat "$STATE_XIAOMI_DIR")

    # Step 8 — Extract OPLUS HAL components
    step 8 "Extracting OPLUS components"
    tg "🔍 *[8/13] Extracting OPLUS HALs, libs & configs...*"
    extract_oplus "$OPLUS_DIR" "$WORK_DIR/oplus_comp"

    # Step 9 — Generate SELinux contexts
    step 9 "Generating SELinux contexts"
    tg "🛡 *[9/13] Generating SELinux contexts...*"
    local oplus_fc=""
    for fc in "$OPLUS_DIR/etc/selinux/odm_file_contexts" \
               "$OPLUS_DIR/file_contexts"; do
        [ -f "$fc" ] && oplus_fc="$fc" && info "Using OPLUS file_contexts: $fc" && break
    done
    [ -z "$oplus_fc" ] && warn "No OPLUS file_contexts found — using auto-generation only"

    local ctx_out="$WORK_DIR/oplus_contexts.txt"
    gen_contexts "$oplus_fc" "$WORK_DIR/oplus_comp" "$ctx_out"

    # Step 10 — Inject OPLUS into Xiaomi + contexts + properties
    step 10 "Injecting OPLUS into Xiaomi ODM"
    tg "💉 *[10/13] Injecting OPLUS into Xiaomi ODM...*"
    inject_oplus "$WORK_DIR/oplus_comp" "$XIAOMI_DIR" "$ctx_out"
    inject_props \
        "$WORK_DIR/oplus_comp/build.prop" \
        "$XIAOMI_DIR/build.prop" \
        "$XIAOMI_DIR/etc/build.prop"

    # Free OPLUS data — no longer needed
    rm -rf "$WORK_DIR/oplus_dir" "$WORK_DIR/oplus_comp" "$WORK_DIR/oplus_extracted"

    # Step 11 — Repack Xiaomi directory → ext4 image
    step 11 "Repacking patched ODM"
    tg "📦 *[11/13] Repacking ODM image...*"
    repack_odm "$XIAOMI_DIR" "$WORK_DIR/patched_odm.img" "$ctx_out"

    # Step 12 — Upload + notify
    step 12 "Uploading to PixelDrain"
    tg "☁️ *[12/13] Uploading to PixelDrain...*"
    upload_pixeldrain "$WORK_DIR/patched_odm.img"

    local secs=$(( $(date +%s) - SCRIPT_START ))
    local elapsed; elapsed=$(printf "%02dm %02ds" $((secs/60)) $((secs%60)))
    local fsize; fsize=$(du -h "$WORK_DIR/patched_odm.img" 2>/dev/null | cut -f1)
    notify_done "$DOWNLOAD_LINK" "$fsize" "$elapsed"

    # Step 13 — Cleanup
    step 13 "Cleanup"
    tg "🧹 *[13/13] Cleaning up...*"
    rm -rf "$WORK_DIR"

    printf '\n%b══════════════════════════════════════\n  ✅ COMPLETE\n  📥 %s\n  📦 %s  ⏱ %s\n══════════════════════════════════════%b\n\n' \
        "$GREEN" "$DOWNLOAD_LINK" "$fsize" "$elapsed" "$NC" >&2
}

main
