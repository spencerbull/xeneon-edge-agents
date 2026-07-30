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
    property bool reducedMotion: false
    property bool recoveryVisible: true
    property int recoveryAttempts: 0

    screen: modelData
    visible: recoveryVisible
    color: "#02050b"
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
        if (recoveryAttempts < 2) {
            recoveryVisible = false
            recoveryTimer.restart()
        }
    }

    onWindowConnected: {
        recoveryAttempts = 0
    }

    Timer {
        id: recoveryTimer
        interval: 120
        repeat: false
        onTriggered: {
            root.recoveryAttempts += 1
            root.recoveryVisible = true
        }
    }

    PortalViewport {
        anchors.fill: parent
        store: root.store
        bridge: root.bridge
        activity: root.activity
        reducedMotion: root.reducedMotion
        previewMode: false
    }
}
