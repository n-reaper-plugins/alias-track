package.path = "./src/?.lua;./tools/?.lua;" .. package.path
local T = require("t")
local Mock = require("mock_reaper")

local function approx(a, b) return math.abs(a - b) < 1e-6 end

-- fresh project + fresh modules (they capture `reaper` when loaded)
local function fresh(cfg)
  Mock.install()
  for _, m in ipairs({ "ATCore", "ATReaper", "ATApp" }) do package.loaded[m] = nil end
  local App = require("ATApp")
  local app = App.new()
  for k, v in pairs(cfg or {}) do app.cfg[k] = v end
  local drums = Mock.track("Drums", 1)
  local kick  = Mock.track("Kick", 0)
  local snare = Mock.track("Snare", 0)
  local hh    = Mock.track("HH", -1)
  local bass  = Mock.track("Bass", 0)
  local k = Mock.item(kick, 10, 1, "/s/kick.wav")
  local s = Mock.item(snare, 11, 1, "/s/snare.wav")
  local h = Mock.item(hh, 10, 2, "/s/hh.wav")
  return { app = app, drums = drums, kick = kick, snare = snare, hh = hh, bass = bass, k = k, s = s, h = h }
end

local function group(P, name)
  Mock.select({ P.k, P.s, P.h })
  local ok = P.app:group_selected(name or "Beat")
  P.lane = Mock.track_named("ALIAS · " .. (name or "Beat"))
  return ok
end

local function aliases(P) return Mock.items_on(P.lane) end
local function n(track) return #track.items end
local function sum_len(track) local s = 0; for _, it in ipairs(track.items) do s = s + it.p.D_LENGTH end; return s end
local function view_inst(P, i) return P.app.view[1] and P.app.view[1].insts[i] end

