import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import "PortalPalette.js" as Palette

Item {
    id: root

    property var agents: []
    property var voice: ({})
    property string connectionState: "reconnecting"
    property bool reducedMotion: false
    property bool suppressRunners: false
    property real phase: 0

    readonly property string mode: Palette.perimeterMode(agents)
    readonly property color accent: Palette.ambientColor(mode)
    readonly property bool active: mode !== "off" && !suppressRunners
    readonly property bool moving: active && !reducedMotion
    readonly property int runnerCount: 2
    readonly property real runnerOffset: 0.5
    readonly property real runnerSpan: 0.105
    readonly property real coreSpan: 0.012
    readonly property int particleCountPerRunner: 6
    readonly property int glowBlurMax: 48
    readonly property real haloMargin: 10
    readonly property real haloRadius: 22
    readonly property real haloWidth: Math.max(1, width - 2 * haloMargin)
    readonly property real haloHeight: Math.max(1, height - 2 * haloMargin)
    readonly property real haloPerimeter:
        2 * Math.max(0, haloWidth - 2 * haloRadius)
        + 2 * Math.max(0, haloHeight - 2 * haloRadius)
        + 2 * Math.PI * haloRadius
    readonly property int travelDuration: Math.max(
        1,
        Palette.haloDuration(mode)
    )

    function wrapped(value) {
        var normalized = value % 1
        return normalized < 0 ? normalized + 1 : normalized
    }

    function perimeterPoint(progress, canvasWidth, canvasHeight, radius) {
        var width = Math.max(1, canvasWidth)
        var height = Math.max(1, canvasHeight)
        var corner = Math.max(
            1,
            Math.min(radius, Math.min(width, height) / 2)
        )
        var horizontal = Math.max(0, width - 2 * corner)
        var vertical = Math.max(0, height - 2 * corner)
        var arc = Math.PI * corner / 2
        var perimeter = 2 * horizontal + 2 * vertical + 4 * arc
        var distance = wrapped(progress) * perimeter

        if (distance <= horizontal)
            return {"x": corner + distance, "y": 0}
        distance -= horizontal
        if (distance <= arc) {
            var topRightAngle = -Math.PI / 2 + distance / corner
            return {
                "x": width - corner + Math.cos(topRightAngle) * corner,
                "y": corner + Math.sin(topRightAngle) * corner
            }
        }
        distance -= arc
        if (distance <= vertical)
            return {"x": width, "y": corner + distance}
        distance -= vertical
        if (distance <= arc) {
            var bottomRightAngle = distance / corner
            return {
                "x": width - corner + Math.cos(bottomRightAngle) * corner,
                "y": height - corner
                    + Math.sin(bottomRightAngle) * corner
            }
        }
        distance -= arc
        if (distance <= horizontal)
            return {"x": width - corner - distance, "y": height}
        distance -= horizontal
        if (distance <= arc) {
            var bottomLeftAngle = Math.PI / 2 + distance / corner
            return {
                "x": corner + Math.cos(bottomLeftAngle) * corner,
                "y": height - corner
                    + Math.sin(bottomLeftAngle) * corner
            }
        }
        distance -= arc
        if (distance <= vertical)
            return {"x": 0, "y": height - corner - distance}
        distance -= vertical
        var topLeftAngle = Math.PI + distance / corner
        return {
            "x": corner + Math.cos(topLeftAngle) * corner,
            "y": corner + Math.sin(topLeftAngle) * corner
        }
    }

    NumberAnimation on phase {
        running: root.moving
        from: 0
        to: 1
        duration: root.travelDuration
        loops: Animation.Infinite
    }

    onActiveChanged: {
        if (!active)
            phase = 0
    }

    Rectangle {
        anchors {
            fill: parent
            margins: root.haloMargin
        }
        radius: root.haloRadius
        color: "transparent"
        border.width: root.active ? 2 : 0
        border.color: Qt.alpha(root.accent, 0.16)
        opacity: root.active ? 1 : 0
    }

    Shape {
        id: runnerGlowSource

        anchors {
            fill: parent
            margins: root.haloMargin
        }
        visible: false
        preferredRendererType: Shape.CurveRenderer

        readonly property real strokeWidth: 14
        readonly property real dashLength: Math.max(
            1,
            root.haloPerimeter * root.runnerSpan / strokeWidth
        )
        readonly property real gapLength: Math.max(
            1,
            (root.haloPerimeter / root.runnerCount
                - root.haloPerimeter * root.runnerSpan) / strokeWidth
        )

        ShapePath {
            strokeColor: root.accent
            strokeWidth: runnerGlowSource.strokeWidth
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            strokeStyle: ShapePath.DashLine
            dashPattern: [
                runnerGlowSource.dashLength,
                runnerGlowSource.gapLength
            ]
            dashOffset: root.phase
                * root.haloPerimeter
                / runnerGlowSource.strokeWidth
            startX: root.haloRadius
            startY: 0

            PathLine {
                x: root.haloWidth - root.haloRadius
                y: 0
            }
            PathArc {
                x: root.haloWidth
                y: root.haloRadius
                radiusX: root.haloRadius
                radiusY: root.haloRadius
                direction: PathArc.Clockwise
            }
            PathLine {
                x: root.haloWidth
                y: root.haloHeight - root.haloRadius
            }
            PathArc {
                x: root.haloWidth - root.haloRadius
                y: root.haloHeight
                radiusX: root.haloRadius
                radiusY: root.haloRadius
                direction: PathArc.Clockwise
            }
            PathLine {
                x: root.haloRadius
                y: root.haloHeight
            }
            PathArc {
                x: 0
                y: root.haloHeight - root.haloRadius
                radiusX: root.haloRadius
                radiusY: root.haloRadius
                direction: PathArc.Clockwise
            }
            PathLine {
                x: 0
                y: root.haloRadius
            }
            PathArc {
                x: root.haloRadius
                y: 0
                radiusX: root.haloRadius
                radiusY: root.haloRadius
                direction: PathArc.Clockwise
            }
        }
    }

    MultiEffect {
        objectName: "perimeterHaloBloom"
        anchors.fill: runnerGlowSource
        source: runnerGlowSource
        visible: root.active
        autoPaddingEnabled: true
        blurEnabled: true
        blur: 1
        blurMax: root.glowBlurMax
        blurMultiplier: 1.25
        brightness: 0.52
        colorization: 0.72
        colorizationColor: root.accent
        opacity: root.active ? 1 : 0

        Behavior on opacity {
            NumberAnimation {
                duration: root.reducedMotion ? 0 : 240
                easing.type: Easing.OutCubic
            }
        }
    }

    Repeater {
        model: root.runnerCount * root.particleCountPerRunner

        Item {
            required property int index

            readonly property int runnerIndex:
                Math.floor(index / root.particleCountPerRunner)
            readonly property int particleIndex:
                index % root.particleCountPerRunner
            readonly property real trailRatio:
                (particleIndex + 1) / (root.particleCountPerRunner + 1)
            readonly property real particleProgress: root.wrapped(
                root.phase
                    + runnerIndex * root.runnerOffset
                    - root.runnerSpan * (0.18 + trailRatio * 0.82)
            )
            readonly property var point: root.perimeterPoint(
                particleProgress,
                root.haloWidth,
                root.haloHeight,
                root.haloRadius
            )
            readonly property real glowSize:
                20 - trailRatio * 9 + (particleIndex % 2) * 3
            readonly property real particleOpacity:
                0.48 * Math.pow(1 - trailRatio, 1.7)

            x: root.haloMargin + point.x - width / 2
            y: root.haloMargin + point.y - height / 2
            width: glowSize
            height: glowSize
            visible: root.moving
            opacity: root.active ? particleOpacity : 0

            Rectangle {
                anchors.fill: parent
                radius: width / 2
                color: Qt.alpha(root.accent, 0.18)
            }

            Rectangle {
                anchors.centerIn: parent
                width: Math.max(2, parent.width * 0.2)
                height: width
                radius: width / 2
                color: root.accent
                opacity: 0.9
            }
        }
    }

    Shape {
        id: runnerCore

        objectName: "perimeterHaloRunners"
        anchors {
            fill: parent
            margins: root.haloMargin
        }
        visible: root.active
        opacity: root.active ? 0.16 : 0
        preferredRendererType: Shape.CurveRenderer

        readonly property real strokeWidth: 1.75
        readonly property real dashLength: Math.max(
            1,
            root.haloPerimeter * root.coreSpan / strokeWidth
        )
        readonly property real gapLength: Math.max(
            1,
            (root.haloPerimeter / root.runnerCount
                - root.haloPerimeter * root.coreSpan) / strokeWidth
        )

        ShapePath {
            strokeColor: "#e8fbff"
            strokeWidth: runnerCore.strokeWidth
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            strokeStyle: ShapePath.DashLine
            dashPattern: [runnerCore.dashLength, runnerCore.gapLength]
            dashOffset: root.phase
                * root.haloPerimeter
                / runnerCore.strokeWidth
            startX: root.haloRadius
            startY: 0

            PathLine {
                x: root.haloWidth - root.haloRadius
                y: 0
            }
            PathArc {
                x: root.haloWidth
                y: root.haloRadius
                radiusX: root.haloRadius
                radiusY: root.haloRadius
                direction: PathArc.Clockwise
            }
            PathLine {
                x: root.haloWidth
                y: root.haloHeight - root.haloRadius
            }
            PathArc {
                x: root.haloWidth - root.haloRadius
                y: root.haloHeight
                radiusX: root.haloRadius
                radiusY: root.haloRadius
                direction: PathArc.Clockwise
            }
            PathLine {
                x: root.haloRadius
                y: root.haloHeight
            }
            PathArc {
                x: 0
                y: root.haloHeight - root.haloRadius
                radiusX: root.haloRadius
                radiusY: root.haloRadius
                direction: PathArc.Clockwise
            }
            PathLine {
                x: 0
                y: root.haloRadius
            }
            PathArc {
                x: root.haloRadius
                y: 0
                radiusX: root.haloRadius
                radiusY: root.haloRadius
                direction: PathArc.Clockwise
            }
        }

        Behavior on opacity {
            NumberAnimation {
                duration: root.reducedMotion ? 0 : 240
                easing.type: Easing.OutCubic
            }
        }
    }

    Rectangle {
        anchors {
            horizontalCenter: parent.horizontalCenter
            top: parent.top
            topMargin: 9
        }
        width: haloText.implicitWidth + 30
        height: root.active ? 27 : 0
        radius: 14
        color: "#e8070d18"
        border.width: height > 0 ? 1 : 0
        border.color: Qt.alpha(root.accent, 0.48)
        clip: true
        opacity: root.active ? 1 : 0

        Text {
            id: haloText

            anchors.centerIn: parent
            text: Palette.ambientLabel(root.mode)
            textFormat: Text.PlainText
            color: root.accent
            font {
                family: "monospace"
                pixelSize: 11
                weight: Font.DemiBold
                letterSpacing: 1.1
            }
        }

        Behavior on height {
            NumberAnimation {
                duration: root.reducedMotion ? 0 : 200
                easing.type: Easing.OutCubic
            }
        }

        Behavior on opacity {
            NumberAnimation {
                duration: root.reducedMotion ? 0 : 160
            }
        }
    }
}
