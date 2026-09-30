package.path = "./src/?.lua;./tools/?.lua;" .. package.path
local T = require("t")
local C = require("ATCore")

local function m(rel, len, extra)
  local x = { mid = 1, track = "T", rel = rel, len = len, soffs = 0, rate = 1, pitch = 0, tvol = 1, vol = 1, mute = 0, fin = 0.01, fout = 0.02 }
  for k, v in pairs(extra or {}) do x[k] = v end
  return x
end

-------------------------------------------------------------------- visible()
do
  local w = { pos = 10, len = 4, offs = 0 }
  local p = C.visible(m(1, 2), w, 0.005)
  T.eq(p.pos, 11, "unclipped piece position")
  T.eq(p.len, 2, "unclipped piece length")
  T.ok(not p.clipL and not p.clipR, "unclipped flags")
  T.eq(p.fin, 0.01, "own fade-in kept"); T.eq(p.fout, 0.02, "own fade-out kept")

  p = C.visible(m(3, 3), w, 0.005)                       -- 3..6 seen through 0..4
  T.eq(p.len, 1, "right-clipped length"); T.ok(p.clipR and not p.clipL, "right clip flag"); T.eq(p.fout, 0.005, "clip fade right")

  local w2 = { pos = 20, len = 2, offs = 2 }             -- window 2..4 at 20
  p = C.visible(m(1, 2, { soffs = 5, rate = 2 }), w2, 0)  -- member 1..3, visible 2..3
  T.eq(p.pos, 20, "left-clipped position"); T.eq(p.len, 1, "left-clipped length")
  T.eq(p.soffs, 7, "left-clipped source offset follows rate (5 + 1*2)")
  T.ok(p.clipL, "left clip flag")
  T.ok(C.visible(m(5, 1), w, 0) == nil, "outside window = nil")
  T.ok(C.visible(m(4, 1), w, 0) == nil, "touching edge = nil")
  local tiny = C.visible(m(0, 4), { pos = 0, len = 0.004, offs = 0 }, 1)
  T.ok(tiny.fout <= 0.002 + 1e-12, "clip fade limited to half the piece")
end

-------------------------------------------------------------------- snapshots
do
  local s = { pos = 1.5, len = 2, soffs = 0.25, vol = 0.5, mute = 1, rate = 1, pitch = -2, tvol = 1, fin = 0, fout = 0.1, track = "{G}", clipR = true }
  local d = C.snap_decode(C.snap_encode(s))
  T.eq(d.pos, 1.5, "snap pos"); T.eq(d.track, "{G}", "snap track"); T.eq(d.pitch, -2, "snap pitch")
  T.ok(d.clipR and not d.clipL, "snap clip flags survive")
  T.ok(C.snap_decode("") == nil, "empty snapshot = nil")
  local a = C.copy(s); a.fout = 0.3
  T.ok(C.snap_eq(a, s), "fade on a clipped edge is ignored")
  a.fin = 0.3
  T.ok(not C.snap_eq(a, s), "fade on an unclipped edge matters")
end

