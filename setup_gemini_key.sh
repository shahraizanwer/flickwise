#!/bin/bash
# Flickwise Gemini API Key Setup Script

echo "═══════════════════════════════════════════════════════════════"
echo "Flickwise - Gemini API Key Setup"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "Steps to get your FREE Gemini API Key:"
echo ""
echo "1. Visit: https://aistudio.google.com/"
echo "2. Click 'Get API Key'"
echo "3. Click 'Create API key in new project'"
echo "4. Copy the generated API key"
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo ""
read -p "Paste your Gemini API Key here: " API_KEY

if [ -z "$API_KEY" ]; then
    echo "❌ Error: API Key cannot be empty"
    exit 1
fi

CONFIG_FILE="$HOME/.hammerspoon/flickwise/config.yaml"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ Error: Config file not found at $CONFIG_FILE"
    exit 1
fi

# Update the API key in config
sed -i '' "s/gemini_api_key: \"\"/gemini_api_key: \"$API_KEY\"/" "$CONFIG_FILE"

if grep -q "gemini_api_key: \"$API_KEY\"" "$CONFIG_FILE"; then
    echo "✅ API Key saved successfully!"
    echo ""
    echo "Reloading Hammerspoon..."
    hs -c "hs.reload()" 2>/dev/null || echo "Note: Hammerspoon CLI may not be available"
    echo "✅ Done! Try using Flickwise now."
else
    echo "❌ Error: Could not save API key"
    exit 1
fi
