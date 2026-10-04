-- drumdrum / state
--
-- The tracks, the params behind them, and the one function that turns a step
-- into a sound: St.hit.
--
-- Every sound parameter is a norns param, so it saves with a PSET and maps to
-- MIDI for free. What a param holds is the track's BASE value. On the way to
-- the engine a value can be replaced by a step's lock and then moved by the
-- track's LFOs, both in the param's normalised 0..1 space, and only then
-- mapped to physical units. The voice is one-shot and latches everything at
-- the trigger, so that is the only moment the effective value has to exist.
--
-- The channel strip is the exception: it runs continuously, so its four
-- COLOUR controls are re-sent whenever an LFO moves them.

local S = include("drumdrum/lib/spec")

local St = {}

St.sel = 1
St.page = "main"       -- main | mix | colour
St.playing = false
St.fill = false
St.dirty = true
St.col_sel = 1         -- the master COLOUR cell E1 is on
St.meter = {}          -- per track, linear amplitude from the engine
St.outamp = 0
St.tracks = {}
St.lfo = nil           -- set by the main script, read here for modulation
St.on_hit = nil        -- hook for the screen: a voice just fired

local KEYS = S.sound_keys()
St.KEYS = KEYS

local AUDIO_EXT = { wav = true, aif = true, aiff = true, flac = true }

function St.pid(t, key) return "t" .. t .. "_" .. key end

function St.track(t) return St.tracks[t or St.sel] end

local function new_track(t)
  local tpl = S.new_step()
  tpl.on = nil
  return {
    idx = t,
    steps = {},
    len = 16,
    speed = 3,          -- 1/16
    mute = false,
    tpl = tpl,          -- what a newly placed step starts as
    -- sequencer position, all owned by lib/seq
    pos = 0, pulse = 1, npulses = 1, loop = 0, pass = false, pre = false,
    ph = 0,             -- the step you can HEAR, for the grid and screen
    flash = 0,
    -- samples
    folder = nil, files = {}, fidx = 0, gen = 0,
    -- what the engine was last told, so a hit only sends what changed
    sent = {}, ssent = {}, strip_lock = {},
  }
end

function St.init()
  for t = 1, S.NTRACKS do
    St.tracks[t] = new_track(t)
    St.meter[t] = 0
  end
end

-- ------------------------------------------------------------------- values

local function cs(id) return params:lookup_param(id).controlspec end

-- a param's normalised position, 0..1
function St.raw(t, key) return params:get_raw(St.pid(t, key)) end

-- base or lock, plus the LFOs, mapped to physical units
function St.eff(t, key, lock)
  local id = St.pid(t, key)
  local r = lock or params:get_raw(id)
  if St.lfo then r = r + St.lfo.mod(t, key) end
  if r < 0 then r = 0 elseif r > 1 then r = 1 end
  return cs(id):map(r)
end

-- turn a param by encoder detents in normalised space: an integer param moves
-- one value a detent, a continuous one a hundredth (a thousandth when fine)
function St.raw_step(id, fine)
  local c = cs(id)
  if c.step and c.step > 0 then return c.step / (c.maxval - c.minval) end
  return fine and 0.002 or 0.01
end

function St.delta(id, d, fine)
  local r = params:get_raw(id) + (d * St.raw_step(id, fine))
  params:set_raw(id, util.clamp(r, 0, 1))
end

-- ------------------------------------------------------------- strip values

function St.push_strip(t, key)
  local tr = St.tracks[t]
  local p = S.param(t, key)
  local v = St.eff(t, key, tr.strip_lock[key])
  if tr.ssent[p.arg] ~= v then
    tr.ssent[p.arg] = v
    engine.strip(t - 1, p.arg, v)
  end
end

-- only the strip keys an LFO is actually moving need re-sending each frame
function St.push_modulated()
  if not St.lfo then return end
  for t = 1, S.NTRACKS do
    for _, key in ipairs({ "C1a", "C1b", "C2a", "C2b" }) do
      if St.lfo.targets(t, key) or St.tracks[t].strip_lock[key] then
        St.push_strip(t, key)
      end
    end
  end
end

-- ---------------------------------------------------------------------- hit

