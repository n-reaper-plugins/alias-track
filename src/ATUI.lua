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
