import QtQuick
import Quickshell
import Quickshell.Wayland
import "components"

PanelWindow {
    id: root

    required property var modelData
    required property var store
    required property var bridge
    required property var activity
    required property var preferences
    required property var theme
    property bool reducedMotion: false
    property string hostName: "LOCAL"
    property bool recoveryVisible: true
    property int recoveryAttempts: 0
    property bool awaitingRecovery: false
    readonly property int maximumRecoveryDelayMs: 2000

    screen: modelData
    visible: recoveryVisible
    color: root.theme.canvas
    surfaceFormat.opaque: true
    focusable: false
    mask: null

    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }

    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "xeneon-edge-agent-portal"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    onResourcesLost: {
        recoveryStabilityTimer.stop()
        recoveryWatchdog.stop()
        awaitingRecovery = true
        scheduleRecovery()
    }

    onWindowConnected: {
        recoveryWatchdog.stop()
        awaitingRecovery = false
        recoveryStabilityTimer.restart()
    }

    function scheduleRecovery() {
        recoveryAttempts += 1
        if (recoveryAttempts > 2) {
            Qt.exit(1)
            return
        }
        recoveryVisible = false
        recoveryTimer.interval = Math.min(
            maximumRecoveryDelayMs,
            120 * Math.pow(2, Math.min(recoveryAttempts - 1, 4))
        )
        recoveryTimer.restart()
    }

    Timer {
        id: recoveryTimer
        interval: 120
        repeat: false
        onTriggered: {
            root.recoveryVisible = true
            root.recoveryWatchdog.restart()
        }
    }

    Timer {
        id: recoveryWatchdog
        interval: 1500
        repeat: false
        onTriggered: {
            if (root.awaitingRecovery)
                root.scheduleRecovery()
        }
    }

    Timer {
        id: recoveryStabilityTimer
        interval: 5000
        repeat: false
        onTriggered: root.recoveryAttempts = 0
    }

    PortalViewport {
        anchors.fill: parent
        store: root.store
        bridge: root.bridge
        activity: root.activity
        preferences: root.preferences
        theme: root.theme
        reducedMotion: root.reducedMotion
        previewMode: false
        hostName: root.hostName
    }
}
