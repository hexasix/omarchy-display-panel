import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

Panel {
  id: root
  moduleName: "omarchy.monitor"
  ipcTarget: "omarchy.monitor"
  manageIpc: false

  // manageIpc: false so this panel can own the single IpcHandler the target
  // permits — needed for the brightness + state methods below.
  property int brightnessPercent: 0
  property int pendingBrightnessPercent: 0
  property bool brightnessSetQueued: false
  property bool brightnessAvailable: false
  property string internalMonitor: ""
  property string externalMonitor: ""
  property string focusedMonitor: ""
  property bool internalEnabled: false
  property bool mirrorEnabled: false
  property string monitorScale: ""
  property var displays: []
  property int enabledDisplayCount: 0

  // The display that currently holds workspace 1 — the "main" display. Derived
  // from live Hyprland state rather than remembered here, so it can never drift
  // from where workspace 1 actually is.
  property string mainDisplay: ""
  // Set while a main-display change is being applied, so the reload -> focus ->
  // move chain below knows it is running and which monitor is the target.
  property string pendingMainDisplay: ""
  // A display disable queued behind a main-display handoff, so the two don't
  // race. { name, enabled } or null.
  property var pendingToggle: null

  // Full geometry per output, from `hyprctl monitors all -j`. `displays` above
  // only carries what the DISPLAYS rows need; arrangement needs x/y/scale too.
  property var layout: []
  // name -> position string, set when the user picks one and cleared once the
  // reload has made it real. Generation reads this first, then the live state.
  property var positionOverrides: ({})
  // The exact text last written to display-layout.lua, so an unchanged layout is
  // never rewritten (and the file watcher never sees a no-op change).
  property string lastLayoutLua: ""
  // Index of the monitor row whose position dropdown is open, or -1. Only one
  // can be open at a time, so one slot is enough.
  property int openPositionIndex: -1

  // First-run setup. setup.sh does the editing; these track what is left before
  // one reload can bring the plugin to life.
  property bool setupWroteRequire: false
  property bool setupWroteLua: false
  property bool setupReloaded: false

  // setup.sh sits next to this file. Qt.resolvedUrl hands back a file:// URL;
  // Process wants a plain path.
  readonly property string setupScriptPath:
    Qt.resolvedUrl("setup.sh").toString().replace(/^file:\/\//, "")

  // Enabled displays only: a disabled panel has no workspaces to hold.
  readonly property var mainOptions: {
    var options = []
    for (var i = 0; i < displays.length; i++) {
      var display = displays[i]
      if (display && display.enabled) options.push(display.name)
    }
    return options
  }

  // Carry sub-notch touchpad deltas between wheel events.
  property real wheelAccumulator: 0

  // Cursor model shared by keyboard and mouse. Sections:
  //   "brightness" - single slider row, selectedIndex = -1 sentinel
  //                  (mirrors Audio's slider rows). Only present if a
  //                  controllable backlight was detected.
  //   "scale"      - 6 Button scale presets; treated as a single
  //                  horizontal row from j/k's perspective. h/l moves
  //                  between presets, identical to bluetooth's header.
  //   "monitors"   - vertical display row list for enabling/disabling displays;
  //                  j/k walks each row.
  // Mouse hover on a target updates root state via the components' `hovered`
  // signal so keyboard cursor and pointer share one highlight.
  readonly property var scalePresets: ["1", "1.25", "1.6", "2", "3", "4"]
  readonly property var scaleValues: {
    for (var i = 0; i < displays.length; i++) {
      var display = displays[i]
      if (display && display.focused)
        return Model.availableScales(scalePresets, display.width, display.height)
    }
    return scalePresets
  }
  property string focusSection: "scale"
  property int selectedIndex: 0
  property bool cursorActive: false

  // Text size slider — curated macOS-style notches (px). The panel snaps to
  // these stops; the CLI (omarchy-display-text-size) accepts any integer in range.
  readonly property var textSizeStops: [9, 10, 11, 12, 14, 16, 20]
  // While a change is in flight, the chosen stop index overrides the live
  // base-size so the knob doesn't snap back during the file round-trip. -1 =
  // no pending change; follow Style.font.baseSize.
  property int textSizePreviewIndex: -1

  // A text-size change reflows the whole panel (both font and spacing scale),
  // which slides rows under a stationary pointer and fires synthetic hover.
  // While true, hover is not allowed to hijack the keyboard focus section —
  // otherwise h/l on the text-size slider can jump focus to another row.
  property bool reflowingText: false
  function markReflowing() {
    root.reflowingText = true
    reflowSettle.restart()
  }

  readonly property var visibleSections: {
    var list = []
    if (brightnessAvailable) list.push("brightness")
    list.push("textsize")
    list.push("scale")
    if (displays.length > 1) {
      list.push("main")
      list.push("monitors")
    }
    return list
  }

  function sectionCount(section) {
    if (section === "brightness") return 0  // only the slider sentinel at -1
    if (section === "textsize") return 0    // slider sentinel at -1, like brightness
    if (section === "main") return 0        // lone dropdown, also sentinel at -1
    if (section === "scale") return scaleValues.length
    if (section === "monitors") return displays.length
    return 0
  }

  function sectionIsSingleRow(section) {
    // brightness, text size and the main-display dropdown are lone controls;
    // scale presets sit horizontally.
    return section === "brightness" || section === "textsize"
      || section === "main" || section === "scale"
  }

  function sectionFirstIndex(section) {
    if (section === "brightness" || section === "textsize" || section === "main") return -1
    return 0
  }

  function moveCursor(delta) {
    var sections = visibleSections
    if (!sections || sections.length === 0) return
    var sIdx = sections.indexOf(focusSection)
    if (sIdx < 0) {
      focusSection = sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    var inSingleRow = sectionIsSingleRow(focusSection)
    var max = inSingleRow ? 0 : sectionCount(focusSection) - 1

    if (delta > 0) {
      if (!inSingleRow && selectedIndex < max) { selectedIndex = selectedIndex + 1; return }
      if (sIdx < sections.length - 1) {
        focusSection = sections[sIdx + 1]
        selectedIndex = sectionFirstIndex(focusSection)
      }
    } else {
      if (!inSingleRow && selectedIndex > 0) { selectedIndex = selectedIndex - 1; return }
      if (sIdx > 0) {
        var prev = sections[sIdx - 1]
        focusSection = prev
        // Coming up from below — land on the last navigable row of the prev
        // section, or its sentinel for single-row sections.
        selectedIndex = sectionIsSingleRow(prev) ? sectionFirstIndex(prev) : sectionCount(prev) - 1
      }
    }
  }

  // h/l: in scale section, walks the preset row; everywhere else, no-op
  // because adjustBrightness handles horizontal motion on the brightness
  // slider.
  function moveCursorH(delta) {
    if (focusSection !== "scale") return
    var next = selectedIndex + delta
    if (next < 0) next = 0
    if (next > scaleValues.length - 1) next = scaleValues.length - 1
    selectedIndex = next
  }

  function adjustBrightness(delta) {
    if (focusSection !== "brightness") return
    if (!brightnessAvailable) return
    setBrightness(root.brightnessPercent + delta)
  }

  function activateCursor() {
    if (focusSection === "main") {
      // The dropdown owns the keys from here; PanelKeyCatcher.blocked follows
      // popupOpen so j/k walk the options instead of the panel cursor.
      mainDropdown.toggle()
      return
    }
    if (focusSection === "scale" && selectedIndex >= 0 && selectedIndex < scaleValues.length) {
      setScale(scaleValues[selectedIndex])
      return
    }
    if (focusSection === "monitors" && selectedIndex >= 0 && selectedIndex < displays.length) {
      var d = displays[selectedIndex]
      if (d) toggleDisplay(d.name, d.enabled)
    }
    // brightness: no separate action; the slider value is the action.
  }

  function clampCursor() {
    var sections = visibleSections
    if (!sections || !sections.length) return
    if (sections.indexOf(focusSection) < 0) {
      focusSection = sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    var count = sectionCount(focusSection)
    if (sectionIsSingleRow(focusSection)) {
      // brightness/text size/main use the -1 sentinel; scale clamps into the presets.
      if (focusSection === "brightness" || focusSection === "textsize"
          || focusSection === "main") selectedIndex = -1
      else if (selectedIndex < 0 || selectedIndex >= count) selectedIndex = 0
      return
    }
    if (count === 0) {
      var sIdx = sections.indexOf(focusSection)
      focusSection = sIdx > 0 ? sections[sIdx - 1] : sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    if (selectedIndex > count - 1) selectedIndex = count - 1
    if (selectedIndex < 0) selectedIndex = 0
  }

  // Keep the keyboard-focused row inside the viewport when the panel grows
  // taller than its allotted height (lots of displays). Mirrors audio's
  // ensureCursorVisible helper.
  function ensureCursorVisible(item) {
    if (!item || !scrollArea) return
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    var pt = item.mapToItem(flick.contentItem || flick, 0, 0)
    var top = pt.y
    var bottom = top + (item.height || 0)
    var viewTop = flick.contentY
    var viewBottom = viewTop + flick.height
    var margin = 6
    if (top < viewTop + margin) flick.contentY = Math.max(0, top - margin)
    else if (bottom > viewBottom - margin)
      flick.contentY = bottom + margin - flick.height
  }

  function brightnessIpc(percent) {
    var value = Number(percent)
    root.setBrightness(value)
    return "got " + root.pendingBrightnessPercent
  }

  function stateIpc() {
    return JSON.stringify({
      brightness: root.brightnessPercent,
      brightnessAvailable: root.brightnessAvailable,
      focusedMonitor: root.focusedMonitor,
      scale: root.monitorScale,
      mainDisplay: root.mainDisplay,
      displays: root.displays
    })
  }

  IpcHandler {
    target: "omarchy.monitor"

    function brightness(percent: string): string { return root.brightnessIpc(percent) }
    function state(): string { return root.stateIpc() }
    // Same action the dropdown performs, for scripting and for driving the
    // panel from outside (e.g. a keybinding).
    function main(): string { return root.mainDisplay }
    function setMain(name: string): string {
      root.setMainDisplay(name)
      return root.mainDisplay
    }
    // Where a display sits: omarchy.monitor position eDP-1 auto-right
    // With no value, just reports the current one.
    function position(name: string, value: string): string {
      if (String(value || "") !== "") root.setPosition(name, String(value))
      return root.positionValue(String(name || ""))
    }
    function arrangement(): string {
      var out = {}
      for (var i = 0; i < root.layout.length; i++) {
        var entry = root.layout[i]
        if (entry && entry.enabled) out[entry.name] = root.positionValue(entry.name)
      }
      return JSON.stringify(out)
    }
    // What a click on a DISPLAYS row does. Named toggleDisplay because
    // toggle() above already means "open/close the panel".
    function toggleDisplay(name: string): string {
      name = String(name || "")
      for (var i = 0; i < root.displays.length; i++) {
        if (root.displays[i] && root.displays[i].name === name) {
          root.toggleDisplay(name, root.displays[i].enabled)
          return "ok"
        }
      }
      return "unknown display"
    }
    function open() { root.open() }
    function close() { root.close() }
    function toggle() { root.toggle() }
    function show() { root.open() }
    function hide() { root.close() }
  }

  function refresh() {
    if (!stateProc.running) stateProc.running = true
    if (!mainStateProc.running) mainStateProc.running = true
    if (!layoutStateProc.running) layoutStateProc.running = true
  }

  // Connector names come from hyprctl, and one is written into generated Lua
  // that Hyprland then executes. A headless output can be created with any name,
  // so only a plain connector string may pass — the same guard Omarchy's own
  // monitor scripts apply.
  function safeMonitorName(name) {
    return /^[A-Za-z0-9._-]+$/.test(String(name || ""))
  }

  // First-run setup lives in setup.sh, next to this file — see its header for
  // why it is a locked script rather than QML.

  // One reload, once both halves of the first-run setup exist. Firing earlier
  // would reload a config that is still missing one of them, which is the exact
  // silent no-op the setup exists to avoid.
  function setupMaybeReload() {
    if (root.setupReloaded) return
    if (!root.setupWroteRequire || !root.setupWroteLua) return
    root.setupReloaded = true
    setupReload.restart()
  }

  // ---- Arrangement ----
  // Hyprland positions monitors in logical (post-scale) coordinates.
  function logicalWidth(entry) {
    return entry && entry.scale > 0 ? entry.w / entry.scale : 0
  }

  function logicalHeight(entry) {
    return entry && entry.scale > 0 ? entry.h / entry.scale : 0
  }

  function layoutEntry(name) {
    for (var i = 0; i < root.layout.length; i++) {
      if (root.layout[i].name === name) return root.layout[i]
    }
    return null
  }

  // Which side of a neighbour a display currently sits on, in the vocabulary
  // Hyprland's relative positions use. "" means a position this panel can't
  // name (hand-arranged, or a three-way overlap).
  function derivedPosition(name) {
    var self = layoutEntry(name)
    if (!self) return ""
    if (Math.abs(self.x) <= 2 && Math.abs(self.y) <= 2) return "0x0"

    var tolerance = 2
    for (var i = 0; i < root.layout.length; i++) {
      var other = root.layout[i]
      if (!other || other.name === name || !other.enabled) continue

      if (Math.abs(self.y - other.y) <= tolerance) {
        if (Math.abs(self.x - (other.x + logicalWidth(other))) <= tolerance) return "auto-right"
        if (Math.abs((self.x + logicalWidth(self)) - other.x) <= tolerance) return "auto-left"
      }
      if (Math.abs(self.x - other.x) <= tolerance) {
        if (Math.abs(self.y - (other.y + logicalHeight(other))) <= tolerance) return "auto-down"
        if (Math.abs((self.y + logicalHeight(self)) - other.y) <= tolerance) return "auto-up"
      }
    }
    return ""
  }

  // What is written for a display: the pending pick, else the live position.
  // An unrecognised arrangement is preserved verbatim rather than snapped to
  // something the panel would rather have.
  function positionValue(name) {
    if (root.positionOverrides[name] !== undefined) return root.positionOverrides[name]

    var derived = derivedPosition(name)
    if (derived !== "") return derived

    var entry = layoutEntry(name)
    if (entry) return Math.round(entry.x) + "x" + Math.round(entry.y)
    return "auto"
  }

  // Offer one set of directions per other display. Only the first display's set
  // is kept: relative positions carry no second name, so a third direction list
  // would be four more entries that generate the same four strings.
  function positionOptions(name) {
    var options = [{ value: "0x0", label: "Main · 0x0" }]
    var seen = {}
    for (var i = 0; i < root.layout.length; i++) {
      var other = root.layout[i]
      if (!other || !other.enabled || other.name === name) continue
      var directions = [
        ["auto-left", "Left of"],
        ["auto-right", "Right of"],
        ["auto-up", "Above"],
        ["auto-down", "Below"]
      ]
      var soleNeighbour = root.mainOptions.length === 2
      for (var j = 0; j < directions.length; j++) {
        if (seen[directions[j][0]]) continue
        seen[directions[j][0]] = true
        options.push({
          value: directions[j][0],
          label: directions[j][1] + (soleNeighbour ? " " + other.name : "")
        })
      }
    }
    return options
  }

  // The whole generated file. Rewritten in full on every change, so it never
  // accumulates stale rules.
  function layoutLua() {
    var main = root.pendingMainDisplay !== "" ? root.pendingMainDisplay : root.mainDisplay
    // On a fresh install nothing has been chosen yet and the workspace read may
    // not have landed, so fall back to the focused output and then to the first
    // enabled one — the file still has to be written on the very first run, or
    // there is nothing for the require to pick up.
    if (!safeMonitorName(main)) main = root.focusedMonitor
    if (!safeMonitorName(main)) {
      for (var i = 0; i < root.layout.length; i++) {
        if (root.layout[i].enabled && safeMonitorName(root.layout[i].name)) {
          main = root.layout[i].name
          break
        }
      }
    }
    if (!safeMonitorName(main)) return ""

    var out = "-- Display layout - written by the \"My Display\" panel (plugin delin.monitor).\n"
      + "--\n"
      + "-- Pick your main display and the arrangement from that panel instead of\n"
      + "-- editing this file: it is regenerated whenever either changes.\n"
      + "\n"
      + "-- Main display: home of workspace 1, and where focus returns when a panel is\n"
      + "-- added. Without the rule Hyprland hands a reconnecting panel the first\n"
      + "-- workspace it can find, dragging workspace 1 - and everything on it - off\n"
      + "-- the main display, and focus is a race the rule does not cover at all.\n"
      + "hl.workspace_rule({ workspace = \"1\", monitor = \"" + main + "\" })\n"
      + "\n"
      + "hl.on(\"monitor.added\", function()\n"
      + "  if hl.get_monitor(\"" + main + "\") then\n"
      + "    hl.dispatch(hl.dsp.focus({ monitor = \"" + main + "\" }))\n"
      + "  end\n"
      + "end)\n"
      + "\n"
      + "-- Arrangement. \"auto-left\" and friends are resolved by Hyprland against the\n"
      + "-- layout already in place, so they cannot go stale the way stored pixel\n"
      + "-- offsets would when a display's scale changes. Mode and scale are named\n"
      + "-- because a monitor rule replaces the whole rule -- leaving scale out makes\n"
      + "-- Hyprland pick one of its own for that output.\n"

    for (var i = 0; i < root.layout.length; i++) {
      var entry = root.layout[i]
      if (!entry || !entry.enabled || !safeMonitorName(entry.name)) continue
      out = out + "hl.monitor({ output = \"" + entry.name + "\", mode = \"preferred\""
        + ", position = \"" + positionValue(entry.name) + "\", scale = " + entry.scale + " })\n"
    }
    return out
  }

  // Write only when the text actually changed, so the file watcher is not fed
  // no-op rewrites every refresh.
  function syncLayoutFile() {
    var text = layoutLua()
    if (text === "" || text === root.lastLayoutLua) return
    root.lastLayoutLua = text
    layoutFile.setText(text)
    root.setupWroteLua = true
    root.setupMaybeReload()
  }

  // Called on refresh: heals the file when a scale was changed from somewhere
  // else (the SCALE pills, or SUPER + SLASH). Skipped mid-change, when the
  // derived state is still one reload behind the pending one.
  function maybeSyncLayout() {
    if (root.pendingMainDisplay !== "") return
    // Before the first geometry read lands there is no arrangement to write;
    // writing anyway would blank the rules until the next refresh.
    if (root.layout.length === 0) return
    root.syncLayoutFile()

    // Drop overrides the reload has now made real.
    var remaining = {}
    var held = false
    for (var name in root.positionOverrides) {
      if (root.derivedPosition(name) === root.positionOverrides[name]) continue
      remaining[name] = root.positionOverrides[name]
      held = true
    }
    if (!held) root.positionOverrides = ({})
  }

  // Persist the choice, then make it true now rather than at the next login:
  // reload so the new rule is live, focus workspace 1 wherever it currently is,
  // and move it onto the chosen display.
  function setMainDisplay(name) {
    name = String(name || "")
    if (!safeMonitorName(name)) return
    if (name === root.mainDisplay) return
    if (root.mainOptions.indexOf(name) < 0) return

    root.mainDisplay = name
    root.pendingMainDisplay = name

    root.syncLayoutFile()
    mainReloadProc.running = true
  }

  // Same shape as setMainDisplay, but the change only needs a reload — no
  // workspace has to move, because nothing about the main display changed.
  function setPosition(name, value) {    name = String(name || "")
    if (!safeMonitorName(name) || !value) return
    if (root.positionValue(name) === value) return

    var next = {}
    for (var key in root.positionOverrides) next[key] = root.positionOverrides[key]
    next[name] = value
    root.positionOverrides = next

    root.syncLayoutFile()
    mainReloadProc.running = true
  }

  // Keyboard route to the same thing the per-row dropdown does: on a DISPLAYS
  // row, h/l walk that display through the position options.
  function cyclePosition(delta) {
    if (focusSection !== "monitors") return
    if (selectedIndex < 0 || selectedIndex >= displays.length) return
    var display = displays[selectedIndex]
    if (!display || !display.enabled) return

    var options = root.positionOptions(display.name)
    if (!options.length) return

    var current = root.positionValue(display.name)
    var index = 0
    for (var i = 0; i < options.length; i++) {
      if (options[i].value === current) { index = i; break }
    }
    index = (index + delta + options.length) % options.length
    root.setPosition(display.name, options[index].value)
  }

  function setBrightness(value) {
    var percent = Model.clampBrightness(value)
    root.brightnessPercent = percent
    root.pendingBrightnessPercent = percent

    if (setBrightnessProc.running) {
      root.brightnessSetQueued = true
      return
    }

    root.brightnessSetQueued = false
    setBrightnessProc.command = ["omarchy-brightness-display", "--no-osd", "--monitor", root.focusedMonitor, percent + "%"]
    setBrightnessProc.running = true
  }

  function previewBrightness(value) {
    root.brightnessPercent = Model.clampBrightness(value)
    brightnessDebounce.restart()
  }

  function showBrightnessOsd(percent) {
    if (!bar || !bar.shell) return
    bar.shell.summon("omarchy.osd", JSON.stringify({
      icon: "brightness",
      value: percent
    }))
  }

  function normalizeScale(scale) {
    return Model.normalizeScale(scale)
  }

  function activeScaleIndex() {
    for (var i = 0; i < displays.length; i++) {
      var display = displays[i]
      if (display && display.focused)
        return Model.matchingScaleIndex(scaleValues, monitorScale, display.width, display.height)
    }
    return -1
  }

  function effectiveScale(scale) {
    for (var i = 0; i < displays.length; i++) {
      var display = displays[i]
      if (display && display.focused)
        return Model.cleanScale(scale, display.width, display.height)
    }
    return normalizeScale(scale)
  }

  // Playful mood-name for a given brightness percent. Bands intentionally
  // span ~10–20 points so casual tweaks change the label, while small
  // nudges within one band don't.
  function brightnessName(percent) {
    return Model.brightnessName(percent)
  }

  function updateDisplays(displaysJson) {
    var parsed = Model.parseDisplays(displaysJson)
    root.displays = parsed.displays
    root.enabledDisplayCount = parsed.enabledDisplayCount
  }

  function toggleDisplay(name, enabled) {
    if (!name) return
    if (enabled && root.enabledDisplayCount <= 1) return

    // Switching off the display that owns workspace 1 would strand that
    // workspace — and every window on it — on a dead output. Hand "main" to
    // another display first, then disable; pendingToggle makes the toggle wait
    // for that change to land rather than racing it.
    if (enabled && name === root.mainDisplay) {
      var fallback = ""
      for (var i = 0; i < root.mainOptions.length; i++) {
        if (root.mainOptions[i] !== name) { fallback = root.mainOptions[i]; break }
      }
      if (fallback === "") return
      root.pendingToggle = { name: name, enabled: true }
      root.setMainDisplay(fallback)
      return
    }

    // The internal panel is Omarchy's own business: its toggle script records
    // the choice so it survives a reboot and stays in step with the
    // SUPER + CTRL + DELETE keybinding.
    if (name === root.internalMonitor) {
      actionProc.command = ["omarchy-hyprland-monitor-internal", enabled ? "off" : "on"]
    } else if (enabled) {
      // `hyprctl keyword monitor ...` — what this used to run — fails under the
      // Lua config parser ("keyword can't work with non-legacy parsers"), which
      // made these rows silently do nothing. `eval` is the working form.
      actionProc.command = ["hyprctl", "eval",
        "hl.monitor({ output = \"" + name + "\", disabled = true })"]
    } else {
      // Dropping the eval'd rule re-enables the display, and the reload puts
      // the explicit positions from monitors.lua back rather than "auto".
      actionProc.command = ["hyprctl", "reload"]
    }
    if (!actionProc.running) actionProc.running = true
  }

  function setScale(scale) {
    actionProc.command = ["bash", "-c", "omarchy-hyprland-monitor-scaling " + scale]
    if (!actionProc.running) actionProc.running = true
  }

  // ---- Text size (shell base font + GTK text-scaling, via one CLI) ----
  function nearestTextStop(px) {
    var best = 0
    var bestDist = 1e9
    for (var i = 0; i < textSizeStops.length; i++) {
      var d = Math.abs(textSizeStops[i] - px)
      if (d < bestDist) { bestDist = d; best = i }
    }
    return best
  }

  // Effective stop index: the pending choice while a change is in flight,
  // otherwise whatever Style's live base-size rounds to.
  function currentTextIndex() {
    return textSizePreviewIndex >= 0 ? textSizePreviewIndex : nearestTextStop(Style.font.baseSize)
  }

  // px shown in the header: the pending stop if any, else the true base-size
  // (which may be an off-notch value set from the CLI).
  function displayedTextPx() {
    return textSizePreviewIndex >= 0 ? textSizeStops[textSizePreviewIndex] : Style.font.baseSize
  }

  function setTextSize(px) {
    textScaleProc.command = ["omarchy-display-text-size", String(px)]
    if (!textScaleProc.running) textScaleProc.running = true
  }

  function adjustTextSize(deltaSteps) {
    var idx = currentTextIndex() + deltaSteps
    if (idx < 0) idx = 0
    if (idx > textSizeStops.length - 1) idx = textSizeStops.length - 1
    markReflowing()
    textSizePreviewIndex = idx
    setTextSize(textSizeStops[idx])
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: {
    refresh()
    setupProc.running = true
  }

  // KeyboardPanel primes focus at open-time, so SUPER-bound IPC summons land
  // with j/k ready to navigate. Keep a default landing point, but don't paint
  // the cursor until hover or the first navigation key.
  onOpenedChanged: {
    if (opened) {
      refresh()
      if (brightnessAvailable) {
        focusSection = "brightness"
        selectedIndex = -1
      } else {
        focusSection = "scale"
        selectedIndex = 0
      }
      cursorActive = false
    }
  }

  onBrightnessAvailableChanged: clampCursor()
  onDisplaysChanged: clampCursor()
  onScaleValuesChanged: clampCursor()
  onVisibleSectionsChanged: clampCursor()

  // Only poll while the panel is open; the bar glyph tracks monitor count via
  // Quickshell.screens, and open-time refresh + Component.onCompleted cover the
  // rest. External brightness changes are reflected whenever the panel is open.
  Timer {
    interval: 5000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  Process {
    id: stateProc
    command: ["omarchy-monitor-state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").split("\n")
        var brightness = String(lines[0] || "").trim()
        root.brightnessAvailable = brightness !== "unavailable" && brightness !== ""
        root.brightnessPercent = root.brightnessAvailable ? Math.max(0, Math.min(100, parseInt(brightness, 10))) : 0
        root.internalMonitor = String(lines[1] || "").trim()
        root.externalMonitor = String(lines[2] || "").trim()
        root.internalEnabled = String(lines[3] || "").trim() !== ""
        root.mirrorEnabled = String(lines[4] || "").trim() === root.externalMonitor && root.externalMonitor !== ""
        root.focusedMonitor = String(lines[5] || "").trim()
        root.monitorScale = root.normalizeScale(String(lines[6] || "").trim())
        root.updateDisplays(String(lines[7] || "[]").trim())
      }
    }
  }

  Timer {
    id: brightnessDebounce
    interval: 180
    repeat: false
    onTriggered: root.setBrightness(root.brightnessPercent)
  }

  Process {
    id: setBrightnessProc
    stdout: StdioCollector { waitForEnd: true }
    // Do NOT call refresh() after a brightness set completes. The local
    // brightnessPercent we just wrote is authoritative; re-reading via
    // `omarchy-brightness-display` races the hardware/driver and can
    // return an empty string, which the parser then coerces to 0 —
    // visible as a "bounce to zero" after h/l keypresses. External
    // brightness changes are still picked up by the 5s periodic refresh,
    // the open-time refresh, and Component.onCompleted.
    onRunningChanged: {
      if (running) return
      if (root.brightnessSetQueued) {
        root.setBrightness(root.pendingBrightnessPercent)
      }
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: if (!running) root.refresh()
  }

  // Applies text size via the CLI, which rewrites the shell override file;
  // Style picks the new base-size up through its own file watch, so there's
  // nothing to refresh here.
  Process {
    id: textScaleProc
    stdout: StdioCollector { waitForEnd: true }
  }

  // ---- Main display ----
  // Read back where workspace 1 actually lives, so the dropdown reflects reality
  // rather than a remembered preference — including when the chosen display was
  // unplugged and workspace 1 fell back to another one.
  Process {
    id: mainStateProc
    command: ["hyprctl", "workspaces", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var found = ""
        try {
          var list = JSON.parse(String(text || "[]"))
          for (var i = 0; i < list.length; i++) {
            if (list[i] && list[i].id === 1) {
              found = String(list[i].monitor || "")
              break
            }
          }
        } catch (e) {
          found = ""
        }
        root.mainDisplay = found
      }
    }
  }

  FileView {
    id: layoutFile
    path: Quickshell.env("HOME") + "/.config/hypr/display-layout.lua"
    watchChanges: false
    atomicWrites: true
    printErrors: false
  }

  // The require in hyprland.lua is added by setup.sh rather than from here: the
  // shell instantiates this panel more than once, and a check-then-edit split
  // across two QML instances is exactly the race that would add the line twice.
  // The script takes a lock and does the whole thing in one process.
  Process {
    id: setupProc
    command: ["bash", root.setupScriptPath]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // "present" means it had nothing to do; anything else (including a
        // missing hyprland.lua) leaves us quiet.
        if (String(text || "").trim() !== "added") return
        root.setupWroteRequire = true
        setupNotifyProc.running = true
        root.setupMaybeReload()
      }
    }
  }

  Process {
    id: setupNotifyProc
    command: ["omarchy-notification-send", "-u", "low", "-g", "󰍹", "-t", "12000",
      "Display Layout set itself up",
      "Added require(\"hypr.display-layout\") to hyprland.lua. A backup of the old file sits next to it."]
  }

  Timer {
    id: setupReload
    interval: 300
    repeat: false
    onTriggered: if (!mainReloadProc.running) mainReloadProc.running = true
  }

  // Geometry for the arrangement controls: hyprctl is the only source that
  // carries x/y/scale, which omarchy-monitor-state does not report.
  Process {
    id: layoutStateProc
    command: ["hyprctl", "monitors", "all", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = []
        try {
          var list = JSON.parse(String(text || "[]"))
          for (var i = 0; i < list.length; i++) {
            var m = list[i]
            if (!m || !m.name) continue
            parsed.push({
              name: String(m.name),
              x: Number(m.x) || 0,
              y: Number(m.y) || 0,
              w: Number(m.width) || 0,
              h: Number(m.height) || 0,
              scale: Number(m.scale) || 1,
              enabled: m.disabled !== true
            })
          }
        } catch (e) {
          parsed = []
        }
        root.layout = parsed
        root.maybeSyncLayout()
      }
    }
  }

  // The three steps of applying a choice, chained so each lands before the next
  // begins. Separate Processes rather than one `bash -c` keep the Lua expression
  // a single argv element, so there is no shell quoting to escape.
  Process {
    id: mainReloadProc
    command: ["hyprctl", "reload"]
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: {
      if (running) return
      if (root.pendingMainDisplay !== "") mainFocusProc.running = true
    }
  }

  Process {
    id: mainFocusProc
    command: ["hyprctl", "dispatch", "hl.dsp.focus({ workspace = \"1\" })"]
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: {
      if (running) return
      mainMoveProc.command = ["hyprctl", "dispatch",
        "hl.dsp.workspace.move({ monitor = \"" + root.pendingMainDisplay + "\" })"]
      mainMoveProc.running = true
    }
  }

  Process {
    id: mainMoveProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: {
      if (running) return
      root.pendingMainDisplay = ""
      root.refresh()

      // The handoff has landed, so a disable that was waiting on it is now safe
      // to run.
      if (root.pendingToggle) {
        var queued = root.pendingToggle
        root.pendingToggle = null
        root.toggleDisplay(queued.name, queued.enabled)
      }
    }
  }

  // Clears the hover-suppression flag once the reflow triggered by a text-size
  // change has settled.
  Timer {
    id: reflowSettle
    interval: 300
    repeat: false
    onTriggered: root.reflowingText = false
  }

  // Once Style's base-size catches up to the pending choice, drop the preview
  // so the slider tracks the live value again. The change itself reflows the
  // panel, so suppress hover for a beat while it lands.
  Connections {
    target: Style
    function onFontBaseSizeChanged() {
      root.markReflowing()
      if (root.textSizePreviewIndex >= 0
          && root.nearestTextStop(Style.font.baseSize) === root.textSizePreviewIndex)
        root.textSizePreviewIndex = -1
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Quickshell.screens.length > 1 ? "󰍺" : "󰍹"
    onPressed: function(b) { root.toggle() }
    onWheelMoved: function(delta) {
      if (!root.brightnessAvailable) return
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (wheel.steps === 0) return
      root.setBrightness(root.brightnessPercent + wheel.steps * 5)
      root.showBrightnessOsd(root.brightnessPercent)
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While a dropdown's list is open it owns j/k/Enter, so short-circuit
      // this handler rather than double-driving the panel cursor.
      blocked: mainDropdown.popupOpen || root.openPositionIndex >= 0
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) {
          if (root.focusSection === "brightness") root.adjustBrightness(dx * 5)
          else if (root.focusSection === "textsize") root.adjustTextSize(dx)
          else if (root.focusSection === "scale") root.moveCursorH(dx)
          else if (root.focusSection === "monitors") root.cyclePosition(dx)
        }
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          // ---------- Hero: display icon · title/status ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

            Text {
              id: heroIcon
              textFormat: Text.PlainText
              text: root.displays.length > 1 ? "󰍺" : "󰍹"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: "Display"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                id: heroLabel
                textFormat: Text.PlainText
                text: {
                  if (root.brightnessAvailable) {
                    return root.brightnessName(brightnessSlider.dragging ? brightnessSlider.liveValue : root.brightnessPercent).toUpperCase()
                  }
                  return "FIXED BRIGHTNESS"
                }
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
                width: parent.width
              }
            }
          }

          // ---------- Brightness ----------
          PanelSeparator {
            visible: root.brightnessAvailable
            foreground: root.bar.foreground
          }

          Column {
            visible: root.brightnessAvailable
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(brightnessHeader.implicitHeight, brightnessPercent.implicitHeight)

              PanelSectionHeader {
                id: brightnessHeader
                text: "BRIGHTNESS"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: brightnessPercent
                textFormat: Text.PlainText
                text: Math.round(brightnessSlider.dragging ? brightnessSlider.liveValue : root.brightnessPercent) + "%"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            CursorSurface {
              id: brightnessRow
              width: parent.width
              height: brightnessSlider.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "brightness" && root.selectedIndex === -1
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(brightnessRow)
              foreground: root.bar.foreground
              outline: true

              PanelSlider {
                id: brightnessSlider
                bar: root.bar
                anchors.fill: parent
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                minimum: 1
                maximum: 100
                step: 1
                value: root.brightnessPercent
                integer: true
                onMoved: function(v) { root.previewBrightness(v) }
                onReleased: function(v) {
                  brightnessDebounce.stop()
                  root.setBrightness(v)
                }
              }

              HoverHandler {
                onHoveredChanged: if (hovered && !root.reflowingText) {
                  root.cursorActive = true
                  root.focusSection = "brightness"
                  root.selectedIndex = -1
                }
              }
            }
          }

          // ---------- Text size ----------
          PanelSeparator {
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(textSizeHeader.implicitHeight, textSizePx.implicitHeight)

              PanelSectionHeader {
                id: textSizeHeader
                text: "TEXT SIZE"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: textSizePx
                textFormat: Text.PlainText
                text: (textSizeSlider.dragging
                       ? root.textSizeStops[Math.round(textSizeSlider.liveValue)]
                       : root.displayedTextPx()) + "px"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            CursorSurface {
              id: textSizeRow
              width: parent.width
              height: textSizeSlider.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "textsize" && root.selectedIndex === -1
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(textSizeRow)
              foreground: root.bar.foreground
              outline: true

              PanelSlider {
                id: textSizeSlider
                bar: root.bar
                anchors.fill: parent
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                minimum: 0
                maximum: root.textSizeStops.length - 1
                step: 1
                integer: true
                tickCount: root.textSizeStops.length
                value: root.currentTextIndex()
                onReleased: function(v) { root.setTextSize(root.textSizeStops[Math.round(v)]) }
              }

              HoverHandler {
                onHoveredChanged: if (hovered && !root.reflowingText) {
                  root.cursorActive = true
                  root.focusSection = "textsize"
                  root.selectedIndex = -1
                }
              }
            }
          }

          // ---------- Scale ----------
          PanelSeparator {
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(10)

            Item {
              width: parent.width
              implicitHeight: Math.max(scaleHeader.implicitHeight, scaleMonitor.implicitHeight)

              PanelSectionHeader {
                id: scaleHeader
                text: "SCALE"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              // Name the monitor SCALE targets, since it only applies to the
              // focused one.
              Text {
                id: scaleMonitor
                textFormat: Text.PlainText
                text: root.focusedMonitor
                // Only worth naming when more than one display is in play.
                visible: root.focusedMonitor !== "" && root.enabledDisplayCount > 1
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Grid {
              id: scaleRow
              width: parent.width
              columns: root.scaleValues.length
              spacing: Style.spacing.xs

              readonly property real cellWidth: root.scaleValues.length > 0
                ? (width - spacing * (columns - 1)) / columns
                : 0

              Repeater {
                model: root.scaleValues

                ScalePill {
                  required property string modelData
                  required property int index

                  scaleValue: modelData
                  scaleIndex: index
                  width: scaleRow.cellWidth
                }
              }
            }
          }

          // ---------- Main display ----------
          PanelSeparator {
            visible: root.displays.length > 1
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.displays.length > 1

            PanelSectionHeader {
              text: "MAIN DISPLAY"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            // Names the display that owns workspace 1, rather than the more
            // accurate but jargon-y "which monitor holds workspace 1".
            Dropdown {
              id: mainDropdown
              width: parent.width
              showLabel: false
              fontFamily: root.bar.fontFamily
              foreground: root.bar.foreground
              options: root.mainOptions
              value: root.mainDisplay
              hasCursor: root.cursorActive && root.focusSection === "main"
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(mainDropdown)
              onHovered: function(isHovered) {
                if (!isHovered || root.reflowingText) return
                root.cursorActive = true
                root.focusSection = "main"
                root.selectedIndex = -1
              }
              onChanged: function(v) { root.setMainDisplay(v) }
            }
          }

          // ---------- Monitors ----------
          PanelSeparator {
            visible: root.displays.length > 1
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: root.displays.length > 1

            PanelSectionHeader {
              text: "DISPLAYS"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            Repeater {
              model: root.displays

              Column {
                id: monitorBlock
                required property var modelData
                required property int index

                width: panelColumn.width
                spacing: Style.space(4)

                MonitorRow {
                  width: parent.width
                  display: monitorBlock.modelData
                  rowIndex: monitorBlock.index
                }

                // Where this display sits relative to the others. Mouse-only by
                // design: the keyboard reaches the same thing with h/l on the
                // row above, which keeps one focus stop per display.
                Dropdown {
                  id: positionDropdown
                  width: parent.width
                  visible: monitorBlock.modelData && monitorBlock.modelData.enabled
                  label: "Position"
                  fontFamily: root.bar.fontFamily
                  foreground: root.bar.foreground
                  options: root.positionOptions(monitorBlock.modelData ? monitorBlock.modelData.name : "")
                  value: monitorBlock.modelData ? root.positionValue(monitorBlock.modelData.name) : ""
                  onPopupOpenChanged: {
                    if (popupOpen) root.openPositionIndex = monitorBlock.index
                    else if (root.openPositionIndex === monitorBlock.index) root.openPositionIndex = -1
                  }
                  onChanged: function(v) {
                    if (monitorBlock.modelData) root.setPosition(monitorBlock.modelData.name, v)
                  }
                }
              }
            }
          }

          Item {
            width: parent.width
            height: Style.space(4)
          }
        }
      }
    }
  }

  component ScalePill: Button {
    id: pill
    required property string scaleValue
    required property int scaleIndex

    text: root.effectiveScale(scaleValue) + "x"
    fontSize: Style.font.caption
    foreground: root.bar.foreground
    fontFamily: root.bar.fontFamily
    horizontalPadding: Style.spacing.sm
    verticalPadding: Style.spacing.controlPaddingY
    bordered: true

    active: root.activeScaleIndex() === scaleIndex
    hasCursor: root.cursorActive && root.focusSection === "scale" && root.selectedIndex === scaleIndex

    onClicked: root.setScale(scaleValue)
    onHovered: function(isHovered) {
      if (!isHovered || root.reflowingText) return
      root.cursorActive = true
      root.focusSection = "scale"
      root.selectedIndex = pill.scaleIndex
    }
  }

  component MonitorRow: CursorSurface {
    id: monitorRow
    required property var display
    required property int rowIndex

    readonly property bool isFocused: display && display.focused
    readonly property bool canToggle: display && (!display.enabled || root.enabledDisplayCount > 1)

    hasCursor: root.cursorActive && root.focusSection === "monitors" && root.selectedIndex === rowIndex
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(monitorRow)
    current: isFocused
    foreground: root.bar.foreground
    fill: Style.hoverFillFor(root.bar.foreground, Color.accent)
    currentFill: Style.selectedFillFor(root.bar.foreground, Color.accent)
    implicitHeight: monitorInner.implicitHeight + Style.spacing.xl
    opacity: canToggle ? 1.0 : 0.45

    Row {
      id: monitorInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        text: "󰍹"
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.title
        width: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: monitorRow.display.name + (monitorRow.display.focused ? " · focused" : "")
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        width: parent.width - Style.space(22) - Style.space(14) - Style.space(16)
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: monitorRow.display.enabled ? "󰄬" : ""
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.subtitle
        width: Style.space(14)
        horizontalAlignment: Text.AlignRight
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: monitorRow.canToggle ? Qt.PointingHandCursor : Qt.ArrowCursor
      onContainsMouseChanged: if (containsMouse && !root.reflowingText) {
        root.cursorActive = true
        root.focusSection = "monitors"
        root.selectedIndex = monitorRow.rowIndex
      }
      onClicked: if (monitorRow.canToggle) root.toggleDisplay(monitorRow.display.name, monitorRow.display.enabled)
    }
  }
}
