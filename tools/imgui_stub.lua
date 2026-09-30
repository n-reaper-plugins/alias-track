-- Stub of ReaImGui: records calls, returns harmless defaults. `clicks[label]=true` makes that button report a click.
local M = {}
function M.install(R)
  local st = { calls = {}, clicks = {}, texts = {}, drop = nil, input_text = nil, deact = false }
  local special = {
    ImGui_CreateContext = function() return "ctx" end,
    ImGui_Begin = function() return true, true end,
    ImGui_BeginTable = function() return true end,
    ImGui_GetContentRegionAvail = function() return 600, 400 end,
    ImGui_InputText = function(_, _, buf) if st.input_text then local v = st.input_text; st.input_text = nil; return true, v end return false, buf end,
    ImGui_InputInt = function(_, _, v) return false, st.seed_value or v end,
    ImGui_IsItemDeactivatedAfterEdit = function() local d = st.deact; st.deact = false; return d end,
    ImGui_Button = function(_, label)
      st.calls[#st.calls + 1] = "Button:" .. label
      local base = label:gsub("##.*$", ""):gsub("\n.*$", "")
      if st.clicks[base] then st.clicks[base] = nil; return true end
      return false
    end,
    ImGui_SmallButton = function(_, label)
      st.calls[#st.calls + 1] = "SmallButton:" .. label
      local base = label:gsub("##.*$", "")
      if st.clicks[base] then st.clicks[base] = nil; return true end
      return false
    end,
    ImGui_Checkbox = function(_, label, v)
      if st.clicks[label] then st.clicks[label] = nil; return true, not v end
      return false, v
    end,
    ImGui_Text = function(_, t) st.texts[#st.texts + 1] = t end,
    ImGui_TextColored = function(_, c, t) st.texts[#st.texts + 1] = t; st.last_color = st.last_color or {}; st.last_color[t] = c end,
    ImGui_BeginDragDropTarget = function() return st.drop ~= nil end,
    ImGui_AcceptDragDropPayloadFiles = function() return true, 1 end,
    ImGui_GetDragDropPayloadFile = function() local d = st.drop; st.drop = nil; return true, d end,
    ImGui_IsItemClicked = function() return false end,
  }
  setmetatable(R, { __index = function(_, k)
    if type(k) ~= "string" or not k:match("^ImGui_") then return nil end
    if special[k] then return special[k] end
    if k:match("^ImGui_%a+Flags_") or k:match("^ImGui_Cond_") then return function() return 0 end end
    return function() return false end
  end })
  return st
end
return M
