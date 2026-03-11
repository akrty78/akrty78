#!/bin/bash
# ==============================================================================
# MT-SMALI ENGINE — JSON-driven Smali Patch Engine
# Sibling of mt_resources.sh. Patches Dalvik bytecode (smali) inside DEX/APK
# using baksmali/smali JARs. No apktool. No resource rebuild.
#
# Usage: mt_smali.sh [OPTIONS] <patch_file.json>
#        OR source mt_smali.sh to use process_mt_smali() loop
# ==============================================================================
set -euo pipefail

# ── Globals ───────────────────────────────────────────────────
MTCLI_HOME="${MTCLI_HOME:-${BIN_DIR:-/usr/local/bin}}"
MTCLI_TMP="${MTCLI_TMP:-/tmp/mt_smali_$$}"
# FIX 6: VERBOSE is global
VERBOSE="${VERBOSE:-0}"

_log()  { echo -e "$1"; }
_info() { echo -e "\033[0;36m[INFO]\033[0m $1"; }
_ok()   { echo -e "\033[0;32m[SUCCESS]\033[0m $1"; }
_warn() { echo -e "\033[1;33m[WARNING]\033[0m $1"; }
_err()  { echo -e "\033[0;31m[ERROR]\033[0m $1" >&2; }
_verb() { [ "$VERBOSE" -eq 1 ] && echo -e "\033[0;36m  → \033[0m$1"; }
_die()  { _err "$1"; return 1; }

