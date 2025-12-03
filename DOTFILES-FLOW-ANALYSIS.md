# Dotfiles Desktop Flow - Complete Analysis

**Purpose**: Document the exact flow from TTY login to functional i3 desktop
**Date**: 2025-12-03

---

## 🔄 Complete Boot-to-Desktop Flow

```
1. TTY Login (auto-login as traum)
   ↓
2. User types "x" → runs startx
   ↓
3. startx reads ~/.xinitrc
   ↓
4. xinitrc executes:
   ├─ Detect VM vs Host (hostname check)
   ├─ Set MOD_KEY (Mod1 for VM, Mod4 for Host)
   ├─ Source load-display-config.sh → sets all resolution/font variables
   ├─ Process templates with sed:
   │  ├─ i3/config.template → i3/config
   │  ├─ polybar/config.ini.template → polybar/config.ini
   │  ├─ alacritty/alacritty.toml.template → alacritty/alacritty.toml
   │  └─ dunst/dunstrc.template → dunst/dunstrc
   └─ exec i3
   ↓
5. i3 starts and reads ~/.config/i3/config
   ├─ Executes autostart.sh
   └─ Sets up keybindings to various scripts
   ↓
6. autostart.sh runs:
   ├─ Links ~/.cache/wal/dunstrc → ~/.config/dunst/dunstrc
   ├─ Configures external monitors (xrandr)
   ├─ Starts picom (compositor, host only)
   ├─ Re-sources load-display-config.sh
   ├─ Launches polybar on all monitors (with per-monitor configs)
   └─ Sends desktop-ready notification
```

---

## 📝 Key Files and Their Roles

### 1. xinitrc (`~/dotfiles/xorg/.xinitrc`)

**Purpose**: Bootstrap X session, generate configs, start i3

**Key actions**:
```bash
# VM detection
hostname=$(hostnamectl | grep "Icon name:" | cut -d ":" -f2 | xargs)
if [[ $hostname =~ [vV][mM] ]]; then
    export MOD_KEY="Mod1"  # Alt for VMs
else
    export MOD_KEY="Mod4"  # Super for hosts
fi

# Load display config (sets all font/size variables)
source ~/.config/scripts/load-display-config.sh

# Process templates
sed -e "s/\${MOD_KEY}/$MOD_KEY/g" \
    -e "s/\${I3_FONT}/$I3_FONT/g" \
    -e "s/\${I3_FONT_SIZE}/$I3_FONT_SIZE/g" \
    ~/.config/i3/config.template > ~/.config/i3/config

# (Same for polybar, alacritty, dunst, firefox)

exec i3
```

**Variables used in templates**:
- `MOD_KEY` - Set directly by xinitrc
- `I3_FONT`, `I3_FONT_SIZE`, `I3_BORDER_THICKNESS`, `GAPS_INNER` - From load-display-config.sh
- `POLYBAR_FONT`, `POLYBAR_FONT_SIZE`, `POLYBAR_HEIGHT` - From load-display-config.sh
- `ALACRITTY_FONT`, `ALACRITTY_FONT_SIZE`, `ALACRITTY_SCALE_FACTOR_LINE` - From load-display-config.sh
- `DUNST_*` - **Missing from load-display-config.sh! Bug or additional logic?**
- `FIREFOX_FONT` - **Missing from load-display-config.sh!**

### 2. load-display-config.sh (`~/dotfiles/scripts/bash/load-display-config.sh`)

**Purpose**: Read display-config.json and export resolution-based variables

**Flow**:
1. Get current hostname (first part before dash)
2. Detect current resolution via xrandr
3. Check for machine-specific overrides in display-config.json
4. Detect external monitors (for machines with external_monitor_resolutions)
5. Load font/size values from machine overrides OR resolution defaults
6. Export all variables as environment variables

**Exported variables**:
```bash
export DISPLAY_RESOLUTION
export DISPLAY_FONTS
export POLYBAR_FONT
export POLYBAR_FONT_SIZE
export POLYBAR_HEIGHT
export POLYBAR_LINE_SIZE
export ALACRITTY_FONT
export ALACRITTY_FONT_SIZE
export ALACRITTY_SCALE_FACTOR
export ALACRITTY_SCALE_FACTOR_LINE
export I3_FONT_SIZE
export I3_BORDER_THICKNESS
export I3_BORDER_THICKNESS_EXTERNAL
export GAPS_INNER
export GAPS_INNER_EXTERNAL
export ROFI_FONT_SIZE
```

