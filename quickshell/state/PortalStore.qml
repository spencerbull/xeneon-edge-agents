import QtQml

QtObject {
    id: root

    property int schemaVersion: 1
    property double sequence: -1
    property string daemonEpoch: ""
    property double generatedAtMs: 0
    property bool hasSnapshot: false
    property bool freshSnapshotRequired: true

    property string transportState: "starting"
    property string transportDetail: ""
    property string protocolError: ""

    // The UI consumes a small view model instead of holding the wire envelope.
    // Only public protocol metadata is copied into it.
    property var connection: ({
        "state": "reconnecting",
        "detail": "Waiting for xeneon-agentd"
    })
    property var sessions: []
    property var agents: []
    property var agentOrder: ({
        "available": false,
        "mode": "grouped"
    })
    property var health: ({})
    property var voice: ({
        "available": false,
        "state": "unavailable",
        "owned": false
    })
    property var usage: ({
        "providers": []
    })
    property var micro: ({
        "connected": false,
        "firmware": "",
        "battery": -1,
        "charging": false,
        "layer": -1,
        "profile": -1,
        "last_updated_ms": 0
    })
    property var lastActionResult: null
    property var lastNotice: null
    property string activitySignature: ""
    property var pendingRequestActions: ({})
    property var pendingRequestOrder: []

    signal snapshotAccepted(var snapshot)
    signal semanticActivityChanged(string signature)
    signal actionResultReceived(var result)
    signal noticeReceived(var notice)
    signal protocolRejected(string reason)

    readonly property var allowedAgentStates: [
        "blocked",
        "done",
        "working",
        "idle",
        "unknown"
    ]

    readonly property var allowedConnectionStates: [
        "connected",
        "degraded",
        "reconnecting",
        "offline"
    ]

    readonly property var allowedSessionStates: [
        "connected",
        "stale",
        "incompatible",
        "offline"
    ]

    readonly property var allowedVoiceStates: [
        "unavailable",
        "idle",
        "recording",
        "processing",
        "error"
    ]

    function reset() {
        sequence = -1
        daemonEpoch = ""
        generatedAtMs = 0
        hasSnapshot = false
        freshSnapshotRequired = true
        transportState = "starting"
        transportDetail = ""
        protocolError = ""
        connection = {
            "state": "reconnecting",
            "detail": "Waiting for xeneon-agentd"
        }
        sessions = []
        agents = []
        agentOrder = {"available": false, "mode": "grouped"}
        health = {}
        voice = {
            "available": false,
            "state": "unavailable",
            "owned": false
        }
        usage = {"providers": []}
        micro = {
            "connected": false,
            "firmware": "",
            "battery": -1,
            "charging": false,
            "layer": -1,
            "profile": -1,
            "last_updated_ms": 0
        }
        lastActionResult = null
        lastNotice = null
        activitySignature = ""
        pendingRequestActions = {}
        pendingRequestOrder = []
    }

    function safeString(value, fallback, limit) {
        var normalized = value === null || value === undefined
                ? String(fallback || "")
                : String(value)
        if (limit !== undefined && normalized.length > limit)
            return normalized.slice(0, limit)
        return normalized
    }

    function finiteNumber(value, fallback) {
        var parsed = Number(value)
        return isFinite(parsed) ? parsed : fallback
    }

    function normalizeCapability(value, expectedKind) {
        if (value === null || value === undefined
                || typeof value !== "object")
            return null

        var capabilityId = safeString(value.capability_id, "", 128)
        var kind = safeString(value.kind, "", 24)
        var expiresAtMs = finiteNumber(value.expires_at_ms, -1)
        var expectedRevision = finiteNumber(value.expected_revision, -1)
        if (capabilityId === "" || kind !== expectedKind
                || expiresAtMs < 0 || expectedRevision < 0)
            return null

        return {
            "capability_id": capabilityId,
            "kind": kind,
            "expires_at_ms": expiresAtMs,
            "expected_revision": expectedRevision
        }
    }

    function statePriority(state, reviewReady) {
        switch (state) {
        case "blocked":
            return 0
        case "done":
            return reviewReady === true ? 1 : 3
        case "working":
            return 2
        case "idle":
            return reviewReady === true ? 1 : 3
        default:
            return 4
        }
    }

    function normalizeAgent(value) {
        if (value === null || value === undefined
                || typeof value !== "object")
            return null

        var id = safeString(value.id, "", 128)
        if (id === "")
            return null

        var status = safeString(value.status, "unknown", 24).toLowerCase()
        if (allowedAgentStates.indexOf(status) === -1)
            status = "unknown"

        var rawActions = value.actions !== null
                && value.actions !== undefined
                && typeof value.actions === "object"
                ? value.actions
                : {}

        return {
            "id": id,
            "display_name": safeString(
                value.display_name,
                "Unnamed agent",
                56
            ),
            "agent": safeString(value.agent, "agent", 48),
            "status": status,
            "workspace": safeString(value.workspace, "", 96),
            "repository": safeString(value.repository, "", 96),
            "worktree": safeString(value.worktree, "", 128),
            "session": safeString(value.session, "", 64),
            "focused": value.focused === true,
            "launch_pending": value.launch_pending === true,
            "review_ready": value.review_ready === true
                || (value.review_ready === undefined && status === "done"),
            "observed_for_seconds": Math.max(
                0,
                Math.floor(finiteNumber(value.observed_for_seconds, 0))
            ),
            "source_order": Math.max(
                0,
                Math.floor(finiteNumber(value.source_order, 0))
            ),
            "state_change_seq": Math.max(
                0,
                Math.floor(finiteNumber(value.state_change_seq, 0))
            ),
            "actions": {
                "open": rawActions.open === true,
                "zoom": rawActions.zoom === true,
                "approve": normalizeCapability(
                    rawActions.approve,
                    "approve"
                ),
                "interrupt": normalizeCapability(
                    rawActions.interrupt,
                    "interrupt"
                )
            }
        }
    }

    function normalizeAgents(values, orderMode) {
        var normalized = []
        for (var index = 0; index < values.length; index += 1) {
            var agent = normalizeAgent(values[index])
            if (agent !== null)
                normalized.push(agent)
        }

        normalized.sort(function(left, right) {
            if (orderMode === "grouped") {
                if (left.source_order !== right.source_order)
                    return left.source_order - right.source_order
                return left.id.localeCompare(right.id)
            }
            var priorityDifference = statePriority(
                left.status,
                left.review_ready
            ) - statePriority(right.status, right.review_ready)
            if (priorityDifference !== 0)
                return priorityDifference
            if (left.state_change_seq !== right.state_change_seq)
                return right.state_change_seq - left.state_change_seq
            if (left.source_order !== right.source_order)
                return left.source_order - right.source_order
            return left.id.localeCompare(right.id)
        })

        return normalized
    }

    function normalizeAgentOrder(value) {
        var source = value !== null
                && value !== undefined
                && typeof value === "object"
            ? value
            : {}
        var mode = safeString(source.mode, "grouped", 16).toLowerCase()
        if (mode !== "grouped" && mode !== "priority")
            mode = "grouped"
        return {
            "available": source.available === true,
            "mode": mode
        }
    }

    function normalizeSessions(values) {
        var normalized = []
        for (var index = 0; index < values.length; index += 1) {
            var session = values[index]
            if (session === null || session === undefined
                    || typeof session !== "object")
                continue

            var name = safeString(session.name, "", 64)
            var state = safeString(session.state, "offline", 24)
                    .toLowerCase()
            if (name === "")
                continue
            if (allowedSessionStates.indexOf(state) === -1)
                state = "offline"

            normalized.push({
                "name": name,
                "state": state,
                "version": safeString(session.version, "", 32),
                "protocol": Math.max(
                    0,
                    Math.floor(finiteNumber(session.protocol, 0))
                ),
                "last_sync_ms": Math.max(
                    0,
                    finiteNumber(session.last_sync_ms, 0)
                ),
                "message": safeString(session.message, "", 160)
            })
        }
        return normalized
    }

    function normalizeConnection(value, sessionViews) {
        var state = safeString(value, "degraded", 24).toLowerCase()
        if (allowedConnectionStates.indexOf(state) === -1)
            state = "degraded"

        var details = {
            "connected": "Herdr event stream synchronized",
            "degraded": "Herdr is reporting partial availability",
            "reconnecting": "Reconnecting to Herdr",
            "offline": "Herdr is offline"
        }
        var detail = details[state]
        if (state === "degraded" || state === "reconnecting") {
            for (var index = 0; index < sessionViews.length; index += 1) {
                if (sessionViews[index].state === "incompatible"
                        && sessionViews[index].message !== "") {
                    detail = sessionViews[index].message
                    break
                }
            }
        }
        return {
            "state": state,
            "detail": detail
        }
    }

    function normalizeMetric(value, fallbackUnit) {
        var source = value !== null
                && value !== undefined
                && typeof value === "object"
                ? value
                : {}
        var numericValue = source.value
        var available = source.available === true
                && typeof numericValue === "number"
                && isFinite(numericValue)
        return {
            "available": available,
            "value": available ? numericValue : null,
            "unit": safeString(source.unit, fallbackUnit, 16)
        }
    }

    function normalizeHealth(value) {
        var source = value !== null
                && value !== undefined
                && typeof value === "object"
                ? value
                : {}
        var normalized = {
            "cpu": normalizeMetric(source.cpu, "%"),
            "cpu_temperature": normalizeMetric(
                source.cpu_temperature,
                "°C"
            ),
            "gpu": normalizeMetric(source.gpu, "%"),
            "gpu_temperature": normalizeMetric(
                source.gpu_temperature,
                "°C"
            ),
            "memory": normalizeMetric(source.memory, "%"),
            "network_down": normalizeMetric(source.network_down, "B/s"),
            "network_up": normalizeMetric(source.network_up, "B/s"),
            "battery": normalizeMetric(source.battery, "%")
        }

        var required = [
            "cpu",
            "cpu_temperature",
            "gpu",
            "gpu_temperature",
            "memory",
            "network_down",
            "network_up",
            "battery"
        ]
        normalized.status = "healthy"
        for (var index = 0; index < required.length; index += 1) {
            if (!normalized[required[index]].available) {
                normalized.status = "partial"
                break
            }
        }
        return normalized
    }

    function normalizeVoice(value) {
        var source = value !== null
                && value !== undefined
                && typeof value === "object"
            ? value
            : {}
        var state = safeString(source.state, "unavailable", 24)
                .toLowerCase()
        if (allowedVoiceStates.indexOf(state) === -1)
            state = "error"
        var available = state !== "unavailable"
            && source.available !== false
        if (!available)
            state = "unavailable"
        return {
            "available": available,
            "state": state,
            "owned": available && source.owned === true
        }
    }

    function normalizeUsageWindow(value) {
        if (value === null || value === undefined
                || typeof value !== "object")
            return null
        var utilization = finiteNumber(value.utilization, -1)
        if (utilization < 0)
            return null
        return {
            "label": safeString(value.label, "Usage", 24),
            "utilization": Math.max(0, Math.min(1, utilization)),
            "reset_at_ms": Math.max(
                0,
                finiteNumber(value.reset_at_ms, 0)
            )
        }
    }

    function normalizeAggregateTokens(value) {
        if (typeof value !== "number" || !isFinite(value)
                || value < 0 || value > 1000000000000000)
            return null
        return Math.floor(value)
    }

    function normalizeUsage(value) {
        var source = value !== null
                && value !== undefined
                && typeof value === "object"
            ? value
            : {}
        var providers = Array.isArray(source.providers)
            ? source.providers
            : []
        var normalized = []
        var allowedIds = ["claude", "codex", "opencode"]
        for (var index = 0; index < providers.length; index += 1) {
            var provider = providers[index]
            if (provider === null || provider === undefined
                    || typeof provider !== "object")
                continue
            var id = safeString(provider.id, "", 24).toLowerCase()
            if (allowedIds.indexOf(id) === -1)
                continue
            normalized.push({
                "id": id,
                "label": safeString(provider.label, id, 24),
                "kind": provider.kind === "local_budget"
                    ? "local_budget"
                    : "quota",
                "available": provider.available === true,
                "stale": provider.stale === true,
                "source": safeString(provider.source, "unknown", 24),
                "status": safeString(provider.status, "unknown", 24),
                "plan": safeString(provider.plan, "", 32),
                "model": safeString(provider.model, "", 80),
                "primary": normalizeUsageWindow(provider.primary),
                "secondary": normalizeUsageWindow(provider.secondary),
                "today_tokens": normalizeAggregateTokens(
                    provider.today_tokens
                ),
                "tokens_per_hour": normalizeAggregateTokens(
                    provider.tokens_per_hour
                ),
                "last_updated_ms": Math.max(
                    0,
                    finiteNumber(provider.last_updated_ms, 0)
                )
            })
        }
        normalized.sort(function(left, right) {
            return allowedIds.indexOf(left.id) - allowedIds.indexOf(right.id)
        })
        return {"providers": normalized}
    }

    function normalizeMicro(value) {
        var source = value !== null
                && value !== undefined
                && typeof value === "object"
            ? value
            : {}
        var battery = Math.floor(finiteNumber(source.battery, -1))
        return {
            "connected": source.connected === true,
            "firmware": safeString(source.firmware, "", 32),
            "battery": battery >= 0 && battery <= 100 ? battery : -1,
            "charging": source.charging === true,
            "layer": Math.max(
                -1,
                Math.floor(finiteNumber(source.layer, -1))
            ),
            "profile": Math.max(
                -1,
                Math.floor(finiteNumber(source.profile, -1))
            ),
            "last_updated_ms": Math.max(
                0,
                finiteNumber(source.last_updated_ms, 0)
            )
        }
    }

    function semanticSignature(connectionView, agentViews, voiceView) {
        var fields = [
            connectionView.state,
            voiceView.state,
            voiceView.owned === true
        ]
        for (var index = 0; index < agentViews.length; index += 1) {
            fields.push(agentViews[index].id)
            fields.push(agentViews[index].status)
            fields.push(agentViews[index].review_ready === true)
        }
        return JSON.stringify(fields)
    }

    function reject(reason) {
        protocolError = reason
        protocolRejected(reason)
        return false
    }

    function awaitFreshSnapshot(state, detail) {
        transportState = safeString(state, "starting", 24)
        transportDetail = safeString(detail, "", 120)
        freshSnapshotRequired = true
        protocolError = ""
    }

    function trackCommand(command) {
        if (command === null || command === undefined
                || typeof command !== "object")
            return false

        var requestId = safeString(command.request_id, "", 128)
        var action = safeString(command.action, "", 32)
        if (requestId === "" || action === "")
            return false

        var actions = Object.assign({}, pendingRequestActions)
        var order = pendingRequestOrder.slice()
        if (actions[requestId] === undefined)
            order.push(requestId)
        actions[requestId] = action

        while (order.length > 128) {
            var expiredId = order.shift()
            delete actions[expiredId]
        }

        pendingRequestActions = actions
        pendingRequestOrder = order
        return true
    }

    function takeTrackedAction(requestId) {
        var normalizedId = safeString(requestId, "", 128)
        if (normalizedId === ""
                || pendingRequestActions[normalizedId] === undefined)
            return ""

        var actions = Object.assign({}, pendingRequestActions)
        var order = pendingRequestOrder.slice()
        var action = safeString(actions[normalizedId], "", 32)
        delete actions[normalizedId]

        var index = order.indexOf(normalizedId)
        if (index !== -1)
            order.splice(index, 1)
        pendingRequestActions = actions
        pendingRequestOrder = order
        return action
    }

    function ingestEnvelope(envelope) {
        if (envelope === null || envelope === undefined
                || typeof envelope !== "object")
            return reject("Envelope is not an object")

        if (Number(envelope.schema_version) !== schemaVersion)
            return reject("Unsupported schema version")

        if (envelope.type === "snapshot")
            return ingestSnapshot(envelope)
        if (envelope.type === "action_result")
            return ingestActionResult(envelope)
        if (envelope.type === "notice")
            return ingestNotice(envelope)

        return reject("Unsupported envelope type")
    }

    function ingestSnapshot(snapshot) {
        if (!Array.isArray(snapshot.agents)
                || !Array.isArray(snapshot.sessions))
            return reject("Snapshot is missing arrays")

        var nextEpoch = safeString(snapshot.daemon_epoch, "", 128)
        var nextSequence = finiteNumber(snapshot.sequence, -1)
        var nextGeneratedAtMs = finiteNumber(
            snapshot.generated_at_ms !== undefined
                ? snapshot.generated_at_ms
                : snapshot.captured_at_ms,
            0
        )
        if (nextEpoch === "" || nextSequence < 0)
            return reject("Snapshot is missing ordering metadata")

        if (hasSnapshot && nextEpoch === daemonEpoch) {
            if (nextSequence < sequence)
                return false
            if (nextSequence === sequence) {
                if (nextGeneratedAtMs < generatedAtMs)
                    return false
                if (nextGeneratedAtMs > generatedAtMs) {
                    var previousSignature = activitySignature
                    var nextVoice = normalizeVoice(snapshot.voice)
                    var nextUsage = normalizeUsage(snapshot.usage)
                    var nextMicro = normalizeMicro(snapshot.micro)
                    generatedAtMs = nextGeneratedAtMs
                    health = normalizeHealth(snapshot.health)
                    voice = nextVoice
                    usage = nextUsage
                    micro = nextMicro
                    activitySignature = semanticSignature(
                        connection,
                        agents,
                        nextVoice
                    )
                    if (activitySignature !== previousSignature)
                        semanticActivityChanged(activitySignature)
                } else if (!freshSnapshotRequired) {
                    return false
                }
                freshSnapshotRequired = false
                protocolError = ""
                snapshotAccepted(snapshot)
                return true
            }
        }

        var hadSnapshot = hasSnapshot
        var previousSignature = activitySignature
        var nextSessions = normalizeSessions(snapshot.sessions)
        var nextConnection = normalizeConnection(
            snapshot.connection,
            nextSessions
        )
        var nextAgentOrder = normalizeAgentOrder(snapshot.agent_order)
        var nextAgents = normalizeAgents(
            snapshot.agents,
            nextAgentOrder.available ? nextAgentOrder.mode : "priority"
        )
        var nextVoice = normalizeVoice(snapshot.voice)
        var nextUsage = normalizeUsage(snapshot.usage)
        var nextMicro = normalizeMicro(snapshot.micro)
        var nextSignature = semanticSignature(
            nextConnection,
            nextAgents,
            nextVoice
        )
        daemonEpoch = nextEpoch
        sequence = nextSequence
        generatedAtMs = nextGeneratedAtMs
        connection = nextConnection
        sessions = nextSessions
        agents = nextAgents
        agentOrder = nextAgentOrder
        health = normalizeHealth(snapshot.health)
        voice = nextVoice
        usage = nextUsage
        micro = nextMicro
        activitySignature = nextSignature
        hasSnapshot = true
        freshSnapshotRequired = false
        protocolError = ""

        snapshotAccepted(snapshot)
        if (hadSnapshot && nextSignature !== previousSignature)
            semanticActivityChanged(nextSignature)
        return true
    }

    function ingestActionResult(envelope) {
        var requestId = safeString(envelope.request_id, "", 128)
        var code = safeString(envelope.code, "", 64)
        if (requestId === "" || code === ""
                || typeof envelope.ok !== "boolean")
            return reject("Action result is incomplete")

        var result = {
            "request_id": requestId,
            "action": takeTrackedAction(requestId),
            "ok": envelope.ok,
            "code": code,
            "message": safeString(envelope.message, "", 120)
        }
        lastActionResult = result
        actionResultReceived(result)
        return true
    }

    function ingestNotice(envelope) {
        var code = safeString(envelope.code, "", 64)
        var level = safeString(envelope.level, "", 24)
        if (code === "" || level === "")
            return reject("Notice is incomplete")

        var notice = {
            "level": level,
            "code": code,
            "message": safeString(envelope.message, "", 120)
        }
        lastNotice = notice
        noticeReceived(notice)
        return true
    }

    function setTransportState(state, detail) {
        transportState = safeString(state, "disconnected", 24)
        transportDetail = safeString(detail, "", 120)
    }

    function surfaceState() {
        if (transportState === "disconnected")
            return "disconnected"
        if (freshSnapshotRequired || !hasSnapshot)
            return "loading"
        if (connection.state === "offline")
            return "disconnected"
        if (connection.state === "degraded"
                || connection.state === "reconnecting"
                || transportState === "degraded"
                || protocolError !== "")
            return "degraded"
        if (agents.length === 0)
            return "empty"
        return "ready"
    }
}
