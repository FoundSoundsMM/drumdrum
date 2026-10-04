-- drumdrum / perform
--
-- The PERFORM page (SHIFT + MIX): sixty-four punch-in effects, after the TE
-- EP-133's and OP-XY's. Rows 1-4 are eight strips of eight pads, one
-- effect a strip, its pads getting stronger (or shorter) to the right:
--
--          columns 1-8                       columns 9-16
--   row 1  REPEAT    1/4 .. 1/64             GATE   1/8 .. 1/128
--   row 2  LOWPASS   5k .. 180 Hz            HIGHPASS  150 Hz .. 6k
--   row 3  SPEED     stops, half, reverse..  CRUSH  12 bit .. 3 bit
--   row 4  ECHO      1/32 .. 1/2             DROP   tracks out
--
-- A pad works while it is held. Strips stack: hold REPEAT and LOWPASS
-- together and the repeat is filtered, in the engine's fixed order whatever
-- order they were pressed in. Within a strip the newest pad wins, and
-- letting it go hands back to one still held. SHIFT + pad latches it;
-- the same again lets go. CLEAR + a pad lets go of its strip's latch, CLEAR
-- on its own of every latch.
--
-- The timed pads are worked out from the tempo when pressed and sit on the
-- beat grid: REPEAT loops from the last line of its own length, so its
-- first pass is what was playing anyway and the loop is always on the grid,
-- and GATE counts its chops from the bar.
--
-- TAPE is the hidden one: SHIFT + COLOUR, held. It loops the last LENGTH of
-- the mix and varispeeds it to PITCH, both on E2/E3 while it is held.

local F = {}
local St

-- the engine's stages, in signal order (see PERFORM in the engine)
local REPEAT, SPEED, TAPE, GATE, CRUSH, LPF, HPF, ECHO = 0, 1, 2, 3, 4, 5, 6, 7

local function bs() return clock.get_beat_sec() end
local function beats() return clock.get_beats() end

-- note values, the way the track speeds are named: a beat is a quarter
local function loop_pad(label, b)
  return { label = label, args = function()
    local L = b * bs()
    local since = (beats() % b) * bs()
    return "loop", since, L, since, 1
  end }
end

local function gate_pad(label, b)
  -- c is kept from the first press, so a new chop length stays on the grid
  return { label = label, args = function(prev)
    return "gate", b, bs(), prev and prev[4] or (beats() % 4), 0.5
  end }
end

local function filt_pad(def, hz)
  local label = (hz >= 1000) and string.format("%.1fk", hz / 1000) or tostring(hz)
  return { label = label, args = function() return def, hz, 0.45, 0, 0 end }
end

local function crush_pad(bits, rate)
  return { label = bits .. "b", args = function() return "crush", bits, rate, 0, 0 end }
end

local function echo_pad(label, b)
  return { label = label, args = function()
    local t = math.min(b * bs(), 1.95)
    local fb = (b < 0.25) and 0.7 or 0.62
    return "echo", t, fb, util.clamp(t * 14, 1.5, 10), 0
  end }
end

-- DROP: which tracks a pad takes out, BD1 BD2 CLP SNR PRC1 PRC2 HAT CYM
local function drop_pad(label, out)
  return { label = label, drop = out }
end

