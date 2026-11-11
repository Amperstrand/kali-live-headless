#!/usr/bin/env bash
# rescue-smoke.sh — daemon-free VM proofs for the two-stick rescue design.
#
#   rescue-smoke.sh banner|fallback|bootnext|offline|soak
#
# The OFFLINE rescue (stick-rescue-local.img, boot=klhrescue static
# rootfs) is the rescue of record — fallback/bootnext/soak exercise the
# production pair. `banner` is the one knob-level proof of the older
# pinned-manifest network variant (bb.rescue=1, wrapper banner), kept
# because the knob still ships on normal sticks.
#
# Every boot runs with -nic none: no unlocker, no relay, no bunlock race —
# these proofs coexist with a standing lab daemon (unlike the full e2e).
# Asserts are on serial evidence lines, never bare counts.
#
#   banner    boot the rescue stick alone: RESCUE MEDIUM banner + pinned-
#             manifest fetch attempts + clean no-network failure (BusyBox
#             shell). Proves the rescue medium is independently bootable
#             and fails cleanly when its dependency (the network) is gone.
#   fallback  healthy-rescue + primary whose UKI is destroyed: OVMF must
#             reject the dead loader and boot the rescue stick unattended.
#   bootnext  three boots with persistent vars: enumerate, BootNext surgery
#             -> rescue boots OUT OF ORDER (one-shot override), BootNext
#             consumed by firmware -> BootOrder default (primary) returns.
#
# Prerequisites: built sticks in $SEEDLING_DIR/e2e (build-uki/build-stick
# --variant rescue and qemu), OVMF 4m firmware, KVM, sgdisk+mtools for the
# broken-stick construction, virt-fw-vars for the surgery.
set -u
here=$(cd "$(dirname "$0")" && pwd)
SEEDLING_DIR=${SEEDLING_DIR:-$HOME/src/seedling-m1}
OVMF_CODE=/usr/share/edk2/x64/OVMF_CODE.4m.fd
OVMF_VARS=/usr/share/edk2/x64/OVMF_VARS.4m.fd
WORK=$(mktemp -d /tmp/opencode/rescue-smoke.XXXXXX)
KEEPLOGS=/tmp/opencode/rescue-smoke-last
mkdir -p "$KEEPLOGS"
# evidence survives failures: serial logs copy out before the EXIT trap
# cleans the scratch dir (learned twice the hard way tonight)
trap 'cp -f "$WORK"/*.log "$KEEPLOGS"/ 2>/dev/null; rm -rf "$WORK"' EXIT
pass=0; fail=0
ok() { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }
say() { echo "smoke: $*"; }

RESUE_STICK="$SEEDLING_DIR/e2e/stick-rescue.img"
# the OFFLINE rescue (boot=klhrescue static rootfs) — the rescue of
# record; fallback/bootnext/soak exercise the production pair
OFFLINE_STICK="$SEEDLING_DIR/e2e/stick-rescue-local.img"
PRIMARY_STICK="$SEEDLING_DIR/e2e/stick-qemu.img"

# boot_until SERIAL SENTINEL TIMEOUT_S [EXTRA_DRIVE] — PRESERVE=1 keeps the
# vars file across calls (needed for multi-boot tests: enumeration and
# BootNext surgery live in the varstore). NET=1 attaches the QEMU user
# NIC (the stall fixture needs 10.0.2.2; every other mode stays -nic
# none). Kills QEMU once SENTINEL appears or the timeout expires
# (timeout+30 hard ceiling).
boot_until() {
	local serial=$1 sentinel=$2 tmo=$3 extra=${4:-}
	rm -f "$serial"
	if [ "${PRESERVE:-0}" != 1 ]; then
		rm -f "$WORK/vars.fd"
		cp "$OVMF_VARS" "$WORK/vars.fd"
	fi
	# shellcheck disable=SC2086 # extra is a full -drive option when set
	timeout $((tmo + 30)) qemu-system-x86_64 \
		-m 2048 -smp 2 -enable-kvm -nic none \
		-device virtio-rng-pci \
		${NET:+-netdev user,id=n1 -device virtio-net-pci,netdev=n1} \
		-drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
		-drive if=pflash,format=raw,file="$WORK/vars.fd" \
		-drive file="$BOOT_IMG",format=raw,if=virtio \
		${extra:+-drive file="$extra",format=raw,if=virtio} \
		-display none -serial file:"$serial" >/dev/null 2>&1 &
	local qpid=$! waited=0
	while [ $waited -lt "$tmo" ]; do
		grep -aq "$sentinel" "$serial" 2>/dev/null && break
		kill -0 $qpid 2>/dev/null || break
		sleep 10; waited=$((waited + 10))
	done
	kill $qpid 2>/dev/null; wait $qpid 2>/dev/null
	[ "$waited" -lt "$tmo" ]
}

