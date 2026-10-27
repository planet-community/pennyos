#!/bin/sh
# Print the Cosmo's niri config.kdl: upstream default-config.kdl with two small edits,
# plus an include of cosmo.kdl (tools/rootfs/files/theme/niri/cosmo.kdl), which holds
# everything device- and theme-specific. niri merges includes, later settings win.
# Usage: niri-config.sh <path to default-config.kdl>
sed -e 's/Open a Terminal: alacritty/Open a Terminal: foot/' -e 's/spawn "alacritty"/spawn "foot"/' \
    -e 's#^spawn-at-startup "waybar"#// spawn-at-startup "waybar"   (Debian starts waybar.service with the session)#' \
    "$1"
cat <<'EOF'

// ---- Planet Cosmo Communicator: device settings + default look ----
include "cosmo.kdl"
// keyboard layout, written by penny-setup
include "keyboard.kdl"
EOF
