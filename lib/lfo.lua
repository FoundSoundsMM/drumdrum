-- drumdrum / lfo
--
-- Two LFOs a track, each patched to one parameter of its own track.
--
-- Patching happens on the grid: hold an LFO button and a TONE, SAMPLE,
-- NOISE or COLOUR button together, then turn E2 or E3 to patch that side.
-- Turning on moves the depth. CLEAR + the LFO unpatches it.
--
-- Rate, depth and shape are params (so they save and MIDI-map); the patch
-- point is saved in the pattern data. Modulation is added to the target's
-- normalised value, so depth 1 swings it half the range either way.

local S = include("drumdrum/lib/spec")

local L = {}

L.st = {}

function L.init()
  for t = 1, S.NTRACKS do
    L.st[t] = {}
    for i = 1, 2 do
      L.st[t][i] = { phase = (i - 1) * 0.5, val = 0, sh = 0,
                     d0 = 0, d1 = math.random() * 2 - 1, target = nil }
    end
  end
end

local function pid(t, i, k) return "t" .. t .. "_l" .. i .. "_" .. k end

function L.rate(t, i) return params:get(pid(t, i, "rate")) end
function L.depth(t, i) return params:get(pid(t, i, "depth")) end
function L.shape(t, i) return math.floor(params:get(pid(t, i, "shape")) + 0.5) end

-- a shape's value at phase ph, -1..1. S+H and DRIFT read their held state.
function L.wave(shape, ph, o)
  if shape == 1 then return math.sin(ph * 2 * math.pi)
  elseif shape == 2 then return 1 - (4 * math.abs(ph - 0.5))
  elseif shape == 3 then return (ph * 2) - 1
  elseif shape == 4 then return (ph < 0.5) and 1 or -1
  elseif shape == 5 then return o and o.sh or 0
  else
    -- DRIFT: a cosine glide from one random point to the next, once a cycle
    local a, b = o and o.d0 or 0, o and o.d1 or 0
    local k = (1 - math.cos(ph * math.pi)) * 0.5
    return a + ((b - a) * k)
  end
end

function L.step(dt)
  for t = 1, S.NTRACKS do
    for i = 1, 2 do
      local o = L.st[t][i]
      o.phase = o.phase + (L.rate(t, i) * dt)
      if o.phase >= 1 then
        o.phase = o.phase % 1
        o.sh = (math.random() * 2) - 1
        o.d0 = o.d1
        o.d1 = (math.random() * 2) - 1
      end
      o.val = L.wave(L.shape(t, i), o.phase, o)
    end
  end
end

local function key_of(target)
  return target and (target.btn .. target.side) or nil
end

-- the summed offset on one key of one track, in normalised units
function L.mod(t, key)
  local m = 0
  local lt = L.st[t]
  if not lt then return 0 end
  for i = 1, 2 do
    local o = lt[i]
    if o.target and key_of(o.target) == key then
      m = m + (o.val * L.depth(t, i) * 0.5)
    end
  end
  return m
end

function L.targets(t, key)
  local lt = L.st[t]
  if not lt then return false end
  return key_of(lt[1].target) == key or key_of(lt[2].target) == key
end

-- does LFO i on track t point at button btn? returns "a", "b" or nil
function L.side_on(t, i, btn)
  local tg = L.st[t][i].target
  if tg and tg.btn == btn then return tg.side end
  return nil
end

-- point LFO i of track t at one side of a button; false if that side
-- cannot be modulated (S1's sample select)
function L.set_target(t, i, btn, side)
  local pair = S.pair(t, btn)
  if not pair or pair[side].nomod then return false end
  L.st[t][i].target = { btn = btn, side = side }
  return true
end

function L.unpatch(t, i)
  L.st[t][i].target = nil
end

function L.target_name(t, i)
  local tg = L.st[t][i].target
  if not tg then return nil end
  local p = S.pair(t, tg.btn)[tg.side]
  return tg.btn .. " " .. p.name
end

function L.save(t)
  local out = {}
  for i = 1, 2 do
    local tg = L.st[t][i].target
    out[i] = tg and { btn = tg.btn, side = tg.side } or false
  end
  return out
end

function L.load(t, d)
  for i = 1, 2 do
    local tg = d[i]
    L.st[t][i].target = (tg and S.BTN[tg.btn]) and { btn = tg.btn, side = tg.side } or nil
  end
end

return L
