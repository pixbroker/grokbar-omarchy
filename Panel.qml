import QtQuick
import qs.Commons
import qs.Ui

// Usage popup. BarWidget.qml owns the bar slot and scan state.
// Grok card mirrors grok.com Settings → Usage (weekly pool + products).
// Cursor, Grok Bot, and GPT cards are optional (settings toggles, off by
// default). Cursor shows two monthly pools; Grok Bot shows its weekly pool;
// GPT shows session, weekly, and any extra windows. Cursor and Grok Bot
// require the Cursor account to match Grok. GPT reads the local Codex /
// ChatGPT login. Gear and reload follow the HEY panel: header buttons,
// flip to settings.
Panel {
  id: root
  moduleName: "pixbroker.grokbar-omarchy"
  ipcTarget: "pixbroker.grokbar-omarchy"
  manageIpc: false

  property var anchorItem: null
  property bool openedFromHotkey: false
  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel. Everything the bar identifies a panel by has to be that
  // widget: the popout coordinator (and with it the open-panel dot under the
  // pill) compares against `slot.activeItem`, and switchPanelFrom looks the
  // slot up the same way. Third-party widgets get PluginBarApi as `bar`.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  // Theme aliases only — no hardcoded greens/reds.
  // Under pace: accent; over pace: urgent.
  // Pace marker uses full accent so it reads apart from faint day ticks.
  readonly property color underPaceColor: Color.accent
  readonly property color overPaceColor: Color.urgent
  readonly property color paceMarkerColor: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color surface: Color.popups.background
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property real rawPrimaryPercent: hostWidget ? Number(hostWidget.primaryPercent) : -1
  readonly property string resetAt: hostWidget ? String(hostWidget.resetAt || "") : ""
  readonly property string periodStart: hostWidget ? String(hostWidget.periodStart || "") : ""
  readonly property string tierLabel: hostWidget ? String(hostWidget.tierLabel || "") : ""
  readonly property string grokLoginName: hostWidget ? String(hostWidget.grokLoginName || "") : ""
  readonly property string grokLoginEmail: hostWidget ? String(hostWidget.grokLoginEmail || "") : ""
  property bool grokIdentityOpen: false
  property bool grokBotIdentityOpen: false
  property bool cursorIdentityOpen: false
  property bool gptIdentityOpen: false
  property bool settingsOpen: false
  property bool pendingSettingsOpen: false
  property bool refreshing: false
  property double refreshHoldUntilMs: 0
  readonly property string subscriptionPeriodEnd: hostWidget ? String(hostWidget.subscriptionPeriodEnd || "") : ""
  readonly property bool subscriptionCancelsAtEnd: hostWidget ? hostWidget.subscriptionCancelsAtEnd === true : false
  readonly property string usageStatusText: hostWidget ? String(hostWidget.usageStatusText || "") : ""
  readonly property string authHelpText: hostWidget ? String(hostWidget.authHelpText || "") : ""
  readonly property var categories: hostWidget && hostWidget.categories ? hostWidget.categories : []
  readonly property double nowMs: hostWidget ? Number(hostWidget.nowMs) : Date.now()

  readonly property bool grokHasData: rawPrimaryPercent >= 0
  readonly property bool showCursorUsage: hostWidget
    ? hostWidget.showCursorUsage === true
    : !!(settings && settings.showCursorUsage === true)
  readonly property bool showGrokBotUsage: hostWidget
    ? hostWidget.showGrokBotUsage === true
    : !!(settings && settings.showGrokBotUsage === true)
  readonly property bool showGptUsage: hostWidget
    ? hostWidget.showGptUsage === true
    : !!(settings && settings.showGptUsage === true)
  readonly property real cursorAutoPercent: hostWidget ? Number(hostWidget.cursorAutoPercent) : -1
  readonly property real cursorApiPercent: hostWidget ? Number(hostWidget.cursorApiPercent) : -1
  readonly property string cursorResetAt: hostWidget ? String(hostWidget.cursorResetAt || "") : ""
  readonly property string cursorPeriodStart: hostWidget ? String(hostWidget.cursorPeriodStart || "") : ""
  readonly property string cursorTierLabel: hostWidget ? String(hostWidget.cursorTierLabel || "") : ""
  readonly property string cursorLoginName: hostWidget ? String(hostWidget.cursorLoginName || "") : ""
  readonly property string cursorLoginEmail: hostWidget ? String(hostWidget.cursorLoginEmail || "") : ""
  readonly property string cursorUsageStatusText: hostWidget ? String(hostWidget.cursorUsageStatusText || "") : ""
  readonly property string cursorAuthHelpText: hostWidget ? String(hostWidget.cursorAuthHelpText || "") : ""
  readonly property bool cursorHasData: cursorAutoPercent >= 0 || cursorApiPercent >= 0
  readonly property real grokBotPercent: hostWidget ? Number(hostWidget.grokBotPercent) : -1
  readonly property string grokBotResetAt: hostWidget ? String(hostWidget.grokBotResetAt || "") : ""
  readonly property string grokBotPeriodStart: hostWidget ? String(hostWidget.grokBotPeriodStart || "") : ""
  readonly property string grokBotTierLabel: hostWidget ? String(hostWidget.grokBotTierLabel || "") : ""
  readonly property string grokBotUsageStatusText: hostWidget ? String(hostWidget.grokBotUsageStatusText || "") : ""
  readonly property string grokBotAuthHelpText: hostWidget ? String(hostWidget.grokBotAuthHelpText || "") : ""
  readonly property bool grokBotHasData: grokBotPercent >= 0
  readonly property real gptSessionPercent: hostWidget ? Number(hostWidget.gptSessionPercent) : -1
  readonly property real gptWeeklyPercent: hostWidget ? Number(hostWidget.gptWeeklyPercent) : -1
  readonly property string gptSessionResetAt: hostWidget ? String(hostWidget.gptSessionResetAt || "") : ""
  readonly property string gptWeeklyResetAt: hostWidget ? String(hostWidget.gptWeeklyResetAt || "") : ""
  readonly property string gptTierLabel: hostWidget ? String(hostWidget.gptTierLabel || "") : ""
  readonly property string gptLoginName: hostWidget ? String(hostWidget.gptLoginName || "") : ""
  readonly property string gptLoginEmail: hostWidget ? String(hostWidget.gptLoginEmail || "") : ""
  readonly property string gptUsageStatusText: hostWidget ? String(hostWidget.gptUsageStatusText || "") : ""
  readonly property string gptAuthHelpText: hostWidget ? String(hostWidget.gptAuthHelpText || "") : ""
  readonly property bool gptHasData: hostWidget ? hostWidget.gptHasData === true : false

  // TEMP QA hook: force over-pace styling (leave false in production).
  readonly property bool simulateOverPace: false

  // Linear expected usage by now: elapsed / period length (0–1).
  readonly property real expectedPace: {
    if (hostWidget && typeof hostWidget.expectedPace === "number"
        && isFinite(hostWidget.expectedPace) && hostWidget.expectedPace >= 0)
      return Math.max(0, Math.min(1, Number(hostWidget.expectedPace)))
    var start = root.parseTimeMs(periodStart)
    var end = root.parseTimeMs(resetAt)
    if (!(end > 0)) return -1
    if (!(start > 0) || !(start < end))
      start = end - 7 * 24 * 3600 * 1000
    var frac = (nowMs - start) / (end - start)
    if (!isFinite(frac)) return -1
    return Math.max(0, Math.min(1, frac))
  }

  // Displayed usage: when simulating, push past the pace marker (~+15pp, min past pace).
  readonly property real primaryPercent: {
    var raw = rawPrimaryPercent
    if (!root.simulateOverPace || !(raw >= 0) || !(expectedPace >= 0))
      return raw
    var bumped = Math.max(raw, expectedPace + 0.15)
    return Math.max(0, Math.min(1, bumped))
  }

  readonly property bool overPace: expectedPace >= 0 && primaryPercent >= 0
    && primaryPercent > expectedPace + 0.0001
  readonly property color usageFillColor: overPace ? overPaceColor : underPaceColor

  // Non-zero product slices only (matches official Usage card).
  readonly property var productLimits: {
    var out = []
    var cats = root.categories
    if (!cats || !cats.length) return out
    for (var i = 0; i < cats.length; i++) {
      var c = cats[i]
      if (!c) continue
      var pct = Number(c.percent)
      if (!isFinite(pct) || pct <= 0) continue
      out.push({
        title: String(c.title || "Product"),
        type: Number(c.type),
        percent: pct
      })
    }
    out.sort(function(a, b) {
      if (b.percent !== a.percent) return b.percent - a.percent
      return 0
    })
    return out
  }

  // Hero title: subscription type only, e.g. "SuperGrok Heavy"
  readonly property string weeklyTitle: {
    if (tierLabel !== "") return tierLabel
    return "Grok"
  }

  readonly property string grokRebillLabel: root.formatRebillLabel(subscriptionPeriodEnd, subscriptionCancelsAtEnd)
  readonly property string heroMeta: root.clickMeta(
    usageStatusText, resetAt, subscriptionPeriodEnd, subscriptionCancelsAtEnd)
  readonly property real grokMetaOpacity: root.clickMetaOpacity(
    usageStatusText, heroMeta, grokIdentityOpen)

  readonly property bool panelRefreshing: {
    if (root.refreshing) return true
    if (!hostWidget) return false
    if (hostWidget.refreshing === true) return true
    if ((root.showCursorUsage || root.showGrokBotUsage)
        && hostWidget.cursorRefreshing === true)
      return true
    return root.showGptUsage && hostWidget.gptRefreshing === true
  }

  // "23% of weekly limit used"
  readonly property string usedLabel: primaryPercent >= 0
    ? Math.round(primaryPercent * 100) + "% of weekly limit used"
    : ""

  // "Resets Aug 13, 9AM" (short month, no year)
  readonly property string resetsLabel: root.formatResetsLabel(resetAt)

  readonly property bool alarming: primaryPercent >= 0.9

  readonly property real cursorExpectedPace: {
    if (hostWidget && typeof hostWidget.cursorExpectedPace === "number"
        && isFinite(hostWidget.cursorExpectedPace) && hostWidget.cursorExpectedPace >= 0)
      return Math.max(0, Math.min(1, Number(hostWidget.cursorExpectedPace)))
    var start = root.parseTimeMs(cursorPeriodStart)
    var end = root.parseTimeMs(cursorResetAt)
    if (!(end > 0)) return -1
    if (!(start > 0) || !(start < end))
      start = end - 30 * 24 * 3600 * 1000
    var frac = (nowMs - start) / (end - start)
    if (!isFinite(frac)) return -1
    return Math.max(0, Math.min(1, frac))
  }

  readonly property real cursorAutoDisplay: {
    var raw = cursorAutoPercent
    if (!root.simulateOverPace || !(raw >= 0) || !(cursorExpectedPace >= 0))
      return raw
    return Math.max(0, Math.min(1, Math.max(raw, cursorExpectedPace + 0.15)))
  }
  readonly property real cursorApiDisplay: {
    var raw = cursorApiPercent
    if (!root.simulateOverPace || !(raw >= 0) || !(cursorExpectedPace >= 0))
      return raw
    return Math.max(0, Math.min(1, Math.max(raw, cursorExpectedPace + 0.15)))
  }
  readonly property bool cursorAutoOverPace: cursorExpectedPace >= 0 && cursorAutoDisplay >= 0
    && cursorAutoDisplay > cursorExpectedPace + 0.0001
  readonly property bool cursorApiOverPace: cursorExpectedPace >= 0 && cursorApiDisplay >= 0
    && cursorApiDisplay > cursorExpectedPace + 0.0001

  readonly property var cursorPools: {
    var out = []
    if (cursorAutoDisplay >= 0)
      out.push({ title: "Cursor Models", percent: cursorAutoDisplay, overPace: cursorAutoOverPace })
    if (cursorApiDisplay >= 0)
      out.push({ title: "Other Models", percent: cursorApiDisplay, overPace: cursorApiOverPace })
    return out
  }

  readonly property string cursorTitle: cursorTierLabel !== "" ? cursorTierLabel : "Cursor"
  readonly property string cursorRebillLabel: root.formatRebillLabel(cursorResetAt, false)
  readonly property string cursorHeroMeta: root.clickMeta(cursorUsageStatusText, cursorResetAt, "", false)
  readonly property real cursorMetaOpacity: root.clickMetaOpacity(
    cursorUsageStatusText, cursorHeroMeta, cursorIdentityOpen)
  readonly property string cursorResetsLabel: root.formatResetsLabel(cursorResetAt)
  readonly property url cursorIconSource: colorLuminance(surface) >= 0.5
    ? Qt.resolvedUrl("assets/cursor-light.svg")
    : Qt.resolvedUrl("assets/cursor.svg")

  readonly property real grokBotExpectedPace: {
    if (hostWidget && typeof hostWidget.grokBotExpectedPace === "number"
        && isFinite(hostWidget.grokBotExpectedPace) && hostWidget.grokBotExpectedPace >= 0)
      return Math.max(0, Math.min(1, Number(hostWidget.grokBotExpectedPace)))
    var start = root.parseTimeMs(grokBotPeriodStart)
    var end = root.parseTimeMs(grokBotResetAt)
    if (!(end > 0)) return -1
    if (!(start > 0) || !(start < end))
      start = end - 7 * 24 * 3600 * 1000
    var frac = (nowMs - start) / (end - start)
    if (!isFinite(frac)) return -1
    return Math.max(0, Math.min(1, frac))
  }
  readonly property real grokBotDisplay: {
    var raw = grokBotPercent
    if (!root.simulateOverPace || !(raw >= 0) || !(grokBotExpectedPace >= 0))
      return raw
    return Math.max(0, Math.min(1, Math.max(raw, grokBotExpectedPace + 0.15)))
  }
  readonly property bool grokBotOverPace: grokBotExpectedPace >= 0 && grokBotDisplay >= 0
    && grokBotDisplay > grokBotExpectedPace + 0.0001
  readonly property string grokBotTitle: grokBotTierLabel !== "" ? grokBotTierLabel : "Grok Bot"
  readonly property string grokBotHeroMeta: root.clickMeta(grokBotUsageStatusText, grokBotResetAt, "", false)
  readonly property real grokBotMetaOpacity: root.clickMetaOpacity(
    grokBotUsageStatusText, grokBotHeroMeta, grokBotIdentityOpen)
  readonly property string grokBotUsedLabel: grokBotDisplay >= 0
    ? Math.round(grokBotDisplay * 100) + "% of weekly limit used"
    : ""
  readonly property string grokBotResetsLabel: root.formatResetsLabel(grokBotResetAt)
  readonly property bool grokBotAlarming: grokBotDisplay >= 0.9 || grokBotOverPace
  readonly property url grokBotIconSource: colorLuminance(surface) >= 0.5
    ? Qt.resolvedUrl("assets/grok-bot-light.svg")
    : Qt.resolvedUrl("assets/grok-bot.svg")

  readonly property var gptPools: {
    if (hostWidget && hostWidget.gptDisplayLimits)
      return hostWidget.gptDisplayLimits
    return []
  }
  readonly property string gptTitle: gptTierLabel !== "" ? gptTierLabel : "GPT"
  readonly property string gptHeroMeta: {
    var resetIso = hostWidget ? String(hostWidget.gptResetAt || gptSessionResetAt || gptWeeklyResetAt) : (gptSessionResetAt || gptWeeklyResetAt)
    return root.clickMeta(gptUsageStatusText, resetIso, "", false)
  }
  readonly property real gptMetaOpacity: root.clickMetaOpacity(
    gptUsageStatusText, gptHeroMeta, gptIdentityOpen)
  readonly property string gptResetsLabel: {
    if (!hostWidget) return root.formatResetsLabel(gptSessionResetAt || gptWeeklyResetAt)
    return root.formatResetsLabel(String(hostWidget.gptResetAt || gptSessionResetAt || gptWeeklyResetAt))
  }
  readonly property bool gptAlarming: {
    var items = root.gptPools
    for (var i = 0; i < items.length; i++) {
      if (Number(items[i].percent) >= 0.9 || items[i].overPace === true)
        return true
    }
    return false
  }
  readonly property url gptIconSource: colorLuminance(surface) >= 0.5
    ? Qt.resolvedUrl("assets/gpt-light.svg")
    : Qt.resolvedUrl("assets/gpt.svg")

  function windowUsedLabel(item) {
    var title = String((item && item.title) || "Limit")
    var pct = Number(item && item.percent)
    var used = isFinite(pct) && pct >= 0 ? Math.round(pct * 100) + "%" : "—"
    var kind = String((item && item.kind) || "")
    var window = kind === "session" ? "5-hour" : (kind === "month" ? "monthly" : "weekly")
    return title + " · " + used + " of " + window + " limit used"
  }

  function gptWindowUsedLabel(item) {
    var title = String((item && item.title) || "Codex")
    var pct = Number(item && item.percent)
    var usedN = (isFinite(pct) && pct >= 0) ? Math.round(pct * 100) : -1
    var used = usedN >= 0 ? usedN + "%" : "—"
    var left = usedN >= 0 ? Math.max(0, 100 - usedN) + "%" : "—"
    return title + " · " + used + " used · " + left + " left"
  }

  // Product-slice opacities of a pace-aware fill (accent under, urgent over).
  // Bind the base color in the caller (`shadeFill(root.usageFillColor, i)`)
  // so QML tracks it; a cached palette array does not.
  function shadeFill(base, index) {
    var alphas = [1.0, 0.72, 0.50, 0.86, 0.60]
    var i = Math.floor(Number(index))
    if (!isFinite(i) || i < 0) i = 0
    var a = alphas[i % alphas.length]
    return Qt.rgba(base.r, base.g, base.b, a)
  }

  readonly property url iconSource: colorLuminance(surface) >= 0.5
    ? Qt.resolvedUrl("assets/grok-light.svg")
    : Qt.resolvedUrl("assets/grok.svg")

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }

  function parseTimeMs(value) {
    var text = String(value || "").trim()
    if (text === "") return NaN
    var t = new Date(text).getTime()
    return isFinite(t) ? t : NaN
  }

  function colorChannelLuminance(value) {
    var channel = Number(value)
    if (!isFinite(channel)) return 0
    return channel <= 0.03928 ? channel / 12.92 : Math.pow((channel + 0.055) / 1.055, 2.4)
  }

  function colorLuminance(color) {
    return 0.2126 * colorChannelLuminance(color.r)
      + 0.7152 * colorChannelLuminance(color.g)
      + 0.0722 * colorChannelLuminance(color.b)
  }

  function parseResetWhen(iso) {
    var text = String(iso || "").trim()
    if (text === "") return null
    var when = new Date(text)
    var t = when.getTime()
    if (isFinite(t)) return when
    var m = text.match(/^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})/)
    if (!m) return null
    t = Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]),
                 Number(m[4]), Number(m[5]), Number(m[6]))
    when = new Date(t)
    return isFinite(t) ? when : null
  }

  // "Resets Aug 13, 9AM" (local time; minutes only when not :00).
  function formatResetsLabel(iso) {
    var when = root.parseResetWhen(iso)
    if (!when) return ""
    var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    var h = when.getHours()
    var min = when.getMinutes()
    var ampm = h >= 12 ? "PM" : "AM"
    var h12 = h % 12
    if (h12 === 0) h12 = 12
    var timePart = min > 0
      ? (h12 + ":" + (min < 10 ? "0" : "") + min + ampm)
      : (h12 + ampm)
    return "Resets " + months[when.getMonth()] + " " + when.getDate()
      + ", " + timePart
  }

  // Subscription rebill/expiry under the plan title (PanelHero.meta is uppercase).
  function formatRebillLabel(iso, cancels) {
    var when = root.parseResetWhen(iso)
    if (!when) return ""
    var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    var verb = cancels === true ? "Expires" : "Renews"
    return verb + " " + months[when.getMonth()] + " " + when.getDate()
      + ", " + when.getFullYear()
  }

  function isFutureIso(iso) {
    var t = root.parseTimeMs(iso)
    return t > root.nowMs
  }

  // Title-click subtitle: live usage reset, else a future rebill. Never a past date.
  function clickMeta(statusText, resetIso, rebillIso, cancels) {
    if (String(statusText || "") !== "")
      return String(statusText)
    if (root.isFutureIso(resetIso)) {
      var resets = root.formatResetsLabel(resetIso)
      if (resets !== "")
        return resets
    }
    if (root.isFutureIso(rebillIso)) {
      var rebill = root.formatRebillLabel(rebillIso, cancels === true)
      if (rebill !== "")
        return rebill
    }
    return "\u00A0"
  }

  function clickMetaOpacity(statusText, meta, identityOpen) {
    if (String(statusText || "") !== "")
      return 1
    var text = String(meta || "").trim()
    if (identityOpen && text !== "" && text !== "\u00A0")
      return 1
    return 0
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  function syncRefreshing() {
    var live = false
    if (hostWidget) {
      live = hostWidget.refreshing === true
        || ((root.showCursorUsage || root.showGrokBotUsage)
          && hostWidget.cursorRefreshing === true)
        || (root.showGptUsage && hostWidget.gptRefreshing === true)
    }
    if (!live && Date.now() < root.refreshHoldUntilMs)
      live = true
    root.refreshing = live
  }

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    root.refresh()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    root.refresh()
    // Set after showing, not before: showing hands the popout coordinator
    // over, which closes whichever panel was open, and that close clears the
    // shared flag. Deferring means the panel taking over always wins.
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    pageFlip.stop()
    root.grokIdentityOpen = false
    root.grokBotIdentityOpen = false
    root.cursorIdentityOpen = false
    root.gptIdentityOpen = false
    root.settingsOpen = false
    root.pendingSettingsOpen = false
    cardRotation.angle = 0
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function showSettings(open) {
    var next = open === true
    if (root.settingsOpen === next || pageFlip.running) return
    root.pendingSettingsOpen = next
    pageFlip.restart()
  }

  function toggle() {
    if (root.opened) close()
    else openFromHotkey()
  }

  function refresh() {
    if (!hostWidget || typeof hostWidget.refresh !== "function")
      return
    root.refreshHoldUntilMs = Date.now() + 480
    root.refreshing = true
    hostWidget.refresh()
    Qt.callLater(root.syncRefreshing)
  }

  function setShowCursorUsage(on) {
    if (hostWidget && typeof hostWidget.setShowCursorUsage === "function")
      hostWidget.setShowCursorUsage(on)
  }

  function setShowGrokBotUsage(on) {
    if (hostWidget && typeof hostWidget.setShowGrokBotUsage === "function")
      hostWidget.setShowGrokBotUsage(on)
  }

  function setShowGptUsage(on) {
    if (hostWidget && typeof hostWidget.setShowGptUsage === "function")
      hostWidget.setShowGptUsage(on)
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  onHostWidgetChanged: root.syncRefreshing()

  Connections {
    target: root.hostWidget
    enabled: root.hostWidget != null
    function onRefreshingChanged() { root.syncRefreshing() }
    function onCursorRefreshingChanged() { root.syncRefreshing() }
    function onGptRefreshingChanged() { root.syncRefreshing() }
  }

  SequentialAnimation {
    id: pageFlip

    NumberAnimation {
      target: cardRotation
      property: "angle"
      from: 0
      to: 90
      duration: 130
      easing.type: Easing.InQuad
    }
    ScriptAction {
      script: {
        root.settingsOpen = root.pendingSettingsOpen
        cardRotation.angle = -90
      }
    }
    NumberAnimation {
      target: cardRotation
      property: "angle"
      from: -90
      to: 0
      duration: 170
      easing.type: Easing.OutQuad
    }
    ScriptAction {
      script: Qt.callLater(function() {
        if (root.settingsOpen && cursorUsageSetting)
          cursorUsageSetting.forceActiveFocus()
        else if (keyCatcher)
          keyCatcher.forceActiveFocus()
      })
    }
  }

  Timer {
    interval: 80
    running: root.refreshing && root.refreshHoldUntilMs > 0 && root.opened
    repeat: true
    onTriggered: {
      if (Date.now() >= root.refreshHoldUntilMs)
        root.syncRefreshing()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(root.settingsOpen
      ? settingsPage.implicitHeight
      : usagePage.implicitHeight, Style.space(780))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.settingsOpen

      onActivateRequested: if (!root.settingsOpen) root.refresh()
      onCloseRequested: {
        if (root.settingsOpen) root.showSettings(false)
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (root.settingsOpen) return
        if (t === "r" || t === "R") root.refresh()
        else if (t === "g" || t === "G") root.showSettings(true)
      }

      transform: Rotation {
        id: cardRotation
        origin.x: keyCatcher.width / 2
        origin.y: keyCatcher.height / 2
        axis.x: 0
        axis.y: 1
        axis.z: 0
      }

      Column {
        id: usagePage
        visible: !root.settingsOpen
        width: parent.width
        spacing: Style.space(12)

        // Grok card. Hidden when there is nothing to say about Grok.
        Column {
          id: grokCard
          visible: root.grokHasData || root.usageStatusText !== ""
          width: parent.width
          spacing: Style.space(12)

        PlanHeader {
          id: grokHeader
          width: parent.width
          title: root.weeklyTitle
          meta: root.heroMeta
          metaOpacity: root.grokMetaOpacity
          iconSource: root.iconSource
          accountName: root.grokLoginName
          accountEmail: root.grokLoginEmail
          identityVisible: root.grokIdentityOpen
          headerActionsVisible: true
          refreshing: root.panelRefreshing
          foreground: root.foreground
          dim: root.dim
          fontFamily: root.fontFamily
          onIdentityClicked: root.grokIdentityOpen = !root.grokIdentityOpen
          onSettingsClicked: root.showSettings(true)
          onRefreshClicked: root.refresh()
        }

        BorderSurface {
          visible: root.usageStatusText !== ""
          width: parent.width
          implicitHeight: statusText.implicitHeight + Style.spacing.xl * 2
          color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.10)
          borderSpec: Border.flat(Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.35), 1)
          radius: Style.cornerRadius

          Text {
            id: statusText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(12)
            anchors.rightMargin: Style.space(12)
            text: root.authHelpText !== "" ? root.authHelpText : root.usageStatusText
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        PanelSeparator {
          visible: usageSection.visible
          foreground: root.foreground
        }

        // Usage body (no section header — title lives in the hero).
        Column {
          id: usageSection
          visible: root.primaryPercent >= 0
          width: parent.width
          spacing: Style.space(10)

          // "23% used" ……………… "Resets August 13, 2026 at 9:46 PM"
          Item {
            width: parent.width
            implicitHeight: Math.max(usedText.implicitHeight, resetsText.implicitHeight)

            Text {
              id: usedText
              text: root.usedLabel
              color: root.alarming ? root.urgent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              id: resetsText
              visible: text !== ""
              text: root.resetsLabel
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideLeft
              horizontalAlignment: Text.AlignRight
              anchors.right: parent.right
              anchors.left: usedText.right
              anchors.leftMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          // Segmented weekly bar (Chat | Grok Build | …) + day ticks + pace marker.
          SegmentedMeter {
            width: parent.width
            visible: root.productLimits.length > 0 || root.primaryPercent >= 0
            segments: root.productLimits
            totalPercent: root.primaryPercent
            expectedPace: root.expectedPace
            overPace: root.overPace
            fillColor: root.usageFillColor
            paceMarkerColor: root.paceMarkerColor
          }

          // "• Chat 12%  • Grok Build 11%"
          Flow {
            id: legend
            visible: root.productLimits.length > 0
            width: parent.width
            spacing: Style.space(12)

            Repeater {
              model: root.productLimits

              Row {
                required property var modelData
                required property int index
                spacing: Style.space(5)

                Rectangle {
                  width: Style.space(6)
                  height: Style.space(6)
                  radius: width / 2
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.shadeFill(root.usageFillColor, index)
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: (modelData.title || "Product") + " "
                    + Math.round(Number(modelData.percent) * 100) + "%"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  renderType: Text.NativeRendering
                }
              }
            }
          }
        }
        }

        PanelSeparator {
          visible: grokCard.visible && (grokBotCard.visible || cursorCard.visible || gptCard.visible)
          foreground: root.foreground
        }

        Column {
          id: grokBotCard
          visible: root.showGrokBotUsage && (root.grokBotHasData || root.grokBotUsageStatusText !== "")
          width: parent.width
          spacing: Style.space(12)

          PlanHeader {
            id: grokBotHeader
            width: parent.width
            title: root.grokBotTitle
            meta: root.grokBotHeroMeta
            metaOpacity: root.grokBotMetaOpacity
            iconSource: root.grokBotIconSource
            accountName: root.cursorLoginName
            accountEmail: root.cursorLoginEmail
            identityVisible: root.grokBotIdentityOpen
            headerActionsVisible: !grokCard.visible
            refreshing: root.panelRefreshing
            foreground: root.foreground
            dim: root.dim
            fontFamily: root.fontFamily
            onIdentityClicked: root.grokBotIdentityOpen = !root.grokBotIdentityOpen
            onSettingsClicked: root.showSettings(true)
            onRefreshClicked: root.refresh()
          }

          BorderSurface {
            visible: root.grokBotUsageStatusText !== ""
            width: parent.width
            implicitHeight: grokBotStatusText.implicitHeight + Style.spacing.xl * 2
            color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.10)
            borderSpec: Border.flat(Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.35), 1)
            radius: Style.cornerRadius

            Text {
              id: grokBotStatusText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              text: root.grokBotAuthHelpText !== "" ? root.grokBotAuthHelpText : root.grokBotUsageStatusText
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          Column {
            visible: root.grokBotHasData
            width: parent.width
            spacing: Style.space(10)

            Item {
              width: parent.width
              implicitHeight: Math.max(grokBotUsedText.implicitHeight, grokBotResetsText.implicitHeight)

              Text {
                id: grokBotUsedText
                text: root.grokBotUsedLabel
                color: root.grokBotAlarming ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: grokBotResetsText
                visible: text !== ""
                text: root.grokBotResetsLabel
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideLeft
                horizontalAlignment: Text.AlignRight
                anchors.right: parent.right
                anchors.left: grokBotUsedText.right
                anchors.leftMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            SegmentedMeter {
              width: parent.width
              segments: []
              totalPercent: root.grokBotDisplay
              expectedPace: root.grokBotExpectedPace
              overPace: root.grokBotOverPace
              fillColor: root.grokBotOverPace ? root.overPaceColor : root.underPaceColor
              paceMarkerColor: root.paceMarkerColor
              dayCount: 7
            }
          }
        }

        PanelSeparator {
          visible: grokBotCard.visible && (cursorCard.visible || gptCard.visible)
          foreground: root.foreground
        }

        Column {
          id: cursorCard
          visible: root.showCursorUsage && (root.cursorHasData || root.cursorUsageStatusText !== "")
          width: parent.width
          spacing: Style.space(12)

          PlanHeader {
            id: cursorHeader
            width: parent.width
            title: root.cursorTitle
            meta: root.cursorHeroMeta
            metaOpacity: root.cursorMetaOpacity
            iconSource: root.cursorIconSource
            accountName: root.cursorLoginName
            accountEmail: root.cursorLoginEmail
            identityVisible: root.cursorIdentityOpen
            headerActionsVisible: !grokCard.visible && !grokBotCard.visible
            refreshing: root.panelRefreshing
            foreground: root.foreground
            dim: root.dim
            fontFamily: root.fontFamily
            onIdentityClicked: root.cursorIdentityOpen = !root.cursorIdentityOpen
            onSettingsClicked: root.showSettings(true)
            onRefreshClicked: root.refresh()
          }

          BorderSurface {
            visible: root.cursorUsageStatusText !== ""
            width: parent.width
            implicitHeight: cursorStatusText.implicitHeight + Style.spacing.xl * 2
            color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.10)
            borderSpec: Border.flat(Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.35), 1)
            radius: Style.cornerRadius

            Text {
              id: cursorStatusText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              text: root.cursorAuthHelpText !== "" ? root.cursorAuthHelpText : root.cursorUsageStatusText
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          Column {
            visible: root.cursorHasData
            width: parent.width
            spacing: Style.space(10)

            Repeater {
              model: root.cursorPools

              Column {
                required property var modelData
                required property int index
                width: cursorCard.width
                spacing: Style.space(6)

                Item {
                  width: parent.width
                  implicitHeight: Math.max(poolUsedText.implicitHeight, poolResetText.implicitHeight)

                  Text {
                    id: poolUsedText
                    width: parent.width
                      - (poolResetText.visible ? poolResetText.implicitWidth + Style.space(10) : 0)
                    text: (modelData.title || "Pool") + " · "
                      + Math.round(Number(modelData.percent) * 100) + "% of monthly limit used"
                    color: (modelData.overPace || Number(modelData.percent) >= 0.9)
                      ? root.urgent : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                  }

                  Text {
                    id: poolResetText
                    visible: index === 0 && root.cursorResetsLabel !== ""
                    text: root.cursorResetsLabel
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideLeft
                    horizontalAlignment: Text.AlignRight
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                SegmentedMeter {
                  width: parent.width
                  segments: []
                  totalPercent: Number(modelData.percent)
                  expectedPace: root.cursorExpectedPace
                  overPace: modelData.overPace === true
                  fillColor: modelData.overPace ? root.overPaceColor : root.underPaceColor
                  paceMarkerColor: root.paceMarkerColor
                  dayCount: 0
                }
              }
            }
          }
        }

        PanelSeparator {
          visible: cursorCard.visible && gptCard.visible
          foreground: root.foreground
        }

        Column {
          id: gptCard
          visible: root.showGptUsage && (root.gptHasData || root.gptUsageStatusText !== "")
          width: parent.width
          spacing: Style.space(12)

          PlanHeader {
            id: gptHeader
            width: parent.width
            title: root.gptTitle
            meta: root.gptHeroMeta
            metaOpacity: root.gptMetaOpacity
            iconSource: root.gptIconSource
            accountName: root.gptLoginName
            accountEmail: root.gptLoginEmail
            identityVisible: root.gptIdentityOpen
            headerActionsVisible: !grokCard.visible && !grokBotCard.visible && !cursorCard.visible
            refreshing: root.panelRefreshing
            foreground: root.foreground
            dim: root.dim
            fontFamily: root.fontFamily
            onIdentityClicked: root.gptIdentityOpen = !root.gptIdentityOpen
            onSettingsClicked: root.showSettings(true)
            onRefreshClicked: root.refresh()
          }

          BorderSurface {
            visible: root.gptUsageStatusText !== ""
            width: parent.width
            implicitHeight: gptStatusText.implicitHeight + Style.spacing.xl * 2
            color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.10)
            borderSpec: Border.flat(Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.35), 1)
            radius: Style.cornerRadius

            Text {
              id: gptStatusText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              text: root.gptAuthHelpText !== "" ? root.gptAuthHelpText : root.gptUsageStatusText
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          Column {
            visible: root.gptHasData
            width: parent.width
            spacing: Style.space(10)

            Repeater {
              model: root.gptPools

              Column {
                required property var modelData
                required property int index
                width: gptCard.width
                spacing: Style.space(6)

                Item {
                  width: parent.width
                  implicitHeight: Math.max(gptPoolUsedText.implicitHeight, gptPoolResetText.implicitHeight)

                  Text {
                    id: gptPoolUsedText
                    width: parent.width
                      - (gptPoolResetText.visible ? gptPoolResetText.implicitWidth + Style.space(10) : 0)
                    text: root.gptWindowUsedLabel(modelData)
                    color: (modelData.overPace === true || Number(modelData.percent) >= 0.9)
                      ? root.urgent : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                  }

                  Text {
                    id: gptPoolResetText
                    visible: root.formatResetsLabel(modelData.resetAt) !== ""
                    text: root.formatResetsLabel(modelData.resetAt)
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideLeft
                    horizontalAlignment: Text.AlignRight
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                SegmentedMeter {
                  width: parent.width
                  segments: []
                  totalPercent: Number(modelData.percent)
                  expectedPace: Number(modelData.expectedPace)
                  overPace: modelData.overPace === true
                  fillColor: modelData.overPace ? root.overPaceColor : root.underPaceColor
                  paceMarkerColor: root.paceMarkerColor
                  dayCount: Number(modelData.dayCount) || 0
                }
              }
            }
          }
        }
      }

      Column {
        id: settingsPage
        visible: root.settingsOpen
        width: parent.width
        spacing: Style.space(12)
        Keys.priority: Keys.AfterItem
        Keys.onEscapePressed: function(event) {
          root.showSettings(false)
          event.accepted = true
        }

        Item {
          width: parent.width
          implicitHeight: Math.max(settingsBackButton.implicitHeight, settingsLabels.implicitHeight)

          PanelActionButton {
            id: settingsBackButton
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰁍"
            tooltipText: "Back to usage"
            foreground: root.foreground
            focusable: true
            fontFamily: root.fontFamily
            onClicked: root.showSettings(false)
          }

          Column {
            id: settingsLabels
            anchors.left: settingsBackButton.right
            anchors.leftMargin: Style.space(10)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(3)

            Text {
              text: "SETTINGS"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }
          }
        }

        PanelSeparator {
          foreground: root.foreground
        }

        Toggle {
          id: cursorUsageSetting
          width: parent.width
          label: "Cursor usage"
          description: "Show Cursor monthly usage on the bar when the Cursor account matches Grok."
          checked: root.showCursorUsage
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.setShowCursorUsage(!root.showCursorUsage)
        }

        Toggle {
          id: grokBotUsageSetting
          width: parent.width
          label: "Grok Bot usage"
          description: "Show Grok Bot weekly usage on the bar when the Cursor account matches Grok."
          checked: root.showGrokBotUsage
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.setShowGrokBotUsage(!root.showGrokBotUsage)
        }

        Toggle {
          id: gptUsageSetting
          width: parent.width
          label: "GPT usage"
          description: "Show GPT usage from the local Codex session. Off by default."
          checked: root.showGptUsage
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.setShowGptUsage(!root.showGptUsage)
        }
      }
    }
  }

  // Icon is centered on the title row so the plan name lines up with the logo.
  // Gear and reload stay on the title row (HEY's trailing actions). Renewal
  // sits on the subtitle row, which runs under the buttons so they cannot
  // clip "Renews …".
  // Plan name, meta, and account identity are API strings: PlainText so
  // QML AutoText cannot treat crafted <img src> markup as a resource fetch.
  component PlanHeader: Item {
    id: hdr
    property string title: ""
    property string meta: ""
    property real metaOpacity: 0
    property url iconSource
    property string accountName: ""
    property string accountEmail: ""
    property bool identityVisible: false
    property bool headerActionsVisible: false
    property bool refreshing: false
    property color foreground: Color.foreground
    property color dim: Color.foreground
    property string fontFamily: Style.font.family

    signal identityClicked()
    signal settingsClicked()
    signal refreshClicked()

    readonly property bool showIdentity: identityVisible
      && (accountName !== "" || accountEmail !== "")
    readonly property string nameLine: accountName !== "" ? accountName : accountEmail
    readonly property string emailLine: accountName !== "" ? accountEmail : ""

    implicitHeight: Math.max(iconBox.height, titleText.height + Style.space(2)
      + Math.max(metaText.implicitHeight, emailText.visible ? emailText.implicitHeight : 0),
      refreshButton.implicitHeight)

    Item {
      id: iconBox
      width: Style.font.display
      height: titleText.height
      anchors.left: parent.left
      anchors.top: parent.top

      Image {
        anchors.centerIn: parent
        source: hdr.iconSource
        width: Style.font.display
        height: Style.font.display
        sourceSize.width: Style.font.display * 2
        sourceSize.height: Style.font.display * 2
        fillMode: Image.PreserveAspectFit
      }
    }

    Text {
      id: titleText
      anchors.left: iconBox.right
      anchors.leftMargin: Style.space(14)
      anchors.right: nameText.visible ? nameText.left : (hdr.headerActionsVisible ? settingsButton.left : parent.right)
      anchors.rightMargin: Style.space(12)
      anchors.top: parent.top
      text: hdr.title
      textFormat: Text.PlainText
      color: hdr.foreground
      font.family: hdr.fontFamily
      font.pixelSize: Style.font.title
      font.bold: true
      elide: Text.ElideRight
    }

    Text {
      id: metaText
      anchors.left: titleText.left
      anchors.right: emailText.visible ? emailText.left : parent.right
      anchors.rightMargin: emailText.visible ? Style.space(10) : 0
      anchors.top: titleText.bottom
      anchors.topMargin: Style.space(2)
      text: hdr.meta !== "" ? hdr.meta.toUpperCase() : "\u00A0"
      textFormat: Text.PlainText
      opacity: hdr.metaOpacity
      color: hdr.dim
      font.family: hdr.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1.2
      wrapMode: Text.NoWrap
      elide: Text.ElideRight
    }

    MouseArea {
      anchors.left: parent.left
      anchors.right: nameText.visible ? nameText.left : (hdr.headerActionsVisible ? settingsButton.left : parent.right)
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: hdr.identityClicked()
    }

    Text {
      id: nameText
      visible: hdr.showIdentity && hdr.nameLine !== ""
      anchors.right: hdr.headerActionsVisible ? settingsButton.left : parent.right
      anchors.rightMargin: hdr.headerActionsVisible ? Style.space(8) : 0
      anchors.verticalCenter: titleText.verticalCenter
      z: 1
      width: Math.min(implicitWidth, Math.max(Style.space(80), parent.width * 0.38))
      text: hdr.nameLine
      textFormat: Text.PlainText
      color: hdr.foreground
      font.family: hdr.fontFamily
      font.pixelSize: Style.font.title
      font.bold: true
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideRight

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: hdr.identityClicked()
      }
    }

    Text {
      id: emailText
      visible: hdr.showIdentity && hdr.emailLine !== ""
      anchors.right: parent.right
      anchors.top: titleText.bottom
      anchors.topMargin: Style.space(2)
      z: 1
      width: Math.min(implicitWidth, parent.width)
      text: hdr.emailLine
      textFormat: Text.PlainText
      color: hdr.dim
      font.family: hdr.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1.2
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideRight

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: hdr.identityClicked()
      }
    }

    PanelActionButton {
      id: settingsButton
      visible: hdr.headerActionsVisible
      anchors.right: refreshButton.left
      anchors.rightMargin: Style.space(4)
      anchors.verticalCenter: titleText.verticalCenter
      z: 1
      iconText: "󰒓"
      tooltipText: "Usage settings"
      foreground: hdr.foreground
      fontFamily: hdr.fontFamily
      onClicked: hdr.settingsClicked()
    }

    PanelActionButton {
      id: refreshButton
      visible: hdr.headerActionsVisible
      anchors.right: parent.right
      anchors.verticalCenter: titleText.verticalCenter
      z: 1
      iconText: hdr.refreshing ? "󰑓" : "󰑐"
      foreground: hdr.foreground
      fontFamily: hdr.fontFamily
      enabled: !hdr.refreshing
      onClicked: hdr.refreshClicked()
    }
  }

  // Full-width track with product slices left-to-right (pool fractions).
  // Day ticks + expected-pace marker (elapsed / period).
  // Fill is accent while usage is behind the pace marker, urgent once it
  // crosses — compared here so the color cannot drift from the bar.
  component SegmentedMeter: Item {
    id: meter
    property var segments: []
    property real totalPercent: -1
    property real expectedPace: -1
    property bool overPace: false
    property color fillColor: root.underPaceColor
    property color paceMarkerColor: root.paceMarkerColor
    // SuperGrok weekly pool = 7 calendar days.
    property int dayCount: 7
    property real thickness: Math.max(Style.space(6), Math.round(Style.spacing.controlHeight * 0.18))

    implicitHeight: thickness

    // dayCount < 2 → no ticks (monthly Cursor pools use dayCount: 0).
    readonly property int dayMarkerCount: dayCount >= 2 ? dayCount - 1 : 0

    readonly property real usedFraction: {
      if (meter.totalPercent >= 0) return root.clamp(meter.totalPercent, 0, 1)
      var sum = 0
      var segs = meter.segments || []
      for (var i = 0; i < segs.length; i++) {
        var p = Number(segs[i] && segs[i].percent)
        if (isFinite(p) && p > 0) sum += p
      }
      return root.clamp(sum, 0, 1)
    }

    readonly property real paceFraction: {
      var p = Number(meter.expectedPace)
      if (!isFinite(p) || p < 0) return -1
      return root.clamp(p, 0, 1)
    }

    // Visual truth: the used fill has crossed the expected-pace marker.
    readonly property bool pastPace: {
      if (meter.overPace === true) return true
      var used = meter.usedFraction
      var pace = meter.paceFraction
      return pace >= 0 && used > pace + 0.0001
    }
    readonly property color usedFill: meter.pastPace ? root.overPaceColor : meter.fillColor

    // Day ticks: fainter on empty track, inverted/higher-contrast over used fill.
    readonly property color dayMarkerOnTrack: Qt.rgba(
      root.foreground.r, root.foreground.g, root.foreground.b, 0.28)
    readonly property color dayMarkerOnFill: Qt.rgba(
      root.track.r, root.track.g, root.track.b, 0.72)

    Rectangle {
      id: meterTrack
      anchors.fill: parent
      radius: height / 2
      color: root.track
      clip: true

      Row {
        id: fillRow
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        height: parent.height
        width: parent.width * meter.usedFraction
        z: 1

        Repeater {
          model: meter.segments

          Rectangle {
            required property var modelData
            required property int index
            readonly property real pct: {
              var p = Number(modelData && modelData.percent)
              return isFinite(p) && p > 0 ? p : 0
            }
            width: {
              var used = meter.usedFraction
              if (!(used > 0) || !(pct > 0)) return 0
              return fillRow.width * (pct / used)
            }
            height: parent.height
            color: root.shadeFill(meter.usedFill, index)
          }
        }

        // Solid fill when we have total % but no product slices yet.
        Rectangle {
          visible: (!meter.segments || meter.segments.length === 0) && meter.usedFraction > 0
          width: fillRow.width
          height: parent.height
          color: meter.usedFill
        }
      }

      // Day boundary ticks at 1/N … (N-1)/N of the full week width.
      Item {
        id: dayMarkers
        anchors.fill: parent
        z: 2

        Repeater {
          model: meter.dayMarkerCount

          Rectangle {
            required property int index
            readonly property real dayFraction: (index + 1) / meter.dayCount
            readonly property bool overUsed: dayFraction <= meter.usedFraction + 0.0001

            width: Math.max(1, Math.round(Style.space(1)))
            height: Math.max(2, Math.round(parent.height * 0.78))
            radius: width / 2
            anchors.verticalCenter: parent.verticalCenter
            x: Math.round(parent.width * dayFraction - width / 2)
            color: overUsed ? meter.dayMarkerOnFill : meter.dayMarkerOnTrack
          }
        }
      }

      // Expected-pace marker: where linear usage "should" be right now.
      // Stronger than day ticks (solid accent, slightly wider, full height).
      Rectangle {
        id: paceMarker
        visible: meter.paceFraction >= 0
        z: 3
        width: Math.max(2, Math.round(Style.space(2)))
        height: parent.height
        radius: width / 2
        anchors.verticalCenter: parent.verticalCenter
        x: Math.round(parent.width * meter.paceFraction - width / 2)
        color: meter.paceMarkerColor
      }
    }
  }
}
