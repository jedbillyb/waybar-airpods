#!/bin/bash
# Symlink the waybar module into ~/.config/waybar, matching how the other
# modules on this box are wired up (the script lives in the project, the
# config directory only holds a link to it).
set -eu

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
WAYBAR_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/waybar"

if [[ ! -d "$WAYBAR_DIR" ]]; then
  echo "no waybar config directory at $WAYBAR_DIR" >&2
  exit 1
fi

ln -sfn "$HERE/waybar/airpods-status.sh" "$WAYBAR_DIR/airpods-status.sh"
echo "linked $WAYBAR_DIR/airpods-status.sh -> $HERE/waybar/airpods-status.sh"

command -v jq >/dev/null || echo "warning: jq is not installed, the module needs it" >&2
python3 -c 'import gi' 2>/dev/null || echo "warning: python gi (PyGObject) missing, the daemon needs it" >&2

cat <<'EOF'

Still to do by hand:
  1. add "custom/airpods" to modules-right in ~/.config/waybar/config
  2. add the module definition (see README)
  3. start the daemon from your compositor config:
       exec_always /mnt/shared/projects/waybar-airpods/daemon/airpodsd
EOF
