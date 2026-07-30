import QtQuick

Item {
    id: root

    property bool active: false
    property bool reducedMotion: false
    property var agents: []
    property var health: ({})

    signal wakeRequested()

    visible: active || opacity > 0
    enabled: visible
    opacity: active ? 1 : 0
    z: 40

    Accessible.role: Accessible.Button
    Accessible.name: "Wake agent portal"
    Accessible.onPressAction: root.wakeRequested()

    Behavior on opacity {
        NumberAnimation {
            duration: root.reducedMotion ? 0 : 480
            easing.type: Easing.OutCubic
        }
    }

    Rectangle {
        anchors.fill: parent
        color: "#ed020711"
    }

    Item {
        id: constellation

        width: 940
        height: 500
        anchors.centerIn: parent
        transformOrigin: Item.Center

        RotationAnimator on rotation {
            from: -1.2
            to: 1.2
            duration: 8000
            loops: Animation.Infinite
            running: root.active && !root.reducedMotion
        }

        Repeater {
            model: 4

            Rectangle {
                required property int index

                width: 250 + index * 130
                height: width
                radius: width / 2
                anchors.centerIn: parent
                color: "transparent"
                border.width: 1
                border.color: index % 2 === 0 ? "#245b81" : "#49337a"
                opacity: 0.28 - index * 0.035
            }
        }

        Repeater {
            model: Math.min(6, root.agents.length)

            Item {
                required property int index

                readonly property var agent: root.agents[index]
                readonly property real angle:
                    (Math.PI * 2 * index / Math.max(1, Math.min(
                        6,
                        root.agents.length
                    ))) - Math.PI / 2

                x: constellation.width / 2 + Math.cos(angle) * 330 - 66
                y: constellation.height / 2 + Math.sin(angle) * 176 - 42
                width: 132
                height: 84

                Rectangle {
                    anchors.fill: parent
                    radius: 42
                    color: "#bc0c1727"
                    border.width: 2
                    border.color: root.stateColor(
                        String(parent.agent.status || "unknown")
                    )
                }

                Text {
                    anchors {
                        left: parent.left
                        right: parent.right
                        verticalCenter: parent.verticalCenter
                        margins: 12
                    }
                    text: String(
                        parent.agent.display_name || "AGENT"
                    ).toUpperCase()
                    textFormat: Text.PlainText
                    color: "#dff8ff"
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    font {
                        family: "monospace"
                        pixelSize: 12
                        weight: Font.DemiBold
                        letterSpacing: 0.6
                    }
                }
            }
        }
    }

    Column {
        anchors.centerIn: parent
        spacing: 8

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "AMBIENT"
            textFormat: Text.PlainText
            color: "#7beeff"
            font {
                family: "monospace"
                pixelSize: 34
                weight: Font.Light
                letterSpacing: 8
            }
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.agents.length + " AGENTS // "
                + String(root.health.status || "UNKNOWN").toUpperCase()
            textFormat: Text.PlainText
            color: "#6d8da9"
            font {
                family: "monospace"
                pixelSize: 14
                letterSpacing: 1.4
            }
        }
    }

    Text {
        anchors {
            horizontalCenter: parent.horizontalCenter
            bottom: parent.bottom
            bottomMargin: 30
        }
        text: "TOUCH TO WAKE"
        textFormat: Text.PlainText
        color: "#7892ad"
        font {
            family: "monospace"
            pixelSize: 13
            letterSpacing: 2
        }
    }

    TapHandler {
        gesturePolicy: TapHandler.ReleaseWithinBounds
        onTapped: root.wakeRequested()
    }

    function stateColor(state) {
        switch (state) {
        case "blocked":
            return "#ff9d52"
        case "done":
            return "#b98cff"
        case "working":
            return "#4fe9ff"
        case "idle":
            return "#6cf7b0"
        default:
            return "#72829a"
        }
    }
}
