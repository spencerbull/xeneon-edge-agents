import QtQuick
import Quickshell
import Quickshell.Io
import "ThemePalette.js" as ThemePalette

Scope {
    id: root

    property string themeRoot: {
        var override = String(
            Quickshell.env("XENEON_EDGE_THEME_ROOT") || ""
        )
        if (override !== "")
            return override
        var stateHome = String(Quickshell.env("XDG_STATE_HOME") || "")
        if (stateHome === "")
            stateHome = String(Quickshell.env("HOME") || "")
                + "/.local/state"
        return stateHome + "/omarchy/current"
    }
    readonly property string themeNamePath: themeRoot + "/theme.name"
    readonly property string colorsPath: themeRoot + "/theme/colors.toml"

    property string themeName: ""
    property bool paletteLoaded: false
    property int paletteGeneration: 0
    property string colorsReadPath: ""

    property string mode: ThemePalette.fallback.mode
    property color background: ThemePalette.fallback.background
    property color darkBackground: ThemePalette.fallback.darkBackground
    property color lighterBackground: ThemePalette.fallback.lighterBackground
    property color foreground: ThemePalette.fallback.foreground
    property color muted: ThemePalette.fallback.muted
    property color accent: ThemePalette.fallback.accent
    property color red: ThemePalette.fallback.red
    property color green: ThemePalette.fallback.green
    property color yellow: ThemePalette.fallback.yellow
    property color blue: ThemePalette.fallback.blue
    property color magenta: ThemePalette.fallback.magenta
    property color cyan: ThemePalette.fallback.cyan
    property color orange: ThemePalette.fallback.orange

    property color canvas: ThemePalette.fallback.canvas
    property color surface: ThemePalette.fallback.surface
    property color surfaceRaised: ThemePalette.fallback.surfaceRaised
    property color surfacePressed: ThemePalette.fallback.surfacePressed
    property color textPrimary: ThemePalette.fallback.textPrimary
    property color textSecondary: ThemePalette.fallback.textSecondary
    property color textMuted: ThemePalette.fallback.textMuted
    property color border: ThemePalette.fallback.border
    property color borderStrong: ThemePalette.fallback.borderStrong
    property color accentSecondary: ThemePalette.fallback.accentSecondary

    function applyPaletteText(text) {
        var palette = ThemePalette.parse(text)
        mode = palette.mode
        background = palette.background
        darkBackground = palette.darkBackground
        lighterBackground = palette.lighterBackground
        foreground = palette.foreground
        muted = palette.muted
        accent = palette.accent
        red = palette.red
        green = palette.green
        yellow = palette.yellow
        blue = palette.blue
        magenta = palette.magenta
        cyan = palette.cyan
        orange = palette.orange
        canvas = palette.canvas
        surface = palette.surface
        surfaceRaised = palette.surfaceRaised
        surfacePressed = palette.surfacePressed
        textPrimary = palette.textPrimary
        textSecondary = palette.textSecondary
        textMuted = palette.textMuted
        border = palette.border
        borderStrong = palette.borderStrong
        accentSecondary = palette.accentSecondary
        paletteLoaded = true
        paletteGeneration += 1
    }

    function resetPalette() {
        applyPaletteText("")
        paletteLoaded = false
    }

    function requestPaletteReload() {
        // A same-path reload is ignored while FileView has an async operation
        // in flight. Clearing the path cancels/disowns that read; restoring it
        // after the debounce always opens the post-swap file.
        colorsReadPath = ""
        paletteReloadDebounce.restart()
    }

    FileView {
        id: themeNameReader
        path: root.themeNamePath
        watchChanges: true
        printErrors: false

        onLoaded: {
            root.themeName = String(themeNameReader.text() || "").trim()
            root.requestPaletteReload()
        }
        onLoadFailed: {
            root.themeName = ""
            root.resetPalette()
        }
        onFileChanged: {
            root.requestPaletteReload()
            themeNameReader.reload()
        }
    }

    Timer {
        id: paletteReloadDebounce
        interval: 40
        repeat: false
        onTriggered: root.colorsReadPath = root.colorsPath
    }

    FileView {
        id: colorsReader
        path: root.colorsReadPath
        watchChanges: false
        printErrors: false

        onLoaded: root.applyPaletteText(colorsReader.text())
        onLoadFailed: root.resetPalette()
    }
}
