import QtQuick

Item {
    id: root

    required property var store
    required property var bridge
    required property var activity
    required property var preferences
    required property var theme
    property var sourceTheme: theme
    property bool reducedMotion: false
    property bool previewMode: false
    property bool restoreVoiceFocus: false
    property bool previewMicroOpen: false
    property string hostName: "LOCAL"

    readonly property real designWidth: 2560
    readonly property real designHeight: 720
    readonly property real viewportScale: Math.min(
        width / designWidth,
        height / designHeight
    )

    clip: true

    Rectangle {
        anchors.fill: parent
        color: root.theme.canvas
    }

    Item {
        id: designSurface

        width: root.designWidth
        height: root.designHeight
        x: (root.width - width * root.viewportScale) / 2
        y: (root.height - height * root.viewportScale) / 2
        scale: root.viewportScale
        transformOrigin: Item.TopLeft

        PortalView {
            anchors.fill: parent
            store: root.store
            bridge: root.bridge
            activity: root.activity
            preferences: root.preferences
            theme: root.theme
            sourceTheme: root.sourceTheme
            reducedMotion: root.reducedMotion
            previewMode: root.previewMode
            restoreVoiceFocus: root.restoreVoiceFocus
            previewMicroOpen: root.previewMicroOpen
            hostName: root.hostName
        }
    }
}
