-- drumdrum / sampler
--
-- Recording a track's sample. Hold S1 and the 64 steps are a length: tap
-- one and the selected track is ARMED to record that many of its own steps
-- (at its own speed, never more than 20 seconds, so at slow tempos the
-- steps past 20 s stay dark). Tap the same step again to disarm.
--
-- While armed the MAIN screen is the REC panel:
--
--   E1  START   THRESH  the first hit louder than LEVEL starts it, with
--                       10 ms of what came before so the attack is kept
--               PLAY    on step 1: the next PLAY, or the next bar if playing
--               NOW     at once
--   E2  LEVEL   the THRESH threshold, against the source's meter
--   E3  SOURCE  the inputs (L+R, L, R), the MIX as you hear it, or one
--               track's own voices, locks and LFOs and all
--   K2  cancel     K3  start now, or end a take early and keep it
--
-- A take is normalised, rounded off at both ends, written to
-- dust/audio/drumdrum/rec/ and loaded onto the track like any other file,
-- so it saves with PSETs and snapshots and S1's E2 walks the takes. The
-- first take on a track whose sample LEVEL is down turns it up.
--
-- The engine keeps the state (lib/Engine_DrumDrum.sc, "SAMPLER"); lua
-- hears it through four polls.

local S = include("drumdrum/lib/spec")

local R = {}
local St, Q

