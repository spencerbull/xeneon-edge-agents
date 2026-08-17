import QtQuick
import "../state/ThemePalette.js" as ThemePalette

Item {
    id: root

    property var voice: ({})
    property var theme: ThemePalette.fallback
    property bool reducedMotion: false
    property bool actionsEnabled: true
    property bool pressOwned: false

    signal startRequested()
    signal stopRequested()
    signal cancelRequested()
    signal interacted()

    readonly property string voiceState: String(
        voice.state || "unavailable"
    ).toLowerCase()
    readonly property bool available: voice.available === true
    readonly property bool daemonOwned: voice.owned === true
    readonly property color accent: voiceState === "recording"
        ? theme.recording
        : voiceState === "processing"
            ? theme.processing
            : voiceState === "error"
                ? theme.error
                : theme.ready
    readonly property color controlBackground:
        pressHandler.pressed || voiceState === "recording"
            ? ThemePalette.mixColors(
                String(theme.surfaceRaised),
                String(accent),
                0.2
            )
            : theme.surfaceRaised
    readonly property color readableAccent: ThemePalette.ensureContrast(
        String(accent),
        String(controlBackground),
        4.5
    )
    readonly property color readableSecondary: ThemePalette.ensureContrast(
        String(theme.textMuted),
        String(controlBackground),
        4.5
    )
    readonly property bool ownedError: voiceState === "error"
        && daemonOwned
    readonly property string stateLabel: voiceState === "recording"
        ? "RECORDING"
        : voiceState === "processing"
            ? "PROCESSING"
            : voiceState === "error"
                ? ownedError
                    ? "VOICE NEEDS CANCEL"
                    : "HOLD TO RETRY"
                : available
                    ? "HOLD TO TALK"
                    : "VOICE OFFLINE"

    function beginPress() {
        if (!actionsEnabled || !available
                || (voiceState !== "idle"
                    && !(voiceState === "error" && !daemonOwned))
                || pressOwned)
            return false
        pressOwned = true
        interacted()
        startRequested()
        return true
    }

    function finishPress() {
        if (!pressOwned)
            return false
        pressOwned = false
        interacted()
        stopRequested()
        return true
    }

    function accessibleToggle() {
        if (!actionsEnabled || !available)
            return false
        interacted()
        if (voiceState === "idle"
                || (voiceState === "error" && !daemonOwned)) {
            startRequested()
            return true
        }
        if ((voiceState === "recording" || voiceState === "error")
                && daemonOwned) {
            if (voiceState === "error")
                cancelRequested()
            else
                stopRequested()
            return true
        }
        return false
    }

    enabled: root.actionsEnabled && root.available

    Accessible.role: Accessible.Button
    Accessible.ignored: !root.enabled || !root.actionsEnabled
    Accessible.name: "Voice dictation"
    Accessible.description: root.stateLabel
    Accessible.onPressAction: root.accessibleToggle()

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: root.controlBackground
        border.width: root.voiceState === "recording" ? 2 : 1
        border.color: Qt.alpha(root.accent, root.available ? 0.72 : 0.28)

        Behavior on color {
            ColorAnimation {
                duration: root.reducedMotion ? 0 : 140
            }
        }

        Behavior on border.color {
            ColorAnimation {
                duration: root.reducedMotion ? 0 : 180
            }
        }
    }

    Item {
        id: voiceGlyph

        anchors {
            left: parent.left
            leftMargin: 14
            verticalCenter: parent.verticalCenter
        }
        width: 40
        height: 40

        Rectangle {
            anchors.centerIn: parent
            width: 19
            height: 27
            radius: 10
            color: "transparent"
            border.width: 2
            border.color: root.accent
        }

        Rectangle {
            anchors {
                horizontalCenter: parent.horizontalCenter
                bottom: parent.bottom
                bottomMargin: 5
            }
            width: 2
            height: 8
            radius: 1
            color: root.accent
        }

        Rectangle {
            anchors {
                horizontalCenter: parent.horizontalCenter
                bottom: parent.bottom
                bottomMargin: 4
            }
            width: 18
            height: 2
            radius: 1
            color: root.accent
        }

        SequentialAnimation {
            running: !root.reducedMotion
                && root.voiceState === "recording"
            loops: Animation.Infinite

            NumberAnimation {
                target: voiceGlyph
                property: "scale"
                from: 0.9
                to: 1.08
                duration: 520
                easing.type: Easing.InOutSine
            }
            NumberAnimation {
                target: voiceGlyph
                property: "scale"
                from: 1.08
                to: 0.9
                duration: 520
                easing.type: Easing.InOutSine
            }
        }
    }

    Column {
        anchors {
            left: voiceGlyph.right
            leftMargin: 10
            right: cancelButton.visible ? cancelButton.left : parent.right
            rightMargin: 12
            verticalCenter: parent.verticalCenter
        }
        spacing: 1

        Text {
            width: parent.width
            text: root.stateLabel
            textFormat: Text.PlainText
            color: root.readableAccent
            elide: Text.ElideRight
            font {
                family: "monospace"
                pixelSize: 13
                weight: Font.Bold
                letterSpacing: 0.8
            }
        }

        Text {
            width: parent.width
            text: root.voiceState === "recording"
                ? "RELEASE TO TRANSCRIBE"
                : root.voiceState === "processing"
                    ? "TYPING INTO FOCUSED APP"
                    : root.voiceState === "error"
                        ? root.ownedError
                            ? "DISCARD PORTAL RECORDING"
                            : "RETRY OR CHECK VOXTYPE"
                    : "OMARCHY // VOXTYPE"
            textFormat: Text.PlainText
            color: root.readableSecondary
            elide: Text.ElideRight
            font {
                family: "monospace"
                pixelSize: 9
                letterSpacing: 0.55
            }
        }
    }

    Rectangle {
        id: cancelButton

        anchors {
            right: parent.right
            rightMargin: 8
            verticalCenter: parent.verticalCenter
        }
        visible: root.daemonOwned
            && (root.voiceState === "recording"
                || root.voiceState === "processing"
                || root.voiceState === "error")
        width: 68
        height: parent.height - 14
        radius: height / 2
        color: cancelHandler.pressed
            ? Qt.alpha(root.theme.error, 0.28)
            : Qt.alpha(root.theme.error, 0.14)
        border.width: 1
        border.color: root.theme.error
        z: 4

        Accessible.role: Accessible.Button
        Accessible.ignored: !root.enabled || !root.actionsEnabled
        Accessible.name: "Cancel voice dictation"
        Accessible.onPressAction: {
            if (root.enabled && root.actionsEnabled) {
                root.interacted()
                root.cancelRequested()
            }
        }

        Text {
            anchors.centerIn: parent
            text: "CANCEL"
            textFormat: Text.PlainText
            color: ThemePalette.ensureContrast(
                String(root.theme.error),
                String(root.theme.surfaceRaised),
                4.5
            )
            font {
                family: "monospace"
                pixelSize: 10
                weight: Font.Bold
                letterSpacing: 0.6
            }
        }

        TapHandler {
            id: cancelHandler

            gesturePolicy: TapHandler.ReleaseWithinBounds
            onTapped: {
                root.pressOwned = false
                root.interacted()
                root.cancelRequested()
            }
        }
    }

    TapHandler {
        id: pressHandler

        acceptedButtons: Qt.LeftButton
        gesturePolicy: TapHandler.DragThreshold
        onPressedChanged: {
            if (pressed)
                root.beginPress()
            else
                root.finishPress()
        }
    }
}
