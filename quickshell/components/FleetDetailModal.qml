import QtQuick
import "../state/ThemePalette.js" as ThemePalette

Rectangle {
    id: root

    objectName: "fleetDetailModal"

    property bool open: false
    property string activeTab: "fleet"
    property var devices: []
    property var agents: []
    property var usage: ({"providers": []})
    property string managerLabel: "T3 CODE"
    property var theme: ThemePalette.fallback
    property bool reducedMotion: false
    property int clockTick: 0

    signal closeRequested()
    signal interactionOccurred()
    signal tabSelected(string tab)

    readonly property var normalizedDevices:
        Array.isArray(devices) ? devices : []
    readonly property var normalizedProviders:
        usage !== null && usage !== undefined && Array.isArray(usage.providers)
            ? usage.providers
            : []
    readonly property bool hasUnpairedOnlineRemote: {
        for (var i = 0; i < normalizedDevices.length; i += 1) {
            var dev = normalizedDevices[i]
            if (String(dev.state || "") === "online"
                    && dev.local !== true
                    && String(dev.feed_state || "") === "unpaired")
                return true
        }
        return false
    }

    visible: open
    enabled: open
    width: 1880
    height: 556
    radius: 22
    color: root.theme.surface
    border.width: 1
    border.color: root.theme.accent
    clip: true

    function deviceCounts() {
        var online = 0
        var offline = 0
        for (var i = 0; i < normalizedDevices.length; i += 1) {
            var state = String(normalizedDevices[i].state || "").toLowerCase()
            if (state === "online")
                online += 1
            else if (state === "offline")
                offline += 1
        }
        return {
            "total": normalizedDevices.length,
            "online": online,
            "offline": offline
        }
    }

    function liveProviderCount() {
        var live = 0
        for (var i = 0; i < normalizedProviders.length; i += 1) {
            if (normalizedProviders[i].available === true)
                live += 1
        }
        return live
    }

    function providerAccent(id) {
        switch (String(id || "").toLowerCase()) {
        case "claude":
            return root.theme.orange
        case "codex":
            return root.theme.green
        case "gemini":
            return root.theme.cyan
        case "grok":
            return root.theme.yellow
        case "cursor":
            return root.theme.blue
        default:
            return root.theme.magenta
        }
    }

    function percent(window) {
        if (window === null || window === undefined)
            return 0
        return Math.max(
            0,
            Math.min(100, Math.round(Number(window.utilization || 0) * 100))
        )
    }

    function resetLabel(window) {
        clockTick
        if (window === null || window === undefined
                || Number(window.reset_at_ms || 0) <= 0)
            return "NO RESET"
        var remaining = Math.max(
            0,
            Math.floor((Number(window.reset_at_ms) - Date.now()) / 60000)
        )
        if (remaining >= 1440)
            return "RESET " + Math.floor(remaining / 1440) + "D "
                + Math.floor((remaining % 1440) / 60) + "H"
        if (remaining >= 60)
            return "RESET " + Math.floor(remaining / 60) + "H "
                + (remaining % 60) + "M"
        return "RESET " + remaining + "M"
    }

    function ageLabel(prefix, timestampMs) {
        clockTick
        var ts = Number(timestampMs || 0)
        if (ts <= 0)
            return prefix + " UNKNOWN"
        var minutes = Math.max(0, Math.floor((Date.now() - ts) / 60000))
        if (minutes < 1)
            return prefix + " NOW"
        if (minutes < 60)
            return prefix + " " + minutes + "M AGO"
        if (minutes < 1440)
            return prefix + " " + Math.floor(minutes / 60) + "H AGO"
        return prefix + " " + Math.floor(minutes / 1440) + "D AGO"
    }

    function formatTokens(value) {
        var count = Math.max(0, Number(value || 0))
        if (count >= 1000000000)
            return (count / 1000000000).toFixed(
                count >= 10000000000 ? 1 : 2
            ) + "B"
        if (count >= 1000000)
            return (count / 1000000).toFixed(
                count >= 100000000 ? 0 : count >= 10000000 ? 1 : 2
            ) + "M"
        if (count >= 1000)
            return (count / 1000).toFixed(count >= 100000 ? 0 : 1) + "K"
        return Math.floor(count).toString()
    }

    function feedBadgeText(device) {
        var state = String(device.state || "unknown").toLowerCase()
        if (state === "offline")
            return "OFFLINE"
        if (device.local === true)
            return "LOCAL SQLITE"
        var feed = String(device.feed_state || "").toLowerCase()
        if (feed === "live")
            return "REMOTE LIVE"
        if (feed === "unpaired")
            return "PAIR FOR THREADS"
        return "CONNECTED"
    }

    function providerMeta(provider) {
        var parts = []
        var plan = String(provider.plan || "").trim()
        if (plan !== "")
            parts.push(plan.toUpperCase())
        var count = Math.floor(Number(provider.account_count || 0))
        if (count > 1)
            parts.push(count + " ACCOUNTS")
        var source = String(provider.source || "").trim().toUpperCase()
        if (source !== "" && source !== "UNAVAILABLE" && source !== "UNKNOWN")
            parts.push(source)
        return parts.length > 0 ? parts.join(" · ") : "UNAVAILABLE"
    }

    function providerStatusText(provider) {
        if (!provider.available)
            return "NO DATA"
        if (provider.stale)
            return "STALE"
        if (provider.status === "allowed_warning")
            return "WARNING"
        return "LIVE"
    }

    function readableOn(fg, bg) {
        return ThemePalette.ensureContrast(String(fg), String(bg), 4.5)
    }

    Timer {
        interval: 60000
        running: root.open
        repeat: true
        triggeredOnStart: true
        onTriggered: root.clockTick += 1
    }

    // Consume taps inside the modal so they never dismiss through the backdrop.
    TapHandler {
        gesturePolicy: TapHandler.ReleaseWithinBounds
        onTapped: root.interactionOccurred()
    }

    Item {
        id: modalHeader

        anchors {
            left: parent.left
            right: parent.right
            top: parent.top
            leftMargin: 28
            rightMargin: 28
            topMargin: 22
        }
        height: 48

        Row {
            id: tabRow

            anchors {
                left: parent.left
                verticalCenter: parent.verticalCenter
            }
            spacing: 12

            Rectangle {
                id: fleetTabButton

                objectName: "detailTabFleet"
                readonly property bool selected: root.activeTab === "fleet"
                readonly property color fill: selected
                    ? ThemePalette.mixColors(
                        String(root.theme.surfaceRaised),
                        String(root.theme.accent),
                        0.18
                    )
                    : root.theme.surfaceRaised

                width: 244
                height: 44
                radius: 12
                color: fill
                border.width: 1
                border.color: selected ? root.theme.accent : root.theme.border

                function activate() {
                    if (!root.open)
                        return false
                    root.interactionOccurred()
                    root.tabSelected("fleet")
                    return true
                }

                Accessible.role: Accessible.Button
                Accessible.ignored: !root.open
                Accessible.name: "Fleet devices tab"
                Accessible.onPressAction: activate()

                Text {
                    anchors.centerIn: parent
                    text: root.managerLabel + " DEVICES ("
                        + root.normalizedDevices.length + ")"
                    textFormat: Text.PlainText
                    color: fleetTabButton.selected
                        ? root.readableOn(root.theme.accent, fleetTabButton.fill)
                        : root.theme.textSecondary
                    font {
                        family: "monospace"
                        pixelSize: 13
                        weight: Font.Bold
                        letterSpacing: 0.7
                    }
                }

                TapHandler {
                    gesturePolicy: TapHandler.ReleaseWithinBounds
                    onTapped: fleetTabButton.activate()
                }
            }

            Rectangle {
                id: usageTabButton

                objectName: "detailTabUsage"
                readonly property bool selected: root.activeTab === "usage"
                readonly property color fill: selected
                    ? ThemePalette.mixColors(
                        String(root.theme.surfaceRaised),
                        String(root.theme.accent),
                        0.18
                    )
                    : root.theme.surfaceRaised

                width: 224
                height: 44
                radius: 12
                color: fill
                border.width: 1
                border.color: selected ? root.theme.accent : root.theme.border

                function activate() {
                    if (!root.open)
                        return false
                    root.interactionOccurred()
                    root.tabSelected("usage")
                    return true
                }

                Accessible.role: Accessible.Button
                Accessible.ignored: !root.open
                Accessible.name: "AI capacity tab"
                Accessible.onPressAction: activate()

                Text {
                    anchors.centerIn: parent
                    text: "AI CAPACITY (" + root.normalizedProviders.length + ")"
                    textFormat: Text.PlainText
                    color: usageTabButton.selected
                        ? root.readableOn(root.theme.accent, usageTabButton.fill)
                        : root.theme.textSecondary
                    font {
                        family: "monospace"
                        pixelSize: 13
                        weight: Font.Bold
                        letterSpacing: 0.7
                    }
                }

                TapHandler {
                    gesturePolicy: TapHandler.ReleaseWithinBounds
                    onTapped: usageTabButton.activate()
                }
            }
        }

        Text {
            objectName: "detailModalSummary"
            anchors {
                left: tabRow.right
                right: closeButton.left
                leftMargin: 24
                rightMargin: 24
                verticalCenter: parent.verticalCenter
            }
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            text: {
                if (root.activeTab === "fleet") {
                    var counts = root.deviceCounts()
                    return counts.online + " ONLINE  ·  "
                        + counts.offline + " OFFLINE  ·  "
                        + (Array.isArray(root.agents) ? root.agents.length : 0)
                        + " ACTIVE AGENTS"
                }
                return root.liveProviderCount() + " LIVE PROVIDERS  ·  "
                    + "CLIPROXYAPI + OMARCHY AGENTS"
            }
            textFormat: Text.PlainText
            color: root.theme.textSecondary
            font {
                family: "monospace"
                pixelSize: 13
                weight: Font.DemiBold
                letterSpacing: 0.8
            }
        }

        Rectangle {
            id: closeButton

            objectName: "detailModalCloseButton"
            anchors {
                right: parent.right
                verticalCenter: parent.verticalCenter
            }
            width: 112
            height: 44
            radius: 12
            color: closeTap.pressed
                ? root.theme.surfacePressed
                : root.theme.surfaceRaised
            border.width: 1
            border.color: root.theme.border

            function activate() {
                if (!root.open)
                    return false
                root.interactionOccurred()
                root.closeRequested()
                return true
            }

            Accessible.role: Accessible.Button
            Accessible.ignored: !root.open
            Accessible.name: "Close detail modal"
            Accessible.onPressAction: activate()

            Text {
                anchors.centerIn: parent
                text: "CLOSE"
                textFormat: Text.PlainText
                color: root.theme.textPrimary
                font {
                    family: "monospace"
                    pixelSize: 13
                    weight: Font.Bold
                    letterSpacing: 0.8
                }
            }

            TapHandler {
                id: closeTap
                gesturePolicy: TapHandler.ReleaseWithinBounds
                onTapped: closeButton.activate()
            }
        }
    }

    Rectangle {
        id: headerDivider

        anchors {
            left: parent.left
            right: parent.right
            top: modalHeader.bottom
            leftMargin: 28
            rightMargin: 28
            topMargin: 14
        }
        height: 1
        color: root.theme.border
    }

    Item {
        id: fleetPane

        objectName: "detailFleetPane"
        visible: root.activeTab === "fleet"
        anchors {
            left: parent.left
            right: parent.right
            top: headerDivider.bottom
            bottom: parent.bottom
            leftMargin: 28
            rightMargin: 28
            topMargin: 16
            bottomMargin: 20
        }

        Grid {
            id: deviceGrid

            anchors {
                left: parent.left
                right: parent.right
                top: parent.top
            }
            columns: 3
            columnSpacing: 14
            rowSpacing: 14
            visible: root.normalizedDevices.length > 0

            Repeater {
                model: root.normalizedDevices.slice(0, 12)

                Rectangle {
                    required property var modelData
                    required property int index

                    readonly property string stateStr:
                        String(modelData.state || "unknown").toLowerCase()
                    readonly property bool online: stateStr === "online"
                    readonly property bool offline: stateStr === "offline"
                    readonly property color tone: online
                        ? root.theme.success
                        : offline
                            ? root.theme.error
                            : root.theme.needsHelp
                    readonly property color cardFill: online
                        ? ThemePalette.mixColors(
                            String(root.theme.surfaceRaised),
                            String(root.theme.success),
                            0.07
                        )
                        : ThemePalette.mixColors(
                            String(root.theme.surface),
                            String(root.theme.surfaceRaised),
                            0.55
                        )
                    readonly property color readableTone:
                        root.readableOn(tone, cardFill)

                    objectName: "fleetDetailDevice-" + index
                    width: (deviceGrid.width - deviceGrid.columnSpacing * 2) / 3
                    height: 92
                    radius: 14
                    color: cardFill
                    border.width: 1
                    border.color: online
                        ? Qt.alpha(tone, 0.5)
                        : root.theme.border

                    Column {
                        anchors {
                            fill: parent
                            leftMargin: 16
                            rightMargin: 16
                            topMargin: 12
                            bottomMargin: 12
                        }
                        spacing: 6

                        Row {
                            width: parent.width
                            height: 22
                            spacing: 10

                            Rectangle {
                                width: 10
                                height: 10
                                radius: 5
                                anchors.verticalCenter: parent.verticalCenter
                                color: parent.parent.parent.tone
                            }

                            Text {
                                width: parent.width - 10 - activeCountText.width
                                    - parent.spacing * 2
                                anchors.verticalCenter: parent.verticalCenter
                                text: String(modelData.label || "DEVICE")
                                    .toUpperCase()
                                textFormat: Text.PlainText
                                color: parent.parent.parent.offline
                                    ? root.theme.textSecondary
                                    : root.theme.textPrimary
                                elide: Text.ElideRight
                                font {
                                    family: "monospace"
                                    pixelSize: 15
                                    weight: Font.Bold
                                    letterSpacing: 0.7
                                }
                            }

                            Text {
                                id: activeCountText

                                anchors.verticalCenter: parent.verticalCenter
                                text: {
                                    if (!parent.parent.parent.online)
                                        return parent.parent.parent.offline
                                            ? "OFFLINE"
                                            : "UNKNOWN"
                                    var active = Math.max(
                                        0,
                                        Math.floor(Number(modelData.agent_count || 0))
                                    )
                                    return active > 0
                                        ? active + " ACTIVE"
                                        : "ONLINE"
                                }
                                textFormat: Text.PlainText
                                color: parent.parent.parent.readableTone
                                font {
                                    family: "monospace"
                                    pixelSize: 11
                                    weight: Font.Bold
                                    letterSpacing: 0.6
                                }
                            }
                        }

                        Text {
                            width: parent.width
                            text: (modelData.local === true ? "LOCAL HOST" : "REMOTE HOST")
                                + (String(modelData.machine || "") !== ""
                                    ? "  ·  " + String(modelData.machine).toUpperCase()
                                    : "")
                            textFormat: Text.PlainText
                            color: root.theme.textMuted
                            elide: Text.ElideRight
                            font {
                                family: "monospace"
                                pixelSize: 11
                                letterSpacing: 0.5
                            }
                        }

                        Row {
                            width: parent.width
                            spacing: 8

                            Text {
                                width: parent.width - checkedText.width - 8
                                text: root.feedBadgeText(modelData)
                                textFormat: Text.PlainText
                                color: String(modelData.feed_state || "") === "unpaired"
                                    ? root.readableOn(
                                        root.theme.needsHelp,
                                        parent.parent.parent.cardFill
                                    )
                                    : root.theme.textSecondary
                                elide: Text.ElideRight
                                font {
                                    family: "monospace"
                                    pixelSize: 10
                                    weight: Font.DemiBold
                                    letterSpacing: 0.4
                                }
                            }

                            Text {
                                id: checkedText

                                text: root.ageLabel("CHECKED", modelData.last_checked_ms)
                                textFormat: Text.PlainText
                                color: root.theme.textMuted
                                font {
                                    family: "monospace"
                                    pixelSize: 10
                                    letterSpacing: 0.3
                                }
                            }
                        }
                    }
                }
            }
        }

        Text {
            visible: root.normalizedDevices.length === 0
            anchors.centerIn: parent
            text: "NO FLEET DEVICES REPORTED FOR THE ACTIVE MANAGER"
            textFormat: Text.PlainText
            color: root.theme.textMuted
            font {
                family: "monospace"
                pixelSize: 15
                letterSpacing: 1
            }
        }

        Text {
            visible: root.hasUnpairedOnlineRemote
            anchors {
                left: parent.left
                right: parent.right
                bottom: parent.bottom
            }
            horizontalAlignment: Text.AlignHCenter
            text: "REMOTE THREADS: ISSUE A READ-ONLY TOKEN ON A REMOTE HOST, THEN RUN  xeneon-t3-status pair <device>"
            textFormat: Text.PlainText
            color: root.theme.textMuted
            elide: Text.ElideRight
            font {
                family: "monospace"
                pixelSize: 11
                letterSpacing: 0.5
            }
        }
    }

    Item {
        id: usagePane

        objectName: "detailUsagePane"
        visible: root.activeTab === "usage"
        anchors {
            left: parent.left
            right: parent.right
            top: headerDivider.bottom
            bottom: parent.bottom
            leftMargin: 28
            rightMargin: 28
            topMargin: 16
            bottomMargin: 20
        }

        Grid {
            id: usageGrid

            anchors.fill: parent
            columns: 3
            columnSpacing: 14
            rowSpacing: 14

            Repeater {
                model: root.normalizedProviders.slice(0, 6)

                Rectangle {
                    required property var modelData
                    required property int index

                    readonly property color accent:
                        root.providerAccent(modelData.id)
                    readonly property color cardFill: root.theme.surfaceRaised
                    readonly property var primaryWin:
                        modelData.primary === undefined ? null : modelData.primary
                    readonly property var secondaryWin:
                        modelData.secondary === undefined ? null : modelData.secondary

                    objectName: "usageDetailCard_" + modelData.id
                    width: (usageGrid.width - usageGrid.columnSpacing * 2) / 3
                    height: 196
                    radius: 14
                    color: cardFill
                    border.width: 1
                    border.color: modelData.available === true
                        ? Qt.alpha(accent, modelData.stale ? 0.34 : 0.62)
                        : root.theme.border

                    Column {
                        anchors {
                            fill: parent
                            margins: 16
                        }
                        spacing: 10

                        Row {
                            width: parent.width
                            height: 22
                            spacing: 10

                            Rectangle {
                                width: 10
                                height: 10
                                radius: 5
                                anchors.verticalCenter: parent.verticalCenter
                                color: parent.parent.parent.accent
                            }

                            Text {
                                width: parent.width - 10 - provStatus.width
                                    - parent.spacing * 2
                                anchors.verticalCenter: parent.verticalCenter
                                text: String(modelData.label || modelData.id)
                                    .toUpperCase()
                                textFormat: Text.PlainText
                                color: root.theme.textPrimary
                                elide: Text.ElideRight
                                font {
                                    family: "monospace"
                                    pixelSize: 16
                                    weight: Font.Bold
                                    letterSpacing: 0.7
                                }
                            }

                            Text {
                                id: provStatus

                                anchors.verticalCenter: parent.verticalCenter
                                text: root.providerStatusText(modelData)
                                textFormat: Text.PlainText
                                color: root.readableOn(
                                    modelData.available === true
                                        ? parent.parent.parent.accent
                                        : root.theme.textMuted,
                                    parent.parent.parent.cardFill
                                )
                                font {
                                    family: "monospace"
                                    pixelSize: 11
                                    weight: Font.Bold
                                    letterSpacing: 0.6
                                }
                            }
                        }

                        Text {
                            width: parent.width
                            text: root.providerMeta(modelData)
                            textFormat: Text.PlainText
                            color: root.theme.textMuted
                            elide: Text.ElideRight
                            font {
                                family: "monospace"
                                pixelSize: 11
                                letterSpacing: 0.5
                            }
                        }

                        Column {
                            width: parent.width
                            spacing: 8

                            Repeater {
                                model: {
                                    var wins = []
                                    if (parent.parent.parent.primaryWin !== null)
                                        wins.push(parent.parent.parent.primaryWin)
                                    if (parent.parent.parent.secondaryWin !== null)
                                        wins.push(parent.parent.parent.secondaryWin)
                                    return wins
                                }

                                Column {
                                    required property var modelData
                                    width: parent.width
                                    spacing: 4

                                    Row {
                                        width: parent.width
                                        spacing: 8

                                        Text {
                                            width: parent.width - pctText.width
                                                - resetText.width - 16
                                            text: String(modelData.label || "QUOTA")
                                                .toUpperCase()
                                            textFormat: Text.PlainText
                                            color: root.theme.textSecondary
                                            elide: Text.ElideRight
                                            font {
                                                family: "monospace"
                                                pixelSize: 11
                                                weight: Font.DemiBold
                                            }
                                        }

                                        Text {
                                            id: pctText

                                            text: root.percent(modelData) + "%"
                                            textFormat: Text.PlainText
                                            color: root.readableOn(
                                                parent.parent.parent.parent.parent.accent,
                                                parent.parent.parent.parent.parent.cardFill
                                            )
                                            font {
                                                family: "monospace"
                                                pixelSize: 11
                                                weight: Font.Bold
                                            }
                                        }

                                        Text {
                                            id: resetText

                                            text: root.resetLabel(modelData)
                                            textFormat: Text.PlainText
                                            color: root.theme.textMuted
                                            font {
                                                family: "monospace"
                                                pixelSize: 10
                                            }
                                        }
                                    }

                                    Rectangle {
                                        width: parent.width
                                        height: 7
                                        radius: 3.5
                                        color: root.theme.surface

                                        Rectangle {
                                            width: parent.width
                                                * (root.percent(modelData) / 100)
                                            height: parent.height
                                            radius: parent.radius
                                            color: parent.parent.parent.parent.parent.accent
                                        }
                                    }
                                }
                            }
                        }

                        Row {
                            width: parent.width
                            spacing: 10

                            Text {
                                width: parent.width - updatedText.width - 10
                                text: Number(modelData.today_tokens || 0) > 0
                                    ? "TODAY " + root.formatTokens(modelData.today_tokens)
                                        + " TOKENS"
                                    : (modelData.available === true
                                        ? "NO RECENT TOKEN ACTIVITY"
                                        : "CAPACITY UNAVAILABLE")
                                textFormat: Text.PlainText
                                color: root.theme.textSecondary
                                elide: Text.ElideRight
                                font {
                                    family: "monospace"
                                    pixelSize: 10
                                    weight: Font.DemiBold
                                }
                            }

                            Text {
                                id: updatedText

                                text: root.ageLabel("UPDATED", modelData.last_updated_ms)
                                textFormat: Text.PlainText
                                color: root.theme.textMuted
                                font {
                                    family: "monospace"
                                    pixelSize: 10
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
