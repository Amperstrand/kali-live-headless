#!/bin/sh
# zz-live-config_xinit.sh — auto-start X on the autologin console.
#
# OVERRIDE of Kali live-config's script with one guard the minimal/LEAN
# variant needs: startx into an image with NO x-session-manager alternative
# leaves a running Xorg with a dead session — a "frozen" console with a
# perfectly working keyboard (found live on #23, 2026-10-24: X had the
# keyboard via libinput, IRQ counters flowed, but no WM existed to consume
# events). Stay on the text console instead — the banner + text login is
# the intended headless-first UX anyway.

if [ -n "$SSH_CONNECTION" ] || [ -n "$SSH_TTY" ]; then
    return 0
fi

# no session manager -> no X (a session-less Xorg is a frozen screen)
if ! update-alternatives --query x-session-manager >/dev/null 2>&1 \
   && ! command -v x-session-manager >/dev/null 2>&1; then
    echo ""
    echo "kali-live-headless: no graphical session in this image — text console only."
    echo "(SSH over Wi-Fi/WireGuard is the primary access channel.)"
    return 0
fi

if [ -x /usr/bin/startx ] && command -v systemctl >/dev/null 2>&1 \
   && ! systemctl is-active graphical.target >/dev/null 2>&1; then
    exec /usr/bin/startx >/dev/null 2>&1
fi
