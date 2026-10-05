-- drumdrum / snapshots
--
-- Sixty-four snapshots, one per sequencer cell. A snapshot is the whole
-- machine: every drumdrum param (every kit's sound and which kit each track
-- is on, samples, mix, LFO settings, swing, master COLOUR and SPACE, ANALOG
-- and HISS, the hidden TAPE's pitch and length), everything the data file
-- carries (steps, lengths, speeds, mutes, templates, LFO patch points, every
-- track's seven clip slots and which one is playing) and
-- the selected track. PERFORM latches are not: they are hands on the
-- machine, not the machine. Tempo is in it too, but only lands while the
-- clock is internal: under MIDI, Link or crow the tempo belongs to whoever
-- runs it.
--
-- A BLANK cell loads the INIT patch: every param at its default and no
-- steps anywhere -- the state the script starts in.
--
-- DELETING is a hold as well: SHIFT + STOP + cell, and the cell drains as
-- you hold. Let go before it is empty and nothing is removed.
--
-- SAVING is a hold, as in Pappus: SHIFT + cell, and the cell fills as you
-- keep holding. Let go before it is full and nothing is written.
--
-- LOADING is a tap, and while the transport runs it lands ON THE NEXT BEAT
-- and every track starts again from step 1 there. Tracks of different
-- lengths and speeds drift apart as they play (that is the point of them),
-- and a snapshot carried into wherever each one happens to be would land as
-- a beat nobody saved. Pattern and sound go in together a sixty-fourth of a
-- beat before it, so the hit on the beat is the first of the new snapshot.
--
-- Stopped, a load is immediate.

local S = include("drumdrum/lib/spec")

local N = {}
local St, Q, L, C

N.COUNT = S.NSTEPS
N.HOLD = 0.6

N.slots = {}         -- slot -> snapshot, or nil
N.last = 0           -- the slot loaded or saved most recently
N.act = nil          -- a save or delete being held: { slot, t0, kind }
N.pending = nil      -- a load waiting for its beat: { slot, beat, snap, co }
N.pulse = {}         -- slot -> 0..1, a flash after a save or a load lands

local LEAD = 1 / 64

function N.init(state, seq, lfo, clips)
  St, Q, L, C = state, seq, lfo, clips
  for i = 1, N.COUNT do N.pulse[i] = 0 end
end

-- ------------------------------------------------------------------- copying

local function copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, e in pairs(v) do out[k] = copy(e) end
  return out
end

-- every param a snapshot holds, built once params exist
local ids

local function param_ids()
  if ids then return ids end
  ids = {}
  for t = 1, S.NTRACKS do
    -- every kit's tone params, not just the one playing
    for _, key in ipairs(St.KEYS) do
      if S.is_tone(key) then
        for k = 1, #S.KITS do ids[#ids + 1] = St.pid(t, key, k) end
      elseif not S.param(t, key).special then
        ids[#ids + 1] = St.pid(t, key)
      end
    end
    for _, k in ipairs({ "kit", "file", "level", "pan", "tilt" }) do
      ids[#ids + 1] = St.pid(t, k)
    end
    for i = 1, 2 do
      for _, k in ipairs({ "rate", "depth", "shape" }) do
        ids[#ids + 1] = St.pid(t, "l" .. i .. "_" .. k)
      end
    end
  end
  for _, id in ipairs({ "swing", "swing_grid", "rain", "analog", "hiss", "tape_pitch", "tape_len" }) do
    ids[#ids + 1] = id
  end
  for _, cell in ipairs(S.COLOUR) do
    ids[#ids + 1] = "col_" .. cell.a.arg
    ids[#ids + 1] = "col_" .. cell.b.arg
  end
  ids[#ids + 1] = "col_bypass"
  return ids
end

local function capture()
  local snap = { p = {}, tracks = {}, sel = St.sel, tempo = params:get("clock_tempo") }
  for _, id in ipairs(param_ids()) do snap.p[id] = params:get(id) end
  for t, tr in ipairs(St.tracks) do
    snap.tracks[t] = {
      steps = copy(tr.steps), len = tr.len, speed = tr.speed, mute = tr.mute,
      dir = tr.dir, dilla = tr.dilla,
      tpl = copy(tr.tpl), lfo = L.save(t), clips = C.save(t),
    }
  end
  return snap
end

local function apply_track(snap, t)
  local e = snap.tracks[t]
  local tr = St.tracks[t]
  if not (e and tr) then return end
  tr.steps = copy(e.steps or {})
  tr.len = e.len or 16
  tr.speed = e.speed or 3
  tr.dir = e.dir or 1
  tr.dilla = e.dilla or 0
  tr.tpl = copy(e.tpl or tr.tpl)
  if e.lfo then L.load(t, e.lfo) end
  -- a snapshot from before the clips: what it played becomes slot 1
  C.load(t, e.clips)
end

-- mutes go with the sound, not the pattern: a track's new steps arrive a
-- pulse early, and muting then would cut the last hit before the beat
local function apply_params(snap)
  for t, e in ipairs(snap.tracks) do
    local m = e.mute or false
    if St.tracks[t] and St.tracks[t].mute ~= m then St.set_mute(t, m) end
  end
  for id, v in pairs(snap.p) do
    -- a snapshot from an older drumdrum can name a param that is gone
    -- (the reverb's, before it was a spring); a sample is only re-read
    -- when it is a different file
    local known = (params.lookup == nil) or (params.lookup[id] ~= nil)
    if known and params:get(id) ~= v then params:set(id, v) end
  end
  -- a snapshot from before the kits was a WARM one
  for t = 1, S.NTRACKS do
    if snap.p[St.pid(t, "kit")] == nil then St.set_kit(t, 1) end
  end
  if snap.tempo and params:get("clock_source") == 1
    and params:get("clock_tempo") ~= snap.tempo then
    params:set("clock_tempo", snap.tempo)
  end
  if snap.sel then St.select(snap.sel) end
end

-- the INIT patch: taken once params exist and before anything is loaded
-- over them, so it is exactly the state a fresh start is in
local init_snap

function N.capture_init()
  init_snap = capture()
  init_snap.tempo = nil   -- a blank cell should not yank the tempo about
end

-- ----------------------------------------------------------------- disk

local function path()
  if norns and norns.state and norns.state.data then
    return norns.state.data .. "drumdrum-snapshots.data"
  end
end

function N.save_file()
  local p = path()
  if p and tab and tab.save then pcall(tab.save, { v = 1, slots = N.slots }, p) end
end

function N.load_file()
  local p = path()
  if not (p and tab and tab.load and util.file_exists(p)) then return end
  local ok, d = pcall(tab.load, p)
  if ok and d and d.v == 1 and d.slots then N.slots = d.slots end
end

-- ----------------------------------------------------------------- save

function N.store(i)
  if i < 1 or i > N.COUNT then return end
  N.slots[i] = capture()
  N.last = i
  N.pulse[i] = 1
  N.save_file()
  St.dirty = true
end

function N.hold_start(i, kind)
  -- nothing to delete in a blank cell
  if kind == "delete" and not N.slots[i] then return end
  N.act = { slot = i, t0 = util.time(), kind = kind or "save" }
end

function N.delete(i)
  if not N.slots[i] then return end
  N.slots[i] = nil
  if N.last == i then N.last = 0 end
  N.save_file()
  St.dirty = true
end

local function commit(a)
  if a.kind == "delete" then N.delete(a.slot) else N.store(a.slot) end
end

-- how far a held save has got, 0..1
function N.progress()
  local a = N.act
  if not a then return 0 end
  return util.clamp((util.time() - a.t0) / N.HOLD, 0, 1)
end

-- called every grid frame: commit the moment the hold completes, still held
function N.tick(dt)
  local a = N.act
  if a and not a.done and N.progress() >= 1 then
    a.done = true
    commit(a)
  end
  for i = 1, N.COUNT do
    if N.pulse[i] > 0 then N.pulse[i] = math.max(0, N.pulse[i] - (dt / 0.45)) end
  end
end

function N.hold_end(i)
  local a = N.act
  if not (a and a.slot == i) then return end
  N.act = nil
  -- the clock as well as the tick: a stuttered frame must not lose a save
  if not a.done and (util.time() - a.t0) >= N.HOLD then commit(a) end
end

-- ----------------------------------------------------------------- load

local function finish(p)
  for t = 1, S.NTRACKS do apply_track(p.snap, t) end
  apply_params(p.snap)
  N.last = p.slot
  N.pulse[p.slot] = 1
  St.dirty = true
end

function N.recall(i)
  local snap = N.slots[i] or init_snap
  if not snap then return end
  if N.pending and N.pending.co then clock.cancel(N.pending.co) end
  N.pending = nil

  -- stopped, or PLAY still waiting for its bar (which starts from step 1
  -- anyway): straight in
  if not St.playing or Q.waiter then
    finish({ slot = i, snap = snap })
    return
  end

  -- the next beat there is still time to get in ahead of
  local beat = math.floor(clock.get_beats() + LEAD + Q.lead() + 1e-6) + 1

  local p = { slot = i, beat = beat, snap = snap }
  N.pending = p
  p.co = clock.run(function()
    -- in before the first hit, which leads the beat by the SYNC LEAD
    local at = beat - LEAD - Q.lead()
    while clock.get_beats() < at - 1e-4 do clock.sync(LEAD) end
    if N.pending ~= p then return end
    N.pending = nil
    finish(p)
    Q.restart(beat)
  end)
  St.dirty = true
end

function N.has(i) return N.slots[i] ~= nil end

return N
