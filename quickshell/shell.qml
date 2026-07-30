import QtQuick
import Quickshell
import "components"
import "state"

ShellRoot {
    id: root

    readonly property bool previewMode:
        String(Quickshell.env("XENEON_EDGE_PREVIEW") || "") === "1"
    readonly property bool reducedMotion:
        String(Quickshell.env("XENEON_EDGE_REDUCED_MOTION") || "") === "1"

    readonly property string targetSerial:
        String(Quickshell.env("XENEON_EDGE_SERIAL") || "")
    readonly property string targetModel:
        String(Quickshell.env("XENEON_EDGE_MODEL") || "")
    readonly property string targetOutput:
        String(Quickshell.env("XENEON_EDGE_OUTPUT") || "")

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
    // multiple matches create no layer surface; preview is the only primary
    // display code path.
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

        if (targetSerial !== ""
                && String(screen.serialNumber || "") !== targetSerial)
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
        model: root.previewMode ? [] : root.targetScreens

        PortalPanel {
            required property var modelData
            store: portalStore
            bridge: portalBridge
            activity: activityController
            reducedMotion: root.reducedMotion
        }
    }

    FloatingWindow {
        id: previewWindow

        visible: root.previewMode
        title: "XENEON EDGE Agent Portal Preview"
        implicitWidth: 1280
        implicitHeight: 360
        minimumSize: Qt.size(960, 270)
        color: "#02050b"
        surfaceFormat.opaque: true

        PortalViewport {
            anchors.fill: parent
            store: portalStore
            bridge: portalBridge
            activity: activityController
            reducedMotion: root.reducedMotion
            previewMode: true
        }
    }
}
