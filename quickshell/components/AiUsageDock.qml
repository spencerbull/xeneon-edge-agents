import QtQuick
import "../state/ThemePalette.js" as ThemePalette

Item {
    id: root

    property var usage: ({"providers": []})
    property var theme: ThemePalette.fallback
    property var agents: []
    property var sessions: []
    property var devices: []
    property string managerLabel: "HERDR"
    property bool reducedMotion: false
    property int clockTick: 0

    signal fleetDetailsRequested()
    signal usageDetailsRequested(string providerId)

    readonly property var defaultProviderIds: ["claude", "codex", "opencode"]
    readonly property var providerIds: activeProviderIds()
    readonly property int fleetTileWidth: 346
    readonly property int hiddenProviderCount: Math.max(
        0,
        allProviders().length - providerIds.length
    )

    function allProviders() {
        return usage !== null
                && usage !== undefined
                && Array.isArray(usage.providers)
            ? usage.providers
            : []
    }

    function activeProviderIds() {
        var providers = allProviders()
        var availableIds = []
        var fallbackIds = []
        for (var index = 0; index < providers.length; index += 1) {
            var id = String(providers[index].id || "")
            if (id === "")
                continue
            if (providers[index].available === true)
                availableIds.push(id)
            else
                fallbackIds.push(id)
        }
        if (availableIds.length > 0) {
            // Show up to 4 live providers (no dead NO DATA boxes when live ones exist).
            if (availableIds.length >= 3)
                return availableIds.slice(0, 4)
            return availableIds.concat(fallbackIds).slice(0, 3)
        }
        return defaultProviderIds
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

    function provider(id) {
        var providers = allProviders()
        for (var index = 0; index < providers.length; index += 1) {
            if (String(providers[index].id || "") === id)
                return providers[index]
        }
        return {
            "id": id,
            "label": id === "opencode" ? "OpenCode"
                : id.charAt(0).toUpperCase() + id.slice(1),
            "kind": id === "opencode" ? "local_budget" : "quota",
            "available": false,
            "stale": true,
            "primary": null,
            "secondary": null,
            "model": "",
            "account_count": 0
        }
    }

    function percent(window) {
        if (window === null)
            return 0
        return Math.max(
            0,
            Math.min(100, Math.round(Number(window.utilization || 0) * 100))
        )
    }

    function resetLabel(window) {
        clockTick
        if (window === null || Number(window.reset_at_ms || 0) <= 0)
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

    function countLabel(count, singular, plural) {
        return count + " " + (count === 1 ? singular : plural)
    }

    function deviceCounts() {
        var total = Array.isArray(devices) ? devices.length : 0
        var online = 0
        var offline = 0
        for (var index = 0; index < total; index += 1) {
            var state = String(devices[index].state || "").toLowerCase()
            if (state === "online")
                online += 1
            else if (state === "offline")
                offline += 1
        }
        return {"total": total, "online": online, "offline": offline}
    }

    function fleetSummary() {
        var counts = deviceCounts()
        if (counts.total > 0) {
            return countLabel(agents.length, "AGENT", "AGENTS")
                + " · " + counts.online + "/" + counts.total
                + " DEVICES ONLINE"
        }
        return countLabel(agents.length, "AGENT", "AGENTS")
            + " · " + countLabel(sessions.length, "SESSION", "SESSIONS")
    }

    function focusedSummary() {
        var counts = deviceCounts()
        if (counts.total > 0) {
            if (counts.online === counts.total)
                return counts.online + " ONLINE · ALL CONNECTED"
            if (counts.offline > 0) {
                return counts.online + " ONLINE · " + counts.offline
                    + " OFFLINE"
            }
            return counts.online + " ONLINE · "
                + (counts.total - counts.online) + " UNKNOWN"
        }
        var focused = 0
        for (var index = 0; index < agents.length; index += 1) {
            if (agents[index].focused === true)
                focused += 1
        }
        return focused > 0
            ? focused + " FOCUSED"
            : "NO FOCUSED AGENT"
    }

    function devicePreviewHosts() {
        var list = Array.isArray(devices) ? devices : []
        return list.slice(0, 3)
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

    function activitySummary(provider) {
        var today = Math.max(0, Number(provider.today_tokens || 0))
        var rate = Math.max(0, Number(provider.tokens_per_hour || 0))
        var fields = []
        if (today > 0)
            fields.push("TODAY " + formatTokens(today))
        if (rate > 0)
            fields.push("RATE " + formatTokens(rate) + "/H")
        if (fields.length > 0)
            return fields.join(" · ")
        if (String(provider.model || "") !== "")
            return String(provider.model).toUpperCase()
        return provider.available
            ? "NO RECENT TOKEN ACTIVITY"
            : "CAPACITY UNAVAILABLE"
    }

    function updatedLabel(provider) {
        clockTick
        var updated = Number(provider.last_updated_ms || 0)
        if (updated <= 0)
            return "UPDATE UNKNOWN"
        var minutes = Math.max(
            0,
            Math.floor((Date.now() - updated) / 60000)
        )
        if (minutes < 1)
            return "UPDATED NOW"
        if (minutes < 60)
            return "UPDATED " + minutes + "M AGO"
        if (minutes < 1440)
            return "UPDATED " + Math.floor(minutes / 60) + "H AGO"
        return "UPDATED " + Math.floor(minutes / 1440) + "D AGO"
    }

    function providerStatus(provider) {
        if (!provider.available) {
            if (provider.status === "rejected")
                return "LIMIT REACHED"
            if (provider.status === "blocked")
                return "BLOCKED"
            if (provider.source === "unknown")
                return "UNTRUSTED"
            return "NO DATA"
        }
        if (provider.stale)
            return "STALE"
        if (provider.status === "allowed_warning")
            return "WARNING"
        return "LIVE"
    }

    function providerDetail(provider) {
        var parts = []
        var plan = String(provider.plan || "").trim()
        if (plan !== "")
            parts.push(plan.toUpperCase())
        var count = Math.floor(Number(provider.account_count || 0))
        if (count > 1)
            parts.push(count + "X")
        var source = String(provider.source || "").trim().toLowerCase()
        if (source === "cliproxy")
            parts.push("PROXY")
        if (parts.length > 0)
            return parts.join(" · ")
        return provider.kind === "local_budget"
            ? "LOCAL BUDGET"
            : "PROVIDER QUOTA"
    }

    function statusColor(provider, accent) {
        var state = providerStatus(provider)
        if (state === "LIVE")
            return accent
        if (state === "WARNING" || state === "STALE")
            return theme.needsHelp
        if (state === "NO DATA")
            return theme.textMuted
        return theme.orange
    }

    function readableColor(color) {
        return ThemePalette.ensureContrast(
            String(color),
            String(theme.surface),
            4.5
        )
    }

    Timer {
        interval: 60000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.clockTick += 1
    }

    component UsageLine: Item {
        property var usageWindow: null
        property string providerId: ""
        property string windowRole: ""
        property bool providerAvailable: false
        property color accent: root.theme.accent
        property bool reducedMotion: false

        visible: usageWindow !== null
        width: parent ? parent.width : 0
        height: visible ? 18 : 0

        Row {
            anchors.fill: parent
            spacing: 8

            Text {
                id: windowLabel

                objectName: "usageLabel_" + providerId + "_" + windowRole
                width: Math.min(136, Math.max(96, Math.ceil(implicitWidth) + 2))
                anchors.verticalCenter: parent.verticalCenter
                text: usageWindow === null
                    ? ""
                    : String(usageWindow.label || "USAGE").toUpperCase()
                textFormat: Text.PlainText
                color: root.theme.textSecondary
                elide: Text.ElideRight
                font {
                    family: "monospace"
                    pixelSize: 10
                    weight: Font.DemiBold
                    letterSpacing: 0.4
                }
            }

            Rectangle {
                width: Math.max(
                    44,
                    parent.width - windowLabel.width - 38 - 96
                        - parent.spacing * 3
                )
                height: 6
                anchors.verticalCenter: parent.verticalCenter
                radius: 3
                color: root.theme.surfaceRaised

                Rectangle {
                    width: parent.width * (
                        providerAvailable
                            ? root.percent(usageWindow) / 100
                            : 0
                    )
                    height: parent.height
                    radius: parent.radius
                    color: accent

                    Behavior on width {
                        NumberAnimation {
                            duration: reducedMotion ? 0 : 280
                            easing.type: Easing.OutCubic
                        }
                    }
                }
            }

            Text {
                width: 38
                anchors.verticalCenter: parent.verticalCenter
                text: providerAvailable
                    ? root.percent(usageWindow) + "%"
                    : "—"
                textFormat: Text.PlainText
                color: providerAvailable
                    ? root.readableColor(accent)
                    : root.theme.textMuted
                horizontalAlignment: Text.AlignRight
                font {
                    family: "monospace"
                    pixelSize: 11
                    weight: Font.Bold
                }
            }

            Text {
                width: 96
                anchors.verticalCenter: parent.verticalCenter
                text: root.resetLabel(usageWindow)
                textFormat: Text.PlainText
                color: root.theme.textMuted
                elide: Text.ElideRight
                horizontalAlignment: Text.AlignRight
                font {
                    family: "monospace"
                    pixelSize: 9
                    letterSpacing: 0.3
                }
            }
        }
    }

    Row {
        anchors.fill: parent
        spacing: 14

        Rectangle {
            id: fleetTile

            objectName: "fleetDetailsButton"
            width: root.fleetTileWidth
            height: parent.height
            radius: 16
            color: fleetTap.pressed
                ? root.theme.surfacePressed
                : root.theme.surface
            border.width: 1
            border.color: root.devices.length > 0
                ? Qt.alpha(root.theme.accent, 0.56)
                : root.theme.border

            function activate() {
                if (!root.enabled)
                    return false
                root.fleetDetailsRequested()
                return true
            }

            Accessible.role: Accessible.Button
            Accessible.ignored: !root.enabled
            Accessible.name: root.managerLabel + " fleet details"
            Accessible.description: root.fleetSummary() + ". Tap to view connected devices."
            Accessible.onPressAction: activate()

            Column {
                anchors {
                    left: parent.left
                    right: parent.right
                    verticalCenter: parent.verticalCenter
                    leftMargin: 18
                    rightMargin: 16
                }
                spacing: 5

                Row {
                    width: parent.width
                    spacing: 8

                    Text {
                        objectName: "fleetTitle"
                        width: parent.width - detailsPill.width - 8
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.managerLabel + " FLEET"
                        textFormat: Text.PlainText
                        color: root.theme.textPrimary
                        elide: Text.ElideRight
                        font {
                            family: "monospace"
                            pixelSize: 16
                            weight: Font.Bold
                            letterSpacing: 1
                        }
                    }

                    Rectangle {
                        id: detailsPill

                        readonly property color pillFill: ThemePalette.mixColors(
                            String(root.theme.surface),
                            String(root.theme.accent),
                            0.14
                        )

                        width: detailsPillText.implicitWidth + 14
                        height: 20
                        radius: 10
                        anchors.verticalCenter: parent.verticalCenter
                        color: pillFill
                        border.width: 1
                        border.color: Qt.alpha(root.theme.accent, 0.52)

                        Text {
                            id: detailsPillText

                            anchors.centerIn: parent
                            text: "DETAILS ▸"
                            textFormat: Text.PlainText
                            color: ThemePalette.ensureContrast(
                                String(root.theme.accent),
                                String(detailsPill.pillFill),
                                4.5
                            )
                            font {
                                family: "monospace"
                                pixelSize: 9
                                weight: Font.Bold
                                letterSpacing: 0.5
                            }
                        }
                    }
                }

                Text {
                    width: parent.width
                    text: root.fleetSummary()
                    textFormat: Text.PlainText
                    color: root.theme.textSecondary
                    elide: Text.ElideRight
                    font {
                        family: "monospace"
                        pixelSize: 10
                        weight: Font.DemiBold
                        letterSpacing: 0.5
                    }
                }

                Row {
                    visible: root.devices.length > 0
                    width: parent.width
                    height: 18
                    spacing: 8

                    Repeater {
                        model: root.devicePreviewHosts()

                        Row {
                            required property var modelData
                            readonly property bool online:
                                String(modelData.state || "").toLowerCase() === "online"

                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 4

                            Rectangle {
                                width: 6
                                height: 6
                                radius: 3
                                anchors.verticalCenter: parent.verticalCenter
                                color: parent.online
                                    ? root.theme.success
                                    : root.theme.error
                            }

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: String(modelData.label || "").toUpperCase()
                                textFormat: Text.PlainText
                                color: parent.online
                                    ? root.theme.textPrimary
                                    : root.theme.textMuted
                                font {
                                    family: "monospace"
                                    pixelSize: 9
                                    weight: Font.DemiBold
                                    letterSpacing: 0.3
                                }
                            }
                        }
                    }

                    Text {
                        visible: root.devices.length > 3
                        anchors.verticalCenter: parent.verticalCenter
                        text: {
                            var counts = root.deviceCounts()
                            var extra = root.devices.length - 3
                            return counts.offline > 0
                                ? "+" + extra + " · " + counts.offline + " OFF"
                                : "+" + extra + " MORE"
                        }
                        textFormat: Text.PlainText
                        color: root.theme.textMuted
                        font {
                            family: "monospace"
                            pixelSize: 9
                            weight: Font.DemiBold
                            letterSpacing: 0.3
                        }
                    }
                }

                Text {
                    visible: root.devices.length === 0
                    width: parent.width
                    text: root.focusedSummary()
                    textFormat: Text.PlainText
                    color: root.theme.textSecondary
                    elide: Text.ElideRight
                    font {
                        family: "monospace"
                        pixelSize: 9
                        letterSpacing: 0.6
                    }
                }
            }

            TapHandler {
                id: fleetTap
                enabled: root.enabled
                gesturePolicy: TapHandler.ReleaseWithinBounds
                onTapped: fleetTile.activate()
            }
        }

        Repeater {
            model: root.providerIds

            Rectangle {
                id: providerCard

                required property string modelData
                required property int index
                readonly property var provider: root.provider(modelData)
                readonly property var primaryUsage:
                    provider.primary === undefined ? null : provider.primary
                readonly property var secondaryUsage:
                    provider.secondary === undefined ? null : provider.secondary
                readonly property int primaryPercent: root.percent(primaryUsage)
                readonly property int secondaryPercent:
                    root.percent(secondaryUsage)
                readonly property string statusLabel:
                    root.providerStatus(provider)
                readonly property string activityLabel:
                    root.activitySummary(provider)
                readonly property color accent: root.providerAccent(modelData)

                objectName: "usageCard_" + modelData
                width: (
                    root.width - root.fleetTileWidth
                        - 14 * root.providerIds.length
                ) / Math.max(1, root.providerIds.length)
                height: parent.height
                radius: 16
                color: cardTap.pressed
                    ? root.theme.surfacePressed
                    : root.theme.surface
                border.width: 1
                border.color: provider.available
                    ? Qt.alpha(accent, provider.stale ? 0.34 : 0.62)
                    : root.theme.border

                function activate() {
                    if (!root.enabled)
                        return false
                    root.usageDetailsRequested(modelData)
                    return true
                }

                Accessible.role: Accessible.Button
                Accessible.ignored: !root.enabled
                Accessible.name: String(provider.label || modelData) + " capacity details"
                Accessible.onPressAction: activate()

                Row {
                    id: providerHeader

                    anchors {
                        left: parent.left
                        right: parent.right
                        top: parent.top
                        leftMargin: 16
                        rightMargin: 16
                        topMargin: 10
                    }
                    height: 22
                    spacing: 8

                    Text {
                        width: Math.min(116, implicitWidth)
                        text: String(providerCard.provider.label || "").toUpperCase()
                        textFormat: Text.PlainText
                        color: root.theme.textPrimary
                        elide: Text.ElideRight
                        font {
                            family: "monospace"
                            pixelSize: 14
                            weight: Font.Bold
                            letterSpacing: 0.7
                        }
                    }

                    Text {
                        width: Math.max(
                            48,
                            parent.width - statusText.width - x - 8
                        )
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.providerDetail(providerCard.provider)
                        textFormat: Text.PlainText
                        color: root.theme.textMuted
                        elide: Text.ElideRight
                        font {
                            family: "monospace"
                            pixelSize: 9
                            letterSpacing: 0.4
                        }
                    }

                    Text {
                        id: statusText

                        anchors.verticalCenter: parent.verticalCenter
                        text: providerCard.index === root.providerIds.length - 1
                                && root.hiddenProviderCount > 0
                            ? providerCard.statusLabel + " · +" + root.hiddenProviderCount
                            : providerCard.statusLabel
                        textFormat: Text.PlainText
                        color: root.readableColor(
                            root.statusColor(
                                providerCard.provider,
                                providerCard.accent
                            )
                        )
                        font {
                            family: "monospace"
                            pixelSize: 9
                            weight: Font.Bold
                            letterSpacing: 0.6
                        }
                    }
                }

                Column {
                    anchors {
                        left: parent.left
                        right: parent.right
                        top: providerHeader.bottom
                        leftMargin: 16
                        rightMargin: 16
                        topMargin: 4
                    }
                    spacing: 3

                    UsageLine {
                        width: parent.width
                        providerId: providerCard.modelData
                        windowRole: "primary"
                        usageWindow: providerCard.primaryUsage
                        providerAvailable: providerCard.provider.available
                        accent: providerCard.accent
                        reducedMotion: root.reducedMotion
                    }

                    UsageLine {
                        width: parent.width
                        providerId: providerCard.modelData
                        windowRole: "secondary"
                        usageWindow: providerCard.secondaryUsage
                        providerAvailable: providerCard.provider.available
                        accent: providerCard.accent
                        reducedMotion: root.reducedMotion
                    }
                }

                Row {
                    id: providerFooter

                    anchors {
                        left: parent.left
                        right: parent.right
                        bottom: parent.bottom
                        leftMargin: 16
                        rightMargin: 16
                        bottomMargin: 9
                    }
                    spacing: 10

                    Text {
                        width: parent.width * 0.58
                        text: providerCard.activityLabel
                        textFormat: Text.PlainText
                        color: root.theme.textSecondary
                        elide: Text.ElideRight
                        font {
                            family: "monospace"
                            pixelSize: 9
                            weight: Font.DemiBold
                            letterSpacing: 0.3
                        }
                    }

                    Text {
                        width: parent.width - parent.children[0].width - 10
                        text: root.updatedLabel(providerCard.provider)
                        textFormat: Text.PlainText
                        color: root.theme.textMuted
                        elide: Text.ElideRight
                        horizontalAlignment: Text.AlignRight
                        font {
                            family: "monospace"
                            pixelSize: 9
                            letterSpacing: 0.3
                        }
                    }
                }

                TapHandler {
                    id: cardTap
                    enabled: root.enabled
                    gesturePolicy: TapHandler.ReleaseWithinBounds
                    onTapped: providerCard.activate()
                }
            }
        }
    }
}
