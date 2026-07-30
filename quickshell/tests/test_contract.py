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


if __name__ == "__main__":
    unittest.main()
