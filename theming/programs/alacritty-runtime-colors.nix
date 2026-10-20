# jq fragment appended to every colors-runtime.toml writer: hint labels, search
# matches and the search bar in wal colors. `bg` is a jq expression for the
# terminal background (a VM's comes from the host). The label is drawn in the
# foreground color, so it reads on any scheme wal produces.
bg: ''
  "\n\n[colors.hints.start]\n" +
  "foreground = \"" + ${bg} + "\"\n" +
  "background = \"" + (.special.foreground // .colors.color7) + "\"\n\n" +
  "[colors.hints.end]\n" +
  "foreground = \"" + ${bg} + "\"\n" +
  "background = \"" + .colors.color8 + "\"\n\n" +
  "[colors.search.matches]\n" +
  "foreground = \"" + ${bg} + "\"\n" +
  "background = \"" + .colors.color8 + "\"\n\n" +
  "[colors.search.focused_match]\n" +
  "foreground = \"" + ${bg} + "\"\n" +
  "background = \"" + (.special.foreground // .colors.color7) + "\"\n\n" +
  "[colors.footer_bar]\n" +
  "foreground = \"" + ${bg} + "\"\n" +
  "background = \"" + .colors.color8 + "\""
''
