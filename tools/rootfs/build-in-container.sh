#!/bin/bash
# Runs INSIDE the (privileged) cosmo-kbuild container; see tools/mkrootfs.sh.
#   /vol   Docker volume: /vol/root = rootfs tree, /vol/mods = kernel modules
#   /work  the repo;  /pubkey (optional) SSH public key to authorize
set -euo pipefail
SUITE=trixie
R=/vol/root
IMG=/work/out/debian-rootfs.img
PKGS=systemd-sysv,udev,dbus,kmod,e2fsprogs,openssh-server,sudo,iproute2,iputils-ping,ca-certificates,curl,less,nano,procps,usbutils,i2c-tools,evtest,kbd,fbset,pciutils,file,strace
# Desktop: Mesa (Panfrost), session plumbing, and the small tools niri's config uses.
DESKTOP_PKGS="evtest libpam-systemd dbus-user-session libseat1 libinput10 libdisplay-info2 libgbm1 libegl1 libgles2 libgl1-mesa-dri libxkbcommon0 libpangocairo-1.0-0 xkb-data foot fuzzel waybar mako-notifier swaybg swaylock fonts-dejavu-core fonts-noto-core locales libnotify-bin wl-clipboard brightnessctl mesa-utils kmscube python3-gi gir1.2-gtk-3.0"
# Default look: fonts, icons, cursor, dark GTK theme; idle handling (swayidle).
THEME_PKGS="libgtk-layer-shell0 fonts-inter-variable fonts-jetbrains-mono fonts-font-awesome papirus-icon-theme bibata-cursor-theme gnome-themes-extra swayidle"
# Voice typing (Fn+Space, penny-dictate): recorder and mixer, and typing into the focused window.
VOICE_PKGS="alsa-utils wtype"
# Network: Wi-Fi tools, regulatory database, DNS for networkd-managed links.
NET_PKGS="iw wpasupplicant wireless-regdb systemd-resolved polkitd"

apt-get update -qq >/dev/null
apt-get install -y -qq debootstrap e2fsprogs kmod >/dev/null

if [ ! -f "$R/.pennyos-debootstrapped" ]; then
  echo "==> debootstrap $SUITE arm64 (minbase)"
  mkdir -p "$R"
  debootstrap --arch=arm64 --variant=minbase --include="$PKGS" "$SUITE" "$R" http://deb.debian.org/debian
  touch "$R/.pennyos-debootstrapped"
fi

echo "==> configuring"
echo pennyos > "$R/etc/hostname"
printf '127.0.0.1 localhost\n127.0.1.1 pennyos\n' > "$R/etc/hosts"
# Root is the GPT partition named "linux" on the eMMC.
printf 'PARTLABEL=linux / ext4 defaults,noatime,errors=remount-ro 0 1\n' > "$R/etc/fstab"

# USB ethernet gadget (usb0): fixed address + DHCP server, so the host configures itself.
mkdir -p "$R/etc/systemd/network"
cat > "$R/etc/systemd/network/10-usb0.network" <<'EOF'
[Match]
Name=usb0

[Network]
Address=172.16.42.1/24
DHCPServer=yes
LinkLocalAddressing=no
IPv6AcceptRA=no

[DHCPServer]
PoolOffset=2
PoolSize=8
EmitDNS=no
EmitRouter=no
EOF

# LK hands over with the hardware watchdog armed; let systemd own it.
mkdir -p "$R/etc/systemd/system.conf.d"
printf '[Manager]\nRuntimeWatchdogSec=25\n' > "$R/etc/systemd/system.conf.d/10-watchdog.conf"

