#!/bin/bash
# Install, or re-install, the Display Layout plugin from this checkout.
#
# Safe to re-run: every step checks before it changes anything. Run it after
# editing the sources here so the running copy picks the changes up.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ID="delin.monitor"
PLUGIN_DIR="${HOME}/.config/omarchy/plugins/${PLUGIN_ID}"
HYPR_DIR="${HOME}/.config/hypr"
LAYOUT_LUA="${HYPR_DIR}/display-layout.lua"
HYPRLAND_LUA="${HYPR_DIR}/hyprland.lua"
SOURCES=(manifest.json Panel.qml Model.js)

# 1. The plugin itself. Omarchy loads user plugins from
#    ~/.config/omarchy/plugins/<id>/, which updates never touch.
mkdir -p "$PLUGIN_DIR"
for file in "${SOURCES[@]}"; do
  cp "${REPO_DIR}/${file}" "${PLUGIN_DIR}/${file}"
done
echo "plugin files  -> ${PLUGIN_DIR}"

# 2. The config file the panel rewrites. It has to exist before hyprland.lua
#    requires it, or the require fails; the panel fills in the real rules the
#    first time the shell starts.
if [[ ! -f $LAYOUT_LUA ]]; then
  cat >"$LAYOUT_LUA" <<'LUA'
-- Display layout - written by the "Display Layout" panel (plugin delin.monitor).
-- The panel fills this in on first run; pick your settings from the panel
-- rather than editing here, because the whole file is regenerated on change.
LUA
  echo "seeded        -> ${LAYOUT_LUA}"
else
  echo "kept existing -> ${LAYOUT_LUA}"
fi

# 3. Require that file. Without this the rules are written but never read --
#    silently, with no config error to point at.
if [[ -f $HYPRLAND_LUA ]]; then
  if grep -q 'hypr\.display-layout' "$HYPRLAND_LUA"; then
    echo "already required in ${HYPRLAND_LUA}"
  else
    cp "$HYPRLAND_LUA" "${HYPRLAND_LUA}.bak.$(date +%Y%m%d-%H%M%S)"
    if grep -q 'require("hypr\.monitors")' "$HYPRLAND_LUA"; then
      awk '
        { print }
        /require\("hypr\.monitors"\)/ && !done {
          print "-- Display Layout panel state (plugin delin.monitor)."
          print "require(\"hypr.display-layout\")"
          done = 1
        }
      ' "$HYPRLAND_LUA" >"${HYPRLAND_LUA}.tmp"
    else
      cp "$HYPRLAND_LUA" "${HYPRLAND_LUA}.tmp"
      printf '\n-- Display Layout panel state (plugin delin.monitor).\nrequire("hypr.display-layout")\n' \
        >>"${HYPRLAND_LUA}.tmp"
    fi
    mv "${HYPRLAND_LUA}.tmp" "$HYPRLAND_LUA"
    echo "require added -> ${HYPRLAND_LUA} (backup alongside)"
  fi
else
  echo "warning: ${HYPRLAND_LUA} not found; add require(\"hypr.display-layout\") by hand" >&2
fi

# 4. Pick everything up. Plugin code hot-reloads, but the bar widget component
#    does not -- a restart is what actually makes edits visible.
omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
hyprctl reload >/dev/null 2>&1 || true
omarchy restart shell >/dev/null 2>&1 || true

echo
echo "Done. The display panel is on the bar as \"Display Layout\""
echo "(SUPER + CTRL + D, or 'omarchy plugin enable ${PLUGIN_ID}')."