# ══════════════════════════════════════════════════════════════════
# MAIN CLI ENGINE
# ══════════════════════════════════════════════════════════════════
_run_mt_smali_cli() {
    local INPUT=""
    local OUTPUT=""
    local DEX_NAME="classes.dex"
    local API_LEVEL=34
    local SMALI_ONLY=0
    local NO_BAKSMALI=0
    local DRY_RUN=0
    local BACKUP=0
    local PATCH_FILE=""

    usage() {
        cat <<'EOF'
mt_smali.sh — JSON-driven Smali Patch Engine

Usage: mt_smali.sh [OPTIONS] <patch_file.json>

Options:
  -i, --input   <path>   APK, DEX, or smali directory (required)
  -o, --output  <path>   Output path (default: overwrite input)
  -d, --dex     <name>   DEX to patch (default: classes.dex)
  --smali-only           Skip recompile; output patched smali dir only
  --no-baksmali          Input is already a smali dir; skip disassembly
  --api         <int>    API level for baksmali/smali (default: 34)
  --dry-run              Validate patches without modifying files
  --verbose              Print each patch application detail
  --backup               Backup original DEX before patching
  -h, --help             Show this help

Environment:
  MTCLI_HOME   Directory containing baksmali.jar and smali.jar
  MTCLI_TMP    Temp directory (default: /tmp/mt_smali_$$)
EOF
        return 0
    }

    # ── Argument Parser ───────────────────────────────────────────
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -i|--input)      INPUT="$2"; shift 2 ;;
            -o|--output)     OUTPUT="$2"; shift 2 ;;
            -d|--dex)        DEX_NAME="$2"; shift 2 ;;
            --smali-only)    SMALI_ONLY=1; shift ;;
            --no-baksmali)   NO_BAKSMALI=1; shift ;;
            --api)           API_LEVEL="$2"; shift 2 ;;
            --dry-run)       DRY_RUN=1; shift ;;
            --verbose)       VERBOSE=1; shift ;;
            --backup)        BACKUP=1; shift ;;
            -h|--help)       usage; return 0 ;;
            -*)              _die "Unknown option: $1" || return 1 ;;
            *)
                if [ -z "$PATCH_FILE" ]; then
                    PATCH_FILE="$1"
                else
                    _die "Unexpected argument: $1" || return 1
                fi
                shift ;;
        esac
    done

    [ -z "$PATCH_FILE" ] && { _die "No patch file specified. Use -h for help."; return 1; }
    [ -z "$INPUT" ]      && { _die "No input specified (-i). Use -h for help."; return 1; }
    [ ! -e "$INPUT" ]    && { _die "Input not found: $INPUT"; return 1; }
    [ ! -f "$PATCH_FILE" ] && { _die "Patch file not found: $PATCH_FILE"; return 1; }

    # Validate JSON
    jq empty "$PATCH_FILE" 2>/dev/null || { _die "Malformed JSON: $PATCH_FILE"; return 1; }
    local PATCH_COUNT=$(jq '.patches | length' "$PATCH_FILE")
    [ "$PATCH_COUNT" -eq 0 ] && { _die "No patches defined in $PATCH_FILE"; return 1; }

    # Resolve tools
    local BAKSMALI_JAR="${MTCLI_HOME}/baksmali.jar"
    local SMALI_JAR="${MTCLI_HOME}/smali.jar"
    [ "$NO_BAKSMALI" -eq 0 ] && [ ! -f "$BAKSMALI_JAR" ] && { _die "baksmali.jar not found in $MTCLI_HOME"; return 1; }
    [ "$SMALI_ONLY" -eq 0 ]  && [ ! -f "$SMALI_JAR" ]    && { _die "smali.jar not found in $MTCLI_HOME"; return 1; }

    [ -z "$OUTPUT" ] && OUTPUT="$INPUT"

    # FIX 7: Clone input to output immediately if different so zip inj doesn't lose APK contents
    local INPUT_EXT="${OUTPUT##*.}"
    local INPUT_EXT_LOWER=$(echo "${INPUT##*.}" | tr '[:upper:]' '[:lower:]')
    local IS_ARCHIVE=0
    [ "$INPUT_EXT_LOWER" = "apk" ] || [ "$INPUT_EXT_LOWER" = "zip" ] || [ "$INPUT_EXT_LOWER" = "jar" ] && IS_ARCHIVE=1

    if [ "$OUTPUT" != "$INPUT" ] && [ "$IS_ARCHIVE" -eq 1 ] && [ "$SMALI_ONLY" -eq 0 ]; then
        cp "$INPUT" "$OUTPUT"
    fi

    # ── Step 1: baksmali — Explode DEX to smali ───────────────────
    rm -rf "$MTCLI_TMP" && mkdir -p "$MTCLI_TMP"
    # Immediately copy patch file inside MTCLI_TMP so it survives the rm above
    # (fixes race: process_mt_smali may have staged job JSON inside MTCLI_TMP)
    cp "$PATCH_FILE" "$MTCLI_TMP/patch_job.json"
    PATCH_FILE="$MTCLI_TMP/patch_job.json"
    local SMALI_DIR="$MTCLI_TMP/smali_out"
    local DEX_PATH=""

    if [ "$NO_BAKSMALI" -eq 1 ]; then
        [ ! -d "$INPUT" ] && { _die "--no-baksmali requires input to be a directory"; return 1; }
        SMALI_DIR="$INPUT"
        _info "Using existing smali dir: $SMALI_DIR"
    elif [ -d "$INPUT" ]; then
        _die "Input is a directory but --no-baksmali not set" || return 1
    else
        if [ "$IS_ARCHIVE" -eq 1 ]; then
            # Disassemble ALL DEX files so patches can target classes across any DEX.
            # Each DEX gets its own smali subdir: smali_classes, smali_classes2, etc.
            # _class_to_path searches all subdirs and records which DEX a class lives in.
            # Only the DEX dirs that were modified get recompiled and re-injected.
            local dex_list
            dex_list=$(unzip -l "$INPUT" | grep -oE 'classes[0-9]*\.dex' | sort -V | uniq)
            [ -z "$dex_list" ] && { _die "No classes*.dex found in $INPUT"; return 1; }

            declare -A SMALI_DEX_DIRS   # dex_name -> smali subdir
            local total_classes=0

            for candidate_dex in $dex_list; do
                _info "Disassembling $candidate_dex (API $API_LEVEL)..."
                local cand_path="$MTCLI_TMP/$candidate_dex"
                unzip -p "$INPUT" "$candidate_dex" > "$cand_path" 2>/dev/null
                [ ! -s "$cand_path" ] && { _warn "  Skipping $candidate_dex — empty extract"; continue; }
                local dex_smali_dir="$MTCLI_TMP/smali_${candidate_dex%.dex}"
                mkdir -p "$dex_smali_dir"
                if ! java -jar "$BAKSMALI_JAR" d -a "$API_LEVEL" -o "$dex_smali_dir" "$cand_path" >/dev/null 2>&1; then
                    _warn "  baksmali failed for $candidate_dex — skipping"
                    continue
                fi
                SMALI_DEX_DIRS["$candidate_dex"]="$dex_smali_dir"
                local cnt; cnt=$(find "$dex_smali_dir" -name '*.smali' | wc -l)
                total_classes=$((total_classes + cnt))
                _info "  $candidate_dex: $cnt classes"
            done

            [ ${#SMALI_DEX_DIRS[@]} -eq 0 ] && { _die "Failed to disassemble any DEX from $INPUT"; return 1; }
            _ok "Disassembly complete: $total_classes classes across ${#SMALI_DEX_DIRS[@]} DEX(es)"

            # Primary DEX name (lowest-numbered) for legacy logging
            DEX_NAME=$(printf '%s\n' "${!SMALI_DEX_DIRS[@]}" | sort -V | head -1)
            _info "Using DEX(es): $(printf '%s\n' "${!SMALI_DEX_DIRS[@]}" | sort -V | tr '\n' ' ')"

        elif [ "$INPUT_EXT_LOWER" = "dex" ]; then
            DEX_PATH="$INPUT"
            _info "Disassembling $DEX_NAME (API $API_LEVEL)..."
            mkdir -p "$SMALI_DIR"
            java -jar "$BAKSMALI_JAR" d -a "$API_LEVEL" -o "$SMALI_DIR" "$DEX_PATH" \
                || { _die "baksmali failed"; return 1; }
            _ok "Disassembly complete: $(find "$SMALI_DIR" -name '*.smali' | wc -l) classes"
            declare -A SMALI_DEX_DIRS; SMALI_DEX_DIRS["$DEX_NAME"]="$SMALI_DIR"
        else
            DEX_PATH="$MTCLI_TMP/$DEX_NAME"
            unzip -p "$INPUT" "$DEX_NAME" > "$DEX_PATH" 2>/dev/null \
                || { _die "Cannot extract DEX and unknown file type: $INPUT_EXT"; return 1; }
            [ ! -s "$DEX_PATH" ] && { _die "Extracted DEX is empty — corrupt archive?"; return 1; }
            _info "Disassembling $DEX_NAME (API $API_LEVEL)..."
            mkdir -p "$SMALI_DIR"
            java -jar "$BAKSMALI_JAR" d -a "$API_LEVEL" -o "$SMALI_DIR" "$DEX_PATH" \
                || { _die "baksmali failed"; return 1; }
            _ok "Disassembly complete: $(find "$SMALI_DIR" -name '*.smali' | wc -l) classes"
            declare -A SMALI_DEX_DIRS; SMALI_DEX_DIRS["$DEX_NAME"]="$SMALI_DIR"
        fi

    fi  # end if NO_BAKSMALI / elif dir / else
    # no-baksmali path — seed SMALI_DEX_DIRS from single input dir
    if [ "$NO_BAKSMALI" -eq 1 ]; then
        declare -A SMALI_DEX_DIRS; SMALI_DEX_DIRS["$DEX_NAME"]="$SMALI_DIR"
    fi

    # ══════════════════════════════════════════════════════════════════
    # PATCH ENGINE — Core Functions
    # ══════════════════════════════════════════════════════════════════

    # Tracks which DEX the last resolved class came from (set by _class_to_path)
    _MT_CLASS_DEX_NAME=""

    _class_to_path() {
        local cls="$1"
        local inner="${cls#L}"; inner="${inner%;}"
        _MT_CLASS_DEX_NAME=""
        OUT_SMALI_FILE=""
        local dex_name dex_dir
        # Search DEX dirs in sorted order (classes.dex first, then classes2.dex, etc.)
        for dex_name in $(printf '%s\n' "${!SMALI_DEX_DIRS[@]}" | sort -V); do
            dex_dir="${SMALI_DEX_DIRS[$dex_name]}"
            local candidate="${dex_dir}/${inner}.smali"
            if [ -f "$candidate" ]; then
                _MT_CLASS_DEX_NAME="$dex_name"
                OUT_SMALI_FILE="$candidate"
                return 0
            fi
        done
        return 1
    }

    _return_type() {
        local method="$1"
        echo "${method##*)}"
    }

    _method_name() {
        local method="$1"
        echo "${method%%(*}"
    }

    # FIX 2: Make globals with explicit prefix to avoid scope loss in bash
    _MT_METHOD_START=0
    _MT_METHOD_END=0
    _MT_METHOD_SIG=""

    _find_method_awk() {
        local smali_file="$1"
        local method_sig="$2"
        _MT_METHOD_START=0
        _MT_METHOD_END=0
        _MT_METHOD_SIG=""
    
        # If no parenthesis in sig, treat as name-only (match first method with that name)
        local match_mode="exact"
        [[ "$method_sig" != *"("* ]] && match_mode="name_only"
    
        local result
        result=$(awk -v sig="$method_sig" -v mode="$match_mode" '
        /^\.method / {
            line = $0
            sub(/^\.method +/, "", line)
            while (match(line, /^(public|private|protected|static|final|synchronized|bridge|varargs|native|abstract|strictfp|synthetic|constructor|declared-synchronized) +/)) {
                sub(/^(public|private|protected|static|final|synchronized|bridge|varargs|native|abstract|strictfp|synthetic|constructor|declared-synchronized) +/, "", line)
            }
            sub(/^ +| +$/, "", line)
            matched = 0
            if (mode == "exact") {
                matched = (line == sig)
            } else {
                # name_only: match method name before the first (
                split(line, parts, "(")
                matched = (parts[1] == sig)
            }
            if (matched) { start = NR; searching = 1; sig_found = $NF }
        }
        searching && /^\.end method/ {
            print start " " NR " " sig_found
            exit
        }
        ' "$smali_file")
    
        if [ -n "$result" ]; then
            _MT_METHOD_START=$(echo "$result" | awk '{print $1}')
            _MT_METHOD_END=$(echo "$result" | awk '{print $2}')
            _MT_METHOD_SIG=$(echo "$result" | awk '{print $3}')
            return 0
        fi
        return 1
    }

    _int_to_hex() {
        local val=$1
        if [ "$val" -lt 0 ]; then
            printf -- "-0x%x" $(( -val ))
        else
            printf "0x%x" "$val"
        fi
    }

    _const_insn() {
        local val=$1
        local hex=$(_int_to_hex "$val")
        if [ "$val" -ge -8 ] && [ "$val" -le 7 ]; then
            echo "const/4 v0, $hex"
        elif [ "$val" -ge -32768 ] && [ "$val" -le 32767 ]; then
            echo "const/16 v0, $hex"
        else
            echo "const v0, $hex"
        fi
    }

    local OP_MSG=""

    # FIX 1: new_body split into registers part and instructions part
    op_return_void() {
        local file="$1" method="$2" ret_type
        _find_method_awk "$file" "$method" || { OP_MSG="method not found: $method"; return 1; }
        ret_type=$(_return_type "$_MT_METHOD_SIG")
        [ "$ret_type" != "V" ] && { OP_MSG="return type must be V, got $ret_type"; return 1; }
        if [ "$DRY_RUN" -eq 1 ]; then OP_MSG="OK (dry-run)"; return 0; fi
        _replace_method_body "$file" ".locals 0" "    return-void"
        OP_MSG="✓"
    }

    op_return_true() {
        local file="$1" method="$2" ret_type
        _find_method_awk "$file" "$method" || { OP_MSG="method not found: $method"; return 1; }
        ret_type=$(_return_type "$_MT_METHOD_SIG")
        case "$ret_type" in Z|B|S|C|I) ;; *) OP_MSG="return type must be Z/B/S/C/I, got $ret_type"; return 1;; esac
        if [ "$DRY_RUN" -eq 1 ]; then OP_MSG="OK (dry-run)"; return 0; fi
        _replace_method_body "$file" ".locals 1" "    const/4 v0, 0x1"$'\n'"    return v0"
        OP_MSG="✓"
    }

    op_return_false() {
        local file="$1" method="$2" ret_type
        _find_method_awk "$file" "$method" || { OP_MSG="method not found: $method"; return 1; }
        ret_type=$(_return_type "$_MT_METHOD_SIG")
        case "$ret_type" in Z|B|S|C|I) ;; *) OP_MSG="return type must be Z/B/S/C/I, got $ret_type"; return 1;; esac
        if [ "$DRY_RUN" -eq 1 ]; then OP_MSG="OK (dry-run)"; return 0; fi
        _replace_method_body "$file" ".locals 1" "    const/4 v0, 0x0"$'\n'"    return v0"
        OP_MSG="✓"
    }

    op_return_minus1() {
        local file="$1" method="$2" ret_type
        _find_method_awk "$file" "$method" || { OP_MSG="method not found: $method"; return 1; }
        ret_type=$(_return_type "$_MT_METHOD_SIG")
        case "$ret_type" in Z|B|S|C|I) ;; *) OP_MSG="return type must be Z/B/S/C/I, got $ret_type"; return 1;; esac
        if [ "$DRY_RUN" -eq 1 ]; then OP_MSG="OK (dry-run)"; return 0; fi
        _replace_method_body "$file" ".locals 1" "    const/4 v0, -0x1"$'\n'"    return v0"
        OP_MSG="✓"
    }

    op_return_null() {
        local file="$1" method="$2" ret_type
        _find_method_awk "$file" "$method" || { OP_MSG="method not found: $method"; return 1; }
        ret_type=$(_return_type "$_MT_METHOD_SIG")
        case "$ret_type" in L*|"["*) ;; *) OP_MSG="return type must be object, got $ret_type"; return 1;; esac
        if [ "$DRY_RUN" -eq 1 ]; then OP_MSG="OK (dry-run)"; return 0; fi
        _replace_method_body "$file" ".locals 1" "    const/4 v0, 0x0"$'\n'"    return-object v0"
        OP_MSG="✓"
    }

    op_return_empty_string() {
        local file="$1" method="$2" ret_type
        _find_method_awk "$file" "$method" || { OP_MSG="method not found: $method"; return 1; }
        ret_type=$(_return_type "$_MT_METHOD_SIG")
        [ "$ret_type" != "Ljava/lang/String;" ] && { OP_MSG="return type must be String, got $ret_type"; return 1; }
        if [ "$DRY_RUN" -eq 1 ]; then OP_MSG="OK (dry-run)"; return 0; fi
        _replace_method_body "$file" ".locals 1" "    const-string v0, \"\""$'\n'"    return-object v0"
        OP_MSG="✓"
    }

    op_return_int() {
        local file="$1" method="$2" patch_json="$3" ret_type
        _find_method_awk "$file" "$method" || { OP_MSG="method not found: $method"; return 1; }
        ret_type=$(_return_type "$_MT_METHOD_SIG")
        case "$ret_type" in Z|B|S|C|I) ;; *) OP_MSG="return type must be Z/B/S/C/I, got $ret_type"; return 1;; esac
        local val=$(echo "$patch_json" | jq -r '.value // empty')
        [ -z "$val" ] && { OP_MSG="'value' field required for return_int"; return 1; }
        if [ "$DRY_RUN" -eq 1 ]; then OP_MSG="OK (dry-run)"; return 0; fi
        local insn=$(_const_insn "$val")
        _replace_method_body "$file" ".locals 1" "    $insn"$'\n'"    return v0"
        OP_MSG="✓"
    }

    op_replace_body() {
        local file="$1" method="$2" patch_json="$3"
        local i
        local regs=$(echo "$patch_json" | jq -r '.registers // empty')
        [ -z "$regs" ] && { OP_MSG="'registers' field required for replace_body"; return 1; }
        _find_method_awk "$file" "$method" || { OP_MSG="method not found: $method"; return 1; }
        if [ "$DRY_RUN" -eq 1 ]; then OP_MSG="OK (dry-run)"; return 0; fi

        local pre_body=".registers $regs"
        export MT_BODY_REPL=""
        local line_count=$(echo "$patch_json" | jq '.lines | length')
        for ((i=0; i<line_count; i++)); do
            local l=$(echo "$patch_json" | jq -r ".lines[$i]")
            if [ -z "$MT_BODY_REPL" ]; then
                MT_BODY_REPL="    ${l}"
            else
                MT_BODY_REPL="${MT_BODY_REPL}
    ${l}"
            fi
        done
        _replace_method_body "$file" "$pre_body" "$MT_BODY_REPL"
        OP_MSG="✓"
    }

    _replace_method_body() {
        local file="$1" new_registers="$2" new_instructions="$3"
        local tmp_file="${file}.tmp"
        local line_num=0
        local in_target=0
        local in_annotation=0
        local annotations=""
        
        while IFS= read -r line || [[ -n "$line" ]]; do
            line_num=$((line_num + 1))
            if [ "$line_num" -eq "$_MT_METHOD_START" ]; then
                in_target=1
                echo "$line" >> "$tmp_file"
                continue
            fi
            if [ "$in_target" -eq 1 ] && [ "$line_num" -lt "$_MT_METHOD_END" ]; then
                if [[ "$line" =~ ^[[:space:]]*\.annotation ]]; then
                    in_annotation=1
                    annotations="${annotations}${line}\n"
                    continue
                fi
                if [ "$in_annotation" -eq 1 ]; then
                    annotations="${annotations}${line}\n"
                    [[ "$line" =~ ^[[:space:]]*\.end[[:space:]]+annotation ]] && in_annotation=0
                    continue
                fi
                if [[ "$line" =~ ^[[:space:]]*\.param ]] || [[ "$line" =~ ^[[:space:]]*\.end[[:space:]]+param ]]; then
                    annotations="${annotations}${line}\n"
                    continue
                fi
                continue
            fi
            if [ "$in_target" -eq 1 ] && [ "$line_num" -eq "$_MT_METHOD_END" ]; then
                # FIX 1 & FIX 3: Emit registers, then annotations, then instructions
                printf "%s\n" "$new_registers" >> "$tmp_file"
                if [ -n "$annotations" ]; then
                    # Replace literal \n with actual newlines for annotations (from earlier accumulation)
                    # wait, annotations is built with \n string concatenation: annotations="${annotations}${line}\n"
                    # To fix it cleanly without eval, we can use awk or just printf
                    # Let's echo -e the annotations since they don't have user string payloads
                    echo -e "${annotations%\\n}" >> "$tmp_file"
                fi
                printf "%s\n" "$new_instructions" >> "$tmp_file"
                echo "$line" >> "$tmp_file"
                in_target=0
                continue
            fi
            echo "$line" >> "$tmp_file"
        done < "$file"
        mv "$tmp_file" "$file"
    }

    _line_op() {
        local file="$1" method="$2" patch_json="$3" op_type="$4"
        local match=$(echo "$patch_json" | jq -r '.match')
        local match_mode=$(echo "$patch_json" | jq -r '.match_mode // "exact"')
        local occ=$(echo "$patch_json" | jq -r '.occurrence // "first"')
        [ "$match" = "null" ] || [ -z "$match" ] && { OP_MSG="'match' field required"; return 1; }

        if [ "$method" = "*" ]; then
            _do_line_op_file "$file" "$match" "$match_mode" "$occ" "$op_type" "$patch_json"
            return $?
        fi

        _find_method_awk "$file" "$method" || { OP_MSG="method not found: $method"; return 1; }

        if [ "$DRY_RUN" -eq 1 ]; then
            # FIX 10: Safe to use since _find_method_awk sets _MT_ variables
            local body=$(sed -n "${_MT_METHOD_START},${_MT_METHOD_END}p" "$file")
            local count=$(_count_matches "$body" "$match" "$match_mode")
            if [ "$count" -eq 0 ] && [ "$occ" != "all" ]; then OP_MSG="match not found: \"$match\""; return 1; fi
            OP_MSG="OK (dry-run, $count matches)"
            return 0
        fi
        _do_line_op_range "$file" "$_MT_METHOD_START" "$_MT_METHOD_END" "$match" "$match_mode" "$occ" "$op_type" "$patch_json"
    }

    _count_matches() {
        local body="$1" match="$2" mode="$3" count=0
        while IFS= read -r line; do
            local trimmed=$(echo "$line" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
            case "$mode" in
                exact)    [ "$trimmed" = "$match" ] && count=$((count+1)) ;;
                contains) [[ "$trimmed" == *"$match"* ]] && count=$((count+1)) ;;
                regex)    echo "$trimmed" | grep -qE "$match" && count=$((count+1)) ;;
            esac
        done <<< "$body"
        echo $count
    }

    _do_line_op_range() {
        local file="$1" start="$2" end="$3" match="$4" mode="$5" occ="$6" op="$7" pjson="$8"
        local scope="${9:-method}"  # 'method' (default) or 'file'
        local i
        local -a new_lines=()
        if [ "$op" != "delete" ]; then
            local key="lines"
            [ "$op" = "replace" ] && key="replacement"
            local nl_count=$(echo "$pjson" | jq ".$key | length")
            for ((i=0; i<nl_count; i++)); do new_lines+=("$(echo "$pjson" | jq -r ".$key[$i]")"); done
        fi

        local -a match_lines=()
        local line_num=0
        local in_annotation=0
        while IFS= read -r line; do
            line_num=$((line_num + 1))
            [ "$line_num" -lt "$start" ] || [ "$line_num" -gt "$end" ] && continue
            # Skip annotation blocks and smali directives ONLY for method-scoped scans
            if [ "$scope" = "method" ]; then
                if [[ "$line" =~ ^[[:space:]]*\.annotation ]]; then in_annotation=1; continue; fi
                if [ "$in_annotation" -eq 1 ]; then
                    [[ "$line" =~ ^[[:space:]]*\.end[[:space:]]+annotation ]] && in_annotation=0
                    continue
                fi
                [[ "$line" =~ ^[[:space:]]*\.(method|end[[:space:]]+method|registers|locals|line|prologue|epilogue|param|local|restart|end[[:space:]]+local|catch|catchall) ]] && continue
            fi

            local trimmed=$(echo "$line" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
            local matched=0
            case "$mode" in
                exact)    [ "$trimmed" = "$match" ] && matched=1 ;;
                contains) [[ "$trimmed" == *"$match"* ]] && matched=1 ;;
                regex)    echo "$trimmed" | grep -qE "$match" && matched=1 ;;
            esac
            [ "$matched" -eq 1 ] && match_lines+=("$line_num")
        done < "$file"

        local total=${#match_lines[@]}
        if [ "$total" -eq 0 ]; then
            if [ "$occ" = "all" ]; then OP_MSG="✓ (0 matches — no changes)"; return 0; fi
            OP_MSG="match not found: \"$match\""; return 1
        fi

        local -a target_lines=()
        case "$occ" in
            first) target_lines=("${match_lines[0]}") ;;
            last)  target_lines=("${match_lines[$((total-1))]}") ;;
            all)   target_lines=("${match_lines[@]}") ;;
        esac

        local sorted_targets=($(echo "${target_lines[@]}" | tr ' ' '\n' | sort -rn))
        local tmp_file="${file}.tmp"
        cp "$file" "$tmp_file"

        for tl in "${sorted_targets[@]}"; do
            case "$op" in
                replace|delete)
                    if [ "$op" = "delete" ] || [ ${#new_lines[@]} -eq 0 ]; then
                        sed -i "${tl}d" "$tmp_file"
                    else
                        if [ "$mode" = "regex" ]; then
                            # For regex, we use sed to allow backreferences (\1, \2) in the replacement
                            # We only support single-line replacements for regex mode currently
                            local repl="${new_lines[0]}"
                            # Escape only | and & for sed replacement — preserve \1 backreferences as-is
                            local esc_repl=$(printf '%s' "$repl" | sed 's/[&|]/\\&/g')
                            # Escape | for match
                            local esc_match=$(printf '%s' "$match" | sed 's/[|]/\\|/g') # FIX 2: Escape only |
                            # Auto-adjust regex anchor to handle baksmali indentation
                            if [[ "$esc_match" == ^* ]]; then
                                esc_match="^[[:space:]]*${esc_match:1}"
                            fi
                            sed -i -E "${tl}s|${esc_match}|${esc_repl}|" "$tmp_file"
                        else
                            export MT_AWK_REPL=""
                            for nl in "${new_lines[@]}"; do
                                MT_AWK_REPL="${MT_AWK_REPL}    ${nl}
"
                            done
                            awk -v ln="$tl" 'NR==ln{printf "%s", ENVIRON["MT_AWK_REPL"]; next}1' "$tmp_file" > "${tmp_file}.2"
                            mv "${tmp_file}.2" "$tmp_file"
                        fi
                    fi
                    ;;
                insert_before)
                    export MT_AWK_REPL=""
                    for nl in "${new_lines[@]}"; do
                        MT_AWK_REPL="${MT_AWK_REPL}    ${nl}
"
                    done
                    awk -v ln="$tl" 'NR==ln{printf "%s", ENVIRON["MT_AWK_REPL"]}1' "$tmp_file" > "${tmp_file}.2"
                    mv "${tmp_file}.2" "$tmp_file"
                    ;;
                insert_after)
                    export MT_AWK_REPL=""
                    for nl in "${new_lines[@]}"; do
                        MT_AWK_REPL="${MT_AWK_REPL}    ${nl}
