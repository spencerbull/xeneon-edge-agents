import QtQuick
import "../state/ThemePalette.js" as ThemePalette

Rectangle {
    id: root

    property bool open: false
    property var preferences
    property var sourceTheme: ThemePalette.fallback
    property var theme: ThemePalette.fallback

    signal closeRequested()
    signal interactionOccurred()

    readonly property var paletteRoles: ThemePalette.selectableRoles
    readonly property var mappingTargets: [
        {"id": "ready", "label": "READY", "fallback": "muted"},
        {"id": "success", "label": "SUCCESS", "fallback": "green"},
        {"id": "working", "label": "WORKING", "fallback": "blue"},
        {"id": "needsHelp", "label": "NEEDS HELP", "fallback": "yellow"},
        {
            "id": "reviewReady",
            "label": "REVIEW READY",
            "fallback": "green"
        },
        {"id": "error", "label": "ERROR", "fallback": "red"},
        {"id": "unknown", "label": "UNKNOWN", "fallback": "magenta"},
        {"id": "recording", "label": "RECORDING", "fallback": "green"},
        {"id": "processing", "label": "PROCESSING", "fallback": "cyan"}
    ]

    readonly property bool customized:
        storedSelectionFor("ready", "muted") !== "muted"
        || storedSelectionFor("success", "green") !== "green"
        || storedSelectionFor("working", "blue") !== "blue"
        || storedSelectionFor("needsHelp", "yellow") !== "yellow"
        || storedSelectionFor("reviewReady", "green") !== "green"
        || storedSelectionFor("error", "red") !== "red"
        || storedSelectionFor("unknown", "magenta") !== "magenta"
        || storedSelectionFor("recording", "green") !== "green"
        || storedSelectionFor("processing", "cyan") !== "cyan"

    function storedSelectionFor(target, fallbackRole) {
        if (preferences === null || preferences === undefined)
            return fallbackRole
        var value = preferences[target + "ColorRole"]
        if (value === undefined || value === null || String(value) === "")
            return fallbackRole
        return String(value).toLowerCase()
    }

    function selectionFor(target, fallbackRole) {
        if (preferences === null || preferences === undefined)
            return fallbackRole
        switch (target) {
        case "ready":
            return ThemePalette.selectableRole(
                preferences.readyColorRole, fallbackRole
            )
        case "success":
            return ThemePalette.selectableRole(
                preferences.successColorRole, fallbackRole
            )
        case "working":
            return ThemePalette.selectableRole(
                preferences.workingColorRole, fallbackRole
            )
        case "needsHelp":
            return ThemePalette.selectableRole(
                preferences.needsHelpColorRole, fallbackRole
            )
        case "reviewReady":
            return ThemePalette.selectableRole(
                preferences.reviewReadyColorRole, fallbackRole
            )
        case "error":
            return ThemePalette.selectableRole(
                preferences.errorColorRole, fallbackRole
            )
        case "unknown":
            return ThemePalette.selectableRole(
                preferences.unknownColorRole, fallbackRole
            )
        case "recording":
            return ThemePalette.selectableRole(
                preferences.recordingColorRole, fallbackRole
            )
        case "processing":
            return ThemePalette.selectableRole(
                preferences.processingColorRole, fallbackRole
            )
        default:
            return fallbackRole
        }
    }

    function setMapping(target, role) {
        if (preferences === null || preferences === undefined
                || ThemePalette.selectableRoles.indexOf(role) < 0)
            return false
        switch (target) {
        case "ready":
            preferences.readyColorRole = role
            break
        case "success":
            preferences.successColorRole = role
            break
        case "working":
            preferences.workingColorRole = role
            break
        case "needsHelp":
            preferences.needsHelpColorRole = role
            break
        case "reviewReady":
            preferences.reviewReadyColorRole = role
            break
        case "error":
            preferences.errorColorRole = role
            break
        case "unknown":
            preferences.unknownColorRole = role
            break
        case "recording":
            preferences.recordingColorRole = role
            break
        case "processing":
            preferences.processingColorRole = role
            break
        default:
            return false
        }
        if (typeof preferences.sync === "function")
            preferences.sync()
        root.interactionOccurred()
        return true
    }

    function resetMappings() {
        if (preferences === null || preferences === undefined)
            return false
        preferences.readyColorRole = "muted"
        preferences.successColorRole = "green"
        preferences.workingColorRole = "blue"
        preferences.needsHelpColorRole = "yellow"
        preferences.reviewReadyColorRole = "green"
        preferences.errorColorRole = "red"
        preferences.unknownColorRole = "magenta"
        preferences.recordingColorRole = "green"
        preferences.processingColorRole = "cyan"
        if (typeof preferences.sync === "function")
            preferences.sync()
        root.interactionOccurred()
        return true
    }

    function sourceColor(role) {
        return ThemePalette.roleColor(sourceTheme, role, "accent")
    }

    function visibleThemeName() {
        if (sourceTheme !== null && sourceTheme !== undefined
                && sourceTheme.themeName !== undefined) {
            var name = String(sourceTheme.themeName || "").trim()
            if (name !== "")
                return name.toUpperCase()
        }
        return "CURRENT OMARCHY THEME"
    }

    objectName: "paletteSettingsPane"
    width: 960
    height: 610
    radius: 20
    visible: root.open
    enabled: root.open
    color: theme.surface
    border.width: 2
    border.color: theme.borderStrong
    clip: true

    Accessible.role: Accessible.Grouping
    Accessible.ignored: !open
    Accessible.name: "XENEON palette mapping"
    Accessible.description:
        "Assign current Omarchy theme colors to agent application states"

    // Keep taps in blank pane space from reaching cards or ambient wake
    // handling beneath this overlay. Later children remain the topmost hit
    // targets for their own controls.
    Item {
        anchors.fill: parent

        TapHandler {
            gesturePolicy: TapHandler.ReleaseWithinBounds
        }
    }

    Column {
        anchors {
            fill: parent
            margins: 18
        }
        spacing: 8

        Item {
            width: parent.width
            height: 44

            Column {
                anchors {
                    left: parent.left
                    verticalCenter: parent.verticalCenter
                }
                spacing: 1

                Text {
                    text: "PALETTE MAPPING"
                    textFormat: Text.PlainText
                    color: root.theme.textPrimary
                    font {
                        family: "monospace"
                        pixelSize: 18
                        weight: Font.Bold
                        letterSpacing: 1
                    }
                }

                Text {
                    text: "THEME // " + root.visibleThemeName()
                    textFormat: Text.PlainText
                    color: root.theme.textMuted
                    font {
                        family: "monospace"
                        pixelSize: 9
                        letterSpacing: 0.5
                    }
                }
            }

            Rectangle {
                id: closeButton
                objectName: "paletteCloseButton"
                anchors {
                    right: parent.right
                    verticalCenter: parent.verticalCenter
                }
                width: 48
                height: 44
                radius: 12
                color: closeTap.pressed
                    ? root.theme.surfacePressed
                    : root.theme.surfaceRaised
                border.width: 1
                border.color: root.theme.border

                function activate() {
                    if (!enabled)
                        return false
                    root.closeRequested()
                    return true
                }

                Accessible.role: Accessible.Button
                Accessible.name: "Close palette mapping"
                Accessible.onPressAction: activate()

                Text {
                    anchors.centerIn: parent
                    text: "CLOSE"
                    textFormat: Text.PlainText
                    color: root.theme.textPrimary
                    font {
                        family: "monospace"
                        pixelSize: 9
                        weight: Font.Bold
                    }
                }

                TapHandler {
                    id: closeTap
                    gesturePolicy: TapHandler.ReleaseWithinBounds
                    onTapped: closeButton.activate()
                }
            }
        }

        Item {
            width: parent.width
            height: 64

            Text {
                id: sourcePaletteLabel
                anchors {
                    left: parent.left
                    top: parent.top
                }
                text: "CURRENT THEME COLORS"
                textFormat: Text.PlainText
                color: root.theme.textSecondary
                font {
                    family: "monospace"
                    pixelSize: 10
                    weight: Font.DemiBold
                    letterSpacing: 0.6
                }
            }

            Row {
                anchors {
                    left: parent.left
                    right: parent.right
                    top: sourcePaletteLabel.bottom
                    topMargin: 5
                }
                height: 48

                Repeater {
                    model: root.paletteRoles

                    Item {
                        required property string modelData
                        width: parent.width / root.paletteRoles.length
                        height: parent.height

                        Column {
                            anchors.centerIn: parent
                            spacing: 3

                            Rectangle {
                                anchors.horizontalCenter: parent.horizontalCenter
                                width: 24
                                height: 24
                                radius: 12
                                color: root.sourceColor(parent.parent.modelData)
                                border.width: 1
                                border.color: root.theme.textSecondary
                            }

                            Text {
                                width: parent.parent.width - 4
                                text: parent.parent.modelData.toUpperCase()
                                textFormat: Text.PlainText
                                color: root.theme.textMuted
                                elide: Text.ElideRight
                                horizontalAlignment: Text.AlignHCenter
                                font {
                                    family: "monospace"
                                    pixelSize: 9
                                    weight: Font.DemiBold
                                }
                            }
                        }
                    }
                }
            }
        }

        Item {
            width: parent.width
            height: root.mappingTargets.length * 44

            Column {
                anchors.fill: parent

                Repeater {
                    model: root.mappingTargets

                    Item {
                        id: mappingRow
                        required property var modelData
                        width: parent.width
                        height: 44

                        Text {
                            anchors {
                                left: parent.left
                                verticalCenter: parent.verticalCenter
                            }
                            width: 160
                            text: mappingRow.modelData.label
                            textFormat: Text.PlainText
                            color: root.theme.textPrimary
                            elide: Text.ElideRight
                            font {
                                family: "monospace"
                                pixelSize: 11
                                weight: Font.Bold
                                letterSpacing: 0.5
                            }
                        }

                        Row {
                            anchors {
                                left: parent.left
                                right: parent.right
                                leftMargin: 160
                            }
                            height: parent.height

                            Repeater {
                                model: root.paletteRoles

                                Rectangle {
                                    id: roleButton
                                    required property string modelData
                                    readonly property bool selected:
                                        root.selectionFor(
                                            mappingRow.modelData.id,
                                            mappingRow.modelData.fallback
                                        ) === modelData

                                    objectName: "paletteRole_"
                                        + mappingRow.modelData.id + "_"
                                        + modelData
                                    width: parent.width / root.paletteRoles.length
                                    height: parent.height
                                    radius: 10
                                    color: roleTap.pressed
                                        ? root.theme.surfacePressed
                                        : selected
                                            ? Qt.alpha(
                                                root.sourceColor(modelData),
                                                0.16
                                            )
                                            : "transparent"
                                    border.width: selected ? 2 : 0
                                    border.color: root.theme.textPrimary

                                    function activate() {
                                        return root.setMapping(
                                            mappingRow.modelData.id,
                                            modelData
                                        )
                                    }

                                    Accessible.role: Accessible.RadioButton
                                    Accessible.name: mappingRow.modelData.label
                                        + " uses " + modelData
                                    Accessible.checkable: true
                                    Accessible.checked: selected
                                    Accessible.onPressAction: activate()

                                    Rectangle {
                                        anchors.centerIn: parent
                                        width: roleButton.selected ? 24 : 18
                                        height: width
                                        radius: width / 2
                                        color: root.sourceColor(roleButton.modelData)
                                        border.width: 1
                                        border.color: root.theme.textSecondary

                                        Text {
                                            anchors.centerIn: parent
                                            visible: roleButton.selected
                                            text: "✓"
                                            textFormat: Text.PlainText
                                            color: ThemePalette.ensureContrast(
                                                String(root.theme.textPrimary),
                                                String(root.sourceColor(
                                                    roleButton.modelData
                                                )),
                                                4.5
                                            )
                                            font {
                                                family: "monospace"
                                                pixelSize: 14
                                                weight: Font.Bold
                                            }
                                        }
                                    }

                                    TapHandler {
                                        id: roleTap
                                        gesturePolicy:
                                            TapHandler.ReleaseWithinBounds
                                        onTapped: roleButton.activate()
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        Item {
            width: parent.width
            height: 44

            Text {
                anchors {
                    left: parent.left
                    verticalCenter: parent.verticalCenter
                }
                width: parent.width - resetButton.width - 18
                text: "CHROME AND TEXT CONTRAST REMAIN AUTOMATIC"
                textFormat: Text.PlainText
                color: root.theme.textMuted
                elide: Text.ElideRight
                font {
                    family: "monospace"
                    pixelSize: 9
                    letterSpacing: 0.5
                }
            }

            Rectangle {
                id: resetButton
                objectName: "paletteResetButton"
                anchors {
                    right: parent.right
                    verticalCenter: parent.verticalCenter
                }
                width: 150
                height: 44
                radius: 12
                color: resetTap.pressed
                    ? root.theme.surfacePressed
                    : root.theme.surfaceRaised
                border.width: 1
                border.color: root.customized
                    ? root.theme.accent
                    : root.theme.border
                enabled: root.customized

                function activate() {
                    if (!enabled)
                        return false
                    return root.resetMappings()
                }

                Accessible.role: Accessible.Button
                Accessible.ignored: !enabled
                Accessible.name: "Reset palette mappings"
                Accessible.description: "Restore the reviewed default roles"
                Accessible.onPressAction: activate()

                Text {
                    anchors.centerIn: parent
                    text: "RESET DEFAULTS"
                    textFormat: Text.PlainText
                    color: resetButton.enabled
                        ? root.theme.textPrimary
                        : root.theme.textMuted
                    font {
                        family: "monospace"
                        pixelSize: 9
                        weight: Font.Bold
                    }
                }

                TapHandler {
                    id: resetTap
                    enabled: resetButton.enabled
                    gesturePolicy: TapHandler.ReleaseWithinBounds
                    onTapped: resetButton.activate()
                }
            }
        }
    }
}
