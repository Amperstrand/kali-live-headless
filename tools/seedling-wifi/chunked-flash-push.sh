#!/bin/bash
# chunked-flash-push.sh — from the laptop: push IMAGE to HOST's USB
# stick in verified, resumable 32MiB chunks. Every chunk is confirmed
# by sha256 before the next starts; a dropped ssh or a rebooted target
# just means rerunning this script — it skips what is already correct.
#
# Usage: chunked-flash-push.sh [-p PORT] HOST[:DEST_DEV] IMAGE
#   DEST_DEV defaults to /dev/sda
#   SSH_KEY defaults to ~/.ssh/klh-seedling
set -euo pipefail

PORT=22
while getopts "p:" o; do case $o in p) PORT=$OPTARG ;; *) echo "bad flag" >&2; exit 2 ;; esac; done
shift $((OPTIND-1))
HOSTSPEC=${1:?usage: chunked-flash-push.sh [-p PORT] HOST[:DEV] IMAGE}
IMAGE=${2:?image path}
HOST=${HOSTSPEC%%:*}
DEV=${HOSTSPEC##*:}
[ "$DEV" = "$HOST" ] && DEV=/dev/sda
KEY=${SSH_KEY:-$HOME/.ssh/klh-seedling}
SSHOpts=(-i "$KEY" -p "$PORT" -o BatchMode=yes -o ConnectTimeout=10
	-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
CHUNK=$(( 32 * 1024 * 1024 ))   # 32 MiB
SCRIPT=$(dirname "$(readlink -f "$0")")/chunked-flash.sh

[ -f "$IMAGE" ] || { echo "no image: $IMAGE" >&2; exit 1; }
IMGSZ=$(stat -c%s "$IMAGE")
NCHUNKS=$(( (IMGSZ + CHUNK - 1) / CHUNK ))
echo "image: $IMAGE ($IMGSZ bytes, $NCHUNKS chunks of 32MiB)"
echo "host:  $HOST dev: $DEV"

# push the helper (idempotent)
scp -q "${SSHOpts[@]}" "$SCRIPT" root@"$HOST":/usr/local/bin/chunked-flash

# probe the device (identity + size)
OUT=$(ssh "${SSHOpts[@]}" root@"$HOST" "/usr/local/bin/chunked-flash probe $DEV")
echo "$OUT"
echo "$OUT" | grep -q "^REFUSED" && exit 1
DEVB=$(echo "$OUT" | sed -n 's/^DEVICE=//p')

# chunk loop: verify → (write → verify) → next
wrote=0 skipped=0 failed=0
for ((n=0; n<NCHUNKS; n++)); do
	# local truth for this chunk (final chunk may be short)
	REMSZ=$(( IMGSZ - n * CHUNK ))
	[ "$REMSZ" -gt "$CHUNK" ] && REMSZ=$CHUNK
	LHASH=$(dd if="$IMAGE" bs="$CHUNK" skip="$n" count=1 status=none | head -c "$REMSZ" | sha256sum | cut -d' ' -f1)

	for _attempt in 1 2 3; do
		RHASH=$(ssh "${SSHOpts[@]}" root@"$HOST" \
			"dd if=$DEVB bs=$CHUNK skip=$n count=1 status=none 2>/dev/null | head -c $REMSZ | sha256sum | cut -d' ' -f1" \
			|| true)
		[ "$RHASH" = "$LHASH" ] && { skipped=$((skipped+1)); continue 2; }

		# write it: exact bytes, exact position
		dd if="$IMAGE" bs="$CHUNK" skip="$n" count=1 status=none | head -c "$REMSZ" |
			ssh "${SSHOpts[@]}" root@"$HOST" \
				"dd of=$DEVB bs=$CHUNK seek=$n count=1 conv=notrunc status=none" || true
		ssh "${SSHOpts[@]}" root@"$HOST" sync || true
	done

	# post-verify after retries
	RHASH=$(ssh "${SSHOpts[@]}" root@"$HOST" \
		"dd if=$DEVB bs=$CHUNK skip=$n count=1 status=none 2>/dev/null | head -c $REMSZ | sha256sum | cut -d' ' -f1" \
		|| true)
	if [ "$RHASH" = "$LHASH" ]; then
		wrote=$((wrote+1))
	else
		failed=$((failed+1))
		echo "CHUNK $n FAILED VERIFICATION after retries" >&2
	fi
	[ $(( (n+1) % 8 )) -eq 0 ] && echo "  progress: $((n+1))/$NCHUNKS chunks (wrote=$wrote skipped=$skipped failed=$failed)"
done

echo "RESULT: wrote=$wrote skipped=$skipped failed=$failed"
[ "$failed" -eq 0 ] || { echo "FLASH INCOMPLETE — rerun to resume" >&2; exit 1; }
echo "FLASH COMPLETE — every chunk verified"
