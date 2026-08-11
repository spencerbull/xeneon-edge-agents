local modulePath = assert(arg[1], "generated Hyprland module path is required")
local deviceCalls = {}
local commands = {}
local subscriptions = {}

hl = {
  device = function(spec)
    table.insert(deviceCalls, spec)
  end,
  exec_cmd = function(command)
    table.insert(commands, command)
  end,
  on = function(event, callback)
    subscriptions[event] = callback
  end,
  timer = function()
    return {
      set_enabled = function() end,
    }
  end,
}

assert(loadfile(modulePath))()

local function assertDisabled(call, label)
  assert(call ~= nil, label .. " did not configure the touchscreen")
  assert(call.name == "wch.cn-touchscreen-1", label .. " targeted the wrong device")
  assert(call.enabled == false, label .. " did not disable the touchscreen")
  assert(call.output == nil, label .. " retained a stale output mapping")
end

assertDisabled(deviceCalls[1], "initial reconciliation")
assert(#commands == 1, "initial reconciliation did not request the lifecycle service")
assert(commands[1]:match(" start xeneon%-edge%-reconcile%.service$"),
  "initial reconciliation did not start the lifecycle service")

assert(subscriptions["monitor.added"] ~= nil, "monitor.added callback is missing")
subscriptions["monitor.added"]()
assertDisabled(deviceCalls[2], "monitor add")
assert(#commands == 2, "monitor add requested duplicate lifecycle retries")
assert(commands[2]:match(" restart xeneon%-edge%-reconcile%.service$"),
  "monitor add did not supersede an in-flight reconciliation")

assert(subscriptions["monitor.removed"] ~= nil, "monitor.removed callback is missing")
subscriptions["monitor.removed"]()
assertDisabled(deviceCalls[3], "monitor removal")
assert(#commands == 3, "monitor removal requested duplicate lifecycle retries")
assert(commands[3]:match(" restart xeneon%-edge%-reconcile%.service$"),
  "monitor removal did not supersede an in-flight reconciliation")
