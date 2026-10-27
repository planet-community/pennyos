# pennyos: start the niri desktop when logging in on the phone's own screen.
# niri-session re-executes itself through a login shell, which reads this file
# again - PENNYOS_NIRI stops that from looping.
if [ -z "$WAYLAND_DISPLAY" ] && [ -z "$PENNYOS_NIRI" ] && [ "$(tty)" = /dev/tty1 ]; then
    export PENNYOS_NIRI=1
    exec niri-session
fi