"
                    done
                    awk -v ln="$tl" '{print}NR==ln{printf "%s", ENVIRON["MT_AWK_REPL"]}' "$tmp_file" > "${tmp_file}.2"
                    mv "${tmp_file}.2" "$tmp_file"
                    ;;
            esac
        done
        mv "$tmp_file" "$file"
        OP_MSG="✓ (${#target_lines[@]} lines ${op}d)"
    }

    _do_line_op_file() {
        local file="$1" match="$2" mode="$3" occ="$4" op="$5" pjson="$6"
        local total=$(wc -l < "$file")
        _do_line_op_range "$file" 1 "$total" "$match" "$mode" "$occ" "$op" "$pjson" "file"
    }

    # ── append_to_class: insert lines before the last line (.end class) ──
    # No text matching, no scanning — just appends before EOF.
    op_append_to_class() {
        local file="$1" patch_json="$2"
        local i
        local nl_count=$(echo "$patch_json" | jq '.lines | length')
        [ "$nl_count" -eq 0 ] && { OP_MSG="'lines' array is empty"; return 1; }
        local total=$(wc -l < "$file")
        local ins="\n"
        for ((i=0; i<nl_count; i++)); do
            local line=$(echo "$patch_json" | jq -r ".lines[$i]")
            ins="${ins}${line}\n"
        done
        ins="${ins}\n"
        if [ "$DRY_RUN" -eq 1 ]; then
            OP_MSG="✓ (dry-run, would append $nl_count lines)"
            return 0
        fi
        awk -v ln="$total" -v ins="$ins" 'NR==ln{printf "%s", ins}{print}' "$file" > "${file}.tmp"
        mv "${file}.tmp" "$file"
        OP_MSG="✓ ($nl_count lines appended before .end class)"
    }

    op_replace_string() {
        local file="$1" method="$2" patch_json="$3"
        local old_val=$(echo "$patch_json" | jq -r '.old_value')
        local new_val=$(echo "$patch_json" | jq -r '.new_value')
        [ -z "$old_val" ] || [ "$old_val" = "null" ] && { OP_MSG="'old_value' required"; return 1; }
        [ -z "$new_val" ] || [ "$new_val" = "null" ] && { OP_MSG="'new_value' required"; return 1; }

        local count
        if [ "$method" = "*" ]; then
            count=$(awk -v old="$old_val" '
            index($0, "const-string") != 0 && index($0, "\"" old "\"") != 0 { count++ }
            END { print count+0 }
            ' "$file")
        else
            _find_method_awk "$file" "$method" || { OP_MSG="method not found: $method"; return 1; }
            count=$(awk -v s="$_MT_METHOD_START" -v e="$_MT_METHOD_END" -v old="$old_val" '
            NR>=s && NR<=e && index($0, "const-string") != 0 && index($0, "\"" old "\"") != 0 { count++ }
            END { print count+0 }
            ' "$file")
        fi

        if [ "$DRY_RUN" -eq 1 ]; then OP_MSG="OK (dry-run, $count occurrences)"; return 0; fi
        if [ "$count" -eq 0 ]; then OP_MSG="string not found: \"$old_val\""; return 1; fi

        # FIX 5 & 14: Safe awk-based string replacement and tmp+mv
        local tmp_file="${file}.tmp"
        if [ "$method" = "*" ]; then
            awk -v old="$old_val" -v new="$new_val" '
            {
                # only replace if const-string is found to avoid false positives in metadata
                if (index($0, "const-string") != 0 && index($0, "\"" old "\"") != 0) {
                    # literal string sub
                    target = "\"" old "\""
                    repl = "\"" new "\""
                    while (index($0, target) != 0) {
                        idx = index($0, target)
                        $0 = substr($0, 1, idx-1) repl substr($0, idx + length(target))
                    }
                }
                print $0
            }
            ' "$file" > "$tmp_file"
        else
            awk -v s="$_MT_METHOD_START" -v e="$_MT_METHOD_END" -v old="$old_val" -v new="$new_val" '
            NR>=s && NR<=e && index($0, "const-string") != 0 && index($0, "\"" old "\"") != 0 {
                target = "\"" old "\""
                repl = "\"" new "\""
                while (index($0, target) != 0) {
                    idx = index($0, target)
                    $0 = substr($0, 1, idx-1) repl substr($0, idx + length(target))
                }
            }
            { print $0 }
            ' "$file" > "$tmp_file"
        fi
        mv "$tmp_file" "$file"
        OP_MSG="✓ ($count occurrences replaced)"
    }

    op_set_flags() {
        local file="$1" method="$2" patch_json="$3"
        _find_method_awk "$file" "$method" || { OP_MSG="method not found: $method"; return 1; }
        if [ "$DRY_RUN" -eq 1 ]; then OP_MSG="OK (dry-run)"; return 0; fi

        local method_line=$(sed -n "${_MT_METHOD_START}p" "$file")
        
        # FIX 9: awk to reliably rip flags out instead of bash glob operator
        local flags_str=$(echo "$method_line" | awk -v sig="$method" '
        {
            sub(/^\.method +/, "")
            idx = index($0, sig)
            if(idx > 0) {
                print substr($0, 1, idx-1)
            }
        }')
        flags_str=$(echo "$flags_str" | xargs)

        local -a add_flags=() remove_flags=()
        local ac=$(echo "$patch_json" | jq '.add | length // 0')
        local rc=$(echo "$patch_json" | jq '.remove | length // 0')
        for ((i=0; i<ac; i++)); do add_flags+=("$(echo "$patch_json" | jq -r ".add[$i]")"); done
        for ((i=0; i<rc; i++)); do remove_flags+=("$(echo "$patch_json" | jq -r ".remove[$i]")"); done

        local -a current_flags=($flags_str)
        local -a new_flags=()
        for f in "${current_flags[@]}"; do
            local skip=0
            for rf in "${remove_flags[@]}"; do [ "$f" = "$rf" ] && skip=1 && break; done
            [ "$skip" -eq 0 ] && new_flags+=("$f")
        done
        for af in "${add_flags[@]}"; do
            local exists=0
            for f in "${new_flags[@]}"; do [ "$f" = "$af" ] && exists=1 && break; done
            [ "$exists" -eq 0 ] && new_flags+=("$af")
        done

        local new_line=".method ${new_flags[*]} $method"
        # FIX 14: Tmp file move instead of sed -i
        awk -v ln="$_MT_METHOD_START" -v nl="$new_line" 'NR==ln{print nl; next}1' "$file" > "${file}.tmp"
        mv "${file}.tmp" "$file"
        OP_MSG="✓ (flags: ${new_flags[*]})"
    }

    op_add_method_annotation() {
        local file="$1" method="$2" patch_json="$3"
        _find_method_awk "$file" "$method" || { OP_MSG="method not found: $method"; return 1; }
        # FIX 3: Replace grep -oP with awk for annotation type extraction
        local ann_type=$(echo "$patch_json" | jq -r '.annotation[]' | head -1 | awk 'match($0, /L[^;]+;/) {print substr($0, RSTART, RLENGTH)}' || true)
        if [ -n "$ann_type" ]; then
            if [ "$(awk -v s="$_MT_METHOD_START" -v e="$_MT_METHOD_END" -v at="$ann_type" 'NR>=s && NR<=e && index($0, at) {count++} END{print count}' "$file")" -gt 0 ]; then
                OP_MSG="⚠ annotation $ann_type already exists — skipped"; return 0
            fi
        fi
        if [ "$DRY_RUN" -eq 1 ]; then OP_MSG="OK (dry-run)"; return 0; fi

        local reg_line=$(awk -v s="$_MT_METHOD_START" -v e="$_MT_METHOD_END" 'NR>s && NR<e && /\.registers/ {print NR; exit}' "$file")
        [ -z "$reg_line" ] && reg_line=$((_MT_METHOD_START + 1))

        local ann_block=""
        local ac=$(echo "$patch_json" | jq '.annotation | length')
        for ((i=0; i<ac; i++)); do ann_block="${ann_block}    $(echo "$patch_json" | jq -r ".annotation[$i]")\n"; done

        awk -v ln="$reg_line" -v ann="$(echo -e "$ann_block")" '{print} NR==ln{printf "%s", ann}' "$file" > "${file}.tmp"
        mv "${file}.tmp" "$file"
        OP_MSG="✓"
    }

    op_remove_method_annotation() {
        local file="$1" method="$2" patch_json="$3"
        _find_method_awk "$file" "$method" || { OP_MSG="method not found: $method"; return 1; }
        local ann_type=$(echo "$patch_json" | jq -r '.annotation_type')
        [ -z "$ann_type" ] || [ "$ann_type" = "null" ] && { OP_MSG="'annotation_type' required"; return 1; }
        if [ "$DRY_RUN" -eq 1 ]; then OP_MSG="OK (dry-run)"; return 0; fi

        awk -v s="$_MT_METHOD_START" -v e="$_MT_METHOD_END" -v at="$ann_type" '
        NR>=s && NR<=e && /\.annotation/ && index($0, at) { skip=1; next }
        skip && /\.end annotation/ { skip=0; next }
        !skip { print }
        ' "$file" > "${file}.tmp"
        mv "${file}.tmp" "$file"
        OP_MSG="✓"
    }

    op_add_class_annotation() {
        local file="$1" patch_json="$2"
        local reg=$(awk '/^\.(super|source|implements)/ {last=NR} END{print last}' "$file")
        [ -z "$reg" ] && reg=2
        if [ "$DRY_RUN" -eq 1 ]; then OP_MSG="OK (dry-run)"; return 0; fi

        local ann_block=""
        local ac=$(echo "$patch_json" | jq '.annotation | length')
        for ((i=0; i<ac; i++)); do ann_block="${ann_block}$(echo "$patch_json" | jq -r ".annotation[$i]")\n"; done

        awk -v ln="$reg" -v ann="$(echo -e "$ann_block")" '{print} NR==ln{printf "%s", ann}' "$file" > "${file}.tmp"
        mv "${file}.tmp" "$file"
        OP_MSG="✓"
    }

    op_remove_class_annotation() {
        local file="$1" patch_json="$2"
        local ann_type=$(echo "$patch_json" | jq -r '.annotation_type')
        if [ "$DRY_RUN" -eq 1 ]; then OP_MSG="OK (dry-run)"; return 0; fi
        awk -v at="$ann_type" '
        /^\.annotation/ && index($0, at) { skip=1; next }
        skip && /^\.end annotation/ { skip=0; next }
        !skip { print }
        ' "$file" > "${file}.tmp"
        mv "${file}.tmp" "$file"
        OP_MSG="✓"
    }

    op_replace_field_value() {
        local file="$1" patch_json="$2"
        local fname=$(echo "$patch_json" | jq -r '.field_name')
        local ftype=$(echo "$patch_json" | jq -r '.field_type')
        local fval=$(echo "$patch_json" | jq -r '.new_value')

        if ! grep -q "${fname}:${ftype}" "$file"; then OP_MSG="field not found: $fname:$ftype"; return 1; fi
        if [ "$DRY_RUN" -eq 1 ]; then OP_MSG="OK (dry-run)"; return 0; fi

        local esc_fname=$(printf '%s' "$fname" | sed 's/[.[\*^$]/\\&/g')
        local esc_fval=$(printf '%s' "$fval" | sed 's/[&/\]/\\&/g')
        local esc_ftype=$(printf '%s' "$ftype" | sed 's/\[/\\\[/g; s/\]/\\\]/g') # FIX 4: Escape ftype brackets for sed BRE
        # FIX 14
        sed "s|\(${esc_fname}:${esc_ftype} = \).*|\1${esc_fval}|" "$file" > "${file}.tmp"
        mv "${file}.tmp" "$file"
        OP_MSG="✓"
    }

    op_rename_field() {
        local file="$1" patch_json="$2"
        local old_name=$(echo "$patch_json" | jq -r '.old_name')
        local new_name=$(echo "$patch_json" | jq -r '.new_name')
        local ftype=$(echo "$patch_json" | jq -r '.field_type')

        if ! grep -q "${old_name}:${ftype}" "$file"; then OP_MSG="field not found: $old_name:$ftype"; return 1; fi
        if [ "$DRY_RUN" -eq 1 ]; then OP_MSG="OK (dry-run)"; return 0; fi

        local esc_ftype=$(printf '%s' "$ftype" | sed 's/\[/\\\[/g; s/\]/\\\]/g') # FIX 4: Escape ftype brackets for sed BRE
        # FIX 14
        sed "s|->${old_name}:${esc_ftype}|->${new_name}:${ftype}|g; s| ${old_name}:${esc_ftype}| ${new_name}:${ftype}|g" "$file" > "${file}.tmp"
        mv "${file}.tmp" "$file"
        OP_MSG="✓"
    }

    op_replace_class_file() {
        local file="$1" patch_json="$2"
        local source_file=$(echo "$patch_json" | jq -r '.source_file // empty')
        if [ -n "$source_file" ]; then
            local abs="$GITHUB_WORKSPACE/$source_file"
            [ ! -f "$abs" ] && { OP_MSG="source_file not found: $abs"; return 1; }
            if [ "$DRY_RUN" -eq 1 ]; then OP_MSG="OK (dry-run)"; return 0; fi
            # Apply env var substitution (__NEXDROID_VERSION__ → $NEXDROID_VERSION)
            sed "s/__NEXDROID_VERSION__/${NEXDROID_VERSION:-1.05}/g" "$abs" > "$file"
        else
            local line_count=$(echo "$patch_json" | jq '.lines | length')
            [ "$line_count" -eq 0 ] && { OP_MSG="'lines' or 'source_file' required"; return 1; }
            if [ "$DRY_RUN" -eq 1 ]; then OP_MSG="OK (dry-run)"; return 0; fi
            > "${file}.tmp"
            local i; for ((i=0; i<line_count; i++)); do
                echo "$patch_json" | jq -r ".lines[$i]" >> "${file}.tmp"
            done
            mv "${file}.tmp" "$file"
        fi
        OP_MSG="✓"
    }

    # ══════════════════════════════════════════════════════════════════
    # MAIN DISPATCH
    # ══════════════════════════════════════════════════════════════════
    _info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    _info "MT-SMALI ENGINE — $PATCH_COUNT patches"
    _info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    [ "$DRY_RUN" -eq 1 ] && _warn "DRY-RUN mode — no files will be modified"

    local APPLIED=0
    local FAILED=0

    for ((idx=0; idx<PATCH_COUNT; idx++)); do
        local PATCH_JSON=$(jq -c ".patches[$idx]" "$PATCH_FILE")
        local P_CLASS=$(echo "$PATCH_JSON" | jq -r '.class')
        local P_METHOD=$(echo "$PATCH_JSON" | jq -r '.method // ""')
        local P_OP=$(echo "$PATCH_JSON" | jq -r '.op')
        local LABEL="[PATCH $((idx+1))/$PATCH_COUNT]"

        if [ "$P_CLASS" = "*" ]; then
            local global_count=0
            for sf in $(find "$SMALI_DIR" -name "*.smali" -type f); do
                OP_MSG=""
                case "$P_OP" in
                    replace_string) op_replace_string "$sf" "$P_METHOD" "$PATCH_JSON" 2>/dev/null && global_count=$((global_count+1)) ;;
                    rename_field)   op_rename_field "$sf" "$PATCH_JSON" 2>/dev/null && global_count=$((global_count+1)) ;;
                    *) _err "$LABEL Global class wildcard only valid for replace_string/rename_field"; FAILED=$((FAILED+1)); continue 2 ;;
                esac
            done
            _log "$LABEL \033[0;36m${P_OP}\033[0m  * :: ${P_METHOD:-*}  \033[0;32m✓\033[0m  ($global_count files touched)"
            APPLIED=$((APPLIED+1))
            continue
        fi

        local P_OPTIONAL; P_OPTIONAL=$(echo "$PATCH_JSON" | jq -r '.optional // false')
        OUT_SMALI_FILE=""
        _class_to_path "$P_CLASS"
        local SMALI_FILE="$OUT_SMALI_FILE"
        if [ -z "$SMALI_FILE" ] || [ ! -f "$SMALI_FILE" ]; then
            if [ "$P_OPTIONAL" = "true" ]; then
                _warn "$LABEL class not found (optional — skipped): $P_CLASS"
                APPLIED=$((APPLIED+1))
                continue
            fi
            _err "$LABEL class not found: $P_CLASS"
            [ "$DRY_RUN" -eq 1 ] && { FAILED=$((FAILED+1)); continue; }
            _die "Aborting — class not found: $P_CLASS" || return 1
        fi
        local PATCH_DEX_NAME="$_MT_CLASS_DEX_NAME"

        OP_MSG=""
        local rc=0
        case "$P_OP" in
            return_void)         op_return_void "$SMALI_FILE" "$P_METHOD" || rc=1 ;;
            return_true|return_1) op_return_true "$SMALI_FILE" "$P_METHOD" || rc=1 ;;
            return_false|return_0) op_return_false "$SMALI_FILE" "$P_METHOD" || rc=1 ;;
            return_minus1)       op_return_minus1 "$SMALI_FILE" "$P_METHOD" || rc=1 ;;
            return_null)         op_return_null "$SMALI_FILE" "$P_METHOD" || rc=1 ;;
            return_empty_string) op_return_empty_string "$SMALI_FILE" "$P_METHOD" || rc=1 ;;
            return_int)          op_return_int "$SMALI_FILE" "$P_METHOD" "$PATCH_JSON" || rc=1 ;;
            replace_body)        op_replace_body "$SMALI_FILE" "$P_METHOD" "$PATCH_JSON" || rc=1 ;;
            replace_line)        _line_op "$SMALI_FILE" "$P_METHOD" "$PATCH_JSON" "replace" || rc=1 ;;
            insert_before)       _line_op "$SMALI_FILE" "$P_METHOD" "$PATCH_JSON" "insert_before" || rc=1 ;;
            insert_after)        _line_op "$SMALI_FILE" "$P_METHOD" "$PATCH_JSON" "insert_after" || rc=1 ;;
            delete_line)         _line_op "$SMALI_FILE" "$P_METHOD" "$PATCH_JSON" "delete" || rc=1 ;;
            replace_string)      op_replace_string "$SMALI_FILE" "$P_METHOD" "$PATCH_JSON" || rc=1 ;;
            set_flags)           op_set_flags "$SMALI_FILE" "$P_METHOD" "$PATCH_JSON" || rc=1 ;;
            add_method_annotation)    op_add_method_annotation "$SMALI_FILE" "$P_METHOD" "$PATCH_JSON" || rc=1 ;;
            remove_method_annotation) op_remove_method_annotation "$SMALI_FILE" "$P_METHOD" "$PATCH_JSON" || rc=1 ;;
            add_class_annotation)     op_add_class_annotation "$SMALI_FILE" "$PATCH_JSON" || rc=1 ;;
            remove_class_annotation)  op_remove_class_annotation "$SMALI_FILE" "$PATCH_JSON" || rc=1 ;;
            replace_field_value)      op_replace_field_value "$SMALI_FILE" "$PATCH_JSON" || rc=1 ;;
            rename_field)             op_rename_field "$SMALI_FILE" "$PATCH_JSON" || rc=1 ;;
            replace_class_file)       op_replace_class_file "$SMALI_FILE" "$PATCH_JSON" || rc=1 ;;
            append_to_class)          op_append_to_class "$SMALI_FILE" "$PATCH_JSON" || rc=1 ;;
            *) _err "$LABEL Unknown op: $P_OP"; rc=1; OP_MSG="unknown op" ;;
        esac

        if [ "$rc" -eq 0 ]; then
            _log "$LABEL \033[0;36m${P_OP}\033[0m  ${P_CLASS} :: ${P_METHOD:-class-level}  \033[0;32m${OP_MSG}\033[0m"
            APPLIED=$((APPLIED+1))
            # Record which DEX was modified so we only recompile/inject what changed
            [ -n "$PATCH_DEX_NAME" ] && echo "$PATCH_DEX_NAME" >> "$MTCLI_TMP/modified_dexes.txt"
        else
            if [ "$P_OPTIONAL" = "true" ]; then
                _warn "$LABEL optional patch skipped: $OP_MSG"
                APPLIED=$((APPLIED+1))
                continue
            fi
            _err "$LABEL ERROR: $OP_MSG"
            FAILED=$((FAILED+1))
            if [ "$DRY_RUN" -eq 0 ]; then
                _die "Aborting. No further patches applied." || return 1
            fi
        fi
    done

    if [ "$DRY_RUN" -eq 1 ]; then
        if [ "$FAILED" -gt 0 ]; then
            _die "Dry-run: $FAILED patches failed. Aborting." || return 1
        fi
        _ok "Dry-run: All $PATCH_COUNT patches validated successfully."
        rm -rf "$MTCLI_TMP"
        return 0
    fi

    # ══════════════════════════════════════════════════════════════════
    # Step 3: smali.jar — Recompile smali → DEX
    # ══════════════════════════════════════════════════════════════════
    if [ "$SMALI_ONLY" -eq 1 ]; then
        _ok "Done. $APPLIED/$PATCH_COUNT patches applied. Smali dir: $SMALI_DIR"
        return 0
    fi

    # ══════════════════════════════════════════════════════════════════
    # Step 3 & 4: Recompile only modified DEX(es), inject each back
    # ══════════════════════════════════════════════════════════════════

    # Determine which DEX dirs actually had smali modifications
    local modified_dex_list=""
    if [ -f "$MTCLI_TMP/modified_dexes.txt" ]; then
        modified_dex_list=$(sort -uV "$MTCLI_TMP/modified_dexes.txt")
    fi

    if [ -z "$modified_dex_list" ]; then
        _warn "No smali files were modified — skipping recompile and injection"
        rm -rf "$MTCLI_TMP"
        _ok "Done. $APPLIED/$PATCH_COUNT patches applied. Output: $OUTPUT"
        return 0
    fi

    local mod_dex
    for mod_dex in $modified_dex_list; do
        local smali_src="${SMALI_DEX_DIRS[$mod_dex]}"
        if [ -z "$smali_src" ] || [ ! -d "$smali_src" ]; then
            _warn "Cannot locate smali dir for $mod_dex — skipping"
            continue
        fi

        _info "Recompiling smali → $mod_dex (API $API_LEVEL)..."
        local PATCHED_DEX="$MTCLI_TMP/patched_${mod_dex}"
        java -jar "$SMALI_JAR" a -a "$API_LEVEL" -o "$PATCHED_DEX" "$smali_src"
        if [ ! -f "$PATCHED_DEX" ]; then
            _die "smali recompile FAILED for $mod_dex — original untouched" || return 1
        fi
        _ok "Recompilation of $mod_dex successful"

        if [ "$IS_ARCHIVE" -eq 1 ]; then
            _info "Injecting $mod_dex into $(basename "$OUTPUT")..."
            cp "$PATCHED_DEX" "$MTCLI_TMP/$mod_dex"
            cd "$MTCLI_TMP"
            zip -j -0 "$OUTPUT" "$mod_dex" > /dev/null 2>&1 || { _die "Failed to inject $mod_dex into $OUTPUT"; return 1; }
            cd - > /dev/null
            _ok "DEX injected into $OUTPUT"
        elif [ "$INPUT_EXT_LOWER" = "dex" ]; then
            cp "$PATCHED_DEX" "$OUTPUT"
        else
            cp "$PATCHED_DEX" "$MTCLI_TMP/$mod_dex"
            cd "$MTCLI_TMP"
            zip -j -0 "$OUTPUT" "$mod_dex" > /dev/null 2>&1 || cp "$PATCHED_DEX" "$OUTPUT"
            cd - > /dev/null
        fi
    done

    rm -rf "$MTCLI_TMP"
    _ok "Done. $APPLIED/$PATCH_COUNT patches applied. Output: $OUTPUT"
    return 0
}

