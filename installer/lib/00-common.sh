cleanup() {
    for m in "$root/proc" "$root/sys" "$root/dev" "$root/run" "$root/boot" "$root"; do
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
