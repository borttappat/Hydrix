# Custom Hydrix Plymouth boot animation.
#
# Mirrors the GRUB theme: same "HYDRIX" title (Iosevka Bold at titleSize),
# same color scheme, same visual structure.
#
# Layout:
#   - Systemd boot messages scrolling from top (~5% down)
#   - "HYDRIX" title at bottom (~85%, matching GRUB)
#   - Grey progress bar below title
#
# Enable with: hydrix.plymouth.enable = true
#
{ config, lib, pkgs, ... }:

let
  cfg = config.hydrix.plymouth;

  # Boot-time identity font — see theming/boot/grub-theme.nix's fontPackage
  # for why this is deliberately independent of hydrix.graphical.font.family.
  fontBold = "${cfg.fontPackage}/share/fonts/truetype/Iosevka-Bold.ttf";
  fontRegular = "${cfg.fontPackage}/share/fonts/truetype/Iosevka-Regular.ttf";

  # Resolve the active colorscheme at build time (theming/lib.nix), so colors
  # below follow hydrix.colorscheme instead of a fixed hex default.
  scheme = (import ../lib.nix { inherit lib pkgs; }).resolveScheme config;

  titleSize = builtins.floor (cfg.fontSize * 1.6);

  # Plymouth's DRM renderer reports a HiDPI-scaled *logical* resolution
  # (observed: 1440x900 on a panel whose EDID-native/preferred mode is
  # unambiguously 2880x1800 — confirmed via edid-decode, and unaffected by
  # forcing gfxmodeEfi, video=, or any other kernel-level mode override).
  # So screen_w/screen_h at runtime bear no fixed relationship to GRUB's
  # actual pixel resolution. Fix: size everything as a proportion of
  # Plymouth's own reported height, calibrated against fontSize/refHeight
  # (refHeight = the resolution hydrix.grub.theme.fontSize is tuned for),
  # rather than baking in an absolute px value.
  refHeight = 1800;
  fontRatio = cfg.fontSize * 1.0 / refHeight;
  titleRatio = titleSize * 1.0 / refHeight;

  # Convert hex "#RRGGBB" to normalized R,G,B (0.0-1.0) for Plymouth script
  hexDigit = c: {
    "0" = 0; "1" = 1; "2" = 2; "3" = 3; "4" = 4;
    "5" = 5; "6" = 6; "7" = 7; "8" = 8; "9" = 9;
    "a" = 10; "b" = 11; "c" = 12; "d" = 13; "e" = 14; "f" = 15;
    "A" = 10; "B" = 11; "C" = 12; "D" = 13; "E" = 14; "F" = 15;
  }.${c};
  hexByte = s: hexDigit (builtins.substring 0 1 s) * 16 + hexDigit (builtins.substring 1 1 s);
  hexToRgb = hex: let
    h = lib.removePrefix "#" hex;
    r = hexByte (builtins.substring 0 2 h);
    g = hexByte (builtins.substring 2 2 h);
    b = hexByte (builtins.substring 4 2 h);
    fmt = v: builtins.toString (v / 255.0);
  in { rs = fmt r; gs = fmt g; bs = fmt b; };

  bg  = hexToRgb cfg.colors.bg;
  acc = hexToRgb cfg.colors.accent;
  fg  = hexToRgb cfg.colors.fg;
  err = hexToRgb cfg.colors.error;

  maxLines = 30;

  plymouthScript = ''
# ── Background ──────────────────────────────────────────────────────
Window.SetBackgroundTopColor(${bg.rs}, ${bg.gs}, ${bg.bs});
Window.SetBackgroundBottomColor(${bg.rs}, ${bg.gs}, ${bg.bs});

# ── Screen geometry ─────────────────────────────────────────────────
screen_w = Window.GetWidth();
screen_h = Window.GetHeight();
cx = screen_w / 2;

