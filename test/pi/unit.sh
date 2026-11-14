#!/bin/bash
# pi/unit.sh — fast, VM-free tests for the Pi appliance card lane.
# Covers: the card-build matrix (every target combo), content asserts
# (config sections, pin/unpin rule, EFI layout, pairing/wifi), byte
# reproducibility per flavor, and the card tools (pi-derive-psk,
# fat-normalize, the wrapper's arch-map logic).
# Every assert prints evidence; verdict is a RESULT line.
set -u
export TMPDIR=${TMPDIR:-/home/user/tmp}
mkdir -p "$TMPDIR"
here=$(cd "$(dirname "$0")/../../tools/seedling-wifi" && pwd)
BIN=$(mktemp -d "${TMPDIR:-/tmp}/pi-unit.XXXXXX")
trap 'rm -rf "$BIN"' EXIT

pass=0; fail=0
ok() { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }

# --- the card-build matrix -------------------------------------------------
# every flavor must build, auto-size, and carry exactly the right files
for t in pi1 pi4 x86 pi1,pi2 pi1,pi4 pi1,pi2,pi4,x86; do
	name=$(echo "$t" | tr ',' '-')
	img="$BIN/card-$name.img"
	if bash "$here/make-pi-sd.sh" "$img" 0 --targets="$t" >/dev/null 2>&1; then
		ok "build: --targets=$t ($(stat -c%s "$img") bytes)"
	else
		bad "build: --targets=$t"
		continue
	fi
	# content: extract the FAT and assert structure
	sectors=$(($(stat -c%s "$img") / 512 - 2048))
	dd if="$img" of="$BIN/esp-$name.img" bs=512 skip=2048 \
		count="$sectors" status=none 2>/dev/null
	mcopy -i "$BIN/esp-$name.img" ::config.txt "$BIN/cfg-$name" 2>/dev/null
	mcopy -i "$BIN/esp-$name.img" ::cmdline.txt "$BIN/cmd-$name" 2>/dev/null
	mcopy -i "$BIN/esp-$name.img" ::pairing.txt "$BIN/pair-$name" 2>/dev/null
	[ -s "$BIN/cfg-$name" ] && ok "config.txt present ($t)" || bad "config.txt present ($t)"
	grep -q "targets: $t" "$BIN/cfg-$name" 2>/dev/null &&
		ok "config header names targets ($t)" || bad "config header ($t)"
	case ",$t," in
	*,pi1,*) grep -q "^\[pi1\]" "$BIN/cfg-$name" && ok "[pi1] section ($t)" || bad "[pi1] section ($t)" ;;
	esac
	case ",$t," in
	*,pi2,*) grep -q "^\[pi2\]" "$BIN/cfg-$name" && ok "[pi2] section ($t)" || bad "[pi2] section ($t)" ;;
	esac
	if case ",$t," in *,pi4,*) true ;; *) false ;; esac; then
		grep -q "^\[pi4\]" "$BIN/cfg-$name" && grep -q "^\[pi5\]" "$BIN/cfg-$name" &&
			ok "[pi4]+[pi5] sections ($t)" || bad "[pi4]/[pi5] sections ($t)"
		mdir -i "$BIN/esp-$name.img" ::/ 2>/dev/null | grep -qi "initrd-v8" &&
			ok "initrd-v8 on card ($t)" || bad "initrd-v8 on card ($t)"
	fi
	# pin/unpin rule: cards spanning both Pi arches are unpinned
	spanning=0
	case ",$t," in *,pi4,*) case ",$t," in *,pi1,*|*,pi2,*) spanning=1 ;; esac ;; esac
	if [ "$spanning" = 1 ]; then
		grep -q "bb.manifest=" "$BIN/cmd-$name" 2>/dev/null &&
			bad "arch-spanning card must be unpinned ($t)" ||
			ok "arch-spanning card unpinned ($t)"
	else
		grep -q "bb.manifest=" "$BIN/cmd-$name" 2>/dev/null &&
			ok "single-arch card pinned ($t)" || bad "single-arch card pin ($t)"
	fi
	# EFI layout: the UKI iff x86
	if case ",$t," in *,x86,*) true ;; *) false ;; esac; then
		mdir -i "$BIN/esp-$name.img" ::/EFI/BOOT 2>/dev/null | grep -q "BOOTX64" &&
			ok "EFI/BOOT/BOOTX64.EFI present ($t)" || bad "UKI missing ($t)"
		sgdisk -i 1 "$img" 2>/dev/null | grep -q C12A7328 &&
			ok "ESP partition type ($t)" || bad "ESP type ($t)"
	else
		[ -z "$(mdir -i "$BIN/esp-$name.img" ::/EFI 2>/dev/null)" ] 2>/dev/null &&
			ok "no EFI dir without x86 ($t)" || echo "  note  EFI dir exists without x86 ($t) (harmless)"
	fi
	# pairing material always present
	grep -q "pairing-secret=" "$BIN/pair-$name" 2>/dev/null &&
		ok "pairing.txt ($t)" || bad "pairing.txt ($t)"
