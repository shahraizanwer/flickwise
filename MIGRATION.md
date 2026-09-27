# Upgrading from TextFixer

TextFixer was renamed to **Flickwise**. To upgrade, run the normal installer:

```bash
curl -fsSL https://raw.githubusercontent.com/shahraizanwer/flickwise/main/install.sh | bash
```

It detects `~/.hammerspoon/textfixer` and migrates it automatically:

| What | Where it goes |
|---|---|
| `textfixer/config.yaml` (modes, hotkeys, API key or Glean path) | copied to `~/.hammerspoon/flickwise/config.yaml` |
| the `textfixer/` folder | moved to `~/.hammerspoon/textfixer.backup.<date>` |
| `~/Applications/TextFixer.app` | moved into that backup folder |
| `require("textfixer")` in `~/.hammerspoon/init.lua` | removed (the original is saved as `init.lua.backup.<date>`) and replaced by `require("flickwise")` |
| new settings (`features:`) | added to your config above `modes:` (the previous file is saved as `config.yaml.backup.<date>`) |

Nothing is deleted. Once you're happy with Flickwise, you can remove the `*.backup.*` files.

**Roll back:** move `textfixer.backup.<date>` back to `~/.hammerspoon/textfixer`, restore `init.lua` from its backup, and reload Hammerspoon.

Old config keys (`api_key`, `defaults.model`, and so on) are ignored. Settings added since TextFixer, such as the diff bubble, the radial menu and the resting pill, are documented in the README under **Features**.
