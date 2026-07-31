import QtQuick
import Quickshell
import "components"
import "state"

ShellRoot {
    id: root
    property bool fatalExitRequested: false
    property bool previewClosing: false

    readonly property bool previewMode:
        String(Quickshell.env("XENEON_EDGE_PREVIEW") || "") === "1"
    readonly property bool livePreviewMode:
        String(Quickshell.env("XENEON_EDGE_LIVE_PREVIEW") || "") === "1"
    readonly property bool previewMicroOpen:
        root.previewMode
        && String(Quickshell.env("XENEON_EDGE_PREVIEW_MICRO_OPEN") || "") === "1"
    readonly property bool previewWindowMode:
        previewMode || livePreviewMode
    readonly property bool reducedMotion:
        String(Quickshell.env("XENEON_EDGE_REDUCED_MOTION") || "") === "1"
    readonly property int previewAmbientTimeoutMs: {
        var requested = Number(
            Quickshell.env("XENEON_EDGE_AMBIENT_TIMEOUT_MS") || "60000"
        )
        if (!Number.isFinite(requested) || requested < 1000
                || requested > 300000)
            return 60000
        return Math.round(requested)
    }

    readonly property string targetSerial:
        String(Quickshell.env("XENEON_EDGE_SERIAL") || "")
    readonly property string targetModel:
        String(Quickshell.env("XENEON_EDGE_MODEL") || "")
    readonly property string targetOutput:
        String(Quickshell.env("XENEON_EDGE_OUTPUT") || "")
    readonly property string hostName:
        String(
            Quickshell.env("XENEON_EDGE_HOSTNAME")
                || Quickshell.env("HOSTNAME")
                || "LOCAL"
        )

    readonly property string fixtureName: {
        var requested = String(
            Quickshell.env("XENEON_EDGE_FIXTURE") || "snapshot.ndjson"
        )
        return /^[a-z0-9_-]+\.ndjson$/.test(requested)
            ? requested
            : "snapshot.ndjson"
    }

    readonly property var matchingScreens: {
        var matches = []
        var screens = Quickshell.screens
        for (var index = 0; index < screens.length; index += 1) {
            if (screenMatches(screens[index]))
                matches.push(screens[index])
        }
        return matches
    }

    // Production is intentionally fail-closed. Incomplete identity or zero or
    // multiple matches create no layer surface; explicit fixture/live preview
    // windows are the only primary-display code paths.
    readonly property var targetScreens:
        matchingScreens.length === 1 ? matchingScreens : []

    function identityConfigured() {
        return targetOutput !== ""
                && targetSerial !== ""
                && targetModel !== ""
    }

    function screenMatches(screen) {
        if (previewMode || !identityConfigured() || screen === null)
            return false

        if (String(screen.name || "") === ""
                || Number(screen.width) <= 0
                || Number(screen.height) <= 0)
            return false

        // Qt's Wayland QScreen backend does not expose EDID serials on every
        // compositor. The installer and check helper verify the configured
        // serial against Hyprland before this service is activated. When Qt
        // does expose a serial, retain the same exact-match gate here.
        var runtimeSerial = String(screen.serialNumber || "")
        if (runtimeSerial !== "" && runtimeSerial !== targetSerial)
            return false

        if (targetModel !== ""
                && String(screen.model || "") !== targetModel)
            return false

        if (targetOutput !== ""
                && String(screen.name || "") !== targetOutput)
            return false

        return true
    }

    Scope {
        id: runtime

        PortalStore {
            id: portalStore
        }

        ActivityController {
            id: activityController
            inactivityMs: root.previewWindowMode
                ? root.previewAmbientTimeoutMs
                : 60000
        }

        PortalBridge {
            id: portalBridge
            store: portalStore
            previewMode: root.previewMode
            fixturePath: Quickshell.shellPath(
                "fixtures/" + root.fixtureName
            )
        }

        Connections {
            target: portalStore

            function onSemanticActivityChanged(signature) {
                activityController.noteEvent()
            }

            function onActionResultReceived(result) {
                activityController.noteEvent()
            }

            function onNoticeReceived(notice) {
                activityController.noteEvent()
            }
        }
    }

    Variants {
        model: root.previewWindowMode ? [] : root.targetScreens

        Scope {
            id: screenVariant
            required property var modelData

            PortalPanel {
                modelData: screenVariant.modelData
                store: portalStore
                bridge: portalBridge
                activity: activityController
                reducedMotion: root.reducedMotion
                hostName: root.hostName
            }
        }
    }

    FloatingWindow {
        id: previewWindow

        visible: root.previewWindowMode
        title: "XENEON EDGE Agent Portal Preview"
        implicitWidth: 1280
        implicitHeight: 360
        minimumSize: Qt.size(960, 270)
        color: "#02050b"
        surfaceFormat.opaque: true

        onClosed: {
            root.previewClosing = true
            if (root.previewWindowMode && !root.fatalExitRequested)
                Qt.quit()
        }
        onResourcesLost: {
            if (root.previewWindowMode && !root.previewClosing) {
                root.fatalExitRequested = true
                Qt.exit(1)
            }
        }

        PortalViewport {
            anchors.fill: parent
            store: portalStore
            bridge: portalBridge
            activity: activityController
            reducedMotion: root.reducedMotion
            previewMode: root.previewMode
            restoreVoiceFocus: root.livePreviewMode
            previewMicroOpen: root.previewMicroOpen
            hostName: root.hostName
        }
    }
}
