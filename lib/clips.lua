-- drumdrum / clips
--
-- Each track has seven sequence slots, launched like Ableton's clips. They
-- live on the COLOUR page's grid (the screen there is the master COLOUR):
-- the column above each track's button holds that track's seven slots, row
-- 1 at the top. Tap a slot and the track moves to it.
--
-- A CLIP is a track's sequence: its steps (locks and all), its LENGTH,
-- TIMING (speed), DIRECTION and DILLA. The sound, the template, the LFOs and
-- the mute stay with the track. The clip that is playing lives in the
-- track's own fields (tr.steps, tr.len, tr.speed, tr.dir, tr.dilla), so the
-- step editor, the sequencer and the saves never need to know clips exist; its slot is only written back when the track
-- leaves it (stash) or something wants to read every slot (sync).
--
-- An empty slot is an empty sixteen-step pattern, forwards, at the speed
-- and DILLA the track was running, so launching one is how you start a new
-- sequence.
--
-- While the transport runs a launch waits for the next bar line, and the
-- track starts its new clip from the top on that bar, as Ableton does with
-- its default 1 BAR quantisation. Like a snapshot, the swap happens as the
-- track prepares the first pulse at or after the bar (a pulse ahead of what
-- you hear, see lib/seq), so the bar itself already plays the new clip.
-- Stopped, a launch is immediate.
--
-- SHIFT + hold a slot + tap another copies the first into the second (any
-- track to any track). SHIFT + STOP + slot empties it.
--
-- RAIN, E1 while SWING is held: random hits scattered across the voices like
-- rain on a roof. Each track's sequencer may drop one into any of its own
-- pulses that would otherwise be silent, so the drops sit on the grid and
-- swing with it. The chance and the loudness both grow with the square of
-- the amount, so a little rain is a stray ghost note every few bars and a
-- lot is a downpour.

local S = include("drumdrum/lib/spec")

local C = {}
local St, Q

C.COUNT = 7

C.hold = nil       -- a slot held on the launcher, { t, c, used }
C.drops = {}       -- rain the grid is showing: { x, t0 }

function C.init(state, seq)
  St, Q = state, seq
  for _, tr in ipairs(St.tracks) do C.reset_track(tr) end
end

local function copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, e in pairs(v) do out[k] = copy(e) end
  return out
end
C.copy = copy

function C.reset_track(tr)
  tr.clips = {}
  tr.clip = 1
  tr.next_clip = nil   -- a launch waiting for its bar: { c, beat }
end

-- the playing clip back into its slot (the steps by reference: they are the
-- same table the step editor is writing into)
function C.stash(tr)
  tr.clips[tr.clip] = { steps = tr.steps, len = tr.len, speed = tr.speed,
    dir = tr.dir, dilla = tr.dilla }
end

local function has_steps(steps)
  for _, st in pairs(steps or {}) do
    if st.on then return true end
  end
  return false
end

function C.has(t, c)
  local tr = St.tracks[t]
  if c == tr.clip then return has_steps(tr.steps) end
  local e = tr.clips[c]
  return e ~= nil and has_steps(e.steps)
end

-- every slot as data, for a snapshot or the data file
function C.save(t)
  local tr = St.tracks[t]
  C.stash(tr)
  return { clip = tr.clip, clips = copy(tr.clips) }
end

-- the counterpart. The playing clip's own fields arrive with the rest of
-- the track (steps, len, speed, dir, dilla), so only the other slots are
-- taken here.
function C.load(t, d)
  local tr = St.tracks[t]
  tr.next_clip = nil
  tr.clips = copy((d and d.clips) or {})
  tr.clip = util.clamp((d and d.clip) or 1, 1, C.COUNT)
  C.stash(tr)
end

-- ------------------------------------------------------------------ switch

