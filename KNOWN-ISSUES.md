# Known Issues - Hydrix Migration

**Date**: 2025-12-02
**Status**: First successful rebuild complete, some issues remaining

---

## ❌ Issues to Fix

### 1. i3 Keybindings Not Working
**Symptom**: i3 keybindings are not responding
**Likely Cause**: Config file deployment or template processing issue
**Files to Check**:
- `~/.config/i3/config` (generated file)
- `~/.config/i3/config.template` (Hydrix template)
- `~/.config/i3/config.base` (base config)
- `~/.xinitrc` (template processing script)

**Debug Steps**:
```bash
# Check what config i3 is actually using
cat ~/.config/i3/config | head -50

# Check if template was processed
ls -la ~/.config/i3/

# Check xinitrc processing
cat ~/.xinitrc | grep -A 10 "i3"

# Compare with dotfiles version
diff ~/.config/i3/config ~/dotfiles/i3/config
```

### 2. Other Potential Issues
- Font rendering (if fonts.env was needed)
- Polybar not launching (config.ini was moved)
- Any pywal-dependent configs

---

## ✅ What's Working

- **System**: Running Hydrix `nixos-system-zeph-router-setup`
- **Router Mode**: Router VM auto-starting, specialisation active
- **Scripts**: `walrgb`, `randomwalrgb`, `nixwal`, `zathuracolors` all in PATH
- **Home-manager**: Successfully deployed configs to `/nix/store`
- **nixbuild.sh**: Hostname-driven, specialisation-aware, interactive fallback

---

## 📝 Migration Notes

### Files Backed Up
All conflicting dotfiles configs backed up to: `~/dotfiles-backup-20251202/`
- `.xinitrc`
- `config.fish`
- `config.template` (i3)
- `display-config.json`
- `load-display-config.sh`
- `zathurarc`
- `starship.toml`
- Old resolution-specific configs (config3k, config4k, etc.)

### System State
- **Hostname**: `zeph` (matches flake entry)
- **Flake Entry**: `.#zeph`
- **Specialisation**: `router` (active)
- **Home-manager**: Deployed, but some configs may need adjustment

---

## 🔧 Quick Fixes to Try

1. **Reload X session**: Log out and back in
2. **Restart i3**: `$mod+Shift+r` (if any bindings work)
3. **Check i3 logs**: `~/.local/share/xorg/Xorg.0.log` or `journalctl -xe`
4. **Compare configs**: Check differences between Hydrix and dotfiles configs
5. **Rebuild**: `cd ~/Hydrix && ./nixbuild.sh`

---

## 🚀 Next Steps

1. Fix i3 keybindings issue
2. Verify all desktop functionality (polybar, rofi, etc.)
3. Test theming workflow (`walrgb`)
4. Document any other discovered issues
5. Consider VM deployment testing

---

## 📦 Repo Info

**GitHub**: https://github.com/borttappat/Hydrix (private)
**Branch**: master
**Last Commit**: First successful rebuild with rewritten nixbuild.sh