need_stick() {
	[ -s "$1" ] || { say "missing $1 — build it first:"; say "  klh-seedling-wifi.sh build-uki --variant ${2} && klh-seedling-wifi.sh build-stick --variant ${2}"; exit 2; }
}

make_broken_primary() {
	local out=$1
	cp "$PRIMARY_STICK" "$out"
	local ss=2048 cnt
	cnt=$(sgdisk -i 1 "$out" | awk '/Last sector/{print $3}')
	cnt=$((cnt - ss + 1))
	dd if="$out" of="$WORK/esp.img" bs=512 skip=$ss count=$cnt status=none
	printf 'NOT-A-PE-IMAGE — rescue-smoke loader payload\n' > "$WORK/bad.efi"
	mcopy -o -i "$WORK/esp.img" "$WORK/bad.efi" ::/EFI/BOOT/BOOTX64.EFI
	dd if="$WORK/esp.img" of="$out" bs=512 seek=$ss conv=notrunc status=none
}

case ${1:-usage} in
banner)
	need_stick "$RESUE_STICK" rescue
	BOOT_IMG="$RESUE_STICK"
	say "banner: booting rescue stick alone, no network (run to terminal state)"
	# wait for the BusyBox shell (the terminal state), not the banner —
	# the failure evidence comes ~4 min after the banner
	if boot_until "$WORK/s.log" '(initramfs)' 480; then
		ok "boot reached its terminal state (BusyBox initramfs shell, no hang)"
	else
		bad "no BusyBox terminal within 480s — boot stalled?"; tail -5 "$WORK/s.log" 2>/dev/null | sed 's/^/    /'
	fi
	if grep -aq 'RESCUE MEDIUM' "$WORK/s.log"; then
		grep -a 'RESCUE MEDIUM' "$WORK/s.log" | head -1 | sed 's/^/    /'
		ok "rescue banner on serial"
	else
		bad "no RESCUE MEDIUM banner"
	fi
	if grep -aq 'bboot: FAILED: manifest' "$WORK/s.log"; then
		grep -a 'bboot: FAILED: manifest' "$WORK/s.log" | head -1 | sed 's|https://[^ "]*|URL|; s/^/    /'
		ok "pinned-manifest fetch fails cleanly (no network)"
	else
		bad "no clean manifest failure (stalled?)"
	fi
	;;

fallback)
	need_stick "$SEEDLING_DIR/e2e/stick-rescue-local.img" rescue-local
	need_stick "$PRIMARY_STICK" qemu
	make_broken_primary "$WORK/broken.img"
	BOOT_IMG="$WORK/broken.img"
	say "fallback: dead primary UKI + offline rescue stick, no network"
	# NOTE: with a fresh varstore the enumeration order of the two media
	# is NOT deterministic (observed 2026-11-11: primary-first in one run,
	# rescue-first in another). The order-independent property is what we
	# assert: the rescue booted, the primary did not. The explicit
	# fail-through (BdsDxe rejection) is asserted informationally when
	# enumeration happens to put the dead primary first.
	if boot_until "$WORK/s.log" 'klh-rescue: LOCAL ROOTFS' 240 "$SEEDLING_DIR/e2e/stick-rescue-local.img"; then
		ok "offline rescue booted unattended"
	else
		bad "no rescue banner — neither medium produced a boot"; tail -5 "$WORK/s.log" 2>/dev/null | sed 's/^/    /'
	fi
	if grep -aq 'NO RADIO APPEARED' "$WORK/s.log"; then
		bad "primary identity on serial — the dead primary must never boot"
	else
		ok "primary never booted (its radio-probe line is absent)"
	fi
	if grep -aq 'BdsDxe: failed to load' "$WORK/s.log"; then
		grep -a 'BdsDxe: failed to load' "$WORK/s.log" | head -1 | cut -c1-110 | sed 's/^/    /'
		ok "firmware explicitly rejected the dead primary (BdsDxe evidence)"
	else
		echo "  info  no BdsDxe failure line (rescue enumerated first — order is nondeterministic on fresh vars)"
	fi
	;;

