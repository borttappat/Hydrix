# Custom Hydrix Plymouth boot animation.
#
# Mirrors the GRUB theme: same "HYDRIX" title (Iosevka Bold at titleSize),
# same color scheme, same visual structure.
#
# Layout:
#   - Systemd boot messages from the top, one line per message across
#     the full width (hydrix.plymouth.messageMargin from each edge),
#     colored like the plain console: [  OK  ]/[FAILED]/[ TIME ]/[DEPEND] tags, unit
#     descriptions highlighted, a bouncing [ *** ] on running jobs. All
#     colors come from hydrix.plymouth.colors (colorscheme-derived).
#     They use every row the screen height allows.
#   - Progress bar: a thin vertical strip along the right edge, filling
#     top to bottom (accent gradient, matching GRUB)
#   - "HYDRIX" title in the bottom-right corner, left of the bar
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

  plymouthScript = ''
# Plymouth script has no boolean literals: an undefined name such as true
# evaluates to NULL, so flags are plain 1/0.

# ── Background ──────────────────────────────────────────────────────
Window.SetBackgroundTopColor(@BG_RGB@);
Window.SetBackgroundBottomColor(@BG_RGB@);

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
# Width of the console's "[  OK  ] " tag column (Iosevka is monospace).
tag_w = Image.Text("[  OK  ]_", 1, 1, 1, 1, msg_font).GetWidth();

# ── Title, progress bar and message area ─────────────────────────────
# The progress bar is a thin vertical strip along the right edge, filling
# top to bottom, with the title in the bottom-right corner just left of it.
# Messages get the rest: every row the height allows, cut short before the
# title's left edge so nothing overlaps.
msg_margin = ${toString cfg.messageMargin};
title_image = Image("title.png");
title_orig_w = title_image.GetWidth();
title_orig_h = title_image.GetHeight();
title_sprite = Sprite();
bar_image = Image("progress.png");
bar_sprite = Sprite();

fun layout_chrome() {
  global.margin_px = Math.Int(screen_h * msg_margin);
  global.gap_px = Math.Int(msg_line_height / 2);

  global.title_h = Math.Int(screen_h * title_ratio);
  global.title_w = Math.Int(title_orig_w * title_h / title_orig_h);

  global.bar_thick = Math.Int(msg_px / 6);
  if (bar_thick < 3) global.bar_thick = 3;
  global.bar_x = screen_w - margin_px - bar_thick;
  global.bar_top = margin_px;
  global.bar_max_height = screen_h - 2 * margin_px;

  global.title_x = bar_x - gap_px - title_w;
  title_sprite.SetImage(title_image.Scale(title_w, title_h));
  title_sprite.SetPosition(title_x, screen_h - margin_px - title_h, 10);
  bar_sprite.SetPosition(bar_x, bar_top, 10);

  global.msg_area_top = margin_px;
  global.msg_rows = Math.Int((screen_h - 2 * margin_px) / msg_line_height);
}
layout_chrome();

# Slots are allocated once; msg_rows (from the current height) decides how
# many are shown, capped here in case a later resize grows the screen.
max_messages = msg_rows;
global.msg_count = 0;

# ── Boot progress callback ──────────────────────────────────────────
# progress is reliable during boot (calibrated against boot.json), but
# stalls around a small fraction during shutdown/reboot - approximate
# with elapsed time there instead so the bar doesn't look stuck.
# Frozen at frozen_progress while awaiting_password is set (by
# password_cb / display_normal_cb below), so entering a LUKS password
# doesn't advance the bar on its own. password_cb also hides the bar
# sprite outright (opacity 0) - freezing the value alone still left a
# faint sub-pixel jitter on some renderers, since SetImage(Scale(...))
# keeps re-issuing every tick even when bar_w is unchanged.
global.awaiting_password = 0;
global.frozen_progress = 0;

fun boot_progress_cb(time, progress) {
  global.awaiting_password; global.frozen_progress;
  mode = Plymouth.GetMode();
  if (mode == "shutdown" || mode == "reboot") {
    display_progress = 1 - 1 / (1 + time);
  } else if (awaiting_password) {
    display_progress = frozen_progress;
  } else {
    display_progress = progress;
    frozen_progress = progress;
  }
  bar_h = Math.Int(display_progress * bar_max_height);
  if (bar_h < 1) bar_h = 1;
  bar_sprite.SetImage(bar_image.Scale(bar_thick, bar_h));
}
Plymouth.SetBootProgressFunction(boot_progress_cb);