R.MODES = { "THRESH", "PLAY", "NOW" }
R.SRCS = { "IN L+R", "IN L", "IN R", "MIX" }
for t = 1, S.NTRACKS do R.SRCS[#R.SRCS + 1] = S.VOICES[t].name end
R.MAX_SEC = 20

R.t = nil         -- the armed track, nil when nothing is
R.steps = 0       -- how many of its steps
R.waiting = nil   -- PLAY: the coroutine waiting for the bar line, or true for PLAY
R.eng = 0         -- the engine's state: 0 off 1 armed 2 listening 3 recording 4 writing
R.seen = false    -- the engine has got past armed since we armed it
R.level = 0       -- the source's amplitude
R.prog = 0        -- 0..1 through a take
R.done = nil      -- the engine's count of finished takes, last we heard
R.path = nil
R.take = nil      -- { t, path } of the take the engine is making, until it lands

function R.init(state, seq)
  St, Q = state, seq
end

function R.add_params()
  params:add_group("dd_rec", "SAMPLER", 3)
  St.DEFAULTS.rec_mode = 1
  St.DEFAULTS.rec_thresh = -30
  St.DEFAULTS.rec_src = 1
  params:add_option("rec_mode", "rec start", R.MODES, 1)
  params:set_action("rec_mode", function() R.rearm() end)
  params:add_control("rec_thresh", "rec threshold",
    controlspec.new(-60, -3, "lin", 0, -30, "dB", 1 / 57))
  params:set_action("rec_thresh", function() R.resend() end)
  params:add_option("rec_src", "rec source", R.SRCS, 1)
  params:set_action("rec_src", function() R.resend() end)
end

-- --------------------------------------------------------------- lengths

local function div(t) return S.SPEED_BEATS[St.tracks[t].speed] or 0.25 end

-- the most steps of track t that fit in 20 seconds
function R.max_steps(t)
  local sec = div(t) * clock.get_beat_sec()
  return util.clamp(math.floor((R.MAX_SEC / sec) + 1e-6), 1, S.NSTEPS)
end

local function seconds()
  return math.min(R.steps * div(R.t) * clock.get_beat_sec(), R.MAX_SEC)
end

-- --------------------------------------------------------------- arming

function R.active() return R.t ~= nil end
function R.busy() return R.eng >= 3 end

local function thresh() return 10 ^ (params:get("rec_thresh") / 20) end

-- source, and the track a TRACK source is
local function src()
  local s = params:get("rec_src") - 1
  if s >= 4 then return 4, s - 4 end
  return s, 0
end

-- the engine's recorder on, at the current source and threshold
function R.resend()
  if not R.t or R.busy() then return end
  local s, tt = src()
  engine.sampArm(s, tt, thresh(), R.path)
  St.dirty = true
end

local function stop_waiting()
  if type(R.waiting) == "number" then clock.cancel(R.waiting) end
  R.waiting = nil
end

function R.go()
  stop_waiting()
  if R.t then engine.sampStart(seconds()) end
end

-- how the armed take starts, by START
local function start_mode()
  stop_waiting()
  local m = R.MODES[params:get("rec_mode")]
  if m == "THRESH" then
    engine.sampListen(seconds())
  elseif m == "NOW" then
    R.go()
  elseif St.playing and not Q.waiter then
    -- playing: on the next bar line
    R.waiting = clock.run(function()
      clock.sync(Q.bar())
      R.waiting = nil
      if R.t and not R.busy() then R.go() end
    end)
  else
    -- stopped: on the next PLAY (R.on_begin)
    R.waiting = true
  end
end

function R.arm(t, steps)
  if R.busy() then return end
  steps = math.min(steps, R.max_steps(t))
  if R.t == t and R.steps == steps then return R.cancel() end
  local dir = _path.audio .. "drumdrum/rec/"
  if util.make_dir then util.make_dir(dir) end
  -- a different arm before this one: off first, so a THRESH that was
  -- listening does not start this take
  if R.t then engine.sampCancel() end
  R.t, R.steps, R.seen = t, steps, false
  R.path = dir .. string.format("%s-%s.wav", S.VOICES[t].name:lower():gsub("%W", ""),
    os.date("%y%m%d-%H%M%S"))
  R.take = { t = t, path = R.path }
  R.resend()
  start_mode()
  St.dirty = true
end

-- START changed while armed: start over the new way
function R.rearm()
  if R.t and not R.busy() then
    engine.sampCancel()
    R.seen = false
    R.resend()
    start_mode()
  end
  St.dirty = true
end

function R.cancel()
  stop_waiting()
  if R.t then engine.sampCancel() end
  -- one already being written still lands
  if R.eng < 4 then R.take = nil end
  R.t, R.steps, R.prog = nil, 0, 0
  St.dirty = true
end

-- K3: start now, or end a take early
function R.now()
  if not R.t then return end
  if R.eng == 3 then engine.sampStop()
  elseif not R.busy() then R.go() end
  St.dirty = true
end

-- Q.start: beat 0 of a PLAY, which is step 1
function R.on_begin()
  if R.t and R.waiting == true then R.go() end
end

-- ----------------------------------------------------------------- polls

local function finished()
  local take = R.take
  R.take = nil
  if R.t == (take and take.t) and not R.waiting then R.t, R.steps, R.prog = nil, 0, 0 end
  if not take then return end
  local t = take.t
  params:set(St.pid(t, "file"), take.path)
  -- a take you cannot hear is no use: the first one brings the layer up
  local lvl = St.pid(t, "S1b")
  if params:get(lvl) < 0.01 then params:set(lvl, 1) end
end

function R.on_state(v)
  v = math.floor((v or 0) + 0.5)
  R.eng = v
  if v >= 2 then R.seen = true end
  -- back to off: the take is done (or was too short to keep) and the
  -- track is no longer armed. Loading it is R.on_done's.
  if v == 0 and R.seen and R.t and not R.waiting then
    R.t, R.steps, R.prog = nil, 0, 0
  end
  St.dirty = true
end

function R.on_done(v)
  v = math.floor((v or 0) + 0.5)
  if R.done == nil then R.done = v return end
  if v > R.done then
    R.done = v
    finished()
  end
end

R.POLLS = {
  sampstate = function(v) R.on_state(v) end,
  sampdone = function(v) R.on_done(v) end,
  samplvl = function(v) R.level = v or 0 end,
  sampprog = function(v) R.prog = v or 0 end,
}

-- what the screen says it is doing
function R.status()
  if not R.t then return "" end
  if R.eng == 4 then return "SAVING" end
  if R.eng == 3 then return "RECORDING" end
  if R.waiting == true then return "WAIT FOR PLAY" end
  if R.waiting then return "NEXT BAR" end
  if R.eng == 2 then return "LISTENING" end
  return "ARMED"
end

return R