# font_ratio/title_ratio are fractions of screen height (calibrated to
# match GRUB's fontSize/titleSize at ${toString refHeight}px reference height).
font_ratio = ${builtins.toString fontRatio};
title_ratio = ${builtins.toString titleRatio};

msg_px = Math.Int(screen_h * font_ratio);
msg_font = "Iosevka " + msg_px + "px";
msg_line_height = Math.Int(msg_px * 1.8);

# ── Title image (pre-rendered: Iosevka Bold; scaled to match GRUB) ─
title_image = Image("title.png");
title_orig_w = title_image.GetWidth();
title_orig_h = title_image.GetHeight();
title_h = Math.Int(screen_h * title_ratio);
title_w = Math.Int(title_orig_w * title_h / title_orig_h);
title_sprite = Sprite(title_image.Scale(title_w, title_h));
title_sprite.SetPosition(cx - title_w / 2, screen_h * 0.85 - title_h / 2, 10);

# ── Progress bar ────────────────────────────────────────────────────
bar_image = Image("progress.png");
bar_max_width = Math.Int(screen_w * 0.25);
bar_height = 3;
bar_y = screen_h * 0.85 + title_h / 2 + 12;
bar_sprite = Sprite();
bar_sprite.SetPosition(cx - bar_max_width / 2, bar_y, 10);

# ── Message area (top of screen, scrolling down) ───────────────────
msg_area_top = screen_h * 0.04;
max_messages = ${toString maxLines};

fun init_messages() {
  global.msg_sprites;
  global.msg_count = 0;
  for (i = 0; i < max_messages; i++)
    msg_sprites[i] = Sprite();
}
init_messages();

# ── Boot progress callback ──────────────────────────────────────────
# progress is reliable during boot (calibrated against boot.json), but
# stalls around a small fraction during shutdown/reboot — approximate
# with elapsed time there instead so the bar doesn't look stuck.
fun boot_progress_cb(time, progress) {
  mode = Plymouth.GetMode();
  if (mode == "shutdown" || mode == "reboot") {
    display_progress = 1 - 1 / (1 + time);
  } else {
    display_progress = progress;
  }
  bar_w = Math.Int(display_progress * bar_max_width);
  if (bar_w < 1) bar_w = 1;
  bar_sprite.SetImage(bar_image.Scale(bar_w, bar_height));
}
Plymouth.SetBootProgressFunction(boot_progress_cb);

# ── Adaptive resize ──────────────────────────────────────────────────
# Re-anchor on every refresh tick in case Plymouth's reported resolution
# ever changes mid-session (e.g. a different renderer handoff on other
# hardware). Cheap no-op when it doesn't.
fun resize_cb() {
  global.screen_w; global.screen_h; global.cx;
  global.msg_px; global.msg_font; global.msg_line_height;
  global.title_w; global.title_h;
  global.bar_max_width; global.bar_y; global.msg_area_top;

  new_w = Window.GetWidth();
  new_h = Window.GetHeight();
  if (new_w == screen_w && new_h == screen_h) return;

  screen_w = new_w;
  screen_h = new_h;
  cx = screen_w / 2;

  msg_px = Math.Int(screen_h * font_ratio);
  msg_font = "Iosevka " + msg_px + "px";
  msg_line_height = Math.Int(msg_px * 1.8);

  title_h = Math.Int(screen_h * title_ratio);
  title_w = Math.Int(title_orig_w * title_h / title_orig_h);
  title_sprite.SetImage(title_image.Scale(title_w, title_h));
  title_sprite.SetPosition(cx - title_w / 2, screen_h * 0.85 - title_h / 2, 10);

  bar_max_width = Math.Int(screen_w * 0.25);
  bar_y = screen_h * 0.85 + title_h / 2 + 12;
  bar_sprite.SetPosition(cx - bar_max_width / 2, bar_y, 10);
  msg_area_top = screen_h * 0.04;
}
Plymouth.SetRefreshFunction(resize_cb);

