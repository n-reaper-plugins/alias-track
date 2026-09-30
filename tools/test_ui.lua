package.path = "./src/?.lua;./tools/?.lua;" .. package.path
local T = require("t")
local Mock = require("mock_reaper")
local S = Mock.install()
local Stub = require("imgui_stub")
local st = Stub.install(reaper)
local App = require("ATApp")
local UI = require("ATUI")

local drums = Mock.track("Drums", 1)
local kick = Mock.track("Kick", 0)
local hh = Mock.track("HH", -1)
local k = Mock.item(kick, 10, 1, "/s/kick.wav")
local h = Mock.item(hh, 10, 2, "/s/hh.wav")

local app = App.new()
local ui = UI.new(app)
local function frame() st.calls, st.texts = {}, {}; return ui.frame() end
local function has(call) for _, c in ipairs(st.calls) do if c == call then return true end end return false end
local function has_text(sub) for _, t in ipairs(st.texts) do if t:find(sub, 1, true) then return true end end return false end

-- colour stack
local pushes, pops = 0, 0
reaper.ImGui_PushStyleColor = function() pushes = pushes + 1 end
reaper.ImGui_PopStyleColor = function(_, n) pops = pops + (n or 1) end
T.ok(frame(), "window stays open")
T.eq(ui.state.err, nil, "empty window draws without error")
T.eq(pushes, 17, "all 17 theme colours pushed")
T.eq(pushes, pops, "colour stack balanced when open")
local real_begin = reaper.ImGui_Begin
reaper.ImGui_Begin = function() return false, true end
pushes, pops = 0, 0
frame()
T.eq(pushes, 17, "theme pushed when collapsed too"); T.eq(pops, 17, "and popped: balanced when collapsed")
reaper.ImGui_Begin = real_begin

frame()
T.ok(has_text("No groups yet"), "hint when there are no groups")
T.ok(has_text("Select the items to group"), "selection hint")

-- group via the button
Mock.select({ k, h })
st.input_text = "Groove"
frame()                                             -- name typed
st.clicks["Group selected items"] = true
frame()
T.eq(#app.view, 1, "button groups the selection")
T.ok(Mock.track_named("ALIAS · Groove") ~= nil, "named from the input field")
frame()
T.ok(has_text("Groove"), "group listed"); T.ok(has("SmallButton:Make unique"), "instance row has Make unique")
T.ok(has_text("2 member(s)"), "member count shown")

-- a mixed alias shows Apply / Revert
Mock.delete(k); app:sync()
frame()
T.ok(has_text("MIXED: deleted"), "mixed state shown in words")
T.ok(has("SmallButton:Apply") and has("SmallButton:Revert"), "Apply and Revert offered")
st.clicks["Revert"] = true
frame()
T.eq(#kick.items, 1, "Revert button recreates the member")

-- settings
st.clicks["Apply member edits to the group automatically"] = true
frame()
T.eq(app.cfg.propagate, false, "checkbox toggles a setting")
T.ok(S.ext["AliasTrack/cfg"]:find("propagate=0"), "setting saved")
local rb = reaper.ImGui_RadioButton
reaper.ImGui_RadioButton = function(_, label) return label:find("undo_steps", 1, true) ~= nil end
frame()
T.eq(app.cfg.undo_mode, "steps", "radio button switches the undo mode")
reaper.ImGui_RadioButton = rb

-- freeze
st.clicks["Freeze"] = true
frame()
T.eq(app.cfg.live, false, "Freeze button")
frame()
T.ok(has_text("FROZEN"), "frozen state shown")

-- detach needs a confirmation
st.clicks["Detach all..."] = true
frame()
T.ok(Mock.track_named("ALIAS · Groove").ext.AT_lane ~= nil, "first click only asks")
st.clicks["Yes, detach"] = true
frame()
T.ok(Mock.track_named("ALIAS · Groove").ext.AT_lane == nil, "confirmed: detached")

T.done("test_ui")
