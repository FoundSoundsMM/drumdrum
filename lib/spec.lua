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
--  row  8     PLAY STOP SWING . [1 2 3 4 5 6 7 8] . CLEAR MIX COLOUR
--
-- SHIFT is norns K2, not a grid button.
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

S.ROW8 = { play = 1, stop = 2, swing = 3, track0 = 4, clear = 14, mix = 15, colour = 16 }

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

local FOLD = function(v)
  local n = (v < 0.34) and "CLEAN" or ((v < 0.67) and "METAL" or "DIRTY")
  return n .. " " .. math.floor(v * 100 + 0.5)
end

-- WARM is voiced after the MFB Tanzbar (see the engine's notes on what its
-- samples measured). The defaults sit on the middle of those samples.
local PMODE = function(v)
  local names = { "CLAVE", "RIM", "COWBL" }
  local x = v * 2
  local i = math.floor(x + 0.5)
  if math.abs(x - i) < 0.12 then return names[i + 1] end
  local lo = math.floor(x)
  return names[lo + 1]:sub(1, 3) .. ">" .. names[lo + 2]:sub(1, 3)
end

S.VOICES = {
  {
    name = "BD1", desc = "zap kick", def = "dd_bd1", choke = true,
    smp = "BD",
    tone = {
      T1 = { a = P("PITCH", 30, 110, "exp", 52, "Hz"),
             b = P("DECAY", 0.08, 3, "exp", 0.65, "s") },
      T2 = { a = P("SWEEP", 0, 4, "lin", 2, "oct"),
             b = P("S.TIME", 0.004, 0.3, "exp", 0.032, "s") },
      T3 = { a = P("PUNCH", 0, 1, "lin", 0.35, "", { fmtf = pct }),
             b = P("BODY", 0, 1, "lin", 0.45, "", { fmtf = pct }) },
      T4 = { a = P("TONE", 200, 14000, "exp", 5000, "Hz"),
             b = P("LEVEL", 0, 1, "lin", 0.8, "", { fmtf = pct }) },
    },
  },
  {
    name = "BD2", desc = "808 boom", def = "dd_bd2", choke = true,
    smp = "BD",
    tone = {
      T1 = { a = P("PITCH", 30, 160, "exp", 50, "Hz"),
             b = P("DECAY", 0.08, 4, "exp", 0.5, "s") },
      T2 = { a = P("SWEEP", 0, 2, "lin", 0.3, "oct"),
             b = P("S.TIME", 0.002, 0.1, "exp", 0.008, "s") },
      T3 = { a = P("CLICK", 0, 1, "lin", 0.3, "", { fmtf = pct }),
             b = P("DRIVE", 0, 1, "lin", 0.15, "", { fmtf = pct }) },
      T4 = { a = P("TONE", 200, 14000, "exp", 3000, "Hz"),
             b = P("LEVEL", 0, 1, "lin", 0.8, "", { fmtf = pct }) },
    },
  },
  {
    name = "CLP", desc = "burst clap", def = "dd_clp", choke = false,
    smp = "CP",
    tone = {
      T1 = { a = P("TONE", 500, 5000, "exp", 1500, "Hz"),
             b = P("DECAY", 0.04, 1.5, "exp", 0.25, "s") },
      T2 = { a = P("SPREAD", 0.002, 0.03, "exp", 0.0045, "s"),
             b = INT("GRAINS", 1, 20, 14) },
      T3 = { a = P("SIZZLE", 0, 1, "lin", 0.2, "", { fmtf = pct }),
             b = P("WIDTH", 0.15, 2, "exp", 0.9, "", { fmtf = function(v)
               return string.format("%.2f", v) end }) },
      T4 = { a = P("SNAP", 0, 1, "lin", 0.3, "", { fmtf = pct }),
             b = P("LEVEL", 0, 1, "lin", 0.75, "", { fmtf = pct }) },
    },
  },
  {
    name = "SNR", desc = "octave snare", def = "dd_snr", choke = true,
    smp = "SD",
    tone = {
      T1 = { a = P("PITCH", 100, 500, "exp", 165, "Hz"),
             b = P("DECAY", 0.03, 0.8, "exp", 0.17, "s") },
      T2 = { a = P("SNAP", 0, 1.5, "lin", 0.8, "", { fmtf = pct }),
             b = P("WIRES", 0.03, 1, "exp", 0.3, "s") },
      T3 = { a = P("W.TONE", 400, 8000, "exp", 1100, "Hz"),
             b = P("RING", 0, 1, "lin", 0.35, "", { fmtf = pct }) },
      T4 = { a = P("CRACK", 0, 1, "lin", 0.3, "", { fmtf = pct }),
             b = P("LEVEL", 0, 1, "lin", 0.75, "", { fmtf = pct }) },
    },
  },
  {
    name = "PRC1", desc = "clave > rim > bell", def = "dd_prc1", choke = false,
    smp = "MT",
    tone = {
      T1 = { a = P("PITCH", 100, 2000, "exp", 540, "Hz"),
             b = P("DECAY", 0.02, 1.5, "exp", 0.2, "s") },
      T2 = { a = P("MODE", 0, 1, "lin", 1, "", { fmtf = PMODE }),
             b = P("DETUNE", 1.2, 1.8, "lin", 1.5, "", { fmtf = function(v)
               return string.format("x%.3f", v) end }) },
      T3 = { a = P("STRIKE", 0, 1, "lin", 0.3, "", { fmtf = pct }),
             b = P("TONE", 600, 8000, "exp", 2800, "Hz") },
      T4 = { a = P("DRIVE", 0, 1, "lin", 0.2, "", { fmtf = pct }),
             b = P("LEVEL", 0, 1, "lin", 0.7, "", { fmtf = pct }) },
    },
  },
  {
    name = "PRC2", desc = "tom / conga", def = "dd_prc2", choke = false,
    smp = "LT",
    tone = {
      T1 = { a = P("PITCH", 40, 600, "exp", 110, "Hz"),
             b = P("DECAY", 0.03, 3, "exp", 0.38, "s") },
      T2 = { a = P("BEND", 0, 1, "lin", 0.25, "", { fmtf = pct }),
             b = P("B.TIME", 0.02, 0.6, "exp", 0.12, "s") },
      T3 = { a = P("STRIKE", 0, 1, "lin", 0.35, "", { fmtf = pct }),
             b = P("DRIVE", 0, 1, "lin", 0.45, "", { fmtf = pct }) },
      T4 = { a = P("NOISE", 0, 1, "lin", 0.05, "", { fmtf = pct }),
             b = P("LEVEL", 0, 1, "lin", 0.7, "", { fmtf = pct }) },
    },
  },
  {
    name = "HAT", desc = "clean > metal > dirt", def = "dd_hat", choke = true,
    smp = "CH",
    tone = {
      T1 = { a = P("PITCH", 120, 900, "exp", 330, "Hz"),
             b = P("DECAY", 0.015, 1.8, "exp", 0.14, "s") },
      T2 = { a = P("FOLD", 0, 1, "lin", 0.42, "", { fmtf = FOLD }),
             b = P("SPREAD", 0, 1, "lin", 0.85, "", { fmtf = pct }) },
      T3 = { a = P("TONE", 2500, 14000, "exp", 8500, "Hz"),
             b = P("RES", 0, 1, "lin", 0.35, "", { fmtf = pct }) },
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

-- --------------------------------------------------------------------- kits
--
-- Four voicings of the same eight roles. Each track has its own KIT param,
-- so they mix and match; on the SNAP page grid row 7, columns 1-4, tap a kit
-- to put every track on it, or hold one and press track buttons to move
-- just those:
--
--   WARM  the voices above, after the MFB Tanzbar
--   WOOD  wooden, organic percussion: cajon, slit log, clappers, wood
--         block, balafon, shaker, seed pods
--   FM    after the Yamaha YMF262 (OPL3), as ALM's Akemie's Taiko plays it:
--         two- and four-operator FM on the chip's waveforms, ratios and
--         rhythm mode, through its floating-point DAC
--   GLITCH soft glitch drums after Matmos and Bjork's Vespertine, all from
--         noise: a hush kick, a heartbeat, a snow step, a card riffle, a
--         water drop, a music box, micro ticks, a whisper
--
-- Each kit has its own T1-T4 params, so a kit keeps how you left it while
-- that track is on another. Everything else on a track (sample, noise, colour,
-- mix, LFOs, steps) is shared: an LFO patched to T2a moves T2a in whichever
-- kit is playing, and a lock on T2a is a position on that knob, whatever it
-- turns. T1 is PITCH / DECAY and T4b LEVEL in every kit, so those locks mean
-- the same thing everywhere.

S.KITS = { "WARM", "WOOD", "FM", "GLITCH" }
-- The kit a track is playing is its KIT param, read from there: every
-- module include()s its own copy of this file, so a table kept here would
-- not be the same one from module to module. WARM until params exist.
function S.kit_of(t)
  local ok, k = pcall(params.get, params, "t" .. t .. "_kit")
  return (ok and k) or 1
end

local OPL_MULTS = { "x1/2", "x1", "x2", "x3", "x4", "x5", "x6", "x7", "x8", "x9",
                    "x10", "x12", "x15" }
local OPL_WAVES = { "SINE", "HALF", "ABS", "QUART", "ALT", "CAMEL", "SQUARE", "LOGSAW" }
local function MULT(def) return OPT("RATIO", OPL_MULTS, def, { zero = true }) end
local function WAVE(def) return OPT("WAVE", OPL_WAVES, def, { zero = true }) end
local function ratio(v) return string.format("x%.2f", v) end
local function signed(v) return string.format("%+d", math.floor(v * 100 + 0.5)) end

-- WOOD's mallets, sticks and hands: how hard is how short the contact.
-- WOOD on every voice is the wood itself: green and damp (it only thocks)
-- to dry hardwood (it rings).
local function WOOD(def) return P("WOOD", 0, 1, "lin", def, "", { fmtf = function(v)
  local n = (v < 0.34) and "GREEN" or ((v < 0.67) and "SEASND" or "HARD")
  return n .. " " .. math.floor(v * 100 + 0.5) end }) end

S.WOOD_VOICES = {
  {
    name = "BD1", desc = "cajon bass", def = "dd_wbd1",
    tone = {
      T1 = { a = P("PITCH", 50, 140, "exp", 78, "Hz"),
             b = P("DECAY", 0.08, 1.5, "exp", 0.35, "s") },
      T2 = { a = P("HAND", 0, 1, "lin", 0.3, "", { fmtf = pct }),
             b = P("BOX", 0, 1, "lin", 0.6, "", { fmtf = pct }) },
      T3 = { a = P("FACE", 0, 1, "lin", 0.4, "", { fmtf = pct }),
             b = P("SLAP", 0, 1, "lin", 0.15, "", { fmtf = pct }) },
      T4 = { a = WOOD(0.4),
             b = P("LEVEL", 0, 1, "lin", 0.8, "", { fmtf = pct }) },
    },
  },
  {
    name = "BD2", desc = "slit log", def = "dd_wbd2",
    tone = {
      T1 = { a = P("PITCH", 55, 260, "exp", 95, "Hz"),
             b = P("DECAY", 0.05, 2, "exp", 0.6, "s") },
      T2 = { a = P("MALLET", 0, 1, "lin", 0.3, "", { fmtf = pct }),
             b = P("TONGUE", 0, 1, "lin", 0.4, "", { fmtf = pct }) },
      T3 = { a = P("HOLLOW", 0, 1, "lin", 0.5, "", { fmtf = pct }),
             b = P("BEND", 0, 1, "lin", 0.3, "", { fmtf = pct }) },
      T4 = { a = WOOD(0.55),
             b = P("LEVEL", 0, 1, "lin", 0.75, "", { fmtf = pct }) },
    },
  },
  {
    name = "CLP", desc = "clappers", def = "dd_wclp",
    tone = {
      T1 = { a = P("TONE", 400, 3000, "exp", 1100, "Hz"),
             b = P("DECAY", 0.02, 0.5, "exp", 0.09, "s") },
      T2 = { a = P("SPREAD", 0.001, 0.03, "exp", 0.006, "s"),
             b = INT("GRAINS", 1, 6, 2) },
      T3 = { a = P("CRACK", 0, 1, "lin", 0.4, "", { fmtf = pct }),
             b = P("SIZE", 0, 1, "lin", 0.4, "", { fmtf = pct }) },
      T4 = { a = WOOD(0.5),
             b = P("LEVEL", 0, 1, "lin", 0.75, "", { fmtf = pct }) },
    },
  },
  {
    name = "SNR", desc = "cajon slap", def = "dd_wsnr",
    tone = {
      T1 = { a = P("PITCH", 150, 600, "exp", 320, "Hz"),
             b = P("DECAY", 0.03, 0.6, "exp", 0.14, "s") },
      T2 = { a = P("SLAP", 0, 1, "lin", 0.6, "", { fmtf = pct }),
             b = P("WIRES", 0, 1.5, "lin", 0.6, "", { fmtf = pct }) },
      T3 = { a = P("W.TONE", 1000, 8000, "exp", 3500, "Hz"),
             b = P("W.DEC", 0.02, 0.6, "exp", 0.15, "s") },
      T4 = { a = WOOD(0.4),
             b = P("LEVEL", 0, 1, "lin", 0.75, "", { fmtf = pct }) },
    },
  },
  {
    name = "PRC1", desc = "wood block", def = "dd_wprc1",
    tone = {
      T1 = { a = P("PITCH", 200, 3000, "exp", 700, "Hz"),
             b = P("DECAY", 0.02, 1, "exp", 0.12, "s") },
      T2 = { a = P("HOLLOW", 0, 1, "lin", 0.5, "", { fmtf = pct }),
             b = P("STICK", 0, 1, "lin", 0.6, "", { fmtf = pct }) },
      T3 = { a = P("SHAPE", 0, 1, "lin", 0.3, "", { fmtf = function(v)
               local n = (v < 0.25) and "BLOCK" or ((v < 0.75) and "TEMPLE" or "CLAVE")
               return n .. " " .. math.floor(v * 100 + 0.5) end }),
             b = P("POS", 0, 1, "lin", 0.3, "", { fmtf = pct }) },
      T4 = { a = WOOD(0.6),
             b = P("LEVEL", 0, 1, "lin", 0.7, "", { fmtf = pct }) },
    },
  },
  {
    name = "PRC2", desc = "balafon", def = "dd_wprc2",
    tone = {
      T1 = { a = P("PITCH", 100, 1500, "exp", 262, "Hz"),
             b = P("DECAY", 0.05, 3, "exp", 0.6, "s") },
      T2 = { a = P("MALLET", 0, 1, "lin", 0.4, "", { fmtf = pct }),
             b = P("GOURD", 0, 1, "lin", 0.5, "", { fmtf = pct }) },
      T3 = { a = P("BUZZ", 0, 1, "lin", 0.25, "", { fmtf = pct }),
             b = P("TUNE", 0, 1, "lin", 0.1, "", { fmtf = function(v)
               return (v < 0.5 and "CARVED " or "PLAIN ") .. math.floor(v * 100 + 0.5) end }) },
      T4 = { a = WOOD(0.6),
             b = P("LEVEL", 0, 1, "lin", 0.7, "", { fmtf = pct }) },
    },
  },
  {
    name = "HAT", desc = "shaker", def = "dd_what",
    tone = {
      T1 = { a = P("PITCH", 1500, 9000, "exp", 4000, "Hz"),
             b = P("DECAY", 0.02, 1, "exp", 0.12, "s") },
      T2 = { a = P("BEANS", 0, 1, "lin", 0.5, "", { fmtf = pct }),
             b = P("SHELL", 0, 1, "lin", 0.4, "", { fmtf = pct }) },
      T3 = { a = P("SPREAD", 0, 1, "lin", 0.4, "", { fmtf = pct }),
             b = P("ATTACK", 0.001, 0.2, "exp", 0.012, "s") },
      T4 = { a = P("GRAIN", 0, 1, "lin", 0.5, "", { fmtf = function(v)
               return (v < 0.5 and "SAND " or "SEEDS ") .. math.floor(v * 100 + 0.5) end }),
             b = P("LEVEL", 0, 1, "lin", 0.6, "", { fmtf = pct }) },
    },
  },
  {
    name = "CYM", desc = "seed pods", def = "dd_wcym",
    tone = {
      T1 = { a = P("PITCH", 600, 6000, "exp", 1800, "Hz"),
             b = P("DECAY", 0.1, 6, "exp", 0.9, "s") },
      T2 = { a = P("DENSITY", 0, 1, "lin", 0.5, "", { fmtf = pct }),
             b = P("SPREAD", 0, 1, "lin", 0.5, "", { fmtf = pct }) },
      T3 = { a = P("SEEDS", 0, 1, "lin", 0.5, "", { fmtf = pct }),
             b = P("SHAKE", 0, 1, "lin", 0.35, "", { fmtf = pct }) },
      T4 = { a = P("SWELL", 0.001, 1.5, "exp", 0.04, "s"),
             b = P("LEVEL", 0, 1, "lin", 0.55, "", { fmtf = pct }) },
    },
  },
}

S.FM_VOICES = {
  {
    name = "BD1", desc = "2-op fm kick", def = "dd_fbd1",
    tone = {
      T1 = { a = P("PITCH", 30, 120, "exp", 50, "Hz"),
             b = P("DECAY", 0.08, 3, "exp", 0.55, "s") },
      T2 = { a = P("SWEEP", 0, 4, "lin", 2.2, "oct"),
             b = P("S.TIME", 0.004, 0.3, "exp", 0.03, "s") },
      T3 = { a = P("FM", 0, 1, "lin", 0.35, "", { fmtf = pct }),
             b = MULT(2) },
      T4 = { a = WAVE(1),
             b = P("LEVEL", 0, 1, "lin", 0.8, "", { fmtf = pct }) },
    },
  },
  {
    name = "BD2", desc = "4-op fb kick", def = "dd_fbd2",
    tone = {
      T1 = { a = P("PITCH", 35, 160, "exp", 56, "Hz"),
             b = P("DECAY", 0.05, 2, "exp", 0.4, "s") },
      T2 = { a = P("SWEEP", 0, 5, "lin", 3, "oct"),
             b = P("S.TIME", 0.003, 0.25, "exp", 0.02, "s") },
      T3 = { a = P("FM", 0, 1, "lin", 0.45, "", { fmtf = pct }),
             b = P("FDBK", 0, 1, "lin", 0.5, "", { fmtf = pct }) },
      T4 = { a = MULT(3),
             b = P("LEVEL", 0, 1, "lin", 0.7, "", { fmtf = pct }) },
    },
  },
  {
    name = "CLP", desc = "feedback clap", def = "dd_fclp",
    tone = {
      T1 = { a = P("TONE", 500, 5000, "exp", 1200, "Hz"),
             b = P("DECAY", 0.04, 1.5, "exp", 0.3, "s") },
      T2 = { a = P("SPREAD", 0.003, 0.03, "exp", 0.011, "s"),
             b = INT("GRAINS", 1, 6, 4) },
      T3 = { a = P("FM", 0, 1, "lin", 0.7, "", { fmtf = pct }),
             b = MULT(4) },
      T4 = { a = WAVE(1),
             b = P("LEVEL", 0, 1, "lin", 0.75, "", { fmtf = pct }) },
    },
  },
  {
    name = "SNR", desc = "rhythm-mode sd", def = "dd_fsnr",
    tone = {
      T1 = { a = P("PITCH", 110, 420, "exp", 200, "Hz"),
             b = P("DECAY", 0.03, 0.8, "exp", 0.15, "s") },
      T2 = { a = P("SNAP", 0, 1.5, "lin", 0.9, "", { fmtf = pct }),
             b = P("N.DEC", 0.03, 1, "exp", 0.2, "s") },
      T3 = { a = P("FM", 0, 1, "lin", 0.4, "", { fmtf = pct }),
             b = MULT(2) },
      T4 = { a = WAVE(1),
             b = P("LEVEL", 0, 1, "lin", 0.75, "", { fmtf = pct }) },
    },
  },
  {
    name = "PRC1", desc = "2-op fm tom", def = "dd_fprc1",
    tone = {
      T1 = { a = P("PITCH", 60, 2000, "exp", 300, "Hz"),
             b = P("DECAY", 0.03, 3, "exp", 0.5, "s") },
      T2 = { a = P("FM", 0, 1, "lin", 0.4, "", { fmtf = pct }),
             b = P("M.DEC", 0.01, 2, "exp", 0.15, "s") },
      T3 = { a = MULT(4),
             b = P("FDBK", 0, 1, "lin", 0.3, "", { fmtf = pct }) },
      T4 = { a = WAVE(1),
             b = P("LEVEL", 0, 1, "lin", 0.7, "", { fmtf = pct }) },
    },
  },
  {
    name = "PRC2", desc = "taiko", def = "dd_fprc2",
    tone = {
      T1 = { a = P("PITCH", 60, 2000, "exp", 130, "Hz"),
             b = P("DECAY", 0.03, 3, "exp", 0.45, "s") },
      T2 = { a = P("FM", 0, 1, "lin", 0.3, "", { fmtf = pct }),
             b = P("M.DEC", 0.01, 2, "exp", 0.06, "s") },
      T3 = { a = P("SWEEP", 0, 2, "lin", 0.7, "oct"),
             b = MULT(2) },
      T4 = { a = WAVE(2),
             b = P("LEVEL", 0, 1, "lin", 0.7, "", { fmtf = pct }) },
    },
  },
  {
    name = "HAT", desc = "rhythm-mode hh", def = "dd_fhat",
    tone = {
      T1 = { a = P("PITCH", 100, 800, "exp", 330, "Hz"),
             b = P("DECAY", 0.015, 1.8, "exp", 0.08, "s") },
      T2 = { a = P("RATIO", 0.5, 4, "exp", 1.41, "", { fmtf = ratio }),
             b = P("NOISE", 0, 1, "lin", 0.6, "", { fmtf = pct }) },
      T3 = { a = P("FM", 0, 1, "lin", 0.2, "", { fmtf = pct }),
             b = P("TONE", 1500, 14000, "exp", 6000, "Hz") },
      T4 = { a = P("CURVE", 0, 1, "lin", 0.3, "", { fmtf = pct }),
             b = P("LEVEL", 0, 1, "lin", 0.6, "", { fmtf = pct }) },
    },
  },
  {
    name = "CYM", desc = "rhythm-mode cy", def = "dd_fcym",
    tone = {
      T1 = { a = P("PITCH", 150, 1200, "exp", 420, "Hz"),
             b = P("DECAY", 0.2, 6, "exp", 1.8, "s") },
      T2 = { a = P("RATIO", 0.5, 4, "exp", 1.76, "", { fmtf = ratio }),
             b = P("NOISE", 0, 1, "lin", 0.2, "", { fmtf = pct }) },
      T3 = { a = P("FM", 0, 1, "lin", 0.3, "", { fmtf = pct }),
             b = P("TONE", 1500, 12000, "exp", 4000, "Hz") },
      T4 = { a = P("TREM", 0, 1, "lin", 0.3, "", { fmtf = pct }),
             b = P("LEVEL", 0, 1, "lin", 0.55, "", { fmtf = pct }) },
    },
  },
}

-- GLITCH: soft glitch drums after Matmos and Bjork's Vespertine, every
-- voice made from noise (see the engine's notes)
local per_s = function(v) return string.format("%d/s", math.floor(v + 0.5)) end
local VOWEL = function(v)
  local names = { "A", "E", "I", "O", "U" }
  local x = v * 4
  local lo = math.floor(x)
  if x - lo < 0.15 or lo >= 4 then return names[math.floor(x + 0.5) + 1] end
  if x - lo > 0.85 then return names[lo + 2] end
  return names[lo + 1] .. ">" .. names[lo + 2]
end

S.GLITCH_VOICES = {
  {
    name = "BD1", desc = "hush kick", def = "dd_gbd1",
    tone = {
      T1 = { a = P("PITCH", 30, 120, "exp", 55, "Hz"),
             b = P("DECAY", 0.05, 2, "exp", 0.35, "s") },
      T2 = { a = P("SOFT", 0, 1, "lin", 0.5, "", { fmtf = pct }),
             b = P("BREATH", 0, 1, "lin", 0.3, "", { fmtf = pct }) },
      T3 = { a = INT("STUTTER", 1, 8, 1),
             b = P("GAP", 0.005, 0.15, "exp", 0.035, "s") },
      T4 = { a = P("SWEEP", 0, 2, "lin", 0.6, "oct"),
             b = P("LEVEL", 0, 1, "lin", 0.8, "", { fmtf = pct }) },
    },
  },
  {
    name = "BD2", desc = "heartbeat", def = "dd_gbd2",
    tone = {
      T1 = { a = P("PITCH", 30, 150, "exp", 58, "Hz"),
             b = P("DECAY", 0.05, 1.5, "exp", 0.3, "s") },
      T2 = { a = P("DUB", 0, 1, "lin", 0.6, "", { fmtf = pct }),
             b = P("GAP", 0.04, 0.5, "exp", 0.17, "s") },
      T3 = { a = P("SOFT", 0, 1, "lin", 0.6, "", { fmtf = pct }),
             b = P("GRIT", 0, 1, "lin", 0.15, "", { fmtf = pct }) },
      T4 = { a = P("TONE", 150, 8000, "exp", 1400, "Hz"),
             b = P("LEVEL", 0, 1, "lin", 0.8, "", { fmtf = pct }) },
    },
  },
  {
    name = "CLP", desc = "snow step", def = "dd_gclp",
    tone = {
      T1 = { a = P("TONE", 400, 8000, "exp", 2600, "Hz"),
             b = P("DECAY", 0.05, 1.5, "exp", 0.3, "s") },
      T2 = { a = P("DENSITY", 20, 4000, "exp", 700, "", { fmtf = per_s }),
             b = P("GRAIN", 0.0002, 0.01, "exp", 0.0012, "s") },
      T3 = { a = P("CRUNCH", 0, 1, "lin", 0.5, "", { fmtf = pct }),
             b = P("SPREAD", 0, 1, "lin", 0.5, "", { fmtf = pct }) },
      T4 = { a = P("SQUEAK", 0, 1, "lin", 0.1, "", { fmtf = pct }),
             b = P("LEVEL", 0, 1, "lin", 0.75, "", { fmtf = pct }) },
    },
  },
  {
    name = "SNR", desc = "card riffle", def = "dd_gsnr",
    tone = {
      T1 = { a = P("TONE", 800, 9000, "exp", 2500, "Hz"),
             b = P("DECAY", 0.03, 1, "exp", 0.16, "s") },
      T2 = { a = P("RATE", 20, 800, "exp", 220, "", { fmtf = per_s }),
             b = P("CURVE", -1, 1, "lin", -0.3, "", { fmtf = function(v)
               if math.abs(v) < 0.05 then return "EVEN" end
               return ((v > 0) and "FASTER " or "SLOWER ") .. math.floor(math.abs(v) * 100 + 0.5) end }) },
      T3 = { a = P("SNAP", 0, 1, "lin", 0.35, "", { fmtf = pct }),
             b = P("PAPER", 0, 1, "lin", 0.3, "", { fmtf = pct }) },
      T4 = { a = P("JITTER", 0, 1, "lin", 0.3, "", { fmtf = pct }),
             b = P("LEVEL", 0, 1, "lin", 0.75, "", { fmtf = pct }) },
    },
  },
  {
    name = "PRC1", desc = "water drop", def = "dd_gprc1",
    tone = {
      T1 = { a = P("PITCH", 150, 5000, "exp", 900, "Hz"),
             b = P("DECAY", 0.01, 0.6, "exp", 0.07, "s") },
      T2 = { a = P("RISE", 0, 2, "lin", 0.7, "oct"),
             b = P("SPLASH", 0, 1, "lin", 0.15, "", { fmtf = pct }) },
      T3 = { a = P("SCATTER", 0, 1, "lin", 0.25, "", { fmtf = pct }),
             b = P("SPREAD", 0, 1, "lin", 0.5, "", { fmtf = pct }) },
      T4 = { a = P("WINDOW", 0.02, 1.5, "exp", 0.3, "s"),
             b = P("LEVEL", 0, 1, "lin", 0.7, "", { fmtf = pct }) },
    },
  },
  {
    name = "PRC2", desc = "music box", def = "dd_gprc2",
    tone = {
      T1 = { a = P("PITCH", 100, 3000, "exp", 660, "Hz"),
             b = P("DECAY", 0.05, 4, "exp", 0.8, "s") },
      T2 = { a = P("BRIGHT", 0, 1, "lin", 0.45, "", { fmtf = pct }),
             b = P("BODY", 0, 1, "lin", 0.25, "", { fmtf = pct }) },
      T3 = { a = INT("STUTTER", 1, 8, 2),
             b = P("GAP", 0.01, 0.3, "exp", 0.09, "s") },
      T4 = { a = INT("STEP", -12, 12, 12, "", { fmtf = function(v)
               return string.format("%+d st", math.floor(v + 0.5)) end }),
             b = P("LEVEL", 0, 1, "lin", 0.65, "", { fmtf = pct }) },
    },
  },
  {
    name = "HAT", desc = "micro ticks", def = "dd_ghat",
    tone = {
      T1 = { a = P("TONE", 1000, 16000, "exp", 6500, "Hz"),
             b = P("DECAY", 0.005, 0.8, "exp", 0.05, "s") },
      T2 = { a = P("GRAINS", 0, 1, "lin", 0.3, "", { fmtf = pct }),
             b = P("SPREAD", 0, 1, "lin", 0.3, "", { fmtf = pct }) },
      T3 = { a = P("BITS", 2, 16, "lin", 12, "", { fmtf = function(v)
               return string.format("%.1f bit", v) end }),
             b = P("RATE", 0, 1, "lin", 0.15, "", { fmtf = pct }) },
      T4 = { a = P("AIR", 0, 1, "lin", 0.25, "", { fmtf = pct }),
             b = P("LEVEL", 0, 1, "lin", 0.6, "", { fmtf = pct }) },
    },
  },
  {
    name = "CYM", desc = "whisper", def = "dd_gcym",
    tone = {
      T1 = { a = P("PITCH", 300, 2500, "exp", 800, "Hz"),
             b = P("DECAY", 0.1, 6, "exp", 1.4, "s") },
      T2 = { a = P("SWELL", 0.001, 1.5, "exp", 0.15, "s"),
             b = P("VOWEL", 0, 1, "lin", 0.25, "", { fmtf = VOWEL }) },
      T3 = { a = P("CRACKLE", 0, 1, "lin", 0.2, "", { fmtf = pct }),
             b = P("SHIMMER", 0, 1, "lin", 0.2, "", { fmtf = pct }) },
      T4 = { a = P("AIR", 0, 1, "lin", 0.35, "", { fmtf = pct }),
             b = P("LEVEL", 0, 1, "lin", 0.55, "", { fmtf = pct }) },
    },
  },
}

-- the same roles in every kit: the sample defaults and the duck's source
-- names come from WARM
S.KIT_VOICES = { S.VOICES, S.WOOD_VOICES, S.FM_VOICES, S.GLITCH_VOICES }
for k = 2, #S.KIT_VOICES do
  for t, v in ipairs(S.KIT_VOICES[k]) do
    v.smp, v.choke = S.VOICES[t].smp, S.VOICES[t].choke
  end
end

-- a track's voice in a kit, the one it is playing if none is given
function S.voice(t, kit) return S.KIT_VOICES[kit or S.kit_of(t)][t] end

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
  -- C2 is the track's sends to the shared DELAY and SPRING, whose own
  -- controls are the SPACE cells on the master COLOUR page
  C2 = { a = P("DELAY", 0, 1, "lin", 0, "", { fmtf = pct, arg = "dsend", strip = true }),
         b = P("SPRING", 0, 1, "lin", 0, "", { fmtf = pct, arg = "ssend", strip = true }) },
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

-- The two parameters a button opens on a given voice (in the kit given, or
-- the one the track is playing), or nil for LFO buttons.
function S.pair(vi, btn, kit)
  local b = S.BTN[btn]
  if not b then return nil end
  if b.kind == "tone" then return S.voice(vi, kit).tone[btn] end
  if b.kind == "smp" then return S.SAMPLE[btn] end
  if b.kind == "noise" then return S.NOISE[btn] end
  if b.kind == "col" then return S.COL[btn] end
  if b.kind == "trig" or b.kind == "pulse" then return S.STEP[btn] end
  return nil
end

-- the keys that differ from kit to kit
function S.is_tone(key) return key:match("^T%d[ab]$") ~= nil end

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
function S.param(vi, key, kit)
  local btn, side = key:sub(1, -2), key:sub(-1)
  local pair = S.pair(vi, btn, kit)
  return pair and pair[side]
end

-- the engine argument a sound key is sent as
function S.arg(vi, key, kit)
  local p = S.param(vi, key, kit)
  if p and p.arg then return p.arg end
  return key:lower()   -- T1a -> t1a
end

-- ------------------------------------------------------------------- speeds

S.SPEEDS = { "1/32", "1/16T", "1/16", "1/8T", "1/8", "1/4" }
S.SPEED_BEATS = { 1 / 8, 1 / 6, 1 / 4, 1 / 3, 1 / 2, 1 }

-- MAIN's pairs, E1 picks one: E2 turns the first, E3 the second
S.MAIN_PAIRS = {
  { "LENGTH", "TIMING" },
  { "DIRECTION", "DILLA" },
}

-- the order a track walks its steps in (see lib/seq)
S.DIRS = { "FWD", "BWD", "PEND", "WALK", "RND" }

-- DILLA at 100 %, in pulses (see lib/seq). LEAN is where each voice sits
-- against the beat, by track: the kicks push a hair early, claps and snares
-- lay back, percussion a little late, hats and cymbal on the grid. SWAY is
-- how much of the way to a triplet each voice's off-beats are dragged, the
-- hats furthest. WANDER is the slow loose drift on top, JITTER hit to hit.
S.DILLA = {
  LEAN   = { -0.04, -0.03, 0.10, 0.12, 0.05, 0.06, 0.0, 0.02 },
  SWAY   = { 0.35, 0.35, 0.5, 0.5, 0.7, 0.7, 1.0, 0.9 },
  TRIP   = 1 / 3,   -- a sixteenth's off-beat moved onto the triplet
  WANDER = 0.05,
  JITTER = 0.03,
}
-- the furthest any of that can put a hit, for the tests and for sanity
S.DILLA_MAX = 0.12 + (1.0 / 3) + 0.05 + 0.03

S.SWING_GRID = { "1/16", "1/8" }
S.SWING_UNIT = { 1 / 4, 1 / 2 }

-- ------------------------------------------------------------------- LFOs

S.LFO_SHAPES = { "SINE", "TRI", "RAMP", "SQUARE", "S+H", "DRIFT" }

-- --------------------------------------------------------- master COLOUR
--
-- Four banks of cells, walked in order by E1:
--
--   BUSS     after Ableton's Drum Buss: comp > drive > crunch > damp >
--            transients > boom, MIX against the dry bus, then the level
--   DUCK     the sidechain: one track's hits duck the other seven
--   TEXTURE  Pappus' colour stage: tilt > loss > envelope-following noise
--            > wow, after the buss, then a Juno-style CHORUS
--   SPACE    the shared delay and spring every track's C2 sends into;
--            their returns go through the buss and the texture with the rest
--
-- E2 and E3 turn a cell's two halves. `to` is the engine command a cell's
-- values go to (colour if unset).

S.COLOUR_BANKS = { "BUSS", "DUCK", "TEXTURE", "SPACE" }

-- delay TIME, in beats, so it follows the tempo
local DTIMES = { "1/16", "1/8T", "1/8", "3/16", "1/4T", "1/4", "3/8", "1/2" }
local DBEATS = { 1 / 4, 1 / 3, 1 / 2, 3 / 4, 2 / 3, 1, 3 / 2, 2 }

-- the duck's source: off, or a track by its voice's name
local SOURCES = { "OFF" }
for t, v in ipairs(S.VOICES) do SOURCES[t + 1] = v.name end

S.COLOUR = {
  { name = "DRIVE", short = "DRV",
    a = P("DRIVE", 0, 1, "lin", 0, "", { fmtf = pct, arg = "drive" }),
    b = OPT("TYPE", { "SOFT", "MEDIUM", "HARD" }, 1, { arg = "drivetype" }) },
  { name = "CRUNCH", short = "CRN",
    a = P("CRUNCH", 0, 1, "lin", 0, "", { fmtf = pct, arg = "crunch" }),
    b = P("DAMP", 400, 20000, "exp", 20000, "Hz", { arg = "bussdamp", fmtf = function(v)
      if v > 19500 then return "OPEN" end
      return S.fmt({ unit = "Hz" }, v) end }) },
  { name = "TRANS", short = "TRN",
    a = P("TRANS", -1, 1, "lin", 0, "bi", { arg = "trans", fmtf = function(v)
      return string.format("%+d", math.floor(v * 100 + 0.5)) end }),
    b = P("COMP", 0, 1, "lin", 0, "", { fmtf = pct, arg = "comp" }) },
  { name = "BOOM", short = "BOM",
    a = P("BOOM", 0, 1, "lin", 0, "", { fmtf = pct, arg = "boom" }),
    b = P("FREQ", 30, 120, "exp", 55, "Hz", { arg = "boomfreq" }) },
  { name = "B.DECAY", short = "B.D",
    a = P("DECAY", 0.05, 1.5, "exp", 0.4, "s", { arg = "boomdecay" }),
    b = P("TILT", -1, 1, "lin", 0, "bi", { arg = "ctilt" }) },
  { name = "OUT", short = "OUT",
    a = P("MIX", 0, 1, "lin", 1, "", { fmtf = pct, arg = "bussmix" }),
    b = P("LEVEL", 0, 1.5, "lin", 1, "", { fmtf = pct, arg = "outlvl" }) },

  { name = "DUCK", short = "DCK", bank = 2, to = "duck",
    a = OPT("SOURCE", SOURCES, 1, { arg = "scsrc", zero = true }),
    b = P("AMOUNT", 0, 1, "lin", 0.5, "", { fmtf = pct, arg = "scamt" }) },
  { name = "RELEASE", short = "REL", bank = 2, to = "duck",
    a = P("RELEASE", 0.02, 1.5, "exp", 0.18, "s", { arg = "screl" }),
    b = P("FX", 0, 1, "lin", 0.5, "", { fmtf = pct, arg = "scfx" }) },

  { name = "LOSS", short = "LOS", bank = 3,
    a = P("LOSS", 0, 1, "lin", 0, "", { fmtf = pct, arg = "loss" }),
    b = P("WOW", 0, 1, "lin", 0, "", { fmtf = pct, arg = "wow" }) },
  { name = "NOISE", short = "NOI", bank = 3,
    a = P("NOISE", 0, 1, "lin", 0, "", { fmtf = pct, arg = "noise" }),
    b = OPT("TYPE", { "WHITE", "PINK", "DUST", "CRACKL", "HISS" }, 2, { arg = "noisetype" }) },
  { name = "N.SHAPE", short = "N.S", bank = 3,
    a = P("N.DEC", 0.01, 4, "exp", 0.25, "s", { arg = "noisedecay" }),
    b = P("N.TONE", 60, 12000, "exp", 1200, "Hz", { arg = "noisetone" }) },
  -- a Juno's chorus: CHORUS is how much (half and half at the top), RATE
  -- and DEPTH the sweep, BBD how much of the bucket brigade's dark, soft,
  -- faintly hissing character comes with it
  { name = "CHORUS", short = "CHO", bank = 3,
    a = P("CHORUS", 0, 1, "lin", 0, "", { fmtf = pct, arg = "chorus" }),
    b = P("RATE", 0.05, 8, "exp", 0.5, "Hz", { arg = "chrate", fmtf = function(v)
      return string.format(v < 1 and "%.2f Hz" or "%.1f Hz", v) end }) },
  { name = "C.SHAPE", short = "C.S", bank = 3,
    a = P("DEPTH", 0, 1, "lin", 0.5, "", { fmtf = pct, arg = "chdepth" }),
    b = P("BBD", 0, 1, "lin", 0.3, "", { fmtf = pct, arg = "chbbd" }) },

  { name = "DELAY", short = "DLY", bank = 4, to = "fx",
    a = OPT("TIME", DTIMES, 4, { arg = "dtime", beats = DBEATS }),
    b = P("FEEDBK", 0, 1.1, "lin", 0.35, "", { fmtf = pct, arg = "fdbk" }) },
  { name = "D.SHAPE", short = "D.S", bank = 4, to = "fx",
    a = P("D.TONE", 300, 16000, "exp", 3500, "Hz", { arg = "dtone" }),
    b = P("PING", 0, 1, "lin", 0.6, "", { fmtf = pct, arg = "ping" }) },
  -- the SPRING tank: DECAY is how long it rings, TONE where its top goes,
  -- DWELL how hard the input transducer is driven (louder, longer, dirtier)
  -- and DRIP how far each echo smears into a falling chirp
  { name = "SPRING", short = "SPR", bank = 4, to = "fx",
    a = P("DECAY", 0.3, 8, "exp", 2.2, "s", { arg = "sdecay" }),
    b = P("TONE", 800, 7000, "exp", 3800, "Hz", { arg = "stone" }) },
  { name = "S.SHAPE", short = "S.S", bank = 4, to = "fx",
    a = P("DWELL", 0, 1, "lin", 0.4, "", { fmtf = pct, arg = "dwell" }),
    b = P("DRIP", 0, 1, "lin", 0.5, "", { fmtf = pct, arg = "drip" }) },
  { name = "RETURN", short = "RET", bank = 4, to = "fx",
    a = P("DELAY", 0, 1.5, "lin", 0.8, "", { fmtf = pct, arg = "dret" }),
    b = P("SPRING", 0, 1.5, "lin", 0.8, "", { fmtf = pct, arg = "sret" }) },
}

-- each bank's cells in order, as indices into S.COLOUR
S.BANK_CELLS = {}
for b = 1, #S.COLOUR_BANKS do S.BANK_CELLS[b] = {} end
for i, cell in ipairs(S.COLOUR) do
  cell.bank = cell.bank or 1
  local list = S.BANK_CELLS[cell.bank]
  list[#list + 1] = i
  cell.row = #list   -- its row on the grid, and its slot on the screen
end

return S