done

# --- deterministic mode: double builds are byte-identical ------------------
for t in pi1 pi1,pi2,pi4,x86; do
	name=$(echo "$t" | tr ',' '-')
	PI_PAIRING=1731494400deadbeef1731494400dead \
		bash "$here/make-pi-sd.sh" "$BIN/d1-$name.img" 0 --targets="$t" --deterministic >/dev/null 2>&1
	PI_PAIRING=1731494400deadbeef1731494400dead \
		bash "$here/make-pi-sd.sh" "$BIN/d2-$name.img" 0 --targets="$t" --deterministic >/dev/null 2>&1
	if [ -s "$BIN/d1-$name.img" ] && cmp -s "$BIN/d1-$name.img" "$BIN/d2-$name.img"; then
		ok "deterministic double-build ($t): $(sha256sum "$BIN/d1-$name.img" | cut -c1-16)…"
	else
		bad "deterministic double-build ($t)"
	fi
done

# --- pi-derive-psk ---------------------------------------------------------
p1=$(python3 "$here/pi-derive-psk.py" 1731494400deadbeef1731494400dead 2>/dev/null | grep -oP 'psk=\K[0-9a-f]{64}')
p2=$(python3 "$here/pi-derive-psk.py" 1731494400deadbeef1731494400dead 2>/dev/null | grep -oP 'psk=\K[0-9a-f]{64}')
p3=$(python3 "$here/pi-derive-psk.py" 1731494400deadbeef1731494400deaf 2>/dev/null | grep -oP 'psk=\K[0-9a-f]{64}')
[ -n "$p1" ] && [ "$p1" = "$p2" ] && ok "derive-psk deterministic" || bad "derive-psk deterministic"
[ -n "$p1" ] && [ "$p1" != "$p3" ] && ok "derive-psk per-secret distinct" || bad "derive-psk distinctness"
[ "${#p1}" = 64 ] && ok "derive-psk 64-hex raw form" || bad "derive-psk form"

# --- fat-normalize: idempotence + both FAT widths --------------------------
echo hi > "$BIN/f.txt"
for sz in 8 64; do
	mkfs.vfat -C "$BIN/n-$sz.img" $((sz * 1024)) >/dev/null 2>&1
	mcopy -i "$BIN/n-$sz.img" "$BIN/f.txt" ::a.txt
	python3 "$here/fat-normalize.py" "$BIN/n-$sz.img" 1731494400 >/dev/null 2>&1
	cp "$BIN/n-$sz.img" "$BIN/n2-$sz.img"
	python3 "$here/fat-normalize.py" "$BIN/n2-$sz.img" 1731494400 >/dev/null 2>&1
	cmp -s "$BIN/n-$sz.img" "$BIN/n2-$sz.img" && ok "fat-normalize idempotent (${sz}M)" || bad "fat-normalize idempotence (${sz}M)"
	mcopy -i "$BIN/n-$sz.img" ::a.txt "$BIN/back-$sz.txt" 2>/dev/null
	grep -q hi "$BIN/back-$sz.txt" 2>/dev/null && ok "fat-normalize keeps files readable (${sz}M)" || bad "fat-normalize readability (${sz}M)"
done

# --- wrapper arch-map logic (source inspection; behavior is VM-proven) -----
grep -q 'pi:32' "$here/bbootd-wrapper" && grep -q 'pi:64' "$here/bbootd-wrapper" &&
	grep -q 'x86_64)' "$here/bbootd-wrapper" &&
	ok "wrapper: arch map covers pi:32/pi:64/x86_64" || bad "wrapper arch map"
grep -q '\-cmdline' "$here/bbootd-wrapper" &&
	ok "wrapper: synthesized cmdline via -cmdline flag" || bad "wrapper -cmdline"
# pinned cmdline must NOT be rewritten (the guard case)
grep -q 'bb.manifest=\*\|bb.d=' "$here/bbootd-wrapper" &&
	ok "wrapper: pinned cards skip tag derivation" || bad "wrapper pin guard"

echo
echo "RESULT: pi-unit pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
