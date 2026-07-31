import QtQuick

Item {
    id: root

    required property var store
    required property var bridge
    required property var activity
    required property var preferences
    property bool reducedMotion: false
    property bool previewMode: false
    property bool restoreVoiceFocus: false
    property bool previewMicroOpen: false
    property string hostName: "LOCAL"

    readonly property int pageSize: 6
    readonly property int pageCount: Math.max(
        1,
        Math.ceil(store.agents.length / pageSize)
    )
    readonly property string surfaceState: store.surfaceState()
    readonly property bool userMotionReduced:
        preferences.reduceMotion === true
    readonly property bool displayDimmed:
        preferences.dimmed === true
    readonly property bool effectiveReducedMotion:
        reducedMotion || userMotionReduced
    readonly property bool controlCenterInteractive:
        !activity.ambientMode
        && ambientView.controlCenterProgress >= 0.999
        && !ambientView.exitShield
    property int currentPage: 0
    property bool userPaging: false
    property string toastTitle: ""
    property string toastDetail: ""
    property bool toastSuccess: true
    property bool toastVisible: false
    property var pendingVoiceFocus: ({})
    property var pendingDesktopActions: ({})
    property bool microDrawerOpen: false

    clip: true

    Component.onCompleted: {
        if (previewMode && previewMicroOpen)
            microDrawerOpen = true
    }

    function agentAt(pageIndex, slotIndex) {
        var agentIndex = pageIndex * pageSize + slotIndex
        return agentIndex >= 0 && agentIndex < store.agents.length
            ? store.agents[agentIndex]
            : null
    }

    function pageAgentCount(pageIndex) {
        return Math.max(
            0,
            Math.min(pageSize, store.agents.length - pageIndex * pageSize)
        )
    }

    function pageColumns(pageIndex) {
        var count = pageAgentCount(pageIndex)
        if (count <= 2)
            return Math.max(1, count)
        return count <= 4 ? 2 : 3
    }

    function pageRows(pageIndex) {
        return Math.max(
            1,
            Math.ceil(pageAgentCount(pageIndex) / pageColumns(pageIndex))
        )
    }

    function attentionSummary() {
        var working = 0
        var review = 0
        var waiting = 0
        for (var index = 0; index < store.agents.length; index += 1) {
            var agent = store.agents[index]
            if (agent.review_ready === true)
                review += 1
            else if (agent.status === "blocked")
                waiting += 1
            else if (agent.status === "working")
                working += 1
        }
        return working + " WORKING  ·  " + review + " REVIEW  ·  "
            + waiting + " WAITING"
    }

    function notePassiveInteraction() {
        activity.noteUserActivity()
        bridge.restoreFocus()
    }

    function selectPage(pageIndex) {
        var nextPage = Math.max(0, Math.min(pageCount - 1, pageIndex))
        currentPage = nextPage
        pages.positionViewAtIndex(nextPage, ListView.SnapPosition)
        notePassiveInteraction()
    }

    function showToast(title, detail, success) {
        toastTitle = String(title || "")
        toastDetail = String(detail || "")
        toastSuccess = success
        toastVisible = true
        toastTimer.restart()
    }

    function requestVoiceAfterFocus(action) {
        var requestId = root.bridge.restoreFocus()
        if (requestId === "")
            return false
        var pending = Object.assign({}, pendingVoiceFocus)
        pending[requestId] = action
        pendingVoiceFocus = pending
        return true
    }

    function desktopActionPending(action) {
        var requestIds = Object.keys(pendingDesktopActions)
        for (var index = 0; index < requestIds.length; index += 1) {
            if (pendingDesktopActions[requestIds[index]] === action)
                return true
        }
        return false
    }

    function requestDesktop(action) {
        if (desktopActionPending(action))
            return false
        var requestId = action === "chatgpt_desktop"
            ? bridge.openChatGptDesktop()
            : bridge.openClaudeDesktop()
        if (requestId === "")
            return false
        var pending = Object.assign({}, pendingDesktopActions)
        pending[requestId] = action
        pendingDesktopActions = pending
        return true
    }

    function toggleMotionReduction() {
        if (reducedMotion)
            return false
        preferences.reduceMotion = !userMotionReduced
        if (typeof preferences.sync === "function")
            preferences.sync()
        return true
    }

    function toggleDisplayDim() {
        preferences.dimmed = !displayDimmed
        if (typeof preferences.sync === "function")
            preferences.sync()
        return true
    }

    onPageCountChanged: {
        currentPage = Math.min(currentPage, pageCount - 1)
        pages.positionViewAtIndex(currentPage, ListView.SnapPosition)
    }

    onControlCenterInteractiveChanged: {
        if (!controlCenterInteractive)
            microDrawerOpen = false
    }

    PortalBackground {
        anchors.fill: parent
        reducedMotion: root.effectiveReducedMotion
        ambientMode: root.activity.ambientMode
    }

    AmbientRing {
        anchors.fill: parent
        agents: root.store.agents
        voice: root.store.voice
        connectionState: root.store.connection.state
        reducedMotion: root.effectiveReducedMotion
        suppressRunners: root.effectiveReducedMotion
        z: 50
    }

    Rectangle {
        id: displayDimmer

        objectName: "displayDimmer"
        anchors.fill: parent
        color: "#000000"
        opacity: root.displayDimmed ? 0.88 : 0
        enabled: false
        z: 70

        Behavior on opacity {
            NumberAnimation {
                duration: root.effectiveReducedMotion ? 0 : 220
                easing.type: Easing.OutCubic
            }
        }
    }

    DisplaySettingsControls {
        id: displaySettings

        objectName: "globalDisplaySettings"
        anchors {
            right: parent.right
            top: parent.top
            rightMargin: 24
            topMargin: 20
        }
        motionReduced: root.effectiveReducedMotion
        motionForced: root.reducedMotion
        dimmed: root.displayDimmed
        opacity: root.displayDimmed ? 0.58 : 1
        z: 80
        onMotionToggleRequested: root.toggleMotionReduction()
        onDimToggleRequested: root.toggleDisplayDim()

        Behavior on opacity {
            NumberAnimation {
                duration: root.effectiveReducedMotion ? 0 : 180
                easing.type: Easing.OutCubic
            }
        }
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
        opacity: ambientView.controlCenterProgress

        transform: Translate {
            y: (1 - ambientView.controlCenterProgress) * -18
        }

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
                    text: String(root.hostName || "LOCAL").toUpperCase()
                        + " // AGENT COMMAND"
                    textFormat: Text.PlainText
                    color: "#ecfbff"
                    font {
                        family: "monospace"
                        pixelSize: 25
                        weight: Font.Bold
                        letterSpacing: 1.2
                    }
                }

                Text {
                    text: root.attentionSummary()
                    textFormat: Text.PlainText
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

                    width: 58
                    height: 48
                    color: "transparent"
                    enabled: root.controlCenterInteractive

                    Accessible.role: Accessible.Button
                    Accessible.ignored: !root.controlCenterInteractive
                    Accessible.name: "Show agent page " + (index + 1)
                        + " of " + root.pageCount
                    Accessible.description: index === root.currentPage
                        ? "Current page"
                        : "Switch pages"
                    Accessible.onPressAction: {
                        if (root.controlCenterInteractive)
                            root.selectPage(index)
                    }

                    Rectangle {
                        anchors.centerIn: parent
                        width: parent.index === root.currentPage ? 46 : 16
                        height: 8
                        radius: 4
                        color: parent.index === root.currentPage
                            ? "#55e9ff"
                            : "#29445f"

                        Behavior on width {
                            NumberAnimation {
                                duration: root.effectiveReducedMotion ? 0 : 180
                                easing.type: Easing.OutCubic
                            }
                        }
                    }

                    TapHandler {
                        gesturePolicy: TapHandler.ReleaseWithinBounds
                        onTapped: root.selectPage(parent.index)
                    }
                }
            }
        }

        Row {
            anchors {
                right: parent.right
                verticalCenter: parent.verticalCenter
                rightMargin: displaySettings.width + 16
            }
            spacing: 12

            DesktopAppButton {
                width: 188
                height: 58
                anchors.verticalCenter: parent.verticalCenter
                label: "CHATGPT"
                accent: "#6cf7b0"
                pending: root.desktopActionPending("chatgpt_desktop")
                enabled: root.controlCenterInteractive
                    && !root.store.freshSnapshotRequired
                onInteracted: root.activity.noteUserActivity()
                onTriggered: root.requestDesktop("chatgpt_desktop")
            }

            DesktopAppButton {
                width: 188
                height: 58
                anchors.verticalCenter: parent.verticalCenter
                label: "CLAUDE"
                accent: "#e89562"
                pending: root.desktopActionPending("claude_desktop")
                enabled: root.controlCenterInteractive
                    && !root.store.freshSnapshotRequired
                onInteracted: root.activity.noteUserActivity()
                onTriggered: root.requestDesktop("claude_desktop")
            }

            VoiceControl {
                width: 320
                height: 58
                anchors.verticalCenter: parent.verticalCenter
                voice: root.store.voice
                reducedMotion: root.effectiveReducedMotion
                enabled: root.controlCenterInteractive
                actionsEnabled: root.controlCenterInteractive
                    && !root.store.freshSnapshotRequired
                onInteracted: root.activity.noteUserActivity()
                onStartRequested: {
                    if (root.restoreVoiceFocus)
                        root.requestVoiceAfterFocus("start")
                    else
                        root.bridge.startVoice()
                }
                onStopRequested: {
                    if (root.restoreVoiceFocus)
                        root.requestVoiceAfterFocus("stop")
                    else
                        root.bridge.stopVoice()
                }
                onCancelRequested: root.bridge.cancelVoice()
            }

            Rectangle {
                id: microButton

                width: 218
                height: 58
                radius: 14
                anchors.verticalCenter: parent.verticalCenter
                color: microTap.pressed ? "#14283a" : "#0b1523"
                border.width: 1
                border.color: root.store.micro.connected
                    ? "#3a8d83"
                    : "#583b49"
                enabled: root.controlCenterInteractive

                function activate() {
                    if (!enabled)
                        return false
                    root.activity.noteUserActivity()
                    root.microDrawerOpen = !root.microDrawerOpen
                    return true
                }

                Accessible.role: Accessible.Button
                Accessible.ignored: !enabled
                Accessible.name: "Codex Micro virtual projection"
                Accessible.description: root.store.micro.connected
                    ? "Connected"
                    : "Unavailable"
                Accessible.onPressAction: activate()

                Row {
                    anchors.centerIn: parent
                    spacing: 11

                    Rectangle {
                        width: 28
                        height: 28
                        radius: 14
                        color: "transparent"
                        border.width: 4
                        border.color: root.store.micro.connected
                            ? "#49e0cf"
                            : "#604253"
                    }

                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 1

                        Text {
                            text: "MICRO"
                            textFormat: Text.PlainText
                            color: "#e8f8fc"
                            font {
                                family: "monospace"
                                pixelSize: 15
                                weight: Font.Bold
                                letterSpacing: 0.7
                            }
                        }

                        Text {
                            text: root.store.micro.connected
                                ? Number(root.store.micro.battery) >= 0
                                    ? root.store.micro.battery + "% · CONNECTED"
                                    : "CONNECTED"
                                : "OFFLINE"
                            textFormat: Text.PlainText
                            color: root.store.micro.connected
                                ? "#65d9c5"
                                : "#b07888"
                            font {
                                family: "monospace"
                                pixelSize: 9
                                weight: Font.DemiBold
                            }
                        }
                    }
                }

                TapHandler {
                    id: microTap
                    enabled: microButton.enabled
                    gesturePolicy: TapHandler.ReleaseWithinBounds
                    onTapped: microButton.activate()
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
        opacity: ambientView.controlCenterProgress

        Text {
            anchors.centerIn: parent
            text: "DEGRADED // " + String(
                root.store.connection.detail
                    || root.store.protocolError
                    || "PARTIAL TELEMETRY"
            ).toUpperCase()
            textFormat: Text.PlainText
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
                duration: root.effectiveReducedMotion ? 0 : 180
            }
        }
    }

    ListView {
        id: pages

        anchors {
            left: parent.left
            right: parent.right
            top: header.bottom
            bottom: commandDock.top
            topMargin: 7
            bottomMargin: 10
        }
        orientation: ListView.Horizontal
        model: root.pageCount
        currentIndex: root.currentPage
        snapMode: ListView.SnapOneItem
        boundsBehavior: Flickable.StopAtBounds
        interactive: root.pageCount > 1 && root.surfaceState !== "disconnected"
            && root.controlCenterInteractive
        highlightMoveDuration: root.effectiveReducedMotion ? 0 : 220
        cacheBuffer: width
        clip: true
        opacity: ambientView.controlCenterProgress
        scale: 0.985 + ambientView.controlCenterProgress * 0.015
        transformOrigin: Item.Center

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
                columns: root.pageColumns(page.index)
                columnSpacing: 16
                rowSpacing: 16

                Repeater {
                    model: root.pageSize

                    AgentCard {
                        required property int index

                        width: (
                            cardGrid.width
                                - cardGrid.columnSpacing
                                    * (cardGrid.columns - 1)
                        ) / cardGrid.columns
                        height: (
                            cardGrid.height
                                - cardGrid.rowSpacing
                                    * (root.pageRows(page.index) - 1)
                        ) / root.pageRows(page.index)
                        agent: root.agentAt(page.index, index)
                        visible: agent !== null
                        enabled: visible && root.controlCenterInteractive
                        reducedMotion: root.effectiveReducedMotion
                        snapshotSequence: root.store.sequence
                        actionsEnabled: !root.store.freshSnapshotRequired

                        onInteracted: root.activity.noteUserActivity()

                        onFocusRequested: function(agentId) {
                            // Card activation intentionally focuses Herdr.
                            root.bridge.openAgent(agentId)
                        }

                        onApproveRequested: function(
                            agentId,
                            capabilityId,
                            sequence
                        ) {
                            root.bridge.approveAgent(
                                agentId,
                                capabilityId,
                                sequence
                            )
                            root.bridge.restoreFocus(sequence)
                        }

                        onInterruptRequested: function(
                            agentId,
                            capabilityId,
                            sequence
                        ) {
                            root.bridge.interruptAgent(
                                agentId,
                                capabilityId,
                                sequence
                            )
                            root.bridge.restoreFocus(sequence)
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
        opacity: ambientView.controlCenterProgress

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
                textFormat: Text.PlainText
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
                            root.store.transportDetail
                                || root.store.connection.detail
                                || "The bridge will reconnect automatically"
                        )
                        : "Herdr is connected and has no running local agents"
                textFormat: Text.PlainText
                color: "#718ca6"
                font {
                    family: "sans-serif"
                    pixelSize: 16
                }
            }
        }
    }

    AiUsageDock {
        id: commandDock

        anchors {
            left: parent.left
            right: parent.right
            bottom: parent.bottom
            leftMargin: 24
            rightMargin: 24
            bottomMargin: 16
        }
        height: 106
        usage: root.store.usage
        agents: root.store.agents
        sessions: root.store.sessions
        reducedMotion: root.effectiveReducedMotion
        enabled: root.controlCenterInteractive
        opacity: ambientView.controlCenterProgress
        transform: Translate {
            y: (1 - ambientView.controlCenterProgress) * 14
        }
    }

    MicroDrawer {
        anchors.fill: parent
        opened: root.microDrawerOpen
        interactive: root.controlCenterInteractive
        reducedMotion: root.effectiveReducedMotion
        micro: root.store.micro
        agents: root.store.agents
        voice: root.store.voice
        z: 35
        opacity: ambientView.controlCenterProgress
        onInteracted: root.activity.noteUserActivity()
        onCloseRequested: root.microDrawerOpen = false
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
        opacity: ambientView.controlCenterProgress

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
                    textFormat: Text.PlainText
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
                    textFormat: Text.PlainText
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
                duration: root.effectiveReducedMotion ? 0 : 170
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
            if (result.action === "restore_focus") {
                var intent = root.pendingVoiceFocus[result.request_id]
                if (intent !== undefined) {
                    var pending = Object.assign(
                        {},
                        root.pendingVoiceFocus
                    )
                    delete pending[result.request_id]
                    root.pendingVoiceFocus = pending
                    if (result.ok) {
                        if (intent === "start")
                            root.bridge.startVoice()
                        else if (intent === "stop")
                            root.bridge.stopVoice()
                    } else {
                        root.showToast(
                            "VOICE // FOCUS REQUIRED",
                            "Choose a laptop typing target and try again",
                            false
                        )
                    }
                }
                return
            }
            if (result.action === "chatgpt_desktop"
                    || result.action === "claude_desktop") {
                var desktopPending = Object.assign(
                    {},
                    root.pendingDesktopActions
                )
                delete desktopPending[result.request_id]
                root.pendingDesktopActions = desktopPending
                root.showToast(
                    result.ok
                        ? "DESKTOP // READY"
                        : "DESKTOP // " + String(result.code).toUpperCase(),
                    result.message || result.request_id,
                    result.ok
                )
                return
            }
            var voiceAction = String(result.action).indexOf("voice_") === 0
            root.showToast(
                result.ok
                    ? voiceAction
                        ? "VOICE // ACCEPTED"
                        : "ACTION // ACCEPTED"
                    : (voiceAction ? "VOICE // " : "ACTION // ")
                        + String(result.code).toUpperCase(),
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

        function onFreshSnapshotRequiredChanged() {
            if (root.store.freshSnapshotRequired)
                root.pendingDesktopActions = {}
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
        id: ambientView

        anchors.fill: parent
        active: root.activity.ambientMode
        reducedMotion: root.effectiveReducedMotion
        agents: root.store.agents
        health: root.store.health
        voice: root.store.voice
        connectionState: root.store.connection.state
        onWakeRequested: root.notePassiveInteraction()
    }
}