**Missing variables** (used in xinitrc but not exported):
- `I3_FONT` - Should be set from fonts array
- `DUNST_FONT` - Should be set from fonts array
- `DUNST_FONT_SIZE` - Exists in display-config.json but not exported!
- `DUNST_WIDTH`, `DUNST_HEIGHT`, `DUNST_OFFSET_X/Y`, etc. - Exist in JSON but not exported!
- `FIREFOX_FONT` - Needed for Firefox templates

### 3. display-config.json (`~/dotfiles/configs/display-config.json`)

**Purpose**: Central data store for resolution defaults and machine overrides

**Structure**:
```json
{
  "resolution_defaults": {
    "1920x1080": { polybar_font_size, alacritty_font_size, i3_font_size, gaps_inner, dunst_*, ... },
    "2560x1440": { ... },
    "2880x1800": { ... },
    "3840x2160": { ... }
  },
  "machine_overrides": {
    "zen": {
      "force_resolution": "2880x1800",
      "dpi": 192,
      "external_monitor_resolutions": ["2560", "3440", "3840"],
      "alacritty_font_size": 9,
      "alacritty_font_size_external": 11.5,
      ...
    }
  },
  "fonts": ["tamzen"]
}
```

**Key features**:
- Resolution-based defaults (1080p, 1440p, 4K, etc.)
- Machine-specific overrides (e.g., "zen" Zenbook)
- Separate values for internal vs external monitors
- External monitor detection by resolution pattern

### 4. autostart.sh (`~/dotfiles/scripts/bash/autostart.sh`)

**Purpose**: Called by i3 on startup/reload, configures multi-monitor setup

**Key actions**:
1. Link wal-generated dunstrc to ~/.config/dunst/dunstrc
2. Start/restart picom (host only)
3. Configure external monitors with xrandr (positioned above internal)
4. Re-source load-display-config.sh
5. Launch polybar on EACH monitor with per-monitor configs

**Critical feature**: Per-monitor polybar configs!
```bash
for monitor in $MONITORS; do
    # Detect if external monitor (for zen machine)
    # Generate monitor-specific config in /tmp/
    sed ... ~/.config/polybar/config.ini.template > /tmp/polybar-${monitor}.ini
    MONITOR=$monitor polybar -q --config="/tmp/polybar-${monitor}.ini" main &
done
```

This allows different polybar font sizes on internal vs external monitors!

---

## 📋 Scripts Called by i3 Config

From analysis of generated i3 config:

**Always executed**:
- `autostart.sh` - On every i3 restart
- `workspace-setup.sh` - On startup and certain keybinds

**Keybind-triggered**:
- `alacritty.sh` - Launch terminal with specific commands
- `detect-monitors.sh` - Manual monitor reconfiguration
- `refresh-display-config.sh` - Reload display config
- `rofi.sh` - Application launcher
- `randomwalrgb.sh` - Random wallpaper + theming
- `float_window.sh` - Toggle floating window

**Other referenced scripts** (in dotfiles but may not be critical):
- `walrgb.sh` - Main theming script (set wallpaper + update all colors)
- `nixwal.sh` - Update nix-colors file
- `wal-gtk.sh` - GTK theme integration
- `zathuracolors.sh` - PDF reader colors
- `polybar-restart.sh` - Restart polybar
- `lock.sh`, `lock-fancy.sh` - Screen locking
- `workspace-setup.sh` - Workspace-specific setup

---

## 🎯 What Hydrix Needs to Replicate

### Critical Files (Must Have)

1. **configs/display-config.json**
   - ✅ Already in Hydrix
   - ⚠️ Needs machine entry for "zeph" (Zephyrus)

2. **scripts/load-display-config.sh**
   - ✅ Already in Hydrix
   - ⚠️ INCOMPLETE - missing DUNST variables export!
   - ⚠️ INCOMPLETE - missing I3_FONT export!
   - ⚠️ INCOMPLETE - missing FIREFOX_FONT export!

3. **scripts/autostart.sh**
   - ✅ Already in Hydrix
   - ⚠️ Check if Hydrix version matches dotfiles version

4. **xorg/.xinitrc**
   - ✅ Deployed by home-manager
   - ❌ CRITICAL: Hydrix version doesn't have template processing logic!

### Scripts Needed

