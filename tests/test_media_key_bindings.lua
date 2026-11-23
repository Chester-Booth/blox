-- Run with: lua tests/test_media_key_bindings.lua path/to/binds.lua [preimage]
-- Hyprland is entirely stubbed. This never connects to the compositor.
local bindings_path = assert(arg[1], "binds.lua path required")
local bindings, dispatched = {}, {}
local function dispatcher(name)
    return setmetatable({}, {
        __index = function(_, part) return dispatcher(name .. "." .. part) end,
        __call = function(_, payload) return { dispatcher = name, payload = payload } end,
    })
end
package.preload.programs = function()
    return { terminal = "fake-terminal", file_manager = "fake-files" }
end
hl = {
    dsp = dispatcher("dsp"),
    bind = function(key, action, options)
        bindings[#bindings + 1] = { key = key, action = action, options = options }
    end,
    dispatch = function(action) dispatched[#dispatched + 1] = action end,
    timer = function() return { set_enabled = function() end } end,
}
assert(loadfile(bindings_path))()
local current = bindings
local changed = {
    XF86AudioRaiseVolume = "volume-up", XF86AudioLowerVolume = "volume-down",
    XF86AudioMute = "volume-mute", XF86AudioMicMute = "mic-mute",
    XF86MonBrightnessUp = "brightness-up", XF86MonBrightnessDown = "brightness-down",
}
local found = 0
for _, binding in ipairs(current) do
    local key = changed[binding.key]
    if key then
        found = found + 1
        assert(type(binding.action) == "function", binding.key .. " must dispatch in process")
        assert(binding.options.repeating == true and binding.options.locked == true)
        dispatched = {}
        for _ = 1, 80 do binding.action() end
        local brightness = key:match("^brightness") ~= nil
        assert(#dispatched == (brightness and 160 or 80))
        for i, action in ipairs(dispatched) do
            if brightness and i % 2 == 1 then
                assert(action.dispatcher == "dsp.dpms" and action.payload.action == "enable")
            else
                assert(action.dispatcher == "dsp.event", "no exec or IPC dispatcher in media repeats")
                assert(action.payload == "blox_media_key>>" .. key)
            end
        end
    end
end
assert(found == 6)
-- Compare registrations and every unchanged dispatcher/options against preimage.
local function equal(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) == "function" then return true end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do if not equal(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end
if arg[2] then
    bindings = {}
    assert(loadfile(arg[2]))()
    assert(#bindings == #current)
    for i, old in ipairs(bindings) do
        local new = current[i]
        assert(new.key == old.key and equal(new.options, old.options), "binding order/options changed")
        if not changed[new.key] then
            assert(equal(new.action, old.action), "unrelated dispatcher changed: " .. new.key)
        end
    end
end
print("PASS: six fixed media bindings, 80 repeats each, ordered native DPMS/event dispatch; unchanged registrations/options preserved")