function St.hit(t, vel, pitch, decm, mix, locks)
  local tr = St.tracks[t]
  if tr.mute then return end
  for _, key in ipairs(KEYS) do
    local p = S.param(t, key)
    if not p.special then
      local lock = locks and locks[key]
      if p.strip then
        -- a lock on a strip control holds until the next hit that has none
        tr.strip_lock[key] = lock
        St.push_strip(t, key)
      else
        local v = St.eff(t, key, lock)
        if p.zero then v = v - 1 end
        local a = S.arg(t, key)
        if tr.sent[a] ~= v then
          tr.sent[a] = v
          engine.set(t - 1, a, v)
        end
      end
    end
  end
  engine.trig(t - 1, util.clamp(vel, 0, 1), pitch, decm, util.clamp(mix, -1, 1))
  tr.flash = 1
  if St.on_hit then St.on_hit(t, vel) end
end

-- a hit with the track's own values, for auditioning
function St.audition(t)
  St.hit(t, 1, 0, 1, 0, nil)
end

-- ----------------------------------------------------------------- tracks

function St.select(t)
  St.sel = util.clamp(t, 1, S.NTRACKS)
  St.dirty = true
end

function St.set_mute(t, m)
  local tr = St.tracks[t]
  tr.mute = m
  engine.strip(t - 1, "mute", m and 1 or 0)
  St.dirty = true
end

function St.toggle_mute(t) St.set_mute(t, not St.tracks[t].mute) end

-- ----------------------------------------------------------------- samples
--
-- A track's sample is a file param. Choosing any file in the PARAMS menu
-- points the track at that file's folder; S1's E2 then walks the folder.

local function basename(p) return p:match("([^/]+)$") or p end
St.basename = basename

