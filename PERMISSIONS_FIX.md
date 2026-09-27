# 🔐 Flickwise Permissions Fix

## The Problem
"No text selected" error occurs because **Hammerspoon needs Accessibility permissions** to send keyboard commands (Cmd+C) to other applications.

## Root Cause
When you press the Flickwise hotkey, Hammerspoon tries to:
1. Send Cmd+C to copy selected text
2. Read the clipboard
3. Send Cmd+V to paste the result

Without **Accessibility** permissions, step 1 fails - the Cmd+C never reaches your app, so the clipboard stays empty.

## Solution: Grant Hammerspoon Accessibility Permissions

### Step 1: Open System Settings
1. Click the **Apple menu** (⌘) in the top-left corner
2. Select **System Settings**
3. Click on **Privacy & Security** (left sidebar)
4. Scroll down and click **Accessibility**

### Step 2: Add Hammerspoon to Accessibility List
1. In the **Accessibility** section, unlock with your password
2. Click the **+** button below the app list
3. Navigate to **Applications** folder
4. Find and select **Hammerspoon.app**
5. Click **Open** to add it
6. **Verify Hammerspoon is checked** in the list

### Step 3: Grant Input Monitoring Permission (if needed)
1. Go to **System Settings > Privacy & Security > Input Monitoring**
2. Unlock with your password
3. Click the **+** button
4. Add **Hammerspoon.app** if not there
5. Verify it's checked

### Step 4: Restart Hammerspoon
1. Right-click the Hammerspoon icon (menu bar)
2. Select **Quit**
3. Open **Applications** folder
4. Double-click **Hammerspoon.app**
5. Grant permission if prompted

## Testing Your Setup

### Quick Test (Copy/Paste)
```bash
# Open Terminal and try this:
echo "test text" | pbcopy
pbpaste
# If you see "test text", your clipboard works
```

### Real Test with Flickwise
1. Open **Notes** or any text editor
2. Type: `The quick brown fox jumpps over the lazi dog`
3. Select all text: **Cmd+A**
4. Press: **Cmd+Shift+G** (Fix Grammar)
5. Watch for alerts:
   - ✨ "Fix Grammar..." = Hammerspoon IS working
   - ⚠️ "No text selected" = Permissions NOT granted yet

## If It Still Doesn't Work

### Troubleshooting Steps

1. **Check Hammerspoon Console**
   - Right-click Hammerspoon icon → Open Console
   - Press your hotkey again and look for error messages

2. **Use the Mode Picker**
   - Select text in any app
   - Press **Cmd+Shift+P** (Mode Picker)
   - Choose a transformation
   - Often works even with limited permissions

3. **Fully Reset Hammerspoon Permissions**
   ```bash
   # Remove Hammerspoon from all privacy settings
   defaults write com.apple.universalaccess 'com.github.Hammerspoon' -dict
   ```
   Then re-add it following Step 1-4 above

4. **Check System Integrity**
   ```bash
   # Verify Hammerspoon can access the system
   spctl -a -vvv -t execute /Applications/Hammerspoon.app
   ```

## Expected Behavior After Permissions are Fixed

✅ Select text in any app  
✅ Press Cmd+Shift+G (or your configured hotkey)  
✅ See "✨ Fix Grammar..." alert  
✅ Text is captured and sent to AI  
✅ Transformed text is pasted back  
✅ See "✓ Done" alert  

## Configuration

Your Flickwise config is at:
```
~/.hammerspoon/flickwise/config.yaml
```

Edit hotkeys:
```yaml
modes:
  - name: "Fix Grammar"
    hotkey: ["cmd", "shift", "g"]  # Change this
```

Reload with: **Cmd+Shift+Semicolon** (menu bar) or `hs -c "hs.reload()"`

## Support

- **Hammerspoon Homepage**: https://www.hammerspoon.org
- **Flickwise Source**: ~/.hammerspoon/flickwise/
- **Logs**: ~/.hammerspoon/flickwise/flickwise.log

