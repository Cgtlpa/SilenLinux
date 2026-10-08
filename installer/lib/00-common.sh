# wipes mounts and temp stuff on exit no matter what
cleanup() {
	for m in "$ROOT_PATH/proc" "$ROOT_PATH/sys" "$ROOT_PATH/dev" "$ROOT_PATH/run" "$ROOT_PATH/boot" "$ROOT_PATH"; do
		if mountpoint -q "$m" 2>/dev/null; then
			umount -R "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || umount "$m" 2>/dev/null || true
		fi
	done
}

on_int_term() {
	cleanup
	echo "Interrupted." >&2
	exit 130
}
