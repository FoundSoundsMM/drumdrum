-- Prints each voice's default arguments the way lua would send them, one
-- line per voice: "defname arg value ...". Used by check-engine.sh --render.
-- An optional "key=value" list overrides physical values, e.g. t2a=0.9;
-- kit=2, 3 or 4 prints the WOOD, FM or GLITCH voices instead of WARM.
local ROOT = (arg[0]:match("(.*)/tools/") or ".")
function include(path) return dofile(ROOT .. "/" .. path:gsub("^drumdrum/", "") .. ".lua") end
local S = include("drumdrum/lib/spec")
local over = {}
for i = 1, #arg do
  local k, v = arg[i]:match("^(%w+)=(.+)$")
  if k then over[k] = tonumber(v) end
end
local kit = over.kit or 1
over.kit = nil
for t, v in ipairs(S.KIT_VOICES[kit]) do
  local out = { v.def }
  for _, key in ipairs(S.sound_keys()) do
    local p = S.param(t, key, kit)
    if not p.special and not p.strip then
      local val = p.def
      if p.zero then val = val - 1 end
      local a = S.arg(t, key, kit)
      if over[a] then val = over[a] end
      out[#out + 1] = a
      out[#out + 1] = string.format("%.6g", val)
    end
  end
  print(table.concat(out, " "))
end