-------------------------------------------------------------------- classify()
do
  local w = { pos = 10, len = 4, offs = 0 }
  local dm = m(1, 2)
  local S = C.visible(dm, w, 0)
  local info = { in_folder = function(g) return g ~= "OUT" end, window = w, def_member = dm }
  local A = C.copy(S)
  T.eq(C.classify(A, S, S, info).kind, "ok", "unchanged = ok")

  local w2 = { pos = 12, len = 4, offs = 0 }                  -- alias moved by +2
  local N2 = C.visible(dm, w2, 0)
  T.eq(C.classify(A, S, N2, info).kind, "write", "alias moved, member not = write")
  local A2 = C.copy(A); A2.pos = A2.pos + 2
  T.eq(C.classify(A2, S, N2, info).kind, "ok", "both moved (ripple) = ok")

  local A3 = C.copy(A); A3.pos = 11.5
  local r = C.classify(A3, S, S, info)
  T.eq(r.kind, "edit", "member moved inside = edit"); T.eq(r.edit.geom.rel, 1.5, "edit gives new def-local position")

  local A4 = C.copy(A); A4.vol = 0.5
  r = C.classify(A4, S, S, info)
  T.eq(r.kind, "edit", "volume = edit"); T.eq(r.edit.props.vol, 0.5, "edit carries volume"); T.ok(r.edit.geom == nil, "no geometry edit")

  local A5 = C.copy(A); A5.pos = 13.5
  T.eq(C.classify(A5, S, S, info).reason, "outside_window", "moved beyond the alias = mixed")
  local A6 = C.copy(A); A6.track = "OUT"
  T.eq(C.classify(A6, S, S, info).reason, "outside_folder", "moved out of folder = mixed")
  local A7 = C.copy(A); A7.track = "T2"
  r = C.classify(A7, S, S, info)
  T.eq(r.kind, "edit", "moved to another track in folder = edit"); T.eq(r.edit.track, "T2", "edit carries track")

  -- clipped member: geometry edit is ambiguous
  local dm2 = m(3, 3)
  local S2 = C.visible(dm2, w, 0)
  local A8 = C.copy(S2); A8.pos = A8.pos - 0.5
  T.eq(C.classify(A8, S2, S2, { in_folder = info.in_folder, window = w, def_member = dm2 }).reason, "clipped_edit", "clipped geometry edit = mixed")

  -- the left piece of a user split: shorter, its fade-out reset; the (already split) window explains it
  local wsplit = { pos = 10, len = 1.5, offs = 0 }
  local Nsplit = C.visible(dm, wsplit, 0.005)
  local A9 = C.copy(S); A9.len = 0.5; A9.fout = 0
  T.eq(C.classify(A9, S, Nsplit, info).kind, "ok", "split left piece matches the split window")
end

