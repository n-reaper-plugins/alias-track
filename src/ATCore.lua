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
