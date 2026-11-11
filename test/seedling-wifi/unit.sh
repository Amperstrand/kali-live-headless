#!/usr/bin/env bash
# unit.sh — fast, dependency-light tests for the seedling-wifi overlay.
# No QEMU, no container, no network. Run: klh-seedling-wifi.sh unit
set -u
here=$(cd "$(dirname "$0")/../../tools/seedling-wifi" && pwd)
repo=$(cd "$here/../.." && pwd)
pass=0
fail=0

ok() { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }

echo "unit: syntax"
BIN=$(mktemp -d)
trap 'rm -rf "$BIN"' EXIT
for f in "$here"/*.sh "$here"/hook-bboot-wifi "$here"/script-bboot-wifi \
	"$here"/script-bboot-wifi-report; do
	case "$f" in
	*.sh) bash -n "$f" 2>/dev/null && ok "bash -n $(basename "$f")" || bad "bash -n $(basename "$f")" ;;
	*) sh -n "$f" 2>/dev/null && ok "sh -n $(basename "$f")" || bad "sh -n $(basename "$f")" ;;
	esac
done

echo "unit: shellcheck (warning level)"
if command -v shellcheck >/dev/null 2>&1; then
	for f in "$here"/*.sh "$here"/hook-bboot-wifi "$here"/script-bboot-wifi \
		"$here"/script-bboot-wifi-report; do
		if shellcheck -S warning "$f" 2>/dev/null; then
			ok "shellcheck $(basename "$f")"
		else
			bad "shellcheck $(basename "$f")"
		fi
	done
else
	echo "  skip  shellcheck not installed (pre-commit will enforce)"
fi

echo "unit: regression guards (defects already found once)"
# inject must install the COMPLETE overlay surface — the report-install
# line was lost to a reset and only the fresh m1b chroot exposed it (the
# minbase chroot had been riding a stale manual copy)
for pat in script-bboot-wifi-report hook-bboot-wifi bbootd-wrapper \
	bbirth bannounce EXTRA_CA SSH_PUBKEY authorized_keys ssh-keygen; do
	grep -q "$pat" "$here/inject-wifi.sh" &&
		ok "inject installs/handles $pat" || bad "inject installs/handles $pat"
done
# 2026-11-05: MODULES=most does NOT include vfat — the ESP mount failed
# silently. The hook must name it.
grep -q 'fat vfat nls_cp437' "$here/hook-bboot-wifi" &&
	ok "hook includes vfat + nls codepages" ||
	bad "hook includes vfat + nls codepages"
# 2026-11-05: WPA2 data-path crypto missing -> kernel refused key install
grep -q 'ccm' "$here/hook-bboot-wifi" && grep -q 'aes_x86_64' "$here/hook-bboot-wifi" &&
	ok "hook includes WPA2 crypto modules" || bad "hook includes WPA2 crypto modules"
# 2026-11-05: hand-listed drivers missed rtw89_8852ae. The hook must add
# the whole drivers/net/wireless tree, not a list.
grep -q 'drivers/net/wireless' "$here/hook-bboot-wifi" &&
	! grep -qE '^\s*for m in iwlwifi iwlwifi_pci' "$here/hook-bboot-wifi" &&
	ok "hook adds the whole wireless tree (no hand list)" ||
	bad "hook adds the whole wireless tree (no hand list)"
# 2026-11-06: predictable interface names (wlp3s0) — radio detection must
# be sysfs-based (phy80211), never a wlan* glob.
grep -q 'phy80211' "$here/script-bboot-wifi" &&
	! grep -q "grep '\^wlan'" "$here/script-bboot-wifi" &&
	ok "radio detection is name-agnostic (phy80211)" ||
	bad "radio detection is name-agnostic (phy80211)"
# the DHCP fast path must use klibc ipconfig (same conf format as the
# normal path), not a bespoke udhcpc script. The ONE sanctioned udhcpc
# is the root-side association-survival unit added by 998a4cb (its
# ExecStart runs after switch_root, in the real root).
grep -q 'ipconfig -t' "$here/script-bboot-wifi" &&
	! grep 'udhcpc -i' "$here/script-bboot-wifi" | grep -qv ExecStart &&
	ok "fast path uses klibc ipconfig (root-side unit excepted)" || bad "fast path uses klibc ipconfig (root-side unit excepted)"
# fails open: every failure branch must continue to the wired path
grep -c 'staying wired' "$here/script-bboot-wifi" | grep -q '[4-9]' &&
	ok "every failure branch fails open (staying wired x4+)" ||
	bad "every failure branch fails open (staying wired x4+)"

echo "unit: fixture sanity"
fx=$repo/test/seedling-wifi/fixtures/wifi-test.conf
grep -q 'ssid=' "$fx" && grep -q 'psk=' "$fx" &&
	grep -q 'klh-test-ap' "$here/script-bboot-wifi" 2>/dev/null ||
	true # hostapd fixture SSID lives in the script's hwsim branch
grep -q 'ssid=' "$fx" && grep -q 'psk=' "$fx" && [ "$(wc -c < "$fx")" -gt 40 ] &&
	ok "wifi-test.conf is a sane wpa_supplicant config" ||
	bad "wifi-test.conf is a sane wpa_supplicant config"
# the fixture PSK must match what the hwsim AP broadcasts
fxpsk=$(sed -n 's/.*psk="\(.*\)".*/\1/p' "$fx")
grep -q "wpa_passphrase=$fxpsk" "$here/script-bboot-wifi" &&
	ok "hwsim AP passphrase matches the fixture" ||
	bad "hwsim AP passphrase matches the fixture"

