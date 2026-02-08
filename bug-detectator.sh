#!/bin/bash
# Bug Detector for mod.sh

echo "=========================================="
echo "   MOD.SH BUG DETECTOR v1.0"
echo "=========================================="
echo ""

SCRIPT_FILE="/home/claude/mod.sh"
BUG_COUNT=0

# Check 1: Partition image existence check
echo "🔍 CHECK 1: Partition image detection"
if grep -q 'if \[ -f "\$IMAGES_DIR/\${part}\.img" \]' "$SCRIPT_FILE"; then
    echo "   ✅ Found partition check"
    # But is there logging?
    if grep -A 5 'if \[ -f "\$IMAGES_DIR/\${part}\.img" \]' "$SCRIPT_FILE" | grep -q "echo.*not found"; then
        echo "   ✅ Has logging for missing partitions"
    else
        echo "   ❌ BUG: Missing partitions are SILENTLY SKIPPED!"
        echo "      → Need to add: else echo 'Partition not found: \$part'"
        BUG_COUNT=$((BUG_COUNT + 1))
    fi
else
    echo "   ❌ BUG: No partition check found!"
    BUG_COUNT=$((BUG_COUNT + 1))
fi
echo ""

# Check 2: Partition variable scope
echo "🔍 CHECK 2: LOGICALS partition list"
if grep -q 'LOGICALS="system system_ext product' "$SCRIPT_FILE"; then
    echo "   ✅ Partition list defined"
    PARTITION_LIST=$(grep 'LOGICALS=' "$SCRIPT_FILE" | head -1 | cut -d'"' -f2)
    echo "      → Partitions: $PARTITION_LIST"
else
    echo "   ❌ BUG: LOGICALS variable not found!"
    BUG_COUNT=$((BUG_COUNT + 1))
fi
echo ""

# Check 3: Loop structure
echo "🔍 CHECK 3: Partition loop structure"
if grep -q 'for part in \$LOGICALS' "$SCRIPT_FILE"; then
    echo "   ✅ Loop structure correct"
else
    echo "   ❌ BUG: Loop not iterating through LOGICALS!"
    BUG_COUNT=$((BUG_COUNT + 1))
fi
echo ""

# Check 4: Conditional partition checks
echo "🔍 CHECK 4: Partition-specific conditionals"

# Check if debloater only runs in product
DEBLOAT_CHECK=$(grep -A 2 "# A. DEBLOATER" "$SCRIPT_FILE" | grep -c 'if \[ "\$part" == "product" \]')
if [ "$DEBLOAT_CHECK" -gt 0 ]; then
    echo "   ✅ Debloater: Only in product partition"
else
    echo "   ❌ BUG: Debloater not restricted to product!"
    BUG_COUNT=$((BUG_COUNT + 1))
fi

# Check if Provision only runs in system_ext
PROV_CHECK=$(grep -B 2 "PROV_APK=" "$SCRIPT_FILE" | grep -c 'if \[ "\$part" == "system_ext" \]')
if [ "$PROV_CHECK" -gt 0 ]; then
    echo "   ✅ Provision patcher: Only in system_ext"
else
    echo "   ❌ BUG: Provision patcher not restricted to system_ext!"
    BUG_COUNT=$((BUG_COUNT + 1))
fi

# Check if Settings only runs in system_ext
SETTINGS_CHECK=$(grep -B 2 "SETTINGS_APK=" "$SCRIPT_FILE" | grep -c 'if \[ "\$part" == "system_ext" \]')
if [ "$SETTINGS_CHECK" -gt 0 ]; then
    echo "   ✅ Settings patcher: Only in system_ext"
else
    echo "   ❌ BUG: Settings patcher not restricted to system_ext!"
    BUG_COUNT=$((BUG_COUNT + 1))
fi

# Check if MiuiBooster only runs in system_ext
BOOST_CHECK=$(grep -A 2 "# D. MIUI BOOSTER" "$SCRIPT_FILE" | grep -c 'if \[ "\$part" == "system_ext" \]')
if [ "$BOOST_CHECK" -gt 0 ]; then
    echo "   ✅ MiuiBooster patcher: Only in system_ext"
else
    echo "   ❌ BUG: MiuiBooster not restricted to system_ext!"
    BUG_COUNT=$((BUG_COUNT + 1))
fi
echo ""

# Check 5: Image extraction logging
echo "🔍 CHECK 5: Payload extraction logging"
if grep -q "payload-dumper-go -o" "$SCRIPT_FILE"; then
    echo "   ✅ Payload dumper command found"
    if grep -A 2 "payload-dumper-go" "$SCRIPT_FILE" | grep -q "ls -lh.*IMAGES_DIR"; then
        echo "   ✅ Lists extracted images"
    else
        echo "   ❌ BUG: No logging of extracted images!"
        echo "      → Should add: ls -lh \$IMAGES_DIR/*.img"
        BUG_COUNT=$((BUG_COUNT + 1))
    fi
else
    echo "   ❌ BUG: Payload dumper not found!"
    BUG_COUNT=$((BUG_COUNT + 1))
fi
echo ""

# Check 6: Error handling
echo "🔍 CHECK 6: Error handling in partition loop"
EXIT_COUNT=$(grep -c "exit 1" "$SCRIPT_FILE")
echo "   ℹ️  Found $EXIT_COUNT 'exit 1' statements"
if [ "$EXIT_COUNT" -gt 10 ]; then
    echo "   ⚠️  WARNING: Too many exit points - script may exit prematurely"
    echo "      → Consider using 'continue' instead of 'exit 1' in loops"
    BUG_COUNT=$((BUG_COUNT + 1))
fi
echo ""

# Check 7: Mount/Unmount handling
echo "🔍 CHECK 7: Mount cleanup"
UMOUNT_COUNT=$(grep -c "fusermount\|umount" "$SCRIPT_FILE")
echo "   ℹ️  Found $UMOUNT_COUNT unmount statements"
if [ "$UMOUNT_COUNT" -lt 2 ]; then
    echo "   ❌ BUG: Insufficient mount cleanup - may cause mount failures!"
    BUG_COUNT=$((BUG_COUNT + 1))
fi
echo ""

# Summary
echo "=========================================="
echo "   DIAGNOSTIC SUMMARY"
echo "=========================================="
echo "Total bugs found: $BUG_COUNT"
echo ""

if [ "$BUG_COUNT" -eq 0 ]; then
    echo "✅ No critical bugs detected!"
else
    echo "❌ Found $BUG_COUNT bug(s) that need fixing!"
fi
