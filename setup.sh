#!/bin/bash
# Make Display Layout's rules actually get read.
#
# `omarchy plugin add` copies this plugin's folder and nothing else, so a fresh
# install has no require for ~/.config/hypr/display-layout.lua in hyprland.lua.
# Without that one line every rule the panel writes is ignored — silently, with
# nothing in `hyprctl configerrors` to point at (Omarchy issue #9422).
#
# Idempotent, and safe to run concurrently: the panel is instantiated more than
# once by the shell, and each instance runs this on startup. The flock and the
# check-then-edit inside one process are what stop them from each adding the
# line and each raising their own notification.
#
# Prints "added" when it changed something, "present" when it had nothing to do,
# and exits 2 when there is no hyprland.lua to edit.

set -u

HYPRLAND_LUA="${HYPRLAND_LUA:-$HOME/.config/hypr/hyprland.lua}"
MARKER="-- Display Layout panel state (plugin delin.monitor)."
REQUIRE_LINE='require("hypr.display-layout")'

[ -f "$HYPRLAND_LUA" ] || exit 2

lock="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/omarchy-display-layout-setup.lock"
exec 9>"$lock" 2>/dev/null || true
flock 9 2>/dev/null || true

# Re-check under the lock: the instance that lost the race will find the line
# already there and stop, rather than adding a second copy.
if grep -q 'hypr\.display-layout' "$HYPRLAND_LUA"; then
  echo present
  exit 0
fi

cp "$HYPRLAND_LUA" "${HYPRLAND_LUA}.bak.display-layout"

# Land next to the other personal requires. Anchored on hypr.monitors so the
# line does not end up past the "add your own configuration below" marker, which
# is the user's space. No anchor found, and it goes at the end instead.
if grep -qE '^[[:space:]]*require\("hypr\.monitors"\)' "$HYPRLAND_LUA"; then
  awk -v marker="$MARKER" -v line="$REQUIRE_LINE" '
    { print }
    /^[[:space:]]*require\("hypr\.monitors"\)/ && !done {
      print marker
      print line
      done = 1
    }
  ' "$HYPRLAND_LUA" >"${HYPRLAND_LUA}.new" &&
    mv "${HYPRLAND_LUA}.new" "$HYPRLAND_LUA"
else
  printf '\n%s\n%s\n' "$MARKER" "$REQUIRE_LINE" >>"$HYPRLAND_LUA"
fi

echo added