echo "unit: no hardcoded credentials anywhere"
# Guard 1 (shape): production tools must never carry a literal PSK assignment.
# Matches psk="<literal>" (8+ chars, not a variable) — synthetic fixtures in
# test/ are excluded on purpose; tools/ has no legitimate literal PSKs.
LEAKS=$(grep -rnE 'psk="[^"$}{]{8,}"' "$repo/tools" 2>/dev/null | grep -v '.git' | wc -l)
[ "$LEAKS" -eq 0 ] && ok "no literal PSK assignments in tools/" || bad "literal PSK assignment in tools/ ($LEAKS occurrences)"
# Guard 2 (exact value): if the operator keeps a private needle file
# (~/.local/share/kali-live-headless/leak-needle, 0600, one value per line —
# NEVER committed), scan the whole tree for each value so a reintroduction of
# any known-exposed secret fails the suite. Absent needle file = skip-ok
# (synthetic CI environments have nothing to check against).
NEEDLE=~/.local/share/kali-live-headless/leak-needle
if [ -r "$NEEDLE" ]; then
	HITS=0
	while IFS= read -r v || [ -n "$v" ]; do
		[ -n "$v" ] || continue
		HITS=$((HITS + $(grep -rF -- "$v" "$here" "$repo/tools" "$repo/docs" 2>/dev/null | grep -v '.git' | wc -l)))
	done < "$NEEDLE"
	[ "$HITS" -eq 0 ] && ok "no known-exposed secret values present" || bad "known-exposed secret value found ($HITS occurrences)"
else
	echo "unit: leak-needle absent — exact-value scan skipped (ok)"
fi
# Guard 3: any psk= reference outside the provisioning tooling is suspect
SUSPECT=$(grep -rn 'psk=' "$repo/tools" 2>/dev/null | grep -v '.git' | grep -v 'write-wifi-conf' | grep -v 'wifi-creds' | grep -vE "psk=\"?\\$|psk=.*\\$\\{|psk=<|psk=\\?|psk=\"\\.\\.\\.\"|#[^!]*psk=" | wc -l || echo 0)
[ "$SUSPECT" -eq 0 ] && ok "no PSK handling outside the provisioning tool" || bad "PSK handling outside provisioning ($SUSPECT)"

echo "unit: render-cmdline"
T=$(mktemp -d)
export MANIFEST=aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111
export NPUB=npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
for v in qemu hwsim nowifi isolated fallback pointer; do
	if bash "$here/render-cmdline.sh" "$v" "$T/$v.txt" >/dev/null 2>&1; then
		case $v in
		pointer) grep -q "bb.manifest=" "$T/$v.txt" && bad "pointer variant must not pin a manifest" || ok "render pointer (relay-resolved)" ;;
		*) grep -q "bb.manifest=$MANIFEST" "$T/$v.txt" && ok "render $v" || bad "render $v" ;;
		esac
	else
		bad "render $v"
	fi
done
grep -q 'bb.wifi.hwsim=1' "$T/hwsim.txt" && ok "hwsim variant sets the test param" ||
	bad "hwsim variant sets the test param"
grep -q 'bb.nowifi=1' "$T/nowifi.txt" && ok "nowifi variant disables wifi" ||
	bad "nowifi variant disables wifi"
# the QEMU-family variants must carry the relay PORT (a portless URL once
# made bbootd dial :443 and every stage died with connection refused)
for v in qemu hwsim nowifi isolated fallback pointer; do
	grep -q ':8443' "$T/$v.txt" && ok "$v cmdline has relay port" || bad "$v cmdline has relay port"
done
! grep -q 'tty0' "$T/qemu.txt" && ok "qemu variant stays serial-only" ||
	bad "qemu variant stays serial-only"
MANIFEST=$(MANIFEST=$MANIFEST) bash -c 'true'
grep -q 'bb.servers=https://.*:9999,https://.*:8443' "$T/fallback.txt" && ok "fallback: dead server first, every entry schemed" || bad "fallback: dead server first, every entry schemed"
grep -q 'bb.relays=wss://.*:8443$' <(tr ' ' '\n' < "$T/fallback.txt" | grep '^bb.relays=') && ok "fallback: relay stays on the live server" || bad "fallback: relay stays on the live server"
RELAY_HOST=10.99.0.5 RELAY_PORT=9443 bash "$here/render-cmdline.sh" hw "$T/hw.txt" >/dev/null 2>&1
grep -q 'console=ttyS0,115200 console=tty0' "$T/hw.txt" &&
	grep -q 'https://10.99.0.5:9443' "$T/hw.txt" &&
	ok "hw variant: display console + relay substitution" ||
	bad "hw variant: display console + relay substitution"

