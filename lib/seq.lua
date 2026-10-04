-- drumdrum / seq
--
-- Eight independent sequencers, one clock coroutine each.
--
-- THE SEQUENCER RUNS ONE PULSE AHEAD OF WHAT YOU HEAR. Each coroutine wakes
-- on its own grid line, works out what happens on the NEXT pulse, and
-- schedules it a pulse from now plus swing plus the step's nudge. That is
-- what lets a nudge go early as well as late: an early step is just a
-- shorter wait. The playhead the grid draws is moved by the scheduled event,
-- so it lands when the sound does, not when the sequencer thought about it.
--
-- PULSES, after the Metropolix. A step owns 1-8 pulses of the track's clock,
-- so a step with four pulses holds the playhead for four steps' worth of
-- time and the pattern stretches around it. What happens inside that time is
-- the step's MODE:
--
--   WAIT     one hit, then rest for the remaining pulses
--   REPEAT   a hit on every pulse (a ratchet that takes up real time)
--   SUSTAIN  one hit with its decay stretched across the pulses
--   EDGE     a hit on the first and the last pulse
--   SCATTER  the first pulse always, each one after it on a coin toss
--
-- RAMP shapes the velocity across those hits and BEND walks their pitch.

local S = include("drumdrum/lib/spec")

local Q = {}
local St

function Q.init(state) St = state end

-- --------------------------------------------------------------- conditions
--
-- Elektron's set. A:B fires on the A-th of every B passes of the pattern.
-- PRE is whether the last condition on this track passed, NEI the same for
-- the track to the left. PRE and NEI do not themselves count as "the last
-- condition", or chaining them would only ever look at themselves.

function Q.cond(tr, t, st)
  local c = S.CONDS[st.cond] or "ALWAYS"
  local res
  if c == "ALWAYS" then res = true
  elseif c == "FILL" then res = St.fill
  elseif c == "!FILL" then res = not St.fill
  elseif c == "PRE" then res = tr.pre
  elseif c == "!PRE" then res = not tr.pre
  elseif c == "NEI" or c == "!NEI" then
    local nb = St.tracks[(t == 1) and S.NTRACKS or (t - 1)]
    res = nb.pre
    if c == "!NEI" then res = not res end
  elseif c == "1ST" then res = (tr.loop == 0)
  elseif c == "!1ST" then res = (tr.loop ~= 0)
  else
    local a, b = c:match("^(%d):(%d)$")
    a, b = tonumber(a), tonumber(b)
    res = (a and b) and ((tr.loop % b) == (a - 1)) or true
  end
  if res and (st.prob or 100) < 100 then
    res = math.random(100) <= st.prob
  end
  if c ~= "PRE" and c ~= "!PRE" and c ~= "NEI" and c ~= "!NEI" then
    tr.pre = res
  end
  return res
end

-- -------------------------------------------------------------------- step

function Q.advance(tr)
  if tr.pulse < tr.npulses then
    tr.pulse = tr.pulse + 1
    return
  end
  tr.pulse = 1
  tr.pos = tr.pos + 1
  if tr.pos > tr.len then
    tr.pos = 1
    tr.loop = tr.loop + 1
  end
  local st = tr.steps[tr.pos]
  tr.npulses = (st and st.on) and (st.pulses or 1) or 1
end

