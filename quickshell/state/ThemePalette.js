.pragma library

// Safe presentation defaults used when Omarchy is absent or publishes an
// incomplete palette. Agent state colors intentionally live elsewhere.
var rawFallback = {
    mode: "dark",
    background: "#02050b",
    darkBackground: "#05091a",
    lighterBackground: "#0b1523",
    foreground: "#ecfbff",
    muted: "#718ca6",
    accent: "#55e9ff",
    red: "#ff5d83",
    green: "#6cf7b0",
    yellow: "#ffc47c",
    blue: "#55e9ff",
    magenta: "#9a7cff",
    cyan: "#55e9ff",
    orange: "#e89562"
}

var selectableRoles = [
    "accent",
    "red",
    "orange",
    "yellow",
    "green",
    "cyan",
    "blue",
    "magenta",
    "muted"
]

function selectableRole(value, fallbackRole) {
    var requested = String(value || "").toLowerCase()
    if (selectableRoles.indexOf(requested) >= 0)
        return requested
    return selectableRoles.indexOf(fallbackRole) >= 0
        ? fallbackRole
        : "accent"
}

function roleColor(theme, role, fallbackRole) {
    var name = selectableRole(role, fallbackRole)
    var value = theme === null || theme === undefined
        ? undefined
        : theme[name]
    if (value !== undefined && value !== null && String(value) !== "")
        return value
    return rawFallback[selectableRole(fallbackRole, "accent")]
}

var linePattern = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"([^"]+)"/

function validColor(value) {
    return typeof value === "string"
        && /^#[0-9A-Fa-f]{6}$/.test(value)
}

function parseAll(text) {
    var values = {}
    var lines = String(text || "").split("\n")
    for (var index = 0; index < lines.length; index += 1) {
        var match = lines[index].match(linePattern)
        if (match !== null)
            values[match[1].toLowerCase()] = match[2]
    }
    return values
}

function firstColor(values, keys, fallbackValue) {
    for (var index = 0; index < keys.length; index += 1) {
        var value = values[keys[index]]
        if (validColor(value))
            return value
    }
    return fallbackValue
}

function colorChannels(value) {
    if (!validColor(value))
        return [0, 0, 0]
    return [
        parseInt(value.slice(1, 3), 16),
        parseInt(value.slice(3, 5), 16),
        parseInt(value.slice(5, 7), 16)
    ]
}

function colorString(channels) {
    var result = "#"
    for (var index = 0; index < 3; index += 1) {
        var channel = Math.max(0, Math.min(255, Math.round(channels[index])))
        result += channel.toString(16).padStart(2, "0")
    }
    return result
}

function mixColors(first, second, amount) {
    var left = colorChannels(first)
    var right = colorChannels(second)
    var weight = Math.max(0, Math.min(1, Number(amount)))
    return colorString([
        left[0] * (1 - weight) + right[0] * weight,
        left[1] * (1 - weight) + right[1] * weight,
        left[2] * (1 - weight) + right[2] * weight
    ])
}

function linearChannel(channel) {
    var value = channel / 255
    return value <= 0.04045
        ? value / 12.92
        : Math.pow((value + 0.055) / 1.055, 2.4)
}

function relativeLuminance(value) {
    var channels = colorChannels(value)
    return 0.2126 * linearChannel(channels[0])
        + 0.7152 * linearChannel(channels[1])
        + 0.0722 * linearChannel(channels[2])
}

function contrastRatio(first, second) {
    var left = relativeLuminance(first)
    var right = relativeLuminance(second)
    return (Math.max(left, right) + 0.05)
        / (Math.min(left, right) + 0.05)
}

function ensureContrast(candidate, background, minimum) {
    if (contrastRatio(candidate, background) >= minimum)
        return candidate

    var black = "#000000"
    var white = "#ffffff"
    var target = contrastRatio(black, background)
            >= contrastRatio(white, background)
        ? black
        : white
    var low = 0
    var high = 1
    for (var iteration = 0; iteration < 12; iteration += 1) {
        var middle = (low + high) / 2
        if (contrastRatio(
                mixColors(candidate, target, middle), background
            ) >= minimum)
            high = middle
        else
            low = middle
    }
    return mixColors(candidate, target, high)
}

function semantic(raw) {
    var light = raw.mode === "light"
    // The EDGE remains a dark command surface even for a light desktop theme.
    // Light palettes still supply every semantic hue and are inverted only
    // for chrome luminance roles.
    var canvas = light
        ? mixColors(raw.foreground, "#000000", 0.62)
        : raw.background
    var surface = light
        ? mixColors(canvas, raw.accent, 0.06)
        : mixColors(raw.background, raw.lighterBackground, 0.34)
    var surfaceRaised = light
        ? mixColors(canvas, raw.accent, 0.12)
        : mixColors(raw.background, raw.lighterBackground, 0.68)
    var primaryCandidate = light ? raw.background : raw.foreground
    var textPrimary = ensureContrast(primaryCandidate, surface, 7)
    var textMuted = ensureContrast(raw.muted, surface, 4.5)

    return Object.assign({}, raw, {
        canvas: canvas,
        surface: surface,
        surfaceRaised: surfaceRaised,
        surfacePressed: mixColors(surfaceRaised, raw.accent, 0.18),
        textPrimary: textPrimary,
        textSecondary: ensureContrast(
            mixColors(textPrimary, textMuted, 0.34), surface, 4.5
        ),
        textMuted: textMuted,
        border: mixColors(raw.muted, raw.accent, 0.32),
        borderStrong: mixColors(raw.muted, raw.accent, 0.68),
        accentSecondary: raw.cyan,
        // Defaults for the app-level semantic roles. MappedTheme.qml replaces
        // these aliases from persisted, allowlisted palette-role selections.
        ready: raw.muted,
        success: raw.green,
        working: raw.blue,
        needsHelp: raw.yellow,
        reviewReady: raw.green,
        error: raw.red,
        unknown: raw.magenta,
        recording: raw.green,
        processing: raw.cyan
    })
}

function parse(text) {
    var values = parseAll(text)
    var mode = String(values.mode || "").toLowerCase()
    if (mode !== "light" && mode !== "dark")
        mode = rawFallback.mode

    var background = firstColor(
        values, ["background", "bg"], rawFallback.background
    )
    var foreground = firstColor(
        values, ["foreground", "fg"], rawFallback.foreground
    )
    var raw = {
        mode: mode,
        background: background,
        darkBackground: firstColor(
            values,
            ["dark_background", "dark_bg", "darker_background", "darker_bg"],
            background
        ),
        lighterBackground: firstColor(
            values, ["lighter_background", "lighter_bg"], background
        ),
        foreground: foreground,
        muted: firstColor(
            values, ["muted", "dark_foreground", "dark_fg"], foreground
        ),
        accent: firstColor(
            values, ["accent", "blue"], rawFallback.accent
        ),
        red: firstColor(values, ["red"], rawFallback.red),
        green: firstColor(values, ["green"], rawFallback.green),
        yellow: firstColor(values, ["yellow"], rawFallback.yellow),
        blue: firstColor(values, ["blue"], rawFallback.blue),
        magenta: firstColor(values, ["magenta"], rawFallback.magenta),
        cyan: firstColor(values, ["cyan"], rawFallback.cyan),
        orange: firstColor(values, ["orange"], rawFallback.orange)
    }
    return semantic(raw)
}

var fallback = semantic(rawFallback)
