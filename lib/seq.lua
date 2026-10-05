-- drumdrum / seq
--
-- Eight independent sequencers, one clock coroutine each.
--
-- THE SEQUENCER RUNS ONE PULSE AHEAD OF WHAT YOU HEAR. Each coroutine wakes
-- on its own grid line, works out what happens on the NEXT pulse, and places
-- it on that pulse's line plus swing plus the step's nudge. That is what lets
-- a nudge go early as well as late. The playhead the grid draws is moved by
-- the placed event, so it lands when the sound does, not when the sequencer
-- thought about it. How the placing stays tight is under "run" below.
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
--
-- DIRECTION is the order the track walks its steps in:
--
--   FWD   1 to LENGTH, round again
--   BWD   LENGTH to 1
--   PEND  there and back, without playing either end twice
--   WALK  a drunk's walk: a step on, a step back, or stay put, wrapping
--   RND   any step, at random
--
-- One pass of the pattern (what A:B and 1ST count) is a lap for FWD and BWD,
-- there-and-back for PEND, and LENGTH steps for WALK and RND.
--
-- DILLA is the feel of a beat played in by hand on an MPC with the quantise
-- off, the J Dilla way. Not random shake: each voice has its own place
-- against the beat (S.DILLA). The kicks push a hair early, the claps and
-- snares lay back late, and every off-beat (the second of each pair of
-- pulses) is dragged part of the way to where a triplet would put it -- the
-- hats almost all the way, the kicks only a little -- so the groove sits
-- somewhere between straight and swung, and the voices rub against each
-- other instead of locking. On top, a slow wander (a random walk pulled back
-- towards the lean, so a track drifts early or late for a bar or two the way
-- a player does) and a touch of hit-to-hit jitter. All of it grows with the
-- amount: low is a gentle loosening, 100 % is properly drunk.

local S = include("drumdrum/lib/spec")

local Q = {}
local St

function Q.init(state) St = state end

local function transport_changed()
  if St.push_hiss then St.push_hiss() end
end

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
    -- not `x and (cmp) or true`: a false comparison would fall through to true
    if a and b then res = ((tr.loop % b) == (a - 1)) else res = true end
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

-- the next step for the track's direction
local function next_pos(tr)
  local len = tr.len
  local d = S.DIRS[tr.dir or 1] or "FWD"
  local pos = tr.pos
  if pos > len then pos = len end
  if d == "BWD" then
    if pos <= 1 then
      if tr.pos ~= 0 then tr.loop = tr.loop + 1 end
      return len
    end
    return pos - 1
  elseif d == "PEND" then
    if pos == 0 then tr.pdir = 1 return 1 end
    if len <= 1 then tr.loop = tr.loop + 1 return 1 end
    local n = pos + tr.pdir
    if n > len then tr.pdir = -1 n = len - 1 end
    if n < 1 then
      tr.pdir = 1
      n = 2
    end
    -- back at the start: a pass is there and back
    if n == 1 then tr.loop = tr.loop + 1 end
    return n
  elseif d == "WALK" or d == "RND" then
    local n
    if pos == 0 then n = (d == "RND") and math.random(len) or 1
    elseif d == "RND" then n = math.random(len)
    else
      local r = math.random()
      n = pos + ((r < 0.5) and 1 or ((r < 0.75) and -1 or 0))
      if n > len then n = 1 elseif n < 1 then n = len end
    end
    if pos ~= 0 then
      tr.count = tr.count + 1
      if tr.count >= len then
        tr.count = 0
        tr.loop = tr.loop + 1
      end
    end
    return n
  end
  if pos + 1 > len then
    if tr.pos ~= 0 then tr.loop = tr.loop + 1 end
    return 1
  end
  return pos + 1
end

function Q.advance(tr)
  if tr.pulse < tr.npulses then
    tr.pulse = tr.pulse + 1
    return
  end
  tr.pulse = 1
  tr.pos = next_pos(tr)
  local st = tr.steps[tr.pos]
  tr.npulses = (st and st.on) and (st.pulses or 1) or 1
end

-- this hit's DILLA, in pulses, for a pulse on line b of a grid of div
local function dilla(t, tr, b, div)
  local amt = (tr.dilla or 0) / 100
  if amt <= 0 then return 0 end
  local D = S.DILLA
  local off = (math.floor((b / div) + 1e-6) % 2) == 1
  tr.dw = util.clamp((tr.dw * 0.92) + ((math.random() - 0.5) * 0.5), -1, 1)
  local jit = (math.random() - 0.5) * 2
  local o = D.LEAN[t] + (D.WANDER * tr.dw) + (D.JITTER * jit)
  if off then o = o + (D.SWAY[t] * D.TRIP) end
  return o * amt
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
--
-- Everything is placed in BEATS on norns' own clock, never in seconds counted
-- from whenever the lua happened to run. Under MIDI or Link the beat is the
-- other machine's beat, so a pulse placed on a beat lands where the DAW put
-- its own, and a late coroutine does not drag the pattern late with it.
--
-- Each track coroutine wakes on its grid lines with clock.sync, which norns
-- counts from the coroutine's previous target rather than from "now": the
-- lines never drift and never get skipped, however late the lua gets to them.
-- Waking on line b, it prepares the pulse for the next line. A pulse with no
-- swing and no nudge is then a clock.sync straight onto its line; only the
-- part of a pulse that is genuinely off the grid (swing, nudge) is a sleep,
-- and that sleep is measured from the line, not from when it was planned.

