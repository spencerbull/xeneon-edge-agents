import QtQuick

Item {
    id: root

    property var usage: ({"providers": []})
    property var agents: []
    property var sessions: []
    property bool reducedMotion: false

    readonly property var providerIds: ["claude", "codex", "opencode"]

    function provider(id) {
        var providers = usage !== null
                && usage !== undefined
                && Array.isArray(usage.providers)
            ? usage.providers
            : []
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
            "model": ""
        }
    }

    function primaryWindow(provider) {
        if (provider.primary !== null && provider.primary !== undefined)
            return provider.primary
        if (provider.secondary !== null && provider.secondary !== undefined)
            return provider.secondary
        return null
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

    function fleetSummary() {
        return countLabel(agents.length, "AGENT", "AGENTS")
            + " · " + countLabel(sessions.length, "SESSION", "SESSIONS")
    }

    function focusedSummary() {
        var focused = 0
        for (var index = 0; index < agents.length; index += 1) {
            if (agents[index].focused === true)
                focused += 1
        }
        return focused > 0
            ? focused + " FOCUSED"
            : "NO FOCUSED AGENT"
    }

    Row {
        anchors.fill: parent
        spacing: 14

        Rectangle {
            width: 286
            height: parent.height
            radius: 16
            color: "#09131f"
            border.width: 1
            border.color: "#244963"

            Column {
                anchors {
                    left: parent.left
                    verticalCenter: parent.verticalCenter
                    leftMargin: 22
                }
                spacing: 4

                Text {
                    text: "HERDR FLEET"
                    textFormat: Text.PlainText
                    color: "#dff9ff"
                    font {
                        family: "monospace"
                        pixelSize: 17
                        weight: Font.Bold
                        letterSpacing: 1.1
                    }
                }

                Text {
                    text: root.fleetSummary()
                    textFormat: Text.PlainText
                    color: "#5f7f9c"
                    font {
                        family: "monospace"
                        pixelSize: 10
                        letterSpacing: 0.6
                    }
                }

                Text {
                    text: root.focusedSummary()
                    textFormat: Text.PlainText
                    color: "#47718d"
                    font {
                        family: "monospace"
                        pixelSize: 9
                        letterSpacing: 0.6
                    }
                }
            }
        }

        Repeater {
            model: root.providerIds

            Rectangle {
                required property string modelData
                readonly property var provider: root.provider(modelData)
                readonly property var window: root.primaryWindow(provider)
                readonly property int usagePercent: root.percent(window)
                readonly property color accent: modelData === "claude"
                    ? "#e89562"
                    : modelData === "codex"
                        ? "#63e6ba"
                        : "#a998ff"

                width: (root.width - 286 - 42) / 3
                height: parent.height
                radius: 16
                color: "#09131f"
                border.width: 1
                border.color: provider.available
                    ? Qt.alpha(accent, provider.stale ? 0.34 : 0.62)
                    : "#263847"

                Row {
                    anchors {
                        left: parent.left
                        right: parent.right
                        top: parent.top
                        leftMargin: 18
                        rightMargin: 18
                        topMargin: 13
                    }
                    height: 25

                    Text {
                        width: parent.width - percentText.width
                        text: String(parent.parent.provider.label || "").toUpperCase()
                        textFormat: Text.PlainText
                        color: "#dceff7"
                        elide: Text.ElideRight
                        font {
                            family: "monospace"
                            pixelSize: 14
                            weight: Font.Bold
                            letterSpacing: 0.7
                        }
                    }

                    Text {
                        id: percentText
                        text: parent.parent.provider.available
                            ? parent.parent.usagePercent + "%"
                            : "—"
                        textFormat: Text.PlainText
                        color: parent.parent.provider.available
                            ? parent.parent.accent
                            : "#647787"
                        font {
                            family: "monospace"
                            pixelSize: 18
                            weight: Font.Bold
                        }
                    }
                }

                Rectangle {
                    anchors {
                        left: parent.left
                        right: parent.right
                        top: parent.top
                        leftMargin: 18
                        rightMargin: 18
                        topMargin: 43
                    }
                    height: 7
                    radius: 4
                    color: "#162333"

                    Rectangle {
                        width: parent.width
                            * (parent.parent.provider.available
                                ? parent.parent.usagePercent / 100
                                : 0)
                        height: parent.height
                        radius: parent.radius
                        color: parent.parent.accent

                        Behavior on width {
                            NumberAnimation {
                                duration: root.reducedMotion ? 0 : 280
                                easing.type: Easing.OutCubic
                            }
                        }
                    }
                }

                Row {
                    anchors {
                        left: parent.left
                        right: parent.right
                        bottom: parent.bottom
                        leftMargin: 18
                        rightMargin: 18
                        bottomMargin: 11
                    }

                    Text {
                        width: parent.width * 0.52
                        text: {
                            var provider = parent.parent.provider
                            var window = parent.parent.window
                            if (!provider.available) {
                                if (provider.status === "blocked"
                                        || provider.status === "rejected")
                                    return String(provider.status).toUpperCase()
                                if (provider.source === "unknown")
                                    return "UNTRUSTED"
                                return "NO DATA"
                            }
                            if (provider.stale)
                                return "STALE"
                            if (provider.kind === "local_budget")
                                return "LOCAL BUDGET"
                            return String(
                                window === null ? "QUOTA" : window.label
                            ).toUpperCase()
                        }
                        textFormat: Text.PlainText
                        color: !parent.parent.provider.available
                                && (parent.parent.provider.status === "blocked"
                                    || parent.parent.provider.status === "rejected"
                                    || parent.parent.provider.source === "unknown")
                            ? "#e08a68"
                            : parent.parent.provider.stale
                                ? "#d5a25f"
                                : "#6888a2"
                        elide: Text.ElideRight
                        font {
                            family: "monospace"
                            pixelSize: 10
                            weight: Font.DemiBold
                            letterSpacing: 0.5
                        }
                    }

                    Text {
                        width: parent.width * 0.48
                        text: parent.parent.provider.kind === "local_budget"
                            ? String(
                                parent.parent.provider.model || "LOCAL ACTIVITY"
                            ).toUpperCase()
                            : root.resetLabel(parent.parent.window)
                        textFormat: Text.PlainText
                        color: "#6888a2"
                        elide: Text.ElideRight
                        horizontalAlignment: Text.AlignRight
                        font {
                            family: "monospace"
                            pixelSize: 10
                            letterSpacing: 0.4
                        }
                    }
                }
            }
        }
    }
}
