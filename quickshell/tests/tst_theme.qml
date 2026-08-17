import QtQuick
import QtTest
import "../state/ThemePalette.js" as ThemePalette

TestCase {
    name: "OmarchyThemePalette"

    function test_parserAllowlistAndAliases() {
        var parsed = ThemePalette.parse([
            'mode = "light"',
            'bg = "#123456"',
            'fg = "#abcdef"',
            'dark_fg = "#334455"',
            'accent = "not-a-color"',
            'blue = "#102030"',
            'unknown = "#ffffff"'
        ].join("\n"))

        compare(parsed.mode, "light")
        compare(parsed.background, "#123456")
        compare(parsed.foreground, "#abcdef")
        compare(parsed.muted, "#334455")
        compare(parsed.accent, "#102030")
        compare(parsed.unknown, parsed.magenta)
        verify(parsed.unknown !== "#ffffff")
    }

    function test_invalidOrPartialPaletteUsesSafeDefaults() {
        var parsed = ThemePalette.parse(
            'accent = "broken"\nbackground = "#222222"\n'
        )
        compare(parsed.background, "#222222")
        compare(parsed.accent, ThemePalette.fallback.accent)
        compare(parsed.foreground, ThemePalette.fallback.foreground)
        compare(parsed.mode, ThemePalette.fallback.mode)
    }

    function test_completePaletteMapsEveryChromeRole() {
        var parsed = ThemePalette.parse([
            'mode = "dark"',
            'accent = "#445566"',
            'background = "#101820"',
            'foreground = "#f4ead5"',
            'dark_bg = "#111111"',
            'lighter_bg = "#333333"',
            'muted = "#777777"',
            'red = "#aa0000"',
            'green = "#00aa00"',
            'yellow = "#aaaa00"',
            'blue = "#0000aa"',
            'magenta = "#aa00aa"',
            'cyan = "#00aaaa"',
            'orange = "#aa5500"'
        ].join("\n"))

        compare(parsed.accent, "#445566")
        compare(parsed.background, "#101820")
        compare(parsed.foreground, "#f4ead5")
        compare(parsed.darkBackground, "#111111")
        compare(parsed.lighterBackground, "#333333")
        compare(parsed.muted, "#777777")
        compare(parsed.red, "#aa0000")
        compare(parsed.green, "#00aa00")
        compare(parsed.yellow, "#aaaa00")
        compare(parsed.blue, "#0000aa")
        compare(parsed.magenta, "#aa00aa")
        compare(parsed.cyan, "#00aaaa")
        compare(parsed.orange, "#aa5500")
    }

    function test_officialLightPaletteAliasesStayDarkAdaptiveAndReadable() {
        var palettes = [
            [
                'mode = "light"',
                'background = "#eff1f5"',
                'dark_background = "#e3e4e8"',
                'lighter_background = "#dce0e8"',
                'foreground = "#4c4f69"',
                'muted = "#acb0be"',
                'accent = "#1e66f5"'
            ],
            [
                'mode = "light"',
                'background = "#fffcf0"',
                'dark_background = "#f2efe4"',
                'lighter_background = "#e6e4d9"',
                'foreground = "#100f0f"',
                'muted = "#b7b5ac"',
                'accent = "#205ea6"'
            ],
            [
                'mode = "light"',
                'background = "#faf4ed"',
                'dark_background = "#ede7e1"',
                'lighter_background = "#f2e9e1"',
                'foreground = "#575279"',
                'muted = "#cecacd"',
                'accent = "#56949f"'
            ]
        ]

        for (var index = 0; index < palettes.length; index += 1) {
            var parsed = ThemePalette.parse(palettes[index].join("\n"))
            compare(parsed.mode, "light")
            verify(parsed.canvas !== parsed.background)
            verify(parsed.surface !== ThemePalette.fallback.surface)
            verify(
                ThemePalette.contrastRatio(
                    parsed.textPrimary, parsed.surface
                ) >= 7
            )
            verify(
                ThemePalette.contrastRatio(
                    parsed.textPrimary, parsed.surfaceRaised
                ) >= 7
            )
            verify(
                ThemePalette.contrastRatio(
                    parsed.textSecondary, parsed.surface
                ) >= 4.5
            )
            verify(
                ThemePalette.contrastRatio(
                    parsed.textMuted, parsed.surface
                ) >= 4.5
            )
            verify(
                ThemePalette.contrastRatio(
                    parsed.textMuted, parsed.surfaceRaised
                ) >= 4.5
            )
        }

        var aliases = ThemePalette.parse(palettes[0].join("\n"))
        compare(aliases.darkBackground, "#e3e4e8")
        compare(aliases.lighterBackground, "#dce0e8")
    }

    function test_themeStatusHuesGetReadableTextVariantsOnDarkThemes() {
        var palettes = [
            [
                'mode = "dark"',
                'accent = "#81a1c1"',
                'muted = "#4c566a"',
                'background = "#2e3440"',
                'dark_background = "#222730"',
                'lighter_background = "#3b4252"',
                'foreground = "#d8dee9"',
                'red = "#bf616a"',
                'green = "#a3be8c"',
                'yellow = "#ebcb8b"',
                'blue = "#81a1c1"'
            ],
            [
                'mode = "dark"',
                'accent = "#7fbbb3"',
                'muted = "#475258"',
                'background = "#2d353b"',
                'dark_background = "#21272c"',
                'lighter_background = "#343f44"',
                'foreground = "#d3c6aa"',
                'red = "#e67e80"',
                'green = "#a7c080"',
                'yellow = "#dbbc7f"',
                'blue = "#7fbbb3"'
            ]
        ]
        for (var paletteIndex = 0;
                paletteIndex < palettes.length;
                paletteIndex += 1) {
            var parsed = ThemePalette.parse(
                palettes[paletteIndex].join("\n")
            )
            var stateColors = [
                parsed.blue,
                parsed.yellow,
                parsed.green,
                parsed.red
            ]
            for (var colorIndex = 0;
                    colorIndex < stateColors.length;
                    colorIndex += 1) {
                var stateColor = stateColors[colorIndex]
                var surfaceText = ThemePalette.ensureContrast(
                    stateColor, parsed.surface, 4.5
                )
                var raisedText = ThemePalette.ensureContrast(
                    stateColor, parsed.surfaceRaised, 4.5
                )
                verify(
                    ThemePalette.contrastRatio(
                        surfaceText, parsed.surface
                    ) >= 4.5
                )
                verify(
                    ThemePalette.contrastRatio(
                        raisedText, parsed.surfaceRaised
                    ) >= 4.5
                )
                verify(
                    ThemePalette.contrastRatio(
                        ThemePalette.ensureContrast(
                            stateColor, parsed.surfacePressed, 4.5
                        ),
                        parsed.surfacePressed
                    ) >= 4.5
                )
                var pillBackground = ThemePalette.mixColors(
                    parsed.surface, stateColor, 0.14
                )
                var pillText = ThemePalette.ensureContrast(
                    stateColor, pillBackground, 4.5
                )
                verify(
                    ThemePalette.contrastRatio(
                        pillText, pillBackground
                    ) >= 4.5
                )
            }

            var voiceBackground = ThemePalette.mixColors(
                parsed.surfaceRaised, parsed.green, 0.2
            )
            verify(
                ThemePalette.contrastRatio(
                    ThemePalette.ensureContrast(
                        parsed.green, voiceBackground, 4.5
                    ),
                    voiceBackground
                ) >= 4.5
            )
            verify(
                ThemePalette.contrastRatio(
                    ThemePalette.ensureContrast(
                        parsed.textMuted, voiceBackground, 4.5
                    ),
                    voiceBackground
                ) >= 4.5
            )
            verify(
                ThemePalette.contrastRatio(
                    ThemePalette.ensureContrast(
                        parsed.textPrimary, parsed.surfacePressed, 7
                    ),
                    parsed.surfacePressed
                ) >= 7
            )
            verify(
                ThemePalette.contrastRatio(
                    ThemePalette.ensureContrast(
                        parsed.textMuted, parsed.surfacePressed, 4.5
                    ),
                    parsed.surfacePressed
                ) >= 4.5
            )
        }
    }
}