bootnext)
	need_stick "$OFFLINE_STICK" rescue-local
	need_stick "$PRIMARY_STICK" qemu
	for t in sgdisk mcopy virt-fw-vars python3; do
		command -v $t >/dev/null || { say "need $t"; exit 2; }
	done
	EFI_GLOBAL=8be4df61-93ca-11d2-aa0d-00e098032b8c

	say "bootnext: boot 1 — enumerate (kill at first BdsDxe start)"
	BOOT_IMG="$PRIMARY_STICK"
	if boot_until "$WORK/s1.log" 'BdsDxe: starting' 120 "$OFFLINE_STICK"; then
		ok "firmware enumerated the two sticks"
	else
		bad "no BdsDxe start within 120s"; exit 1
	fi
	# find the rescue's Boot####: the entry OVMF did NOT start in boot 1
	# (it started the primary). Dump vars, locate both media entries.
	virt-fw-vars -i "$WORK/vars.fd" --output-json "$WORK/vars.json" 2>/dev/null
	read -r PRIMARY_ENTRY RESCUE_ENTRY < <(python3 - "$WORK/vars.json" << 'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
media, bo = [], []
for v in d['variables']:
    if not v['name'].startswith('Boot'):
        continue
    if v['name'] == 'BootOrder':
        raw = bytes.fromhex(v['data'])
        bo = [raw[i] | (raw[i+1] << 8) for i in range(0, len(raw), 2)]
    elif v['name'][4:].isdigit():
        data = bytes.fromhex(v['data'])
        # bytes 4.. = UCS-16 description; OVMF calls removable media
        # "UEFI Misc Device N" — BootManager/Shell are named differently
        try:
            desc = data[4:64].decode('utf-16-le', errors='ignore')
        except Exception:
            desc = ''
        if 'Misc' in desc:
            media.append(v['name'][4:])
ordered = [f"{n:04X}" for n in bo if f"{n:04X}" in media]
print(ordered[0] if ordered else '0000', ordered[1] if len(ordered) > 1 else '0000')
PYEOF
)
	say "bootnext: primary=Boot$PRIMARY_ENTRY rescue=Boot$RESCUE_ENTRY"
	[ "$RESCUE_ENTRY" != "0000" ] || { bad "could not identify rescue Boot entry"; exit 1; }

	say "bootnext: surgery — set BootNext=$RESCUE_ENTRY (rescue)"
	python3 - "$WORK/vars.json" "$RESCUE_ENTRY" "$EFI_GLOBAL" > "$WORK/next.json" << 'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
for v in d['variables']:
    v['attr'] = int(v['attr'])
entry = format(int(sys.argv[2], 16), '04x')
d['variables'].append({'name': 'BootNext', 'guid': sys.argv[3], 'attr': 7,
                       'data': entry[2:4] + entry[0:2]})
json.dump(d, sys.stdout)
PYEOF
	virt-fw-vars -i "$WORK/vars.fd" --set-json "$WORK/next.json" -o "$WORK/vars-next.fd" >/dev/null 2>&1
	cp "$WORK/vars-next.fd" "$WORK/vars.fd"

	say "bootnext: boot 2 — one-shot override must boot the RESCUE"
	BOOT_IMG="$PRIMARY_STICK"
	PRESERVE=1
	if boot_until "$WORK/s2.log" 'klh-rescue: LOCAL ROOTFS' 420 "$OFFLINE_STICK"; then
		ok "BootNext override: rescue booted out of BootOrder"
	else
		PRESERVE=0
		bad "boot 2 did not reach the rescue banner"; exit 1
	fi

	say "bootnext: boot 3 — BootNext must be consumed (BootOrder default returns)"
	BOOT_IMG="$PRIMARY_STICK"
	if boot_until "$WORK/s3.log" 'NO RADIO APPEARED' 420 "$OFFLINE_STICK"; then
		ok "primary booted again (its radio-probe evidence on serial)"
	else
		PRESERVE=0
		bad "boot 3 did not show primary identity"; exit 1
	fi
	PRESERVE=0
	if ! grep -aq 'klh-rescue: LOCAL ROOTFS' "$WORK/s3.log"; then
		ok "one-shot confirmed: no rescue banner on the post-consumption boot"
	else
		bad "rescue banner on boot 3 — BootNext was NOT consumed"
	fi
	;;

