-- drumdrum / spec
--
-- Everything the script knows about itself that is not state: the grid
-- layout, the eight voices, and every parameter a control button opens.
--
-- A parameter here is written in PHYSICAL units (Hz, seconds, semitones) and
-- the engine receives physical units. Lua is the only place a range lives, so
-- the screen, the LFOs and the parameter locks all agree on it without a
-- second copy in the SynthDefs drifting away from the first.
--
-- LFOs and locks work in the normalised 0..1 space of each control's
-- controlspec, which is what makes "an LFO at depth 0.3" mean the same amount
-- of movement on a pitch as on a decay.

local S = {}

S.NTRACKS = 8
S.NSTEPS  = 64

-- ---------------------------------------------------------------------- grid
--
--  rows 1-4   the selected track's sequencer, 16 steps a row
--  row  5     divider, unlit
--  rows 6-7   track controls
--  row  8     PLAY STOP SWING . [1 2 3 4 5 6 7 8] . SHIFT MIX COLOUR
--
--         1   2   3   4   5   6   7   8   9  10  11  12  13  14  15  16
--   6    T1  T2  .   S1  S2  .   N1  .  TC1 TC2  .   P1  .   L1  .   C1
--   7    T3  T4  .   S3  S4  .   N2  .  TC3 TC4  .   P2  .   L2  .   C2
--
-- The top-left button of each group is always the most-used pair: T1 is
-- pitch and decay on every voice, S1 is which sample and how loud.

S.SEQ_ROWS = 4
S.CTRL_ROW = 6

S.BTN = {
  T1  = { x = 1,  y = 6, kind = "tone",  label = "TONE 1" },
  T2  = { x = 2,  y = 6, kind = "tone",  label = "TONE 2" },
  T3  = { x = 1,  y = 7, kind = "tone",  label = "TONE 3" },
  T4  = { x = 2,  y = 7, kind = "tone",  label = "TONE 4" },
  S1  = { x = 4,  y = 6, kind = "smp",   label = "SAMPLE 1" },
  S2  = { x = 5,  y = 6, kind = "smp",   label = "SAMPLE 2" },
  S3  = { x = 4,  y = 7, kind = "smp",   label = "SAMPLE 3" },
  S4  = { x = 5,  y = 7, kind = "smp",   label = "SAMPLE 4" },
  N1  = { x = 7,  y = 6, kind = "noise", label = "NOISE 1" },
  N2  = { x = 7,  y = 7, kind = "noise", label = "NOISE 2" },
  TC1 = { x = 9,  y = 6, kind = "trig",  label = "TRIG 1" },
  TC2 = { x = 10, y = 6, kind = "trig",  label = "TRIG 2" },
  TC3 = { x = 9,  y = 7, kind = "trig",  label = "TRIG 3" },
  TC4 = { x = 10, y = 7, kind = "trig",  label = "TRIG 4" },
  P1  = { x = 12, y = 6, kind = "pulse", label = "PULSE 1" },
  P2  = { x = 12, y = 7, kind = "pulse", label = "PULSE 2" },
  L1  = { x = 14, y = 6, kind = "lfo",   label = "LFO 1", lfo = 1 },
  L2  = { x = 14, y = 7, kind = "lfo",   label = "LFO 2", lfo = 2 },
  C1  = { x = 16, y = 6, kind = "col",   label = "COLOUR 1" },
  C2  = { x = 16, y = 7, kind = "col",   label = "COLOUR 2" },
}

-- (x, y) -> button id
S.BTN_AT = {}
for id, b in pairs(S.BTN) do
  b.id = id
  S.BTN_AT[b.x * 10 + b.y] = id
end
function S.btn_at(x, y) return S.BTN_AT[x * 10 + y] end

-- the kinds whose parameters are sound: lockable to a step, LFO destinations
S.SOUND_KIND = { tone = true, smp = true, noise = true, col = true }
-- the kinds whose parameters belong to a step rather than to the track
S.STEP_KIND = { trig = true, pulse = true }