-- what the current pulse plays, or nil
function Q.hit_for(tr, t)
  local st = tr.steps[tr.pos]
  if not (st and st.on) then return nil end
  local pulse, n = tr.pulse, tr.npulses
  if pulse == 1 then tr.pass = Q.cond(tr, t, st) end
  if not tr.pass then return nil end

  local mode = S.PMODES[st.pmode] or "WAIT"
  local fire
  if n <= 1 or pulse == 1 then fire = true
  elseif mode == "REPEAT" then fire = true
  elseif mode == "EDGE" then fire = (pulse == n)
  elseif mode == "SCATTER" then fire = math.random() < 0.5
  else fire = false end
  if not fire then return nil end

  local frac = (n > 1) and ((pulse - 1) / (n - 1)) or 0
  local ramp = (st.ramp or 0) / 100
  local vf = (ramp >= 0) and ((1 - ramp) + (ramp * frac)) or (1 + (ramp * frac))
  local decm = 2 ^ (((st.dec or 0) / 100) * 1.5)
  if mode == "SUSTAIN" and n > 1 then decm = decm * n end
  return {
    vel = ((st.vel or 100) / 100) * vf,
    pitch = (st.pitch or 0) + ((st.bend or 0) * frac),
    decm = decm,
    mix = (st.mix or 0) / 100,
    locks = st.locks,
    flam = (pulse == 1) and (st.flam or 0) or 0,
    nudge = (pulse == 1) and ((st.nudge or 0) / 100) or 0,
  }
end

-- --------------------------------------------------------------------- swing
--
-- A time warp over each pair of swing units: the first unit is stretched to
-- SWING% of the pair and the second squeezed into what is left, so every
-- pulse inside the pair moves in proportion rather than only the off-beat.

function Q.swing_delay(beat)
  local s = params:get("swing") / 100
  local u = S.SWING_UNIT[params:get("swing_grid")] or 0.25
  local p = beat % (2 * u)
  local w
  if p < u then w = p * (2 * s)
  else w = (2 * u * s) + ((p - u) * (2 - (2 * s))) end
  return w - p
end

-- ---------------------------------------------------------------------- run

local function fire(t, h)
  St.hit(t, h.vel, h.pitch, h.decm, h.mix, h.locks)
  if h.flam > 0 then
    clock.run(function()
      clock.sleep(h.flam / 1000)
      St.hit(t, h.vel * 0.6, h.pitch, h.decm, h.mix, h.locks)
    end)
  end
end

function Q.tick(t)
  local tr = St.tracks[t]
  local div = S.SPEED_BEATS[tr.speed] or 0.25
  Q.advance(tr)
  local pos = tr.pos
  local h = Q.hit_for(tr, t)

  -- the pulse being scheduled sits one division ahead, snapped to its grid
  local beat = (math.floor((clock.get_beats() / div) + 0.5) + 1) * div
  local wait = div + Q.swing_delay(beat)
  local bs = clock.get_beat_sec()

  local nudge = h and h.nudge or 0
  if nudge == 0 then
    clock.run(function()
      clock.sleep(wait * bs)
      tr.ph = pos
      if h then fire(t, h) end
      St.dirty = true
    end)
  else
    clock.run(function()
      clock.sleep(wait * bs)
      tr.ph = pos
      St.dirty = true
    end)
    clock.run(function()
      clock.sleep(math.max(wait + (nudge * div), 0) * bs)
      fire(t, h)
    end)
  end
end

local function loop(t)
  local tr = St.tracks[t]
  clock.sync(S.SPEED_BEATS[tr.speed] or 0.25)
  while St.playing do
    Q.tick(t)
    clock.sync(S.SPEED_BEATS[tr.speed] or 0.25)
  end
end

Q.ids = {}

function Q.reset()
  for _, tr in ipairs(St.tracks) do
    tr.pos, tr.pulse, tr.npulses, tr.loop = 0, 1, 1, 0
    tr.pass, tr.pre, tr.ph = false, false, 0
  end
  St.dirty = true
end

function Q.play()
  if St.playing then return end
  St.playing = true
  for t = 1, S.NTRACKS do
    Q.ids[t] = clock.run(loop, t)
  end
  St.dirty = true
end

-- STOP stops where it is; STOP again while stopped goes back to the top
function Q.stop()
  if not St.playing then
    Q.reset()
    return
  end
  St.playing = false
  for t = 1, S.NTRACKS do
    if Q.ids[t] then clock.cancel(Q.ids[t]) end
    Q.ids[t] = nil
  end
  St.dirty = true
end

function Q.toggle()
  if St.playing then Q.stop() else Q.play() end
end

return Q
