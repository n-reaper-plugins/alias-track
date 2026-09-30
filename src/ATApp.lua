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
