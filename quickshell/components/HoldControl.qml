import QtQuick

Item {
    id: root

    property string label: "HOLD"
    property color accent: "#66f7ff"
    property bool reducedMotion: false
    property bool completed: false
    property bool armed: false
    property string targetAgentId: ""
    property string targetCapabilityId: ""
    property double targetSequence: -1
    property string heldAgentId: ""
    property string heldCapabilityId: ""
    property double heldSequence: -1

    signal confirmed(
        string agentId,
        string capabilityId,
        double snapshotSequence
    )
    signal cancelled()
    signal interacted()
    signal accessibleHoldRequested()

    implicitHeight: 48

    Accessible.role: Accessible.Button
    Accessible.ignored: !root.enabled
    Accessible.name: label
    Accessible.description:
        "Touch and hold for 800 milliseconds; a press action cannot confirm"
    Accessible.onPressAction: {
        if (root.enabled)
            root.accessibleHoldRequested()
    }

    onTargetAgentIdChanged: invalidateChangedTarget()
    onTargetCapabilityIdChanged: invalidateChangedTarget()
    onTargetSequenceChanged: invalidateChangedTarget()

    function guardMatches() {
        return heldAgentId === targetAgentId
                && heldCapabilityId === targetCapabilityId
                && heldSequence === targetSequence
    }

    function beginHold() {
        completed = false
        heldAgentId = targetAgentId
        heldCapabilityId = targetCapabilityId
        heldSequence = targetSequence
        armed = enabled
                && heldAgentId !== ""
                && heldCapabilityId !== ""
                && isFinite(heldSequence)
                && heldSequence >= 0
        if (armed)
            interacted()
        return armed
    }

    function cancelHold() {
        if (!armed || completed)
            return false
        armed = false
        completed = false
        cancelled()
        return true
    }

    function invalidateChangedTarget() {
        if (armed && !guardMatches())
            cancelHold()
    }

    function confirmHold() {
        if (!armed || completed || !guardMatches()) {
            cancelHold()
            return false
        }

        completed = true
        confirmed(heldAgentId, heldCapabilityId, heldSequence)
        return true
    }

    function finishHold() {
        if (armed && !completed)
            cancelled()
        armed = false
        completed = false
        heldAgentId = ""
        heldCapabilityId = ""
        heldSequence = -1
    }

    Rectangle {
        anchors.fill: parent
        radius: 10
        color: holdHandler.pressed ? Qt.alpha(root.accent, 0.18) : "#0b1422"
        border.width: 1
        border.color: root.enabled ? Qt.alpha(root.accent, 0.72) : "#263143"
        opacity: root.enabled ? 1 : 0.36
    }

    Rectangle {
        anchors {
            left: parent.left
            top: parent.top
            bottom: parent.bottom
            margins: 3
        }
        width: Math.max(
            0,
            (parent.width - 6) * Math.min(
                1,
                Math.max(0, holdHandler.timeHeld) / 0.8
            )
        )
        radius: 7
        color: Qt.alpha(root.accent, 0.26)
        visible: holdHandler.pressed && root.armed
    }

    Rectangle {
        anchors {
            left: parent.left
            top: parent.top
            bottom: parent.bottom
        }
        width: 4
        radius: 2
        color: root.accent
        opacity: root.enabled ? 0.9 : 0.25
    }

    Text {
        anchors.centerIn: parent
        text: root.label
        textFormat: Text.PlainText
        color: root.enabled ? "#edfaff" : "#718096"
        font {
            family: "monospace"
            pixelSize: 15
            weight: Font.DemiBold
            letterSpacing: 1.2
        }
    }

    TapHandler {
        id: holdHandler

        enabled: root.enabled
        gesturePolicy: TapHandler.WithinBounds
        longPressThreshold: 0.8
        acceptedButtons: Qt.LeftButton

        onPressedChanged: {
            if (pressed)
                root.beginHold()
            else
                root.finishHold()
        }

        onLongPressed: root.confirmHold()

        onCanceled: {
            root.cancelHold()
            root.finishHold()
        }
    }
}
