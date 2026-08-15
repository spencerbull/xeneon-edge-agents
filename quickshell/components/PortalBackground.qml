import QtQuick
import "../state/ThemePalette.js" as ThemePalette

Item {
    id: root

    property var theme: ThemePalette.fallback
    property bool reducedMotion: false
    property bool ambientMode: false

    Rectangle {
        anchors.fill: parent
        color: root.theme.canvas
        gradient: Gradient {
            GradientStop {
                position: 0
                color: root.theme.canvas
            }
            GradientStop {
                position: 0.54
                color: root.theme.surface
            }
            GradientStop {
                position: 1
                color: root.ambientMode
                    ? Qt.alpha(root.theme.magenta, 0.16)
                    : Qt.alpha(root.theme.accent, 0.12)
            }
        }
    }

    Repeater {
        model: 33

        Rectangle {
            required property int index

            x: index * 80
            width: 1
            height: root.height
            color: root.theme.accent
            opacity: index % 4 === 0 ? 0.24 : 0.12
        }
    }

    Repeater {
        model: 10

        Rectangle {
            required property int index

            y: index * 80
            width: root.width
            height: 1
            color: root.theme.border
            opacity: index % 2 === 0 ? 0.2 : 0.1
        }
    }

    Repeater {
        model: 22

        Rectangle {
            required property int index

            x: (index * 347 + 83) % 2520
            y: (index * 173 + 47) % 680
            width: index % 5 === 0 ? 4 : 2
            height: width
            radius: width / 2
            color: index % 3 === 0
                ? root.theme.accentSecondary
                : root.theme.magenta
            opacity: 0.18 + (index % 4) * 0.08
        }
    }

    Rectangle {
        id: horizonGlow

        x: -160
        y: 558
        width: root.width + 320
        height: 180
        radius: height / 2
        color: "transparent"
        border.width: 2
        border.color: root.theme.blue
        opacity: root.ambientMode ? 0.42 : 0.22
    }

    Rectangle {
        id: scanline

        width: root.width
        height: 2
        y: -4
        color: root.theme.accentSecondary
        opacity: 0.15

        NumberAnimation on y {
            from: -4
            to: root.height + 4
            duration: root.ambientMode ? 9000 : 14000
            loops: Animation.Infinite
            running: !root.reducedMotion
        }
    }
}
