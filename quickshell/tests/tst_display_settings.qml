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

    function init() {
        settings.motionReduced = false
        settings.motionForced = false
        settings.dimmed = false
        motionSpy.clear()
        dimSpy.clear()
    }

    function test_buttonsExposeCurrentGlobalState() {
        var motion = findChild(settings, "motionSettingButton")
        var dim = findChild(settings, "dimSettingButton")

        verify(motion !== null)
        verify(dim !== null)
        compare(motion.checked, false)
        compare(motion.stateLabel, "FULL")
        compare(dim.checked, false)
        compare(dim.stateLabel, "NORMAL")

        settings.motionReduced = true
        settings.dimmed = true
        compare(motion.checked, true)
        compare(motion.stateLabel, "REDUCED")
        compare(dim.checked, true)
        compare(dim.stateLabel, "MINIMUM")
    }

    function test_activationRequestsExactlyOneToggle() {
        var motion = findChild(settings, "motionSettingButton")
        var dim = findChild(settings, "dimSettingButton")

        compare(motion.activate(), true)
        compare(motionSpy.count, 1)
        compare(dimSpy.count, 0)

        compare(dim.activate(), true)
        compare(motionSpy.count, 1)
        compare(dimSpy.count, 1)
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
