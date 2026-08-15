import QtQuick
import QtQuick.Shapes
import "../state/ThemePalette.js" as ThemePalette

Item {
    id: root

    property real centerX: width / 2
    property real centerY: height / 2
    property real radiusX: 320
    property real radiusY: 170
    property real angleDegrees: 0
    property real reveal: 0
    property color accent: ThemePalette.fallback.accent
    property real sweepDegrees: 44

    // One broad after-image is built from nested arcs that share the same head.
    // Longer arcs are thinner and dimmer; shorter arcs thicken toward the
    // moving pill. This reads as one tapered ribbon without a surface blur.
    readonly property int segmentCount: 8
    readonly property real headGapDegrees: 5
    readonly property real segmentSweep:
        Math.max(1, sweepDegrees / segmentCount)

    visible: reveal > 0

    Repeater {
        model: root.segmentCount

        Shape {
            id: trailSegment

            required property int index

            anchors.fill: parent
            readonly property real headWeight:
                index / (root.segmentCount - 1)
            readonly property real lengthFraction:
                (root.segmentCount - index) / root.segmentCount
            opacity: root.reveal
                * (0.005 + headWeight * headWeight * 0.045)

            ShapePath {
                fillColor: "transparent"
                strokeColor: root.accent
                strokeWidth: 8 + trailSegment.headWeight * 34
                capStyle: ShapePath.RoundCap
                joinStyle: ShapePath.RoundJoin

                PathAngleArc {
                    centerX: root.centerX
                    centerY: root.centerY
                    radiusX: root.radiusX
                    radiusY: root.radiusY
                    startAngle: root.angleDegrees
                        - root.headGapDegrees
                        - root.sweepDegrees
                            * trailSegment.lengthFraction
                    sweepAngle: root.sweepDegrees
                        * trailSegment.lengthFraction
                    moveToStart: true
                }
            }
        }
    }
}