${if cfg.showMessages then ''
global.last_status = "";

# Plymouth script's String lib has no built-in Find/Contains — only
# SubString/Length/CharAt — so scan manually.
fun string_contains(haystack, needle) {
  h_len = haystack.Length();
  n_len = needle.Length();
  if (n_len > h_len) return false;
  for (i = 0; i <= h_len - n_len; i++)
    if (haystack.SubString(i, i + n_len) == needle) return true;
  return false;
}

fun status_is_failure(status) {
  return string_contains(status, "failed") || string_contains(status, "Failed") || string_contains(status, "FAILED");
}

fun status_cb(status) {
  global.last_status;
  if (status == last_status) return;
  last_status = status;

  if (global.msg_count >= max_messages) {
    oldest = msg_sprites[0];
    for (i = 0; i < max_messages - 1; i++)
      msg_sprites[i] = msg_sprites[i + 1];
    msg_sprites[max_messages - 1] = oldest;
    global.msg_count = max_messages;
  } else {
    global.msg_count = global.msg_count + 1;
  }

  for (i = 0; i < global.msg_count; i++) {
    line_y = msg_area_top + i * msg_line_height;
    msg_sprites[i].SetPosition(screen_w * 0.04, line_y, 10);
  }

  idx = global.msg_count - 1;
  if (status_is_failure(status)) {
    text_image = Image.Text(status, ${err.rs}, ${err.gs}, ${err.bs}, 1, msg_font);
  } else {
    text_image = Image.Text(status, ${fg.rs}, ${fg.gs}, ${fg.bs}, 1, msg_font);
  }
  msg_sprites[idx].SetImage(text_image);
  msg_sprites[idx].SetPosition(screen_w * 0.04, msg_area_top + idx * msg_line_height, 10);
  msg_sprites[idx].SetOpacity(0.85);
}
Plymouth.SetUpdateStatusFunction(status_cb);

fun message_cb(text) {
  status_cb(text);
}
Plymouth.SetMessageFunction(message_cb);

fun display_normal_cb() {
  for (i = 0; i < max_messages; i++)
    msg_sprites[i].SetImage(Image(""));
  global.msg_count = 0;
  global.last_status = "";
}
Plymouth.SetDisplayNormalFunction(display_normal_cb);
'' else ''
fun message_cb(text) { }
Plymouth.SetMessageFunction(message_cb);
''}

# ── Password prompt (LUKS, etc.) ────────────────────────────────────
global.prompt_sprite = Sprite();
global.bullet_sprite = Sprite();

fun password_cb(prompt, bullets) {
  bullet_string = "";
  for (i = 0; i < bullets; i++)
    bullet_string = bullet_string + "●";

  prompt_image = Image.Text(prompt, ${fg.rs}, ${fg.gs}, ${fg.bs}, 1, msg_font);
  global.prompt_sprite.SetImage(prompt_image);
  global.prompt_sprite.SetPosition(cx - prompt_image.GetWidth() / 2, screen_h * 0.55, 10);

  if (bullets > 0) {
    bullet_image = Image.Text(bullet_string, ${acc.rs}, ${acc.gs}, ${acc.bs}, 1, msg_font);
    global.bullet_sprite.SetImage(bullet_image);
    global.bullet_sprite.SetPosition(cx - bullet_image.GetWidth() / 2, screen_h * 0.60, 10);
  }
}
Plymouth.SetDisplayPasswordFunction(password_cb);
  '';

  hydrixPlymouthTheme = pkgs.runCommand "plymouth-theme-hydrix" {
    nativeBuildInputs = [ pkgs.imagemagick ];
  } ''
    dir=$out/share/plymouth/themes/hydrix
    mkdir -p $dir

    # ── Title image (Iosevka Bold at titleSize — matches GRUB exactly) ─
    magick -background transparent \
      -fill "${cfg.colors.accent}" \
      -font ${fontBold} \
      -pointsize ${toString titleSize} \
      -kerning 6 \
      label:"${cfg.title}" \
      $dir/title.png

    # ── Progress bar base image (matches GRUB's accent gradient) ───────
    magick -size 400x3 -define gradient:direction=east \
      gradient:"${cfg.colors.accent}"-"${cfg.colors.accentBright}" \
      $dir/progress.png

    # ── Theme metadata ─────────────────────────────────────────────────
    cat > $dir/hydrix.plymouth << EOF
