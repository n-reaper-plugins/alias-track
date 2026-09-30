-- In-memory fake of the parts of the REAPER API that AliasTrack uses. It checks OUR logic, not REAPER's behaviour.
-- REAPER behaviours reproduced on purpose (confirmed in real REAPER, see spikes/SPIKES.md):
--   * item P_EXT tags are NOT copied by split, copy/duplicate or paste
--   * a split keeps the ORIGINAL item as the left piece; the right piece is a new item (new GUIDs)
--   * the take start offset follows splits (right piece: offset + distance * rate)
--   * SetItemStateChunk takes the GUIDs written in the chunk (so we must refresh them ourselves)

local M = {}

function M.install()
  local S = { tracks = {}, ext = {}, statecount = 1, guid_n = 0, undo = {}, redo = nil, clock = 0, dirty = 0 }
  M.S = S
  local function bump() S.statecount = S.statecount + 1 end
  local function guid() S.guid_n = S.guid_n + 1; return string.format("{%08X-0000-4000-8000-%012X}", S.guid_n, S.guid_n) end
  M.guid = guid
  local function tidx(t) for i, x in ipairs(S.tracks) do if x == t then return i end end end

  local function new_take(opts)
    return { guid = guid(), name = opts.name or "", src = { file = opts.file or "", midi = opts.midi or false },
             pool = opts.midi and guid() or nil, fx = opts.fx or {},
             p = { D_STARTOFFS = opts.soffs or 0, D_PLAYRATE = opts.rate or 1, D_PITCH = 0, D_VOL = 1 } }
  end
  local function new_item(t, pos, len)
    local it = { guid = guid(), track = t, ext = {}, takes = {},
                 p = { D_POSITION = pos or 0, D_LENGTH = len or 0, D_VOL = 1, B_MUTE = 0, D_FADEINLEN = 0, D_FADEOUTLEN = 0,
                       B_UISEL = 0, B_LOOPSRC = 1, I_CUSTOMCOLOR = 0 } }
    t.items[#t.items + 1] = it
    return it
  end
  local function copy_take(tk, keep_pool)
    local n = { guid = guid(), name = tk.name, src = { file = tk.src.file, midi = tk.src.midi },
                pool = keep_pool and tk.pool or (tk.src.midi and guid() or nil), fx = {}, p = {} }
    for k, v in pairs(tk.p) do n.p[k] = v end
    for i, f in ipairs(tk.fx) do n.fx[i] = f end
    return n
  end

  --------------------------------------------------------------------------------------------- scene helpers (the "user")
  function M.track(name, depth)
    local t = { guid = guid(), name = name, depth = depth or 0, ext = {}, items = {}, color = 0 }
    S.tracks[#S.tracks + 1] = t; bump(); return t
  end
  function M.item(t, pos, len, file, opts)
    opts = opts or {}
    local it = new_item(t, pos, len)
    opts.file = file; opts.name = opts.name or (file and file:match("([^/]+)$")) or ""
    it.takes[1] = new_take(opts)
    bump(); return it
  end
  function M.split(it, t) local rgt = reaper.SplitMediaItem(it, t); return rgt end
  function M.copy(it, track, pos)                      -- ctrl-drag / duplicate: tags are NOT copied
    local n = new_item(track or it.track, pos, it.p.D_LENGTH)
    for k, v in pairs(it.p) do if k ~= "D_POSITION" then n.p[k] = v end end
    n.p.B_UISEL = 0
    for i, tk in ipairs(it.takes) do n.takes[i] = copy_take(tk, true) end
    bump(); return n
  end
  function M.move(it, pos) it.p.D_POSITION = pos; bump() end
  function M.nudge(it, d) it.p.D_POSITION = it.p.D_POSITION + d; bump() end
  function M.set(it, k, v) it.p[k] = v; bump() end
  function M.set_take(it, k, v) it.takes[1].p[k] = v; bump() end
  function M.trim_left(it, t)                           -- drag the left edge to t
    local d = t - it.p.D_POSITION
    it.p.D_POSITION = t; it.p.D_LENGTH = it.p.D_LENGTH - d
    local tk = it.takes[1]; if tk then tk.p.D_STARTOFFS = tk.p.D_STARTOFFS + d * tk.p.D_PLAYRATE end
    bump()
  end
  function M.trim_right(it, e) it.p.D_LENGTH = e - it.p.D_POSITION; bump() end
  function M.delete(it) reaper.DeleteTrackMediaItem(it.track, it) end
  function M.move_track(it, t) reaper.MoveMediaItemToTrack(it, t) end
  function M.select(list)
    for _, t in ipairs(S.tracks) do for _, it in ipairs(t.items) do it.p.B_UISEL = 0 end end
    for _, it in ipairs(list) do it.p.B_UISEL = 1 end
    bump()
  end
  -- razor edit + delete of [t1, t2) on the given tracks
  function M.razor_delete(tracks, t1, t2)
    for _, tr in ipairs(tracks) do
      local list = {}
      for _, it in ipairs(tr.items) do list[#list + 1] = it end
      for _, it in ipairs(list) do
        local s, e = it.p.D_POSITION, it.p.D_POSITION + it.p.D_LENGTH
        if e > t1 and s < t2 then
          local mid = it
          if s < t1 then mid = reaper.SplitMediaItem(it, t1) end
          if e > t2 then reaper.SplitMediaItem(mid, t2) end
          reaper.DeleteTrackMediaItem(tr, mid)
        end
      end
    end
  end
  function M.items_on(t)
    local out = {}
    for _, it in ipairs(t.items) do out[#out + 1] = it end
    table.sort(out, function(a, b) return a.p.D_POSITION < b.p.D_POSITION end)
    return out
  end
  function M.tag(it, k) return it.ext[k] end
  function M.track_named(name) for _, t in ipairs(S.tracks) do if t.name == name then return t end end end
  function M.structure()
    local out, depth = {}, 0
    for _, t in ipairs(S.tracks) do out[#out + 1] = string.rep("  ", depth) .. t.name; depth = depth + t.depth end
    return out, depth
  end
  function M.all_guids()
    local seen, dup = {}, 0
    for _, t in ipairs(S.tracks) do
      for _, it in ipairs(t.items) do
        for _, g in ipairs({ it.guid, it.takes[1] and it.takes[1].guid or nil }) do
          if g then if seen[g] then dup = dup + 1 end; seen[g] = true end
        end
      end
    end
    return dup
  end

  --------------------------------------------------------------------------------------------- API
  local R = {}
  reaper = R
  R.ShowConsoleMsg = function() end
  R.MB = function() return 1 end
  R.atexit = function() end
  R.defer = function() end
  R.time_precise = function() return S.clock end
  R.get_action_context = function() return true, "x", 0, 0, 0, 0 end
  R.SetToggleCommandState = function() end
  R.RefreshToolbar2 = function() end
  R.GetExtState = function(sec, k) return S.ext[sec .. "/" .. k] or "" end
  R.SetExtState = function(sec, k, v) S.ext[sec .. "/" .. k] = v end
  R.GetProjectStateChangeCount = function() return S.statecount end
  R.PreventUIRefresh = function() end
  R.UpdateArrange = function() end
  R.MarkProjectDirty = function() S.dirty = S.dirty + 1 end
  R.Undo_BeginBlock2 = function() S.in_block = true end
  R.Undo_EndBlock2 = function(_, label) S.in_block = false; S.undo[#S.undo + 1] = label end
  R.Undo_CanRedo2 = function() return S.redo end
  R.genGuid = function() return guid() end
  R.ColorToNative = function(r, g, b) return r | (g << 8) | (b << 16) end
  R.ColorFromNative = function(c) return c & 0xFF, (c >> 8) & 0xFF, (c >> 16) & 0xFF end
  R.format_timestr_pos = function(p) return string.format("%.3f", p) end

  -- tracks
  R.CountTracks = function() return #S.tracks end
  R.GetTrack = function(_, i) return S.tracks[i + 1] end
  R.GetTrackGUID = function(t) return t.guid end
  R.InsertTrackAtIndex = function(i)
    table.insert(S.tracks, i + 1, { guid = guid(), name = "", depth = 0, ext = {}, items = {}, color = 0 }); bump()
  end
  R.DeleteTrack = function(t) table.remove(S.tracks, assert(tidx(t), "DeleteTrack: unknown")); t.deleted = true; bump() end
  R.GetMediaTrackInfo_Value = function(t, k)
    assert(not t.deleted, "deleted track")
    if k == "I_FOLDERDEPTH" then return t.depth end
    if k == "IP_TRACKNUMBER" then return tidx(t) or 0 end
    if k == "I_CUSTOMCOLOR" then return t.color end
    error("track value " .. k)
  end
  R.SetMediaTrackInfo_Value = function(t, k, v)
    if k == "I_FOLDERDEPTH" then t.depth = v elseif k == "I_CUSTOMCOLOR" then t.color = v else error("set track " .. k) end
    bump()
  end
  R.GetSetMediaTrackInfo_String = function(t, k, v, set)
    assert(not t.deleted, "deleted track")
    if k == "P_NAME" then if set then t.name = v; bump(); return true, v end; return true, t.name end
    local ek = assert(k:match("^P_EXT:(.+)$"), "track string " .. k)
    if set then t.ext[ek] = (v ~= "" and v) or nil; bump(); return true, v end
    return t.ext[ek] ~= nil, t.ext[ek] or ""
  end

  -- items
  R.CountTrackMediaItems = function(t) return #t.items end
  R.GetTrackMediaItem = function(t, i) return t.items[i + 1] end
  R.GetMediaItem_Track = function(it) return it.track end
  R.AddMediaItemToTrack = function(t) local it = new_item(t, 0, 0); bump(); return it end
  R.DeleteTrackMediaItem = function(t, it)
    for i, x in ipairs(t.items) do if x == it then table.remove(t.items, i); it.deleted = true; bump(); return true end end
    error("DeleteTrackMediaItem: not on track")
  end
  R.MoveMediaItemToTrack = function(it, t)
    for i, x in ipairs(it.track.items) do if x == it then table.remove(it.track.items, i); break end end
    it.track = t; t.items[#t.items + 1] = it; bump(); return true
  end
  R.GetMediaItemInfo_Value = function(it, k)
    assert(not it.deleted, "deleted item"); assert(it.p[k] ~= nil, "item value " .. k); return it.p[k]
  end
  R.SetMediaItemInfo_Value = function(it, k, v) assert(not it.deleted, "deleted item"); it.p[k] = v; bump(); return true end
  R.GetSetMediaItemInfo_String = function(it, k, v, set)
    assert(not it.deleted, "deleted item")
    if k == "GUID" then return true, it.guid end
    local ek = assert(k:match("^P_EXT:(.+)$"), "item string " .. k)
    if set then it.ext[ek] = (v ~= "" and v) or nil; bump(); return true, v end
    return it.ext[ek] ~= nil, it.ext[ek] or ""
  end
  R.SelectAllMediaItems = function(_, s) for _, t in ipairs(S.tracks) do for _, it in ipairs(t.items) do it.p.B_UISEL = s and 1 or 0 end end end
  R.SetMediaItemSelected = function(it, s) it.p.B_UISEL = s and 1 or 0 end

  -- takes
  R.GetActiveTake = function(it) return it.takes[1] end
  R.TakeIsMIDI = function(tk) return tk.src.midi end
  R.GetMediaItemTakeInfo_Value = function(tk, k) assert(tk.p[k] ~= nil, "take value " .. k); return tk.p[k] end
  R.SetMediaItemTakeInfo_Value = function(tk, k, v) tk.p[k] = v; bump(); return true end
  R.GetSetMediaItemTakeInfo_String = function(tk, k, v, set)
    assert(k == "P_NAME", "take string " .. k)
    if set then tk.name = v; bump(); return true, v end
    return true, tk.name
  end
  R.GetMediaItemTake_Source = function(tk) return tk.src end
  R.GetMediaSourceFileName = function(src) return src.midi and "" or src.file end

  R.CreateNewMIDIItemInProj = function(t, s, e)
    local it = new_item(t, s, e - s)
    it.takes[1] = new_take({ midi = true, name = "" })
    bump(); return it
  end

  -- split: the original stays the left piece and keeps its tags; the right piece is new and untagged
  R.SplitMediaItem = function(it, t)
    local s, e = it.p.D_POSITION, it.p.D_POSITION + it.p.D_LENGTH
    if t <= s + 1e-9 or t >= e - 1e-9 then return nil end
    local rgt = new_item(it.track, t, e - t)
    for k, v in pairs(it.p) do if k ~= "D_POSITION" and k ~= "D_LENGTH" then rgt.p[k] = v end end
    for i, tk in ipairs(it.takes) do
      local n = copy_take(tk, true)
      n.p.D_STARTOFFS = tk.p.D_STARTOFFS + (t - s) * tk.p.D_PLAYRATE
      rgt.takes[i] = n
    end
    it.p.D_LENGTH = t - s
    it.p.D_FADEOUTLEN = 0; rgt.p.D_FADEINLEN = 0
    bump(); return rgt
  end

  -- chunks: a small flat stand-in for the real format, with the GUID lines we have to refresh
  R.GetItemStateChunk = function(it)
    local tk = it.takes[1]
    local L = { "<ITEM", "POSITION " .. it.p.D_POSITION, "LENGTH " .. it.p.D_LENGTH, "IGUID " .. it.guid }
    if tk then
      L[#L + 1] = "NAME \"" .. tk.name .. "\""
      L[#L + 1] = "GUID " .. tk.guid
      L[#L + 1] = tk.src.midi and "SOURCE MIDI" or ("FILE \"" .. tk.src.file .. "\"")
      if tk.pool then L[#L + 1] = "POOLEDEVTS " .. tk.pool end
      for _, f in ipairs(tk.fx) do L[#L + 1] = "FX " .. f.name; L[#L + 1] = "FXID " .. f.id end
    end
    L[#L + 1] = ">"
    return true, table.concat(L, "\n")
  end
  R.SetItemStateChunk = function(it, chunk)
    local tk = { p = { D_STARTOFFS = 0, D_PLAYRATE = 1, D_PITCH = 0, D_VOL = 1 }, fx = {}, src = { file = "", midi = false }, name = "" }
    local fxname
    for line in chunk:gmatch("[^\n]+") do
      local k, v = line:match("^%s*(%u+)%s*(.*)$")
      if k == "IGUID" then it.guid = v
      elseif k == "POSITION" then it.p.D_POSITION = tonumber(v)
      elseif k == "LENGTH" then it.p.D_LENGTH = tonumber(v)
      elseif k == "NAME" then tk.name = v:match('^"(.*)"$') or v
      elseif k == "GUID" then tk.guid = v
      elseif k == "FILE" then tk.src.file = v:match('^"(.*)"$') or v
      elseif k == "SOURCE" and v == "MIDI" then tk.src.midi = true
      elseif k == "POOLEDEVTS" then tk.pool = v
      elseif k == "FX" then fxname = v
      elseif k == "FXID" then tk.fx[#tk.fx + 1] = { name = fxname, id = v } end
    end
    it.takes = { tk }
    bump(); return true
  end

  return S
end

return M