soak)
	# Power-cut soak (recovery report §4, labgrid exercise in miniature):
	# N cycles of kill-QEMU-at-a-random-moment against persistent vars,
	# dead primary + rescue. Property: repeated interruption never wedges
	# the machine — a subsequent full boot still converges to rescue.
	need_stick "$OFFLINE_STICK" rescue-local
	need_stick "$PRIMARY_STICK" qemu
	make_broken_primary "$WORK/broken.img"
	BOOT_IMG="$WORK/broken.img"
	CYCLES=${CYCLES:-5}
	say "soak: $CYCLES random-kill cycles, then one convergence boot"
	cut_seen=0
	i=1
	while [ $i -le "$CYCLES" ]; do
		# cycle 1 is the machine's FIRST boot (fresh vars = provision);
		# the cuts then hit an already-enumerated machine. PRESERVE=1 on
		# a fresh WORK dir would hand QEMU a nonexistent vars file and
		# every cycle would die instantly (found via the empty counters)
		if [ $i -eq 1 ]; then PRESERVE=0; else PRESERVE=1; fi
		t=$((RANDOM % 90 + 10))
		boot_until "$WORK/soak-$i.log" '__SENTINEL_NEVER_MATCHES__' "$t" "$OFFLINE_STICK" || true
		kill_line=$(grep -acE 'BdsDxe: starting' "$WORK/soak-$i.log" 2>/dev/null || true)
		[ "$kill_line" -gt 0 ] && cut_seen=$((cut_seen + 1))
		say "soak: cycle $i/$CYCLES cut at ~${t}s (firmware had started: $kill_line)"
		i=$((i + 1))
	done
	# convergence boot uses the INTERRUPTED vars — that is the power-cut
	# scenario: the machine reboots on whatever state the cuts left behind
	if boot_until "$WORK/soak-final.log" 'klh-rescue: LOCAL ROOTFS' 480 "$OFFLINE_STICK"; then
		grep -a 'klh-rescue: LOCAL ROOTFS' "$WORK/soak-final.log" | head -1 | sed 's/^/    /'
		ok "convergence: full boot after $CYCLES interruptions reaches rescue"
	else
		bad "no convergence — machine wedged after interruption cycles"
		tail -5 "$WORK/soak-final.log" 2>/dev/null | sed 's/^/    /'
	fi
	if [ "$cut_seen" -eq "$CYCLES" ]; then
		ok "every cut landed mid-boot (firmware started in all $CYCLES cycles)"
	else
		bad "only $cut_seen/$CYCLES cycles reached firmware start (cuts too early?)"
	fi
	;;

offline)
	# rescue-v2: the offline rescue boots to LOGIN with no network, no
	# relay, no unlock — the static rootfs on the stick is the whole OS.
	# (the wait sentinel IS 'login:' — earlier revisions waited for the
	# banner, killed QEMU mid-boot, then wondered why login never
	# appeared. Evidence first, kills second.)
	LOCAL_STICK="$SEEDLING_DIR/e2e/stick-rescue-local.img"
	need_stick "$LOCAL_STICK" rescue-local
	BOOT_IMG="$LOCAL_STICK"
	say "offline: booting the static-rootfs rescue stick, no network at all"
	if boot_until "$WORK/s.log" 'login:' 420; then
		grep -a 'login:' "$WORK/s.log" | head -1 | sed 's/^/    /'
		ok "OFFLINE LOGIN REACHED — no network, no unlock, no bboot"
	else
		bad "no login prompt — the recovery OS did not boot"
		tail -5 "$WORK/s.log" 2>/dev/null | sed 's/^/    /'
	fi
	if grep -aq 'klh-rescue: LOCAL ROOTFS' "$WORK/s.log"; then
		grep -a 'klh-rescue: LOCAL ROOTFS' "$WORK/s.log" | head -1 | sed 's/^/    /'
		ok "offline rescue banner on serial"
	else
		bad "no klh-rescue banner"
	fi
	if grep -aq 'klh-rescue: root mounted' "$WORK/s.log"; then
		ok "static erofs + overlay mounted (loop from the stick's ESP)"
	else
		bad "root never mounted — loop/erofs failed?"
	fi
	if grep -aqE 'nostrconnect|bboot: manifest|Waiting up to .* network device' "$WORK/s.log"; then
		bad "network/unlock machinery ran on the offline image (leakage into the rescue path)"
	else
		ok "zero network/unlock activity (no manifest fetch, no URI, no NIC wait)"
	fi
	;;

