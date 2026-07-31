import QtQuick

Item {
    id: root

    property bool motionReduced: false
    property bool dimmed: false
    property bool motionForced: false

    signal motionToggleRequested()
    signal dimToggleRequested()

    width: 200
    height: 52

    Row {
        anchors.fill: parent
        spacing: 8

        DisplaySettingButton {
            objectName: "motionSettingButton"
            width: 96
            height: parent.height
            label: "MOTION"
            stateLabel: root.motionForced
                ? "SYSTEM"
                : root.motionReduced
                    ? "REDUCED"
                    : "FULL"
            accent: "#55e9ff"
            checked: root.motionReduced
            enabled: !root.motionForced
            onToggled: root.motionToggleRequested()
        }

        DisplaySettingButton {
            objectName: "dimSettingButton"
            width: 96
            height: parent.height
            label: "SCREEN"
            stateLabel: root.dimmed ? "MINIMUM" : "NORMAL"
            accent: "#9a7cff"
            checked: root.dimmed
            onToggled: root.dimToggleRequested()
        }
    }
}