local EPS = 1e-6

-- SYNC LEAD. Under Link or MIDI the beat is the other machine's, and it
-- plays its own audio so that it is HEARD on the beat. norns does not: a hit
-- fired on the beat comes out of the jack a few buffers later (the audio
-- interface, scsynth's block, the trip from lua to the engine). So under an
-- external clock every hit is placed this many milliseconds early. The
-- internal clock has nothing to line up with, and leads by nothing.
local INTERNAL, MIDI, LINK = 1, 2, 3

local function source()
  local ok, v = pcall(function() return params:get("clock_source") end)
  return ok and v or INTERNAL
end

-- the lead, in beats at the current tempo
function Q.lead()
  local src = source()
  if src ~= LINK and src ~= MIDI then return 0 end
  local ok, ms = pcall(function() return params:get("sync_lead") end)
  if not ok or not ms or ms <= 0 then return 0 end
  return (ms / 1000) / clock.get_beat_sec()
end

-- inside a clock coroutine: wait for the next line of n far enough off to
-- be early for, wake the lead before it, and return that line
function Q.wait_line(n)
  local lead = Q.lead()
  if lead <= 0 then
    clock.sync(n)
    return math.floor(clock.get_beats() + 0.5)
  end
  local now = clock.get_beats()
  local line = (math.floor(((now + lead) / n) + EPS) + 1) * n
  clock.sleep((line - lead - now) * clock.get_beat_sec())
  return line
end

Q.ids = {}
Q.gen = 0        -- bumped on every start and stop: anything already scheduled
                 -- from an older run sees a different number and drops out
Q.waiter = nil   -- a start that is waiting for its bar line

local function speed(tr) return S.SPEED_BEATS[tr.speed] or 0.25 end

-- the first line of a grid of div strictly after beat b
local function line_after(b, div)
  return (math.floor((b / div) + EPS) + 1) * div
end

-- run fn at beat `at`, as exactly as the clock allows
local function place(at, div, gen, fn)
  clock.run(function()
    -- ride the clock up to the last grid line at or before `at` ...
    local line = math.floor((at / div) + EPS) * div
    if line - clock.get_beats() > 0.001 then clock.sync(div) end
    -- ... and sleep only what is left over, measured from where we really are
    local rem = at - clock.get_beats()
    if rem > 0.0005 then clock.sleep(rem * clock.get_beat_sec()) end
    if gen == Q.gen then fn() end
  end)
end

local function fire(t, h, gen)
  St.hit(t, h.vel, h.pitch, h.decm, h.mix, h.locks)
  if h.rain and Q.on_rain and not St.tracks[t].mute then Q.on_rain(t) end
  if h.flam > 0 then
    clock.run(function()
      clock.sleep(h.flam / 1000)
      if gen == Q.gen then St.hit(t, h.vel * 0.6, h.pitch, h.decm, h.mix, h.locks) end
    end)
  end
end

-- advance track t one pulse and put that pulse on line b
function Q.tick(t, b, div, gen)
  local tr = St.tracks[t]
  -- a clip launch due on this line swaps the pattern in before it is read
  if Q.on_tick then Q.on_tick(t, b) end
  Q.advance(tr)
  local pos = tr.pos
  local h = Q.hit_for(tr, t)
  -- RAIN only falls where the track itself is silent (see lib/clips)
  if not h and Q.rain then h = Q.rain(t) end

  local at = b + Q.swing_delay(b) - Q.lead()
  local nudge = h and ((h.nudge + dilla(t, tr, b, div)) * div) or 0
  -- the playhead moves with the line, so it lands when the beat does
  place(at, div, gen, function()
    tr.ph = pos
    if h and nudge == 0 then fire(t, h, gen) end
    St.dirty = true
  end)
  if nudge ~= 0 then
    place(at + nudge, div, gen, function() fire(t, h, gen) end)
  end
end

-- one track, from line a. The pulse for a is due now (or, with a SYNC
-- LEAD, the lead before a: place() waits for it either way); after that the
-- coroutine stays one line ahead of what you hear, which is the room an
-- early nudge and the lead need.
local function loop(t, gen, a)
  local tr = St.tracks[t]
  Q.tick(t, a, speed(tr), gen)
  local b = a
  while gen == Q.gen do
    local div = speed(tr)
    -- started early (a Link start a moment before its beat 0, a join a
    -- lead before its bar): be on line b before preparing the one after
    if b - clock.get_beats() > 0.001 then clock.sync(div) end
    if gen ~= Q.gen then return end
    local nb = line_after(b, div)
    Q.tick(t, nb, div, gen)
    clock.sync(div)
    b = nb
  end
end

function Q.reset()
  for _, tr in ipairs(St.tracks) do
    tr.pos, tr.pulse, tr.npulses, tr.loop = 0, 1, 1, 0
    tr.pass, tr.pre, tr.ph = false, false, 0
    tr.pdir, tr.count, tr.dw = 1, 0, 0
  end
  St.dirty = true
end

-- everything stops and goes back to the top; nothing told to anyone else
function Q.halt()
  Q.gen = Q.gen + 1
  St.playing = false
  transport_changed()
  for t = 1, S.NTRACKS do
    if Q.ids[t] then clock.cancel(Q.ids[t]) end
    Q.ids[t] = nil
  end
  if Q.waiter then clock.cancel(Q.waiter) end
  Q.waiter = nil
  Q.reset()
end

-- all eight tracks from step 1 on line a together, the transport left as
-- it is. a is a whole beat, so it sits on every track's grid whatever its
-- speed. Anything the old run already placed on or after a drops out with
-- its generation, so a pulse a track prepared early is not heard twice.
local function from_top(a)
  Q.gen = Q.gen + 1
  local gen = Q.gen
  for t = 1, S.NTRACKS do
    if Q.ids[t] then clock.cancel(Q.ids[t]) end
    Q.ids[t] = nil
  end
  Q.reset()
  for t = 1, S.NTRACKS do
    Q.ids[t] = clock.run(loop, t, gen, a)
  end
  -- step 1 is now: a sample take armed for PLAY starts here
  if Q.on_begin then Q.on_begin(a) end
  St.dirty = true
end

function Q.start(a)
  Q.halt()
  St.playing = true
  transport_changed()
  from_top(a)
end

-- back to step 1 on line a without stopping (a snapshot landing): tracks
-- of different lengths and speeds line up again from there. Call it a
-- little before a, as Q.start is.
function Q.restart(a)
  if not St.playing or Q.waiter then return end
  from_top(a)
end

-- --------------------------------------------------------------- transport
--
-- Where START and STOP come from depends on SYSTEM > CLOCK > source:
--
--   internal  PLAY restarts norns' clock, so beat 0 is the moment you press
--             it. The clock answers with a transport start and that is what
--             actually starts the tracks.
--   midi      the DAW's START starts us on its first clock tick, which is
--             its beat 0, and its STOP stops us. PLAY here can not start the
--             DAW, so it joins on the next bar line of the DAW's count.
--   link      with "link start/stop sync" on, PLAY and STOP run the whole
--             Link session and we start with it on its beat 0. With it off
--             (or the session already running) PLAY joins on the next
--             quantum line.
--   crow      no transport at all: PLAY joins on the next bar.
--
-- An external clock is not evidence of an external transport -- a DAW that is
-- already rolling sent its START before we existed -- so PLAY and STOP here
-- always work, whatever the source.

local function link_sync()
  local ok, v = pcall(function() return params:get("link_start_stop_sync") end)
  return ok and v == 2
end

function Q.bar()
  if source() == LINK then
    local ok, v = pcall(function() return params:get("link_quantum") end)
    if ok and v and v > 0 then return v end
  end
  return 4
end

-- start on the next bar line of whatever clock is running, the SYNC LEAD
-- early so that the first hit is not late
function Q.join()
  Q.halt()
  St.playing = true   -- PLAY lights while it waits
  transport_changed()
  local gen = Q.gen
  local n = Q.bar()
  Q.waiter = clock.run(function()
    local line = Q.wait_line(n)
    if gen ~= Q.gen then return end
    Q.waiter = nil
    Q.start(line)
  end)
  St.dirty = true
end

-- ask the clock to start, and join on the bar if it never answers
local function ask(f)
  Q.halt()
  St.playing = true
  transport_changed()
  local gen = Q.gen
  if not pcall(f) then return Q.join() end
  Q.waiter = clock.run(function()
    clock.sleep(0.25)
    if gen ~= Q.gen then return end
    Q.waiter = nil
    Q.join()
  end)
  St.dirty = true
end

-- clock.transport.start: beat 0 is now (MIDI's first tick after START, the
-- Link session's start, an internal restart). Already running, this is the
-- other end going back to the top, and we go with it.
function Q.on_start()
  Q.start(math.max(math.floor(clock.get_beats() + 0.5), 0))
end

function Q.on_stop()
  if Q.on_halt then Q.on_halt() end
  Q.halt()
end

-- PLAY
function Q.play()
  if St.playing then return end
  local src = source()
  if src == INTERNAL then ask(function() clock.internal.start() end)
  elseif src == LINK and link_sync() then ask(function() clock.link.start() end)
  else Q.join() end
end

-- STOP: stops and goes back to the top
function Q.stop()
  if source() == LINK and link_sync() then pcall(function() clock.link.stop() end) end
  if Q.on_halt then Q.on_halt() end
  Q.halt()
end

function Q.toggle()
  if St.playing then Q.stop() else Q.play() end
end

return Q
