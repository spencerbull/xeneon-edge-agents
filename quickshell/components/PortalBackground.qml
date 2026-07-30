import QtQuick

Item {
    id: root

    property bool reducedMotion: false
    property bool ambientMode: false

    Rectangle {
        anchors.fill: parent
        color: "#02050b"
        gradient: Gradient {
            GradientStop {
                position: 0
                color: root.ambientMode ? "#020813" : "#03101a"
            }
            GradientStop {
                position: 0.54
                color: "#05091a"
            }
            GradientStop {
                position: 1
                color: root.ambientMode ? "#09051a" : "#100721"
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
            color: index % 4 === 0 ? "#19436a" : "#102942"
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
            color: index % 2 === 0 ? "#153c60" : "#10263d"
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
            color: index % 3 === 0 ? "#62f5ff" : "#9367ff"
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
        border.color: "#173c7a"
        opacity: root.ambientMode ? 0.42 : 0.22
    }

    Rectangle {
        id: scanline

        width: root.width
        height: 2
        y: -4
        color: "#5cf6ff"
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