# ── Adaptive resize ──────────────────────────────────────────────────
# Also drives the running-job ticker animation (ticker_cb, below).
# Re-anchor on every refresh tick in case Plymouth's reported resolution
# ever changes mid-session (e.g. a different renderer handoff on other
# hardware). Cheap no-op when it doesn't.
fun resize_cb() {
  ticker_cb();

  new_w = Window.GetWidth();
  new_h = Window.GetHeight();
  if (new_w == screen_w && new_h == screen_h) return;

  global.screen_w = new_w;
  global.screen_h = new_h;
  global.cx = screen_w / 2;

  global.msg_px = Math.Int(screen_h * font_ratio);
  global.msg_font = "Iosevka " + msg_px + "px";
  global.msg_line_height = Math.Int(msg_px * 1.8);
  global.tag_w = Image.Text("[  OK  ]_", 1, 1, 1, 1, msg_font).GetWidth();

  layout_chrome();
  if (msg_rows > max_messages) global.msg_rows = max_messages;
  layout_width();
  layout_messages();
}
Plymouth.SetRefreshFunction(resize_cb);

${if cfg.showMessages then ''
global.last_status = "";

fun rgb_color(r, g, b) {
  c.r = r; c.g = g; c.b = b;
  return c;
}
global.c_fg   = rgb_color(@FG_RGB@);
global.c_err  = rgb_color(@ERROR_RGB@);
global.c_ok   = rgb_color(@OK_RGB@);
global.c_warn = rgb_color(@WARN_RGB@);
global.c_hl   = rgb_color(@HIGHLIGHT_RGB@);
global.c_dim  = rgb_color(@DIM_RGB@);

# Plymouth script's String lib has no built-in Find/Contains, only
# SubString/Length/CharAt, so scan manually.
fun string_find(haystack, needle, from) {
  h_len = haystack.Length();
  n_len = needle.Length();
  for (i = from; i <= h_len - n_len; i++)
    if (haystack.SubString(i, i + n_len) == needle) return i;
  return -1;
}

fun string_contains(haystack, needle) {
  return string_find(haystack, needle, 0) >= 0;
}

fun status_is_failure(status) {
  return string_contains(status, "failed") || string_contains(status, "Failed") || string_contains(status, "FAILED");
}

fun is_tagged(text) {
  return text.Length() >= 8 && text.CharAt(0) == "[" && text.CharAt(7) == "]";
}

# Bare unit names ("foo.service"), as sent by systemd itself and by the
# shutdown watcher.
fun is_unit_id(text) {
  if (text == "" || string_contains(text, " ")) return 0;
  return string_contains(text, ".");
}

# Line format, matching the systemd console: "[TAG...] verb|subject|suffix".
# The 8-char tag and every segment are optional; a blank tag keeps the tag
# column empty (console's indented "Starting ..." lines).
fun parse_line(text) {
  p.tagged = 0; p.tag = ""; p.verb = ""; p.subj = ""; p.suf = ""; p.unit = 0;
  rest = text;
  if (is_tagged(text)) {
    p.tagged = 1;
    p.tag = text.SubString(1, 7);
    rest = text.SubString(8, text.Length());
    if (rest.Length() > 0 && rest.CharAt(0) == " ")
      rest = rest.SubString(1, rest.Length());
  } else if (is_unit_id(text)) {
    p.unit = 1;
    mode = Plymouth.GetMode();
    if (mode == "shutdown" || mode == "reboot") p.verb = "Stopping";
    else p.verb = "Starting";
    dot = text.Length() - 1;
    while (dot > 0 && text.CharAt(dot) != ".") dot--;
    p.subj = text.SubString(0, dot);
    p.suf = text.SubString(dot, text.Length());
    return p;
  }

  a = string_find(rest, "|", 0);
  if (a < 0) {
    p.verb = rest;
    return p;
  }
  p.verb = rest.SubString(0, a);
  b = string_find(rest, "|", a + 1);
  if (b < 0) {
    p.subj = rest.SubString(a + 1, rest.Length());
    return p;
  }
  p.subj = rest.SubString(a + 1, b);
  p.suf = rest.SubString(b + 1, rest.Length());
  return p;
}

fun tag_color(tag) {
  if (tag == "  OK  ") return c_ok;
  if (tag == "FAILED" || tag == " TIME ") return c_err;
  if (tag == "DEPEND" || string_contains(tag, "*")) return c_warn;
  return c_fg;
}

# systemd's bouncing 3-star "cylon" for jobs that are still running.
global.cylon_frames = 14;
global.cylon[0]  = "*     "; global.cylon[1]  = "**    "; global.cylon[2]  = "***   ";
global.cylon[3]  = " ***  "; global.cylon[4]  = "  *** "; global.cylon[5]  = "   ***";
global.cylon[6]  = "    **"; global.cylon[7]  = "     *"; global.cylon[8]  = "    **";
global.cylon[9]  = "   ***"; global.cylon[10] = "  *** "; global.cylon[11] = " ***  ";
global.cylon[12] = "***   "; global.cylon[13] = "**    ";
global.cylon_frame = 0;
global.cylon_tick = 0;

# Each line is a slot of sprites laid out left to right, one per color.
fun new_slot() {
  s.lb = Sprite(); s.tag = Sprite(); s.rb = Sprite();
  s.verb = Sprite(); s.subj = Sprite(); s.suf = Sprite();
  s.ticker = 0;
  s.dx_tag = 0; s.dx_rb = 0; s.dx_verb = 0; s.dx_subj = 0; s.dx_suf = 0;
  return s;
}

# Each segment's x offset from the slot's left edge, set by render_line;
# place_slot positions the whole line when it moves up a row.
fun place_slot(slot, x, y) {
  slot.lb.SetPosition(x, y, 10);
  slot.tag.SetPosition(x + slot.dx_tag, y, 10);
  slot.rb.SetPosition(x + slot.dx_rb, y, 10);
  slot.verb.SetPosition(x + slot.dx_verb, y, 10);
  slot.subj.SetPosition(x + slot.dx_subj, y, 10);
  slot.suf.SetPosition(x + slot.dx_suf, y, 10);
}

# Empty segments are hidden by opacity: SetImage with a null image (the
# Image("") idiom) leaves the previous image in place, so reused slots would
# keep stale segments drawn under the new ones. Returns the drawn width.
fun put(spr, text, c) {
  if (text == "") {
    spr.SetOpacity(0);
    return 0;
  }
  img = Image.Text(text, c.r, c.g, c.b, 1, msg_font);
  spr.SetImage(img);
  spr.SetOpacity(0.85);
  return img.GetWidth();
}

# Lines run from the left margin to just before the title; msg_chars is how
# many characters fit (Iosevka is monospace, so the tag column's width gives
# an exact per-character width).
fun layout_width() {
  global.msg_x0 = margin_px;
  global.msg_chars = Math.Int((title_x - gap_px - margin_px) / (tag_w / 9));
}
layout_width();

# Shortens a parsed line to avail characters after the tag column: the
# subject first (keeping a suffix such as a running job's durations), then
# the verb on its own for lines without one.
fun fit_line(p, avail) {
  sep = 0;
  if (p.verb != "" && p.subj != "") sep = 1;
  over = p.verb.Length() + sep + p.subj.Length() + p.suf.Length() - avail;
  if (over <= 0) return p;
  if (p.subj.Length() > over + 1) {
    p.subj = p.subj.SubString(0, p.subj.Length() - over - 1) + "…";
    return p;
  }
  p.subj = "";
  p.suf = "";
  if (p.verb.Length() > avail) p.verb = p.verb.SubString(0, avail - 1) + "…";
  return p;
}

fun render_line(slot, text) {
  p = fit_line(parse_line(text), msg_chars - 9);
  blank = p.tag == "      ";
  slot.ticker = p.tagged && string_contains(p.tag, "*");
  slot.dx_tag = 0; slot.dx_rb = 0;

  if (p.tagged && !blank) {
    tag = p.tag;
    if (slot.ticker) tag = cylon[global.cylon_frame];
    slot.dx_tag = put(slot.lb, "[", c_fg);
    slot.dx_rb = slot.dx_tag + put(slot.tag, tag, tag_color(p.tag));
    put(slot.rb, "]", c_fg);
  } else {
    put(slot.lb, "", c_fg);
    put(slot.tag, "", c_fg);
    put(slot.rb, "", c_fg);
  }

  verb_c = c_fg;
  subj_c = c_hl;
  if (blank || p.unit) {
    verb_c = c_dim;
    subj_c = c_fg;
  }
  if (!p.tagged && status_is_failure(text)) verb_c = c_err;

  sep = "";
  if (p.verb != "" && p.subj != "") sep = " ";

  slot.dx_verb = tag_w;
  slot.dx_subj = slot.dx_verb + put(slot.verb, p.verb, verb_c);
  slot.dx_suf = slot.dx_subj + put(slot.subj, sep + p.subj, subj_c);
  put(slot.suf, p.suf, c_dim);
}

fun init_messages() {
  global.msg_lines;
  global.msg_count = 0;
  for (i = 0; i < max_messages; i++)
    msg_lines[i] = new_slot();
}
init_messages();

# The last line can be a "live" line (display-message): repeated messages
# overwrite it in place and hide-message removes it, like the console's
# "A start job is running for ..." ticker. Status updates are inserted
# above it, so it stays pinned to the bottom.
global.live_line = 0;

fun layout_messages() {
  while (global.msg_count > msg_rows) {
    render_line(msg_lines[0], "");
    drop_oldest();
  }
  for (i = 0; i < global.msg_count; i++)
    place_slot(msg_lines[i], msg_x0, msg_area_top + i * msg_line_height);
}

fun drop_oldest() {
  oldest = msg_lines[0];
  for (i = 0; i < max_messages - 1; i++)
    msg_lines[i] = msg_lines[i + 1];
  msg_lines[max_messages - 1] = oldest;
  global.msg_count = global.msg_count - 1;
}

fun append_line(text) {
  if (global.msg_count >= msg_rows) {
    while (global.msg_count >= msg_rows) {
      render_line(msg_lines[0], "");
      drop_oldest();
    }
    global.msg_count = global.msg_count + 1;
  } else {
    global.msg_count = global.msg_count + 1;
  }

  idx = global.msg_count - 1;
  if (global.live_line && idx > 0) {
    live = msg_lines[idx - 1];
    msg_lines[idx - 1] = msg_lines[idx];
    msg_lines[idx] = live;
    idx = idx - 1;
  }

  render_line(msg_lines[idx], text);
  layout_messages();
}

fun ticker_cb() {
  if (global.live_line == 0 || global.msg_count == 0) return;
  slot = msg_lines[global.msg_count - 1];
  if (slot.ticker == 0) return;
  global.cylon_tick = global.cylon_tick + 1;
  if (global.cylon_tick < 6) return;
  global.cylon_tick = 0;
  global.cylon_frame = global.cylon_frame + 1;
  if (global.cylon_frame >= cylon_frames) global.cylon_frame = 0;
  slot.tag.SetImage(Image.Text(cylon[global.cylon_frame], c_warn.r, c_warn.g, c_warn.b, 1, msg_font));
}

# Once tagged lines arrive (the journal feed from the boot and shutdown
# status services), they carry unit descriptions, so systemd's own bare unit
# names would only duplicate them.
global.journal_feed = 0;

fun status_cb(status) {
  if (status == global.last_status) return;
  global.last_status = status;
  if (is_tagged(status)) global.journal_feed = 1;
  else if (global.journal_feed && is_unit_id(status)) return;
  append_line(status);
}
Plymouth.SetUpdateStatusFunction(status_cb);

fun message_cb(text) {
  if (global.live_line && global.msg_count > 0) {
    render_line(msg_lines[global.msg_count - 1], text);
    layout_messages();
  } else {
    append_line(text);
    global.live_line = 1;
  }
}
Plymouth.SetMessageFunction(message_cb);

fun hide_message_cb(text) {
  if (global.live_line == 0 || global.msg_count == 0) return;
  render_line(msg_lines[global.msg_count - 1], "");
  global.msg_count = global.msg_count - 1;
  global.live_line = 0;
}
Plymouth.SetHideMessageFunction(hide_message_cb);

'' else ''
fun ticker_cb() { }
fun layout_width() { }
fun layout_messages() { }
fun message_cb(text) { }
Plymouth.SetMessageFunction(message_cb);
''}

