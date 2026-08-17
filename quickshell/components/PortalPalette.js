.pragma library

// Maps authoritative state meaning onto the active Omarchy palette. QML owns
// only presentation; daemon and Herdr state remain authoritative.

function effectiveAgentState(agent) {
    if (agent === null || agent === undefined)
        return "unknown"

    var state = String(agent.status || "unknown").toLowerCase()
    if (state === "blocked" || state === "working")
        return state
    if (agent.review_ready === true)
        return "review"
    if (state === "idle" || state === "done")
        return "idle"
    return "unknown"
}

function agentColor(agent, theme) {
    switch (effectiveAgentState(agent)) {
    case "working":
        return theme.working
    case "blocked":
        return theme.needsHelp
    case "review":
        return theme.reviewReady
    case "idle":
        return theme.ready
    default:
        return theme.unknown
    }
}

function ambientMode(agents, voice, connectionState) {
    var voiceState = voice === null || voice === undefined
        ? "unavailable"
        : String(voice.state || "unavailable").toLowerCase()
    if (voiceState === "recording")
        return "voice-recording"
    if (voiceState === "processing")
        return "voice-processing"
    if (voiceState === "error")
        return "voice-error"

    if (connectionState === "offline")
        return "error"

    var hasReview = false
    var hasWorking = false
    for (var index = 0; index < agents.length; index += 1) {
        var state = effectiveAgentState(agents[index])
        if (state === "blocked")
            return "blocked"
        if (state === "review")
            hasReview = true
        else if (state === "working")
            hasWorking = true
    }
    if (hasReview)
        return "review"
    if (hasWorking)
        return "working"
    return "off"
}

function perimeterMode(agents) {
    var hasWorking = false
    for (var index = 0; index < agents.length; index += 1) {
        var state = String(agents[index].status || "unknown").toLowerCase()
        if (state === "blocked")
            return "blocked"
        if (state === "working")
            hasWorking = true
    }
    return hasWorking ? "working" : "off"
}

function ambientColor(mode, theme) {
    switch (mode) {
    case "voice-recording":
        return theme.recording
    case "voice-processing":
        return theme.processing
    case "voice-error":
    case "error":
        return theme.error
    case "blocked":
        return theme.needsHelp
    case "review":
        return theme.reviewReady
    case "working":
        return theme.working
    default:
        return theme.ready
    }
}

function ambientLabel(mode) {
    switch (mode) {
    case "voice-recording":
        return "VOICE // RECORDING"
    case "voice-processing":
        return "VOICE // PROCESSING"
    case "voice-error":
        return "VOICE // ERROR"
    case "error":
        return "SYSTEM // ATTENTION"
    case "blocked":
        return "AGENT // BLOCKED"
    case "review":
        return "AGENT // REVIEW READY"
    case "working":
        return "AGENTS // ACTIVE"
    default:
        return "AMBIENT // IDLE"
    }
}

function snakeDuration(mode) {
    switch (mode) {
    case "voice-error":
    case "error":
        return 2200
    case "blocked":
        return 2700
    case "voice-recording":
    case "voice-processing":
    case "working":
        return 3200
    default:
        return 0
    }
}

function haloDuration(mode) {
    switch (mode) {
    case "blocked":
        return 6200
    case "working":
        return 7600
    default:
        return 0
    }
}