echo "unit: write-wifi-conf escaping"
# the tool demands a real block device (correct behavior) — give it a loop
# partition from the stick image we just built, with mcopy shimmed to capture
if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null &&
	command -v losetup >/dev/null 2>&1 && [ -s "$BIN/stick.img" ]; then
	BIN2=$(mktemp -d)
	CAP="$BIN2/captured.conf"
	mkdir -p "$BIN2/shim"
	printf '#!/bin/sh\nfor a in "$@"; do case "$a" in /*) [ -f "$a" ] && cp "$a" %q && exit 0 ;; esac; done\n' "$CAP" > "$BIN2/shim/mcopy"
	chmod +x "$BIN2/shim/mcopy"
	LOOP=$(sudo -n losetup -f --show -o $((2048 * 512)) --sizelimit $((63 * 1024 * 1024)) "$BIN/stick.img" 2>/dev/null || true)
	if [ -n "${LOOP:-}" ]; then
		printf 'weird"ss\\id\npa$$w0rd"x8\n' |
			PATH="$BIN2/shim:$PATH" bash "$here/write-wifi-conf.sh" --wpa3 "$LOOP" >/dev/null 2>&1
		if [ -s "$CAP" ] && grep -q 'key_mgmt=SAE WPA-PSK' "$CAP" && grep -q 'ieee80211w=1' "$CAP"; then
			ok "write-wifi-conf --wpa3 emits SAE-mixed with PMF"
		elif [ -s "$CAP" ]; then
			bad "write-wifi-conf --wpa3 missing SAE/PMF lines"
		else
			bad "write-wifi-conf produced no file"
		fi
		sudo -n losetup -d "$LOOP"
	else
		echo "  skip  no free loop device"
	fi
	rm -rf "$BIN2"
else
	echo "  skip  write-wifi-conf needs sudo+losetup"
fi

echo "unit: write-wifi-conf stdin mode"
T2=$(mktemp -d)
printf 'ssidtwo\npassphrase8chars\n' > "$T2/in"
# shellcheck disable=SC2016
if command -v mcopy >/dev/null 2>&1; then
	# exercise the non-tty path through a shimmed block device check via bash -c
	printf '#!/bin/sh\nexit 0\n' > "$T2/stat-shim"
	# feed stdin; expect the tool to pass the -b check against a loop of the stick image
	if [ -s "$BIN/stick.img" ]; then
		L2=$(sudo -n losetup -f --show -o $((2048 * 512)) --sizelimit $((63 * 1024 * 1024)) "$BIN/stick.img" 2>/dev/null || true)
		if [ -n "${L2:-}" ]; then
			PATH="$T2/stat-shim:$PATH" bash "$here/write-wifi-conf.sh" "$L2" < "$T2/in" >/dev/null 2>&1
			sudo -n mcopy -i "$L2" ::/wifi.conf "$T2/out" 2>/dev/null
			if grep -q 'ssid="ssidtwo"' "$T2/out" 2>/dev/null && grep -q 'passphrase8chars' "$T2/out" 2>/dev/null; then
				ok "write-wifi-conf stdin mode writes the same config shape"
			else
				bad "write-wifi-conf stdin mode writes the same config shape"
			fi
			sudo -n losetup -d "$L2"
		else
			echo "  skip  no loop device for the stdin-mode test"
		fi
	fi
	rm -rf "$T2"
fi

echo "unit: stick image layout"
command -v sgdisk >/dev/null 2>&1 && command -v mdir >/dev/null 2>&1 || {
	echo "  skip  sgdisk/mtools not installed"
}
if command -v sgdisk >/dev/null 2>&1 && command -v mdir >/dev/null 2>&1; then
	head -c 65536 /dev/urandom > "$BIN/fake.efi"
	bash "$here/make-wifi-stick.sh" "$BIN/fake.efi" "$fx" "$BIN/stick.img" 64 >/dev/null 2>&1 &&
		ok "make-wifi-stick builds" || bad "make-wifi-stick builds"
	sgdisk -i 1 "$BIN/stick.img" 2>/dev/null | grep -q 'C12A7328-F81F-11D2-BA4B-00A0C93EC93B' &&
		ok "stick: partition type EFI system" || bad "stick: partition type EFI system"
	dd if="$BIN/stick.img" of="$BIN/esp.img" bs=512 skip=2048 status=none
	mdir -i "$BIN/esp.img" ::/ 2>/dev/null | grep -q 'is BBOOT' &&
		ok "stick: ESP labeled BBOOT" || bad "stick: ESP labeled BBOOT"
	mdir -i "$BIN/esp.img" ::/ 2>/dev/null | grep -q 'EFI' &&
		ok "stick: EFI directory present" || bad "stick: EFI directory present"
	mcopy -i "$BIN/esp.img" ::/wifi.conf "$BIN/readback.conf" 2>/dev/null
	cmp -s "$BIN/readback.conf" "$fx" &&
		ok "stick: wifi.conf round-trips byte-identical" ||
		bad "stick: wifi.conf round-trips byte-identical"
fi

echo
echo "RESULT: unit pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
