import QtQuick
import "../state/ThemePalette.js" as ThemePalette

Item {
    id: root

    property bool motionReduced: false
    property bool dimmed: false
    property bool motionForced: false
    property var theme: ThemePalette.fallback

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
            accent: root.theme.accent
            theme: root.theme
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
            accent: root.theme.magenta
            theme: root.theme
            checked: root.dimmed
            onToggled: root.dimToggleRequested()
        }
    }
}
