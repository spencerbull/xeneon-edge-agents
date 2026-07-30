import QtQuick

Item {
    id: root

    required property var store
    required property var bridge
    required property var activity
    property bool reducedMotion: false
    property bool previewMode: false

    readonly property int pageSize: 6
    readonly property int pageCount: Math.max(
        1,
        Math.ceil(store.agents.length / pageSize)
    )
    readonly property string surfaceState: store.surfaceState()
    property int currentPage: 0
    property bool userPaging: false
    property string toastTitle: ""
    property string toastDetail: ""
    property bool toastSuccess: true
    property bool toastVisible: false

    clip: true

    function agentAt(pageIndex, slotIndex) {
        var agentIndex = pageIndex * pageSize + slotIndex
        return agentIndex >= 0 && agentIndex < store.agents.length
            ? store.agents[agentIndex]
            : null
    }

    function notePassiveInteraction() {
        activity.noteUserActivity()
        bridge.restoreFocus()
    }

    function showToast(title, detail, success) {
        toastTitle = String(title || "")
        toastDetail = String(detail || "")
        toastSuccess = success
        toastVisible = true
        toastTimer.restart()
    }

    onPageCountChanged: {
        currentPage = Math.min(currentPage, pageCount - 1)
        pages.positionViewAtIndex(currentPage, ListView.SnapPosition)
    }

    PortalBackground {
        anchors.fill: parent
        reducedMotion: root.reducedMotion
        ambientMode: root.activity.ambientMode
    }

    Item {
        id: header

        anchors {
            left: parent.left
            right: parent.right
            top: parent.top
            leftMargin: 34
            rightMargin: 34
        }
        height: 92

        Row {
            anchors {
                left: parent.left
                verticalCenter: parent.verticalCenter
            }
            spacing: 18

            Rectangle {
                width: 8
                height: 52
                radius: 4
                color: "#55e9ff"
            }

            Column {
                spacing: 2

                Text {
                    text: "XENEON // AGENT COMMAND"
                    color: "#ecfbff"
                    font {
                        family: "monospace"
                        pixelSize: 25
                        weight: Font.Bold
                        letterSpacing: 1.2
                    }
                }

                Text {
                    text: root.store.agents.length + " AGENTS  ·  "
                        + root.store.sessions.length + " SESSIONS  ·  SEQ "
                        + Math.max(0, root.store.sequence)
                    color: "#6385a5"
                    font {
                        family: "monospace"
                        pixelSize: 13
                        letterSpacing: 0.6
                    }
                }
            }
        }

        Row {
            id: pageDots

            anchors.centerIn: parent
            spacing: 12
            visible: root.pageCount > 1

            Repeater {
                model: root.pageCount

                Rectangle {
                    required property int index

                    width: index === root.currentPage ? 46 : 16
                    height: 8
                    radius: 4
                    color: index === root.currentPage ? "#55e9ff" : "#29445f"

                    Behavior on width {
                        NumberAnimation {
                            duration: root.reducedMotion ? 0 : 180
                            easing.type: Easing.OutCubic
                        }
                    }

                    TapHandler {
                        gesturePolicy: TapHandler.ReleaseWithinBounds
                        onTapped: {
                            root.currentPage = parent.index
                            pages.positionViewAtIndex(
                                parent.index,
                                ListView.SnapPosition
                            )
                            root.notePassiveInteraction()
                        }
                    }
                }
            }
        }

        Rectangle {
            anchors {
                right: parent.right
                verticalCenter: parent.verticalCenter
            }
            width: connectionLabel.implicitWidth + 38
            height: 40
            radius: 20
            color: "#0c1726"
            border.width: 1
            border.color: root.store.connection.state === "connected"
                ? "#27735b"
                : root.store.connection.state === "degraded"
                    ? "#8d6735"
                    : "#7a354e"

            Rectangle {
                width: 9
                height: 9
                radius: 5
                anchors {
                    left: parent.left
                    leftMargin: 14
                    verticalCenter: parent.verticalCenter
                }
                color: root.store.connection.state === "connected"
                    ? "#6cf7b0"
                    : root.store.connection.state === "degraded"
                        ? "#ffb45e"
                        : "#ff5d83"
            }

            Text {
                id: connectionLabel

                anchors {
                    left: parent.left
                    leftMargin: 30
                    verticalCenter: parent.verticalCenter
                }
                text: String(
                    root.store.connection.state || "STARTING"
                ).toUpperCase()
                color: "#cce8f5"
                font {
                    family: "monospace"
                    pixelSize: 13
                    weight: Font.DemiBold
                    letterSpacing: 0.8
                }
            }
        }
    }

    Rectangle {
        anchors {
            top: header.bottom
            horizontalCenter: parent.horizontalCenter
        }
        width: 960
        height: root.surfaceState === "degraded" ? 28 : 0
        radius: 14
        color: "#d4362b0f"
        border.width: height > 0 ? 1 : 0
        border.color: "#7f5d30"
        clip: true
        visible: height > 0
        z: 12

        Text {
            anchors.centerIn: parent
            text: "DEGRADED // " + String(
                root.store.connection.detail
                    || root.store.protocolError
                    || "PARTIAL TELEMETRY"
            ).toUpperCase()
            color: "#ffc47c"
            elide: Text.ElideRight
            width: parent.width - 40
            horizontalAlignment: Text.AlignHCenter
            font {
                family: "monospace"
                pixelSize: 12
                weight: Font.DemiBold
                letterSpacing: 0.7
            }
        }

        Behavior on height {
            NumberAnimation {
                duration: root.reducedMotion ? 0 : 180
            }
        }
    }

    ListView {
        id: pages

        anchors {
            left: parent.left
            right: parent.right
            top: header.bottom
            bottom: healthStrip.top
            topMargin: 7
            bottomMargin: 10
        }
        orientation: ListView.Horizontal
        model: root.pageCount
        currentIndex: root.currentPage
        snapMode: ListView.SnapOneItem
        boundsBehavior: Flickable.StopAtBounds
        interactive: root.pageCount > 1 && root.surfaceState !== "disconnected"
        highlightMoveDuration: root.reducedMotion ? 0 : 220
        cacheBuffer: width
        clip: true

        onMovementStarted: {
            root.userPaging = true
        }

        onMovementEnded: {
            var nextPage = Math.max(
                0,
                Math.min(
                    root.pageCount - 1,
                    Math.round(contentX / width)
                )
            )
            root.currentPage = nextPage
            positionViewAtIndex(nextPage, ListView.SnapPosition)
            if (root.userPaging)
                root.notePassiveInteraction()
            root.userPaging = false
        }

        delegate: Item {
            id: page

            required property int index
            width: pages.width
            height: pages.height

            Grid {
                id: cardGrid

                anchors {
                    fill: parent
                    leftMargin: 34
                    rightMargin: 34
                    topMargin: 8
                    bottomMargin: 4
                }
                columns: 3
                columnSpacing: 16
                rowSpacing: 16

                Repeater {
                    model: root.pageSize

                    AgentCard {
                        required property int index

                        width: (cardGrid.width - cardGrid.columnSpacing * 2) / 3
                        height: (cardGrid.height - cardGrid.rowSpacing) / 2
                        agent: root.agentAt(page.index, index)
                        visible: agent !== null
                        enabled: visible
                        reducedMotion: root.reducedMotion

                        onInteracted: root.activity.noteUserActivity()

                        onOpenRequested: function(agentId) {
                            // Opening intentionally keeps focus in Herdr.
                            root.bridge.openAgent(agentId)
                        }

                        onZoomRequested: function(agentId) {
                            // Zooming intentionally keeps focus in Herdr.
                            root.bridge.zoomAgent(agentId)
                        }

                        onApproveRequested: function(agentId, capabilityId) {
                            root.bridge.approveAgent(agentId, capabilityId)
                            root.bridge.restoreFocus()
                        }

                        onInterruptRequested: function(agentId, capabilityId) {
                            root.bridge.interruptAgent(agentId, capabilityId)
                            root.bridge.restoreFocus()
                        }
                    }
                }
            }
        }
    }

    Item {
        anchors {
            left: parent.left
            right: parent.right
            top: pages.top
            bottom: pages.bottom
            margins: 34
        }
        visible: root.surfaceState === "loading"
            || root.surfaceState === "disconnected"
            || root.surfaceState === "empty"
        z: 20

        Rectangle {
            anchors.fill: parent
            radius: 22
            color: "#e8050a14"
            border.width: 1
            border.color: root.surfaceState === "disconnected"
                ? "#6f3047"
                : "#244a67"
        }

        Column {
            anchors.centerIn: parent
            spacing: 12

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.surfaceState === "loading"
                    ? "SYNCHRONIZING"
                    : root.surfaceState === "disconnected"
                        ? "HERDR DISCONNECTED"
                        : "NO ACTIVE AGENTS"
                color: root.surfaceState === "disconnected"
                    ? "#ff769a"
                    : "#77eaff"
                font {
                    family: "monospace"
                    pixelSize: 30
                    weight: Font.Light
                    letterSpacing: 4
                }
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.surfaceState === "loading"
                    ? "Waiting for the first schema v1 snapshot"
                    : root.surfaceState === "disconnected"
                        ? String(
                            root.store.connection.detail
                                || root.store.transportDetail
                                || "The bridge will reconnect automatically"
                        )
                        : "Herdr is connected and has no running local agents"
                color: "#718ca6"
                font {
                    family: "sans-serif"
                    pixelSize: 16
                }
            }
        }
    }

    HealthStrip {
        id: healthStrip

        anchors {
            left: parent.left
            right: parent.right
            bottom: parent.bottom
            leftMargin: 24
            rightMargin: 24
            bottomMargin: 16
        }
        height: 64
        health: root.store.health
        connection: root.store.connection
        onInteracted: root.notePassiveInteraction()
    }

    Rectangle {
        id: toast

        anchors {
            horizontalCenter: parent.horizontalCenter
            top: parent.top
            topMargin: 82
        }
        width: 780
        height: root.toastVisible ? 74 : 0
        radius: 16
        color: root.toastSuccess ? "#ed0b241f" : "#ed2b0e1a"
        border.width: root.toastVisible ? 1 : 0
        border.color: root.toastSuccess ? "#377f69" : "#8b3d58"
        clip: true
        visible: height > 0
        z: 60

        Row {
            anchors {
                fill: parent
                margins: 16
            }
            spacing: 16

            Rectangle {
                width: 8
                height: parent.height
                radius: 4
                color: root.toastSuccess ? "#6cf7b0" : "#ff5d83"
            }

            Column {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - 30
                spacing: 3

                Text {
                    width: parent.width
                    text: root.toastTitle
                    color: "#e8fbff"
                    elide: Text.ElideRight
                    font {
                        family: "monospace"
                        pixelSize: 15
                        weight: Font.Bold
                        letterSpacing: 0.8
                    }
                }

                Text {
                    width: parent.width
                    text: root.toastDetail
                    color: "#8eabc3"
                    elide: Text.ElideRight
                    font {
                        family: "sans-serif"
                        pixelSize: 14
                    }
                }
            }
        }

        Behavior on height {
            NumberAnimation {
                duration: root.reducedMotion ? 0 : 170
                easing.type: Easing.OutCubic
            }
        }
    }

    Timer {
        id: toastTimer

        interval: 3200
        repeat: false
        onTriggered: root.toastVisible = false
    }

    Connections {
        target: root.store

        function onActionResultReceived(result) {
            root.showToast(
                result.ok
                    ? "ACTION // ACCEPTED"
                    : "ACTION // " + String(result.code).toUpperCase(),
                result.message || result.request_id,
                result.ok
            )
        }

        function onNoticeReceived(notice) {
            root.showToast(
                "NOTICE // " + String(notice.code).toUpperCase(),
                notice.message,
                String(notice.level).toLowerCase() !== "error"
            )
        }
    }

    Connections {
        target: root.bridge

        function onCommandRejected(reason) {
            root.showToast("COMMAND REJECTED", reason, false)
        }

        function onCommandEmitted(command) {
            if (root.previewMode) {
                root.showToast(
                    "PREVIEW // " + String(command.action).toUpperCase(),
                    command.request_id,
                    true
                )
            }
        }
    }

    AmbientView {
        anchors.fill: parent
        active: root.activity.ambientMode
        reducedMotion: root.reducedMotion
        agents: root.store.agents
        health: root.store.health
        onWakeRequested: root.notePassiveInteraction()
    }
}