S.ROW8 = { play = 1, stop = 2, swing = 3, track0 = 4, shift = 14, mix = 15, colour = 16 }

-- ------------------------------------------------------------------ helpers

local function P(name, lo, hi, warp, def, unit, extra)
  local p = { name = name, lo = lo, hi = hi, warp = warp or "lin", def = def,
              unit = unit or "" }
  if extra then for k, v in pairs(extra) do p[k] = v end end
  return p
end
local function INT(name, lo, hi, def, unit, extra)
  local e = { step = 1 }
  if extra then for k, v in pairs(extra) do e[k] = v end end
  return P(name, lo, hi, "lin", def, unit, e)
end
local function OPT(name, opts, def, extra)
  local e = { step = 1, opts = opts }
  if extra then for k, v in pairs(extra) do e[k] = v end end
  return P(name, 1, #opts, "lin", def, "", e)
end
S.P, S.INT, S.OPT = P, INT, OPT

-- What a value looks like on the screen. Short: the overlay gives each value
-- half the width of a 128px display.
function S.fmt(p, v)
  if p.opts then return p.opts[math.floor(v + 0.5)] or "-" end
  if p.fmtf then return p.fmtf(v) end
  local u = p.unit
  if u == "Hz" then
    if v >= 1000 then return string.format("%.1fk", v / 1000) end
    return string.format("%.0f Hz", v)
  elseif u == "s" then
    if v < 1 then return string.format("%.0f ms", v * 1000) end
    return string.format("%.2f s", v)
  elseif u == "ms" then
    return string.format("%.0f ms", v)
  elseif u == "st" then
    return string.format("%+.1f st", v)
  elseif u == "oct" then
    return string.format("%.1f oct", v)
  elseif u == "%" then
    return string.format("%d%%", math.floor(v + 0.5))
  elseif u == "bi" then
    return string.format("%+.2f", v)
  end
  if p.step then return string.format("%d%s", math.floor(v + 0.5), u) end
  return string.format("%.2f", v)
end

-- ------------------------------------------------------------------- voices
--
-- Each voice has four TONE buttons of two parameters: t1a t1b ... t4b, which
-- are also the SynthDef argument names. T1 is always PITCH / DECAY. T4b is
-- always LEVEL, the synth layer's own level against the sample layer.

local function pct(v) return string.format("%d%%", math.floor(v * 100 + 0.5)) end

local MATERIAL = function(v)
  local names = { "SKIN", "WOOD", "BAR", "BELL" }
  local i = math.min(math.floor(v * 3 + 0.5), 3) + 1
  return names[i] .. string.format(" %d", math.floor(v * 100 + 0.5))
end

local FOLD = function(v)
  local n = (v < 0.34) and "CLEAN" or ((v < 0.67) and "METAL" or "DIRTY")
  return n .. " " .. math.floor(v * 100 + 0.5)
end

S.VOICES = {
  {
    name = "BD1", desc = "smooth 808 body", def = "dd_bd1", choke = true,
    smp = "BD",
    tone = {
      T1 = { a = P("PITCH", 30, 110, "exp", 47, "Hz"),
             b = P("DECAY", 0.08, 3, "exp", 0.7, "s") },
      T2 = { a = P("SWEEP", 0, 4, "lin", 1.6, "oct"),
             b = P("S.TIME", 0.004, 0.3, "exp", 0.045, "s") },
      T3 = { a = P("PUNCH", 0, 1, "lin", 0.35, "", { fmtf = pct }),
             b = P("BODY", 0, 1, "lin", 0.3, "", { fmtf = pct }) },
      T4 = { a = P("TONE", 200, 14000, "exp", 4000, "Hz"),
             b = P("LEVEL", 0, 1, "lin", 0.8, "", { fmtf = pct }) },
    },
  },
  {
    name = "BD2", desc = "tube-driven thump", def = "dd_bd2", choke = true,
    smp = "BD",
    tone = {
      T1 = { a = P("PITCH", 35, 160, "exp", 55, "Hz"),
             b = P("DECAY", 0.05, 2, "exp", 0.45, "s") },
      T2 = { a = P("SWEEP", 0, 5, "lin", 2.5, "oct"),
             b = P("S.TIME", 0.003, 0.25, "exp", 0.03, "s") },
      T3 = { a = P("TUBE", 0, 1, "lin", 0.55, "", { fmtf = pct }),
             b = P("BIAS", 0, 0.8, "lin", 0.25, "", { fmtf = pct }) },
      T4 = { a = P("SHAPE", 0, 1, "lin", 0.3, "", { fmtf = function(v)
               local n = (v < 0.25) and "SINE" or ((v < 0.75) and "TRI" or "PULSE")
               return n .. " " .. math.floor(v * 100 + 0.5) end }),
             b = P("LEVEL", 0, 1, "lin", 0.7, "", { fmtf = pct }) },
    },
  },
  {
    name = "CLP", desc = "grain clap", def = "dd_clp", choke = false,
    smp = "CP",
    tone = {
      T1 = { a = P("TONE", 500, 5000, "exp", 1300, "Hz"),
             b = P("DECAY", 0.04, 1.5, "exp", 0.28, "s") },
      T2 = { a = P("SPREAD", 0.003, 0.03, "exp", 0.011, "s"),
             b = INT("GRAINS", 1, 6, 4) },
      T3 = { a = P("SIZZLE", 0, 1, "lin", 0.3, "", { fmtf = pct }),
             b = P("WIDTH", 0.15, 2, "exp", 0.6, "", { fmtf = function(v)
               return string.format("%.2f", v) end }) },
      T4 = { a = P("SNAP", 0, 1, "lin", 0.4, "", { fmtf = pct }),
             b = P("LEVEL", 0, 1, "lin", 0.75, "", { fmtf = pct }) },
    },
  },
  {
    name = "SNR", desc = "tight snare", def = "dd_snr", choke = true,
    smp = "SD",
    tone = {
      T1 = { a = P("PITCH", 110, 420, "exp", 185, "Hz"),
             b = P("DECAY", 0.03, 0.8, "exp", 0.16, "s") },
      T2 = { a = P("SNAP", 0, 1.5, "lin", 0.8, "", { fmtf = pct }),
             b = P("WIRES", 0.03, 1, "exp", 0.2, "s") },
      T3 = { a = P("W.TONE", 1200, 10000, "exp", 4500, "Hz"),
             b = P("RING", 0, 1, "lin", 0.25, "", { fmtf = pct }) },
      T4 = { a = P("CRACK", 0, 1, "lin", 0.4, "", { fmtf = pct }),
             b = P("LEVEL", 0, 1, "lin", 0.75, "", { fmtf = pct }) },
    },
  },
  {
    name = "PRC1", desc = "modal: struck bar", def = "dd_prc1", choke = false,
    smp = "MT",
    tone = {
      T1 = { a = P("PITCH", 60, 2000, "exp", 320, "Hz"),
             b = P("DECAY", 0.03, 3, "exp", 0.5, "s") },
      T2 = { a = P("MATERL", 0, 1, "lin", 0.4, "", { fmtf = MATERIAL }),
             b = P("DAMP", 0, 1, "lin", 0.4, "", { fmtf = pct }) },
      T3 = { a = P("STRIKE", 0, 1, "lin", 0.5, "", { fmtf = pct }),
             b = P("POS", 0, 1, "lin", 0.3, "", { fmtf = pct }) },
      T4 = { a = P("INHARM", 0, 1, "lin", 0.1, "", { fmtf = pct }),
             b = P("LEVEL", 0, 1, "lin", 0.7, "", { fmtf = pct }) },
    },
  },
  {
    name = "PRC2", desc = "modal: skin + bend", def = "dd_prc2", choke = false,
    smp = "LT",
    tone = {
      T1 = { a = P("PITCH", 60, 2000, "exp", 150, "Hz"),
             b = P("DECAY", 0.03, 3, "exp", 0.35, "s") },
      T2 = { a = P("MATERL", 0, 1, "lin", 0.05, "", { fmtf = MATERIAL }),
             b = P("DAMP", 0, 1, "lin", 0.3, "", { fmtf = pct }) },
      T3 = { a = P("STRIKE", 0, 1, "lin", 0.35, "", { fmtf = pct }),
             b = P("BEND", 0, 1, "lin", 0.3, "", { fmtf = pct }) },
      T4 = { a = P("SPREAD", 0, 1, "lin", 0.2, "", { fmtf = pct }),
             b = P("LEVEL", 0, 1, "lin", 0.7, "", { fmtf = pct }) },
    },
  },
  {
    name = "HAT", desc = "clean > metal > dirt", def = "dd_hat", choke = true,
    smp = "CH",
    tone = {
      T1 = { a = P("PITCH", 120, 900, "exp", 330, "Hz"),
             b = P("DECAY", 0.015, 1.8, "exp", 0.09, "s") },
      T2 = { a = P("FOLD", 0, 1, "lin", 0.42, "", { fmtf = FOLD }),
             b = P("SPREAD", 0, 1, "lin", 0.85, "", { fmtf = pct }) },
      T3 = { a = P("TONE", 1500, 14000, "exp", 7000, "Hz"),
             b = P("RES", 0, 1, "lin", 0.2, "", { fmtf = pct }) },
      T4 = { a = P("CURVE", 0, 1, "lin", 0.3, "", { fmtf = pct }),
             b = P("LEVEL", 0, 1, "lin", 0.6, "", { fmtf = pct }) },
    },
  },
  {
    name = "CYM", desc = "smooth > dusty", def = "dd_cym", choke = false,
    smp = "CY",
    tone = {
      T1 = { a = P("PITCH", 200, 1200, "exp", 420, "Hz"),
             b = P("DECAY", 0.2, 6, "exp", 1.8, "s") },
      T2 = { a = P("DUST", 0, 1, "lin", 0.15, "", { fmtf = pct }),
             b = P("SPREAD", 0, 1, "lin", 0.5, "", { fmtf = pct }) },
      T3 = { a = P("TONE", 1500, 12000, "exp", 4500, "Hz"),
             b = P("SIZZLE", 0, 1, "lin", 0.3, "", { fmtf = pct }) },
      T4 = { a = P("SWELL", 0.001, 1.5, "exp", 0.002, "s"),
             b = P("LEVEL", 0, 1, "lin", 0.55, "", { fmtf = pct }) },
    },
  },
}

-- ------------------------------------------------- shared per-track controls
--
-- The same on every voice. `arg` is the engine argument; `strip` means the
-- value goes to the track's channel strip rather than to the next voice.

S.SAMPLE = {
  S1 = { a = P("SAMPLE", 0, 1, "lin", 0, "", { special = "sample", nomod = true }),
         b = P("LEVEL", 0, 1, "lin", 0, "", { fmtf = pct, arg = "slvl" }) },
  S2 = { a = P("START", 0, 1, "lin", 0, "", { fmtf = pct, arg = "sstart" }),
         b = P("DECAY", 0.02, 4, "exp", 0.6, "s", { arg = "sdec" }) },
  S3 = { a = P("PITCH", -24, 24, "lin", 0, "st", { arg = "spitch" }),
         b = P("TONE", -1, 1, "lin", 0, "bi", { arg = "stone", fmtf = function(v)
           if math.abs(v) < 0.02 then return "OPEN" end
           return (v < 0 and "LP " or "HP ") .. math.floor(math.abs(v) * 100 + 0.5)
         end }) },
  S4 = { a = P("ATTACK", 0.0005, 0.5, "exp", 0.0005, "s", { arg = "satk" }),
         b = OPT("DIR", { "FWD", "REV" }, 1, { arg = "srev", zero = true }) },
}

S.NOISE_TYPES = { "WHITE", "PINK", "DUST", "TAPE", "METAL" }

S.NOISE = {
  N1 = { a = OPT("TYPE", S.NOISE_TYPES, 2, { arg = "ntype", zero = true }),
         b = P("LEVEL", 0, 1, "lin", 0, "", { fmtf = pct, arg = "nlvl" }) },
  N2 = { a = P("TONE", 60, 14000, "exp", 3000, "Hz", { arg = "ntone" }),
         b = P("GRAIN", 0, 1, "lin", 0, "", { fmtf = pct, arg = "ngrain" }) },
}

S.COL = {
  C1 = { a = P("DRIVE", 0, 1, "lin", 0, "", { fmtf = pct, arg = "drive", strip = true }),
         b = P("WARMTH", 0, 1, "lin", 0.3, "", { fmtf = pct, arg = "warmth", strip = true }) },
  C2 = { a = P("CRUSH", 0, 1, "lin", 0, "", { fmtf = pct, arg = "crush", strip = true }),
         b = P("DUST", 0, 1, "lin", 0, "", { fmtf = pct, arg = "dust", strip = true }) },
}

-- ---------------------------------------------------- step controls (TC / P)
--
-- These live on a step, not on the track. With steps held they edit those
-- steps; with none held they edit the track's template, which is what the
-- next step placed on that track starts from.

S.CONDS = { "ALWAYS", "FILL", "!FILL", "PRE", "!PRE", "NEI", "!NEI",
            "1ST", "!1ST", "1:2", "2:2", "1:3", "2:3", "3:3",
            "1:4", "2:4", "3:4", "4:4" }

S.PMODES = { "WAIT", "REPEAT", "SUSTAIN", "EDGE", "SCATTER" }

S.STEP = {
  TC1 = { a = OPT("COND", S.CONDS, 1, { key = "cond" }),
          b = INT("PROB", 0, 100, 100, "%", { key = "prob" }) },
  TC2 = { a = INT("VEL", 0, 100, 100, "%", { key = "vel" }),
          b = INT("NUDGE", -50, 50, 0, "%", { key = "nudge", fmtf = function(v)
            return string.format("%+d%%", math.floor(v + 0.5)) end }) },
  TC3 = { a = INT("PITCH", -24, 24, 0, " st", { key = "pitch", fmtf = function(v)
            return string.format("%+d st", math.floor(v + 0.5)) end }),
          b = INT("MIX", -100, 100, 0, "", { key = "mix", fmtf = function(v)
            v = math.floor(v + 0.5)
            if v == 0 then return "BOTH" end
            return (v < 0 and "SYN " or "SMP ") .. math.abs(v) end }) },
  TC4 = { a = INT("FLAM", 0, 80, 0, "", { key = "flam", fmtf = function(v)
            v = math.floor(v + 0.5)
            return v == 0 and "OFF" or (v .. " ms") end }),
          b = INT("DECAY", -100, 100, 0, "", { key = "dec", fmtf = function(v)
            return string.format("%+d", math.floor(v + 0.5)) end }) },
  P1  = { a = INT("PULSES", 1, 8, 1, "", { key = "pulses" }),
          b = OPT("MODE", S.PMODES, 1, { key = "pmode" }) },
  P2  = { a = INT("RAMP", -100, 100, 0, "", { key = "ramp", fmtf = function(v)
            return string.format("%+d", math.floor(v + 0.5)) end }),
          b = INT("BEND", -12, 12, 0, "", { key = "bend", fmtf = function(v)
            return string.format("%+d st", math.floor(v + 0.5)) end }) },
}

function S.new_step(tpl)
  local s = { on = true }
  for _, pair in pairs(S.STEP) do
    for _, side in ipairs({ "a", "b" }) do
      local p = pair[side]
      s[p.key] = (tpl and tpl[p.key]) or p.def
    end
  end
  return s
end

-- ------------------------------------------------------------- lookups

-- The two parameters a button opens on a given voice, or nil for LFO buttons.
function S.pair(vi, btn)
  local b = S.BTN[btn]
  if not b then return nil end
  if b.kind == "tone" then return S.VOICES[vi].tone[btn] end
  if b.kind == "smp" then return S.SAMPLE[btn] end
  if b.kind == "noise" then return S.NOISE[btn] end
  if b.kind == "col" then return S.COL[btn] end
  if b.kind == "trig" or b.kind == "pulse" then return S.STEP[btn] end
  return nil
end

-- every sound key on a voice, e.g. "T1a", in a fixed order
S.SOUND_BTNS = { "T1", "T2", "T3", "T4", "S1", "S2", "S3", "S4", "N1", "N2", "C1", "C2" }

function S.sound_keys()
  local out = {}
  for _, b in ipairs(S.SOUND_BTNS) do
    out[#out + 1] = b .. "a"
    out[#out + 1] = b .. "b"
  end
  return out
end

-- the parameter behind a sound key on a voice
function S.param(vi, key)
  local btn, side = key:sub(1, -2), key:sub(-1)
  local pair = S.pair(vi, btn)
  return pair and pair[side]
end

-- the engine argument a sound key is sent as
function S.arg(vi, key)
  local p = S.param(vi, key)
  if p and p.arg then return p.arg end
  return key:lower()   -- T1a -> t1a
end

-- ------------------------------------------------------------------- speeds

S.SPEEDS = { "1/32", "1/16T", "1/16", "1/8T", "1/8", "1/4" }
S.SPEED_BEATS = { 1 / 8, 1 / 6, 1 / 4, 1 / 3, 1 / 2, 1 }

S.SWING_GRID = { "1/16", "1/8" }
S.SWING_UNIT = { 1 / 4, 1 / 2 }

-- ------------------------------------------------------------------- LFOs

S.LFO_SHAPES = { "SINE", "TRI", "RAMP", "SQUARE", "S+H", "DRIFT" }

-- --------------------------------------------------------- master COLOUR
--
-- Pappus' colour stage, rebuilt for a drum bus: drive > crush > loss >
-- envelope-following noise > wow, then a glue compressor and the output.
-- E1 picks a cell, E2 and E3 turn its two halves.

S.COLOUR = {
  { name = "DRIVE", short = "DRV",
    a = P("DRIVE", 0, 1, "lin", 0, "", { fmtf = pct, arg = "drive" }),
    b = P("TILT", -1, 1, "lin", 0, "bi", { arg = "ctilt" }) },
  { name = "CRUSH", short = "CRU",
    a = P("CRUSH", 0, 1, "lin", 0, "", { fmtf = pct, arg = "crush" }),
    b = OPT("MODE", { "BITS", "REDUX", "BIT+RDX" }, 3, { arg = "crushmode" }) },
  { name = "LOSS", short = "LOS",
    a = P("LOSS", 0, 1, "lin", 0, "", { fmtf = pct, arg = "loss" }),
    b = P("WOW", 0, 1, "lin", 0, "", { fmtf = pct, arg = "wow" }) },
  { name = "NOISE", short = "NOI",
    a = P("NOISE", 0, 1, "lin", 0, "", { fmtf = pct, arg = "noise" }),
    b = OPT("TYPE", { "WHITE", "PINK", "DUST", "CRACKL", "HISS" }, 2, { arg = "noisetype" }) },
  { name = "N.SHAPE", short = "N.S",
    a = P("N.DEC", 0.01, 4, "exp", 0.25, "s", { arg = "noisedecay" }),
    b = P("N.TONE", 60, 12000, "exp", 1200, "Hz", { arg = "noisetone" }) },
  { name = "OUT", short = "OUT",
    a = P("GLUE", 0, 1, "lin", 0.2, "", { fmtf = pct, arg = "glue" }),
    b = P("LEVEL", 0, 1.5, "lin", 1, "", { fmtf = pct, arg = "outlvl" }) },
}

return S