---------------------------------------------------------------------------------------------- group
do
  local P = fresh()
  T.ok(group(P), "group succeeds")
  local st, depth = Mock.structure()
  T.eq(st[2], "  ALIAS · Beat", "lane is the first child of the folder")
  T.eq(depth, 0, "folder structure balanced")
  local al = aliases(P)
  T.eq(#al, 1, "one alias item"); T.eq(al[1].p.D_POSITION, 10, "alias starts at the selection"); T.eq(al[1].p.D_LENGTH, 2, "alias spans the selection")
  T.eq(al[1].p.B_LOOPSRC, 0, "alias does not loop"); T.eq(al[1].takes[1].name, "Beat", "alias shows the group name")
  T.ok(al[1].takes[1].src.midi, "alias is an empty MIDI item")
  T.ok(P.k.ext.AT_m ~= nil and P.h.ext.AT_m ~= nil, "members tagged")
  T.eq(Mock.S.undo[#Mock.S.undo], "AliasTrack: group items", "grouping is one undo step")
  T.eq(#P.app.view, 1, "view shows the group"); T.eq(#P.app.view[1].insts, 1, "view shows one alias")
  local changed = P.app:sync()
  T.ok(not changed, "a second sync changes nothing")

  -- validation
  local Q = fresh()
  Mock.select({ Q.k, Mock.item(Q.bass, 0, 1, "/s/b.wav") })
  T.ok(not Q.app:group_selected("x"), "items in different folders are refused")
  T.ok(Q.app.msg:find("same folder"), "refusal explains why")
  Mock.select({})
  T.ok(not Q.app:group_selected("x"), "nothing selected is refused")
end

---------------------------------------------------------------------------------------------- move / trim
do
  local P = fresh(); group(P)
  local a = aliases(P)[1]
  Mock.nudge(a, 5); P.app:sync()
  T.eq(P.k.p.D_POSITION, 15, "moving the alias moves kick"); T.eq(P.s.p.D_POSITION, 16, "and snare"); T.eq(P.h.p.D_POSITION, 15, "and hh")
  T.ok(not P.app:sync(), "stable after move")

  Mock.trim_right(a, 16.5); P.app:sync()
  T.eq(P.h.p.D_LENGTH, 1.5, "right trim clips hh"); T.eq(P.s.p.D_LENGTH, 0.5, "and snare")
  T.eq(P.k.p.D_LENGTH, 1, "kick untouched")
  Mock.trim_right(a, 17); P.app:sync()
  T.eq(P.h.p.D_LENGTH, 2, "extending again reveals hh (non-destructive)"); T.eq(P.s.p.D_LENGTH, 1, "and snare")

  Mock.trim_left(a, 15.5); P.app:sync()
  T.eq(P.k.p.D_POSITION, 15.5, "left trim moves kick start"); T.eq(P.k.p.D_LENGTH, 0.5, "kick shortened")
  T.eq(P.k.takes[1].p.D_STARTOFFS, 0.5, "kick source offset follows")
  T.ok(approx(P.k.p.D_FADEINLEN, 0.005), "cut edge gets the short fade")
  Mock.trim_left(a, 15); P.app:sync()
  T.eq(P.k.p.D_LENGTH, 1, "left edge back: kick whole again"); T.eq(P.k.takes[1].p.D_STARTOFFS, 0, "offset back")
  T.eq(n(P.kick) + n(P.snare) + n(P.hh), 3, "never more than one item per member")

  -- trimming everything away of a member deletes it, extending brings it back
  Mock.trim_right(a, 15.5); P.app:sync()
  T.eq(n(P.snare), 0, "snare outside the window is removed")
  Mock.trim_right(a, 17); P.app:sync()
  T.eq(n(P.snare), 1, "snare comes back")
  T.eq(P.snare.items[1].p.D_POSITION, 16, "at the right place")
end

---------------------------------------------------------------------------------------------- split the alias
do
  local P = fresh(); group(P)
  local a = aliases(P)[1]
  Mock.split(a, 11); P.app:sync()
  local al = aliases(P)
  T.eq(#al, 2, "split alias = two aliases")
  T.eq(al[2].takes[1].p.D_STARTOFFS, 1, "right alias carries its window offset")
  T.eq(n(P.kick), 1, "kick once"); T.eq(n(P.snare), 1, "snare once"); T.eq(n(P.hh), 2, "hh split in two")
  T.ok(approx(sum_len(P.hh), 2), "hh pieces cover the original")
  T.eq(#P.app.view[1].insts, 2, "view: two aliases")
  T.ok(al[2].ext.AT_i ~= nil, "right alias tagged")
  T.ok(not P.app:sync(), "stable after split")
  -- move the right piece: only its members move
  Mock.nudge(al[2], 4); P.app:sync()
  T.eq(P.s.p.D_POSITION, 15, "snare follows the right alias")
  T.eq(P.k.p.D_POSITION, 10, "kick stays with the left alias")
  T.eq(Mock.all_guids(), 0, "no duplicate GUIDs")
end

---------------------------------------------------------------------------------------------- cutting a member cuts the alias
do
  local P = fresh(); group(P)
  Mock.split(P.h, 11)                          -- S key on the hh item only
  P.app:sync()
  local al = aliases(P)
  T.eq(#al, 2, "member split cuts the alias")
  T.eq(al[1].p.D_LENGTH, 1, "left alias ends at the cut"); T.eq(al[2].p.D_POSITION, 11, "right alias starts at the cut")
  T.eq(n(P.hh), 2, "hh pieces adopted, not duplicated"); T.eq(n(P.kick), 1, "kick once"); T.eq(n(P.snare), 1, "snare once")
  for _, it in ipairs(P.hh.items) do T.ok(it.ext.AT_m ~= nil, "every hh piece is a member") end
  T.ok(not P.app:sync(), "stable after member cut")

  -- a cut through a member that spans the cut on other tracks splits those too
  local Q = fresh(); group(Q)
  Mock.item(Q.kick, 30, 1, "/s/other.wav")    -- unrelated item, must be left alone
  Mock.split(Q.h, 10.5); Q.app:sync()
  T.eq(#aliases(Q), 2, "cut at 10.5"); T.eq(n(Q.kick), 3, "kick split by the alias cut (2) + the unrelated item")
  T.eq(Q.kick.items[1].p.D_LENGTH, 0.5, "left kick piece")
end

---------------------------------------------------------------------------------------------- razor
do
  -- through every member track: the alias loses the same range
  local P = fresh(); group(P)
  Mock.razor_delete({ P.kick, P.snare, P.hh }, 10.5, 11.5)
  P.app:sync()
  local al = aliases(P)
  T.eq(#al, 2, "razor through all members: two aliases left")
  T.eq(al[1].p.D_POSITION + al[1].p.D_LENGTH, 10.5, "left alias ends at razor start")
  T.eq(al[2].p.D_POSITION, 11.5, "right alias starts at razor end")
  T.eq(n(P.kick) + n(P.snare) + n(P.hh), 4, "kick-left, snare-right, hh two pieces")
  T.ok(not P.app:sync(), "stable after razor")

  -- including the alias lane: same result
  local Q = fresh(); group(Q)
  Mock.razor_delete({ Q.lane, Q.kick, Q.snare, Q.hh }, 10.5, 11.5)
  Q.app:sync()
  T.eq(#aliases(Q), 2, "razor incl. lane: two aliases")
  T.eq(n(Q.kick) + n(Q.snare) + n(Q.hh), 4, "same members")

  -- on one track only: the middle alias is MIXED (its hh piece was deleted)
  local R = fresh(); group(R)
  Mock.razor_delete({ R.hh }, 10.5, 11.5)
  R.app:sync()
  T.eq(#aliases(R), 3, "razor on one track: three aliases")
  local mixed = 0
  for _, x in ipairs(R.app.view[1].insts) do if x.mixed > 0 then mixed = mixed + 1; T.eq(x.reasons[1], "missing", "reason = deleted") end end
  T.eq(mixed, 1, "exactly the middle alias is mixed")
  -- Apply: the group loses that part of hh
  local mid
  for _, x in ipairs(R.app.view[1].insts) do if x.mixed > 0 then mid = x.iid end end
  R.app:request(R.app.view[1].gid, mid, "apply")
  mixed = 0
  for _, x in ipairs(R.app.view[1].insts) do mixed = mixed + x.mixed end
  T.eq(mixed, 0, "apply clears the mixed state")
end

---------------------------------------------------------------------------------------------- linked copies
do
  local P = fresh(); group(P)
  local a = aliases(P)[1]
  local c = Mock.copy(a, P.lane, 20); P.app:sync()
  T.eq(#aliases(P), 2, "copy = second alias")
  T.eq(n(P.kick), 2, "kick materialised for the copy"); T.eq(n(P.hh), 2, "hh too")
  local kc
  for _, it in ipairs(P.kick.items) do if it ~= P.k then kc = it end end
  T.eq(kc.p.D_POSITION, 20, "copy's kick at the copy position")
  T.ok(kc.guid ~= P.k.guid and kc.takes[1].guid ~= P.k.takes[1].guid, "fresh item and take GUIDs")
  T.eq(Mock.all_guids(), 0, "no duplicate GUIDs after copy")

  -- edit in the copy -> original follows
  Mock.set(kc, "D_VOL", 0.5); P.app:sync()
  T.eq(P.k.p.D_VOL, 0.5, "volume edit propagates to the linked original")
  local sc
  for _, it in ipairs(P.snare.items) do if it ~= P.s then sc = it end end
  Mock.nudge(sc, -0.25); P.app:sync()
  T.eq(P.s.p.D_POSITION, 10.75, "moving a member inside the copy moves it in the original")
  Mock.nudge(sc, 0.5); P.app:sync()
  T.eq(P.app.view[1].insts[2].reasons[1], "outside_window", "pushing it past the alias end = mixed, not propagated")
  T.eq(P.s.p.D_POSITION, 10.75, "original untouched by the mixed edit")
  P.app:request(P.app.view[1].gid, P.app.view[1].insts[2].iid, "revert")
  T.eq(sc.p.D_POSITION, 20.75, "revert puts it back")
  T.ok(not P.app:sync(), "stable after propagation")

  -- copying alias + members together is adopted, not doubled
  local Q = fresh(); group(Q)
  local qa = aliases(Q)[1]
  Mock.copy(qa, Q.lane, 30); Mock.copy(Q.k, Q.kick, 30); Mock.copy(Q.s, Q.snare, 31); Mock.copy(Q.h, Q.hh, 30)
  Q.app:sync()
  T.eq(n(Q.kick) + n(Q.snare) + n(Q.hh), 6, "copied members adopted, none created twice")
end

---------------------------------------------------------------------------------------------- unique copies (COPIES lane)
do
  local P = fresh(); group(P)
  local a = aliases(P)[1]
  Mock.copy(a, P.lane, 20); P.app:sync()
  local g = P.app.view[1]
  local copy_iid = g.insts[2].iid
  P.app:make_unique(g.gid, copy_iid)
  local copies = Mock.track_named("COPIES · Beat")
  T.ok(copies ~= nil, "COPIES lane created")
  local st, depth = Mock.structure()
  T.eq(st[3], "  COPIES · Beat", "COPIES lane right below the ALIAS lane"); T.eq(depth, 0, "folder still balanced")
  T.eq(#Mock.items_on(copies), 1, "alias moved to the COPIES lane")
  T.ok(Mock.items_on(copies)[1].takes[1].name:find("#"), "unique alias is numbered")
  local kc
  for _, it in ipairs(P.kick.items) do if it ~= P.k then kc = it end end
  Mock.set(kc, "D_VOL", 0.25); P.app:sync()
  T.eq(P.k.p.D_VOL, 1, "edit in the unique copy does NOT reach the original")
  -- copy of the unique alias forks from IT, not from the group
  local u = Mock.items_on(copies)[1]
  Mock.copy(u, copies, 40); P.app:sync()
  local k40
  for _, it in ipairs(P.kick.items) do if approx(it.p.D_POSITION, 40) then k40 = it end end
  T.ok(k40 ~= nil and approx(k40.p.D_VOL, 0.25), "copy of a unique alias carries its edits")
  Mock.set(k40, "D_VOL", 0.9); P.app:sync()
  T.eq(kc.p.D_VOL, 0.25, "and is independent of it")
  -- link again
  local vu
  for _, x in ipairs(P.app.view[1].insts) do if approx(x.pos, 20) then vu = x.iid end end
  P.app:relink(P.app.view[1].gid, vu)
  T.eq(kc.p.D_VOL, 1, "relinked alias shows the group again")
end

---------------------------------------------------------------------------------------------- mixed: delete / outside / no propagation
do
  local P = fresh(); group(P)
  Mock.delete(P.s); P.app:sync()
  local x = view_inst(P, 1)
  T.eq(x.mixed, 1, "deleted member = mixed"); T.eq(x.reasons[1], "missing", "reason missing")
  T.eq(n(P.snare), 0, "not silently recreated")
  P.app:request(P.app.view[1].gid, x.iid, "revert")
  T.eq(n(P.snare), 1, "revert recreates it"); T.eq(view_inst(P, 1).mixed, 0, "and clears mixed")

  Mock.move_track(P.k, P.bass); P.app:sync()
  T.eq(view_inst(P, 1).reasons[1], "outside_folder", "member moved out of the folder = mixed")
  P.app:request(P.app.view[1].gid, view_inst(P, 1).iid, "revert")
  T.eq(P.k.track, P.kick, "revert moves it back")

  Mock.move(P.k, 11.9); Mock.set(P.k, "D_LENGTH", 1); P.app:sync()
  T.eq(view_inst(P, 1).reasons[1], "outside_window", "member dragged past the alias end = mixed")
  P.app:request(P.app.view[1].gid, view_inst(P, 1).iid, "apply")
  T.ok(approx(aliases(P)[1].p.D_LENGTH, 2.9), "apply extends the alias to cover it")
  T.eq(view_inst(P, 1).mixed, 0, "not mixed any more")

  local Q = fresh({ propagate = false }); group(Q)
  local qa = aliases(Q)[1]
  Mock.copy(qa, Q.lane, 20); Q.app:sync()
  Mock.set(Q.k, "D_VOL", 0.3); Q.app:sync()
  local vol_copy
  for _, it in ipairs(Q.kick.items) do if it ~= Q.k then vol_copy = it.p.D_VOL end end
  T.eq(vol_copy, 1, "no automatic propagation when switched off")
  T.eq(view_inst(Q, 1).reasons[1], "edited", "edited alias is mixed")
  Q.app:request(Q.app.view[1].gid, view_inst(Q, 1).iid, "apply")
  for _, it in ipairs(Q.kick.items) do if it ~= Q.k then vol_copy = it.p.D_VOL end end
  T.eq(vol_copy, 0.3, "apply pushes the edit to the linked copy")
end

---------------------------------------------------------------------------------------------- delete / flatten / ungroup / detach
do
  local P = fresh(); group(P)
  Mock.delete(aliases(P)[1]); P.app:sync()
  T.eq(n(P.kick) + n(P.snare) + n(P.hh), 0, "deleting the alias deletes its members")

  local Q = fresh({ delete_with_alias = false }); group(Q)
  Mock.delete(aliases(Q)[1]); Q.app:sync()
  T.eq(n(Q.kick), 1, "option: members stay"); T.ok(Q.k.ext.AT_m == nil, "and are released")

  local R = fresh(); group(R)
  R.app:flatten(R.app.view[1].gid, view_inst(R, 1).iid)
  T.eq(#aliases(R), 0, "flatten removes the alias"); T.eq(n(R.kick), 1, "members stay"); T.ok(R.k.ext.AT_m == nil, "untagged")

  local U = fresh(); group(U)
  U.app:ungroup(U.app.view[1].gid)
  T.ok(Mock.track_named("ALIAS · Beat") == nil, "ungroup removes the lane")
  T.eq(n(U.kick) + n(U.snare) + n(U.hh), 3, "members stay"); T.eq(#U.app.view, 0, "no groups left")
  local _, depth = Mock.structure(); T.eq(depth, 0, "folder balanced after ungroup")

  local D = fresh(); group(D)
  D.app:detach_all()
  T.ok(D.lane.ext.AT_lane == nil and D.k.ext.AT_m == nil, "detach removes every tag"); T.eq(#aliases(D), 1, "items stay")
end

---------------------------------------------------------------------------------------------- push / add / remove
do
  local P = fresh(); group(P)
  Mock.copy(aliases(P)[1], P.lane, 20); P.app:sync()
  P.k.takes[1].fx = { { name = "ReaEQ", id = Mock.guid() } }
  Mock.select({ P.k }); P.app:push_selected()
  local other
  for _, it in ipairs(P.kick.items) do if it ~= P.k then other = it end end
  T.eq(#other.takes[1].fx, 1, "pushed FX reaches the linked copy")
  T.ok(other.takes[1].fx[1].id ~= P.k.takes[1].fx[1].id, "with its own FX GUID")
  T.eq(n(P.kick), 2, "rebuilt, not doubled")

  local extra = Mock.item(P.kick, 11.2, 0.3, "/s/kick2.wav")
  Mock.select({ extra }); P.app:add_selected()
  T.ok(extra.ext.AT_m ~= nil, "added item is a member")
  T.eq(n(P.kick), 4, "and appears in the linked copy too")
  Mock.select({ extra }); P.app:remove_selected()
  T.eq(n(P.kick), 3, "removing takes it out of the copy"); T.ok(extra.ext.AT_m == nil, "the item itself stays, untagged")
end

---------------------------------------------------------------------------------------------- undo modes & tick
do
  local P = fresh({ undo_mode = "steps" }); group(P)
  local before = #Mock.S.undo
  Mock.nudge(aliases(P)[1], 1); P.app:sync()
  T.eq(#Mock.S.undo, before + 1, "steps mode: sync is an undo point")
  T.eq(Mock.S.undo[#Mock.S.undo], "AliasTrack: sync", "labelled")
  -- simulate: user pressed undo once (our sync step is now on the redo stack)
  Mock.S.redo = "AliasTrack: sync"
  Mock.nudge(aliases(P)[1], 1)
  Mock.S.clock = 100; P.app:tick()
  Mock.S.clock = 101; P.app:tick()
  T.ok(P.app.paused, "paused while our step is on the redo stack")
  T.eq(P.k.p.D_POSITION, 11, "nothing synced while paused")
  Mock.S.redo = nil; Mock.nudge(aliases(P)[1], 0)
  Mock.S.clock = 102; P.app:tick(); Mock.S.clock = 103; P.app:tick()
  T.ok(not P.app.paused, "resumes after a new edit"); T.eq(P.k.p.D_POSITION, 12, "and syncs")

  local Q = fresh(); group(Q)
  local before_q = #Mock.S.undo
  Mock.nudge(aliases(Q)[1], 1); Q.app:sync()
  T.eq(#Mock.S.undo, before_q, "silent mode: no undo point for syncs")
  T.ok(Mock.S.dirty > 0, "but the project is marked modified")

  -- debounce: no sync while changes keep coming
  local R = fresh(); group(R)
  Mock.S.clock = 10; R.app:tick()
  Mock.nudge(aliases(R)[1], 1); Mock.S.clock = 10.1; R.app:tick()
  T.eq(R.k.p.D_POSITION, 10, "debounced: not yet")
  Mock.S.clock = 10.5; R.app:tick()
  T.eq(R.k.p.D_POSITION, 11, "after the pause: synced")

  -- frozen: nothing changes
  local F = fresh({ live = false }); group(F)
  Mock.nudge(aliases(F)[1], 3); Mock.S.clock = 50; F.app:tick(); Mock.S.clock = 60; F.app:tick()
  T.eq(F.k.p.D_POSITION, 10, "frozen: members stay")
end

---------------------------------------------------------------------------------------------- robustness
do
  local P = fresh(); group(P)
  -- a duplicated lane track (Track > Duplicate) is released
  local dup = Mock.track("ALIAS · Beat copy", 0)
  dup.ext.AT_lane = P.lane.ext.AT_lane; dup.ext.AT_group = P.lane.ext.AT_group
  P.app:sync()
  T.ok(dup.ext.AT_lane == nil, "duplicate lane released"); T.eq(#P.app.view, 1, "still one group")
  -- something that is not an alias on the lane is ignored
  Mock.item(P.lane, 50, 1, "/s/oops.wav"); P.app:sync()
  T.eq(P.app.view[1].foreign, 1, "foreign item on lane reported")
  -- two groups in the same folder
  local k2 = Mock.item(P.kick, 40, 1, "/s/k2.wav")
  Mock.select({ k2 }); T.ok(P.app:group_selected("Fill"), "second group in the same folder")
  T.eq(#P.app.view, 2, "two groups")
  Mock.nudge(aliases(P)[1], 1); P.app:sync()
  T.eq(k2.p.D_POSITION, 40, "groups are independent")
  T.eq(P.k.p.D_POSITION, 11, "first group moved")
  -- a group made of a MIDI member
  local m = Mock.item(P.snare, 60, 1, nil, { midi = true, name = "notes" })
  Mock.select({ m }); P.app:group_selected("Keys")
  local keys = Mock.track_named("ALIAS · Keys")
  Mock.copy(Mock.items_on(keys)[1], keys, 70); P.app:sync()
  local mc
  for _, it in ipairs(P.snare.items) do if approx(it.p.D_POSITION, 70) then mc = it end end
  T.ok(mc and mc.takes[1].pool == m.takes[1].pool, "linked MIDI copy stays pooled")
end

T.done("test_sync")