# ── Password prompt (LUKS, etc.) ────────────────────────────────────
global.prompt_sprite = Sprite();
global.bullet_sprite = Sprite();

fun password_cb(prompt, bullets) {
  global.awaiting_password = 1;
  global.bar_sprite.SetOpacity(0);

  bullet_string = "";
  for (i = 0; i < bullets; i++)
    bullet_string = bullet_string + "●";

  prompt_image = Image.Text(prompt, @FG_RGB@, 1, msg_font);
  global.prompt_sprite.SetImage(prompt_image);
  global.prompt_sprite.SetPosition(cx - prompt_image.GetWidth() / 2, screen_h * 0.55, 10);

  if (bullets > 0) {
    bullet_image = Image.Text(bullet_string, @ACCENT_RGB@, 1, msg_font);
    global.bullet_sprite.SetImage(bullet_image);
    global.bullet_sprite.SetPosition(cx - bullet_image.GetWidth() / 2, screen_h * 0.60, 10);
  }
}
Plymouth.SetDisplayPasswordFunction(password_cb);

fun display_normal_cb() {
  global.awaiting_password = 0;
  global.bar_sprite.SetOpacity(1);
  ${if cfg.showMessages then ''
  for (i = 0; i < max_messages; i++)
    render_line(msg_lines[i], "");
  global.msg_count = 0;
  global.last_status = "";
  global.live_line = 0;
  '' else ""}
}
Plymouth.SetDisplayNormalFunction(display_normal_cb);
  '';

  # Colors are @NAME_RGB@ placeholders ("r, g, b" floats), filled in by
  # renderPlymouth from the environment.
  scriptTemplate = pkgs.writeText "hydrix.script.in" plymouthScript;

  # Renders the theme files (script, title, progress bar) into $1, with colors
  # from the environment. Shared by the build below and by the runtime wal
  # override (runtime-colors.nix), so both always produce the same theme.
  renderPlymouth = pkgs.writeShellScript "hydrix-plymouth-render" ''
    set -eu
    PATH=${lib.makeBinPath [ pkgs.imagemagick pkgs.coreutils pkgs.gnused pkgs.gawk ]}
    dir=$1
    mkdir -p "$dir"

    rgb() {
      local h=''${1#"#"}
      awk -v r=$((16#''${h:0:2})) -v g=$((16#''${h:2:2})) -v b=$((16#''${h:4:2})) \
        'BEGIN { printf "%.6g, %.6g, %.6g", r / 255, g / 255, b / 255 }'
    }

    # ── Title image (Iosevka Bold at titleSize — matches GRUB exactly) ─
    magick -background transparent \
      -fill "$ACCENT" \
      -font ${fontBold} \
      -pointsize ${toString titleSize} \
      -kerning 6 \
      label:${lib.escapeShellArg cfg.title} \
      "$dir/title.png"

    # ── Progress bar base image (vertical, matches GRUB's accent gradient)
    magick -size 3x400 -define gradient:direction=south \
      gradient:"$ACCENT"-"$ACCENT_BRIGHT" \
      "$dir/progress.png"

    sed -e "s/@BG_RGB@/$(rgb "$BG")/g" \
        -e "s/@FG_RGB@/$(rgb "$FG")/g" \
        -e "s/@ACCENT_RGB@/$(rgb "$ACCENT")/g" \
        -e "s/@ERROR_RGB@/$(rgb "$ERROR")/g" \
        -e "s/@OK_RGB@/$(rgb "$OK")/g" \
        -e "s/@WARN_RGB@/$(rgb "$WARN")/g" \
        -e "s/@HIGHLIGHT_RGB@/$(rgb "$HIGHLIGHT")/g" \
        -e "s/@DIM_RGB@/$(rgb "$DIM")/g" \
        ${scriptTemplate} > "$dir/hydrix.script"
  '';

  # Theme files live at a fixed non-store path, so a runtime override can
  # replace them: in the initrd, an extra cpio loaded by GRUB after the main
  # one; in stage 2, whatever /etc/hydrix-plymouth points at (config below).
  themeDir = "/etc/hydrix-plymouth";
  themeFiles = [ "hydrix.script" "title.png" "progress.png" ];

  declaredFiles = pkgs.runCommand "hydrix-plymouth-files" {
    BG = cfg.colors.bg;
    FG = cfg.colors.fg;
    ACCENT = cfg.colors.accent;
    ACCENT_BRIGHT = cfg.colors.accentBright;
    ERROR = cfg.colors.error;
    OK = cfg.colors.ok;
    WARN = cfg.colors.warn;
    HIGHLIGHT = cfg.colors.highlight;
    DIM = cfg.colors.dim;
  } "${renderPlymouth} $out";

  hydrixPlymouthTheme = pkgs.runCommand "plymouth-theme-hydrix" { } ''
    dir=$out/share/plymouth/themes/hydrix
    mkdir -p $dir
    cat > $dir/hydrix.plymouth << EOF
[Plymouth Theme]
Name=Hydrix
Description=Hydrix boot animation
ModuleName=script

[script]
ImageDir=${themeDir}
ScriptFile=${themeDir}/hydrix.script
EOF
  '';

  # Runs a theme in an X11 window (XWayland) through Plymouth's x11 renderer,
  # without root or a TTY: a user namespace satisfies plymouthd's uid check,
  # and a private mount namespace binds the theme dir over ${themeDir}.
  # Feeds sample boot (or, with --shutdown, shutdown) lines covering every
  # tag style and the live "start/stop job" line, then quits after $HOLD
  # seconds (default 15).
  previewInner = pkgs.writeShellScript "hydrix-plymouth-preview-inner" ''
    set -eu
    PATH=${lib.makeBinPath [ pkgs.util-linux pkgs.coreutils ]}
    ply=${config.boot.plymouth.package}/bin/plymouth
    mount --bind "$1" ${themeDir}
    run=$(mktemp -d)
    trap 'rm -rf "$run"' EXIT

    ${config.boot.plymouth.package}/bin/plymouthd --no-daemon --mode="$3" --pid-file="$run/pid" \
      --kernel-command-line="splash plymouth.ignore-udev" &
    for _ in $(seq 50); do "$ply" --ping 2>/dev/null && break; sleep 0.1; done
    "$ply" show-splash

    if [ "$3" = shutdown ]; then
      for unit in "Network Manager" "User Login Management" "Journal Service"; do
        "$ply" update --status="[      ] Stopping|$unit|..."
        "$ply" update --status="[  OK  ] Stopped|$unit|."
      done
      "$ply" update --status="[  OK  ] Stopped target|Local File Systems|."
      "$ply" update --status="[      ] Unmounting|/boot|..."
      "$ply" update --status="[  OK  ] Unmounted|/boot|."
      "$ply" update --status="[  OK  ] Deactivated swap|/dev/zram0|."
      "$ply" update --status="[  OK  ] Reached target|System Shutdown|."
    else
      for unit in "Journal Service" "Network Manager" "User Login Management" \
        "Load Kernel Modules" "Remount Root and Kernel File Systems"; do
        "$ply" update --status="[      ] Starting|$unit|..."
        "$ply" update --status="[  OK  ] Started|$unit|."
      done
      "$ply" update --status="[  OK  ] Reached target|Local File Systems|."
    fi
    "$ply" update --status="[DEPEND] Dependency failed for|Some Mount|."
    "$ply" update --status="[ TIME ] Timed out starting|Slow Device|."
    "$ply" update --status="[FAILED] Failed|Broken Service| (exit-code)"
    "$ply" update --status="[  OK  ] Finished|A unit with a very long description that runs past the right margin of the screen to show how truncation looks at full width|."
    job=start
    [ "$3" = shutdown ] && job=stop
    "$ply" display-message --text="[  *** ] A $job job is running for|Preview stall| (6s / 1min 30s)"

    sleep "$2"
    "$ply" quit
    wait
  '';

  previewScript = pkgs.writeShellScriptBin "hydrix-plymouth-preview" ''
    # Usage: hydrix-plymouth-preview [--shutdown] [theme-dir]   (HOLD=<seconds> to change duration)
    # theme-dir defaults to the active theme (${themeDir}); point it at a
    # copy of that folder to try script edits before a rebuild.
    set -eu
    if [ -z "''${DISPLAY:-}" ]; then
      echo "hydrix-plymouth-preview: needs an X display (XWayland)" >&2
      exit 1
    fi
    mode=boot
    if [ "''${1:-}" = --shutdown ]; then mode=shutdown; shift; fi
    dir=$(${pkgs.coreutils}/bin/realpath "''${1:-${themeDir}}")
    exec ${pkgs.util-linux}/bin/unshare -rm ${previewInner} "$dir" "''${HOLD:-15}" "$mode"
  '';

  # Runs for the whole uptime (started at boot, DefaultDependencies=false
  # below keeps it alive through the shutdown.target wave). Idle until
  # shutdown is detected, by whichever fires first: logind's
  # PrepareForShutdown(true) signal, or systemd's JobNew signal for one of
  # the shutdown/reboot/poweroff/halt/kexec targets. Then it follows PID 1's
  # journal from that moment, the same console-style lines as boot
  # ("[  OK  ] Stopped ...", "Unmounting ...", failures and timeouts),
  # queued until plymouthd (mode=shutdown) answers --ping and flushed paced
  # so they read as a scroll. Once the splash is up it also starts the
  # "A stop job is running for ..." ticker (statusPollScript --shutdown).
  # journald runs until the final kill spree, so this covers nearly all of
  # shutdown. Both busctl monitors run in a retry loop with a journal line
  # on every restart, so a dead subprocess can't silently disable detection.
  shutdownStatusScript = pkgs.writeShellScript "hydrix-plymouth-shutdown-status" ''
    set -u
    plymouth="${pkgs.plymouth}/bin/plymouth"
    busctl="${pkgs.systemd}/bin/busctl"
    jq="${pkgs.jq}/bin/jq"
    lock=/run/hydrix-plymouth-shutdown-follow
    tag=hydrix-plymouth-shutdown-status

    follow() {
      mkdir "$lock" 2>/dev/null || return 0
      (
        ready=0
        declare -a queue=()
        ${pkgs.systemd}/bin/journalctl -f -n 0 -o json \
          --output-fields=MESSAGE,JOB_RESULT,JOB_TYPE _PID=1 2>/dev/null \
        | "$jq" --unbuffered -r --argjson failures true -f ${jobLineFilter} 2>/dev/null \
        | while IFS= read -r line; do
            if [ "$ready" = 1 ]; then
              "$plymouth" update --status="$line" 2>/dev/null
            elif "$plymouth" --ping 2>/dev/null; then
              ready=1
              ${statusPollScript} --shutdown &
              for q in "''${queue[@]}" "$line"; do
                "$plymouth" update --status="$q" 2>/dev/null
                sleep 0.03
              done
              queue=()
            else
              queue+=("$line")
            fi
          done
      ) &
    }

    (
      while :; do
        "$busctl" monitor --system --json=short \
          --match="type='signal',interface='org.freedesktop.login1.Manager',member='PrepareForShutdown'" \
          org.freedesktop.login1 2>/dev/null \
        | "$jq" --unbuffered -r \
            'select(.type=="signal" and .member=="PrepareForShutdown" and .payload.data[0]==true) | "1"' \
        | while IFS= read -r _; do
            follow
          done
        echo "$tag: login1 watcher exited, restarting" >&2
        sleep 1
      done
    ) &

    while :; do
      "$busctl" monitor --system --json=short \
        --match="type='signal',interface='org.freedesktop.systemd1.Manager',member='JobNew'" \
        org.freedesktop.systemd1 2>/dev/null \
      | "$jq" --unbuffered -r \
          'select(.type=="signal" and .member=="JobNew") | .payload.data[2]' \
      | while IFS= read -r unit; do
          case "$unit" in
            shutdown.target|reboot.target|poweroff.target|halt.target|kexec.target) follow ;;
          esac
        done
      echo "$tag: job watcher exited, restarting" >&2
      sleep 1
    done
  '';

  # Maps PID 1's job journal entries to console-style status lines
  # ("[  OK  ] Finished|Description", "[  OK  ] Stopped|Description",
  # "      Unmounting|/home|..."), see parse_line in the script above.
  # Condition-skipped units are dropped, like the console does. $failures
  # adds [FAILED] lines for failed jobs: shutdown has no other source for
  # them, while boot leaves them to the list-units poller in
  # statusPollScript, which also catches units that die after starting.
  # Verb alternatives are ordered longest first ("Stopped target" before
  # "Stopped"), since the first match wins.
  jobLineFilter = pkgs.writeText "hydrix-plymouth-job-lines.jq" ''
    select(.JOB_TYPE != null)
    | (.MESSAGE // "" | if type == "array" then implode else . end) as $m
    | select($m | test(" skipped, |being skipped\\.$") | not)
    | (.JOB_RESULT // "") as $r
    | (if $r == "done" then "  OK  "
       elif $r == "timeout" then " TIME "
       elif $r == "dependency" then "DEPEND"
       elif $r == "failed" and $failures then "FAILED"
       elif $r == "" and ($m | test("^(Starting|Stopping|Reloading|Unmounting|Deactivating) ")) then "      "
       else empty end) as $tag
    | (($m | capture("^(?<v>Started|Finished|Reached target|Stopped target|Stopped|Stopping|Mounted|Unmounted|Unmounting|Found device|Listening on|Closed|Created slice|Removed slice|Activated swap|Deactivated swap|Deactivating swap|Set up automount|Unset automount|Reloaded|Reloading|Starting|Timed out starting|Timed out stopping|Dependency failed for|Failed to start|Failed to stop|Failed unmounting|Failed deactivating swap) (?<s>.*?)(\\.\\.\\.|\\.)?$"))
       // {v: "", s: $m}) as $p
    | "[\($tag)] \($p.v)|\($p.s | gsub("\\|"; "/"))"
  '';

  # systemd itself only tells Plymouth which units are starting or stopping.
  # Completions, failures, timeouts and the "A start job is running for ..."
  # ticker go to the text console, which the splash covers, so a hung unit
  # looks like a frozen splash. At boot this follows PID 1's job journal
  # entries for [  OK  ] style lines (the -n all backlog replays initrd too).
  # Either way it polls PID 1 (private socket, no D-Bus needed) once a
  # second while plymouthd is up: the oldest job running 5s or more as the
  # live message line, and at boot failed units as status lines (--shutdown
  # skips both the journal, which shutdownStatusScript follows itself, and
  # failed units, which at shutdown would be stale ones from the session).
  # The journal follower needs no cleanup: systemd kills the rest of the
  # cgroup once this main process exits.
  statusPollScript = pkgs.writeShellScript "hydrix-plymouth-status-poll" ''
    set -u
    plymouth="${pkgs.plymouth}/bin/plymouth"
    systemctl="${pkgs.systemd}/bin/systemctl"
    declare -A first=() reported=()
    shown=""
    boot=1
    [ "''${1:-}" = --shutdown ] && boot=0

    if [ "$boot" = 1 ]; then
      ${pkgs.systemd}/bin/journalctl -b -f -n all -o json \
        --output-fields=MESSAGE,JOB_RESULT,JOB_TYPE _PID=1 JOB_TYPE=start 2>/dev/null \
      | ${pkgs.jq}/bin/jq --unbuffered -r --argjson failures false -f ${jobLineFilter} 2>/dev/null \
      | while IFS= read -r line; do
          "$plymouth" update --status="$line" 2>/dev/null
        done &
    fi

    _dur() {
      local s=$1
      if [ "$s" -ge 60 ]; then echo "$((s / 60))min $((s % 60))s"; else echo "''${s}s"; fi
    }

    while "$plymouth" --ping 2>/dev/null; do
      now=$(${pkgs.coreutils}/bin/date +%s)

      [ "$boot" = 1 ] && while read -r unit _; do
        [ -z "$unit" ] || [ -n "''${reported[$unit]:-}" ] && continue
        reported[$unit]=1
        desc=$("$systemctl" show -P Description "$unit")
        result=$("$systemctl" show -P Result "$unit")
        desc=''${desc:-$unit}
        "$plymouth" update --status="[FAILED] Failed|''${desc//"|"/"/"}| (''${result:-failed})" 2>/dev/null
      done < <("$systemctl" list-units --failed --plain --no-legend --no-pager 2>/dev/null)

      declare -A running=()
      oldest="" oldest_t=$now oldest_type=""
      while read -r _ unit type state _; do
        [ "$state" = running ] || continue
        running[$unit]=1
        : "''${first[$unit]:=$now}"
        if [ "''${first[$unit]}" -le "$oldest_t" ]; then
          oldest=$unit oldest_t=''${first[$unit]} oldest_type=$type
        fi
      done < <("$systemctl" list-jobs --no-legend --no-pager 2>/dev/null)
      for u in "''${!first[@]}"; do
        [ -n "''${running[$u]:-}" ] || unset "first[$u]"
      done
      unset running

      msg=""
      if [ -n "$oldest" ] && [ $((now - oldest_t)) -ge 5 ]; then
        desc=$("$systemctl" show -P Description "$oldest")
        case "$oldest_type:$oldest" in
          start:*.service) limit=$("$systemctl" show -P TimeoutStartUSec "$oldest") ;;
          stop:*.service) limit=$("$systemctl" show -P TimeoutStopUSec "$oldest") ;;
          *) limit=$("$systemctl" show -P JobRunningTimeoutUSec "$oldest") ;;
        esac
        case "$limit" in ""|infinity) limit="no limit" ;; esac
        desc=''${desc:-$oldest}
        msg="[  *** ] A $oldest_type job is running for|''${desc//"|"/"/"}| ($(_dur $((now - oldest_t))) / $limit)"
      fi

      if [ -n "$msg" ]; then
        "$plymouth" display-message --text="$msg" 2>/dev/null
      elif [ -n "$shown" ]; then
        "$plymouth" hide-message --text="$shown" 2>/dev/null
      fi
      shown=$msg

      sleep 1
    done
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

    preview = lib.mkEnableOption ''
      the hydrix-plymouth-preview command, which runs the splash in a window
      (Plymouth's x11 renderer, no root or TTY needed) with sample boot lines'';

    showShutdownMessages = lib.mkOption {
      type    = lib.types.bool;
      default = cfg.showMessages;
      description = ''
        Show systemd job status during shutdown/reboot/halt, forwarded from a
        dedicated D-Bus watcher (upstream Plymouth's own shutdown status
        rarely has anything to show, since plymouth-poweroff/halt/reboot.service
        only start once most of shutdown.target's own jobs are already done).
      '';
    };

    messageMargin = lib.mkOption {
      type = lib.types.numbers.between 0 0.25;
      default = 0.01;
      description = ''
        Gap between the boot messages and the left, right and top screen
        edges, as a fraction of the screen height (the same pixel gap on
        every side). 0 starts at the very edge, like the plain console.
      '';
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

    followWal = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Recolor the splash from the runtime wal colors while a wal scheme is
        active (walrgb, apply-colorscheme), back to the declared colors on
        restore-colorscheme. Applied without a rebuild through an extra initrd
        on the ESP (theming/boot/runtime-colors.nix). Colors pinned explicitly
        in hydrix.plymouth.colors stay pinned; error is never wal-derived.
      '';
    };

    renderer = lib.mkOption {
      type = lib.types.package;
      internal = true;
      readOnly = true;
      default = renderPlymouth;
    };

    declaredFiles = lib.mkOption {
      type = lib.types.package;
      internal = true;
      readOnly = true;
      default = declaredFiles;
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
      # Boot message colors, console style: [  OK  ] tag, [DEPEND] tag and the
      # "A start job is running" stars, unit descriptions, and secondary text
      # (Starting lines, durations, unit type suffixes).
      ok           = lib.mkOption { type = lib.types.str; default = "#${scheme.base0B}"; };
      warn         = lib.mkOption { type = lib.types.str; default = "#${scheme.base0A}"; };
      highlight    = lib.mkOption { type = lib.types.str; default = "#${scheme.base0D}"; };
      dim          = lib.mkOption { type = lib.types.str; default = "#${scheme.base03}"; };
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = lib.optional cfg.preview previewScript;

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

    # Per file rather than one directory symlink, so the runtime overlay cpio
    # replaces each file instead of writing through a symlink into the store.
    boot.initrd.systemd.contents = lib.genAttrs (map (f: "${themeDir}/${f}") themeFiles)
      (path: { source = "${declaredFiles}/${baseNameOf path}"; });

    # Stage 2 (shutdown/reboot splash): runtime-colors.nix keeps
    # /var/lib/hydrix-boot-theme/plymouth filled with the declared or the wal theme.
    environment.etc."hydrix-plymouth".source =
      if cfg.followWal then "/var/lib/hydrix-boot-theme/plymouth" else declaredFiles;

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

    systemd.services.hydrix-plymouth-boot-status = lib.mkIf cfg.showMessages {
      description = "Forward boot failures and stalled jobs to Plymouth";
      unitConfig = {
        # Early boot, before basic.target; exits on its own once plymouthd
        # quits, so it never holds up plymouth-quit-wait or the greeter.
        DefaultDependencies = false;
        After = ["plymouth-start.service"];
        Conflicts = ["shutdown.target"];
        Before = ["shutdown.target"];
        ConditionKernelCommandLine = "!plymouth.enable=0";
        ConditionVirtualization = "!container";
      };
      serviceConfig = {
        Type = "simple";
        ExecStart = "${statusPollScript}";
      };
      wantedBy = ["sysinit.target"];
    };

    systemd.services.hydrix-plymouth-shutdown-status = lib.mkIf cfg.showShutdownMessages {
      description = "Forward systemd shutdown job status to Plymouth";
      unitConfig = {
        # No DefaultDependencies: a normal service gets an implicit
        # Conflicts=/Before=shutdown.target, which would stop this alongside
        # everything else in the very burst it exists to observe.
        DefaultDependencies = false;
        ConditionKernelCommandLine = "!plymouth.enable=0";
        ConditionVirtualization = "!container";
      };
      serviceConfig = {
        Type = "simple";
        ExecStart = "${shutdownStatusScript}";
        Restart = "on-failure";
        RestartSec = 2;
      };
      wantedBy = [ "multi-user.target" ];
    };
  };
}
