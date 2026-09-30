-- spike_1_probe.lua - run inside REAPER (Actions > Load ReaScript). Checks spikes S1..S4 on a temporary track,
-- prints a report to the console and removes the track again. Your project is otherwise untouched
-- (the whole run is one undo step "AliasTrack probe" in case anything is left over).
local r = reaper
local out = {}
local function say(fmt, ...) out[#out + 1] = string.format(fmt, ...) end
local function check(name, cond, detail) say("%-4s %-58s %s", cond and "OK" or "FAIL", name, detail or "") end

local SPLIT, DUPLICATE, TRIM_LEFT, TRIM_RIGHT = 40012, 41295, 41305, 41311   -- REAPER 7 action ids

local cursor = r.GetCursorPosition()
r.Undo_BeginBlock2(0)
r.PreventUIRefresh(1)
r.InsertTrackAtIndex(r.CountTracks(0), true)
local tr = r.GetTrack(0, r.CountTracks(0) - 1)
r.GetSetMediaTrackInfo_String(tr, "P_NAME", "AliasTrack probe", true)

local function only(it) r.SelectAllMediaItems(0, false); r.SetMediaItemSelected(it, true) end
local function offs(it) return r.GetMediaItemTakeInfo_Value(r.GetActiveTake(it), "D_STARTOFFS") end
local function items() local t = {}; for i = 0, r.CountTrackMediaItems(tr) - 1 do t[#t + 1] = r.GetTrackMediaItem(tr, i) end; return t end
local function tag(it) local _, v = r.GetSetMediaItemInfo_String(it, "P_EXT:AT_probe", "", false); return v end

local ok, err = pcall(function()
  -- S1: offset through trim and split
  local it = r.CreateNewMIDIItemInProj(tr, 10, 14, false)
  r.SetMediaItemInfo_Value(it, "B_LOOPSRC", 0)
  r.GetSetMediaItemTakeInfo_String(r.GetActiveTake(it), "P_NAME", "Beat #3", true)
  r.GetSetMediaItemInfo_String(it, "P_EXT:AT_probe", "tagged", true)
  only(it); r.SetEditCurPos(11, false, false); r.Main_OnCommand(TRIM_LEFT, 0)
  check("S1 left trim moves the take offset", math.abs(offs(it) - 1) < 1e-6, string.format("offs = %.6f (want 1)", offs(it)))
  r.SetEditCurPos(12, false, false); only(it); r.Main_OnCommand(SPLIT, 0)
  local list = items()
  table.sort(list, function(a, b) return r.GetMediaItemInfo_Value(a, "D_POSITION") < r.GetMediaItemInfo_Value(b, "D_POSITION") end)
  check("S1 split gives two items", #list == 2, #list .. " item(s)")
  if #list == 2 then
    check("S1 right piece offset = offs + distance", math.abs(offs(list[2]) - 2) < 1e-6, string.format("offs = %.6f (want 2)", offs(list[2])))
    check("S3 left piece is the original (keeps P_EXT)", tag(list[1]) == "tagged", "left tag = '" .. tag(list[1]) .. "'")
    check("S3 split does not copy P_EXT", tag(list[2]) == "", "right tag = '" .. tag(list[2]) .. "'")
    -- S2: extend the right piece far beyond its source
    local right = list[2]
    only(right); r.SetEditCurPos(30, false, false); r.Main_OnCommand(TRIM_RIGHT, 0)
    local e = r.GetMediaItemInfo_Value(right, "D_POSITION") + r.GetMediaItemInfo_Value(right, "D_LENGTH")
    check("S2 unlooped MIDI item extends past its end", math.abs(e - 30) < 1e-6, string.format("end = %.3f (want 30)", e))
    check("S2 still not looping", r.GetMediaItemInfo_Value(right, "B_LOOPSRC") == 0)
    -- S3: duplicate
    only(list[1]); r.Main_OnCommand(DUPLICATE, 0)
    local dup
    for _, x in ipairs(items()) do if x ~= list[1] and x ~= list[2] then dup = x end end
    check("S3 duplicate exists", dup ~= nil)
    if dup then
      local _, nm = r.GetSetMediaItemTakeInfo_String(r.GetActiveTake(dup), "P_NAME", "", false)
      check("S3 duplicate does not copy P_EXT", tag(dup) == "", "tag = '" .. tag(dup) .. "'")
      check("S3 duplicate copies the take name", nm == "Beat #3", "name = '" .. nm .. "'")
      check("S3 duplicate keeps the offset", math.abs(offs(dup) - offs(list[1])) < 1e-6)
    end
  end
  -- S4: SetItemStateChunk with a copied chunk
  local src = items()[1]
  local _, chunk = r.GetItemStateChunk(src, "", false)
  local copy = r.AddMediaItemToTrack(tr)
  r.SetItemStateChunk(copy, chunk, false)
  local _, g1 = r.GetSetMediaItemInfo_String(src, "GUID", "", false)
  local _, g2 = r.GetSetMediaItemInfo_String(copy, "GUID", "", false)
  check("S4 chunk copy keeps the GUID (so we must refresh it)", g1 == g2, g1 == g2 and "same GUID" or "REAPER made a new one")
end)

r.DeleteTrack(tr)
r.SetEditCurPos(cursor, false, false)
r.PreventUIRefresh(-1)
r.Undo_EndBlock2(0, "AliasTrack probe", -1)
r.UpdateArrange()
if not ok then say("ERROR: %s", tostring(err)) end
r.ShowConsoleMsg("AliasTrack probe (REAPER " .. r.GetAppVersion() .. ")\n" .. table.concat(out, "\n") .. "\n\n")
