#!/usr/bin/env bash
# serial-listen.sh — receive the remote serial console (UDP syslog on :514)
# Usage: sudo serial-listen.sh  (leave running; Ctrl-C to stop)
set -euo pipefail
PORT=${1:-514}
echo "listening on UDP :$PORT — boot progress will appear below:"
# socat is the simplest UDP listener
exec socat -u UDP-RECV:${PORT},reuseaddr - 2>/dev/null || {
	# fallback: busybox nc
	exec busybox nc -u -l -p ${PORT}
}