F.STRIPS = {
  { name = "REPEAT", stage = REPEAT, pads = {
    loop_pad("1/4", 1), loop_pad("3/16", 3 / 4), loop_pad("1/8", 1 / 2),
    loop_pad("1/8T", 1 / 3), loop_pad("1/16", 1 / 4), loop_pad("1/16T", 1 / 6),
    loop_pad("1/32", 1 / 8), loop_pad("1/64", 1 / 16) } },
  { name = "GATE", stage = GATE, settable = true, pads = {
    gate_pad("1/8", 1 / 2), gate_pad("1/8T", 1 / 3), gate_pad("1/16", 1 / 4),
    gate_pad("1/16T", 1 / 6), gate_pad("1/32", 1 / 8), gate_pad("1/32T", 1 / 12),
    gate_pad("1/64", 1 / 16), gate_pad("1/128", 1 / 32) } },
  { name = "LOWPASS", stage = LPF, settable = true, pads = {
    filt_pad("lpf", 5000), filt_pad("lpf", 3200), filt_pad("lpf", 2000),
    filt_pad("lpf", 1300), filt_pad("lpf", 800), filt_pad("lpf", 500),
    filt_pad("lpf", 300), filt_pad("lpf", 180) } },
  { name = "HIGHPASS", stage = HPF, settable = true, pads = {
    filt_pad("hpf", 150), filt_pad("hpf", 300), filt_pad("hpf", 500),
    filt_pad("hpf", 800), filt_pad("hpf", 1300), filt_pad("hpf", 2000),
    filt_pad("hpf", 3500), filt_pad("hpf", 6000) } },
  -- SPEED: tape stops of three lengths, a drop to half speed, the last
  -- beat or half beat backwards, the last half beat an octave up, and a
  -- record spun back
  { name = "SPEED", stage = SPEED, pads = {
    { label = "STOP 2", args = function() return "stop", 2 * bs(), 0, 0, 0 end },
    { label = "STOP 1", args = function() return "stop", bs(), 0, 0, 0 end },
    { label = "STOP.5", args = function() return "stop", 0.5 * bs(), 0, 0, 0 end },
    { label = "HALF", args = function() return "stop", 0.15, 0.5, 0, 0 end },
    { label = "REV 1", args = function()
      local L = bs()
      return "loop", L, L, L * 0.999, -1 end },
    { label = "REV.5", args = function()
      local L = bs() * 0.5
      return "loop", L, L, L * 0.999, -1 end },
    { label = "OCT UP", args = function()
      local L = bs() * 0.5
      return "loop", L, L, 0, 2 end },
    { label = "SPIN", args = function() return "stop", bs(), -4, 0, 0 end } } },
  { name = "CRUSH", stage = CRUSH, settable = true, pads = {
    crush_pad(12, 16000), crush_pad(10, 11025), crush_pad(8, 8000), crush_pad(7, 6000),
    crush_pad(6, 4000), crush_pad(5, 3000), crush_pad(4, 2000), crush_pad(3, 1200) } },
  { name = "ECHO", stage = ECHO, pads = {
    echo_pad("1/32", 1 / 8), echo_pad("1/16", 1 / 4), echo_pad("1/8T", 1 / 3),
    echo_pad("1/8", 1 / 2), echo_pad("3/16", 3 / 4), echo_pad("1/4", 1),
    echo_pad("3/8", 3 / 2), echo_pad("1/2", 2) } },
  { name = "DROP", pads = {
    drop_pad("NO BD", { 1, 2 }), drop_pad("NO SN", { 3, 4 }),
    drop_pad("NO PRC", { 5, 6 }), drop_pad("NO HAT", { 7, 8 }),
    drop_pad("BD ONLY", { 3, 4, 5, 6, 7, 8 }), drop_pad("BD+SN", { 5, 6, 7, 8 }),
    drop_pad("TOPS", { 1, 2, 3, 4, 5, 6 }), drop_pad("BREAK", { 1, 2, 3, 4, 5, 6, 7, 8 }) } },
}

-- strip f on the grid: rows 1-4, left half then right half
function F.strip_at(x, y)
  if y < 1 or y > 4 then return nil end
  local f = ((y - 1) * 2) + ((x > 8) and 2 or 1)
  return f, ((x - 1) % 8) + 1
end

function F.pad_xy(f, i)
  return (((f - 1) % 2) * 8) + i, math.floor((f - 1) / 2) + 1
end

F.held = {}      -- per strip: the pads physically held, oldest first
F.latched = {}   -- per strip: a latched pad, or nil
F.active = {}    -- per strip: what is sounding, { pad, args }
F.tape = nil     -- the hidden TAPE while held: { args }

function F.init(state)
  St = state
  for f = 1, #F.STRIPS do F.held[f] = {} end
  St.pmute = {}
  for t = 1, 8 do St.pmute[t] = false end
end

-- ------------------------------------------------------------------- sound

