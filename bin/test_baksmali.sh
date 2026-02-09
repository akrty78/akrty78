#!/bin/bash

# TEST SCRIPT - Verify Baksmali Download
# Run this BEFORE your main build to ensure baksmali works

set -e

BIN_DIR="./bin"
mkdir -p "$BIN_DIR"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🧪 BAKSMALI/SMALI DOWNLOAD TEST"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Clean slate - delete any existing files
if [ -f "$BIN_DIR/baksmali.jar" ]; then
    echo "🗑️  Removing old baksmali.jar..."
    rm -f "$BIN_DIR/baksmali.jar"
fi

if [ -f "$BIN_DIR/smali.jar" ]; then
    echo "🗑️  Removing old smali.jar..."
    rm -f "$BIN_DIR/smali.jar"
fi

echo ""
echo "📥 Downloading baksmali v3.0.9-fat.jar..."
BAKSMALI_URL="https://github.com/baksmali/smali/releases/download/v3.0.9/baksmali-3.0.9-fat.jar"

if wget -q --show-progress -O "$BIN_DIR/baksmali.jar" "$BAKSMALI_URL"; then
    FILE_SIZE=$(stat -c%s "$BIN_DIR/baksmali.jar")
    echo "✅ Downloaded: $FILE_SIZE bytes"
    
    if [ "$FILE_SIZE" -lt 1000000 ]; then
        echo "❌ ERROR: File too small! Download failed."
        rm -f "$BIN_DIR/baksmali.jar"
        exit 1
    fi
else
    echo "❌ ERROR: Download failed!"
    exit 1
fi

echo ""
echo "📥 Downloading smali v3.0.9-fat.jar..."
SMALI_URL="https://github.com/baksmali/smali/releases/download/v3.0.9/smali-3.0.9-fat.jar"

if wget -q --show-progress -O "$BIN_DIR/smali.jar" "$SMALI_URL"; then
    FILE_SIZE=$(stat -c%s "$BIN_DIR/smali.jar")
    echo "✅ Downloaded: $FILE_SIZE bytes"
    
    if [ "$FILE_SIZE" -lt 1000000 ]; then
        echo "❌ ERROR: File too small! Download failed."
        rm -f "$BIN_DIR/smali.jar"
        exit 1
    fi
else
    echo "❌ ERROR: Download failed!"
    exit 1
fi

echo ""
echo "🧪 Testing baksmali.jar..."
if java -jar "$BIN_DIR/baksmali.jar" --version 2>/dev/null; then
    echo "✅ baksmali.jar is VALID!"
else
    echo "❌ ERROR: baksmali.jar is CORRUPT!"
    exit 1
fi

echo ""
echo "🧪 Testing smali.jar..."
if java -jar "$BIN_DIR/smali.jar" --version 2>/dev/null; then
    echo "✅ smali.jar is VALID!"
else
    echo "❌ ERROR: smali.jar is CORRUPT!"
    exit 1
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ ALL TESTS PASSED!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Your baksmali/smali tools are ready!"
echo "You can now run your main build script."
echo ""
