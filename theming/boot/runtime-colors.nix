# Runtime wal colors for GRUB, Plymouth and SDDM.
#
# Declared colors stay where they always are: the store-built theme in
# /boot/theme and the main initrd. While a wal scheme is active
# (~/.cache/wal/.active), a root service renders the same themes from
# ~/.cache/wal/colors.json into /boot/hydrix, which grub.cfg prefers when
# present:
#   /boot/hydrix/grub/        GRUB theme, replaces /theme/theme.txt
#   /boot/hydrix/plymouth.cpio  extra initrd overlaying /etc/hydrix-plymouth
# restore-colorscheme removes the .active marker, and the service deletes
# /boot/hydrix again. SDDM gets a theme.conf.user override in
# /var/lib/hydrix-boot-theme/sddm the same way. Rebuilds never touch the
# overrides, so runtime colors persist until restored, like every other
# wal-themed surface.
#
# Trigger: refresh-colors (run last by walrgb, apply-colorscheme and
# restore-colorscheme) writes ~/.cache/hydrix/boot-theme.trigger, which a
# path unit watches.
#
# Enable with: hydrix.{grub.theme,plymouth,sddm}.followWal
{
  config,
  options,
  lib,
  pkgs,
  ...
}: let
  grub = config.hydrix.grub.theme;
  ply = config.hydrix.plymouth;
  doGrub = grub.enable && grub.followWal;
  doPly = ply.enable && ply.followWal && config.boot.loader.grub.enable;
  sddm = config.hydrix.sddm;
  doSddm = sddm.enable && sddm.followWal;

  home = config.users.users.${config.hydrix.username}.home;
  wal = "${home}/.cache/wal";
  trigger = "${home}/.cache/hydrix/boot-theme.trigger";

  espDir = "/boot/hydrix";
  stageDir = "/var/lib/hydrix-boot-theme/plymouth";
  sddmConf = "/var/lib/hydrix-boot-theme/sddm/theme.conf.user";
  # GRUB-side path of espDir, same rule install-grub.pl uses for /theme.
  grubDir = "${lib.optionalString (!(config.fileSystems ? "/boot")) "/boot"}/hydrix";

  # wal key per color slot, the same mapping pywalToBase16 (theming/lib.nix)
  # applies to declared colorschemes. error has none: it stays a fixed red.
  bootWalKey = {
    bg = ".special.background // .colors.color0";
    fg = ".special.foreground // .colors.color7";
    accent = ".colors.color1";
    accentBright = ".colors.color2";
    muted = ".colors.color8";
    ok = ".colors.color2";
    warn = ".colors.color3";
    highlight = ".colors.color4";
    dim = ".colors.color8";
  };
  # The greeter mirrors hyprlock's colors-lock.conf slots instead.
  sddmWalKey = {
    bg = ".special.background // .colors.color0";
    fg = ".special.foreground // .colors.color7";
    accent = ".colors.color4";
    wrong = ".colors.color1";
  };
  envName = {
    bg = "BG";
    fg = "FG";
    accent = "ACCENT";
    accentBright = "ACCENT_BRIGHT";
    muted = "MUTED";
    error = "ERROR";
    ok = "OK";
    warn = "WARN";
    highlight = "HIGHLIGHT";
    dim = "DIM";
    wrong = "WRONG";
  };

  # Exports one renderer's colors: wal-derived, except slots set explicitly in
  # Nix (anything above the option default's priority), which stay pinned.
  exportColors = walKey: opts: values:
    lib.concatStrings (lib.mapAttrsToList (name: value: let
      pinned = opts.${name}.highestPrio < (lib.mkOptionDefault null).priority;
    in
      if walKey ? ${name} && !pinned
      then "${envName.${name}}=$(walColor ${lib.escapeShellArg walKey.${name}})\nexport ${envName.${name}}\n"
      else "export ${envName.${name}}=${lib.escapeShellArg value}\n")
    values);

  syncScript = pkgs.writeShellScript "hydrix-boot-theme-sync" ''
    set -euo pipefail
    PATH=${lib.makeBinPath [pkgs.coreutils pkgs.findutils pkgs.jq pkgs.cpio]}
    colors=${wal}/colors.json

    # colors.json is user-writable and this runs as root: accept plain hex only.
    walColor() {
      local v
      v=$(jq -r "($1) // empty" "$colors")
      if [[ ! $v =~ ^#[0-9a-fA-F]{6}$ ]]; then
        echo "invalid wal color for $1: '$v'" >&2
        return 1
      fi
      printf '%s' "$v"
    }

    # Swap a directory in whole, so a half-written theme is never visible.
    replaceDir() {
      rm -rf "$2.new" "$2.old"
      cp -rL --no-preserve=mode "$1" "$2.new"
      if [ -e "$2" ]; then mv "$2" "$2.old"; fi
      mv "$2.new" "$2"
      rm -rf "$2.old"
    }

    if [ -f ${wal}/.active ] && [ -f "$colors" ]; then
      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT
      mkdir -p "$work/esp"
      ${lib.optionalString doGrub ''
      (
        ${exportColors bootWalKey options.hydrix.grub.theme.colors grub.colors}
        ${grub.renderer} "$work/esp/grub"
      )
    ''}
      ${lib.optionalString doPly ''
      (
        ${exportColors bootWalKey options.hydrix.plymouth.colors ply.colors}
        ${ply.renderer} "$work/plymouth"
      )
      mkdir -p "$work/initrd/etc"
      cp -r "$work/plymouth" "$work/initrd/etc/hydrix-plymouth"
      (cd "$work/initrd" && find etc -type f | cpio -o -H newc -R 0:0 --quiet) > "$work/esp/plymouth.cpio"
      replaceDir "$work/plymouth" ${stageDir}
    ''}
      ${lib.optionalString doSddm ''
      (
        ${exportColors sddmWalKey options.hydrix.sddm.colors sddm.colors}
        mkdir -p "$(dirname ${sddmConf})"
        printf '[General]\nbg="%s"\nfg="%s"\naccent="%s"\nwrong="%s"\n' \
          "$BG" "$FG" "$ACCENT" "$WRONG" > ${sddmConf}.tmp
        mv ${sddmConf}.tmp ${sddmConf}
      )
    ''}
      replaceDir "$work/esp" ${espDir}
      echo "Boot theme: wal colors"
    else
      rm -rf ${espDir} ${espDir}.new ${espDir}.old ${sddmConf}
      ${lib.optionalString doPly "replaceDir ${ply.declaredFiles} ${stageDir}"}
      echo "Boot theme: declared colors"
    fi
  '';

  serviceConfig = {
    Type = "oneshot";
    ExecStart = syncScript;
    StateDirectory = "hydrix-boot-theme";
    ReadWritePaths = ["/boot"];
    ProtectSystem = "strict";
    ProtectHome = "read-only";
    PrivateTmp = true;
    PrivateNetwork = true;
    NoNewPrivileges = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectControlGroups = true;
  };
in {
  config = lib.mkIf (doGrub || doPly || doSddm) {
    boot.loader.grub.extraConfig = lib.mkIf (doGrub || doPly) ''
      ${lib.optionalString doGrub ''
        if [ -f ${grubDir}/grub/theme.txt ]; then
          set theme=${grubDir}/grub/theme.txt
          export theme
        fi
      ''}
      ${lib.optionalString doPly ''
        if [ -f ${grubDir}/plymouth.cpio ]; then
          set hydrix_plymouth=($root)${grubDir}/plymouth.cpio
          export hydrix_plymouth
        fi
      ''}
    '';

    # Every menu entry loads the overlay after its own initrd when present.
    # Unset, $hydrix_plymouth expands to nothing and the declared theme boots.
    boot.loader.grub.extraInstallCommands = lib.mkIf doPly ''
      for cfg in ${lib.concatMapStringsSep " " (b: "${b.path}/grub/grub.cfg") config.boot.loader.grub.mirroredBoots}; do
        [ -f "$cfg" ] || continue
        ${pkgs.gnused}/bin/sed -i '/^  initrd .* \$hydrix_plymouth$/!s/^  initrd .*$/& $hydrix_plymouth/' "$cfg"
      done
    '';

    systemd.paths.hydrix-boot-theme = {
      description = "Watch for colorscheme changes to apply to the boot theme";
      wantedBy = ["paths.target"];
      pathConfig.PathChanged = trigger;
    };

    systemd.services.hydrix-boot-theme = {
      description = "Apply runtime wal colors to the GRUB, Plymouth and SDDM themes";
      unitConfig.RequiresMountsFor = ["/boot" home];
      inherit serviceConfig;
    };

    # Same sync at boot and whenever a rebuild changes the script (declared
    # colors, theme layout), so stage 2 and the overlay never lag behind.
    systemd.services.hydrix-boot-theme-init = {
      description = "Sync the GRUB, Plymouth and SDDM themes with the active colorscheme";
      wantedBy = ["multi-user.target"];
      unitConfig.RequiresMountsFor = ["/boot" home];
      serviceConfig = serviceConfig // {RemainAfterExit = true;};
    };
  };
}
