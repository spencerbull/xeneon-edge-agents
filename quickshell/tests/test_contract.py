import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


def source(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


class QmlSafetyContractTests(unittest.TestCase):
    def test_production_output_matching_is_fail_closed(self):
        shell = source("shell.qml")
        self.assertIn(
            "matchingScreens.length === 1 ? matchingScreens : []",
            shell,
        )
        self.assertIn(
            "model: root.previewWindowMode ? [] : root.targetScreens",
            shell,
        )
        self.assertNotRegex(shell, r"Quickshell\.screens\s*\[\s*0\s*\]")
        self.assertNotRegex(shell, r"primary(Screen|Output|Monitor)")
        self.assertIn("screenMatches", shell)
        self.assertIn("identityConfigured", shell)
        identity_gate = re.search(
            r"function identityConfigured\(\) \{(?P<body>.*?)\n\s*\}",
            shell,
            re.DOTALL,
        )
        self.assertIsNotNone(identity_gate)
        gate_body = identity_gate.group("body")
        self.assertIn('targetOutput !== ""', gate_body)
        self.assertIn('targetSerial !== ""', gate_body)
        self.assertIn('targetModel !== ""', gate_body)
        self.assertEqual(gate_body.count("&&"), 2)
        self.assertNotIn("||", gate_body)
        self.assertIn(
            'var runtimeSerial = String(screen.serialNumber || "")',
            shell,
        )
        self.assertIn(
            'if (runtimeSerial !== "" && runtimeSerial !== targetSerial)',
            shell,
        )

    def test_panel_has_exact_layer_surface_contract(self):
        panel = source("PortalPanel.qml")
        self.assertIn(
            'WlrLayershell.namespace: "xeneon-edge-agent-portal"',
            panel,
        )
        self.assertIn("WlrLayershell.layer: WlrLayer.Overlay", panel)
        self.assertIn("exclusionMode: ExclusionMode.Ignore", panel)
        self.assertIn(
            "WlrLayershell.keyboardFocus: WlrKeyboardFocus.None",
            panel,
        )
        self.assertIn("focusable: false", panel)
        self.assertNotIn("exclusiveZone", panel)

    def test_one_bridge_process_and_explicit_preview_window(self):
        qml = "\n".join(
            path.read_text(encoding="utf-8")
            for path in ROOT.rglob("*.qml")
            if "tests" not in path.parts
        )
        self.assertEqual(len(re.findall(r"\bProcess\s*\{", qml)), 1)
        shell = source("shell.qml")
        self.assertEqual(shell.count("id: runtime"), 1)
        self.assertEqual(shell.count("PortalBridge {"), 1)
        self.assertIn("FloatingWindow", shell)
        self.assertIn("XENEON_EDGE_PREVIEW", shell)
        self.assertIn("XENEON_EDGE_LIVE_PREVIEW", shell)

    def test_commands_are_allowlisted_ndjson_without_raw_input(self):
        builder = source("state/CommandBuilder.qml")
        bridge = source("state/PortalBridge.qml")
        qml = "\n".join(
            path.read_text(encoding="utf-8")
            for path in ROOT.rglob("*.qml")
            if "tests" not in path.parts
        )

        for action in (
            "open",
            "zoom",
            "approve",
            "interrupt",
            "restore_focus",
            "chatgpt_desktop",
            "claude_desktop",
            "voice_start",
            "voice_stop",
            "voice_cancel",
            "order_grouped",
            "order_priority",
        ):
            self.assertIn(f'"{action}"', builder)
        self.assertIn('"type": "command"', builder)
        self.assertIn('JSON.stringify(command) + "\\n"', bridge)
        self.assertNotIn("pane.send_keys", qml)
        self.assertNotIn("send_keys", qml)
        self.assertNotIn('["bash", "-c"', qml)
        self.assertNotIn('["sh", "-c"', qml)
        self.assertNotIn('["voxtype"', qml)

    def test_card_focus_is_single_action_and_does_not_restore_focus(self):
        portal = source("components/PortalView.qml")
        card = source("components/AgentCard.qml")
        focus_handler = re.search(
            r"onFocusRequested: function.*?\n\s*\}",
            portal,
            re.DOTALL,
        )
        self.assertIsNotNone(focus_handler)
        self.assertNotIn("restoreFocus", focus_handler.group(0))
        self.assertIn("function requestFocus()", card)
        self.assertNotIn("signal zoomRequested", card)
        self.assertNotIn('text: "OPEN"', card)
        self.assertNotIn('text: "ZOOM"', card)
        self.assertIsNotNone(
            re.search(
                r"onApproveRequested: function.*?restoreFocus",
                portal,
                re.DOTALL,
            )
        )
        self.assertIsNotNone(
            re.search(
                r"onInterruptRequested: function.*?restoreFocus",
                portal,
                re.DOTALL,
            )
        )

    def test_card_accents_use_bounded_blurred_blooms(self):
        card = source("components/AgentCard.qml")
        self.assertIn("import QtQuick.Effects", card)
        self.assertEqual(card.count("MultiEffect {"), 2)
        self.assertIn('objectName: "cardAccentBloom"', card)
        self.assertIn('objectName: "cardActivityBloom"', card)
        self.assertEqual(card.count("blurEnabled: true"), 2)
        self.assertIn("blurMax: 42", card)
        self.assertIn("blurMax: 36", card)
        self.assertEqual(card.count("visible: false"), 2)
        self.assertNotIn("Gradient", card)
        self.assertIn('root.agentState === "working"', card)
        self.assertNotIn("Canvas", card)

    def test_hold_controls_are_800ms_and_drag_cancellable(self):
        hold = source("components/HoldControl.qml")
        self.assertIn("longPressThreshold: 0.8", hold)
        self.assertIn("TapHandler.WithinBounds", hold)
        self.assertIn("onCanceled", hold)
        self.assertIn("timeHeld", hold)

    def test_paging_and_ambient_contracts_are_explicit(self):
        portal = source("components/PortalView.qml")
        activity = source("state/ActivityController.qml")
        shell = source("shell.qml")
        self.assertIn("readonly property int pageSize: 14", portal)
        self.assertIn("return Math.ceil(count / 2)", portal)
        ambient = source("components/AmbientView.qml")
        self.assertIn("readonly property int nodeLimit: 14", ambient)
        self.assertIn("readonly property bool denseConstellation", ambient)
        self.assertIn("ListView.Horizontal", portal)
        self.assertIn("ListView.SnapOneItem", portal)
        self.assertIn("property int inactivityMs: 60000", activity)
        self.assertIn("previewAmbientTimeoutMs", shell)
        self.assertIn("root.previewWindowMode", shell)
        self.assertIn("XENEON_EDGE_AMBIENT_TIMEOUT_MS", shell)
        self.assertIn("property int eventWakeMs: 15000", activity)
        self.assertIn("onSemanticActivityChanged", shell)
        self.assertNotIn("onSnapshotAccepted", shell)

    def test_all_portal_text_is_explicitly_plain(self):
        qml_sources = [
            path.read_text(encoding="utf-8")
            for path in ROOT.rglob("*.qml")
            if "tests" not in path.parts
        ]
        text_blocks = sum(
            len(re.findall(r"\bText\s*\{", contents))
            for contents in qml_sources
        )
        plain_text = sum(
            contents.count("textFormat: Text.PlainText")
            for contents in qml_sources
        )
        self.assertGreater(text_blocks, 0)
        self.assertEqual(text_blocks, plain_text)

        interaction_test = source("tests/tst_interaction.qml")
        self.assertIn("<img src=", interaction_test)
        self.assertIn(
            "compare(displayName.textFormat, Text.PlainText)",
            interaction_test,
        )

    def test_guarded_hold_pins_identity_capability_and_sequence(self):
        hold = source("components/HoldControl.qml")
        card = source("components/AgentCard.qml")
        portal = source("components/PortalView.qml")
        bridge = source("state/PortalBridge.qml")
        builder = source("state/CommandBuilder.qml")

        for pinned_field in (
            "heldAgentId",
            "heldCapabilityId",
            "heldSequence",
        ):
            self.assertIn(pinned_field, hold)
        self.assertIn("guardMatches()", hold)
        self.assertIn("onTargetAgentIdChanged", hold)
        self.assertIn("onTargetCapabilityIdChanged", hold)
        self.assertIn("onTargetSequenceChanged", hold)
        self.assertIn("targetSequence: root.snapshotSequence", card)
        self.assertIn("snapshotSequence: root.store.sequence", portal)
        self.assertIn("restoreFocus(sequence)", portal)
        self.assertIn(
            "function build(action, agentId, capabilityId, pinnedSequence)",
            builder,
        )
        self.assertNotIn("property double snapshotSequence", builder)
        self.assertIn("pinnedSequence", bridge)

    def test_accessible_controls_are_large_and_guarded_press_is_safe(self):
        portal = source("components/PortalView.qml")
        hold = source("components/HoldControl.qml")

        self.assertIn("width: 58", portal)
        self.assertIn("height: 48", portal)
        self.assertIn('Accessible.name: "Show agent page "', portal)
        self.assertIn("Accessible.ignored: !root.controlCenterInteractive", portal)
        self.assertIn("if (root.controlCenterInteractive)", portal)
        guarded_action = re.search(
            r"Accessible\.onPressAction:\s*\{(?P<body>.*?)\n\s*\}",
            hold,
            re.DOTALL,
        )
        self.assertIsNotNone(guarded_action)
        self.assertIn("accessibleHoldRequested", guarded_action.group("body"))
        self.assertNotIn("confirm", guarded_action.group("body").lower())

    def test_restore_focus_results_are_correlated_and_suppressed(self):
        store = source("state/PortalStore.qml")
        portal = source("components/PortalView.qml")
        bridge = source("state/PortalBridge.qml")

        self.assertIn("pendingRequestActions", store)
        self.assertIn('"action": takeTrackedAction(requestId)', store)
        self.assertIn('result.action === "restore_focus"', portal)
        self.assertIn("store.trackCommand(command)", bridge)
        self.assertIn("restoreFocus(pinnedSequence)", bridge)

    def test_bridge_restart_requires_fresh_snapshot_and_transport_copy_wins(self):
        store = source("state/PortalStore.qml")
        bridge = source("state/PortalBridge.qml")
        portal = source("components/PortalView.qml")

        self.assertIn("property bool freshSnapshotRequired: true", store)
        self.assertGreaterEqual(bridge.count("awaitFreshSnapshot("), 2)
        self.assertIn("if (store.freshSnapshotRequired)", bridge)
        self.assertIn(
            "actionsEnabled: !root.store.freshSnapshotRequired",
            portal,
        )
        disconnected = re.search(
            r'root\.surfaceState === "disconnected".*?'
            r"root\.store\.transportDetail.*?"
            r"root\.store\.connection\.detail",
            portal,
            re.DOTALL,
        )
        self.assertIsNotNone(disconnected)

    def test_resource_loss_exits_after_bounded_recovery_budget(self):
        panel = source("PortalPanel.qml")
        shell = source("shell.qml")

        self.assertIn("recoveryAttempts > 2", panel)
        self.assertIn("Qt.exit(1)", panel)
        self.assertIn("recoveryStabilityTimer", panel)
        self.assertIn("maximumRecoveryDelayMs", panel)
        self.assertIn("onResourcesLost", shell)
        self.assertIn("fatalExitRequested", shell)
        self.assertIn("Qt.exit(1)", shell)

    def test_preview_is_unique_closable_and_nonpersistent(self):
        shell = source("shell.qml")
        preview = (ROOT.parent / "scripts" / "preview").read_text(
            encoding="utf-8"
        )

        self.assertIn("onClosed", shell)
        self.assertIn("Qt.quit()", shell)
        self.assertIn("QS_APP_ID=$preview_app_id", preview)
        self.assertIn("$BASHPID", preview)
        self.assertIn("--live)", preview)
        self.assertIn("--ambient-after)", preview)
        self.assertIn("XENEON_EDGE_AMBIENT_TIMEOUT_MS", preview)
        self.assertIn("XENEON_AGENT_SOCKET=$preview_socket", preview)
        self.assertIn("hyprctl eval", preview)
        self.assertIn("address:$address", preview)
        self.assertIn('prop = \\"opacity_inactive_override\\"', preview)
        self.assertIn("preview_preferences=$(\n  mktemp", preview)
        self.assertEqual(
            preview.count(
                "XENEON_EDGE_SETTINGS_PATH=$preview_preferences"
            ),
            2,
        )
        self.assertIn('rm -f -- "$preview_preferences"', preview)
        self.assertNotIn("hyprctl keyword", preview)
        self.assertNotIn(".config/hypr", preview)

    def test_ambient_fadeout_shields_hidden_card_actions(self):
        ambient = source("components/AmbientView.qml")
        portal = source("components/PortalView.qml")
        self.assertIn("visible: active || revealProgress > 0 || exitShield", ambient)
        self.assertIn("enabled: active || exitShield", ambient)
        self.assertIn("enabled: root.enabled", ambient)
        self.assertIn("readonly property int exitDurationMs: 1000", ambient)
        self.assertIn("interval: root.exitDurationMs + 80", ambient)
        self.assertIn("Behavior on revealProgress", ambient)
        self.assertIn("duration: root.reducedMotion", ambient)
        self.assertIn("readonly property bool controlCenterInteractive", portal)
        self.assertIn("enabled: visible && root.controlCenterInteractive", portal)
        self.assertIn("enabled: root.controlCenterInteractive", portal)
        self.assertIn(
            "Accessible.ignored: !root.controlCenterInteractive",
            portal,
        )
        self.assertIn("if (root.controlCenterInteractive)", portal)

        for component in (
            "AgentCard.qml",
            "DesktopAppButton.qml",
            "HoldControl.qml",
            "MicroDrawer.qml",
            "VoiceControl.qml",
        ):
            self.assertIn(
                "Accessible.ignored:",
                source("components/" + component),
                component,
            )

        self.assertFalse((ROOT / "components/HealthStrip.qml").exists())

    def test_bridge_warnings_recover_and_passive_focus_is_quiet(self):
        bridge = source("state/PortalBridge.qml")
        portal = source("components/PortalView.qml")

        self.assertIn('"Bridge reported a warning"', bridge)
        self.assertIn('store.transportState === "degraded"', bridge)
        self.assertIn(
            'root.previewMode ? "fixture" : "streaming"',
            bridge,
        )
        passive = re.search(
            r"function notePassiveInteraction\(\) \{(?P<body>.*?)\n\s*\}",
            portal,
            re.DOTALL,
        )
        self.assertIsNotNone(passive)
        self.assertIn("if (bridge.ready)", passive.group("body"))
        reconnect = re.search(
            r"function onFreshSnapshotRequiredChanged\(\) \{(?P<body>.*?)\n\s*\}",
            portal,
            re.DOTALL,
        )
        self.assertIsNotNone(reconnect)
        self.assertIn("root.pendingVoiceFocus = {}", reconnect.group("body"))
        self.assertIn("root.pendingDesktopActions = {}", reconnect.group("body"))

    def test_home_telemetry_and_app_controls_remain_presentation_only(self):
        portal = source("components/PortalView.qml")
        store = source("state/PortalStore.qml")
        bridge = source("state/PortalBridge.qml")
        usage = source("components/AiUsageDock.qml")
        micro = source("components/MicroDrawer.qml")
        shell = source("shell.qml")
        panel = source("PortalPanel.qml")

        self.assertIn("normalizeUsage", store)
        self.assertIn("normalizeMicro", store)
        self.assertIn('sendBuilt("chatgpt_desktop"', bridge)
        self.assertIn('sendBuilt("claude_desktop"', bridge)
        self.assertIn("AiUsageDock", portal)
        self.assertIn("agents: root.store.agents", portal)
        self.assertIn("sessions: root.store.sessions", portal)
        self.assertIn("HERDR FLEET", usage)
        self.assertNotIn("AI CAPACITY", usage)
        self.assertNotIn("id: connectionLabel", portal)
        self.assertIn("XENEON_EDGE_HOSTNAME", shell)
        self.assertEqual(shell.count("hostName: root.hostName"), 2)
        self.assertIn("property string hostName:", panel)
        self.assertIn("hostName: root.hostName", panel)
        self.assertIn("MicroDrawer", portal)
        self.assertNotIn("Process {", usage)
        self.assertNotIn("Process {", micro)
        self.assertNotIn("terminal_text", portal)
        self.assertNotIn("prompt_text", portal)

    def test_voice_and_ring_stay_presentation_only_and_reduce_motion(self):
        voice = source("components/VoiceControl.qml")
        ring = source("components/AmbientRing.qml")
        bridge = source("state/PortalBridge.qml")
        portal = source("components/PortalView.qml")
        shell = source("shell.qml")

        self.assertIn("function beginPress()", voice)
        self.assertIn("function finishPress()", voice)
        self.assertIn("startRequested()", voice)
        self.assertIn("stopRequested()", voice)
        self.assertIn("cancelRequested()", voice)
        self.assertIn('sendBuilt("voice_start"', bridge)
        self.assertIn('sendBuilt("voice_stop"', bridge)
        self.assertIn('sendBuilt("voice_cancel"', bridge)
        self.assertEqual(portal.count("if (root.restoreVoiceFocus)"), 2)
        self.assertIn("pendingVoiceFocus", portal)
        self.assertIn("if (result.ok)", portal)
        self.assertIn("VOICE // FOCUS REQUIRED", portal)
        self.assertIn("restoreVoiceFocus: root.livePreviewMode", shell)
        self.assertIn("&& !reducedMotion", ring)
        self.assertIn("runnerCount: 2", ring)
        self.assertIn("runnerOffset: 0.5", ring)
        self.assertIn("import QtQuick.Effects", ring)
        self.assertIn("MultiEffect", ring)
        self.assertIn("blurEnabled: true", ring)
        self.assertIn("particleCountPerRunner: 6", ring)
        self.assertNotIn("Canvas", ring)
        self.assertIn("Palette.perimeterMode(agents)", ring)
        self.assertIn("dashOffset: root.phase", ring)
        self.assertNotIn("id: topBeam", ring)
        self.assertNotIn("Process {", voice)
        self.assertNotIn("Process {", ring)

    def test_display_settings_are_shared_persistent_and_presentation_only(self):
        shell = source("shell.qml")
        portal = source("components/PortalView.qml")
        controls = source("components/DisplaySettingsControls.qml")
        palette_pane = source("components/PaletteSettingsPane.qml")
        button = source("components/DisplaySettingButton.qml")
        ring = source("components/AmbientRing.qml")
        service = (ROOT.parent / "config/systemd/user/"
                   "xeneon-edge-portal.service.in").read_text(
                       encoding="utf-8"
                   )
        qml = "\n".join(
            path.read_text(encoding="utf-8")
            for path in ROOT.rglob("*.qml")
            if "tests" not in path.parts
        )

        self.assertEqual(shell.count("Settings {"), 1)
        self.assertIn("import QtCore", shell)
        self.assertIn("XENEON_EDGE_SETTINGS_PATH", shell)
        self.assertIn('category: "display"', shell)
        self.assertIn("property bool reduceMotion: false", shell)
        self.assertIn("property bool dimmed: false", shell)
        for setting in (
            'readyColorRole: "muted"',
            'successColorRole: "green"',
            'workingColorRole: "blue"',
            'needsHelpColorRole: "yellow"',
            'reviewReadyColorRole: "green"',
            'errorColorRole: "red"',
            'unknownColorRole: "magenta"',
            'recordingColorRole: "green"',
            'processingColorRole: "cyan"',
        ):
            self.assertIn(setting, shell)
        self.assertEqual(
            shell.count("preferences: portalPreferences"),
            3,
        )

        self.assertEqual(portal.count("DisplaySettingsControls {"), 1)
        self.assertIn('objectName: "globalDisplaySettings"', portal)
        self.assertIn("rightMargin: displaySettings.width + 16", portal)
        self.assertIn("readonly property bool effectiveReducedMotion", portal)
        self.assertIn(
            "suppressRunners: root.effectiveReducedMotion",
            portal,
        )
        self.assertIn('objectName: "displayDimmer"', portal)
        self.assertIn("opacity: root.displayDimmed ? 0.88 : 0", portal)
        self.assertIn("enabled: false", portal)
        self.assertIn("z: 70", portal)
        self.assertIn("z: 80", portal)

        self.assertIn('label: "MOTION"', controls)
        self.assertIn('label: "SCREEN"', controls)
        self.assertIn('label: "PALETTE"', controls)
        self.assertIn('stateLabel: root.dimmed ? "MINIMUM" : "NORMAL"', controls)
        self.assertIn("Accessible.role: Accessible.Button", button)
        self.assertIn("TapHandler.ReleaseWithinBounds", button)
        self.assertIn("property bool suppressRunners: false", ring)
        self.assertIn('mode !== "off" && !suppressRunners', ring)
        self.assertNotIn("Process {", controls)
        self.assertNotIn("Process {", palette_pane)
        self.assertNotIn("Process {", button)
        self.assertEqual(len(re.findall(r"\bProcess\s*\{", qml)), 1)

        self.assertIn(
            'Environment="XENEON_EDGE_SETTINGS_PATH=@STATE_HOME@/'
            'xeneon-edge-agents/portal/preferences.ini"',
            service,
        )
        self.assertIn("StateDirectory=xeneon-edge-agents/portal", service)
        self.assertIn("StateDirectoryMode=0700", service)
        self.assertIn("UMask=0077", service)

    def test_omarchy_theme_reload_is_runtime_owned_and_chrome_is_bound(self):
        shell = source("shell.qml")
        theme = source("state/OmarchyTheme.qml")
        palette = source("state/ThemePalette.js")
        mapped_theme = source("state/MappedTheme.qml")
        status_palette = source("components/PortalPalette.js")
        palette_pane = source("components/PaletteSettingsPane.qml")
        agent_card = source("components/AgentCard.qml")
        ai_usage = source("components/AiUsageDock.qml")
        ambient = source("components/AmbientView.qml")
        display_setting = source("components/DisplaySettingButton.qml")
        micro_drawer = source("components/MicroDrawer.qml")
        portal = source("components/PortalView.qml")
        voice = source("components/VoiceControl.qml")
        qml_sources = "\n".join(
            path.read_text(encoding="utf-8")
            for path in ROOT.rglob("*.qml")
            if "tests" not in path.parts
        )

        self.assertEqual(shell.count("OmarchyTheme {"), 1)
        self.assertEqual(shell.count("MappedTheme {"), 1)
        self.assertIn('Quickshell.env("XDG_STATE_HOME")', theme)
        self.assertIn('/omarchy/current"', theme)
        self.assertIn('readonly property string themeNamePath:', theme)
        self.assertIn('readonly property string colorsPath:', theme)
        self.assertIn("id: themeNameReader", theme)
        self.assertIn("watchChanges: true", theme)
        self.assertRegex(
            theme,
            r"onFileChanged:\s*\{\s*"
            r"root\.requestPaletteReload\(\)\s*"
            r"themeNameReader\.reload\(\)",
        )
        self.assertIn("root.requestPaletteReload()", theme)
        self.assertIn("id: paletteReloadDebounce", theme)
        self.assertIn('colorsReadPath = ""', theme)
        self.assertIn(
            "onTriggered: root.colorsReadPath = root.colorsPath",
            theme,
        )
        self.assertIn("id: colorsReader", theme)
        self.assertIn("path: root.colorsReadPath", theme)
        self.assertIn("watchChanges: false", theme)
        self.assertNotIn("Process {", theme)

        self.assertIn("function validColor(value)", palette)
        self.assertIn("function parse(text)", palette)
        self.assertIn("function selectableRole(value, fallbackRole)", palette)
        self.assertIn("function roleColor(theme, role, fallbackRole)", palette)
        for role in (
            "theme.working",
            "theme.needsHelp",
            "theme.reviewReady",
            "theme.error",
            "theme.ready",
            "theme.unknown",
            "theme.recording",
            "theme.processing",
        ):
            self.assertIn(role, status_palette)
        self.assertNotRegex(status_palette, r"#[0-9A-Fa-f]{6,8}")
        self.assertIn("String(theme.surface)", ambient)
        self.assertNotIn("String(theme.canvas),\n        4.5", ambient)

        # Omarchy owns the source hues. XENEON persists only allowlisted role
        # names and maps explicit app meanings while text remains normalized.
        self.assertIn('mappedColor("workingColorRole", "blue")', mapped_theme)
        self.assertIn('mappedColor("successColorRole", "green")', mapped_theme)
        self.assertIn('mappedColor("needsHelpColorRole", "yellow")', mapped_theme)
        self.assertIn('mappedColor("reviewReadyColorRole", "green")', mapped_theme)
        self.assertIn('mappedColor("errorColorRole", "red")', mapped_theme)
        self.assertIn("ThemePalette.selectableRoles.indexOf(role) < 0", palette_pane)
        self.assertNotIn("property color", palette_pane)
        self.assertIn("accent: root.theme.reviewReady", agent_card)
        self.assertIn("accent: root.theme.error", agent_card)
        self.assertIn("color: root.cardBackground", agent_card)
        self.assertIn("String(cardBackground)", agent_card)
        self.assertIn("color: root.readablePrimary", agent_card)
        self.assertIn("color: root.readableMuted", agent_card)
        self.assertIn("String(statePillBackground)", agent_card)
        self.assertIn("color: root.readablePillAccent", agent_card)
        self.assertIn("microStatusColor: store.micro.connected", portal)
        self.assertIn("? theme.success\n        : theme.error", portal)
        self.assertIn("degradedColor: theme.needsHelp", portal)
        self.assertIn("toastColor: toastSuccess", portal)
        self.assertIn("border.color: root.theme.error", voice)
        self.assertIn("String(controlBackground)", voice)
        self.assertIn("color: root.readableSecondary", voice)
        self.assertIn("root.readableColor(accent)", ai_usage)
        self.assertIn("root.readableColor(\n                            root.statusColor", ai_usage)
        self.assertIn("ThemePalette.ensureContrast(", display_setting)
        self.assertIn("color: root.readableConnectionColor", micro_drawer)
        self.assertIn("color: root.readableSurfaceMessageColor", portal)

        self.assertNotIn(
            "color: providerAvailable ? accent", ai_usage
        )
        self.assertNotIn(
            "color: root.checked ? root.accent : root.theme.textMuted\n"
            "                font {",
            display_setting,
        )
        self.assertNotIn("? root.theme.green", micro_drawer)
        self.assertNotIn("? root.theme.red", micro_drawer)
        self.assertIn("? theme.success\n        : theme.error", micro_drawer)
        self.assertIn("return root.theme.ready", micro_drawer)
        self.assertIn('? theme.ready\n        : Palette.ambientColor', ambient)

        # The only literal left in production QML is the intentional black
        # minimum-screen veil. Theme defaults live in the reviewed palette JS;
        # state color meaning maps onto those runtime theme roles.
        self.assertEqual(
            set(re.findall(r"#[0-9A-Fa-f]{6,8}", qml_sources)),
            {"#000000"},
        )


if __name__ == "__main__":
    unittest.main()