stall)
	# watchdog-hang proof: boot behind the stall-proxy — the manifest
	# arrives, the first chunk freezes mid-body, bbootd hangs without
	# writing ready/failed, and the watchdog must FIRE (reboot -f) and
	# the machine must begin a fresh boot. Proxy lifecycle is ours.
	need_stick "$SEEDLING_DIR/e2e/stick-stall.img" stall
	command -v python3 >/dev/null || { say "stall: need python3"; exit 2; }
	PROXY_LOG="$WORK/stall-proxy.log"
	python3 "$here/stall-proxy.py" 8453 16384 > "$PROXY_LOG" 2>&1 &
	local_proxy_pid=$!
	say "stall: proxy up (pid $local_proxy_pid), booting with the network"
	NET=1
	BOOT_IMG="$SEEDLING_DIR/e2e/stick-stall.img"
	# run a fixed window and let the machine LIVE through the reboot —
	# killing at the first expiry (boot_until's job) beheads the second
	# cycle before it can re-arm (found the hard way, 3/1)
	rm -f "$WORK/vars.fd"
	cp "$OVMF_VARS" "$WORK/vars.fd"
	# shellcheck disable=SC2086
	timeout 330 qemu-system-x86_64 \
		-m 2048 -smp 2 -enable-kvm \
		-device virtio-rng-pci \
		-netdev user,id=n1 -device virtio-net-pci,netdev=n1 \
		-drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
		-drive if=pflash,format=raw,file="$WORK/vars.fd" \
		-drive file="$BOOT_IMG",format=raw,if=virtio \
		-display none -serial file:"$WORK/s.log" >/dev/null 2>&1 &
	qpid=$! waited=0
	while [ $waited -lt 300 ]; do
		armed=$(grep -ac 'watchdog armed' "$WORK/s.log" 2>/dev/null || true)
		[ "${armed:-0}" -ge 2 ] && break
		kill -0 $qpid 2>/dev/null || break
		sleep 10; waited=$((waited + 10))
	done
	kill $qpid 2>/dev/null; wait $qpid 2>/dev/null
	NET=
	if grep -aq 'watchdog expired after 60s' "$WORK/s.log"; then
		grep -a 'watchdog expired' "$WORK/s.log" | head -1 | sed 's/^/    /'
		ok "watchdog FIRED on a hung boot (mid-chunk stall)"
	else
		kill "$local_proxy_pid" 2>/dev/null
		bad "watchdog never fired — the hung boot stayed hung"
		tail -6 "$WORK/s.log" 2>/dev/null | sed 's/^/    /'
	fi
	if grep -aq 'watchdog armed (60s)' "$WORK/s.log"; then
		ok "watchdog armed at boot (serial evidence)"
	else
		bad "no 'watchdog armed' line — wrapper did not run the watchdog block"
	fi
	armed=$(grep -ac 'watchdog armed' "$WORK/s.log" 2>/dev/null || true)
	if [ "${armed:-0}" -ge 2 ]; then
		ok "machine rebooted and re-armed ($armed armed-lines = fresh boot cycles)"
	else
		bad "no second boot cycle after the expiry ($armed armed-line)"
	fi
	if grep -aq 'bboot: FAILED' "$WORK/s.log"; then
		bad "bbootd clean-failed instead of hanging (fixture defeated by a deadline)"
	else
		ok "bbootd never wrote FAILED — a true hang, exactly the watchdog's case"
	fi
	grep -a 'FREEZING' "$PROXY_LOG" 2>/dev/null | head -1 | sed 's/^/    proxy: /'
	kill "$local_proxy_pid" 2>/dev/null
	;;

*) sed -n '2,12p' "$0"; exit 1 ;;
esac
echo "RESULT: rescue-smoke $1 pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
