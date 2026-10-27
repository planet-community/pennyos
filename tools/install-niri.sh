#!/bin/sh
# Install the niri build from out/niri (tools/rootfs/build-niri.sh) on the running
# Cosmo over SSH, with a config tailored to the device. niri then starts when the
# `cosmo` user logs in on the phone's own console (tty1).
#
# Usage: tools/install-niri.sh [user@host]      (default cosmo@172.16.42.1)
set -e
REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${1:-cosmo@172.16.42.1}"
N="$REPO/out/niri"
[ -x "$N/niri" ] || { echo "no build in out/niri - run tools/rootfs/build-niri.sh"; exit 1; }

# Device config = upstream default + Cosmo specifics (shared with the image build).
CFG=$(mktemp)
sh "$REPO/tools/rootfs/niri-config.sh" "$N/default-config.kdl" > "$CFG"

ssh "$HOST" 'mkdir -p /tmp/niri ~/.config/niri'
scp -q "$N/niri" "$N/niri-session" "$N/niri.service" "$N/niri-shutdown.target" "$N/niri.desktop" "$N/niri-portals.conf" "$REPO/tools/rootfs/files/profile-niri.sh" "$HOST:/tmp/niri/"
scp -q "$CFG" "$HOST:.config/niri/config.kdl"
scp -q "$REPO/tools/rootfs/files/theme/niri/cosmo.kdl" "$HOST:.config/niri/cosmo.kdl"
ssh "$HOST" 'echo cosmo | sudo -S sh -c "
  install -m 755 /tmp/niri/niri /tmp/niri/niri-session /usr/local/bin/ &&
  install -D -m 644 /tmp/niri/niri.service /tmp/niri/niri-shutdown.target -t /etc/systemd/user/ &&
  install -D -m 644 /tmp/niri/niri.desktop /usr/local/share/wayland-sessions/niri.desktop &&
  install -D -m 644 /tmp/niri/niri-portals.conf /usr/local/share/xdg-desktop-portal/niri-portals.conf &&
  sed -i s#/usr/bin/niri#/usr/local/bin/niri# /etc/systemd/user/niri.service
" 2>/dev/null
# start the desktop on console login only (never over SSH or serial)
sed -i "/^# \(pennyos\|cosmonext\): start the niri desktop/,/^fi\$/d" ~/.profile 2>/dev/null
cat /tmp/niri/profile-niri.sh >> ~/.profile
niri --version; niri validate'
