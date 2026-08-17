import QtQuick
import QtTest
import "../components"

TestCase {
    id: testCase

    name: "DisplaySettings"
    width: 240
    height: 80

    DisplaySettingsControls {
        id: settings
    }

    SignalSpy {
        id: motionSpy
        target: settings
        signalName: "motionToggleRequested"
    }

    SignalSpy {
        id: dimSpy
        target: settings
        signalName: "dimToggleRequested"
    }

    SignalSpy {
        id: paletteSpy
        target: settings
        signalName: "paletteToggleRequested"
    }

    function init() {
        settings.motionReduced = false
        settings.motionForced = false
        settings.dimmed = false
        settings.paletteOpen = false
        settings.paletteCustom = false
        motionSpy.clear()
        dimSpy.clear()
        paletteSpy.clear()
    }

    function test_buttonsExposeCurrentGlobalState() {
        var motion = findChild(settings, "motionSettingButton")
        var dim = findChild(settings, "dimSettingButton")
        var palette = findChild(settings, "paletteSettingButton")

        verify(motion !== null)
        verify(dim !== null)
        verify(palette !== null)
        compare(motion.checked, false)
        compare(motion.stateLabel, "FULL")
        compare(dim.checked, false)
        compare(dim.stateLabel, "NORMAL")
        compare(palette.checked, false)
        compare(palette.stateLabel, "THEME")

        settings.motionReduced = true
        settings.dimmed = true
        compare(motion.checked, true)
        compare(motion.stateLabel, "REDUCED")
        compare(dim.checked, true)
        compare(dim.stateLabel, "MINIMUM")
        settings.paletteCustom = true
        compare(palette.checked, true)
        compare(palette.stateLabel, "CUSTOM")
        settings.paletteOpen = true
        compare(palette.stateLabel, "OPEN")
    }

    function test_activationRequestsExactlyOneToggle() {
        var motion = findChild(settings, "motionSettingButton")
        var dim = findChild(settings, "dimSettingButton")
        var palette = findChild(settings, "paletteSettingButton")

        compare(motion.activate(), true)
        compare(motionSpy.count, 1)
        compare(dimSpy.count, 0)

        compare(dim.activate(), true)
        compare(motionSpy.count, 1)
        compare(dimSpy.count, 1)

        compare(palette.activate(), true)
        compare(paletteSpy.count, 1)
    }

    function test_systemReducedMotionCannotBeReenabled() {
        var motion = findChild(settings, "motionSettingButton")

        settings.motionReduced = true
        settings.motionForced = true
        compare(motion.stateLabel, "SYSTEM")
        compare(motion.enabled, false)
        compare(motion.activate(), false)
        compare(motionSpy.count, 0)
    }
}
