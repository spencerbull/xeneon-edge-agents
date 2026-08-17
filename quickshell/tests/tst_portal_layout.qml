import QtQuick
import QtTest
import "../components"
import "../state/ThemePalette.js" as ThemePalette

TestCase {
    id: testCase

    name: "PortalLayout"
    width: 2560
    height: 720

    QtObject {
        id: mockStore

        signal actionResultReceived(var result)
        signal noticeReceived(var notice)

        property var agents: []
        property var agentOrder: ({"available": true, "mode": "grouped"})
        property var sessions: []
        property var usage: ({"providers": []})
        property var micro: ({"connected": false, "charging": false})
        property var voice: ({"available": false, "state": "unavailable"})
        property var health: ({})
        property var connection: ({"state": "connected", "detail": ""})
        property string transportDetail: ""
        property string protocolError: ""
        property bool freshSnapshotRequired: false
        property double sequence: 1
        property string testSurfaceState: ""

        function surfaceState() {
            return testSurfaceState || (agents.length > 0 ? "ready" : "empty")
        }
    }

    QtObject {
        id: mockBridge

        signal commandRejected(string reason)
        signal commandEmitted(var command)

        property bool ready: true
        property int orderRequests: 0
        property string lastOrder: ""

        function restoreFocus() { return "restore" }
        function openAgent(agentId) { return agentId }
        function approveAgent() { return "approve" }
        function interruptAgent() { return "interrupt" }
        function openChatGptDesktop() { return "chatgpt" }
        function openClaudeDesktop() { return "claude" }
        function startVoice() { return "voice-start" }
        function stopVoice() { return "voice-stop" }
        function cancelVoice() { return "voice-cancel" }
        function setAgentOrder(mode) {
            orderRequests += 1
            lastOrder = mode
            return "order-" + orderRequests
        }
    }

    QtObject {
        id: mockActivity

        property bool ambientMode: false
        property int noteCount: 0
        function noteUserActivity() {
            noteCount += 1
            ambientMode = false
        }
    }

    QtObject {
        id: mockPreferences

        property bool reduceMotion: false
        property bool dimmed: false
        property string readyColorRole: "muted"
        property string successColorRole: "green"
        property string workingColorRole: "blue"
        property string needsHelpColorRole: "yellow"
        property string reviewReadyColorRole: "green"
        property string errorColorRole: "red"
        property string unknownColorRole: "magenta"
        property string recordingColorRole: "green"
        property string processingColorRole: "cyan"
        property int syncCount: 0
        function sync() { syncCount += 1 }
    }

    PortalView {
        id: portal

        width: testCase.width
        height: testCase.height
        store: mockStore
        bridge: mockBridge
        activity: mockActivity
        preferences: mockPreferences
        theme: ThemePalette.fallback
        reducedMotion: true
    }

    function agent(index) {
        return {
            "id": "layout-agent-" + index,
            "display_name": "Layout Agent " + index,
            "agent": "fixture",
            "status": index % 3 === 0 ? "working" : "idle",
            "review_ready": false,
            "focused": index === 0,
            "observed_for_seconds": index,
            "workspace": "layout-test",
            "repository": "xeneon-edge-agents",
            "worktree": "",
            "actions": {
                "open": true,
                "zoom": true,
                "approve": null,
                "interrupt": null
            }
        }
    }

    function agents(count) {
        var result = []
        for (var index = 0; index < count; index += 1)
            result.push(agent(index))
        return result
    }

    function init() {
        mockStore.agents = agents(20)
        mockStore.agentOrder = {"available": true, "mode": "grouped"}
        mockStore.connection = {"state": "connected", "detail": ""}
        mockStore.testSurfaceState = ""
        mockBridge.orderRequests = 0
        mockBridge.lastOrder = ""
        portal.pendingAgentOrderRequest = ""
        portal.paletteSettingsOpen = false
        mockPreferences.readyColorRole = "muted"
        mockPreferences.successColorRole = "green"
        mockPreferences.workingColorRole = "blue"
        mockPreferences.needsHelpColorRole = "yellow"
        mockPreferences.reviewReadyColorRole = "green"
        mockPreferences.errorColorRole = "red"
        mockPreferences.unknownColorRole = "magenta"
        mockPreferences.recordingColorRole = "green"
        mockPreferences.processingColorRole = "cyan"
        mockPreferences.syncCount = 0
        mockActivity.ambientMode = false
        mockActivity.noteCount = 0
        portal.currentPage = 0
        wait(0)
    }

    function cleanup() {
        mockStore.agents = []
        portal.currentPage = 0
        portal.paletteSettingsOpen = false
        wait(0)
    }

    function test_twentyAgentsUseFourteenPlusSixPages() {
        compare(portal.pageSize, 14)
        compare(portal.pageCount, 2)
        compare(portal.pageAgentCount(0), 14)
        compare(portal.pageColumns(0), 7)
        compare(portal.pageRows(0), 2)
        compare(portal.pageAgentCount(1), 6)
        compare(portal.pageColumns(1), 3)
        compare(portal.pageRows(1), 2)
        compare(portal.agentAt(0, 13).id, "layout-agent-13")
        compare(portal.agentAt(1, 0).id, "layout-agent-14")
        compare(portal.agentAt(1, 5).id, "layout-agent-19")
        compare(portal.agentAt(1, 6), null)

        var firstGrid = findChild(portal, "agentGrid_0")
        var firstLastCard = findChild(portal, "agentCard_0_13")
        var firstSpaceName = findChild(firstLastCard, "agentSpaceName")
        verify(firstGrid !== null)
        verify(firstLastCard !== null)
        verify(firstSpaceName !== null)
        compare(firstGrid.columns, 7)
        compare(firstSpaceName.text, "SPACE // LAYOUT-TEST")
        verify(!firstSpaceName.truncated)
        verify(firstLastCard.width > 330)
        verify(firstLastCard.height > 220)
        verify(firstLastCard.x + firstLastCard.width <= firstGrid.width + 0.5)
        verify(firstLastCard.y + firstLastCard.height <= firstGrid.height + 0.5)

        portal.selectPage(1)
        tryCompare(portal, "currentPage", 1)
        var pages = findChild(portal, "agentPages")
        tryCompare(pages, "currentIndex", 1)
        var secondGrid = findChild(portal, "agentGrid_1")
        var secondLastCard = findChild(portal, "agentCard_1_5")
        verify(secondGrid !== null)
        verify(secondLastCard !== null)
        compare(secondGrid.columns, 3)
        verify(secondLastCard.x + secondLastCard.width <= secondGrid.width + 0.5)
        verify(secondLastCard.y + secondLastCard.height <= secondGrid.height + 0.5)
    }

    function test_agentOrderToggleUsesAuthoritativeHerdrModeOnce() {
        var toggle = findChild(portal, "agentOrderToggle")
        var label = findChild(portal, "agentOrderLabel")
        verify(toggle !== null)
        verify(label !== null)
        verify(toggle.enabled)
        compare(label.text, "ORDER // GROUPED")

        verify(toggle.activate())
        compare(mockBridge.orderRequests, 1)
        compare(mockBridge.lastOrder, "priority")
        verify(!toggle.enabled)
        compare(label.text, "ORDER // SYNCING")
        compare(toggle.Accessible.name, "Agent ordering syncing")
        compare(
            toggle.Accessible.description,
            "Synchronizing agent ordering with Herdr"
        )

        mockStore.actionResultReceived({
            "request_id": "order-1",
            "action": "order_priority",
            "ok": true,
            "code": "agent_order_updated",
            "message": "agent_order_updated"
        })
        compare(portal.pendingAgentOrderRequest, "")
        mockStore.agentOrder = {"available": true, "mode": "priority"}
        compare(label.text, "ORDER // PRIORITY")
        verify(toggle.activate())
        compare(mockBridge.orderRequests, 2)
        compare(mockBridge.lastOrder, "grouped")
    }

    function test_lowerCountsAndShrinkClampSafely() {
        mockStore.agents = agents(4)
        wait(0)
        compare(portal.pageCount, 1)
        compare(portal.pageColumns(0), 2)
        compare(portal.pageRows(0), 2)

        mockStore.agents = agents(20)
        wait(0)
        portal.selectPage(1)
        tryCompare(portal, "currentPage", 1)
        mockStore.agents = agents(6)
        tryCompare(portal, "pageCount", 1)
        tryCompare(portal, "currentPage", 0)
        compare(portal.pageColumns(0), 3)
        compare(portal.pageRows(0), 2)
    }

    function test_degradedBannerRendersBoundedProtocolReasonAsPlainText() {
        var prefix = "Herdr protocol 19 is incompatible <img src='file:///private'> "
        var reason = prefix + "X".repeat(160 - prefix.length)
        compare(reason.length, 160)
        mockStore.connection = {"state": "degraded", "detail": reason}
        mockStore.testSurfaceState = "degraded"
        tryCompare(portal, "surfaceState", "degraded")

        var banner = findChild(portal, "degradedBanner")
        var label = findChild(portal, "degradedBannerText")
        verify(banner !== null)
        verify(label !== null)
        tryCompare(banner, "height", 28)
        compare(label.text, "DEGRADED // " + reason.toUpperCase())
        compare(label.textFormat, Text.PlainText)
        verify(label.truncated)
    }

    function test_palettePaneMapsAllowlistedThemeRolesAndResets() {
        var controls = findChild(portal, "globalDisplaySettings")
        var toggle = findChild(controls, "paletteSettingButton")
        var pane = findChild(portal, "paletteSettingsPane")
        var scrim = findChild(portal, "paletteModalScrim")
        var dimmer = findChild(portal, "displayDimmer")
        verify(controls !== null)
        verify(toggle !== null)
        verify(pane !== null)
        verify(scrim !== null)
        verify(dimmer !== null)
        compare(toggle.stateLabel, "THEME")
        verify(toggle.activate())
        compare(portal.paletteSettingsOpen, true)
        compare(pane.open, true)
        compare(toggle.stateLabel, "OPEN")
        compare(mockActivity.noteCount, 1)
        verify(pane.x >= 0)
        verify(pane.y >= 0)
        verify(pane.x + pane.width <= portal.width)
        verify(pane.y + pane.height <= portal.height)
        verify(scrim.z < pane.z)
        verify(pane.z < dimmer.z)

        var lastChoice = findChild(
            pane, "paletteRole_processing_magenta"
        )
        verify(lastChoice !== null)
        verify(lastChoice.x + lastChoice.width <= pane.width)
        verify(lastChoice.y + lastChoice.height <= pane.height)

        var redWorking = findChild(pane, "paletteRole_working_red")
        verify(redWorking !== null)
        verify(redWorking.activate())
        compare(mockPreferences.workingColorRole, "red")
        compare(mockPreferences.syncCount, 1)
        compare(mockActivity.noteCount, 2)
        compare(pane.customized, true)

        var close = findChild(pane, "paletteCloseButton")
        verify(close.activate())
        compare(portal.paletteSettingsOpen, false)
        compare(toggle.stateLabel, "CUSTOM")

        portal.paletteSettingsOpen = true
        var reset = findChild(pane, "paletteResetButton")
        verify(reset.enabled)
        verify(reset.activate())
        compare(mockPreferences.workingColorRole, "blue")
        compare(mockPreferences.syncCount, 2)
        compare(pane.customized, false)
        compare(pane.setMapping("working", "not-a-theme-role"), false)
        compare(mockPreferences.workingColorRole, "blue")

        mockPreferences.workingColorRole = "not-a-theme-role"
        compare(pane.customized, true)
        compare(pane.selectionFor("working", "blue"), "blue")
        verify(reset.activate())
        compare(mockPreferences.workingColorRole, "blue")
    }

    function test_palettePaneWakesAmbientAndClosesBeforeReentry() {
        mockActivity.ambientMode = true
        wait(0)
        verify(portal.togglePaletteSettings())
        compare(portal.paletteSettingsOpen, true)
        compare(mockActivity.ambientMode, false)
        compare(mockActivity.noteCount, 1)

        mockActivity.ambientMode = true
        tryCompare(portal, "paletteSettingsOpen", false)
    }
}
