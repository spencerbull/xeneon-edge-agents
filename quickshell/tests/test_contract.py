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
        self.assertIn("model: root.previewMode ? [] : root.targetScreens", shell)
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
        self.assertEqual(len(re.findall(r"\bScope\s*\{", shell)), 1)
        self.assertIn("FloatingWindow", shell)
        self.assertIn("XENEON_EDGE_PREVIEW", shell)

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
        ):
            self.assertIn(f'"{action}"', builder)
        self.assertIn('"type": "command"', builder)
        self.assertIn('JSON.stringify(command) + "\\n"', bridge)
        self.assertNotIn("pane.send_keys", qml)
        self.assertNotIn("send_keys", qml)
        self.assertNotIn('["bash", "-c"', qml)
        self.assertNotIn('["sh", "-c"', qml)

    def test_open_and_zoom_do_not_restore_focus(self):
        portal = source("components/PortalView.qml")
        open_handler = re.search(
            r"onOpenRequested: function.*?\n\s*\}",
            portal,
            re.DOTALL,
        )
        zoom_handler = re.search(
            r"onZoomRequested: function.*?\n\s*\}",
            portal,
            re.DOTALL,
        )
        self.assertIsNotNone(open_handler)
        self.assertIsNotNone(zoom_handler)
        self.assertNotIn("restoreFocus", open_handler.group(0))
        self.assertNotIn("restoreFocus", zoom_handler.group(0))
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

    def test_hold_controls_are_800ms_and_drag_cancellable(self):
        hold = source("components/HoldControl.qml")
        self.assertIn("longPressThreshold: 0.8", hold)
        self.assertIn("TapHandler.WithinBounds", hold)
        self.assertIn("onCanceled", hold)
        self.assertIn("timeHeld", hold)

    def test_paging_and_ambient_contracts_are_explicit(self):
        portal = source("components/PortalView.qml")
        activity = source("state/ActivityController.qml")
        self.assertIn("readonly property int pageSize: 6", portal)
        self.assertIn("ListView.Horizontal", portal)
        self.assertIn("ListView.SnapOneItem", portal)
        self.assertIn("property int inactivityMs: 60000", activity)
        self.assertIn("property int eventWakeMs: 15000", activity)
        shell = source("shell.qml")
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
        self.assertIn(
            "Accessible.onPressAction: root.selectPage(index)",
            portal,
        )
        guarded_action = re.search(
            r"Accessible\.onPressAction:\s*(?P<body>[^\n]+)",
            hold,
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
        self.assertIn("hyprctl eval", preview)
        self.assertIn("address:$address", preview)
        self.assertNotIn("hyprctl keyword", preview)
        self.assertNotIn(".config/hypr", preview)

    def test_ambient_overlay_shields_input_until_fade_finishes(self):
        ambient = source("components/AmbientView.qml")
        self.assertIn("visible: active || opacity > 0", ambient)
        self.assertIn("enabled: visible", ambient)
        self.assertIn("duration: root.reducedMotion ? 0 : 480", ambient)


if __name__ == "__main__":
    unittest.main()
