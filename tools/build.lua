-- Build:  lua tools/build.lua        (run from the project root)
-- Output: dist/AliasTrack.lua = the ONE file users need
package.path = "./src/?.lua;" .. package.path
local V = require("ATVersion").VERSION

local function read(p) local f = assert(io.open(p, "rb"), "cannot read " .. p); local s = f:read("*a"); f:close(); return s end
local function write(p, s) local f = assert(io.open(p, "wb"), "cannot write " .. p); f:write(s); f:close() end

local function bundle(main, modules, out)
  local src = read("src/" .. main .. ".lua"):gsub("@@VERSION@@", V)
  local header, body = {}, src
  while true do
    local line, rest = body:match("^([^\n]*)\n(.*)$")
    if line and line:match("^%-%-") then header[#header + 1] = line; body = rest else break end
  end
  local parts = { table.concat(header, "\n"),
    "-- BUNDLED BUILD of " .. main .. " v" .. V .. " - edit the files in src/, not this one.",
    "local __preload = package.preload" }
  for _, m in ipairs(modules) do
    parts[#parts + 1] = string.format('__preload["%s"] = function(...)\n%s\nend', m, read("src/" .. m .. ".lua"))
  end
  parts[#parts + 1] = body
  os.execute("mkdir -p dist")
  write("dist/" .. out, table.concat(parts, "\n") .. "\n")
  print("built dist/" .. out .. " v" .. V)
end

bundle("AliasTrack", { "ATVersion", "ATCore", "ATReaper", "ATApp", "ATUI" }, "AliasTrack.lua")