local function switch(tr, c)
  C.stash(tr)
  local e = tr.clips[c]
  if not e then
    e = { steps = {}, len = 16, speed = tr.speed, dir = 1, dilla = tr.dilla }
    tr.clips[c] = e
  end
  tr.clip = c
  tr.steps = e.steps
  tr.len = e.len or 16
  tr.speed = e.speed or 3
  tr.dir = e.dir or 1
  tr.dilla = e.dilla or 0
  -- from the top: the advance that follows lands on step 1, and A:B and
  -- 1ST count from this clip's first pass
  tr.pos, tr.pulse, tr.npulses, tr.loop = 0, 1, 1, 0
  tr.pdir, tr.count = 1, 0
  St.dirty = true
end

-- the next bar line this track can still be ready for: it has to prepare
-- the pulse on it one of its own pulses early
local function next_bar(tr)
  local bar = Q.bar and Q.bar() or 4
  local lead = S.SPEED_BEATS[tr.speed] or 0.25
  return (math.floor(((clock.get_beats() + lead) / bar) + 1e-6) + 1) * bar
end

function C.launch(t, c)
  local tr = St.tracks[t]
  if not St.playing then
    tr.next_clip = nil
    switch(tr, c)
    return
  end
  tr.next_clip = { c = c, beat = next_bar(tr) }
  St.dirty = true
end

-- from Q.tick, as track t prepares the pulse on line b
function C.on_tick(t, b)
  local tr = St.tracks[t]
  local n = tr.next_clip
  if n and b >= n.beat - 1e-6 then
    tr.next_clip = nil
    switch(tr, n.c)
  end
end

-- a stop drops every launch still waiting
function C.on_stop()
  for _, tr in ipairs(St.tracks) do tr.next_clip = nil end
end

function C.copy_slot(t1, c1, t2, c2)
  local src = St.tracks[t1]
  C.stash(src)
  local e = copy(src.clips[c1] or { steps = {}, len = 16, speed = src.speed, dir = 1, dilla = src.dilla })
  local dst = St.tracks[t2]
  if c2 == dst.clip then
    -- into the clip that is playing: it changes under the playhead
    dst.steps, dst.len, dst.speed = e.steps, e.len or 16, e.speed or 3
    dst.dir, dst.dilla = e.dir or 1, e.dilla or 0
    C.stash(dst)
  else
    dst.clips[c2] = e
  end
  St.dirty = true
end

function C.clear_slot(t, c)
  local tr = St.tracks[t]
  if c == tr.clip then
    tr.steps = {}
    C.stash(tr)
  else
    tr.clips[c] = nil
  end
  St.dirty = true
end

-- ------------------------------------------------------------------- grid

-- launcher cell (x, y) -> track, slot
function C.at(x, y)
  local t = x - S.ROW8.track0
  if t >= 1 and t <= S.NTRACKS and y >= 1 and y <= C.COUNT then return t, y end
  return nil
end

function C.press(t, c, clear)
  if clear then
    C.clear_slot(t, c)
    return
  end
  if C.hold and C.hold.t ~= nil then
    C.copy_slot(C.hold.t, C.hold.c, t, c)
    C.hold.used = true
    return
  end
  C.hold = { t = t, c = c, used = false }
end

-- a slot comes up: a press that copied nothing was a launch
function C.release(t, c)
  local h = C.hold
  if not (h and h.t == t and h.c == c) then return end
  C.hold = nil
  if not h.used then C.launch(t, c) end
end

-- ------------------------------------------------------------------- rain

-- from Q.tick, for a pulse of track t that plays nothing: a drop, or nil
function C.rain(t)
  local r = params:get("rain")
  if r <= 0 then return nil end
  if math.random() >= (r * r * 0.3) then return nil end
  local vel = (0.12 + (0.5 * r * r)) * (0.5 + (math.random() * 0.5))
  return { vel = vel, pitch = 0, decm = 0.8, mix = 0, locks = nil, flam = 0, nudge = 0, rain = true }
end

-- a drop has just been heard: give the launcher's side columns one to show
function C.splash()
  local x = math.random(8)
  if x > 4 then x = x + 8 end
  C.drops[#C.drops + 1] = { x = x, t0 = util.time() }
  if #C.drops > 24 then table.remove(C.drops, 1) end
end

return C