local function scan(folder)
  local out = {}
  if util.scandir then
    local ok, list = pcall(util.scandir, folder)
    if ok and list then
      for _, f in ipairs(list) do
        local ext = f:match("%.(%w+)$")
        if ext and AUDIO_EXT[ext:lower()] then out[#out + 1] = f end
      end
    end
  end
  table.sort(out)
  return out
end

function St.on_file(t, path)
  local tr = St.tracks[t]
  if path and path ~= "" and not path:match("/$") and util.file_exists(path) then
    local folder = path:match("^(.*/)")
    if folder ~= tr.folder then
      tr.folder = folder
      tr.files = scan(folder)
    end
    tr.fidx = 0
    local name = basename(path)
    for i, f in ipairs(tr.files) do
      if f == name then tr.fidx = i break end
    end
    tr.path = path
    engine.sample(t - 1, path)
  else
    tr.path = nil
    engine.sampleClear(t - 1)
  end
  St.dirty = true
end

function St.sample_name(t)
  local tr = St.tracks[t]
  if tr.fidx > 0 and tr.files[tr.fidx] then return tr.files[tr.fidx] end
  if tr.path then return basename(tr.path) end
  return "no sample"
end

-- Scrolling through a folder shows the name at once and loads only once the
-- encoder has rested, so a fast turn does not queue twenty buffer reads.
function St.sample_delta(t, d)
  local tr = St.tracks[t]
  if not tr.folder or #tr.files == 0 then return end
  tr.fidx = util.clamp((tr.fidx == 0 and 1 or tr.fidx) + d, 1, #tr.files)
  tr.gen = tr.gen + 1
  local g = tr.gen
  clock.run(function()
    clock.sleep(0.25)
    if tr.gen == g then
      params:set(St.pid(t, "file"), tr.folder .. tr.files[tr.fidx])
    end
  end)
  St.dirty = true
end

-- Norns ships an 808 kit in audio/common/808. Each track is pointed at the
-- matching file if it is there, with the sample layer at zero: the synth is
-- the voice, the sample is something you bring in.
local function default_sample(t)
  local dir = _path and (_path.audio .. "common/808/") or nil
  if not dir then return "" end
  local files = scan(dir)
  local want = S.VOICES[t].smp
  for _, f in ipairs(files) do
    if f:upper():find(want, 1, true) then return dir .. f end
  end
  return files[1] and (dir .. files[1]) or (_path.audio or "")
end

-- ------------------------------------------------------------------ params

local function add_spec_param(id, p, action)
  local step = p.step or 0
  local quantum = (step > 0) and (step / (p.hi - p.lo)) or 0.01
  params:add_control(id, p.name:lower(),
    controlspec.new(p.lo, p.hi, p.warp, step, p.def, p.unit ~= "bi" and p.unit or "", quantum),
    function(param) return S.fmt(p, param:get()) end)
  params:set_action(id, action)
end

function St.build_params()
  for t = 1, S.NTRACKS do
    local v = S.VOICES[t]
    -- sound keys less S1a (the sample select, which is the file param), plus
    -- the file, level pan tilt, and three per LFO
    params:add_group("dd_t" .. t, t .. " " .. v.name, (#KEYS - 1) + 1 + 3 + 6)

    for _, key in ipairs(KEYS) do
      local p = S.param(t, key)
      if not p.special then
        add_spec_param(St.pid(t, key), p, function()
          if p.strip then St.push_strip(t, key) end
          St.dirty = true
        end)
      end
    end

    params:add_file(St.pid(t, "file"), "sample", default_sample(t))
    params:set_action(St.pid(t, "file"), function(path) St.on_file(t, path) end)

    params:add_control(St.pid(t, "level"), "level", controlspec.new(0, 1, "lin", 0, 0.8, ""))
    params:set_action(St.pid(t, "level"), function(x)
      engine.strip(t - 1, "level", x) St.dirty = true end)
    params:add_control(St.pid(t, "pan"), "pan", controlspec.new(-1, 1, "lin", 0, 0, ""))
    params:set_action(St.pid(t, "pan"), function(x)
      engine.strip(t - 1, "pan", x) St.dirty = true end)
    params:add_control(St.pid(t, "tilt"), "tilt", controlspec.new(-1, 1, "lin", 0, 0, ""))
    params:set_action(St.pid(t, "tilt"), function(x)
      engine.strip(t - 1, "tilt", x) St.dirty = true end)

    for i = 1, 2 do
      local pre = St.pid(t, "l" .. i .. "_")
      params:add_control(pre .. "rate", "lfo " .. i .. " rate",
        controlspec.new(0.02, 20, "exp", 0, 0.5 * i, "Hz"))
      params:add_control(pre .. "depth", "lfo " .. i .. " depth",
        controlspec.new(-1, 1, "lin", 0, 0.4, ""))
      params:add_control(pre .. "shape", "lfo " .. i .. " shape",
        controlspec.new(1, #S.LFO_SHAPES, "lin", 1, 1, "", 1 / (#S.LFO_SHAPES - 1)),
        function(param) return S.LFO_SHAPES[math.floor(param:get() + 0.5)] or "-" end)
    end
  end

  params:add_group("dd_seq", "SEQUENCER", 2)
  params:add_control("swing", "swing", controlspec.new(50, 75, "lin", 0, 50, "%", 1 / 25))
  params:set_action("swing", function() St.dirty = true end)
  params:add_option("swing_grid", "swing grid", S.SWING_GRID, 1)
  params:set_action("swing_grid", function() St.dirty = true end)

  params:add_group("dd_colour", "COLOUR", (#S.COLOUR * 2) + 1)
  for _, cell in ipairs(S.COLOUR) do
    for _, side in ipairs({ "a", "b" }) do
      local p = cell[side]
      add_spec_param("col_" .. p.arg, p, function(x)
        engine.colour(p.arg, x)
        St.dirty = true
      end)
    end
  end
  params:add_option("col_bypass", "colour bypass", { "off", "on" }, 1)
  params:set_action("col_bypass", function(x) engine.colour("bypass", x - 1) St.dirty = true end)
end

-- --------------------------------------------------------------- persistence
--
-- Params carry the sound. The data file carries what params cannot: steps,
-- lengths, speeds, mutes, templates and the LFO patch points.

St.DATA_VERSION = 1

function St.serialize()
  local out = { v = St.DATA_VERSION, sel = St.sel, tracks = {} }
  for t, tr in ipairs(St.tracks) do
    out.tracks[t] = {
      steps = tr.steps, len = tr.len, speed = tr.speed, mute = tr.mute,
      tpl = tr.tpl, lfo = St.lfo and St.lfo.save(t) or nil,
    }
  end
  return out
end

function St.deserialize(d)
  if not d or d.v ~= St.DATA_VERSION or not d.tracks then return end
  for t, e in ipairs(d.tracks) do
    local tr = St.tracks[t]
    if tr and e then
      tr.steps = e.steps or {}
      tr.len = e.len or 16
      tr.speed = e.speed or 3
      tr.tpl = e.tpl or tr.tpl
      St.set_mute(t, e.mute or false)
      if St.lfo and e.lfo then St.lfo.load(t, e.lfo) end
    end
  end
  St.sel = d.sel or 1
  St.dirty = true
end

return St
