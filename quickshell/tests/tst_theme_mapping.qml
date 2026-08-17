import QtQuick
import QtTest
import "../state"
import "../state/ThemePalette.js" as ThemePalette

TestCase {
    id: testCase

    name: "ThemeMapping"
    property var liveSource: ThemePalette.fallback

    QtObject {
        id: mockPreferences

        property string readyColorRole: "muted"
        property string successColorRole: "green"
        property string workingColorRole: "blue"
        property string needsHelpColorRole: "yellow"
        property string reviewReadyColorRole: "green"
        property string errorColorRole: "red"
        property string unknownColorRole: "magenta"
        property string recordingColorRole: "green"
        property string processingColorRole: "cyan"
    }

    MappedTheme {
        id: mapped
        sourceTheme: testCase.liveSource
        preferences: mockPreferences
    }

    function init() {
        liveSource = ThemePalette.fallback
        mockPreferences.readyColorRole = "muted"
        mockPreferences.successColorRole = "green"
        mockPreferences.workingColorRole = "blue"
        mockPreferences.needsHelpColorRole = "yellow"
        mockPreferences.reviewReadyColorRole = "green"
        mockPreferences.errorColorRole = "red"
        mockPreferences.unknownColorRole = "magenta"
        mockPreferences.recordingColorRole = "green"
        mockPreferences.processingColorRole = "cyan"
    }

    function test_defaultsPreserveReviewedSemanticMeanings() {
        compare(String(mapped.ready), ThemePalette.fallback.muted)
        compare(String(mapped.success), ThemePalette.fallback.green)
        compare(String(mapped.working), ThemePalette.fallback.blue)
        compare(String(mapped.needsHelp), ThemePalette.fallback.yellow)
        compare(String(mapped.reviewReady), ThemePalette.fallback.green)
        compare(String(mapped.error), ThemePalette.fallback.red)
        compare(String(mapped.unknown), ThemePalette.fallback.magenta)
        compare(String(mapped.recording), ThemePalette.fallback.green)
        compare(String(mapped.processing), ThemePalette.fallback.cyan)
    }

    function test_eachMeaningCanSelectAThemePaletteRole() {
        mockPreferences.readyColorRole = "cyan"
        mockPreferences.successColorRole = "red"
        mockPreferences.workingColorRole = "orange"
        mockPreferences.needsHelpColorRole = "magenta"
        mockPreferences.reviewReadyColorRole = "accent"
        mockPreferences.errorColorRole = "yellow"
        mockPreferences.unknownColorRole = "red"
        mockPreferences.recordingColorRole = "blue"
        mockPreferences.processingColorRole = "green"

        compare(String(mapped.ready), ThemePalette.fallback.cyan)
        compare(String(mapped.success), ThemePalette.fallback.red)
        compare(String(mapped.working), ThemePalette.fallback.orange)
        compare(String(mapped.needsHelp), ThemePalette.fallback.magenta)
        compare(String(mapped.reviewReady), ThemePalette.fallback.accent)
        compare(String(mapped.error), ThemePalette.fallback.yellow)
        compare(String(mapped.unknown), ThemePalette.fallback.red)
        compare(String(mapped.recording), ThemePalette.fallback.blue)
        compare(String(mapped.processing), ThemePalette.fallback.green)
    }

    function test_invalidPersistedRolesFailClosedToDefaults() {
        mockPreferences.workingColorRole = "#ffffff"
        mockPreferences.errorColorRole = "background"
        compare(String(mapped.working), ThemePalette.fallback.blue)
        compare(String(mapped.error), ThemePalette.fallback.red)
    }

    function test_mappingFollowsAReplacedLiveThemePalette() {
        mockPreferences.workingColorRole = "red"
        liveSource = Object.assign({}, ThemePalette.fallback, {
            "red": "#010203"
        })
        compare(String(mapped.working), "#010203")
    }
}
