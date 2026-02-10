#!/bin/bash

# Helper script to download smali.jar for upload to Google Drive

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📥 SMALI.JAR DOWNLOAD HELPER"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

SMALI_URL="https://github.com/baksmali/smali/releases/download/v3.0.9/smali-3.0.9-fat.jar"

echo "Downloading smali.jar from GitHub..."
echo "URL: $SMALI_URL"
echo ""

if wget -O smali.jar "$SMALI_URL" 2>&1 | grep -E "(saved|Downloaded)"; then
    FILE_SIZE=$(stat -c%s smali.jar 2>/dev/null || stat -f%z smali.jar 2>/dev/null)
    
    if [ "$FILE_SIZE" -gt 1000000 ]; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "✅ SUCCESS!"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "Downloaded: smali.jar"
        echo "Size: $FILE_SIZE bytes"
        echo ""
        echo "NEXT STEPS:"
        echo "1. Upload smali.jar to your Google Drive"
        echo "2. Share the file (Anyone with link can view)"
        echo "3. Copy the file ID from the share link"
        echo "4. Update nexdroid_manager_optimized.sh:"
        echo "   Find: SMALI_GDRIVE=\"YOUR_SMALI_JAR_ID\""
        echo "   Replace with your actual ID"
        echo ""
        echo "Example:"
        echo "If share link is:"
        echo "https://drive.google.com/file/d/1ABC123XYZ/view"
        echo ""
        echo "The ID is: 1ABC123XYZ"
        echo ""
        echo "Then update script to:"
        echo "SMALI_GDRIVE=\"1ABC123XYZ\""
        echo ""
    else
        echo "❌ ERROR: Downloaded file is too small ($FILE_SIZE bytes)"
        echo "This usually means the download failed."
        rm -f smali.jar
        exit 1
    fi
else
    echo "❌ ERROR: Failed to download smali.jar"
    echo ""
    echo "Alternative: Download manually from browser"
    echo "URL: $SMALI_URL"
    exit 1
fi