**Critical (system won't work without)**:
- [x] `load-display-config.sh` (has it, but incomplete)
- [x] `autostart.sh` (has it)
- [ ] `workspace-setup.sh` (called by i3 config)
- [ ] `detect-monitors.sh` (keybind in i3)
- [ ] `refresh-display-config.sh` (keybind in i3)
- [ ] `alacritty.sh` (used extensively)
- [ ] `rofi.sh` (app launcher)

**Important (keybinds broken without)**:
- [ ] `float_window.sh` (i3 keybind)
- [ ] `randomwalrgb.sh` (probably in Hydrix theming already?)

**Nice to have**:
- [ ] `lock.sh` / `lock-fancy.sh` (screen locking)
- [ ] `polybar-restart.sh` (convenience)

### Config Files Needed

**Templates (processed by xinitrc)**:
- [x] `i3/config.template` (has it)
- [x] `i3/config.base` (has it)
- [x] `polybar/config.ini.template` (has it)
- [x] `alacritty/alacritty.toml.template` (has it)
- [x] `dunst/dunstrc.template` (has it)
- [x] `rofi/config.rasi.template` (has it)

**Static configs**:
- [x] All other configs (ranger, joshuto, fish, etc.)

---

## ⚠️ Critical Bugs Found in load-display-config.sh

**Missing exports** (variables used in xinitrc but not exported):

```bash
# These should be added to load-display-config.sh:
export I3_FONT=$(jq -r '.fonts[0]' "$CONFIG_FILE")
export DUNST_FONT=$(jq -r '.fonts[0]' "$CONFIG_FILE")

# Dunst variables (exist in JSON but not exported!)
export DUNST_FONT_SIZE=$(echo "$RES_DEFAULTS" | jq -r '.dunst_font_size')
export DUNST_WIDTH=$(echo "$RES_DEFAULTS" | jq -r '.dunst_width')
export DUNST_HEIGHT=$(echo "$RES_DEFAULTS" | jq -r '.dunst_height')
export DUNST_OFFSET_X=$(echo "$RES_DEFAULTS" | jq -r '.dunst_offset_x')
export DUNST_OFFSET_Y=$(echo "$RES_DEFAULTS" | jq -r '.dunst_offset_y')
export DUNST_PADDING=$(echo "$RES_DEFAULTS" | jq -r '.dunst_padding')
export DUNST_FRAME_WIDTH=$(echo "$RES_DEFAULTS" | jq -r '.dunst_frame_width')
export DUNST_ICON_SIZE=$(echo "$RES_DEFAULTS" | jq -r '.dunst_icon_size')

# Firefox font
export FIREFOX_FONT=$(jq -r '.fonts[0]' "$CONFIG_FILE")
```

---

## 🔧 Hydrix Implementation Plan

### Phase 1: Fix Hydrix xinitrc

**File**: `modules/desktop/xinitrc.nix`

**Current state**: Deploys xinitrc from `configs/xorg/.xinitrc`

**Required**: Hydrix xinitrc must include template processing logic from dotfiles

**Options**:
1. Copy dotfiles xinitrc to Hydrix (easy, quick)
2. Create new xinitrc with same logic (cleaner, Hydrix-specific)

**Recommended**: Copy dotfiles xinitrc, update paths to Hydrix

### Phase 2: Fix load-display-config.sh

Add missing variable exports:
- I3_FONT
- DUNST_* (all dunst variables)
- FIREFOX_FONT

### Phase 3: Add Machine Override for Zephyrus

Update `configs/display-config.json` to include "zeph" entry with appropriate settings

### Phase 4: Copy Missing Scripts

Copy from dotfiles to Hydrix:
- workspace-setup.sh
- detect-monitors.sh
- refresh-display-config.sh
- alacritty.sh
- rofi.sh
- float_window.sh

### Phase 5: Update Config Paths

Update all configs to reference Hydrix paths instead of ~/dotfiles paths:
- i3/config.base (script paths)
- Any other configs with hardcoded paths

---

## ✅ Summary

**The dotfiles flow is**:
1. xinitrc detects VM/host, sources load-display-config.sh, processes templates, starts i3
2. load-display-config.sh reads JSON, exports variables based on resolution + machine
3. Templates get processed with sed to create working configs
4. i3 starts, calls autostart.sh
5. autostart.sh configures monitors, launches polybar on each monitor

**Hydrix is missing**:
1. Template processing logic in xinitrc (CRITICAL)
2. Complete variable exports in load-display-config.sh (CRITICAL)
3. Some scripts referenced by i3 config (IMPORTANT)
4. Machine override for "zeph" in display-config.json (MINOR)

**Next action**: Fix Hydrix xinitrc to include template processing, then copy missing scripts.
