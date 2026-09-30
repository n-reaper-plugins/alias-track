-- @description AliasTrack: linked item groups inside REAPER folders (alias items that move, cut and copy their contents)
-- @version 0.1.0
-- @author _n_plugins
-- @about
--   Select items on tracks inside one folder and group them: an ALIAS lane appears in that folder with one alias item
--   spanning the selection. Moving the alias moves its members, trimming it hides/reveals them, cutting it (or any member)
--   cuts the whole group, and copying it makes a linked copy. Aliases on the COPIES lane are independent.
--   Needs ReaImGui (ReaPack > ReaTeam Extensions). Run the action again while the window is open to close it.
-- BUNDLED BUILD of AliasTrack v0.1.0 - edit the files in src/, not this one.
local __preload = package.preload
__preload["ATVersion"] = function(...)
return { VERSION = "0.1.0" }

end
__preload["ATCore"] = function(...)
-- ATCore.lua
-- Pure logic for AliasTrack. No reaper.* calls here, so everything in this file is tested with plain Lua.
--
-- Model
--   group      one ALIAS lane track (linked instances) + optional COPIES lane (unique instances), inside one folder
--   def        a definition: member items in def-local time 0..len (the "virtual source" of an alias)
--   instance   one alias item = a window { pos, len, offs } onto a def (offs = the alias take's start offset)
--   member     a real item materialised from a def member, clipped to the window and shifted to the window's position

local C = {}

C.EPS = 1e-5            -- seconds; positions/lengths closer than this are equal

local function approx(a, b, eps) return math.abs((a or 0) - (b or 0)) <= (eps or C.EPS) end
C.approx = approx

--------------------------------------------------------------------------------------------------- snapshots
-- A snapshot is what one member item looks like: geometry + the properties we propagate.
C.GEOM  = { "pos", "len", "soffs" }
C.PROPS = { "vol", "mute", "rate", "pitch", "tvol" }
C.FADES = { "fin", "fout" }
C.FIELDS = { "pos", "len", "soffs", "vol", "mute", "rate", "pitch", "tvol", "fin", "fout", "track" }

local function num(v) return string.format("%.10g", v or 0) end

-- the last field carries the clip flags (1 = left edge clipped, 2 = right edge clipped)
function C.snap_encode(s)
  local out = {}
  for i, k in ipairs(C.FIELDS) do out[i] = (k == "track") and (s.track or "") or num(s[k]) end
  out[#out + 1] = tostring((s.clipL and 1 or 0) + (s.clipR and 2 or 0))
  return table.concat(out, "|")
end

function C.snap_decode(str)
  if not str or str == "" then return nil end
  local parts, s = {}, {}
  for p in (str .. "|"):gmatch("([^|]*)|") do parts[#parts + 1] = p end
  if #parts < #C.FIELDS then return nil end
  for i, k in ipairs(C.FIELDS) do
    if k == "track" then s[k] = parts[i] else s[k] = tonumber(parts[i]) or 0 end
  end
  local clip = tonumber(parts[#C.FIELDS + 1]) or 0
  s.clipL, s.clipR = clip % 2 == 1, clip >= 2
  return s
end

function C.geom_eq(a, b)
  if not a or not b then return false end
  return approx(a.pos, b.pos) and approx(a.len, b.len) and approx(a.soffs, b.soffs) and (a.track or "") == (b.track or "")
end

function C.props_eq(a, b)
  if not a or not b then return false end
  for _, k in ipairs(C.PROPS) do if not approx(a[k], b[k]) then return false end end
  return true
end

-- equal as far as we care: geometry, props and the fades on edges that are not clipped
function C.snap_eq(a, b)
  if not (C.geom_eq(a, b) and C.props_eq(a, b)) then return false end
  if not b.clipL and not approx(a.fin, b.fin) then return false end
  if not b.clipR and not approx(a.fout, b.fout) then return false end
  return true
end

--------------------------------------------------------------------------------------------------- windows
-- anchor = the project time at which def-local time 0 sits. All pieces of one window share it (splits keep it).
function C.anchor(pos, offs, rate) return pos - (offs or 0) / (rate or 1) end

-- The part of def member m visible through window w, as a snapshot (or nil if nothing is visible).
-- m: { track, rel, len, soffs, rate, pitch, tvol, vol, mute, fin, fout }   w: { pos, len, offs }
function C.visible(m, w, clipfade)
  local a = math.max(m.rel, w.offs)
  local b = math.min(m.rel + m.len, w.offs + w.len)
  if b - a <= C.EPS then return nil end
  local clipL = a > m.rel + C.EPS
  local clipR = b < m.rel + m.len - C.EPS
  local len = b - a
  local cf = math.min(clipfade or 0, len / 2)
  local fin  = clipL and cf or math.min(m.fin or 0, len)
  local fout = clipR and cf or math.min(m.fout or 0, len)
  return {
    track = m.track, pos = w.pos + (a - w.offs), len = len,
    soffs = (m.soffs or 0) + (a - m.rel) * (m.rate or 1),
    vol = m.vol or 1, mute = m.mute or 0, rate = m.rate or 1, pitch = m.pitch or 0, tvol = m.tvol or 1,
    fin = fin, fout = fout, clipL = clipL, clipR = clipR, a = a, b = b,
  }
end

function C.window_end(w) return w.pos + w.len end

--------------------------------------------------------------------------------------------------- classification
-- What happened to one member item since we last wrote it?
--   A = actual (now), S = applied (last written by us), N = wanted (from the def and the CURRENT window; nil = not visible)
--   info = { in_folder = function(track_guid) -> bool, window = { pos, len, offs }, def_member = m }
-- Returns { kind = "ok" | "write" | "edit" | "mixed", reason, edit = { geom = {...}, props = {...}, track = guid } }
function C.classify(A, S, N, info)
  if N and C.snap_eq(A, N) then return { kind = "ok" } end
  if S and C.snap_eq(A, S) then return { kind = "write" } end
  if not S then return { kind = "write" } end
  local edit = { props = {} }
  local changed = false
  -- track
  if (A.track or "") ~= (S.track or "") and (not N or (A.track or "") ~= (N.track or "")) then
    if info.in_folder(A.track) then edit.track = A.track; changed = true
    else return { kind = "mixed", reason = "outside_folder" } end
  end
  -- geometry: fine when it matches the wanted piece (window explains it) or the applied one (window moved)
  local gA = { pos = A.pos, len = A.len, soffs = A.soffs }
  local function geq(x) return x and approx(gA.pos, x.pos) and approx(gA.len, x.len) and approx(gA.soffs, x.soffs) end
  if not (geq(N) or geq(S)) then
    local m, w = info.def_member, info.window
    local was_clipped = S.clipL or S.clipR or not (approx(S.len, m.len) and approx(S.soffs, m.soffs))
    if was_clipped then return { kind = "mixed", reason = "clipped_edit" } end
    if A.pos < w.pos - C.EPS or A.pos + A.len > w.pos + w.len + C.EPS then
      return { kind = "mixed", reason = "outside_window" }
    end
    edit.geom = { rel = A.pos - w.pos + w.offs, len = A.len, soffs = A.soffs }
    changed = true
  end
  -- properties
  for _, k in ipairs(C.PROPS) do
    if not approx(A[k], S[k]) and not (N and approx(A[k], N[k])) then edit.props[k] = A[k]; changed = true end
  end
  -- fades, only on edges that are not clipped (clipped edges carry our own short fade)
  local refL, refR = N or S, N or S
  if not refL.clipL and not approx(A.fin, S.fin) and not approx(A.fin, refL.fin) then edit.props.fin = A.fin; changed = true end
  if not refR.clipR and not approx(A.fout, S.fout) and not approx(A.fout, refR.fout) then edit.props.fout = A.fout; changed = true end
  if not changed then return { kind = "write" } end
  return { kind = "edit", edit = edit }
end

-- apply an edit (from classify) to a def member, in place
function C.apply_edit(m, edit)
  if edit.track then m.track = edit.track end
  if edit.geom then m.rel, m.len, m.soffs = edit.geom.rel, edit.geom.len, edit.geom.soffs end
  for k, v in pairs(edit.props or {}) do m[k] = v end
end

--------------------------------------------------------------------------------------------------- cuts
-- A member item was split / partly deleted by the user (razor, S key, ...). REAPER keeps the LEFT piece as the original
-- item (our tags stay on it) and makes new, untagged items for the rest. All pieces keep the anchor.
-- S = applied snapshot of the original, A = its actual state, pieces = untagged candidates on the same track with the same
-- source: { pos, len, soffs, rate }. Returns cut times (sorted, strictly inside S's extent) and the matched pieces.
function C.find_cuts(S, A, pieces)
  if not S or not A then return {}, {} end
  local s0, s1 = S.pos, S.pos + S.len
  if not (approx(A.pos, S.pos) and A.len < S.len - C.EPS) then return {}, {} end
  local anc = C.anchor(S.pos, S.soffs, S.rate)
  local matched, bounds = {}, { A.pos + A.len }
  for _, p in ipairs(pieces) do
    if approx(C.anchor(p.pos, p.soffs, p.rate or S.rate), anc, 1e-4)
       and p.pos >= s0 - C.EPS and p.pos + p.len <= s1 + C.EPS and p.pos >= A.pos + A.len - C.EPS then
      matched[#matched + 1] = p
      bounds[#bounds + 1] = p.pos
      bounds[#bounds + 1] = p.pos + p.len
    end
  end
  if #matched == 0 then return {}, {} end      -- only shortened: a trim, not a cut
  table.sort(bounds)
  local cuts = {}
  for _, t in ipairs(bounds) do
    if t > s0 + C.EPS and t < s1 - C.EPS and (#cuts == 0 or not approx(cuts[#cuts], t)) then cuts[#cuts + 1] = t end
  end
  return cuts, matched
end

-- Untagged alias items that are pieces of a known alias item which was split (same lane, same anchor, inside its old extent).
-- W0 = last known window of the parent, now = its current window. Returns the matching candidates.
function C.split_children(W0, now, cands)
  if not W0 then return {} end
  local anc = C.anchor(W0.pos, W0.offs)
  -- a split keeps the anchor and makes the original shorter; a move keeps the length
  local shrunk = now.len < W0.len - C.EPS and approx(C.anchor(now.pos, now.offs), anc, 1e-4)
  if not shrunk then return {} end
  local out = {}
  for _, c in ipairs(cands) do
    if approx(C.anchor(c.pos, c.offs), anc, 1e-4) and c.pos >= W0.pos - C.EPS
       and c.pos + c.len <= W0.pos + W0.len + C.EPS then out[#out + 1] = c end
  end
  return out
end

--------------------------------------------------------------------------------------------------- defs
function C.copy(t)
  if type(t) ~= "table" then return t end
  local o = {}
  for k, v in pairs(t) do o[k] = C.copy(v) end
  return o
end

function C.member_by_mid(def, mid)
  for i, m in ipairs(def.members) do if m.mid == mid then return m, i end end
end

-- Remove def-local range [a, b) from member mid. The member is kept, shortened or split in two (the right part gets a new mid).
-- Returns the list of mids that now exist for that material.
function C.def_cut(def, mid, a, b)
  local m, i = C.member_by_mid(def, mid)
  if not m then return {} end
  local s, e = m.rel, m.rel + m.len
  if b <= s + C.EPS or a >= e - C.EPS then return { mid } end
  local left  = (a > s + C.EPS) and { s, a } or nil
  local right = (b < e - C.EPS) and { b, e } or nil
  if not left and not right then table.remove(def.members, i); return {} end
  local out = {}
  if left then
    local keep_fout = m.fout
    m.len = left[2] - left[1]; m.fout = 0
    out[#out + 1] = mid
    if right then
      local r = C.copy(m)
      def.next_mid = (def.next_mid or #def.members + 1)
      r.mid = def.next_mid; def.next_mid = def.next_mid + 1
      r.rel, r.len = right[1], right[2] - right[1]
      r.soffs = (m.soffs or 0) + (right[1] - s) * (m.rate or 1)
      r.fin, r.fout = 0, keep_fout
      table.insert(def.members, i + 1, r)
      out[#out + 1] = r.mid
    end
  else
    m.soffs = (m.soffs or 0) + (right[1] - s) * (m.rate or 1)
    m.rel, m.len, m.fin = right[1], right[2] - right[1], 0
    out[#out + 1] = mid
  end
  return out
end

-- recompute def.len as the end of its last member (never shorter than before unless shrink = true)
function C.def_extent(def)
  local e = 0
  for _, m in ipairs(def.members) do e = math.max(e, m.rel + m.len) end
  return e
end

--------------------------------------------------------------------------------------------------- tracks
-- parent index for every track (1-based list of I_FOLDERDEPTH values). parent[i] = index of the folder track or 0.
function C.parents(depths)
  local parent, stack = {}, {}
  for i, d in ipairs(depths) do
    parent[i] = stack[#stack] or 0
    if d > 0 then stack[#stack + 1] = i
    elseif d < 0 then for _ = 1, -d do stack[#stack] = nil end end
  end
  return parent
end

function C.is_desc(parent, i, f)
  local p = parent[i]
  while p and p ~= 0 do
    if p == f then return true end
    p = parent[p]
  end
  return false
end

-- deepest folder that contains all of the given track indices (not the tracks themselves); 0 = none
function C.common_folder(parent, idxs)
  if #idxs == 0 then return 0 end
  local chain = {}
  local p = parent[idxs[1]]
  while p and p ~= 0 do chain[#chain + 1] = p; p = parent[p] end
  for _, f in ipairs(chain) do
    local all = true
    for _, i in ipairs(idxs) do if not C.is_desc(parent, i, f) then all = false; break end end
    if all then return f end
  end
  return 0
end

--------------------------------------------------------------------------------------------------- names / tags
function C.take_name(group_name, defno, main)
  if defno == main then return group_name end
  return group_name .. " #" .. tostring(defno)
end

function C.take_code(name)
  return name and name:match("#(%d+)%s*$")
end

-- "a|b|c" helpers
function C.split_bar(s)
  local out = {}
  if not s or s == "" then return out end
  for p in (s .. "|"):gmatch("([^|]*)|") do out[#out + 1] = p end
  return out
end

function C.list_encode(t)
  local k = {}
  for mid in pairs(t) do k[#k + 1] = tonumber(mid) end
  table.sort(k)
  for i, v in ipairs(k) do k[i] = tostring(v) end
  return table.concat(k, ",")
end

function C.list_decode(s)
  local t = {}
  for v in (s or ""):gmatch("[^,]+") do t[tonumber(v)] = true end
  return t
end

--------------------------------------------------------------------------------------------------- chunks
-- Fresh GUIDs for a copied item chunk. IGUID (item), GUID (takes), FXID (take FX) always get new ones.
-- POOLEDEVTS (pooled MIDI source) is kept when keep_pool is true: linked instances then share MIDI natively.
function C.refresh_guids(chunk, gen, keep_pool)
  local out = {}
  for line in (chunk .. "\n"):gmatch("([^\n]*)\n") do
    local ind, key = line:match("^(%s*)(%u+)%s+{[%x%-]+}%s*$")
    if key == "IGUID" or key == "GUID" or key == "FXID" or (key == "POOLEDEVTS" and not keep_pool) then
      line = ind .. key .. " " .. gen()
    end
    out[#out + 1] = line
  end
  if out[#out] == "" then out[#out] = nil end
  return table.concat(out, "\n")
end

--------------------------------------------------------------------------------------------------- overlaps
-- instances whose windows overlap in time (only meaningful inside one group). list of { a, b } iids.
function C.overlaps(list)
  local s = {}
  for _, x in ipairs(list) do s[#s + 1] = x end
  table.sort(s, function(a, b) return a.pos < b.pos end)
  local out = {}
  for i = 1, #s do
    for j = i + 1, #s do
      if s[j].pos < s[i].pos + s[i].len - C.EPS then out[#out + 1] = { s[i].iid, s[j].iid } else break end
    end
  end
  return out
end

--------------------------------------------------------------------------------------------------- tiny JSON
local function jenc(v, out)
  local t = type(v)
  if t == "nil" then out[#out + 1] = "null"
  elseif t == "boolean" then out[#out + 1] = v and "true" or "false"
  elseif t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then v = 0 end
    out[#out + 1] = (math.type and math.type(v) == "integer") and tostring(v) or string.format("%.14g", v)
  elseif t == "string" then
    out[#out + 1] = '"' .. v:gsub('[%c"\\]', function(c)
      local map = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
      return map[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
  elseif t == "table" then
    local n = #v
    local is_arr = n > 0 or next(v) == nil
    if is_arr then for k in pairs(v) do if type(k) ~= "number" then is_arr = false; break end end end
    if is_arr and next(v) ~= nil then
      out[#out + 1] = "["
      for i = 1, n do if i > 1 then out[#out + 1] = "," end; jenc(v[i], out) end
      out[#out + 1] = "]"
    elseif next(v) == nil then out[#out + 1] = "{}"
    else
      local keys = {}
      for k in pairs(v) do keys[#keys + 1] = tostring(k) end
      table.sort(keys)
      out[#out + 1] = "{"
      for i, k in ipairs(keys) do
        if i > 1 then out[#out + 1] = "," end
        jenc(k, out); out[#out + 1] = ":"
        local val = v[k]; if val == nil then val = v[tonumber(k)] end
        jenc(val, out)
      end
      out[#out + 1] = "}"
    end
  else error("json: cannot encode " .. t) end
end

function C.json_encode(v) local out = {}; jenc(v, out); return table.concat(out) end

function C.json_decode(s)
  local i = 1
  local function ws() i = s:find("[^ \t\r\n]", i) or #s + 1 end
  local val
  local function str()
    local buf = {}
    i = i + 1
    while true do
      local c = s:sub(i, i)
      if c == "" then error("json: open string") end
      if c == '"' then i = i + 1; break end
      if c == "\\" then
        local e = s:sub(i + 1, i + 1)
        local map = { n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f" }
        if e == "u" then buf[#buf + 1] = utf8 and utf8.char(tonumber(s:sub(i + 2, i + 5), 16)) or "?"; i = i + 6
        else buf[#buf + 1] = map[e] or e; i = i + 2 end
      else buf[#buf + 1] = c; i = i + 1 end
    end
    return table.concat(buf)
  end
  function val()
    ws()
    local c = s:sub(i, i)
    if c == "{" then
      local o = {}; i = i + 1; ws()
      if s:sub(i, i) == "}" then i = i + 1; return o end
      while true do
        ws(); local k = str(); ws()
        assert(s:sub(i, i) == ":", "json: ':' expected"); i = i + 1
        o[k] = val(); ws()
        local d = s:sub(i, i); i = i + 1
        if d == "}" then return o end
        assert(d == ",", "json: ',' expected")
      end
    elseif c == "[" then
      local a = {}; i = i + 1; ws()
      if s:sub(i, i) == "]" then i = i + 1; return a end
      while true do
        a[#a + 1] = val(); ws()
        local d = s:sub(i, i); i = i + 1
        if d == "]" then return a end
        assert(d == ",", "json: ',' expected")
      end
    elseif c == '"' then return str()
    elseif s:sub(i, i + 3) == "true" then i = i + 4; return true
    elseif s:sub(i, i + 4) == "false" then i = i + 5; return false
    elseif s:sub(i, i + 3) == "null" then i = i + 4; return nil
    else
      local n = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
      assert(n and n ~= "", "json: bad value at " .. i)
      i = i + #n
      return tonumber(n)
    end
  end
  local ok, r = pcall(val)
  if not ok then return nil, r end
  return r
end

return C

end
__preload["ATReaper"] = function(...)
-- ATReaper.lua
-- Every reaper.* call of AliasTrack lives here. scan() turns the project into plain tables; the write functions change it.
-- Identity never depends on names: tracks and items are recognised by P_EXT tags (see TAG).

local r = reaper
local C = require("ATCore")

local RA = {}

RA.TAG = {
  lane  = "P_EXT:AT_lane",    -- track: "<gid>|linked" or "<gid>|unique"
  group = "P_EXT:AT_group",   -- linked lane track: the group (JSON: name, colour, folder, defs, counters)
  inst  = "P_EXT:AT_i",       -- alias item: "<gid>|<iid>|<def>"
  win   = "P_EXT:AT_w",       -- alias item: last window "pos|len|offs"
  has   = "P_EXT:AT_h",       -- alias item: mids materialised for this instance "1,2,5"
  mem   = "P_EXT:AT_m",       -- member item: "<gid>|<iid>|<mid>"
  app   = "P_EXT:AT_a",       -- member item: applied snapshot (C.snap_encode)
}

local function tstr(tr, k) local ok, v = r.GetSetMediaTrackInfo_String(tr, k, "", false); return ok and v or "" end
local function istr(it, k) local ok, v = r.GetSetMediaItemInfo_String(it, k, "", false); return ok and v or "" end
function RA.track_tag(tr, k) return tstr(tr, RA.TAG[k]) end
function RA.item_tag(it, k) return istr(it, RA.TAG[k]) end
function RA.set_track_tag(tr, k, v) r.GetSetMediaTrackInfo_String(tr, RA.TAG[k], v or "", true) end
function RA.set_item_tag(it, k, v) r.GetSetMediaItemInfo_String(it, RA.TAG[k], v or "", true) end

function RA.gen_guid() return r.genGuid("") end

---------------------------------------------------------------------------------------------------------- scan
-- W = { tracks = {T...}, parent = {...}, by_guid = {guid -> T}, items = {I...} }
function RA.scan()
  local W = { tracks = {}, by_guid = {}, items = {} }
  local depths = {}
  for i = 0, r.CountTracks(0) - 1 do
    local tr = r.GetTrack(0, i)
    local T = {
      ptr = tr, i = i + 1, guid = r.GetTrackGUID(tr), name = tstr(tr, "P_NAME"),
      depth = math.floor(r.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH") + 0.5),
      lane = tstr(tr, RA.TAG.lane), items = {},
    }
    if T.lane ~= "" then T.group = tstr(tr, RA.TAG.group) end
    W.tracks[#W.tracks + 1] = T
    W.by_guid[T.guid] = T
    depths[#depths + 1] = T.depth
    for j = 0, r.CountTrackMediaItems(tr) - 1 do
      local it = r.GetTrackMediaItem(tr, j)
      local I = RA.read_item(it, T)
      T.items[#T.items + 1] = I
      W.items[#W.items + 1] = I
    end
  end
  W.parent = C.parents(depths)
  return W
end

function RA.read_item(it, T)
  local gv = r.GetMediaItemInfo_Value
  local I = {
    ptr = it, T = T,
    pos = gv(it, "D_POSITION"), len = gv(it, "D_LENGTH"),
    vol = gv(it, "D_VOL"), mute = gv(it, "B_MUTE"),
    fin = gv(it, "D_FADEINLEN"), fout = gv(it, "D_FADEOUTLEN"),
    sel = gv(it, "B_UISEL") ~= 0,
    tag_i = istr(it, RA.TAG.inst), tag_m = istr(it, RA.TAG.mem),
  }
  if I.tag_i ~= "" then I.tag_w = istr(it, RA.TAG.win); I.tag_h = istr(it, RA.TAG.has) end
  if I.tag_m ~= "" then I.tag_a = istr(it, RA.TAG.app) end
  local tk = r.GetActiveTake(it)
  I.soffs, I.rate, I.pitch, I.tvol = 0, 1, 0, 1
  if tk then
    local tv = r.GetMediaItemTakeInfo_Value
    I.take = true
    I.midi = r.TakeIsMIDI(tk) and true or false
    I.soffs, I.rate, I.pitch, I.tvol = tv(tk, "D_STARTOFFS"), tv(tk, "D_PLAYRATE"), tv(tk, "D_PITCH"), tv(tk, "D_VOL")
    local _, nm = r.GetSetMediaItemTakeInfo_String(tk, "P_NAME", "", false)
    I.tname = nm or ""
    local src = r.GetMediaItemTake_Source(tk)
    I.file = src and r.GetMediaSourceFileName(src, "") or ""
  end
  return I
end

function RA.snap(I)
  return { pos = I.pos, len = I.len, soffs = I.soffs, vol = I.vol, mute = I.mute, rate = I.rate, pitch = I.pitch,
           tvol = I.tvol, fin = I.fin, fout = I.fout, track = I.T.guid }
end

---------------------------------------------------------------------------------------------------------- undo
-- mode "silent": no undo points for syncs (your own action is the undo step; the result is derived again after undo)
-- mode "steps":  every sync that changes something is its own undo step "AliasTrack: sync"
RA.SYNC_LABEL = "AliasTrack: sync"
local W_open, W_mode, W_changed = false, "silent", false

function RA.begin_writes(mode) W_open, W_mode, W_changed = true, mode or "silent", false end
function RA.touch()
  if W_open and not W_changed then
    W_changed = true
    r.PreventUIRefresh(1)
    if W_mode == "steps" then r.Undo_BeginBlock2(0) end
  end
end
function RA.end_writes()
  if W_open and W_changed then
    if W_mode == "steps" then r.Undo_EndBlock2(0, RA.SYNC_LABEL, -1)
    elseif r.MarkProjectDirty then r.MarkProjectDirty(0) end
    r.PreventUIRefresh(-1)
    r.UpdateArrange()
  end
  local changed = W_changed
  W_open, W_changed = false, false
  return changed
end

-- explicit user commands always get a real undo point
function RA.with_undo(label, fn)
  r.Undo_BeginBlock2(0)
  r.PreventUIRefresh(1)
  local ok, err = pcall(fn)
  r.PreventUIRefresh(-1)
  r.Undo_EndBlock2(0, label, -1)
  r.UpdateArrange()
  if not ok then error(err, 0) end
end

function RA.redo_label() local s = r.Undo_CanRedo2 and r.Undo_CanRedo2(0); return s end
function RA.change_count() return r.GetProjectStateChangeCount(0) end
function RA.mouse_down()
  if r.JS_Mouse_GetState then return (r.JS_Mouse_GetState(1) or 0) & 1 == 1 end
  return false
end

---------------------------------------------------------------------------------------------------------- tracks
function RA.insert_track(index0, name, color)
  r.InsertTrackAtIndex(index0, true)
  local tr = r.GetTrack(0, index0)
  r.GetSetMediaTrackInfo_String(tr, "P_NAME", name, true)
  if color and color ~= 0 then r.SetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR", color | 0x1000000) end
  return tr, r.GetTrackGUID(tr)
end
function RA.delete_track(tr) r.DeleteTrack(tr) end
function RA.set_depth(tr, d) r.SetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH", d) end
function RA.track_index0(tr) return math.floor(r.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER") + 0.5) - 1 end
function RA.track_depth(tr) return math.floor(r.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH") + 0.5) end

---------------------------------------------------------------------------------------------------------- items
function RA.item_chunk(it) local ok, c = r.GetItemStateChunk(it, "", false); return ok and c or "" end

-- the alias item: an empty MIDI item, so REAPER itself keeps its take start offset (= window offset) through
-- trims, splits and copies. Looping is switched off so extending it does not repeat anything.
function RA.create_alias(lane, pos, len, offs, name, color)
  local it = r.CreateNewMIDIItemInProj(lane, pos, pos + len, false)
  r.SetMediaItemInfo_Value(it, "B_LOOPSRC", 0)
  local tk = r.GetActiveTake(it)
  if tk then
    r.SetMediaItemTakeInfo_Value(tk, "D_STARTOFFS", offs or 0)
    r.GetSetMediaItemTakeInfo_String(tk, "P_NAME", name or "", true)
  end
  if color and color ~= 0 then r.SetMediaItemInfo_Value(it, "I_CUSTOMCOLOR", color | 0x1000000) end
  return it
end

function RA.style_alias(it, name, color)
  local tk = r.GetActiveTake(it)
  if tk then
    local _, cur = r.GetSetMediaItemTakeInfo_String(tk, "P_NAME", "", false)
    if cur ~= name then r.GetSetMediaItemTakeInfo_String(tk, "P_NAME", name, true) end
  end
  if color and color ~= 0 then
    local want = color | 0x1000000
    if r.GetMediaItemInfo_Value(it, "I_CUSTOMCOLOR") ~= want then r.SetMediaItemInfo_Value(it, "I_CUSTOMCOLOR", want) end
  end
end

function RA.set_window(it, w)
  r.SetMediaItemInfo_Value(it, "D_POSITION", w.pos)
  r.SetMediaItemInfo_Value(it, "D_LENGTH", w.len)
  local tk = r.GetActiveTake(it)
  if tk then r.SetMediaItemTakeInfo_Value(tk, "D_STARTOFFS", w.offs) end
end

function RA.split(it, t) return r.SplitMediaItem(it, t) end
function RA.delete_item(it) r.DeleteTrackMediaItem(r.GetMediaItem_Track(it), it) end
function RA.move_to_track(it, tr) r.MoveMediaItemToTrack(it, tr) end

-- write a wanted snapshot onto an item; returns what REAPER now reports (the new "applied" snapshot)
function RA.write_member(it, N, track_ptr)
  local sv = r.SetMediaItemInfo_Value
  if track_ptr and r.GetMediaItem_Track(it) ~= track_ptr then r.MoveMediaItemToTrack(it, track_ptr) end
  sv(it, "D_POSITION", N.pos); sv(it, "D_LENGTH", N.len)
  sv(it, "D_VOL", N.vol); sv(it, "B_MUTE", N.mute)
  sv(it, "D_FADEINLEN", N.fin); sv(it, "D_FADEOUTLEN", N.fout)
  local tk = r.GetActiveTake(it)
  if tk then
    local st = r.SetMediaItemTakeInfo_Value
    st(tk, "D_PLAYRATE", N.rate); st(tk, "D_STARTOFFS", N.soffs); st(tk, "D_PITCH", N.pitch); st(tk, "D_VOL", N.tvol)
  end
  local T = { guid = r.GetTrackGUID(r.GetMediaItem_Track(it)) }
  local A = RA.snap(RA.read_item(it, T))
  A.clipL, A.clipR = N.clipL, N.clipR
  return A
end

function RA.create_member(track_ptr, chunk, N, keep_pool)
  local it = r.AddMediaItemToTrack(track_ptr)
  if chunk and chunk ~= "" then r.SetItemStateChunk(it, C.refresh_guids(chunk, RA.gen_guid, keep_pool), false) end
  return it, RA.write_member(it, N)
end

function RA.select_only(items)
  r.SelectAllMediaItems(0, false)
  for _, it in ipairs(items) do r.SetMediaItemSelected(it, true) end
  r.UpdateArrange()
end

return RA

end
__preload["ATApp"] = function(...)
-- ATApp.lua
-- State, settings, the debounced tick and the sync engine. Reads the project through ATReaper, decides with ATCore.
--
-- One sync = up to 4 passes of:  scan -> build model -> (cuts? split aliases, rescan) -> reconcile
--   cuts       a member was split by the user (razor, S, ...): split its alias at the same time, then rescan
--   reconcile  new alias items (split pieces / copies / lane changes) -> member edits -> materialise -> tags -> group data

local r = reaper
local C = require("ATCore")
local RA = require("ATReaper")

local App = {}
App.__index = App

local EXT = "AliasTrack"
local DEBOUNCE = 0.3

App.DEFAULTS = {
  live = true,               -- follow the project
  undo_mode = "silent",      -- "silent" | "steps"
  propagate = true,          -- member edits go into the group (and so to every linked alias) automatically
  delete_with_alias = true,  -- deleting an alias item deletes its members (off: they are released as plain items)
  clipfade_ms = 5,           -- fade on edges cut by an alias window
  keep_pool = true,          -- MIDI members of linked aliases stay pooled (note edits are shared natively)
  copies_lane = false,       -- create the COPIES lane together with the group
}

local PALETTE = { { 0x85, 0x42, 0xFA }, { 0x3F, 0xA7, 0xD6 }, { 0x59, 0xCD, 0x90 }, { 0xFA, 0xC0, 0x5E },
                  { 0xF7, 0x9D, 0x84 }, { 0xEE, 0x63, 0x52 }, { 0xB3, 0x8C, 0xF8 }, { 0x5E, 0xD1, 0xC4 } }

---------------------------------------------------------------------------------------------------------- settings
function App.new()
  local self = setmetatable({}, App)
  self.cfg = {}
  for k, v in pairs(App.DEFAULTS) do self.cfg[k] = v end
  local raw = r.GetExtState(EXT, "cfg")
  for k, v in raw:gmatch("([%w_]+)=([^;]*)") do
    local d = App.DEFAULTS[k]
    if type(d) == "boolean" then self.cfg[k] = (v == "1")
    elseif type(d) == "number" then self.cfg[k] = tonumber(v) or d
    elseif d ~= nil then self.cfg[k] = v end
  end
  self.view = {}             -- groups as shown in the window
  self.requests = {}         -- ["gid|iid"] = "apply" | "revert"
  self.push = {}             -- [gid] = { [def] = { [mid] = source iid } }
  self.pending = true
  self.changed_at = -1e9
  self.seen = -1
  self.stats = {}
  return self
end

function App:save()
  local out = {}
  for k in pairs(App.DEFAULTS) do
    local v = self.cfg[k]
    if type(v) == "boolean" then v = v and "1" or "0" end
    out[#out + 1] = k .. "=" .. tostring(v)
  end
  table.sort(out)
  r.SetExtState(EXT, "cfg", table.concat(out, ";"), true)
end

function App:set(k, v) self.cfg[k] = v; self:save(); self.pending = true; self.changed_at = -1e9 end

---------------------------------------------------------------------------------------------------------- tick
function App:tick()
  local cc = RA.change_count()
  local now = r.time_precise()
  if cc ~= self.seen then self.seen = cc; self.changed_at = now; self.pending = true end
  if not self.pending or now - self.changed_at < DEBOUNCE then return end
  if not self.cfg.live then self.pending = false; self:sync(true); return end   -- frozen: refresh the view only
  if RA.mouse_down() then return end                                           -- still dragging
  if self.cfg.undo_mode == "steps" and RA.redo_label() == RA.SYNC_LABEL then
    -- you just undid one of our sync steps: stay out of the way until you do something else (or undo further)
    self.paused = true; self.pending = false
    return
  end
  self.paused = false
  self.pending = false
  self:sync()
  self.seen = RA.change_count()
end

function App:refresh() self.pending = true; self.changed_at = -1e9 end

---------------------------------------------------------------------------------------------------------- model
-- "gid|iid|x": iids are strings everywhere (tags, new ids, the view), mids are numbers
local function parse_bar(s)
  local p = C.split_bar(s)
  local iid = p[2] and p[2]:match("^%d+$") and p[2] or nil
  return p[1], iid, p[3]
end

local function track_of(W, guid) return W.by_guid[guid] end

-- build the model of every group from a scan. No writes.
function App:build(W)
  local M = { W = W, groups = {}, order = {}, stray = {}, release_lanes = {}, free = {} }
  local lanes_unique = {}
  for _, T in ipairs(W.tracks) do
    if T.lane ~= "" then
      local gid, _, mode = T.lane:match("^([^|]+)(|)(%a+)$")
      if gid and mode == "linked" then
        if M.groups[gid] then M.release_lanes[#M.release_lanes + 1] = T       -- a duplicated lane track
        else
          local data = C.json_decode(T.group or "")
          if type(data) == "table" and data.defs and data.main then
            M.groups[gid] = { gid = gid, data = data, raw = T.group, linked = T, inst = {}, order = {},
                              untagged = { linked = {}, unique = {} }, orphans = {}, dups = {}, foreign = {} }
            M.order[#M.order + 1] = gid
          else M.release_lanes[#M.release_lanes + 1] = T end
        end
      elseif gid and mode == "unique" then lanes_unique[#lanes_unique + 1] = { T = T, gid = gid }
      else M.release_lanes[#M.release_lanes + 1] = T end
    end
  end
  for _, u in ipairs(lanes_unique) do
    local G = M.groups[u.gid]
    if G and not G.unique then G.unique = u.T else M.release_lanes[#M.release_lanes + 1] = u.T end
  end

  for _, gid in ipairs(M.order) do
    local G = M.groups[gid]
    G.F = W.parent[G.linked.i] or 0
    local function in_folder(guid)
      local T = track_of(W, guid)
      if not T then return false end
      if G.F == 0 then return true end
      return C.is_desc(W.parent, T.i, G.F)
    end
    G.in_folder = in_folder
    for _, lane in ipairs({ { T = G.linked, mode = "linked" }, { T = G.unique, mode = "unique" } }) do
      if lane.T then
        for _, I in ipairs(lane.T.items) do
          if not (I.take and I.midi) then G.foreign[#G.foreign + 1] = I
          else
            local g, iid, def = parse_bar(I.tag_i)
            if g == gid and iid and not G.inst[iid] then
              local w0 = C.split_bar(I.tag_w)
              G.inst[iid] = {
                iid = iid, def = def, item = I, lane = lane.mode, members = {}, mixed = {},
                W = { pos = I.pos, len = I.len, offs = I.soffs },
                W0 = (#w0 >= 3) and { pos = tonumber(w0[1]), len = tonumber(w0[2]), offs = tonumber(w0[3]) } or nil,
                has = C.list_decode(I.tag_h), known = true,
              }
              G.order[#G.order + 1] = iid
            else
              local L = G.untagged[lane.mode]
              L[#L + 1] = I
            end
          end
        end
      end
    end
  end

  -- members and free items
  for _, I in ipairs(W.items) do
    if I.T.lane == "" then
      if I.tag_m ~= "" then
        local g, iid, mid = parse_bar(I.tag_m)
        mid = tonumber(mid)
        local G = M.groups[g]
        if not G or not iid or not mid then M.stray[#M.stray + 1] = I
        else
          local inst = G.inst[iid]
          if not inst then G.orphans[#G.orphans + 1] = I
          elseif inst.members[mid] then G.dups[#G.dups + 1] = I                          -- tag copied by something: not ours
          else inst.members[mid] = { I = I, S = C.snap_decode(I.tag_a) } end
        end
      else
        local L = M.free[I.T.guid] or {}
        L[#L + 1] = I
        M.free[I.T.guid] = L
      end
    end
  end
  for _, G in pairs(M.groups) do
    for _, I in ipairs(G.dups) do local L = M.free[I.T.guid] or {}; L[#L + 1] = I; M.free[I.T.guid] = L end
  end
  return M
end

local function same_source(I, m)
  if (I.midi or false) ~= (m.midi or false) then return false end
  if m.midi then return true end
  return (I.file or "") == (m.file or "")
end

-- an untagged item that is exactly the wanted piece N of def member m (REAPER split it, or it was copied with the alias)
local function find_piece(M, N, m)
  for _, I in ipairs(M.free[N.track] or {}) do
    if not I.used and same_source(I, m) and C.approx(I.pos, N.pos, 1e-4) and C.approx(I.len, N.len, 1e-4)
       and C.approx(I.soffs, N.soffs, 1e-4) then return I end
  end
end

---------------------------------------------------------------------------------------------------------- cuts
-- a member split by the user -> split its alias item at the same time(s). Returns true when something was split.
function App:do_cuts(M)
  local did = false
  for _, gid in ipairs(M.order) do
    local G = M.groups[gid]
    local defs = G.data.defs
    for _, iid in ipairs(G.order) do
      local inst = G.inst[iid]
      local def = defs[inst.def]
      local times = {}
      for mid, mem in pairs(inst.members) do
        local m = def and C.member_by_mid(def, mid)
        if m and mem.S then
          local pieces = {}
          for _, I in ipairs(M.free[mem.I.T.guid] or {}) do
            if same_source(I, m) then pieces[#pieces + 1] = { pos = I.pos, len = I.len, soffs = I.soffs, rate = I.rate } end
          end
          local cuts = C.find_cuts(mem.S, RA.snap(mem.I), pieces)
          for _, t in ipairs(cuts) do
            if t > inst.W.pos + C.EPS and t < inst.W.pos + inst.W.len - C.EPS then
              local dup = false
              for _, x in ipairs(times) do if C.approx(x, t) then dup = true end end
              if not dup then times[#times + 1] = t end
            end
          end
        end
      end
      table.sort(times, function(a, b) return a > b end)       -- right to left: the original item stays the left piece
      for _, t in ipairs(times) do
        RA.touch()
        if RA.split(inst.item.ptr, t) then did = true; self.stats.cuts = (self.stats.cuts or 0) + 1 end
      end
    end
  end
  return did
end

---------------------------------------------------------------------------------------------------------- reconcile
local function new_def_id(data)
  local id = tostring(data.next_def or 2)
  data.next_def = tonumber(id) + 1
  return id
end

local function new_iid(data)
  local id = tostring(data.next_iid or 2)
  data.next_iid = tonumber(id) + 1
  return id
end

function App:fork(G, src)
  local data = G.data
  local id = new_def_id(data)
  data.defs[id] = C.copy(data.defs[src] or data.defs[data.main])
  self.stats.forks = (self.stats.forks or 0) + 1
  return id
end

function App:resolve_instances(G, M)
  local data = G.data
  -- 1. split pieces of known aliases (same lane, same anchor, inside the old extent)
  for _, iid in ipairs({ table.unpack(G.order) }) do
    local K = G.inst[iid]
    if K.known then
      local L = G.untagged[K.lane]
      local cands = {}
      for _, I in ipairs(L) do cands[#cands + 1] = { pos = I.pos, len = I.len, offs = I.soffs, I = I } end
      for _, c in ipairs(C.split_children(K.W0, K.W, cands)) do
        for k, I in ipairs(L) do if I == c.I then table.remove(L, k); break end end
        local nid = new_iid(data)
        G.inst[nid] = { iid = nid, def = K.def, item = c.I, lane = K.lane, members = {}, mixed = {},
                        W = { pos = c.pos, len = c.len, offs = c.offs }, has = {}, parent = K, split = true }
        G.order[#G.order + 1] = nid
      end
    end
  end
  -- 2. copies (anything else new on a lane)
  for _, mode in ipairs({ "linked", "unique" }) do
    for _, I in ipairs(G.untagged[mode]) do
      local def
      if mode == "linked" then def = data.main
      else
        local code = C.take_code(I.tname)
        def = self:fork(G, (code and data.defs[code]) and code or data.main)
      end
      local nid = new_iid(data)
      G.inst[nid] = { iid = nid, def = def, item = I, lane = mode, members = {}, mixed = {},
                      W = { pos = I.pos, len = I.len, offs = I.soffs }, has = {}, copy = true }
      G.order[#G.order + 1] = nid
      self.stats.copies = (self.stats.copies or 0) + 1
    end
  end
  -- 3. lane changes of known aliases: moved to COPIES = make unique, moved to ALIAS = link again
  for _, iid in ipairs(G.order) do
    local K = G.inst[iid]
    if K.known then
      if K.lane == "linked" and K.def ~= data.main then K.def = data.main; K.relinked = true
      elseif K.lane == "unique" and K.def == data.main then K.def = self:fork(G, data.main) end
    end
    if not data.defs[K.def] then K.def = data.main end
  end
  -- 4. members of a split alias: hand whole ones over to the piece they now lie in, split spanning ones at the
  --    piece boundaries (natively, so the items stay the user's items), and remember what each piece already had
  local by_parent = {}
  for _, iid in ipairs(G.order) do
    local X = G.inst[iid]
    if X.split then
      by_parent[X.parent] = by_parent[X.parent] or {}
      table.insert(by_parent[X.parent], X)
    end
  end
  for P, kids in pairs(by_parent) do
    local bounds = {}
    for _, X in ipairs(kids) do bounds[#bounds + 1] = X.W.pos; bounds[#bounds + 1] = X.W.pos + X.W.len end
    for mid in pairs(P.has) do
      for _, X in ipairs(kids) do X.has[mid] = true end
      local pm = P.members[mid]
      if pm then
        local s, e = pm.I.pos, pm.I.pos + pm.I.len
        local cuts = {}
        for _, t in ipairs(bounds) do
          if t > s + C.EPS and t < e - C.EPS then
            local dup = false
            for _, x in ipairs(cuts) do if C.approx(x, t) then dup = true end end
            if not dup then cuts[#cuts + 1] = t end
          end
        end
        table.sort(cuts, function(a, b) return a > b end)
        local L = M.free[pm.I.T.guid] or {}
        M.free[pm.I.T.guid] = L
        for _, t in ipairs(cuts) do
          RA.touch()
          local rgt = RA.split(pm.I.ptr, t)
          if rgt then L[#L + 1] = RA.read_item(rgt, pm.I.T) end
        end
        if #cuts > 0 then pm.I = RA.read_item(pm.I.ptr, pm.I.T) end
        -- the (left) original now lies wholly in the parent or wholly in one piece
        local ps, pe = pm.I.pos, pm.I.pos + pm.I.len
        local pw = P.W
        if not (ps >= pw.pos - C.EPS and pe <= pw.pos + pw.len + C.EPS) then
          P.members[mid] = nil
          pm.I.tag_m = ""
          L[#L + 1] = pm.I                  -- adopted by the piece it lies in
        end
      end
    end
  end
end

function App:classify_edits(G, M)
  local data = G.data
  local clipfade = (self.cfg.clipfade_ms or 0) / 1000
  local edited = {}            -- [def][mid] = true: first edit wins
  for _, iid in ipairs(G.order) do
    local inst = G.inst[iid]
    local def = data.defs[inst.def]
    if inst.known and def and not inst.relinked then
      for mid, mem in pairs(inst.members) do
        local m = C.member_by_mid(def, mid)
        if m then
          local N = C.visible(m, inst.W, clipfade)
          local res = C.classify(RA.snap(mem.I), mem.S, N, { in_folder = G.in_folder, window = inst.W, def_member = m })
          if res.kind == "mixed" then inst.mixed[mid] = res.reason
          elseif res.kind == "edit" then
            if not self.cfg.propagate then inst.mixed[mid] = "edited"
            else
              edited[inst.def] = edited[inst.def] or {}
              if not edited[inst.def][mid] then
                edited[inst.def][mid] = true
                C.apply_edit(m, res.edit)
                self.stats.edits = (self.stats.edits or 0) + 1
              end
            end
          end
        end
      end
    end
  end
  -- members this alias had that are gone and not found as pieces anywhere = deleted by you
  for _, iid in ipairs(G.order) do
    local inst = G.inst[iid]
    local def = data.defs[inst.def]
    if def and not inst.relinked then
      for _, m in ipairs(def.members) do
        if inst.has[m.mid] and not inst.members[m.mid] and not inst.mixed[m.mid] then
          local N = C.visible(m, inst.W, clipfade)
          if N and track_of(M.W, N.track) and not find_piece(M, N, m) then inst.mixed[m.mid] = "missing" end
        end
      end
    end
  end
end

-- explicit Apply / Revert on a mixed alias
function App:handle_requests(G, M)
  local data = G.data
  for _, iid in ipairs(G.order) do
    local inst = G.inst[iid]
    local req = self.requests[G.gid .. "|" .. iid]
    local def = data.defs[inst.def]
    if req and def then
      for mid, reason in pairs(inst.mixed) do
        local m = C.member_by_mid(def, mid)
        local mem = inst.members[mid]
        if req == "revert" then
          if reason == "missing" then inst.has[mid] = nil end
          inst.mixed[mid] = nil
        elseif m then
          if reason == "missing" then
            local N = C.visible(m, inst.W, 0)
            if N then C.def_cut(def, mid, N.a, N.b) end
          elseif reason == "outside_folder" then
            C.def_cut(def, mid, -math.huge, math.huge)
            if mem then RA.touch(); RA.set_item_tag(mem.I.ptr, "mem", ""); RA.set_item_tag(mem.I.ptr, "app", ""); inst.members[mid] = nil end
          elseif mem then
            local A = RA.snap(mem.I)
            if reason == "outside_window" then
              local w = inst.W
              local p0 = math.min(w.pos, A.pos)
              local p1 = math.max(w.pos + w.len, A.pos + A.len)
              inst.W = { pos = p0, len = p1 - p0, offs = w.offs - (w.pos - p0) }
              RA.touch(); RA.set_window(inst.item.ptr, inst.W)
            end
            m.track = A.track
            m.rel, m.len, m.soffs = A.pos - inst.W.pos + inst.W.offs, A.len, A.soffs
            for _, k in ipairs(C.PROPS) do m[k] = A[k] end
            m.fin, m.fout = A.fin, A.fout
          end
          inst.mixed[mid] = nil
        end
      end
      self.requests[G.gid .. "|" .. iid] = nil
    end
  end
end

function App:materialize(G, M)
  local data = G.data
  local W = M.W
  local clipfade = (self.cfg.clipfade_ms or 0) / 1000
  local push = self.push[G.gid] or {}
  local leftovers = {}
  -- items whose member is no longer visible (window moved, def cut ...) become candidates for another member first
  for _, iid in ipairs(G.order) do
    local inst = G.inst[iid]
    local def = data.defs[inst.def]
    for mid, mem in pairs(inst.members) do
      local m = def and C.member_by_mid(def, mid)
      if not inst.mixed[mid] and not (m and C.visible(m, inst.W, clipfade)) then
        inst.members[mid] = nil
        local L = M.free[mem.I.T.guid] or {}
        M.free[mem.I.T.guid] = L
        L[#L + 1] = mem.I
        leftovers[#leftovers + 1] = mem.I
      end
    end
  end
  for _, iid in ipairs(G.order) do
    local inst = G.inst[iid]
    local def = data.defs[inst.def]
    local has_new, wanted, present, missing = {}, 0, 0, 0
    if def then
      for _, m in ipairs(def.members) do
        local N = C.visible(m, inst.W, clipfade)
        local mem = inst.members[m.mid]
        local T = N and track_of(W, N.track)
        if N and not T then inst.mixed[m.mid] = "track_gone" end
        if inst.mixed[m.mid] then
          has_new[m.mid] = true
          if inst.mixed[m.mid] == "missing" then missing = missing + 1 end
          if N then wanted = wanted + 1 end
        elseif N then
          wanted = wanted + 1
          local src_iid = push[inst.def] and push[inst.def][m.mid]
          local rebuild = false
          if mem and src_iid and src_iid ~= iid then                       -- chunk-level edit pushed from another alias
            RA.touch(); RA.delete_item(mem.I.ptr); mem = nil; rebuild = true
          end
          if mem then
            local A = RA.snap(mem.I)
            if not C.snap_eq(A, N) then
              RA.touch()
              local S = RA.write_member(mem.I.ptr, N, T.ptr)
              RA.set_item_tag(mem.I.ptr, "app", C.snap_encode(S))
              self.stats.updated = (self.stats.updated or 0) + 1
            else
              A.clipL, A.clipR = N.clipL, N.clipR
              local enc = C.snap_encode(A)
              if enc ~= mem.I.tag_a then RA.touch(); RA.set_item_tag(mem.I.ptr, "app", enc) end
            end
            present = present + 1
            has_new[m.mid] = true
          else
            -- adopt an untagged item that is exactly this piece (REAPER split it, or you copied alias + members together)
            local adopted = find_piece(M, N, m)
            if adopted then
              adopted.used = true
              RA.touch()
              RA.set_item_tag(adopted.ptr, "mem", G.gid .. "|" .. iid .. "|" .. m.mid)
              local S = RA.write_member(adopted.ptr, N, T.ptr)
              RA.set_item_tag(adopted.ptr, "app", C.snap_encode(S))
              present = present + 1
              has_new[m.mid] = true
              self.stats.adopted = (self.stats.adopted or 0) + 1
            elseif inst.has[m.mid] and not rebuild then
              inst.mixed[m.mid] = "missing"; has_new[m.mid] = true; missing = missing + 1
            else
              RA.touch()
              local it, S = RA.create_member(T.ptr, m.chunk, N, self.cfg.keep_pool and inst.lane == "linked")
              RA.set_item_tag(it, "mem", G.gid .. "|" .. iid .. "|" .. m.mid)
              RA.set_item_tag(it, "app", C.snap_encode(S))
              present = present + 1
              has_new[m.mid] = true
              self.stats.created = (self.stats.created or 0) + 1
            end
          end
        end
      end
    end
    local others = 0
    for _, why in pairs(inst.mixed) do if why ~= "missing" and why ~= "track_gone" then others = others + 1 end end
    inst.count = present + others
    -- a split piece whose content was deleted everywhere (razor through all tracks): remove the piece itself
    if inst.split and wanted > 0 and present == 0 and missing == wanted then
      RA.touch(); RA.delete_item(inst.item.ptr)
      inst.removed = true
    else
      local tag_i = G.gid .. "|" .. iid .. "|" .. inst.def
      local tag_w = string.format("%.10g|%.10g|%.10g", inst.W.pos, inst.W.len, inst.W.offs)
      local tag_h = C.list_encode(has_new)
      local I = inst.item
      if I.tag_i ~= tag_i then RA.touch(); RA.set_item_tag(I.ptr, "inst", tag_i) end
      if I.tag_w ~= tag_w then RA.touch(); RA.set_item_tag(I.ptr, "win", tag_w) end
      if (I.tag_h or "") ~= tag_h then RA.touch(); RA.set_item_tag(I.ptr, "has", tag_h) end
      local want_name = C.take_name(data.name, inst.def, data.main)
      if I.tname ~= want_name or not inst.known then RA.touch(); RA.style_alias(I.ptr, want_name, data.color) end
    end
  end
  for _, I in ipairs(leftovers) do
    if not I.used then RA.touch(); RA.delete_item(I.ptr); self.stats.deleted = (self.stats.deleted or 0) + 1 end
  end
  self.push[G.gid] = nil
end

function App:finish_group(G, M)
  local data = G.data
  -- members whose alias item is gone
  for _, I in ipairs(G.orphans) do
    RA.touch()
    if self.cfg.delete_with_alias then RA.delete_item(I.ptr); self.stats.deleted = (self.stats.deleted or 0) + 1
    else RA.set_item_tag(I.ptr, "mem", ""); RA.set_item_tag(I.ptr, "app", "") end
  end
  for _, I in ipairs(G.dups) do
    if I.tag_m ~= "" and not I.used then RA.touch(); RA.set_item_tag(I.ptr, "mem", ""); RA.set_item_tag(I.ptr, "app", "") end
  end
  -- drop defs nobody uses any more
  local used = { [data.main] = true }
  for _, iid in ipairs(G.order) do if not G.inst[iid].removed then used[G.inst[iid].def] = true end end
  for id in pairs(data.defs) do if not used[id] then data.defs[id] = nil end end
  for _, def in pairs(data.defs) do def.len = C.def_extent(def) end
  local enc = C.json_encode(data)
  if enc ~= G.raw then RA.touch(); RA.set_track_tag(G.linked.ptr, "group", enc) end
end

function App:reconcile(M)
  for _, gid in ipairs(M.order) do
    local G = M.groups[gid]
    self:resolve_instances(G, M)
    self:classify_edits(G, M)
    self:handle_requests(G, M)
    self:materialize(G, M)
    self:finish_group(G, M)
  end
  for _, I in ipairs(M.stray) do RA.touch(); RA.set_item_tag(I.ptr, "mem", ""); RA.set_item_tag(I.ptr, "app", "") end
  for _, T in ipairs(M.release_lanes) do
    RA.touch(); RA.set_track_tag(T.ptr, "lane", ""); RA.set_track_tag(T.ptr, "group", "")
    for _, I in ipairs(T.items) do if I.tag_i ~= "" then RA.set_item_tag(I.ptr, "inst", "") end end
  end
end

---------------------------------------------------------------------------------------------------------- view
function App:make_view(M)
  local view = {}
  for _, gid in ipairs(M.order) do
    local G = M.groups[gid]
    local data = G.data
    local F = M.W.tracks[G.F]
    local v = { gid = gid, name = data.name, color = data.color, folder = F and F.name or "(no folder)",
                has_copies = G.unique ~= nil, insts = {}, foreign = #G.foreign, lane = G.linked }
    local list = {}
    for _, iid in ipairs(G.order) do
      local inst = G.inst[iid]
      if not inst.removed then
        local n, reasons = 0, {}
        for mid, why in pairs(inst.mixed) do n = n + 1; reasons[#reasons + 1] = why end
        table.sort(reasons)
        local members = inst.count
        if not members then members = 0; for _ in pairs(inst.members) do members = members + 1 end end
        v.insts[#v.insts + 1] = { iid = iid, pos = inst.W.pos, len = inst.W.len, offs = inst.W.offs, lane = inst.lane,
                                  def = inst.def, main = inst.def == data.main, mixed = n, reasons = reasons,
                                  members = members }
        list[#list + 1] = { iid = iid, pos = inst.W.pos, len = inst.W.len }
      end
    end
    local ov = {}
    for _, p in ipairs(C.overlaps(list)) do ov[p[1]] = true; ov[p[2]] = true end
    for _, x in ipairs(v.insts) do x.overlap = ov[x.iid] or false end
    table.sort(v.insts, function(a, b) return a.pos < b.pos end)
    view[#view + 1] = v
  end
  self.view = view
end

---------------------------------------------------------------------------------------------------------- sync
-- view_only = true: just read (frozen mode). mode_override: "none" when called inside a command's own undo block.
function App:sync(view_only, mode_override)
  self.stats = {}
  if view_only then
    local M = self:build(RA.scan())
    self:make_view(M)
    return false
  end
  RA.begin_writes(mode_override or self.cfg.undo_mode)
  local done
  local ok, err = pcall(function()
    for _ = 1, 4 do
      local M = self:build(RA.scan())
      if not self:do_cuts(M) then
        self:reconcile(M)
        done = M
        break
      end
    end
  end)
  local changed = RA.end_writes()
  if not ok then self.err = tostring(err) else self.err = nil end
  -- the view comes from the reconciled model: it knows what is missing / mixed
  self:make_view(done or self:build(RA.scan()))
  self.last_sync = { changed = changed, stats = self.stats }
  return changed
end

---------------------------------------------------------------------------------------------------------- commands
function App:selection_info()
  local W = RA.scan()
  local sel, on_lane, grouped = {}, 0, 0
  local groups = {}
  for _, T in ipairs(W.tracks) do if T.lane:match("|linked$") then groups[T.lane:match("^([^|]+)")] = true end end
  for _, I in ipairs(W.items) do
    if I.sel then
      if I.T.lane ~= "" then on_lane = on_lane + 1
      else
        sel[#sel + 1] = I
        local g = I.tag_m ~= "" and I.tag_m:match("^([^|]+)")
        if g and groups[g] then grouped = grouped + 1 end
      end
    end
  end
  local idxs, tracks = {}, {}
  for _, I in ipairs(sel) do if not tracks[I.T.i] then tracks[I.T.i] = true; idxs[#idxs + 1] = I.T.i end end
  local F = C.common_folder(W.parent, idxs)
  local info = { W = W, sel = sel, n = #sel, tracks = #idxs, folder = F, grouped = grouped, on_lane = on_lane }
  if #sel == 0 then info.why = "Select the items to group (on tracks inside one folder)."
  elseif grouped > 0 then info.why = grouped .. " selected item(s) already belong to a group."
  elseif F == 0 then info.why = "The items must be on tracks inside the same folder (not on the folder track itself)."
  else info.folder_name = W.tracks[F].name end
  return info
end

local function short_id() return (RA.gen_guid():gsub("[^%x]", "")):sub(1, 8):lower() end

function App:ensure_copies_lane(G_linked_ptr, gid, name, color)
  local W = RA.scan()
  for _, T in ipairs(W.tracks) do if T.lane == gid .. "|unique" then return T.ptr end end
  local idx0 = RA.track_index0(G_linked_ptr)
  local d = RA.track_depth(G_linked_ptr)
  local tr = RA.insert_track(idx0 + 1, "COPIES · " .. name, color)
  if d < 0 then RA.set_depth(tr, d); RA.set_depth(G_linked_ptr, 0) end     -- the lane was the folder's last track
  RA.set_track_tag(tr, "lane", gid .. "|unique")
  return tr
end

function App:group_selected(name)
  local info = self:selection_info()
  if info.why then self.msg = info.why; return false end
  name = (name and name:match("%S")) and name:gsub("^%s+", ""):gsub("%s+$", "") or ("Group " .. (#self.view + 1))
  local W = info.W
  local sel = info.sel
  table.sort(sel, function(a, b) if a.T.i ~= b.T.i then return a.T.i < b.T.i end return a.pos < b.pos end)
  local P, E = math.huge, -math.huge
  for _, I in ipairs(sel) do P = math.min(P, I.pos); E = math.max(E, I.pos + I.len) end
  local c = PALETTE[(#self.view % #PALETTE) + 1]
  local color = r.ColorToNative(c[1], c[2], c[3])
  local gid = short_id()
  RA.with_undo("AliasTrack: group items", function()
    local members, has = {}, {}
    for k, I in ipairs(sel) do
      members[k] = { mid = k, track = I.T.guid, rel = I.pos - P, len = I.len, soffs = I.soffs, rate = I.rate,
                     pitch = I.pitch, tvol = I.tvol, vol = I.vol, mute = I.mute, fin = I.fin, fout = I.fout,
                     file = I.file, midi = I.midi, chunk = RA.item_chunk(I.ptr) }
      has[k] = true
    end
    local data = { v = 1, name = name, color = color, main = "1", next_def = 2, next_iid = 2,
                   defs = { ["1"] = { members = members, next_mid = #members + 1, len = E - P } } }
    local F = W.tracks[info.folder]
    local lane = RA.insert_track(F.i, "ALIAS · " .. name, color)          -- index0 = F.i -> first child of the folder
    RA.set_track_tag(lane, "lane", gid .. "|linked")
    RA.set_track_tag(lane, "group", C.json_encode(data))
    local alias = RA.create_alias(lane, P, E - P, 0, name, color)
    RA.set_item_tag(alias, "inst", gid .. "|1|1")
    RA.set_item_tag(alias, "win", string.format("%.10g|%.10g|%.10g", P, E - P, 0))
    RA.set_item_tag(alias, "has", C.list_encode(has))
    for k, I in ipairs(sel) do
      RA.set_item_tag(I.ptr, "mem", gid .. "|1|" .. k)
      RA.set_item_tag(I.ptr, "app", C.snap_encode(RA.snap(I)))
    end
    if self.cfg.copies_lane then self:ensure_copies_lane(lane, gid, name, color) end
    self:sync(false, "none")
  end)
  self.msg = string.format("Grouped %d item(s) as '%s'.", #sel, name)
  return true
end

-- find the alias item of an instance in a fresh scan
function App:find(gid, iid)
  iid = tostring(iid)
  local M = self:build(RA.scan())
  local G = M.groups[gid]
  return M, G, G and G.inst[iid]
end

function App:make_unique(gid, iid)
  local M, G, inst = self:find(gid, iid)
  if not inst or inst.lane == "unique" then return end
  RA.with_undo("AliasTrack: make alias unique", function()
    local lane = self:ensure_copies_lane(G.linked.ptr, gid, G.data.name, G.data.color)
    RA.move_to_track(inst.item.ptr, lane)
    self:sync(false, "none")
  end)
end

function App:relink(gid, iid)
  local M, G, inst = self:find(gid, iid)
  if not inst or inst.lane == "linked" then return end
  RA.with_undo("AliasTrack: link alias again", function()
    RA.move_to_track(inst.item.ptr, G.linked.ptr)
    self:sync(false, "none")
  end)
end

function App:request(gid, iid, what)
  iid = tostring(iid)
  self.requests[gid .. "|" .. iid] = what
  RA.with_undo(what == "apply" and "AliasTrack: apply alias edits to group" or "AliasTrack: revert alias", function()
    self:sync(false, "none")
  end)
end

-- members become ordinary items, the alias item is removed
function App:flatten(gid, iid)
  local M, G, inst = self:find(gid, iid)
  if not inst then return end
  RA.with_undo("AliasTrack: flatten alias", function()
    for _, mem in pairs(inst.members) do RA.set_item_tag(mem.I.ptr, "mem", ""); RA.set_item_tag(mem.I.ptr, "app", "") end
    RA.delete_item(inst.item.ptr)
    self:sync(false, "none")
  end)
end

-- every alias of the group is flattened, the lane tracks are removed
function App:ungroup(gid)
  local M = self:build(RA.scan())
  local G = M.groups[gid]
  if not G then return end
  RA.with_undo("AliasTrack: ungroup", function()
    for _, iid in ipairs(G.order) do
      for _, mem in pairs(G.inst[iid].members) do
        RA.set_item_tag(mem.I.ptr, "mem", ""); RA.set_item_tag(mem.I.ptr, "app", "")
      end
    end
    if G.unique then RA.delete_track(G.unique.ptr) end
    RA.delete_track(G.linked.ptr)
    self:sync(false, "none")
  end)
end

-- stop managing everything: tags removed, tracks and items stay as they are
function App:detach_all()
  local W = RA.scan()
  RA.with_undo("AliasTrack: detach all", function()
    for _, T in ipairs(W.tracks) do
      if T.lane ~= "" then RA.set_track_tag(T.ptr, "lane", ""); RA.set_track_tag(T.ptr, "group", "") end
    end
    for _, I in ipairs(W.items) do
      if I.tag_i ~= "" then RA.set_item_tag(I.ptr, "inst", ""); RA.set_item_tag(I.ptr, "win", ""); RA.set_item_tag(I.ptr, "has", "") end
      if I.tag_m ~= "" then RA.set_item_tag(I.ptr, "mem", ""); RA.set_item_tag(I.ptr, "app", "") end
    end
  end)
  self:sync(true)
end

-- selected member items: take everything about them (FX, envelopes, takes ...) into the group, then rebuild the others
function App:push_selected()
  local M = self:build(RA.scan())
  local n = 0
  RA.with_undo("AliasTrack: push member edits to group", function()
    for _, gid in ipairs(M.order) do
      local G = M.groups[gid]
      for _, iid in ipairs(G.order) do
        local inst = G.inst[iid]
        local def = G.data.defs[inst.def]
        for mid, mem in pairs(inst.members) do
          local m = def and C.member_by_mid(def, mid)
          if mem.I.sel and m then
            m.chunk = RA.item_chunk(mem.I.ptr)
            self.push[gid] = self.push[gid] or {}
            self.push[gid][inst.def] = self.push[gid][inst.def] or {}
            self.push[gid][inst.def][mid] = iid
            n = n + 1
          end
        end
      end
      RA.set_track_tag(G.linked.ptr, "group", C.json_encode(G.data))
    end
    self:sync(false, "none")
  end)
  self.msg = n > 0 and (n .. " member(s) pushed to their group.") or "Select member items first."
end

-- add selected plain items to the alias they lie in
function App:add_selected()
  local M = self:build(RA.scan())
  local n = 0
  RA.with_undo("AliasTrack: add items to alias", function()
    for _, I in ipairs(M.W.items) do
      if I.sel and I.T.lane == "" and I.tag_m == "" then
        for _, gid in ipairs(M.order) do
          local G = M.groups[gid]
          if G.in_folder(I.T.guid) then
            local best
            for _, iid in ipairs(G.order) do
              local w = G.inst[iid].W
              if I.pos >= w.pos - C.EPS and I.pos < w.pos + w.len - C.EPS then
                if not best or (G.inst[iid].lane == "linked" and G.inst[best].lane ~= "linked") then best = iid end
              end
            end
            if best then
              local inst = G.inst[best]
              local def = G.data.defs[inst.def]
              local mid = def.next_mid or (#def.members + 1)
              def.next_mid = mid + 1
              def.members[#def.members + 1] = {
                mid = mid, track = I.T.guid, rel = I.pos - inst.W.pos + inst.W.offs, len = I.len, soffs = I.soffs,
                rate = I.rate, pitch = I.pitch, tvol = I.tvol, vol = I.vol, mute = I.mute, fin = I.fin, fout = I.fout,
                file = I.file, midi = I.midi, chunk = RA.item_chunk(I.ptr) }
              RA.set_item_tag(I.ptr, "mem", gid .. "|" .. best .. "|" .. mid)
              RA.set_item_tag(I.ptr, "app", C.snap_encode(RA.snap(I)))
              RA.set_item_tag(inst.item.ptr, "has", (inst.item.tag_h ~= "" and (inst.item.tag_h .. ",") or "") .. mid)
              inst.item.tag_h = (inst.item.tag_h ~= "" and (inst.item.tag_h .. ",") or "") .. mid
              RA.set_track_tag(G.linked.ptr, "group", C.json_encode(G.data))
              n = n + 1
              break
            end
          end
        end
      end
    end
    self:sync(false, "none")
  end)
  self.msg = n > 0 and (n .. " item(s) added.") or "Select plain items that lie inside an alias (same folder)."
end

-- selected members leave their group: removed from the definition (so from every linked alias), the item itself stays
function App:remove_selected()
  local M = self:build(RA.scan())
  local n = 0
  RA.with_undo("AliasTrack: remove items from group", function()
    for _, gid in ipairs(M.order) do
      local G = M.groups[gid]
      for _, iid in ipairs(G.order) do
        local inst = G.inst[iid]
        local def = G.data.defs[inst.def]
        for mid, mem in pairs(inst.members) do
          if mem.I.sel and def then
            C.def_cut(def, mid, -math.huge, math.huge)
            RA.set_item_tag(mem.I.ptr, "mem", ""); RA.set_item_tag(mem.I.ptr, "app", "")
            n = n + 1
          end
        end
      end
      RA.set_track_tag(G.linked.ptr, "group", C.json_encode(G.data))
    end
    self:sync(false, "none")
  end)
  self.msg = n > 0 and (n .. " item(s) removed from their group.") or "Select member items first."
end

function App:select_instance(gid, iid)
  local M, G, inst = self:find(gid, iid)
  if not inst then return end
  local list = { inst.item.ptr }
  for _, mem in pairs(inst.members) do list[#list + 1] = mem.I.ptr end
  RA.select_only(list)
end

function App:rename(gid, name)
  local M = self:build(RA.scan())
  local G = M.groups[gid]
  if not G or not name:match("%S") then return end
  RA.with_undo("AliasTrack: rename group", function()
    G.data.name = name
    RA.set_track_tag(G.linked.ptr, "group", C.json_encode(G.data))
    self:sync(false, "none")
  end)
end

return App

end
__preload["ATUI"] = function(...)
-- ATUI.lua
-- ReaImGui window. Reads App state, calls App methods. Same layout conventions as the other _n_plugins.

local r = reaper
local V = require("ATVersion")

local UI = {}

local COL_HEAD = 0xFFCC44FF
local COL_DIM  = 0x999999FF
local COL_WARN, COL_ERR, COL_OK = 0xFFAA33FF, 0xFF5F5FFF, 0x5FE07FFF

-- Accent colour scheme. Hue 262 deg (from #4700C2); saturation, brightness and alpha are those of ImGui's default dark
-- style (its blue is hue 212 deg), so buttons/headers are translucent like the default instead of solid and heavy.
local BG = 0x181A1AFF
local THEME = {
  { "WindowBg", BG }, { "PopupBg", BG }, { "ChildBg", BG },
  { "FrameBg", 0x47297A8A }, { "FrameBgHovered", 0x8542FA66 }, { "FrameBgActive", 0x8542FAAB },
  { "Button", 0x8542FA66 }, { "ButtonHovered", 0x8542FAFF }, { "ButtonActive", 0x650FFAFF },
  { "SliderGrab", 0x793DE0FF }, { "SliderGrabActive", 0x8542FAFF }, { "CheckMark", 0x8542FAFF },
  { "Header", 0x8542FA4F }, { "HeaderHovered", 0x8542FACC }, { "HeaderActive", 0x8542FAFF },
  { "PlotHistogram", 0x8542FAFF }, { "TitleBgActive", 0x47297AFF },
}

-- pushes the theme and returns how many colours were pushed
-- (a colour name missing in an older ReaImGui is skipped instead of raising an error)
local function push_theme(ctx)
  local n = 0
  for _, c in ipairs(THEME) do
    local get = r["ImGui_Col_" .. c[1]]
    if get then r.ImGui_PushStyleColor(ctx, get(), c[2]); n = n + 1 end
  end
  return n
end

local REASON = {
  missing = "deleted", edited = "edited", clipped_edit = "edited at a cut edge", outside_window = "moved outside",
  outside_folder = "moved out of the folder", track_gone = "track deleted",
}

local function fmt_time(t)
  if r.format_timestr_pos then return r.format_timestr_pos(t, "", -1) end
  return string.format("%.3f", t)
end

local function rgba(native)
  if not native or native == 0 or not r.ColorFromNative then return COL_DIM end
  local R, G, B = r.ColorFromNative(native)
  return (R << 24) | (G << 16) | (B << 8) | 0xFF
end

function UI.new(app)
  local ui = {}
  local ctx = r.ImGui_CreateContext("AliasTrack")
  local title = "AliasTrack v" .. V.VERSION .. "###alias_track_main"
  local state = { name = "", renaming = nil, rename_buf = "", confirm_detach = false, sel_cc = -1, sel = nil }
  ui.state = state

  local function tip(t) if r.ImGui_IsItemHovered(ctx) and r.ImGui_SetTooltip then r.ImGui_SetTooltip(ctx, t) end end
  local function heading(t) r.ImGui_Spacing(ctx); r.ImGui_TextColored(ctx, COL_HEAD, t); r.ImGui_Separator(ctx) end
  local function btn(label, t, disabled)
    if disabled and r.ImGui_BeginDisabled then r.ImGui_BeginDisabled(ctx, true) end
    local clicked = r.ImGui_Button(ctx, label)
    if disabled and r.ImGui_EndDisabled then r.ImGui_EndDisabled(ctx) end
    if t then tip(t) end
    return clicked and not disabled
  end
  local function small(label, t, disabled)
    if disabled and r.ImGui_BeginDisabled then r.ImGui_BeginDisabled(ctx, true) end
    local clicked = r.ImGui_SmallButton(ctx, label)
    if disabled and r.ImGui_EndDisabled then r.ImGui_EndDisabled(ctx) end
    if t then tip(t) end
    return clicked and not disabled
  end
  local function checkbox(label, key, t)
    local ch, v = r.ImGui_Checkbox(ctx, label, app.cfg[key])
    if t then tip(t) end
    if ch then app:set(key, v) end
  end

  ------------------------------------------------------------------------------------------------ sections
  local function draw_top()
    if app.cfg.live then
      r.ImGui_TextColored(ctx, COL_OK, "LIVE")
      r.ImGui_SameLine(ctx)
      r.ImGui_Text(ctx, app.paused and "- paused after your undo (undo again, or edit to continue)" or "- aliases follow the project")
    else
      r.ImGui_TextColored(ctx, COL_WARN, "FROZEN")
      r.ImGui_SameLine(ctx)
      r.ImGui_Text(ctx, "- nothing is changed until you go live again")
    end
    if btn(app.cfg.live and "Freeze" or "Go live", "Freeze: stop following edits. Items stay as they are.") then
      app:set("live", not app.cfg.live)
    end
    r.ImGui_SameLine(ctx)
    if btn("Sync now", "Run one full sync, even if nothing seems to have changed.", not app.cfg.live) then
      app:sync(); app.seen = -1
    end
    local ls = app.last_sync
    if ls and ls.stats then
      local s = ls.stats
      local parts = {}
      for _, k in ipairs({ "created", "updated", "deleted", "adopted", "cuts", "copies", "forks", "edits" }) do
        if s[k] and s[k] > 0 then parts[#parts + 1] = s[k] .. " " .. k end
      end
      if #parts > 0 then r.ImGui_TextColored(ctx, COL_DIM, "Last sync: " .. table.concat(parts, ", ")) end
    end
    if app.err then r.ImGui_TextColored(ctx, COL_ERR, app.err) end
    if state.err then r.ImGui_TextColored(ctx, COL_ERR, "UI: " .. state.err) end
  end

  local function draw_group_box()
    heading("Group selected items")
    local cc = r.GetProjectStateChangeCount(0)
    if cc ~= state.sel_cc or not state.sel then state.sel_cc = cc; state.sel = app:selection_info() end
    local info = state.sel
    r.ImGui_SetNextItemWidth(ctx, 220)
    local ch, v = r.ImGui_InputText(ctx, "Name##group_name", state.name)
    if ch then state.name = v end
    r.ImGui_SameLine(ctx)
    if btn("Group selected items", "Creates an ALIAS lane inside the folder and one alias item spanning the selection.", info.why ~= nil) then
      if app:group_selected(state.name) then state.name = "" end
      state.sel = nil
    end
    if info.why then r.ImGui_TextColored(ctx, COL_DIM, info.why)
    else
      r.ImGui_TextColored(ctx, COL_OK, string.format("%d item(s) on %d track(s) in folder '%s'", info.n, info.tracks, info.folder_name or "?"))
    end
    if btn("Add selected to alias", "Plain items that start inside an alias (same folder) become members of its group.") then app:add_selected(); state.sel = nil end
    r.ImGui_SameLine(ctx)
    if btn("Remove selected from group", "Selected members leave the group; the same material disappears from every linked alias.") then app:remove_selected(); state.sel = nil end
    r.ImGui_SameLine(ctx)
    if btn("Push selected edits", "Take FX, envelopes, takes ... of the selected members into the group and rebuild the linked copies.") then app:push_selected() end
  end

  local function draw_instance_table(g)
    if not r.ImGui_BeginTable(ctx, "insts##" .. g.gid, 7, (r.ImGui_TableFlags_Borders and r.ImGui_TableFlags_Borders() or 0)) then return end
    for _, h in ipairs({ "Alias", "Lane", "Position", "Length", "Offset", "Status", "" }) do r.ImGui_TableSetupColumn(ctx, h) end
    r.ImGui_TableHeadersRow(ctx)
    for _, x in ipairs(g.insts) do
      r.ImGui_PushID(ctx, g.gid .. x.iid)
      r.ImGui_TableNextRow(ctx)
      r.ImGui_TableSetColumnIndex(ctx, 0); r.ImGui_Text(ctx, "#" .. x.iid)
      r.ImGui_TableSetColumnIndex(ctx, 1)
      if x.lane == "linked" then r.ImGui_Text(ctx, "linked") else r.ImGui_Text(ctx, "unique #" .. x.def) end
      r.ImGui_TableSetColumnIndex(ctx, 2); r.ImGui_Text(ctx, fmt_time(x.pos))
      r.ImGui_TableSetColumnIndex(ctx, 3); r.ImGui_Text(ctx, string.format("%.3f s", x.len))
      r.ImGui_TableSetColumnIndex(ctx, 4); r.ImGui_Text(ctx, string.format("%.3f s", x.offs))
      r.ImGui_TableSetColumnIndex(ctx, 5)
      if x.mixed > 0 then
        local words = {}
        for _, why in ipairs(x.reasons) do words[#words + 1] = REASON[why] or why end
        r.ImGui_TextColored(ctx, COL_WARN, "MIXED: " .. table.concat(words, ", "))
        tip("Some members were changed in a way that cannot be applied to the group automatically.\nApply = make the group like this alias. Revert = make this alias like the group.")
      else
        r.ImGui_TextColored(ctx, COL_OK, x.members .. " member(s)")
      end
      if x.overlap then r.ImGui_SameLine(ctx); r.ImGui_TextColored(ctx, COL_DIM, "(overlaps)") end
      r.ImGui_TableSetColumnIndex(ctx, 6)
      if small("Select", "Select this alias and its members.") then app:select_instance(g.gid, x.iid) end
      r.ImGui_SameLine(ctx)
      if x.lane == "linked" then
        if small("Make unique", "Move to the COPIES lane: from now on its edits stay its own.") then app:make_unique(g.gid, x.iid) end
      else
        if small("Link", "Move back to the ALIAS lane: it shows the group again (its own edits are dropped).") then app:relink(g.gid, x.iid) end
      end
      if x.mixed > 0 then
        r.ImGui_SameLine(ctx)
        if small("Apply", "Make the group like this alias (linked aliases follow).") then app:request(g.gid, x.iid, "apply") end
        r.ImGui_SameLine(ctx)
        if small("Revert", "Make this alias like the group again.") then app:request(g.gid, x.iid, "revert") end
      end
      r.ImGui_SameLine(ctx)
      if small("Flatten", "Members become plain items, the alias item is removed.") then app:flatten(g.gid, x.iid) end
      r.ImGui_PopID(ctx)
    end
    r.ImGui_EndTable(ctx)
  end

  local function draw_groups()
    heading(string.format("Groups (%d)", #app.view))
    if #app.view == 0 then
      r.ImGui_TextColored(ctx, COL_DIM, "No groups yet. Select items on tracks inside one folder and press 'Group selected items'.")
      return
    end
    for _, g in ipairs(app.view) do
      r.ImGui_PushID(ctx, g.gid)
      r.ImGui_TextColored(ctx, rgba(g.color), "■")
      r.ImGui_SameLine(ctx)
      if state.renaming == g.gid then
        r.ImGui_SetNextItemWidth(ctx, 180)
        local ch, v = r.ImGui_InputText(ctx, "##rename", state.rename_buf)
        if ch then state.rename_buf = v end
        r.ImGui_SameLine(ctx)
        if small("OK") then app:rename(g.gid, state.rename_buf); state.renaming = nil end
        r.ImGui_SameLine(ctx)
        if small("Cancel") then state.renaming = nil end
      else
        r.ImGui_Text(ctx, g.name)
        r.ImGui_SameLine(ctx)
        r.ImGui_TextColored(ctx, COL_DIM, string.format("in '%s' - %d alias(es)%s", g.folder, #g.insts, g.has_copies and ", COPIES lane" or ""))
        r.ImGui_SameLine(ctx)
        if small("Rename") then state.renaming = g.gid; state.rename_buf = g.name end
        r.ImGui_SameLine(ctx)
        if small("Ungroup", "Every alias of this group is flattened and its lane tracks are removed.") then app:ungroup(g.gid) end
      end
      if g.foreign > 0 then
        r.ImGui_TextColored(ctx, COL_WARN, g.foreign .. " item(s) on the lanes are not aliases (only empty MIDI alias items belong there) - ignored.")
      end
      draw_instance_table(g)
      r.ImGui_Spacing(ctx)
      r.ImGui_PopID(ctx)
    end
  end

  local function draw_settings()
    heading("Settings")
    r.ImGui_Text(ctx, "Undo:")
    r.ImGui_SameLine(ctx)
    if r.ImGui_RadioButton(ctx, "One step per edit##undo_silent", app.cfg.undo_mode == "silent") then app:set("undo_mode", "silent") end
    tip("Syncs add no undo points: Ctrl+Z undoes your own edit and the aliases are derived again. Recommended.")
    r.ImGui_SameLine(ctx)
    if r.ImGui_RadioButton(ctx, "Separate sync steps##undo_steps", app.cfg.undo_mode == "steps") then app:set("undo_mode", "steps") end
    tip("Every sync is its own undo point 'AliasTrack: sync'. After undoing one, syncing pauses until you undo again or edit.")
    checkbox("Apply member edits to the group automatically", "propagate",
      "On: moving / trimming / fading a member changes every linked alias.\nOff: the alias shows MIXED until you Apply or Revert.")
    checkbox("Deleting an alias deletes its members", "delete_with_alias", "Off: the members stay as plain items.")
    checkbox("Keep MIDI pooled between linked aliases", "keep_pool", "MIDI note edits are then shared by REAPER itself.")
    checkbox("Create the COPIES lane with every new group", "copies_lane")
    r.ImGui_SetNextItemWidth(ctx, 90)
    local ch, v = r.ImGui_InputInt(ctx, "ms fade on edges cut by an alias", app.cfg.clipfade_ms)
    if ch then app:set("clipfade_ms", math.max(0, math.min(1000, v))) end
    r.ImGui_Spacing(ctx)
    if not state.confirm_detach then
      if btn("Detach all...", "Stop managing everything: tags are removed, tracks and items stay.") then state.confirm_detach = true end
    else
      r.ImGui_TextColored(ctx, COL_WARN, "Remove every AliasTrack tag from this project?")
      r.ImGui_SameLine(ctx)
      if btn("Yes, detach") then app:detach_all(); state.confirm_detach = false end
      r.ImGui_SameLine(ctx)
      if btn("Cancel##detach") then state.confirm_detach = false end
    end
  end

  local function draw_ui()
    draw_top()
    draw_group_box()
    draw_groups()
    draw_settings()
    if app.msg then r.ImGui_Spacing(ctx); r.ImGui_TextColored(ctx, COL_DIM, app.msg) end
  end
  ui.draw_ui = draw_ui

  function ui.frame()
    local pushed = push_theme(ctx)
    r.ImGui_SetNextWindowSize(ctx, 980, 620, r.ImGui_Cond_FirstUseEver())
    local visible, open = r.ImGui_Begin(ctx, title, true)
    if visible then
      local ok, e = pcall(draw_ui)
      if not ok then state.err = tostring(e) end
      r.ImGui_End(ctx)
    end
    r.ImGui_PopStyleColor(ctx, pushed)   -- also when the window is collapsed: the colour stack must stay balanced
    return open
  end

  return ui
end

return UI

end

local r = reaper
local dir = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or ""
package.path = dir .. "?.lua;" .. package.path

if not r.ImGui_CreateContext then
  r.MB("This script needs the ReaImGui extension.\n\nInstall it via ReaPack (Extensions > ReaPack > Browse packages > 'ReaImGui').", "AliasTrack", 0)
  return
end

local App = require("ATApp")
local UI  = require("ATUI")

local EXT = "AliasTrackApp"

-- running again while open = close
local hb_age = os.time() - (tonumber(r.GetExtState(EXT, "hb")) or 0)
if r.GetExtState(EXT, "running") == "1" and hb_age < 3 then
  r.SetExtState(EXT, "stop", "1", false)
  return
end
r.SetExtState(EXT, "running", "1", false)
r.SetExtState(EXT, "stop", "0", false)
r.SetExtState(EXT, "hb", tostring(os.time()), false)

local _, _, sec, cmdid = r.get_action_context()
local function set_toggle(on)
  if cmdid and cmdid ~= 0 then r.SetToggleCommandState(sec, cmdid, on and 1 or 0); r.RefreshToolbar2(sec, cmdid) end
end
set_toggle(true)

local app = App.new()
local ui = UI.new(app)

local function shutdown()
  app:save()
  set_toggle(false)
  r.SetExtState(EXT, "running", "0", false)
  r.SetExtState(EXT, "stop", "0", false)
end
r.atexit(shutdown)

local last_hb, last_err = 0, nil
local function loop()
  if r.GetExtState(EXT, "stop") == "1" then shutdown(); return end
  local now = r.time_precise()
  if now - last_hb > 1 then r.SetExtState(EXT, "hb", tostring(os.time()), false); last_hb = now end
  local ok, err = pcall(app.tick, app)
  if not ok and tostring(err) ~= last_err then last_err = tostring(err); app.err = "Error: " .. last_err end
  if ui.frame() then r.defer(loop) else shutdown() end
end

loop()

