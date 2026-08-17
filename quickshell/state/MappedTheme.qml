import QtQuick
import "ThemePalette.js" as ThemePalette

QtObject {
    id: root

    required property var sourceTheme
    required property var preferences

    readonly property var selectableRoles: ThemePalette.selectableRoles

    function mappedColor(preferenceName, fallbackRole) {
        return ThemePalette.roleColor(
            sourceTheme,
            preferences[preferenceName],
            fallbackRole
        )
    }

    // Raw Omarchy roles remain available for chrome and provider accents.
    readonly property string mode: sourceTheme.mode
    readonly property color background: sourceTheme.background
    readonly property color darkBackground: sourceTheme.darkBackground
    readonly property color lighterBackground: sourceTheme.lighterBackground
    readonly property color foreground: sourceTheme.foreground
    readonly property color muted: sourceTheme.muted
    readonly property color accent: sourceTheme.accent
    readonly property color red: sourceTheme.red
    readonly property color green: sourceTheme.green
    readonly property color yellow: sourceTheme.yellow
    readonly property color blue: sourceTheme.blue
    readonly property color magenta: sourceTheme.magenta
    readonly property color cyan: sourceTheme.cyan
    readonly property color orange: sourceTheme.orange

    readonly property color canvas: sourceTheme.canvas
    readonly property color surface: sourceTheme.surface
    readonly property color surfaceRaised: sourceTheme.surfaceRaised
    readonly property color surfacePressed: sourceTheme.surfacePressed
    readonly property color textPrimary: sourceTheme.textPrimary
    readonly property color textSecondary: sourceTheme.textSecondary
    readonly property color textMuted: sourceTheme.textMuted
    readonly property color border: sourceTheme.border
    readonly property color borderStrong: sourceTheme.borderStrong
    readonly property color accentSecondary: sourceTheme.accentSecondary

    // XENEON semantic roles are independently assignable to current Omarchy
    // palette entries. No arbitrary colors cross this presentation boundary.
    readonly property color ready:
        mappedColor("readyColorRole", "muted")
    readonly property color success:
        mappedColor("successColorRole", "green")
    readonly property color working:
        mappedColor("workingColorRole", "blue")
    readonly property color needsHelp:
        mappedColor("needsHelpColorRole", "yellow")
    readonly property color reviewReady:
        mappedColor("reviewReadyColorRole", "green")
    readonly property color error:
        mappedColor("errorColorRole", "red")
    readonly property color unknown:
        mappedColor("unknownColorRole", "magenta")
    readonly property color recording:
        mappedColor("recordingColorRole", "green")
    readonly property color processing:
        mappedColor("processingColorRole", "cyan")
}
