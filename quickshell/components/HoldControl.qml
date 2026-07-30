import QtQuick

Item {
    id: root

    property string label: "HOLD"
    property color accent: "#66f7ff"
    property bool reducedMotion: false
    property bool completed: false
    property bool armed: false

    signal confirmed()
    signal cancelled()
    signal interacted()

    implicitHeight: 48

    Accessible.role: Accessible.Button
    Accessible.name: label
    Accessible.description: "Press and hold for 800 milliseconds"

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
        visible: holdHandler.pressed
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
            if (pressed) {
                root.completed = false
                root.armed = true
                root.interacted()
            } else if (root.armed) {
                if (!root.completed)
                    root.cancelled()
                root.armed = false
                root.completed = false
            }
        }

        onLongPressed: {
            if (!root.completed) {
                root.completed = true
                root.confirmed()
            }
        }

        onCanceled: {
            if (root.armed && !root.completed)
                root.cancelled()
            root.armed = false
            root.completed = false
        }
    }
}