# ══════════════════════════════════════════════════════════════════
# BRIDGE INTEGRATION FOR MOD.SH
# ══════════════════════════════════════════════════════════════════
process_mt_smali() {
    local DUMP_DIR="$1"
    local json_dir="$(dirname "${BASH_SOURCE[0]}")"
    local part_name=$(basename "$DUMP_DIR" | sed 's/_dump//')

    _info "[MT-Smali] Processing MT-Smali for partition: $part_name"

    if [ ! -d "$json_dir" ]; then
        _warn "[MT-Smali] No mt_smali directory found at $json_dir. Skipping."
        return 0
    fi

    local processed_any=0

    # FIX 8 & UNIFIED JSON: Support array of jobs or single job
    for config_json in "$json_dir"/*.json; do
        if [ -f "$config_json" ]; then
            local is_array=$(jq -r 'if type=="array" then "yes" else "no" end' "$config_json")
            
            if [ "$is_array" = "yes" ]; then
                local len=$(jq 'length' "$config_json")
                # Use a SEPARATE staging dir for job JSONs — _run_mt_smali_cli wipes $MTCLI_TMP on entry
                local JOB_STAGE="/tmp/mt_smali_jobs_$$"
                rm -rf "$JOB_STAGE" && mkdir -p "$JOB_STAGE"
                for ((job_idx=0; job_idx<len; job_idx++)); do
                    jq ".[$job_idx]" "$config_json" > "$JOB_STAGE/job_${job_idx}.json"
                    local target_apk=$(jq -r '.apk_path // empty' "$JOB_STAGE/job_${job_idx}.json")
                    local out_apk=$(jq -r '.out_apk_path // empty' "$JOB_STAGE/job_${job_idx}.json")
                    
                    if [ -n "$target_apk" ]; then
                        # Strip the leading partition name (e.g. 'system_ext/') to append to DUMP_DIR
                        local abs_target="$DUMP_DIR/${target_apk#*/}"
                        if [ -f "$abs_target" ]; then
                            _info "[MT-Smali] Found target $abs_target. Triggering engine for job $job_idx in $(basename "$config_json")"
                            
                            if _run_mt_smali_cli -i "$abs_target" "$JOB_STAGE/job_${job_idx}.json" --verbose; then
                                processed_any=1
                            else
                                _err "[MT-Smali] Pipeline failed for job $job_idx in $config_json"
                                rm -rf "$JOB_STAGE"
                                return 1
                            fi
                        fi
                    fi
                done
                rm -rf "$JOB_STAGE"
            else
                local target_apk=$(jq -r '.apk_path // empty' "$config_json")
                local out_apk=$(jq -r '.out_apk_path // empty' "$config_json")
                
                if [ -n "$target_apk" ]; then
                    local abs_target="$DUMP_DIR/${target_apk#*/}"
                    if [ -f "$abs_target" ]; then
                        _info "[MT-Smali] Found target $abs_target. Triggering engine for: $(basename "$config_json")"
                        
                        if _run_mt_smali_cli -i "$abs_target" "$config_json" --verbose; then
                            processed_any=1
                        else
                            _err "[MT-Smali] Pipeline failed for $config_json"
                            return 1
                        fi
                    fi
                fi
            fi
        fi
    done

    if [ "$processed_any" -eq 1 ]; then
        _info "[MT-Smali] MT-Smali injection strictly completed for $part_name."
    fi
    return 0
}

# ══════════════════════════════════════════════════════════════════
# EXECUTION ENTRY POINT
# ══════════════════════════════════════════════════════════════════
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    _run_mt_smali_cli "$@"
    exit $?
fi
