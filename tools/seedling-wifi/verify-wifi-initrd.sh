#!/bin/bash
# verify-wifi-initrd.sh — assert the Wi-Fi initrd contents (run in container)
set -u
L=$(lsinitramfs /src/out/initrd-wifi.img)
c() { echo "$2: $(echo "$L" | grep -c "$1")"; }
c 'wpa_supplicant$' 'wpa_supplicant bin'
c 'sbin/iw$'        'iw bin'
c 'hostapd$'        'hostapd bin'
c 'firmware/'  'firmware files'
c 'iwlwifi-.*ucode' 'iwlwifi ucode'
c 'net/wireless/'   'wireless modules'
c 'mac80211_hwsim'  'hwsim (QEMU wifi test)'
c 'init-premount/bboot-wifi$' 'our premount script'
c 'usr/sbin/bbootd$' 'bbootd intact'
c 'etc/bboot/extra-ca.pem' 'testenv CA intact'
c '^scripts/bboot$'  'bboot boot script'
