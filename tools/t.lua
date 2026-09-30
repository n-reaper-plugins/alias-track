-- tiny test helper
local T = { n = 0, fail = 0 }
function T.ok(cond, msg) T.n = T.n + 1; if not cond then T.fail = T.fail + 1; print("FAIL: " .. msg) end end
function T.eq(a, b, msg) T.ok(a == b, string.format("%s (got %s, want %s)", msg, tostring(a), tostring(b))) end
function T.done(name) print(string.format("%s: %d checks, %d failed", name, T.n, T.fail)); os.exit(T.fail == 0 and 0 or 1) end
return T