# The Cosmo's power key IS the Esc key. A tap must never shut the machine down;
# only a deliberate long press does.
mkdir -p "$R/etc/systemd/logind.conf.d"
printf '[Login]\nHandlePowerKey=ignore\nHandlePowerKeyLongPress=poweroff\n' > "$R/etc/systemd/logind.conf.d/10-pennyos-esc.conf"
# closing the lid sleeps (also applied to a running phone by tools/install-theme.sh)
install -m 644 /work/tools/rootfs/files/logind/20-pennyos-lid.conf "$R/etc/systemd/logind.conf.d/"
# Sleep must be s2idle: "deep" goes through PSCI SYSTEM_SUSPEND, which this firmware
# does not handle for mainline. mem_sleep_default= on the command line does not
# stick on this kernel, so set it at boot.
mkdir -p "$R/etc/tmpfiles.d"
echo 'w /sys/power/mem_sleep - - - - s2idle' > "$R/etc/tmpfiles.d/pennyos-sleep.conf"

# Display (mediatek-drm + panel + MT6370 backlight), GPU (panfrost) and the MT6370
# charger/ADC autoload. Without the charger driver the battery does not charge at all.
cat > "$R/etc/modprobe.d/pennyos-manual.conf" <<'EOF'
# pennyos: load these by hand (modprobe <name>) while they are being brought up.
blacklist pwm_mtk_disp
# 6.4 mtk_dsi registers its DSI host before setting drvdata, so it oopses if the
# panel driver is already loaded and binds from inside that call. Load order matters:
softdep panel_simple pre: mediatek_drm
EOF

# Grow the filesystem to fill the partition on first boot, then never again.
cat > "$R/etc/systemd/system/pennyos-growfs.service" <<'EOF'
[Unit]
Description=Grow the root filesystem to fill the linux partition (first boot)
ConditionPathExists=!/var/lib/pennyos-growfs.done
After=systemd-remount-fs.service

[Service]
Type=oneshot
# resolve the device from the mounted root: /dev/disk/by-partlabel may not exist yet
ExecStart=/bin/sh -c 'exec /sbin/resize2fs "$(findmnt -no SOURCE /)"'
ExecStartPost=/usr/bin/touch /var/lib/pennyos-growfs.done

[Install]
WantedBy=multi-user.target
EOF

echo "==> desktop packages"
cp /etc/resolv.conf "$R/etc/resolv.conf"
chroot "$R" apt-get update -qq
DEBIAN_FRONTEND=noninteractive chroot "$R" apt-get install -y -qq --no-install-recommends $DESKTOP_PKGS $THEME_PKGS $NET_PKGS >/dev/null

# keyboard layouts for the Cosmo Fn layer (selected in the niri config). In the
# system directory: a compositor that is already running does not pick up /etc/xkb.
install -D -m 644 /work/tools/rootfs/files/xkb/cosmo "$R/usr/share/X11/xkb/symbols/cosmo"
install -m 644 /work/tools/rootfs/files/99-pennyos-touch.rules "$R/etc/udev/rules.d/"
install -m 644 /work/tools/rootfs/files/90-pennyos-backlight.rules "$R/etc/udev/rules.d/"
install -m 644 /work/tools/rootfs/files/91-pennyos-charger.rules "$R/etc/udev/rules.d/"
install -m 644 /work/tools/rootfs/files/92-pennyos-wifi.rules "$R/etc/udev/rules.d/"
install -m 755 /work/tools/rootfs/files/penny-charge-setup "$R/usr/local/bin/"
install -m 755 /work/tools/rootfs/files/penny-thermal "$R/usr/local/bin/"
install -m 644 /work/tools/rootfs/files/penny-thermal.service "$R/etc/systemd/system/"

chroot "$R" systemctl enable systemd-networkd ssh pennyos-growfs.service penny-thermal.service >/dev/null 2>&1

# User: cosmo / cosmo (sudo) - a known default so the on-device console works out
# of the box. `penny-setup` (Settings > First-time setup) changes name and password.
if ! chroot "$R" id cosmo >/dev/null 2>&1; then
  chroot "$R" useradd -m -s /bin/bash -G sudo,video,input,dialout,audio cosmo
