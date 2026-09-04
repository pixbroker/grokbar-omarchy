import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Claude & Grok: SuperGrok weekly and Claude Code windows, plus optional Cursor
// monthly pools and optional Grok Bot weekly pool. Cursor and Grok Bot
// are off by default; Claude shows when a Claude Code login exists.
// Each provider is icon + % + reset (5d / 12h). Cursor also shows Other
// Models %. Claude shows session % and weekly %.
// Self-hides a provider with no usable session or period-pool data.
// Left click toggles the panel; right click refreshes.
BarWidget {
  id: root
  moduleName: "pixbroker.grokbar-omarchy"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  property double nowMs: Date.now()
  property real primaryPercent: -1
  property string resetAt: ""
  property string periodStart: ""
  property string tierLabel: ""
  property string grokLoginName: ""
  property string grokLoginEmail: ""
  property string subscriptionPeriodEnd: ""
  property bool subscriptionCancelsAtEnd: false
  property string usageStatusText: ""
  property string authHelpText: ""
  property var categories: []
  property bool hasData: false
  property bool refreshing: false
  // Signed in with usable credentials (auth.json present / refreshable).
  property bool grokAvailable: false

  // Cursor (X-login session only — Google Cursor accounts are ignored).
  property real cursorAutoPercent: -1
  property real cursorApiPercent: -1
  property string cursorResetAt: ""
  property string cursorPeriodStart: ""
  property string cursorTierLabel: ""
  property string cursorLoginName: ""
  property string cursorLoginEmail: ""
  property string cursorUsageStatusText: ""
  property string cursorAuthHelpText: ""
  property bool cursorHasData: false
  property bool cursorRefreshing: false
  property bool cursorAvailable: false

  // Grok Bot weekly pool (same Cursor session as the monthly pools).
  property real grokBotPercent: -1
  property string grokBotResetAt: ""
  property string grokBotPeriodStart: ""
  property string grokBotTierLabel: ""
  property string grokBotUsageStatusText: ""
  property string grokBotAuthHelpText: ""
  property bool grokBotHasData: false

  // Claude Code (local ~/.claude OAuth; session + weekly + scoped windows).
  property real claudeSessionPercent: -1
  property real claudeWeeklyPercent: -1
  property string claudeSessionResetAt: ""
  property string claudeSessionPeriodStart: ""
  property string claudeWeeklyResetAt: ""
  property string claudeWeeklyPeriodStart: ""
  property string claudeTierLabel: ""
  property string claudeUsageStatusText: ""
  property string claudeAuthHelpText: ""
  property var claudeLimits: []
  property bool claudeHasData: false
  property bool claudeRefreshing: false
  property bool claudeAvailable: false

  readonly property int refreshIntervalSec: Math.max(30, Number(setting("refreshIntervalSec", 300)) || 300)
  // Writable so a settings click flips immediately. shell.json reloads can
  // briefly replay the previous entry; persistGuardUntilMs ignores that echo.
  property bool showCursorUsage: false
  property bool showGrokBotUsage: false
  property bool showClaudeUsage: true
  property double persistGuardUntilMs: 0
  readonly property bool needsCursorSession: showCursorUsage || showGrokBotUsage
  readonly property int sessionMs: 5 * 3600 * 1000
  readonly property int weekMs: 7 * 24 * 3600 * 1000

  // TEMP QA hook: force over-pace styling (leave false in production).
  readonly property bool simulateOverPace: false

  // Expected usage by now = elapsed / period (0–1). -1 when unknown.
  readonly property real expectedPace: {
    var start = root.parseTimeMs(periodStart)
    var end = root.parseTimeMs(resetAt)
    if (!(start > 0) || !(end > start)) {
      // Weekly fallback: 7d before reset.
      if (!(end > 0)) return -1
      start = end - 7 * 24 * 3600 * 1000
    }
    var frac = (root.nowMs - start) / (end - start)
    if (!isFinite(frac)) return -1
    return Math.max(0, Math.min(1, frac))
  }

  // Displayed usage % (simulation can push past the pace marker).
  readonly property real displayPercent: {
    if (!root.simulateOverPace || !(primaryPercent >= 0) || !(expectedPace >= 0))
      return primaryPercent
    return Math.max(0, Math.min(1, Math.max(primaryPercent, expectedPace + 0.15)))
  }

  // Over budget if used more than the linear pace marker allows.
  readonly property bool overPace: expectedPace >= 0 && displayPercent >= 0
    && displayPercent > expectedPace + 0.0001
  readonly property bool grokAlarming: displayPercent >= 0.9
  readonly property string primaryText: displayPercent >= 0 ? Math.round(displayPercent * 100) + "%" : ""
  readonly property string resetText: {
    if (resetAt === "") return ""
    var ms = new Date(resetAt).getTime() - root.nowMs
    return isFinite(ms) ? root.formatBarDuration(ms) : ""
  }

  // Monthly expected usage by now. Fallback: 1 month before reset (not Grok's 7d).
  readonly property real cursorExpectedPace: {
    var start = root.parseTimeMs(cursorPeriodStart)
    var end = root.parseTimeMs(cursorResetAt)
    if (!(start > 0) || !(end > start)) {
      if (!(end > 0)) return -1
      start = end - 30 * 24 * 3600 * 1000
    }
    var frac = (root.nowMs - start) / (end - start)
    if (!isFinite(frac)) return -1
    return Math.max(0, Math.min(1, frac))
  }

  readonly property real cursorAutoDisplay: {
    if (!root.simulateOverPace || !(cursorAutoPercent >= 0) || !(cursorExpectedPace >= 0))
      return cursorAutoPercent
    return Math.max(0, Math.min(1, Math.max(cursorAutoPercent, cursorExpectedPace + 0.15)))
  }
  readonly property real cursorApiDisplay: {
    if (!root.simulateOverPace || !(cursorApiPercent >= 0) || !(cursorExpectedPace >= 0))
      return cursorApiPercent
    return Math.max(0, Math.min(1, Math.max(cursorApiPercent, cursorExpectedPace + 0.15)))
  }
  readonly property bool cursorAutoOverPace: cursorExpectedPace >= 0 && cursorAutoDisplay >= 0
    && cursorAutoDisplay > cursorExpectedPace + 0.0001
  readonly property bool cursorApiOverPace: cursorExpectedPace >= 0 && cursorApiDisplay >= 0
    && cursorApiDisplay > cursorExpectedPace + 0.0001
  readonly property bool cursorAlarming: cursorAutoDisplay >= 0.9 || cursorApiDisplay >= 0.9
    || cursorAutoOverPace || cursorApiOverPace
  readonly property string cursorAutoText: cursorAutoDisplay >= 0 ? Math.round(cursorAutoDisplay * 100) + "%" : ""
  readonly property string cursorApiText: cursorApiDisplay >= 0 ? Math.round(cursorApiDisplay * 100) + "%" : ""
  readonly property string cursorResetText: {
    if (cursorResetAt === "") return ""
    var ms = new Date(cursorResetAt).getTime() - root.nowMs
    return isFinite(ms) ? root.formatBarDuration(ms) : ""
  }

  readonly property real grokBotExpectedPace: {
    var start = root.parseTimeMs(grokBotPeriodStart)
    var end = root.parseTimeMs(grokBotResetAt)
    if (!(start > 0) || !(end > start)) {
      if (!(end > 0)) return -1
      start = end - 7 * 24 * 3600 * 1000
    }
    var frac = (root.nowMs - start) / (end - start)
    if (!isFinite(frac)) return -1
    return Math.max(0, Math.min(1, frac))
  }
  readonly property real grokBotDisplay: {
    if (!root.simulateOverPace || !(grokBotPercent >= 0) || !(grokBotExpectedPace >= 0))
      return grokBotPercent
    return Math.max(0, Math.min(1, Math.max(grokBotPercent, grokBotExpectedPace + 0.15)))
  }
  readonly property bool grokBotOverPace: grokBotExpectedPace >= 0 && grokBotDisplay >= 0
    && grokBotDisplay > grokBotExpectedPace + 0.0001
  readonly property bool grokBotAlarming: grokBotDisplay >= 0.9 || grokBotOverPace
  readonly property string grokBotText: grokBotDisplay >= 0 ? Math.round(grokBotDisplay * 100) + "%" : ""
  readonly property string grokBotResetText: {
    if (grokBotResetAt === "") return ""
    var ms = new Date(grokBotResetAt).getTime() - root.nowMs
    return isFinite(ms) ? root.formatBarDuration(ms) : ""
  }

  readonly property real claudeSessionExpectedPace: root.claudePaceFor(
    claudeSessionPeriodStart, claudeSessionResetAt, root.sessionMs)
  readonly property real claudeWeeklyExpectedPace: root.claudePaceFor(
    claudeWeeklyPeriodStart, claudeWeeklyResetAt, root.weekMs)

  readonly property real claudeSessionDisplay: {
    if (!root.simulateOverPace || !(claudeSessionPercent >= 0) || !(claudeSessionExpectedPace >= 0))
      return claudeSessionPercent
    return Math.max(0, Math.min(1, Math.max(claudeSessionPercent, claudeSessionExpectedPace + 0.15)))
  }
  readonly property real claudeWeeklyDisplay: {
    if (!root.simulateOverPace || !(claudeWeeklyPercent >= 0) || !(claudeWeeklyExpectedPace >= 0))
      return claudeWeeklyPercent
    return Math.max(0, Math.min(1, Math.max(claudeWeeklyPercent, claudeWeeklyExpectedPace + 0.15)))
  }
  readonly property bool claudeSessionOverPace: claudeSessionExpectedPace >= 0 && claudeSessionDisplay >= 0
    && claudeSessionDisplay > claudeSessionExpectedPace + 0.0001
  readonly property bool claudeWeeklyOverPace: claudeWeeklyExpectedPace >= 0 && claudeWeeklyDisplay >= 0
    && claudeWeeklyDisplay > claudeWeeklyExpectedPace + 0.0001
  readonly property var claudeDisplayLimits: {
    var raw = root.claudeLimits
    var out = []
    if (!raw || !raw.length) {
      if (claudeSessionDisplay >= 0)
        out.push({
          title: "Session", percent: claudeSessionDisplay, resetAt: claudeSessionResetAt,
          periodStart: claudeSessionPeriodStart, kind: "session", dayCount: 0,
          overPace: claudeSessionOverPace
        })
      if (claudeWeeklyDisplay >= 0)
        out.push({
          title: "Weekly", percent: claudeWeeklyDisplay, resetAt: claudeWeeklyResetAt,
          periodStart: claudeWeeklyPeriodStart, kind: "week", dayCount: 7,
          overPace: claudeWeeklyOverPace
        })
      return out
    }
    for (var i = 0; i < raw.length; i++) {
      var item = raw[i]
      if (!item) continue
      var pct = Number(item.percent)
      if (!isFinite(pct) || pct < 0) continue
      var kind = String(item.kind || "")
      var fallback = kind === "session" ? root.sessionMs : (kind === "month" ? 30 * 24 * 3600 * 1000 : root.weekMs)
      var pace = root.claudePaceFor(item.periodStart, item.resetAt, fallback)
      var over = pace >= 0 && pct > pace + 0.0001
      out.push({
        title: String(item.title || "Limit"),
        percent: pct,
        resetAt: String(item.resetAt || ""),
        periodStart: String(item.periodStart || ""),
        kind: kind,
        dayCount: Number(item.dayCount) || (kind === "week" ? 7 : 0),
        overPace: over,
        expectedPace: pace
      })
    }
    return out
  }
  readonly property bool claudeAlarming: {
    var items = root.claudeDisplayLimits
    for (var i = 0; i < items.length; i++) {
      if (Number(items[i].percent) >= 0.9 || items[i].overPace === true)
        return true
    }
    return false
  }
  readonly property string claudeSessionText: claudeSessionDisplay >= 0 ? Math.round(claudeSessionDisplay * 100) + "%" : ""
  readonly property string claudeWeeklyText: claudeWeeklyDisplay >= 0 ? Math.round(claudeWeeklyDisplay * 100) + "%" : ""
  readonly property string claudeResetAt: {
    var soonest = ""
    var soonestMs = NaN
    var items = root.claudeDisplayLimits
    for (var i = 0; i < items.length; i++) {
      var iso = String(items[i].resetAt || "")
      var t = root.parseTimeMs(iso)
      if (!(t > 0)) continue
      if (!isFinite(soonestMs) || t < soonestMs) {
        soonestMs = t
        soonest = iso
      }
    }
    return soonest
  }
  readonly property string claudeResetText: {
    if (claudeResetAt === "") return ""
    var ms = new Date(claudeResetAt).getTime() - root.nowMs
    return isFinite(ms) ? root.formatBarDuration(ms) : ""
  }

  readonly property bool grokVisible: grokAvailable && hasData
  readonly property bool cursorVisible: showCursorUsage && cursorAvailable && cursorHasData
  readonly property bool grokBotVisible: showGrokBotUsage && cursorAvailable && grokBotHasData
  readonly property bool claudeVisible: showClaudeUsage && claudeAvailable && claudeHasData
  readonly property bool alarming: grokAlarming
    || (grokBotVisible && grokBotAlarming)
    || (cursorVisible && cursorAlarming)
    || (claudeVisible && claudeAlarming)
  readonly property string verticalIcon: {
    if (grokVisible && grokAlarming) return "grok"
    if (grokBotVisible && grokBotAlarming) return "bot"
    if (cursorVisible && cursorAlarming) return "cursor"
    if (claudeVisible && claudeAlarming) return "claude"
    if (grokVisible) return "grok"
    if (grokBotVisible) return "bot"
    if (cursorVisible) return "cursor"
    if (claudeVisible) return "claude"
    return ""
  }

  readonly property string scannerPath: String(Qt.resolvedUrl("scripts/grokbar_scanner.py")).replace("file://", "")
  readonly property string cursorScannerPath: String(Qt.resolvedUrl("scripts/cursor_usage_scanner.py")).replace("file://", "")
  readonly property string claudeScannerPath: String(Qt.resolvedUrl("scripts/claude_usage_scanner.py")).replace("file://", "")
  // White icon only — MultiEffect recolors it to bar.foreground so it tracks
  // the theme the same way glyph widgets do (baked #fff/#111 never will).
  readonly property url iconSource: Qt.resolvedUrl("assets/grok.svg")
  readonly property url grokBotIconSource: Qt.resolvedUrl("assets/grok-bot.svg")
  readonly property url cursorIconSource: Qt.resolvedUrl("assets/cursor.svg")
  readonly property url claudeIconSource: Qt.resolvedUrl("assets/claude.svg")

  // Shape contract for shell.summon/hide/toggle routing.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function resolvePath(value) {
    var text = String(value || "").trim()
    if (text === "") return ""
    if (text.startsWith("~/"))
      return (Quickshell.env("HOME") || "") + text.slice(1)
    if (text === "~")
      return Quickshell.env("HOME") || ""
    return text
  }

  function scannerCommand(probe) {
    var command = ["python3", root.scannerPath]
    if (probe)
      command.push("--probe")
    var authPath = root.resolvePath(root.setting("authPath", ""))
    if (authPath !== "")
      command.push("--auth", authPath)
    return command
  }

  function cursorScannerCommand(probe) {
    var command = ["python3", root.cursorScannerPath]
    if (probe)
      command.push("--probe")
    var authPath = root.resolvePath(root.setting("cursorAuthPath", ""))
    if (authPath !== "")
      command.push("--auth", authPath)
    var stateDb = root.resolvePath(root.setting("stateDbPath", ""))
    if (stateDb !== "")
      command.push("--state-db", stateDb)
    var grokAuth = root.resolvePath(root.setting("authPath", ""))
    if (grokAuth !== "")
      command.push("--grok-auth", grokAuth)
    if (!probe && root.showGrokBotUsage)
      command.push("--include-sand")
    return command
  }

  function claudeScannerCommand(probe) {
    var command = ["python3", root.claudeScannerPath]
    if (probe)
      command.push("--probe")
    var configDir = root.resolvePath(root.setting("claudeConfigDir", ""))
    if (configDir !== "")
      command.push("--config", configDir)
    return command
  }

  // ≥1 day → "5d"; under a day → "12h" (no minutes on the bar).
  function formatBarDuration(ms) {
    if (!(ms > 0)) return "now"
    var hours = Math.floor(ms / 3600000)
    var days = Math.floor(hours / 24)
    if (days > 0) return days + "d"
    return Math.max(1, hours) + "h"
  }

  function parseTimeMs(value) {
    var text = String(value || "").trim()
    if (text === "") return NaN
    var t = new Date(text).getTime()
    return isFinite(t) ? t : NaN
  }

  function claudePaceFor(startIso, endIso, fallbackMs) {
    var start = root.parseTimeMs(startIso)
    var end = root.parseTimeMs(endIso)
    if (!(end > 0)) return -1
    if (!(start > 0) || !(start < end)) {
      if (!(fallbackMs > 0)) return -1
      start = end - fallbackMs
    }
    var frac = (root.nowMs - start) / (end - start)
    if (!isFinite(frac)) return -1
    return Math.max(0, Math.min(1, frac))
  }

  function applyScan(data) {
    if (!data || typeof data !== "object") {
      root.hasData = false
      return
    }
    var primary = Number(data.rateLimitPercent)
    if (!isFinite(primary)) primary = -1
    root.primaryPercent = primary
    root.resetAt = String(data.rateLimitResetAt || "")
    root.periodStart = String(data.rateLimitPeriodStart || "")
    root.tierLabel = String(data.tierLabel || "")
    root.grokLoginName = String(data.accountName || "")
    root.grokLoginEmail = String(data.accountEmail || "")
    root.subscriptionPeriodEnd = String(data.subscriptionPeriodEnd || "")
    root.subscriptionCancelsAtEnd = data.subscriptionCancelsAtEnd === true
    root.usageStatusText = String(data.usageStatusText || "")
    root.authHelpText = String(data.authHelpText || "")
    root.categories = Array.isArray(data.categories) ? data.categories : []
    root.hasData = primary >= 0
    root.nowMs = Date.now()
    root.injectPanel()
  }

  function clearUsage() {
    root.primaryPercent = -1
    root.resetAt = ""
    root.periodStart = ""
    root.tierLabel = ""
    root.grokLoginName = ""
    root.grokLoginEmail = ""
    root.subscriptionPeriodEnd = ""
    root.subscriptionCancelsAtEnd = false
    root.usageStatusText = ""
    root.authHelpText = ""
    root.categories = []
    root.hasData = false
  }

  function applyCursorScan(data) {
    if (!data || typeof data !== "object") {
      root.cursorHasData = false
      return
    }
    var autoPct = Number(data.rateLimitPercent)
    var apiPct = Number(data.secondaryRateLimitPercent)
    if (!isFinite(autoPct)) autoPct = -1
    if (!isFinite(apiPct)) apiPct = -1
    root.cursorAutoPercent = autoPct
    root.cursorApiPercent = apiPct
    root.cursorResetAt = String(data.rateLimitResetAt || data.secondaryRateLimitResetAt || "")
    root.cursorPeriodStart = String(data.rateLimitPeriodStart || "")
    root.cursorTierLabel = String(data.tierLabel || "")
    root.cursorLoginName = String(data.accountName || "")
    root.cursorLoginEmail = String(data.accountEmail || "")
    root.cursorUsageStatusText = String(data.usageStatusText || "")
    root.cursorAuthHelpText = String(data.authHelpText || "")
    root.cursorHasData = autoPct >= 0 || apiPct >= 0
    var botPct = Number(data.grokBotPercent)
    if (!isFinite(botPct)) botPct = -1
    root.grokBotPercent = botPct
    root.grokBotResetAt = String(data.grokBotResetAt || "")
    root.grokBotPeriodStart = String(data.grokBotPeriodStart || "")
    root.grokBotTierLabel = String(data.grokBotTierLabel || "")
    root.grokBotUsageStatusText = String(data.grokBotUsageStatusText || "")
    root.grokBotAuthHelpText = String(data.grokBotAuthHelpText || "")
    root.grokBotHasData = botPct >= 0
    root.nowMs = Date.now()
    root.injectPanel()
  }

  function clearCursorUsage() {
    root.cursorAutoPercent = -1
    root.cursorApiPercent = -1
    root.cursorResetAt = ""
    root.cursorPeriodStart = ""
    root.cursorTierLabel = ""
    root.cursorLoginName = ""
    root.cursorLoginEmail = ""
    root.cursorUsageStatusText = ""
    root.cursorAuthHelpText = ""
    root.cursorHasData = false
    root.clearGrokBotUsage()
  }

  function clearGrokBotUsage() {
    root.grokBotPercent = -1
    root.grokBotResetAt = ""
    root.grokBotPeriodStart = ""
    root.grokBotTierLabel = ""
    root.grokBotUsageStatusText = ""
    root.grokBotAuthHelpText = ""
    root.grokBotHasData = false
  }

  function applyClaudeScan(data) {
    if (!data || typeof data !== "object") {
      root.claudeHasData = false
      return
    }
    var sessionPct = Number(data.rateLimitPercent)
    var weeklyPct = Number(data.secondaryRateLimitPercent)
    if (!isFinite(sessionPct)) sessionPct = -1
    if (!isFinite(weeklyPct)) weeklyPct = -1
    root.claudeSessionPercent = sessionPct
    root.claudeWeeklyPercent = weeklyPct
    root.claudeSessionResetAt = String(data.rateLimitResetAt || "")
    root.claudeSessionPeriodStart = String(data.rateLimitPeriodStart || "")
    root.claudeWeeklyResetAt = String(data.secondaryRateLimitResetAt || "")
    root.claudeWeeklyPeriodStart = String(data.secondaryRateLimitPeriodStart || "")
    root.claudeTierLabel = String(data.tierLabel || "")
    root.claudeUsageStatusText = String(data.usageStatusText || "")
    root.claudeAuthHelpText = String(data.authHelpText || "")
    root.claudeLimits = Array.isArray(data.limits) ? data.limits : []
    root.claudeHasData = sessionPct >= 0 || weeklyPct >= 0 || root.claudeLimits.length > 0
    root.nowMs = Date.now()
    root.injectPanel()
  }

  function clearClaudeUsage() {
    root.claudeSessionPercent = -1
    root.claudeWeeklyPercent = -1
    root.claudeSessionResetAt = ""
    root.claudeSessionPeriodStart = ""
    root.claudeWeeklyResetAt = ""
    root.claudeWeeklyPeriodStart = ""
    root.claudeTierLabel = ""
    root.claudeUsageStatusText = ""
    root.claudeAuthHelpText = ""
    root.claudeLimits = []
    root.claudeHasData = false
  }

  function probeGrok() {
    if (!presenceProbe.running) presenceProbe.running = true
  }

  function probeCursor() {
    if (!cursorPresenceProbe.running) cursorPresenceProbe.running = true
  }

  function probeClaude() {
    if (!root.showClaudeUsage) return
    if (!claudePresenceProbe.running) claudePresenceProbe.running = true
  }

  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) {
      if (values[key] === undefined) delete entry[key]
      else entry[key] = values[key]
    }
    root.persistGuardUntilMs = Date.now() + 1500
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function applyIncomingSettings(s) {
    if (Date.now() < root.persistGuardUntilMs) return
    if (!s) s = {}
    if ("showCursorUsage" in s)
      root.showCursorUsage = s.showCursorUsage === true
    if ("showGrokBotUsage" in s)
      root.showGrokBotUsage = s.showGrokBotUsage === true
    if ("showClaudeUsage" in s)
      root.showClaudeUsage = s.showClaudeUsage !== false
  }

  function setShowCursorUsage(on) {
    var next = on === true
    if (root.showCursorUsage === next) return
    root.showCursorUsage = next
    root.persistSettings({ showCursorUsage: next })
    if (next) root.probeCursor()
    else if (!root.showGrokBotUsage) root.clearCursorUsage()
  }

  function setShowGrokBotUsage(on) {
    var next = on === true
    if (root.showGrokBotUsage === next) return
    root.showGrokBotUsage = next
    root.persistSettings({ showGrokBotUsage: next })
    if (next) root.probeCursor()
    else {
      root.clearGrokBotUsage()
      if (!root.showCursorUsage) root.clearCursorUsage()
    }
  }

  function setShowClaudeUsage(on) {
    var next = on === true
    if (root.showClaudeUsage === next) return
    root.showClaudeUsage = next
    root.persistSettings({ showClaudeUsage: next })
    if (next) root.probeClaude()
    else root.clearClaudeUsage()
  }

  function refresh() {
    // Availability first: no auth → hide and skip the API.
    if (root.grokAvailable) root.refreshing = true
    if (root.needsCursorSession && root.cursorAvailable) root.cursorRefreshing = true
    if (root.showClaudeUsage && root.claudeAvailable) root.claudeRefreshing = true
    root.probeGrok()
    if (root.needsCursorSession) root.probeCursor()
    if (root.showClaudeUsage) root.probeClaude()
  }

  function refreshUsage() {
    if (!root.grokAvailable) {
      root.clearUsage()
      return
    }
    if (usageScanner.running) return
    root.refreshing = true
    usageScanner.command = root.scannerCommand()
    usageScanner.running = true
  }

  function refreshCursorUsage() {
    if (!root.cursorAvailable) {
      root.clearCursorUsage()
      return
    }
    if (cursorUsageScanner.running) return
    root.cursorRefreshing = true
    cursorUsageScanner.command = root.cursorScannerCommand(false)
    cursorUsageScanner.running = true
  }

  function refreshClaudeUsage() {
    if (!root.claudeAvailable) {
      root.clearClaudeUsage()
      return
    }
    if (claudeUsageScanner.running) return
    root.claudeRefreshing = true
    claudeUsageScanner.command = root.claudeScannerCommand(false)
    claudeUsageScanner.running = true
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("grokLoginName" in target) target.grokLoginName = root.grokLoginName
    if ("grokLoginEmail" in target) target.grokLoginEmail = root.grokLoginEmail
    if ("cursorLoginName" in target) target.cursorLoginName = root.cursorLoginName
    if ("cursorLoginEmail" in target) target.cursorLoginEmail = root.cursorLoginEmail
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  // Missing auth or nothing to report → collapse the slot.
  visible: grokVisible || grokBotVisible || cursorVisible || claudeVisible
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: {
    root.applyIncomingSettings(root.settings)
    root.injectPanel()
  }

  Component.onCompleted: root.applyIncomingSettings(root.settings)

  IpcHandler {
    target: "pixbroker.grokbar-omarchy"
    function refresh(): string { root.refresh(); return "ok" }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  Process {
    id: presenceProbe
    // Signed-in credentials (default or override path). Grok CLI does not
    // need to be running — usage is fetched from grok.com with the OAuth token.
    // authPath is argv, never interpolated into a shell program.
    command: root.scannerCommand(true)
    running: false

    stdout: StdioCollector {
      onStreamFinished: {
        var status = text.trim()
        var available = status === "ready"
        if (root.grokAvailable !== available)
          root.grokAvailable = available
        if (available) root.refreshUsage()
        else root.clearUsage()
      }
    }
  }

  Process {
    id: usageScanner
    command: root.scannerCommand()
    running: false

    stdout: StdioCollector {
      onStreamFinished: {
        try {
          root.applyScan(JSON.parse(text))
        } catch (e) {
          root.hasData = false
          console.warn("pixbroker.grokbar-omarchy: bad scanner JSON", e)
        }
      }
    }

    onExited: root.refreshing = false

    stderr: StdioCollector {
      onStreamFinished: if (text.trim() !== "") console.warn("pixbroker.grokbar-omarchy", text.trim())
    }
  }

  Process {
    id: cursorPresenceProbe
    // X-login Cursor session only. --probe never calls the usage API.
    command: root.cursorScannerCommand(true)
    running: false

    stdout: StdioCollector {
      onStreamFinished: {
        var status = text.trim()
        var available = status === "ready"
        if (root.cursorAvailable !== available)
          root.cursorAvailable = available
        if (available) root.refreshCursorUsage()
        else root.clearCursorUsage()
      }
    }
  }

  Process {
    id: cursorUsageScanner
    command: root.cursorScannerCommand(false)
    running: false

    stdout: StdioCollector {
      onStreamFinished: {
        try {
          root.applyCursorScan(JSON.parse(text))
        } catch (e) {
          root.cursorHasData = false
          console.warn("pixbroker.grokbar-omarchy: bad cursor scanner JSON", e)
        }
      }
    }

    onExited: root.cursorRefreshing = false

    stderr: StdioCollector {
      onStreamFinished: if (text.trim() !== "") console.warn("pixbroker.grokbar-omarchy cursor", text.trim())
    }
  }

  Process {
    id: claudePresenceProbe
    command: root.claudeScannerCommand(true)
    running: false

    stdout: StdioCollector {
      onStreamFinished: {
        var status = text.trim()
        var available = status === "ready"
        if (root.claudeAvailable !== available)
          root.claudeAvailable = available
        if (available) root.refreshClaudeUsage()
        else root.clearClaudeUsage()
      }
    }
  }

  Process {
    id: claudeUsageScanner
    command: root.claudeScannerCommand(false)
    running: false

    stdout: StdioCollector {
      onStreamFinished: {
        try {
          root.applyClaudeScan(JSON.parse(text))
        } catch (e) {
          root.claudeHasData = false
          console.warn("pixbroker.grokbar-omarchy: bad claude scanner JSON", e)
        }
      }
    }

    onExited: root.claudeRefreshing = false

    stderr: StdioCollector {
      onStreamFinished: if (text.trim() !== "") console.warn("pixbroker.grokbar-omarchy claude", text.trim())
    }
  }

  Timer {
    // Auth file can appear after `grok login` / Cursor X sign-in / Claude
    // login; keep presence snappier than the usage API poll.
    interval: 5000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      root.probeGrok()
      if (root.needsCursorSession) root.probeCursor()
      if (root.showClaudeUsage) root.probeClaude()
    }
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: root.grokAvailable
      || (root.needsCursorSession && root.cursorAvailable)
      || (root.showClaudeUsage && root.claudeAvailable)
    repeat: true
    onTriggered: {
      root.refreshUsage()
      if (root.needsCursorSession) root.refreshCursorUsage()
      if (root.showClaudeUsage) root.refreshClaudeUsage()
    }
  }

  Timer {
    interval: 30000
    running: root.visible || root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: root.grokVisible || root.grokBotVisible || root.cursorVisible || root.claudeVisible
    active: root.alarming
    // Tooltip suppressed because the panel is the detail view.
    tooltipText: ""
    fixedWidth: {
      if (vertical) return Style.bar.iconSlot
      return Math.ceil(contentRow.implicitWidth + Style.spaceReal(8.75) * 2)
    }
    fixedHeight: vertical ? Style.bar.iconSlot : -1
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.refresh()
      else root.togglePanel()
    }

    Row {
      id: contentRow
      visible: !button.vertical
      anchors.centerIn: parent
      spacing: Style.space(8)

      Row {
        id: grokCluster
        visible: root.grokVisible
        spacing: Style.space(5)

        ThemedGrokIcon {
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          visible: root.primaryText !== ""
          anchors.verticalCenter: parent.verticalCenter
          text: root.primaryText
          color: root.displayPercent >= 0.9
            ? button.activeColor
            : button.foreground
          font.family: button.fontFamily
          font.pixelSize: Style.font.bodySmall
          renderType: Text.NativeRendering
        }

        Text {
          visible: root.resetText !== ""
          anchors.verticalCenter: parent.verticalCenter
          text: root.resetText
          color: root.dim
          font.family: button.fontFamily
          font.pixelSize: Style.font.bodySmall
          renderType: Text.NativeRendering
        }
      }

      Row {
        id: grokBotCluster
        visible: root.grokBotVisible
        spacing: Style.space(5)

        ThemedGrokBotIcon {
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          visible: root.grokBotText !== ""
          anchors.verticalCenter: parent.verticalCenter
          text: root.grokBotText
          color: root.grokBotOverPace || root.grokBotDisplay >= 0.9
            ? button.activeColor
            : button.foreground
          font.family: button.fontFamily
          font.pixelSize: Style.font.bodySmall
          renderType: Text.NativeRendering
        }

        Text {
          visible: root.grokBotResetText !== ""
          anchors.verticalCenter: parent.verticalCenter
          text: root.grokBotResetText
          color: root.dim
          font.family: button.fontFamily
          font.pixelSize: Style.font.bodySmall
          renderType: Text.NativeRendering
        }
      }

      Row {
        id: cursorCluster
        visible: root.cursorVisible
        spacing: Style.space(5)

        ThemedCursorIcon {
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          visible: root.cursorAutoText !== ""
          anchors.verticalCenter: parent.verticalCenter
          text: root.cursorAutoText
          color: root.cursorAutoOverPace || root.cursorAutoDisplay >= 0.9
            ? button.activeColor
            : button.foreground
          font.family: button.fontFamily
          font.pixelSize: Style.font.bodySmall
          renderType: Text.NativeRendering
        }

        Text {
          visible: root.cursorApiText !== ""
          anchors.verticalCenter: parent.verticalCenter
          text: root.cursorApiText
          color: root.cursorApiOverPace || root.cursorApiDisplay >= 0.9
            ? button.activeColor
            : button.foreground
          font.family: button.fontFamily
          font.pixelSize: Style.font.bodySmall
          renderType: Text.NativeRendering
        }

        Text {
          visible: root.cursorResetText !== ""
          anchors.verticalCenter: parent.verticalCenter
          text: root.cursorResetText
          color: root.dim
          font.family: button.fontFamily
          font.pixelSize: Style.font.bodySmall
          renderType: Text.NativeRendering
        }
      }

      Row {
        id: claudeCluster
        visible: root.claudeVisible
        spacing: Style.space(5)

        ThemedClaudeIcon {
          anchors.verticalCenter: parent.verticalCenter
        }

        Repeater {
          model: root.claudeDisplayLimits

          Text {
            required property var modelData
            visible: Number(modelData.percent) >= 0
            anchors.verticalCenter: parent.verticalCenter
            text: Math.round(Number(modelData.percent) * 100) + "%"
            color: modelData.overPace === true || Number(modelData.percent) >= 0.9
              ? button.activeColor
              : button.foreground
            font.family: button.fontFamily
            font.pixelSize: Style.font.bodySmall
            renderType: Text.NativeRendering
          }
        }

        Text {
          visible: root.claudeResetText !== ""
          anchors.verticalCenter: parent.verticalCenter
          text: root.claudeResetText
          color: root.dim
          font.family: button.fontFamily
          font.pixelSize: Style.font.bodySmall
          renderType: Text.NativeRendering
        }
      }

    }

    ThemedGrokIcon {
      visible: button.vertical && root.verticalIcon === "grok"
      anchors.centerIn: parent
    }

    ThemedGrokBotIcon {
      visible: button.vertical && root.verticalIcon === "bot"
      anchors.centerIn: parent
    }

    ThemedCursorIcon {
      visible: button.vertical && root.verticalIcon === "cursor"
      anchors.centerIn: parent
    }

    ThemedClaudeIcon {
      visible: button.vertical && root.verticalIcon === "claude"
      anchors.centerIn: parent
    }
  }

  // Same optical model as BarIconButton: iconCanvas slot, iconFont size.
  component ThemedGrokIcon: Item {
    width: Style.bar.iconCanvas
    height: Style.bar.iconCanvas
    implicitWidth: width
    implicitHeight: height

    readonly property int iconSize: Style.bar.iconFont

    Image {
      id: icon
      anchors.centerIn: parent
      width: parent.iconSize
      height: parent.iconSize
      source: root.iconSource
      sourceSize.width: parent.iconSize * 2
      sourceSize.height: parent.iconSize * 2
      fillMode: Image.PreserveAspectFit
      visible: false
      layer.enabled: true
    }

    MultiEffect {
      anchors.fill: icon
      source: icon
      colorization: 1.0
      colorizationColor: root.foreground
    }
  }

  component ThemedGrokBotIcon: Item {
    width: Style.bar.iconCanvas
    height: Style.bar.iconCanvas
    implicitWidth: width
    implicitHeight: height

    readonly property int iconSize: Style.bar.iconFont

    Image {
      id: grokBotIcon
      anchors.centerIn: parent
      width: parent.iconSize
      height: parent.iconSize
      source: root.grokBotIconSource
      sourceSize.width: parent.iconSize * 2
      sourceSize.height: parent.iconSize * 2
      fillMode: Image.PreserveAspectFit
      visible: false
      layer.enabled: true
    }

    MultiEffect {
      anchors.fill: grokBotIcon
      source: grokBotIcon
      colorization: 1.0
      colorizationColor: root.foreground
    }
  }

  component ThemedCursorIcon: Item {
    width: Style.bar.iconCanvas
    height: Style.bar.iconCanvas
    implicitWidth: width
    implicitHeight: height

    readonly property int iconSize: Style.bar.iconFont

    Image {
      id: cursorIcon
      anchors.centerIn: parent
      width: parent.iconSize
      height: parent.iconSize
      source: root.cursorIconSource
      sourceSize.width: parent.iconSize * 2
      sourceSize.height: parent.iconSize * 2
      fillMode: Image.PreserveAspectFit
      visible: false
      layer.enabled: true
    }

    MultiEffect {
      anchors.fill: cursorIcon
      source: cursorIcon
      colorization: 1.0
      colorizationColor: root.foreground
    }
  }

  component ThemedClaudeIcon: Item {
    width: Style.bar.iconCanvas
    height: Style.bar.iconCanvas
    implicitWidth: width
    implicitHeight: height

    readonly property int iconSize: Style.bar.iconFont

    Image {
      id: claudeIcon
      anchors.centerIn: parent
      width: parent.iconSize
      height: parent.iconSize
      source: root.claudeIconSource
      sourceSize.width: parent.iconSize * 2
      sourceSize.height: parent.iconSize * 2
      fillMode: Image.PreserveAspectFit
      visible: false
      layer.enabled: true
    }

    MultiEffect {
      anchors.fill: claudeIcon
      source: claudeIcon
      colorization: 1.0
      colorizationColor: root.foreground
    }
  }
}
