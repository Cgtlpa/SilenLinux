set -e

title="Silen installer"
root="/silen"

INSTALL_MODE=""

INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
for _lib in "$INSTALLER_DIR"/lib/*.sh; do
    [ -f "$_lib" ] || continue
    . "$_lib"
done
unset _lib
for _fn in choose-install-mode main_screen partitioning install-base setup-grub; do
    command -v "$_fn" >/dev/null 2>&1 || { echo "installer lib missing: $_fn" >&2; exit 1; }
done
unset _fn

trap cleanup EXIT
trap on_int_term INT TERM

[ "$(id -u)" = "0" ] || {
    whiptail --msgbox --title "$title" "root perms needed" 8 40 2>/dev/null || true
    exit 1
}

choose-install-mode

whiptail --msgbox --title "$title" "Silen linux installer still in early development errors may accur" 10 40 || true

main_screen