fi
echo 'cosmo:cosmo' | chroot "$R" chpasswd
if [ -f /pubkey ]; then
  install -d -m 700 "$R/home/cosmo/.ssh"
  install -m 600 /pubkey "$R/home/cosmo/.ssh/authorized_keys"
  chroot "$R" chown -R cosmo:cosmo /home/cosmo/.ssh
  echo "    authorized SSH key: $(cut -d' ' -f1,3 /pubkey)"
else
  echo "    WARNING: no SSH public key supplied - SSH logins will not be possible until you add one"
fi
# The well-known password is only ever good at the physical console / serial getty
# (and for sudo), never over the network - key or no key.
printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' > "$R/etc/ssh/sshd_config.d/10-pennyos.conf"

# niri is not packaged in Debian: take the build from out/niri (tools/rootfs/build-niri.sh).
if [ -x /work/out/niri/niri ]; then
  echo "==> installing niri $(cat /work/out/niri/TAG 2>/dev/null)"
  install -m 755 /work/out/niri/niri /work/out/niri/niri-session "$R/usr/local/bin/"
  install -D -m 644 /work/out/niri/niri.service /work/out/niri/niri-shutdown.target -t "$R/etc/systemd/user/"
  sed -i 's#/usr/bin/niri#/usr/local/bin/niri#' "$R/etc/systemd/user/niri.service"
  install -D -m 644 /work/out/niri/niri.desktop "$R/usr/local/share/wayland-sessions/niri.desktop"
  install -D -m 644 /work/out/niri/niri-portals.conf "$R/usr/local/share/xdg-desktop-portal/niri-portals.conf"
  install -d "$R/home/cosmo/.config/niri"
  sh /work/tools/rootfs/niri-config.sh /work/out/niri/default-config.kdl > "$R/home/cosmo/.config/niri/config.kdl"
  grep -q "pennyos: start the niri desktop" "$R/home/cosmo/.profile" || cat /work/tools/rootfs/files/profile-niri.sh >> "$R/home/cosmo/.profile"
  # default look (Tokyo Night): niri include, bar, launcher, notifications, terminal,
  # lock screen, GTK settings, wallpaper, screen on/off helper - same files as tools/install-theme.sh
  T=/work/tools/rootfs/files/theme
  install -m 644 $T/niri/cosmo.kdl "$R/home/cosmo/.config/niri/cosmo.kdl"
  install -m 644 $T/niri/keyboard.kdl "$R/home/cosmo/.config/niri/keyboard.kdl"
  for d in waybar fuzzel mako foot swaylock gtk-3.0 gtk-4.0; do
    install -d "$R/home/cosmo/.config/$d" && cp $T/$d/* "$R/home/cosmo/.config/$d/"
  done
  install -D -m 644 $T/wallpaper.png "$R/usr/local/share/pennyos/wallpaper.png"
  install -m 755 /work/tools/rootfs/files/penny-screen "$R/usr/local/bin/penny-screen"
  install -m 755 /work/tools/rootfs/files/penny-bar-battery /work/tools/rootfs/files/penny-wifi-menu \
    /work/tools/rootfs/files/penny-bar-close /work/tools/rootfs/files/penny-power-menu \
    /work/tools/rootfs/files/penny-sleep /work/tools/rootfs/files/penny-hold-esc \
    /work/tools/rootfs/files/penny-settings /work/tools/rootfs/files/penny-setup \
    /work/tools/rootfs/files/penny-kbd-light /work/tools/rootfs/files/penny-volume /work/tools/rootfs/files/penny-diag "$R/usr/local/bin/"
  # launcher tidy-up: a Settings entry, "Terminal" for foot, helper entries hidden
  # (/usr/local/share/applications overrides /usr/share/applications by file name)
  install -d "$R/usr/local/share/applications"
  install -m 644 /work/tools/rootfs/files/applications/*.desktop "$R/usr/local/share/applications/"
  install -D -m 755 /work/tools/rootfs/files/penny-sleep-hook "$R/usr/lib/systemd/system-sleep/pennyos"
  # the animation shown while the desktop starts (tools/splash/build.sh)
  if [ -x /work/out/splash/penny-splash ]; then
    install -m 755 /work/out/splash/penny-splash "$R/usr/local/bin/"
  else
    echo "WARNING: no out/splash/penny-splash - the desktop starts without its animation"
  fi
  # voice typing: whisper.cpp from out/whisper (tools/rootfs/build-whisper.sh) and its
  # model; penny-dictate says so if they are missing
  chroot "$R" apt-get install -y --no-install-recommends $VOICE_PKGS
  install -m 755 /work/tools/rootfs/files/penny-dictate "$R/usr/local/bin/"
  # speakers: mixer routing when the sound card appears (needs amixer from alsa-utils)
  install -m 755 /work/tools/rootfs/files/penny-sound-setup "$R/usr/local/bin/"
  install -m 644 /work/tools/rootfs/files/93-pennyos-sound.rules "$R/etc/udev/rules.d/"
  install -m 644 /work/tools/rootfs/files/asound.conf "$R/etc/asound.conf"
  if [ -x /work/out/whisper/whisper-cli ] && ls /work/out/whisper/ggml-*.bin >/dev/null 2>&1; then
    echo "==> installing whisper.cpp $(cat /work/out/whisper/TAG 2>/dev/null)"
    install -m 755 /work/out/whisper/whisper-cli "$R/usr/local/bin/"
    install -D -m 644 -t "$R/usr/local/share/pennyos/whisper/" /work/out/whisper/ggml-*.bin
  else
    echo "WARNING: out/whisper is incomplete - voice typing will not work"
  fi
  # file manager and app store: Thunar, GNOME Software (Debian packages + Flatpak
  # from Flathub), a polkit agent for their password prompts, dark defaults via dconf
  chroot "$R" apt-get install -y --no-install-recommends thunar gvfs tumbler gnome-software \
    gnome-software-plugin-flatpak gnome-software-plugin-deb packagekit flatpak mate-polkit dconf-cli adwaita-icon-theme
  # creating the repository needs /proc (ostree links its temporary files through it)
  mount -t proc proc "$R/proc"
  chroot "$R" flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || { umount "$R/proc"; exit 1; }
  umount "$R/proc"
  install -D -m 644 /work/tools/rootfs/files/dconf/00-pennyos "$R/etc/dconf/db/local.d/00-pennyos"
  mkdir -p "$R/etc/dconf/profile" && printf 'user-db:user\nsystem-db:local\n' > "$R/etc/dconf/profile/user"
  chroot "$R" dconf update
  # Flatpak apps are sandboxed and cannot read dconf: they learn the colour scheme
  # (and get file-open dialogs) from the desktop portal. Without it they come up light.
  chroot "$R" apt-get install -y --no-install-recommends xdg-desktop-portal xdg-desktop-portal-gtk
  install -d "$R/etc/xdg/xdg-desktop-portal"
  printf '[preferred]\ndefault=gtk\n' > "$R/etc/xdg/xdg-desktop-portal/niri-portals.conf"
  # login screen: greetd + gtkgreet inside a bare niri (tools/rootfs/files/greetd/)
  G=/work/tools/rootfs/files/greetd
  chroot "$R" apt-get install -y --no-install-recommends greetd gtkgreet
  install -m 644 $G/config.toml $G/niri-greeter.kdl $G/environments $G/gtkgreet.css "$R/etc/greetd/"
  install -m 644 $T/niri/keyboard.kdl "$R/etc/greetd/keyboard.kdl"
  install -m 755 $G/penny-greeter "$R/usr/local/bin/penny-greeter"
  chroot "$R" usermod -aG video,render,input _greetd
  chroot "$R" systemctl enable greetd.service
  chroot "$R" chown -R cosmo:cosmo /home/cosmo
else
  echo "    (no out/niri build found - image will boot to a console login)"
fi

# Built-in radio (Wi-Fi/BT): out-of-tree vendor modules (kernel/connectivity), our
# daemon and helpers, and - not in git - the proprietary firmware plus THIS phone's
# NVRAM calibration/MAC, both under collected/vendor-conn (see kernel/connectivity/README.md).
if [ -f /work/out/conn-mods/wmt_drv.ko ] && [ -x /work/out/penny-wmtd ]; then
  echo "==> installing the radio stack"
  install -d "$R/opt/pennyos/conn" "$R/etc/firmware" "$R/lib/firmware"
  install -m 644 /work/out/conn-mods/*.ko "$R/opt/pennyos/conn/"
  install -m 755 /work/out/penny-wmtd /work/tools/wmt/penny-conn-up /work/tools/wmt/penny-wifi-connect "$R/usr/local/bin/"
  install -D -m 644 /work/tools/rootfs/files/penny-wifi-lib "$R/usr/local/lib/pennyos/wifi.sh"
  # saved networks start empty; wpa_supplicant@wlan0 does not start without the file
  [ -f "$R/etc/wpa_supplicant/wpa_supplicant-wlan0.conf" ] ||
    install -D -m 600 /work/tools/rootfs/files/wpa_supplicant-wlan0.conf "$R/etc/wpa_supplicant/wpa_supplicant-wlan0.conf"
  install -D -m 644 /work/tools/rootfs/files/polkit/50-pennyos-wifi.rules "$R/etc/polkit-1/rules.d/50-pennyos-wifi.rules"
  install -m 644 /work/tools/rootfs/files/20-wlan0.network "$R/etc/systemd/network/"
  install -m 644 /work/tools/rootfs/files/penny-conn.service "$R/etc/systemd/system/"
  chroot "$R" systemctl enable penny-conn.service systemd-resolved >/dev/null 2>&1
  chroot "$R" usermod -aG netdev cosmo
  FW=/work/collected/vendor-conn/firmware
  if [ -f $FW/WIFI_RAM_CODE_6759 ]; then
    install -m 644 $FW/ROMv4_be_patch_1_0_hdr.bin $FW/ROMv4_be_patch_1_1_hdr.bin $FW/WMT_SOC.cfg $FW/WIFI_RAM_CODE_6759 "$R/lib/firmware/"
    ln -sf /lib/firmware/WIFI_RAM_CODE_6759 "$R/etc/firmware/WIFI_RAM_CODE_6759"
  else
    echo "    WARNING: no radio firmware in collected/vendor-conn/firmware - Wi-Fi will not start"
  fi
  if [ -f /work/collected/vendor-conn/nvram/WIFI ]; then
    install -d -m 700 "$R/opt/pennyos/conn/nvram"
    install -m 600 /work/collected/vendor-conn/nvram/WIFI "$R/opt/pennyos/conn/nvram/WIFI"
  fi
fi

echo "==> installing kernel modules"
KVER=$(ls /vol/mods/lib/modules | head -1)
mkdir -p "$R/usr/lib/modules"
# replace, do not merge: stale modules from an earlier kernel config must not survive
if [ -d "$R/usr/lib/modules/$KVER" ]; then find "$R/usr/lib/modules/$KVER" -delete; fi
cp -a "/vol/mods/lib/modules/$KVER" "$R/usr/lib/modules/"
depmod -b "$R/usr" "$KVER" 2>/dev/null || depmod -b "$R" "$KVER"
echo "    $KVER: $(find "$R/usr/lib/modules/$KVER" -name '*.ko' | wc -l) modules"

chroot "$R" apt-get clean
# the build container's DNS servers were only for the package installs above
: > "$R/etc/resolv.conf"
USED_MB=$(du -sm --exclude=./proc --exclude=./sys "$R" | cut -f1)
SIZE_MB=$((USED_MB + USED_MB / 4 + 200))
echo "==> building ext4 image (${USED_MB} MiB used -> ${SIZE_MB} MiB image)"
mkdir -p /work/out
truncate -s 0 "$IMG"
truncate -s "${SIZE_MB}M" "$IMG"
mkfs.ext4 -q -F -L pennyos-root -d "$R" "$IMG"
ls -la "$IMG"