local function drop(out)
  local set = {}
  for _, t in ipairs(out or {}) do set[t] = true end
  for t = 1, 8 do
    local m = set[t] or false
    if St.pmute[t] ~= m then
      St.pmute[t] = m
      engine.strip(t - 1, "pmute", m and 1 or 0)
    end
  end
end

-- what strip f should be playing: the newest held pad, else its latch
function F.want(f)
  local h = F.held[f]
  return h[#h] or F.latched[f]
end

-- bring strip f's sound in line with what is held and latched
function F.update(f)
  local s = F.STRIPS[f]
  local want = F.want(f)
  local cur = F.active[f]
  if (cur and cur.pad) == want then return end
  if s.stage == nil then
    drop(want and s.pads[want].drop or nil)
    F.active[f] = want and { pad = want } or nil
  elseif want == nil then
    engine.unpunch(s.stage)
    F.active[f] = nil
  else
    local args = { s.pads[want].args(cur and cur.args) }
    if cur and s.settable then
      engine.punchSet(s.stage, args[2], args[3], args[4], args[5])
    else
      engine.punch(s.stage, args[1], args[2], args[3], args[4], args[5])
    end
    F.active[f] = { pad = want, args = args }
  end
  St.dirty = true
end

-- ------------------------------------------------------------------- pads

function F.press(f, i, shift)
  if shift then
    F.latched[f] = (F.latched[f] ~= i) and i or nil
  else
    local h = F.held[f]
    for k = #h, 1, -1 do if h[k] == i then table.remove(h, k) end end
    h[#h + 1] = i
  end
  F.update(f)
end

function F.release(f, i)
  local h = F.held[f]
  for k = #h, 1, -1 do if h[k] == i then table.remove(h, k) end end
  F.update(f)
end

-- leaving the page: fingers come off, latches stay
function F.release_held()
  for f = 1, #F.STRIPS do
    if #F.held[f] > 0 then
      F.held[f] = {}
      F.update(f)
    end
  end
end

-- CLEAR + pad: that strip's latch off
function F.unlatch(f)
  F.latched[f] = nil
  F.update(f)
end

-- CLEAR on its own: everything off
function F.clear()
  for f = 1, #F.STRIPS do
    F.held[f] = {}
    F.latched[f] = nil
    F.update(f)
  end
end

function F.label(f)
  local a = F.active[f]
  return a and F.STRIPS[f].pads[a.pad].label or nil
end

-- --------------------------------------------------------------- the tape

F.TAPE_LENS = { "1/16", "1/8", "1/4", "1/2", "1 BAR", "2 BAR" }
F.TAPE_BEATS = { 1 / 4, 1 / 2, 1, 2, 4, 8 }

local function tape_args()
  local L = math.min(F.TAPE_BEATS[params:get("tape_len")] * bs(), 25)
  return L, L, 0, 2 ^ (params:get("tape_pitch") / 12)
end

function F.tape_on()
  local a, b, c, d = tape_args()
  engine.punch(TAPE, "loop", a, b, c, d)
  F.tape = true
  St.dirty = true
end

function F.tape_off()
  if not F.tape then return end
  engine.unpunch(TAPE)
  F.tape = nil
  St.dirty = true
end

-- a turn while it is held: the length keeps its end where the press was
local function tape_move()
  if not F.tape then return end
  local a, b, c, d = tape_args()
  engine.punchSet(TAPE, a, b, c, d)
end

function F.add_params()
  params:add_group("dd_perform", "TAPE", 2)
  params:add_control("tape_pitch", "tape pitch",
    controlspec.new(-24, 24, "lin", 1, -12, "st", 1 / 48),
    function(param) return string.format("%+d st", math.floor(param:get() + 0.5)) end)
  params:set_action("tape_pitch", function() tape_move() St.dirty = true end)
  params:add_option("tape_len", "tape length", F.TAPE_LENS, 5)
  params:set_action("tape_len", function() tape_move() St.dirty = true end)
  St.DEFAULTS.tape_pitch = -12
  St.DEFAULTS.tape_len = 5
end

return F
