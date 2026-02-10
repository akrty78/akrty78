#!/bin/bash

# DIAGNOSTIC SCRIPT - Test GitHub Download
# This will show EXACTLY why the download is failing

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔍 GITHUB DOWNLOAD DIAGNOSTIC"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

BAKSMALI_URL="https://github.com/baksmali/smali/releases/download/v3.0.9/baksmali-3.0.9-fat.jar"

echo "Testing URL: $BAKSMALI_URL"
echo ""

# Test 1: Can we reach GitHub?
echo "TEST 1: Checking GitHub connectivity..."
if curl -I https://github.com 2>&1 | head -1; then
    echo "✅ GitHub is reachable"
else
    echo "❌ Cannot reach GitHub!"
    echo "Your network might be blocking GitHub"
fi
echo ""

# Test 2: Can we access the release page?
echo "TEST 2: Checking release URL..."
HTTP_CODE=$(curl -L -s -o /dev/null -w "%{http_code}" "$BAKSMALI_URL")
echo "HTTP Status Code: $HTTP_CODE"

if [ "$HTTP_CODE" = "200" ]; then
    echo "✅ URL is valid and accessible"
elif [ "$HTTP_CODE" = "302" ] || [ "$HTTP_CODE" = "301" ]; then
    echo "⚠️  URL redirects (this is normal for GitHub releases)"
    echo "Following redirect..."
    FINAL_URL=$(curl -Ls -o /dev/null -w %{url_effective} "$BAKSMALI_URL")
    echo "Final URL: $FINAL_URL"
elif [ "$HTTP_CODE" = "404" ]; then
    echo "❌ URL NOT FOUND (404)"
    echo "The file doesn't exist at this URL!"
    echo ""
    echo "Let me check what releases are actually available..."
    curl -s https://api.github.com/repos/baksmali/smali/releases/latest | grep "browser_download_url" | grep "baksmali"
else
    echo "❌ Unexpected status code: $HTTP_CODE"
fi
echo ""

# Test 3: Try actual download
echo "TEST 3: Attempting download with wget..."
mkdir -p test_download
cd test_download
rm -f baksmali.jar

echo "Command: wget -O baksmali.jar '$BAKSMALI_URL'"
if wget -v -O baksmali.jar "$BAKSMALI_URL" 2>&1 | tee wget.log; then
    if [ -f baksmali.jar ]; then
        FILE_SIZE=$(stat -c%s baksmali.jar 2>/dev/null || stat -f%z baksmali.jar 2>/dev/null || echo "0")
        echo ""
        echo "Downloaded file size: $FILE_SIZE bytes"
        
        if [ "$FILE_SIZE" -gt 1000000 ]; then
            echo "✅ Download successful!"
            echo ""
            echo "File type:"
            file baksmali.jar || echo "file command not available"
            echo ""
            echo "First few bytes (hex):"
            xxd baksmali.jar | head -3 || hexdump -C baksmali.jar | head -3
        else
            echo "❌ File is too small (probably an error page)"
            echo ""
            echo "Content:"
            cat baksmali.jar | head -20
        fi
    else
        echo "❌ File was not created"
    fi
else
    echo "❌ wget failed"
    echo ""
    echo "Error output:"
    tail -20 wget.log
fi

cd ..
echo ""

# Test 4: Try with curl
echo "TEST 4: Attempting download with curl..."
mkdir -p test_download_curl
cd test_download_curl
rm -f baksmali.jar

echo "Command: curl -L -o baksmali.jar '$BAKSMALI_URL'"
if curl -L -v -o baksmali.jar "$BAKSMALI_URL" 2>&1 | tee curl.log; then
    if [ -f baksmali.jar ]; then
        FILE_SIZE=$(stat -c%s baksmali.jar 2>/dev/null || stat -f%z baksmali.jar 2>/dev/null || echo "0")
        echo ""
        echo "Downloaded file size: $FILE_SIZE bytes"
        
        if [ "$FILE_SIZE" -gt 1000000 ]; then
            echo "✅ Download successful with curl!"
        else
            echo "❌ File is too small"
            echo "Content:"
            cat baksmali.jar | head -20
        fi
    fi
else
    echo "❌ curl failed"
fi

cd ..
echo ""

# Summary
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 SUMMARY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "If download failed, possible reasons:"
echo "1. GitHub is blocked by firewall/proxy"
echo "2. The release URL changed (v3.0.9 might not exist)"
echo "3. Network requires authentication"
echo "4. Rate limiting from GitHub"
echo ""
echo "Recommended actions:"
echo "- Check if you can access https://github.com/baksmali/smali/releases in browser"
echo "- Try from a different network"
echo "- Check if proxy settings are needed"
echo "- Download manually and place in bin/ directory"
echo ""
