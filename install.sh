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
# setup.sh is the very same script the panel runs on startup, so the installed
# and the freshly-installed paths cannot drift apart.
case "$(bash "${REPO_DIR}/setup.sh" 2>/dev/null || true)" in
added) echo "require added -> ${HYPRLAND_LUA} (backup alongside)" ;;
present) echo "already required in ${HYPRLAND_LUA}" ;;
*) echo "warning: could not read ${HYPRLAND_LUA}; add require(\"hypr.display-layout\") by hand" >&2 ;;
esac

# 4. Pick everything up. Plugin code hot-reloads, but the bar widget component
#    does not -- a restart is what actually makes edits visible.
omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
hyprctl reload >/dev/null 2>&1 || true
omarchy restart shell >/dev/null 2>&1 || true

echo
echo "Done. The display panel is on the bar as \"Display Layout\""
echo "(SUPER + CTRL + D, or 'omarchy plugin enable ${PLUGIN_ID}')."
