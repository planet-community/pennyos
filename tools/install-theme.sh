#!/bin/sh
# Apply the default PennyOS look (Tokyo Night theme, wallpaper, bar, idle/screen-off)
# to a running Cosmo over SSH. The same files are baked into the image by
# tools/mkrootfs.sh; this is for a phone that is already installed.
#
# Usage: tools/install-theme.sh [user@host]      (default cosmo@172.16.42.1)
set -e
REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${1:-cosmo@172.16.42.1}"
T="$REPO/tools/rootfs/files/theme"
PKGS="libgtk-layer-shell0 fonts-inter-variable fonts-jetbrains-mono fonts-font-awesome papirus-icon-theme bibata-cursor-theme gnome-themes-extra swayidle alsa-utils wtype libnotify-bin locales"

CFG=$(mktemp)
sh "$REPO/tools/rootfs/niri-config.sh" "$REPO/out/niri/default-config.kdl" > "$CFG"
ssh "$HOST" 'mkdir -p /tmp/theme ~/.config/niri'
scp -q -r "$T"/niri "$T"/waybar "$T"/fuzzel "$T"/mako "$T"/foot "$T"/swaylock "$T"/gtk-3.0 "$T"/gtk-4.0 "$HOST:/tmp/theme/"
scp -q "$T/wallpaper.png" "$REPO/tools/rootfs/files/penny-screen" "$REPO/tools/rootfs/files/penny-bar-battery" "$REPO/tools/rootfs/files/penny-bar-close" "$REPO/tools/rootfs/files/penny-power-menu" "$REPO/tools/rootfs/files/penny-sleep" "$REPO/tools/rootfs/files/penny-hold-esc" "$REPO/tools/rootfs/files/penny-dictate" "$REPO/tools/rootfs/files/penny-setup" "$REPO/tools/rootfs/files/penny-settings" "$REPO/tools/rootfs/files/greetd/niri-greeter.kdl" "$REPO/tools/rootfs/files/penny-wifi-menu" "$REPO/out/splash/penny-splash" "$REPO/tools/rootfs/files/penny-wifi-lib" "$REPO/tools/wmt/penny-wifi-connect" "$REPO/tools/rootfs/files/wpa_supplicant-wlan0.conf" "$REPO/tools/rootfs/files/polkit/50-pennyos-wifi.rules" "$REPO/tools/rootfs/files/penny-sleep-hook" "$REPO/tools/rootfs/files/90-pennyos-backlight.rules" "$REPO/tools/rootfs/files/xkb/cosmo" "$REPO/tools/rootfs/files/logind/20-pennyos-lid.conf" "$HOST:/tmp/theme/"
scp -q "$CFG" "$HOST:/tmp/theme/config.kdl"
# A phone installed before the project was renamed to PennyOS: carry its data over,
# drop the old copies of what is installed below, and keep the old command names as
# links, because files this script does not replace may still call them.
cat > "$CFG" <<'EOF'
[ -d /usr/local/share/cosmonext ] || exit 0
[ -e /usr/local/share/pennyos ] || mv /usr/local/share/cosmonext /usr/local/share/pennyos
for f in screen bar-battery bar-close power-menu sleep hold-esc wifi-menu dictate setup settings; do
  [ -e /usr/local/bin/cosmo-$f ] && ln -sf penny-$f /usr/local/bin/cosmo-$f
done
rm -f /usr/lib/systemd/system-sleep/cosmonext /etc/systemd/logind.conf.d/20-cosmonext-lid.conf \
  /etc/udev/rules.d/90-cosmonext-backlight.rules
echo "renamed the old cosmonext files to pennyos"
EOF
scp -q "$CFG" "$HOST:/tmp/theme/migrate-names.sh"
ssh -t "$HOST" "sudo sh -c 'apt-get install -y --no-install-recommends $PKGS && sh /tmp/theme/migrate-names.sh && install -D -m 644 /tmp/theme/wallpaper.png /usr/local/share/pennyos/wallpaper.png && cd /tmp/theme && install -m 755 penny-screen penny-bar-battery penny-bar-close penny-power-menu penny-sleep penny-hold-esc penny-wifi-menu penny-splash penny-dictate penny-setup penny-settings /usr/local/bin/ && if [ -d /etc/greetd ]; then [ -e /etc/greetd/keyboard.kdl ] || install -m 644 niri/keyboard.kdl /etc/greetd/keyboard.kdl; install -m 644 niri-greeter.kdl /etc/greetd/; fi && install -D -m 755 penny-sleep-hook /usr/lib/systemd/system-sleep/pennyos && install -D -m 644 cosmo /usr/share/X11/xkb/symbols/cosmo && install -D -m 644 penny-wifi-lib /usr/local/lib/pennyos/wifi.sh && install -m 755 penny-wifi-connect /usr/local/bin/ && install -D -m 644 50-pennyos-wifi.rules /etc/polkit-1/rules.d/50-pennyos-wifi.rules && if [ ! -f /etc/wpa_supplicant/wpa_supplicant-wlan0.conf ]; then install -D -m 600 wpa_supplicant-wlan0.conf /etc/wpa_supplicant/ && systemctl restart wpa_supplicant@wlan0.service || true; fi && install -D -m 644 20-pennyos-lid.conf /etc/systemd/logind.conf.d/20-pennyos-lid.conf && systemctl reload systemd-logind && install -m 644 /tmp/theme/90-pennyos-backlight.rules /etc/udev/rules.d/ && udevadm control --reload && udevadm trigger --subsystem-match=backlight --action=add'"
ssh "$HOST" 'set -e
  for d in waybar fuzzel mako foot swaylock gtk-3.0 gtk-4.0; do mkdir -p ~/.config/$d && cp /tmp/theme/$d/* ~/.config/$d/; done
  cp /tmp/theme/niri/cosmo.kdl ~/.config/niri/cosmo.kdl
  # the keyboard layout belongs to penny-setup: only supply the default
  [ -e ~/.config/niri/keyboard.kdl ] || cp /tmp/theme/niri/keyboard.kdl ~/.config/niri/keyboard.kdl
  cp /tmp/theme/config.kdl ~/.config/niri/config.kdl
  niri validate 2>&1 | tail -1
  if [ -S "$(ls /run/user/$(id -u)/niri.*.sock 2>/dev/null | head -1)" ]; then
    systemctl --user restart waybar.service 2>/dev/null || true
    makoctl reload 2>/dev/null || true
    echo "theme applied to the running session (log out and in for cursor/GTK changes)"
  fi'
