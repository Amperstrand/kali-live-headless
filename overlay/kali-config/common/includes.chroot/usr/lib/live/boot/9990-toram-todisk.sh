#!/bin/sh
# shellcheck disable=SC2046,SC2154,SC2164
# ^ file-level: this file is a near-VERBATIM copy of live-boot's
# 9990-toram-todisk.sh with a minimal klh patch (below). Restyling it for
# lint-cleanliness would invite drift at every upstream pin bump; the
# disables cover the inherited quirks only.

# klh override of live-boot's 9990-toram-todisk.sh (2026-10-26, FR-6).
# Changes vs upstream (keep the diff minimal — this file must track
# live-boot's version at each pin bump):
#   1. plain `toram` is AUTO: besides upstream's "does it even fit" check,
#      require MemFree+Cached > size + KLH_TORAM_HEADROOM (default 4 GiB —
#      we host 2x4G KVM guests; a copy that starves them is worse than no
#      copy). `toram=always` skips the headroom (operator override).
#   2. log the decision to the console: the boot mode is a security AND
#      operations-relevant fact (self-flash safety, medium removability).
# Refused toram falls through to a normal medium boot (upstream behavior).

#set -e

copy_live_to ()
{
	copyfrom="${1}"
	copytodev="${2}"
	copyto="${copyfrom}_swap"

	if [ -z "${MODULETORAM}" ]
	then
		size=$(fs_size "" ${copyfrom}/ "used")
	else
		MODULETORAMFILE="${copyfrom}/${LIVE_MEDIA_PATH}/${MODULETORAM}"

		if [ -f "${MODULETORAMFILE}" ]
		then
			size=$( expr $(ls -la ${MODULETORAMFILE} | awk '{print $5}') / 1024 + 5000 )
		else
			log_warning_msg "Error: toram-module ${MODULETORAM} (${MODULETORAMFILE}) could not be read."
			return 1
		fi
	fi

	if [ "${copytodev}" = "ram" ]
	then
		# copying to ram:
		freespace=$(awk '/^MemFree:/{f=$2} /^Cached:/{c=$2} END{print f+c}' /proc/meminfo)
		mount_options="-o size=${size}k"
		free_string="memory"
		fstype="tmpfs"
		dev="tmpfs"

		# --- klh: headroom semantics -----------------------------------
		# Plain `toram` (and `toram=<module>`) is AUTO: besides upstream's
		# "does it fit" check below, demand room for the KVM guests we host
		# (default 4 GiB). `toram-force` anywhere on the cmdline skips the
		# headroom (operator override). NOTE: live-boot's `toram=<value>`
		# names the MODULE to copy (toram=filesystem.squashfs), NOT a mode.
		headroom_k=4194304 # 4 GiB in KiB
		if grep -qw toram-force /proc/cmdline 2>/dev/null; then
			headroom_k=0
		fi
		if [ "${headroom_k}" -gt 0 ] && [ "${freespace}" -lt $(( size + headroom_k )) ]; then
			echo " * toram=auto: only ${freespace}k free, need ${size}k + ${headroom_k}k headroom — booting from medium (add toram=always to force)" > /dev/console 2>&1
			return 1
		fi
		if [ -n "${MODULETORAM}" ]; then
			echo " * toram: copying ${MODULETORAM} to RAM (${size}k, ${headroom_k}k headroom reserved)" > /dev/console 2>&1
		else
			echo " * toram: copying whole medium to RAM (${size}k, ${headroom_k}k headroom reserved)" > /dev/console 2>&1
		fi
		# ----------------------------------------------------------------
	else
		# it should be a writable block device
		if [ -b "${copytodev}" ]
		then
			dev="${copytodev}"
			free_string="space"
			fstype=$(get_fstype "${dev}")
			freespace=$(fs_size "${dev}")
		else
			log_warning_msg "${copytodev} is not a block device."
			return 1
		fi
	fi

	if [ "${freespace}" -lt "${size}" ]
	then
		log_warning_msg "Not enough free ${free_string} (${freespace}k free, ${size}k needed) to copy live media in ${copytodev}."
		return 1
	fi

	# Custom ramdisk size
	if [ -z "${mount_options}" ] && [ -n "${ramdisk_size}" ]
	then
		# FIXME: should check for wrong values
		mount_options="-o size=${ramdisk_size}"
	fi

	# begin copying (or uncompressing)
	mkdir "${copyto}"
	log_begin_msg "mount -t ${fstype} ${mount_options} ${dev} ${copyto}"
	mount -t "${fstype}" ${mount_options} "${dev}" "${copyto}"

	if [ "${extension}" = "tgz" ]
	then
		cd "${copyto}"
		tar zxf "${copyfrom}/${LIVE_MEDIA_PATH}/$(basename ${FETCH})"
		rm -f "${copyfrom}/${LIVE_MEDIA_PATH}/$(basename ${FETCH})"
		mount -r -o move "${copyto}" "${rootmnt}"
		cd "${OLDPWD}"
	else
		if [ -n "${MODULETORAMFILE}" ]
		then
			if [ -x /bin/rsync ]
			then
				echo " * Copying $MODULETORAMFILE to RAM" 1>/dev/console
				rsync -a --progress ${MODULETORAMFILE} ${copyto} 1>/dev/console # copy only the filesystem module
			else
				cp ${MODULETORAMFILE} ${copyto} # copy only the filesystem module
			fi
		else
			if [ -x /bin/rsync ]
			then
				echo " * Copying whole medium to RAM" 1>/dev/console
				rsync -a --progress ${copyfrom}/* ${copyto} 1>/dev/console  # "cp -a" from busybox also copies hidden files
			else
				cp -a ${copyfrom}/* ${copyto}/
				if [ -e ${copyfrom}/${LIVE_MEDIA_PATH}/.disk ]
				then
					cp -a ${copyfrom}/${LIVE_MEDIA_PATH}/.disk ${copyto}
				fi
			fi
		fi

		umount ${copyfrom}
		mount -r -o move ${copyto} ${copyfrom}
	fi

	rmdir ${copyto}
	return 0
}
