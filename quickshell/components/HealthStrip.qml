import QtQuick

Item {
    id: root

    property var health: ({})
    property var connection: ({})
    property bool detailsVisible: false

    signal interacted()

    readonly property var metrics: [
        {
            "label": "CPU",
            "metric": metric("cpu", "%")
        },
        {
            "label": "GPU",
            "metric": metric("gpu", "%")
        },
        {
            "label": "MEM",
            "metric": metric("memory", "%")
        },
        {
            "label": "TEMP",
            "metric": hottestTemperature()
        }
    ]

    function metric(name, unit) {
        var value = health === null || health === undefined
                ? null
                : health[name]
        if (value === null || value === undefined
                || typeof value !== "object")
            return {"available": false, "value": null, "unit": unit}
        return value
    }

    function hottestTemperature() {
        var cpu = metric("cpu_temperature", "°C")
        var gpu = metric("gpu_temperature", "°C")
        if (!cpu.available)
            return gpu
        if (!gpu.available)
            return cpu
        return Number(cpu.value) >= Number(gpu.value) ? cpu : gpu
    }

    function rateText(name, arrow) {
        var value = metric(name, "B/s")
        if (!value.available)
            return arrow + " --"
        var bytes = Math.max(0, Number(value.value || 0))
        if (bytes >= 1000000)
            return arrow + " " + (bytes / 1000000).toFixed(1) + " MB/s"
        if (bytes >= 1000)
            return arrow + " " + (bytes / 1000).toFixed(0) + " KB/s"
        return arrow + " " + Math.round(bytes) + " B/s"
    }

    function batteryText() {
        var battery = metric("battery", "%")
        return battery.available
            ? "BAT " + Math.round(Number(battery.value || 0))
                + String(battery.unit || "%")
            : "BAT --"
    }

    Accessible.role: Accessible.Button
    Accessible.name: "System health strip"

    Rectangle {
        anchors.fill: parent
        radius: 14
        color: root.detailsVisible ? "#0c1726" : "#080f1b"
        border.width: 1
        border.color: root.connection.state === "connected"
            ? "#255d70"
            : "#6c3f50"
    }

    Row {
        anchors {
            fill: parent
            leftMargin: 20
            rightMargin: 20
        }
        spacing: 22

        Item {
            width: 390
            height: parent.height

            Rectangle {
                width: 10
                height: 10
                radius: 5
                anchors {
                    left: parent.left
                    verticalCenter: parent.verticalCenter
                }
                color: root.connection.state === "connected"
                    ? "#6cf7b0"
                    : root.connection.state === "degraded"
                        ? "#ffb45e"
                        : "#ff5d83"
            }

            Text {
                anchors {
                    left: parent.left
                    leftMargin: 22
                    verticalCenter: parent.verticalCenter
                }
                text: root.detailsVisible
                    ? String(root.connection.detail || "HERDR LINK")
                    : "HERDR // "
                        + String(root.connection.state || "UNKNOWN").toUpperCase()
                color: "#c9e4f5"
                elide: Text.ElideRight
                width: parent.width - 26
                font {
                    family: "monospace"
                    pixelSize: 15
                    weight: Font.DemiBold
                    letterSpacing: 0.6
                }
            }
        }

        Repeater {
            model: root.metrics

            Item {
                required property var modelData

                width: 325
                height: parent.height

                Text {
                    anchors {
                        left: parent.left
                        verticalCenter: parent.verticalCenter
                    }
                    text: String(modelData.label)
                    color: "#6386a5"
                    font {
                        family: "monospace"
                        pixelSize: 13
                        weight: Font.DemiBold
                    }
                }

                Rectangle {
                    anchors {
                        left: parent.left
                        leftMargin: 58
                        right: valueText.left
                        rightMargin: 12
                        verticalCenter: parent.verticalCenter
                    }
                    height: 7
                    radius: 4
                    color: "#17283b"

                    Rectangle {
                        width: parent.width * Math.max(0, Math.min(
                            1,
                            Number(modelData.metric.value || 0) / 100
                        ))
                        height: parent.height
                        radius: parent.radius
                        color: Number(modelData.metric.value || 0) >= 85
                            ? "#ff5d83"
                            : Number(modelData.metric.value || 0) >= 65
                                ? "#ffb45e"
                                : "#55e9ff"
                    }
                }

                Text {
                    id: valueText

                    anchors {
                        right: parent.right
                        verticalCenter: parent.verticalCenter
                    }
                    width: 72
                    text: !modelData.metric.available
                        ? "--"
                        : Math.round(Number(modelData.metric.value))
                            + String(modelData.metric.unit)
                    color: "#dff8ff"
                    horizontalAlignment: Text.AlignRight
                    font {
                        family: "monospace"
                        pixelSize: 15
                        weight: Font.Bold
                    }
                }
            }
        }

        Item {
            width: 260
            height: parent.height

            Text {
                anchors.centerIn: parent
                width: parent.width
                text: root.detailsVisible
                    ? root.rateText("network_down", "↓")
                        + "  " + root.rateText("network_up", "↑")
                    : root.batteryText()
                color: "#7696b4"
                elide: Text.ElideRight
                horizontalAlignment: Text.AlignRight
                font {
                    family: "monospace"
                    pixelSize: 13
                }
            }
        }
    }

    TapHandler {
        gesturePolicy: TapHandler.ReleaseWithinBounds
        onTapped: {
            root.detailsVisible = !root.detailsVisible
            root.interacted()
        }
    }
}