-------------------------------------------------------------------- find_cuts()
do
  local S = { pos = 10, len = 4, soffs = 1, rate = 1, track = "T" }
  local A = { pos = 10, len = 1.5, soffs = 1 }
  local cuts, matched = C.find_cuts(S, A, { { pos = 11.5, len = 2.5, soffs = 2.5, rate = 1 } })
  T.eq(#cuts, 1, "one split = one cut"); T.eq(cuts[1], 11.5, "cut time"); T.eq(#matched, 1, "piece matched")
  cuts = C.find_cuts(S, A, { { pos = 12, len = 2, soffs = 3, rate = 1 } })     -- razor: middle 11.5..12 deleted
  T.eq(#cuts, 2, "razor gap = two cuts"); T.eq(cuts[2], 12, "second cut")
  cuts = C.find_cuts(S, A, {})
  T.eq(#cuts, 0, "shortened without pieces = trim, not cut")
  cuts = C.find_cuts(S, A, { { pos = 12, len = 2, soffs = 9, rate = 1 } })
  T.eq(#cuts, 0, "piece with another anchor is not ours")
  cuts = C.find_cuts(S, A, { { pos = 11.5, len = 1, soffs = 2.5 }, { pos = 12.5, len = 1.5, soffs = 3.5 } })
  T.eq(#cuts, 2, "two splits = two cuts")
end

-------------------------------------------------------------------- split_children()
do
  local W0 = { pos = 10, len = 4, offs = 0 }
  local now = { pos = 10, len = 1, offs = 0 }
  local kids = C.split_children(W0, now, { { pos = 11, len = 3, offs = 1 }, { pos = 20, len = 4, offs = 0 }, { pos = 12, len = 1, offs = 0 } })
  T.eq(#kids, 1, "only the same-anchor piece inside the old extent is a split child")
  T.eq(#C.split_children(W0, { pos = 12, len = 4, offs = 0 }, { { pos = 11, len = 3, offs = 1 } }), 0, "a moved alias has no split children")
  T.eq(#C.split_children(nil, now, { { pos = 11, len = 3, offs = 1 } }), 0, "no last window = nothing")
end

-------------------------------------------------------------------- def_cut()
do
  local def = { members = { m(0, 10, { mid = 1, soffs = 2 }) }, next_mid = 2 }
  local out = C.def_cut(def, 1, 3, 5)
  T.eq(#out, 2, "cut in the middle = two parts"); T.eq(#def.members, 2, "def has two members")
  T.eq(def.members[1].len, 3, "left part length"); T.eq(def.members[2].rel, 5, "right part start")
  T.eq(def.members[2].soffs, 7, "right part source offset"); T.eq(def.members[2].mid, 2, "right part new mid")
  C.def_cut(def, 2, 4, 20)
  T.eq(#def.members, 1, "cutting everything of a member removes it")
  C.def_cut(def, 1, -1, 1)
  T.eq(def.members[1].rel, 1, "cutting the head moves the start"); T.eq(def.members[1].soffs, 3, "head cut offset")
  T.eq(C.def_extent(def), 3, "extent")
end

-------------------------------------------------------------------- folders
do
  -- 1 Drums(+1)  2 Kick  3 Snare(-1)  4 Bass  5 FX(+1) 6 Sub(+1) 7 Verb(-2)
  local p = C.parents({ 1, 0, -1, 0, 1, 1, -2 })
  T.eq(p[2], 1, "kick in drums"); T.eq(p[4], 0, "bass top level"); T.eq(p[7], 6, "verb in sub")
  T.eq(C.common_folder(p, { 2, 3 }), 1, "common folder of kick+snare")
  T.eq(C.common_folder(p, { 6, 7 }), 5, "sub + verb -> FX")
  T.eq(C.common_folder(p, { 2, 4 }), 0, "kick + bass: none")
  T.eq(C.common_folder(p, { 1 }), 0, "folder track itself is not inside itself")
  T.ok(C.is_desc(p, 7, 5), "verb inside FX (nested)")
end

-------------------------------------------------------------------- chunks
do
  local n = 0
  local gen = function() n = n + 1; return "{NEW-" .. n .. "}" end
  local chunk = "<ITEM\nIGUID {AAAA-1}\n  GUID {BBBB-2}\nPOOLEDEVTS {CCCC-3}\n  FXID {DDDD-4}\nNAME \"x\"\n>"
  local out = C.refresh_guids(chunk, gen, true)
  T.ok(not out:find("AAAA") and not out:find("BBBB") and not out:find("DDDD"), "item, take and FX GUIDs replaced")
  T.ok(out:find("CCCC"), "MIDI pool kept for linked copies")
  T.ok(out:find("\n  GUID {NEW"), "indentation kept")
  out = C.refresh_guids(chunk, gen, false)
  T.ok(not out:find("CCCC"), "MIDI pool replaced for unique copies")
end

-------------------------------------------------------------------- names, lists, json, overlaps
do
  T.eq(C.take_name("Drums", "1", "1"), "Drums", "linked alias name")
  T.eq(C.take_name("Drums", "3", "1"), "Drums #3", "unique alias name")
  T.eq(C.take_code("Drums #3"), "3", "code from name"); T.ok(C.take_code("Drums") == nil, "no code")
  local l = C.list_decode("3,1,2"); T.ok(l[1] and l[2] and l[3], "list decode")
  T.eq(C.list_encode({ [10] = true, [2] = true }), "2,10", "list encode sorted numerically")
  local data = { name = "Dr\"um\ns", defs = { ["1"] = { members = { { mid = 1, chunk = "<ITEM\n>" } } }, ["2"] = { members = {} } }, n = 1.25 }
  local back = C.json_decode(C.json_encode(data))
  T.eq(back.name, data.name, "json string escapes"); T.eq(back.defs["1"].members[1].chunk, "<ITEM\n>", "json nested")
  T.eq(back.n, 1.25, "json number")
  T.eq(#back.defs["2"].members, 0, "json empty list")
  T.ok(C.json_decode("{bad") == nil, "bad json = nil")
  local ov = C.overlaps({ { iid = "1", pos = 0, len = 4 }, { iid = "2", pos = 3, len = 2 }, { iid = "3", pos = 10, len = 1 } })
  T.eq(#ov, 1, "one overlap"); T.eq(ov[1][2], "2", "overlap pair")
end

T.done("test_core")