[Plymouth Theme]
Name=Hydrix
Description=Hydrix boot animation
ModuleName=script

[script]
ImageDir=$dir
ScriptFile=$dir/hydrix.script
EOF

    cat > $dir/hydrix.script << 'SCRIPT'
${plymouthScript}
SCRIPT
  '';

in {
  options.hydrix.plymouth = {
    enable = lib.mkEnableOption "Hydrix Plymouth boot animation";

    title = lib.mkOption {
      type    = lib.types.str;
      default = "HYDRIX";
    };

    showMessages = lib.mkOption {
      type    = lib.types.bool;
      default = false;
      description = "Show systemd boot messages during boot";
    };

    fontSize = lib.mkOption {
      type    = lib.types.int;
      default = 18;
      description = ''
        Base font size (px) at a ${toString refHeight}px-tall reference canvas —
        match to hydrix.grub.theme.fontSize at the resolution GRUB actually
        renders at. Title = 1.6x. Plymouth's own reported resolution is often
        a HiDPI-scaled logical value unrelated to the real display mode, so
        this is applied proportionally at runtime rather than as a literal
        pixel size.
      '';
    };

    fontPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.iosevka;
      description = ''
        Package providing the boot font. Must ship Iosevka-Regular.ttf and
        Iosevka-Bold.ttf under share/fonts/truetype — the boot font is a
        deliberate identity choice independent of hydrix.graphical.font.family,
        not auto-derived from it. Matches hydrix.grub.theme.fontPackage.
      '';
    };

    # Defaults resolve from the active hydrix.colorscheme (theming/lib.nix) —
    # override any of these to pin a specific color regardless of colorscheme.
    colors = {
      bg           = lib.mkOption { type = lib.types.str; default = "#${scheme.base00}"; };
      accent       = lib.mkOption { type = lib.types.str; default = "#${scheme.base08}"; };
      accentBright = lib.mkOption { type = lib.types.str; default = "#${scheme.base0B}"; };
      fg           = lib.mkOption { type = lib.types.str; default = "#${scheme.base05}"; };
      # No natural base16 slot for "error" — an alarm color should stay a
      # recognizable red regardless of colorscheme, not reinterpret whatever
      # hue happens to occupy the accent slot for a given scheme.
      error        = lib.mkOption { type = lib.types.str; default = "#FF4444"; };
    };
  };

  config = lib.mkIf cfg.enable {
    boot.plymouth = {
      enable = true;
      theme  = "hydrix";
      themePackages = [ hydrixPlymouthTheme ];
      font = fontRegular;
      # Plymouth auto-detects HiDPI panels from EDID physical size and applies
      # a 2x device scale to Window.GetWidth()/GetHeight() (observed: reports
      # 1440x900 on this panel's true 2880x1800), independent of the actual
      # DRM mode. Force 1x so reported dimensions match real pixels.
      extraConfig = ''
        DeviceScale=1
      '';
    };

    boot.initrd.systemd.enable = true;

    # show_status=auto (systemd's default) suppresses raw console status
    # printing once Plymouth owns the display, falling back to it only for
    # slow/stalled units. Forcing show_status=1 (tried, reverted) disables
    # that suppression and duplicates every unit's status as raw text
    # racing visually with Plymouth's own splash — confirmed via
    # journalctl -b -1: Plymouth starts at ~1s (on simpledrm), well before
    # most units even run, so message sparsity isn't a Plymouth-timing
    # problem — leave show_status on its default.
    boot.kernelParams = [ "quiet" ];
    boot.consoleLogLevel = 0;
    boot.initrd.verbose = false;
  };
}
