-- The shipped single file must work without src/ on the path.
package.path = "./tools/?.lua;" .. package.path
local T = require("t")
local Mock = require("mock_reaper")
local Stub = require("imgui_stub")

for k in pairs(package.loaded) do if k:match("^AT") then package.loaded[k] = nil end end
local S = Mock.install()
local st = Stub.install(reaper)
local deferred
reaper.defer = function(f) deferred = f end
local drums = Mock.track("Drums", 1)
local kick = Mock.track("Kick", -1)
local k = Mock.item(kick, 1, 1, "/s/k.wav")

local f = assert(loadfile("dist/AliasTrack.lua"))
local ok, err = pcall(f)
T.ok(ok, "bundle runs: " .. tostring(err))
T.ok(deferred ~= nil, "main loop scheduled")
T.ok(package.preload["ATApp"] ~= nil, "modules come from the bundle")
local src = io.open("dist/AliasTrack.lua"):read("*a")
T.ok(src:find("@version 0.1.0", 1, true) ~= nil, "version stamped into the ReaPack header")
T.ok(not src:find("@@VERSION@@", 1, true), "no placeholder left")

-- run a few frames: group through the button, move the alias, let the debounce pass
Mock.select({ k })
st.clicks["Group selected items"] = true
for i = 1, 3 do S.clock = S.clock + 1; local d = deferred; deferred = nil; local ok2, e2 = pcall(d); T.ok(ok2, "frame " .. i .. ": " .. tostring(e2)) end
local lane = Mock.track_named("ALIAS · Group 1")
T.ok(lane ~= nil, "grouped from the bundled UI")
Mock.nudge(Mock.items_on(lane)[1], 2)
for _ = 1, 3 do S.clock = S.clock + 1; local d = deferred; deferred = nil; pcall(d) end
T.eq(k.p.D_POSITION, 3, "the running loop syncs the member")

-- running the action again closes the window
reaper.GetExtState = function(sec, key) if key == "running" then return "1" end if key == "hb" then return tostring(os.time()) end return S.ext[sec .. "/" .. key] or "" end
local ok3 = pcall(assert(loadfile("dist/AliasTrack.lua")))
T.ok(ok3, "second start runs"); T.eq(S.ext["AliasTrackApp/stop"], "1", "second start asks the first to stop")

T.done("test_bundle")
