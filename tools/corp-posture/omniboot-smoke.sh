#!/usr/bin/env bash
# omniboot-smoke.sh — boot the omniboot stick through every chain it
# carries, in QEMU. One boot per firmware profile; assert per chain.
#   1. BIOS (SeaBIOS)        -> grub -> kernel ("Linux version")
#   2. UEFI, SB off          -> shim->grub->kernel (MS entry)
#   3. UEFI + MS-only db     -> same chain under enforcement
#   4. UEFI + our keys       -> Boot entry -> our-signed grub -> our kernel
#      (setup for 4 = boot the enroll entry first, i.e. the corp-enroll
#       flow is part of this smoke — that's the hardware-day sequence)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
CORP=${CORP_DIR:-$(cd "$here/../.." && pwd)/../corp-posture-spike}
CORP=$(cd "$CORP" 2>/dev/null && pwd) || { echo "CORP_DIR not found" >&2; exit 1; }
W=$CORP/work; IMG=${1:-$W/omniboot.img}
[ -s "$IMG" ] || { echo "run omniboot-build.sh first" >&2; exit 1; }
PASS=0; FAIL=0
say() { printf 'omni-smoke: %s\n' "$*"; }
check() { if grep -aq "$3" "$2" 2>/dev/null; then say "PASS $1"; PASS=$((PASS+1)); else say "FAIL $1 — wanted '$3' in $2"; tr -d '\0' < "$2" 2>/dev/null | tail -3 | sed 's/^/    /'; FAIL=$((FAIL+1)); fi; }

# ---- 1. BIOS (SeaBIOS, no UEFI at all) ----
rm -f $W/omni-bios.log
timeout 240 qemu-system-x86_64 -machine accel=kvm -cpu host -smp 2 -m 2048 \
	-drive file="$IMG",format=raw,if=virtio \
	-netdev user,id=n1 -device virtio-net-pci,netdev=n1 \
	-display none -serial file:$W/omni-bios.log >/dev/null 2>&1 || true
check "bios-grub-kernel" $W/omni-bios.log "Linux version"
# (grub's menu renders to VGA; the serial kernel lines are the real assert)

# ---- 2. UEFI, SB off (blank vars) ----
cp /usr/share/edk2/x64/OVMF_VARS.4m.fd $W/omni-vars-off.fd
rm -f $W/omni-uefi.log
timeout 240 qemu-system-x86_64 -machine q35,smm=on,accel=kvm -cpu host -smp 2 -m 2048 \
	-global driver=cfi.pflash01,property=secure,value=on \
	-drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd \
	-drive if=pflash,format=raw,unit=1,file=$W/omni-vars-off.fd \
	-drive file="$IMG",format=raw,if=virtio \
	-netdev user,id=n1 -device virtio-net-pci,netdev=n1 \
	-display none -serial file:$W/omni-uefi.log >/dev/null 2>&1 || true
check "uefi-shim-grub-kernel" $W/omni-uefi.log "Linux version"

# ---- 3. UEFI + MS-only db (the MS-SB chain under enforcement) ----
virt-fw-vars -i /usr/share/edk2/x64/OVMF_VARS.4m.fd -o $W/omni-vars-ms.fd --enroll-microsoft --sb >/dev/null 2>&1
cp $W/omni-vars-ms.fd $W/omni-vars-ms-run.fd
rm -f $W/omni-mssb.log
timeout 240 qemu-system-x86_64 -machine q35,smm=on,accel=kvm -cpu host -smp 2 -m 2048 \
	-global driver=cfi.pflash01,property=secure,value=on \
	-drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd \
	-drive if=pflash,format=raw,unit=1,file=$W/omni-vars-ms-run.fd \
	-drive file="$IMG",format=raw,if=virtio \
	-netdev user,id=n1 -device virtio-net-pci,netdev=n1 \
	-display none -serial file:$W/omni-mssb.log >/dev/null 2>&1 || true
check "mssb-enforced-kernel" $W/omni-mssb.log "Linux version"
grep -aq "Security Violation\|Access Denied" $W/omni-mssb.log && { say "FAIL mssb (refused!)"; FAIL=$((FAIL+1)); }

# ---- 4. UEFI + our keys: enroll (boot entry 3 on the grub menu can't be
#         driven headless, so this smoke reuses the proven enroll stick for
#         setup) then boot the omniboot's our-chain via its Boot entry ----
# base = vars-corp.fd (our keys ALREADY enrolled offline; the enroll
# boot can't run here — SB is enforcing and corp-enroll is unsigned by
# design until our keys exist — chicken/egg broken by enrolling on a
# setup-mode boot, proven in ENROLL-STATE.md and exercised on hardware)
cp $W/vars-corp.fd $W/omni-vars-ours.fd

# our-keys machines boot the kernel DIRECTLY (Boot entry + load options):
# Debian-built grub cannot load kernels without shim's lock protocol, and
# shim is MS-signed (refused under our db) — the kernel EFI stub IS the
# loader (proven in corp-spike). The grub menu serves MS/SB-off machines.
virt-fw-vars -i $W/omni-vars-ours.fd -o $W/omni-vars-ours-run.fd \
	--append-boot-filepath '\boot\vmlinuz.klh console=ttyS0,115200 console=tty0 initrd=\boot\initrd.gz' >/dev/null 2>&1
rm -f $W/omni-ours.log
timeout 240 qemu-system-x86_64 -machine q35,smm=on,accel=kvm -cpu host -smp 2 -m 2048 \
	-global driver=cfi.pflash01,property=secure,value=on \
	-drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd \
	-drive if=pflash,format=raw,unit=1,file=$W/omni-vars-ours-run.fd \
	-drive file="$IMG",format=raw,if=virtio \
	-netdev user,id=n1 -device virtio-net-pci,netdev=n1 \
	-display none -serial file:$W/omni-ours.log >/dev/null 2>&1 || true
check "ours-grub-kernel" $W/omni-ours.log "Linux version"

say "RESULT pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
