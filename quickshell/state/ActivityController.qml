import QtQml

QtObject {
    id: root

    property bool automatic: true
    property int inactivityMs: 60000
    property int eventWakeMs: 15000
    property double lastUserActivityMs: Date.now()
    property double eventWakeUntilMs: 0
    property bool ambientMode: false

    property Timer ticker: Timer {
        interval: 500
        repeat: true
        running: root.automatic
        onTriggered: root.evaluate(Date.now())
    }

    function reset(nowMs) {
        var now = nowMs === undefined ? Date.now() : nowMs
        lastUserActivityMs = now
        eventWakeUntilMs = 0
        ambientMode = false
    }

    function noteUserActivity(nowMs) {
        var now = nowMs === undefined ? Date.now() : nowMs
        lastUserActivityMs = now
        eventWakeUntilMs = 0
        evaluate(now)
    }

    function noteEvent(nowMs) {
        var now = nowMs === undefined ? Date.now() : nowMs

        if (now - lastUserActivityMs >= inactivityMs)
            eventWakeUntilMs = Math.max(eventWakeUntilMs, now + eventWakeMs)

        evaluate(now)
    }

    function evaluate(nowMs) {
        var now = nowMs === undefined ? Date.now() : nowMs
        ambientMode = now - lastUserActivityMs >= inactivityMs
                && now >= eventWakeUntilMs
        return ambientMode
    }
}
