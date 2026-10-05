-- Smoke test for the lua side, run on a desktop with plain lua:
--
--   lua lib/tools/check-lua.lua
--
-- Stubs enough of norns to actually run the script: init, a few bars of
-- every sequencer, grid presses on all three faces, step holds with locks,
-- LFO patching, every overlay, every page redrawn. Parsing does not catch
-- nil fields and wrong call shapes; running does.

local ROOT = (arg[0]:match("(.*)/lib/tools/") or ".")

function include(path)
  return dofile(ROOT .. "/" .. path:gsub("^drumdrum/", "") .. ".lua")
end

local now = 0
util = {
  clamp = function(v, lo, hi) return math.min(math.max(v, lo), hi) end,
  round = function(v) return math.floor(v + 0.5) end,
  time = function() return now end,
  file_exists = function(p) return p:match("%.wav$") ~= nil end,
  scandir = function() return { "808-BD.wav", "808-CH.wav", "808-SD.wav", "readme.txt" } end,
}
_path = { audio = "/home/we/dust/audio/" }

local draws = 0
-- The screen stub measures text the way norns' 04B_03 font roughly does
-- (a touch wide, about 5 px a character at size 8) and remembers every
-- string's box for the frame. frame() then fails on any two that touch:
-- overlapping labels were only ever caught by squinting at the OLED.
local txt = { x = 0, y = 0, size = 8, boxes = {} }
local function txt_w(s) return #tostring(s) * 5 * (txt.size / 8) end
local function txt_box(s, x0)
  local w = txt_w(s)
  local h = math.floor(txt.size * 0.75 + 0.5)
  txt.boxes[#txt.boxes + 1] = { s = tostring(s), x0 = x0, x1 = x0 + w - 1,
    y0 = txt.y - h + 1, y1 = txt.y }
end
local SCREEN = {
  move = function(x, y) txt.x, txt.y = x, y end,
  font_size = function(n) txt.size = n end,
  text_extents = function(s) return txt_w(s), txt.size end,
  text = function(s) txt_box(s, txt.x) end,
  text_right = function(s) txt_box(s, txt.x - txt_w(s)) end,
  text_center = function(s) txt_box(s, txt.x - (txt_w(s) / 2)) end,
}
screen = setmetatable({}, { __index = function(_, k)
  local f = SCREEN[k]
  return function(...)
    draws = draws + 1
    if f then return f(...) end
  end
end })
local overlaps = {}
local function check_overlaps(where)
  local b = txt.boxes
  for i = 1, #b do
    for j = i + 1, #b do
      local p, q = b[i], b[j]
      if p.s ~= "" and q.s ~= "" and p.x0 <= q.x1 and q.x0 <= p.x1
        and p.y0 <= q.y1 and q.y0 <= p.y1 then
        local k = string.format("%s: '%s' x '%s'", where, p.s, q.s)
        if not overlaps[k] then
          overlaps[k] = true
          overlaps[#overlaps + 1] = k
        end
      end
    end
    if b[i].x0 < -1 or b[i].x1 > 128 then
      local k = string.format("%s: '%s' runs off screen", where, b[i].s)
      if not overlaps[k] then
        overlaps[k] = true
        overlaps[#overlaps + 1] = k
      end
    end
  end
  txt.boxes = {}
end

-- every engine.trig, with the beat it happened on
local trig_log = {}

local calls, last = {}, {}
engine = setmetatable({ name = "" }, { __index = function(_, k)
  return function(...)
    calls[k] = (calls[k] or 0) + 1
    last[k] = { ... }
    if k == "trig" and trig_log then
      trig_log[#trig_log + 1] = { t = select(1, ...) + 1, beat = clock.get_beats() }
    end
  end
end })

local leds = 0
local gobj = {
  led = function(_, x, y, l)
    assert(x >= 1 and x <= 16 and y >= 1 and y <= 8, "led out of range " .. x .. "," .. y)
    assert(l >= 0 and l <= 15 and l == math.floor(l), "bad led level " .. tostring(l))
    leds = leds + 1
  end,
  all = function() end,
  refresh = function() end,
}
grid = { connect = function() return gobj end }

-- A clock that behaves like matron's: time runs in 1 ms steps, clock.sync
-- lands on the next multiple of its quantum (counted from the coroutine's
-- previous target when it was syncing already), sleeps are in seconds, and a
-- transport start sets beat 0 and fires every pending sync at once.
local BS = 0.5          -- 120 bpm
local DT = 0.001
local beats = 0
local coros, wake, last_sync, nid = {}, {}, {}, 0
local restart = false
local EPSF = 1.1920929e-07

local function next_beat(base, q, off)
  off = off or 0
  local nb = math.ceil((base + EPSF) / q) * q + off
  while nb < base + EPSF do nb = nb + q end
  return math.max(nb, 0)
end

local function resume(id, ...)
  local co = coros[id]
  if not co then return end
  local ok, mode, a, b = coroutine.resume(co, ...)
  if not ok then error(mode) end
  if coroutine.status(co) == "dead" then
    coros[id], wake[id], last_sync[id] = nil, nil, nil
  elseif mode == "sync" then
    local base = last_sync[id] or beats
    local nb = next_beat(base, a, b)
    last_sync[id] = nb
    wake[id] = { sync = nb }
  else
    last_sync[id] = nil
    wake[id] = { time = now + a }
  end
end

clock = {
  run = function(f, ...)
    nid = nid + 1
    coros[nid] = coroutine.create(f)
    resume(nid, ...)
    return nid
  end,
  sleep = function(s) return coroutine.yield("sleep", s) end,
  sync = function(q, off) return coroutine.yield("sync", q, off) end,
  cancel = function(id) coros[id], wake[id], last_sync[id] = nil, nil, nil end,
  get_beat_sec = function() return BS end,
  get_beats = function() return beats end,
  get_tempo = function() return 60 / BS end,
  transport = {},
  internal = { start = function() restart = true end, stop = function() end },
}

local function step()
  now = now + DT
  beats = beats + (DT / BS)
  if restart then
    restart = false
    beats = 0
    for id, w in pairs(wake) do if w.sync then w.sync = 0 end last_sync[id] = 0 end
    if clock.transport.start then clock.transport.start() end
  end
  local due = {}
  for id, w in pairs(wake) do
    if (w.sync and beats > w.sync) or (w.time and now >= w.time) then due[#due + 1] = id end
  end
  table.sort(due)
  for _, id in ipairs(due) do
    if wake[id] then wake[id] = nil resume(id) end
  end
end

-- n sixteenths of a beat
local function pump(n)
  for _ = 1, math.floor((n * 0.25 * BS / DT) + 0.5) do step() end
end

metro = { init = function(f, t)
  return { start = function() end, stop = function() end, event = f, time = t }
end }
poll = { set = function() return nil end }
tab = { save = function() end, load = function() return nil end }
norns = { state = { data = "/tmp/" } }

-- controlspec + params, enough to be real about raw/mapped values
controlspec = { new = function(lo, hi, warp, step, def, unit, quantum)
  local c = { minval = lo, maxval = hi, warp = warp or "lin", step = step or 0,
              default = def or lo, units = unit, quantum = quantum or 0.01 }
  function c:map(r)
    r = math.min(math.max(r, 0), 1)
    local v
    if self.warp == "exp" then v = self.minval * ((self.maxval / self.minval) ^ r)
    else v = self.minval + ((self.maxval - self.minval) * r) end
    if self.step > 0 then v = math.floor((v / self.step) + 0.5) * self.step end
    return v
  end
  function c:unmap(v)
    if self.warp == "exp" then return math.log(v / self.minval) / math.log(self.maxval / self.minval) end
    return (v - self.minval) / (self.maxval - self.minval)
  end
  return c
end }

local P = {}   -- id -> { kind, cs, raw, val, opts, action, fmt }
local count = 0
params = {
  add_group = function() end,
  add_separator = function() end,
  add_control = function(_, id, name, cs, fmt)
    assert(not P[id], "duplicate param " .. id)
    count = count + 1
    P[id] = { kind = "control", cs = cs, raw = cs:unmap(cs.default), fmt = fmt }
  end,
  add_option = function(_, id, name, opts, def)
    count = count + 1
    P[id] = { kind = "option", opts = opts, val = def or 1 }
  end,
  add_file = function(_, id, name, path)
    count = count + 1
    P[id] = { kind = "file", val = path }
  end,
  add_number = function(_, id, name, lo, hi, def)
    P[id] = { kind = "number", val = def, lo = lo, hi = hi }
  end,
  set_action = function(_, id, f) P[id].action = f end,
  lookup_param = function(_, id)
    local p = assert(P[id], "no param " .. tostring(id))
    return { controlspec = p.cs, get = function() return params:get(id) end }
  end,
  get = function(_, id)
    local p = assert(P[id], "no param " .. tostring(id))
    if p.kind == "control" then return p.cs:map(p.raw) end
    return p.val
  end,
  get_raw = function(_, id)
    local p = assert(P[id], "no param " .. tostring(id))
    assert(p.kind == "control", "get_raw on " .. id)
    return p.raw
  end,
  set_raw = function(_, id, r)
    local p = P[id]
    p.raw = math.min(math.max(r, 0), 1)
    if p.action then p.action(params:get(id)) end
  end,
  set = function(_, id, v)
    local p = assert(P[id], "no param " .. tostring(id))
    if p.kind == "control" then p.raw = p.cs:unmap(v) else p.val = v end
    if p.action then p.action(params:get(id)) end
  end,
  delta = function(_, id, d)
    local p = assert(P[id], "no param " .. tostring(id))
    if p.kind == "control" then params:set_raw(id, p.raw + (d * p.cs.quantum))
    elseif p.kind == "option" then params:set(id, math.min(math.max(p.val + d, 1), #p.opts))
    else params:set(id, math.min(math.max(p.val + d, p.lo), p.hi)) end
  end,
  string = function(_, id)
    local p = P[id]
    if p.fmt then return p.fmt({ get = function() return params:get(id) end }) end
    return tostring(params:get(id))
  end,
  bang = function()
    for id, p in pairs(P) do if p.action then p.action(params:get(id)) end end
  end,
}
params:add_number("clock_tempo", "tempo", 1, 300, 120)
params:add_option("clock_source", "source", { "internal", "midi", "link", "crow" }, 1)

-- ----------------------------------------------------------------- run it

dofile(ROOT .. "/drumdrum.lua")
init()
pump(2)          -- the deferred params:bang
local dd = drumdrum
local St, G, S, L = dd.state, dd.grid, dd.spec, dd.lfo

-- every formatter on every param formats
for id, p in pairs(P) do
  if p.fmt then
    local s = p.fmt({ get = function() return params:get(id) end })
    assert(type(s) == "string", "formatter " .. id)
  end
end
print("params: " .. count)

-- the script starts with nothing on the sequencer; the timing tests below
-- need something to hear, so put the old demo beat in by hand
for t = 1, S.NTRACKS do
  assert(next(St.tracks[t].steps) == nil, "init should have an empty pattern")
end
local function put(t, steps, extra)
  for _, i in ipairs(steps) do
    local s = S.new_step()
    if extra then for k, v in pairs(extra) do s[k] = v end end
    St.tracks[t].steps[i] = s
  end
end
put(1, { 1, 7, 11 })
put(4, { 5, 13 })
put(7, { 3, 7, 11, 15 }, { vel = 70 })
put(7, { 1, 5, 9, 13 }, { vel = 45 })
put(3, { 13 }, { cond = 10 })

local function frame()
  screen_tick = screen_tick or 0
  txt.boxes = {}
  redraw()
  check_overlaps(St.page or "?")
  G.redraw()
end

local function press(x, y) G.key(x, y, 1) end
local function release(x, y) G.key(x, y, 0) end
local function tap(x, y) press(x, y) release(x, y) end

-- ------------------------------------------------------------- timing
--
-- 2 ms is two scheduler ticks of this fake clock; the real one polls every
-- 1 ms, so anything later than that is the sequencer's fault.
local TOL = 0.002 / BS

local function off_grid(b, g) return math.abs(b - (math.floor((b / g) + 0.5) * g)) end
local function first_trig(t)
  for _, e in ipairs(trig_log) do if e.t == t then return e.beat end end
end
local function all_on_grid(g)
  for _, e in ipairs(trig_log) do
    if off_grid(e.beat, g) > TOL then return false, e end
  end
  return true
end

-- internal clock: PLAY restarts it, step 1 is beat 0
beats = 13.37
trig_log = {}
tap(1, 8)
assert(St.playing, "PLAY did not start")
pump(64)
assert(math.abs(first_trig(1)) <= TOL, "internal: step 1 not on beat 0: " .. tostring(first_trig(1)))
local ok, e = all_on_grid(0.25)
assert(ok, e and ("internal: trig off the grid at beat " .. e.beat))

-- the HISS floor is only there while playing
assert(last.hiss and last.hiss[1] > 0, "no hiss while playing")
tap(2, 8)
assert(last.hiss[1] == 0, "hiss left on when stopped")
tap(1, 8)
assert(last.hiss[1] > 0, "hiss not back on PLAY")
pump(4)

-- MIDI clock, DAW already rolling: PLAY joins on the next bar line (with
-- no SYNC LEAD here; it has its own test below)
params:set("sync_lead", 0)
params:set("clock_source", 2)
tap(2, 8)
assert(not St.playing)
beats = 37.3
trig_log = {}
tap(1, 8)
assert(St.playing)
pump(16)
assert(math.abs(first_trig(1) - 40) <= TOL, "midi join: not on the bar: " .. tostring(first_trig(1)))
ok, e = all_on_grid(0.25)
assert(ok, e and ("midi join: off the grid at beat " .. e.beat))

-- the DAW goes back to the top while we play: we go with it
trig_log = {}
restart = true
pump(16)
assert(St.playing)
assert(math.abs(first_trig(1)) <= TOL, "midi restart: step 1 not on beat 0: " .. tostring(first_trig(1)))
ok, e = all_on_grid(0.25)
assert(ok, e and ("midi restart: off the grid at beat " .. e.beat))

-- the DAW stops: we stop and nothing already scheduled sounds afterwards
clock.transport.stop()
assert(not St.playing and St.tracks[1].pos == 0)
local n = #trig_log
pump(8)
assert(#trig_log == n, "a pulse sounded after STOP")

-- the DAW starts from stopped
restart = true
trig_log = {}
pump(64)
assert(St.playing and math.abs(first_trig(1)) <= TOL, "midi start: step 1 not on beat 0")

-- a nudged step lands exactly that far off its line, early or late
St.tracks[1].steps[7].nudge = -25
St.tracks[1].steps[11].nudge = 40
restart = true
trig_log = {}
pump(16)
local got = {}
for _, e in ipairs(trig_log) do if e.t == 1 then got[#got + 1] = e.beat end end
assert(math.abs(got[2] - (1.5 - 0.0625)) <= TOL, "early nudge: " .. tostring(got[2]))
assert(math.abs(got[3] - (2.5 + 0.1)) <= TOL, "late nudge: " .. tostring(got[3]))
St.tracks[1].steps[7].nudge = 0
St.tracks[1].steps[11].nudge = 0

-- SYNC LEAD under an external clock: every hit exactly that much early,
-- the joined bar's first hit included
params:set("sync_lead", 30)
tap(2, 8)
beats = 41.3
trig_log = {}
tap(1, 8)
pump(16)
local lead = 0.030 / BS
assert(math.abs(first_trig(1) - (44 - lead)) <= TOL, "lead join: " .. tostring(first_trig(1)))
for _, e in ipairs(trig_log) do
  assert(off_grid(e.beat + lead, 0.25) <= TOL, "lead: hit not a lead early at beat " .. e.beat)
end
-- the internal clock leads by nothing
params:set("clock_source", 1)
assert(dd.seq.lead() == 0, "internal clock should not lead")

params:set("clock_source", 1)
pump(64)
assert((calls.trig or 0) > 0, "no voices fired in four bars")
print("trigs in 4 bars: " .. calls.trig)
frame()

-- every track, every control screen, every page
for t = 1, 8 do
  tap(4 + t, 8)
  assert(St.sel == t)
  for id, b in pairs(S.BTN) do
    press(b.x, b.y)
    for n = 2, 3 do enc(n, 3) enc(n, -1) end
    key(2, 1) key(2, 0) key(3, 1) key(3, 0)
    frame()
    release(b.x, b.y)
  end
  St.audition(t)
end
-- K2/K3 on an open control: only LFO shapes respond, so transport is unchanged
assert(St.playing, "keys on an overlay changed transport")

-- a lock: hold a step, open TONE 1, turn
tap(5, 8)  -- track 1
press(3, 1)                 -- places step 3 on track 1
press(1, 6)                 -- T1
enc(2, 5)
release(1, 6)
release(3, 1)
local st = St.tracks[1].steps[3]
assert(st and st.locks and st.locks.T1a, "lock not written")
-- the lock stays open on the step with every finger off
assert(G.lock and G.lock.btn == "T1", "lock did not stay open")
local before = st.locks.T1a
enc(2, 3)
assert(st.locks.T1a > before, "lock not editable after letting go")
-- the next step press only closes it
tap(3, 1)
assert(G.lock == nil and St.tracks[1].steps[3], "closing the lock touched the step")
-- tapping the lock's own button closes it too
press(3, 1) press(2, 6) release(2, 6) release(3, 1)
assert(G.lock and G.lock.btn == "T2", "lock not opened on T2")
tap(2, 6)
assert(G.lock == nil, "lock button did not close it")
-- a quick tap on a placed step with no edit removes it
tap(3, 1)
assert(St.tracks[1].steps[3] == nil, "quick tap did not remove the step")

-- trig condition + pulses on a held step (from a fresh template: the
-- control sweep above edited the template, which is what it is for)
St.tracks[1].tpl = S.new_step()
press(2, 1)
press(9, 6) enc(2, 1) release(9, 6)       -- COND -> FILL
press(12, 6) enc(2, 3) enc(3, 1) release(12, 6)   -- 4 pulses, REPEAT
release(2, 1)
st = St.tracks[1].steps[2]
assert(st.cond == 2 and st.pulses == 4 and st.pmode == 2, "step props not edited")

-- shift + step sets length, shift + track previews, shift + control latches
local trigs0 = calls.trig or 0
key(2, 1) frame() tap(8, 2) tap(6, 8) tap(4, 6) key(2, 0)
assert(St.tracks[1].len == 24, "length not set")
assert(not St.tracks[2].mute and St.sel == 1, "shift + track should only preview")
assert((calls.trig or 0) > trigs0, "shift + track did not preview")
assert(G.latched == "S1", "latch not set")
frame()
key(2, 1) tap(4, 6) key(2, 0)
assert(G.latched == nil, "latch not cleared")

-- the clip launcher (the COLOUR page's grid), stopped: launches are immediate
tap(2, 8)
local C = dd.clips
local tr1 = St.tracks[1]
local before = tr1.steps
local function clips() tap(16, 8) end
clips()
assert(St.page == "colour", "COLOUR did not open the launcher")
frame() redraw()
tap(5, 3)                                   -- track 1, slot 3: empty
assert(tr1.clip == 3 and next(tr1.steps) == nil and tr1.len == 16, "empty slot not launched")
clips()
assert(St.page == "main", "COLOUR did not close")
tap(1, 1) tap(5, 1)                          -- write into clip 3
clips() tap(5, 1)                            -- back to slot 1
assert(tr1.clip == 1 and tr1.steps == before and tr1.len == 24, "slot 1 not restored")
assert(C.has(1, 3) and not C.has(1, 4), "slot contents wrong")
-- hold slot 3, tap track 2 slot 2: a copy, and no launch
press(5, 3) tap(6, 2) release(5, 3)
assert(tr1.clip == 1 and C.has(2, 2) and St.tracks[2].clip == 1, "copy went wrong")
St.tracks[2].clips[2].steps[1].vel = 5
assert(tr1.clips[3].steps[1].vel ~= 5, "copy shares tables")
-- CLEAR + slot empties it; STOP + slot is just a launch now
press(14, 8) tap(6, 2) release(14, 8)
assert(not C.has(2, 2) and not St.fill, "slot not emptied")
-- the pager and BYPASS on row 7 are not slots
local cs0 = St.col_sel
tap(1, 7) tap(2, 7)
assert(St.col_sel == dd.spec.BANK_CELLS[dd.spec.COLOUR[cs0].bank][1] and not C.hold, "pager")
-- rain: E1 while SWING is held, and SWING's screen shows it
press(3, 8) enc(1, 10) frame() redraw() release(3, 8)
assert(math.abs(params:get("rain") - 0.1) < 1e-6, "rain not turned")
params:set("rain", 0)
clips()
assert(St.page == "main")

-- playing, a launch waits for the bar and starts the clip from its top
tap(1, 8)
pump(6)
clips() tap(5, 3)
assert(tr1.clip == 1 and tr1.next_clip and tr1.next_clip.beat == 4, "launch not quantised to the bar")
pump(9)
assert(tr1.clip == 1, "launched before the bar")
trig_log = {}
pump(4)
assert(tr1.clip == 3 and tr1.next_clip == nil, "launch did not land")
local hit4 = false
for _, e in ipairs(trig_log) do
  if e.t == 1 and math.abs(e.beat - 4) <= TOL then hit4 = true end
end
assert(hit4, "the new clip's step 1 did not play on the bar")
-- a launch still waiting is dropped by STOP
tap(5, 1)
tap(2, 8)
assert(tr1.next_clip == nil and tr1.clip == 3, "stop kept a waiting launch")
tap(5, 1)
assert(tr1.clip == 1)
-- plain SWING on COLOUR is still the swing screen
press(3, 8) assert(G.overlay() == "swing") release(3, 8)

-- rain falls only between hits, on the grid, and only while it rains
params:set("rain", 1)
tap(1, 8)
trig_log = {}
pump(64)
local rained = #trig_log
ok, e = all_on_grid(0.25)
assert(ok, e and ("rain off the grid at beat " .. e.beat))
params:set("rain", 0)
assert(rained > 40, "a downpour produced only " .. rained .. " hits")
assert(#C.drops > 0, "rain drew nothing")
frame() clips()
assert(St.page == "main")

-- LFO patching: hold the LFO and a control, the first turn patches a side,
-- turning on is the depth
press(14, 6)
press(1, 6)
assert(L.st[1][1].target == nil, "pressing patched without a turn")
frame()
enc(2, 1)
assert(L.st[1][1].target and L.st[1][1].target.btn == "T1" and L.st[1][1].target.side == "a")
local dep0 = params:get("t1_l1_depth")
enc(2, 2)
assert(params:get("t1_l1_depth") > dep0, "turning on did not move the depth")
enc(3, 1)
assert(L.st[1][1].target.side == "b", "E3 did not move the patch to side b")
frame()
release(1, 6)
assert(G.patch == nil)
press(4, 6)                 -- S1: side a is the sample select, not modulatable
enc(2, 1)
assert(L.st[1][1].target.btn == "T1", "S1's sample select got patched")
enc(3, 1)
assert(L.st[1][1].target.btn == "S1" and L.st[1][1].target.side == "b")
release(4, 6)
release(14, 6)
-- the other way round: control first, then the LFO
press(1, 6) press(14, 7) enc(2, 1) release(14, 7) release(1, 6)
assert(L.st[1][2].target and L.st[1][2].target.btn == "T1", "control-then-LFO did not patch")
-- CLEAR + LFO unpatches it
press(14, 8) tap(14, 7) release(14, 8)
assert(L.st[1][2].target == nil, "CLEAR + LFO did not unpatch")
for _ = 1, 40 do L.step(1 / 30) St.push_modulated() end

-- swing
press(3, 8) enc(2, 8) enc(3, 1) frame() release(3, 8)
assert(params:get("swing") > 50)
pump(32)

-- mix page
tap(15, 8)
assert(St.page == "mix")
tap(6, 3)
-- track buttons mute here
tap(6, 8)
assert(St.tracks[2].mute, "mix: track button did not mute")
tap(6, 8)
assert(not St.tracks[2].mute, "mix: track button did not unmute")
-- pan: nudge left twice, centre, nudge track 8 right
tap(1, 1) tap(1, 1)
assert(math.abs(params:get("t1_pan") + 0.2) < 1e-6, "pan nudge: " .. params:get("t1_pan"))
tap(2, 1)
assert(params:get("t1_pan") == 0, "pan centre")
for _ = 1, 15 do tap(16, 4) end
assert(math.abs(params:get("t8_pan") - 1) < 1e-6, "pan clamps at hard right")
tap(16, 1)
assert(math.abs(params:get("t5_pan") - 0.1) < 1e-6, "pan right nudge")
enc(1, 1) enc(2, 3) enc(3, -2)
for i = 1, 8 do St.meter[i] = i / 10 end
frame()
tap(15, 8)

-- colour page: the screen is the master COLOUR, the grid the launcher
local SP = dd.spec
local function bank() return SP.COLOUR[St.col_sel].bank end
tap(16, 8)
assert(St.page == "colour")
for _ = 1, #SP.COLOUR do enc(1, 1) enc(2, 2) enc(3, 1) end
assert(St.col_sel == #SP.COLOUR)
frame()
-- row 7: column 2 forward a bank, column 1 back, round at the ends
St.col_sel = 1
tap(2, 7)
assert(bank() == 2 and St.col_sel == SP.BANK_CELLS[2][1], "pager forward")
tap(1, 7) tap(1, 7)
assert(bank() == #SP.COLOUR_BANKS, "pager back from BUSS goes round to SPACE")
tap(2, 7)
assert(bank() == 1, "pager forward from SPACE goes round to BUSS")
-- BYPASS on row 7 column 16
local byp = params:get("col_bypass")
tap(16, 7)
assert(params:get("col_bypass") ~= byp, "bypass")
tap(16, 7)
-- DUCK
tap(2, 7)
params:set("col_scsrc", 2)
assert(last.duck[1] == "scsrc" and last.duck[2] == 1, "duck source sent as track 1")
St.col_sel = SP.BANK_CELLS[2][2]
enc(2, 1)
assert(last.duck[1] == "screl")
St.hit(1, 1, 0, 1, 0)   -- the source's hit pulls the field down
frame()
params:set("col_scsrc", 1)
assert(last.duck[2] == 0, "duck off")
-- SPACE: its cells go to the fx, the last one is the returns
tap(2, 7) tap(2, 7)
assert(bank() == 4)
for _, i in ipairs(SP.BANK_CELLS[4]) do St.col_sel = i enc(2, 3) end
assert(calls.fx and calls.fx > 0)
assert(last.fx[1] == "dret", "SPACE's last cell is the returns")
-- TEXTURE goes to the colour stage
tap(1, 7)
local tex = SP.BANK_CELLS[3]
St.col_sel = tex[1] enc(2, 1)
assert(last.colour[1] == "loss")
frame()
-- the chorus: cells 4 and 5 of TEXTURE, and its twin lines on the field
St.col_sel = tex[4] enc(2, 100)
assert(last.colour[1] == "chorus" and last.colour[2] > 0.7, "chorus cell")
St.col_sel = tex[5] enc(2, 1)
assert(last.colour[1] == "chdepth")
for _ = 1, 10 do dd.ui.vis_update(1 / 30) frame() end
params:set("clock_tempo", 90)
St.follow_tempo()
St.col_sel = 1
St.outamp = 0.4
for _ = 1, 30 do
  dd.ui.vis_update(1 / 30)
  St.hit(1, 1, 0, 1, 0)
  frame()
end
tap(16, 8)

-- snapshots: SHIFT + PLAY opens the page
local N = dd.snap
key(2, 1) tap(1, 8) key(2, 0)
assert(St.page == "snap", "shift + play did not open SNAP")
assert(St.playing, "shift + play should not touch transport")
-- a short shift-hold saves nothing, a full one saves
key(2, 1) press(4, 1) pump(1) release(4, 1) key(2, 0)
assert(not N.has(4), "short hold saved")
key(2, 1) press(3, 1)
for _ = 1, 8 do pump(1) G.redraw() redraw() end
release(3, 1) key(2, 0)
assert(N.has(3), "hold did not save")
frame()
-- change things, then load while playing: lands on a beat
local saved_steps, saved_level = 0, params:get("t1_level")
for _ in pairs(St.tracks[1].steps) do saved_steps = saved_steps + 1 end
St.tracks[1].steps = {}
params:set("t1_level", 0.1)
St.tracks[4].speed = 6
local tapped_at = clock.get_beats()
tap(3, 1)
local p = N.pending
assert(p and p.beat == math.floor(p.beat) and p.beat > tapped_at, "load not aimed at a beat")
local applied_at, restarted
local orig_set = params.set
params.set = function(self, id, v)
  if id == "t1_level" and not applied_at then applied_at = clock.get_beats() end
  return orig_set(self, id, v)
end
local orig_restart = dd.seq.restart
dd.seq.restart = function(a)
  restarted = a
  orig_restart(a)
  -- every track back to the top, whatever its length and speed: its
  -- first pulse (step 1, on the beat) is already prepared
  for t = 1, S.NTRACKS do
    local tr = St.tracks[t]
    assert(tr.pos == 1 and tr.pulse == 1 and tr.loop == 0, "track " .. t .. " not back at the top")
  end
end
pump(16)
params.set = orig_set
dd.seq.restart = orig_restart
assert(restarted == p.beat, "the sequencer did not restart on the load's beat")
assert(N.pending == nil and N.last == 3, "load never landed")
assert(applied_at and math.abs(applied_at - (p.beat - 1 / 64)) < 0.01,
  "sound not loaded just before the beat: " .. tostring(applied_at) .. " vs " .. p.beat)
local n_steps = 0
for _ in pairs(St.tracks[1].steps) do n_steps = n_steps + 1 end
assert(n_steps == saved_steps and math.abs(params:get("t1_level") - saved_level) < 1e-6,
  "snapshot not restored")
assert(St.tracks[4].speed ~= 6, "track speed not restored")
-- the restored steps are a copy: editing them does not edit the snapshot
St.tracks[1].steps[60] = S.new_step()
assert(N.slots[3].tracks[1].steps[60] == nil, "snapshot shares tables with the live pattern")
-- stopped, a load is immediate
tap(2, 8)
St.tracks[1].steps = {}
tap(3, 1)
assert(next(St.tracks[1].steps) ~= nil and N.pending == nil, "stopped load not immediate")
frame()
-- every param a snapshot carries, ANALOG included
params:set("analog", 0.9)
tap(3, 1)
assert(math.abs(params:get("analog") - 0.5) < 1e-6, "snapshot does not carry analog")
-- a blank cell is the INIT patch: no steps, defaults back
St.select(5)
params:set("t1_level", 0.2)
assert(not N.has(9))
tap(9, 1)
for t = 1, S.NTRACKS do
  assert(next(St.tracks[t].steps) == nil, "init patch left steps on track " .. t)
end
assert(math.abs(params:get("t1_level") - 0.8) < 1e-6 and St.sel == 1, "init patch not default")
-- SHIFT alone flashes the last step on MAIN
key(2, 1) tap(1, 8) key(2, 0)
key(2, 1) frame() key(2, 0)
key(2, 1) tap(1, 8) key(2, 0)
-- CLEAR + hold deletes; a short hold does not, and neither touches FILL
local fill0 = St.fill
press(14, 8) press(3, 1) pump(1) release(3, 1) release(14, 8)
assert(N.has(3), "short delete hold deleted")
assert(St.fill == fill0, "delete chord toggled FILL")
press(14, 8) press(3, 1)
for _ = 1, 8 do pump(1) G.redraw() redraw() end
release(3, 1) release(14, 8)
assert(not N.has(3), "hold did not delete")
assert(St.page == "snap", "CLEAR used for a delete still reset something")
-- SHIFT + STOP alone on SNAP is still FILL while held
key(2, 1) press(2, 8)
assert(St.fill, "shift + stop on SNAP did not fill")
release(2, 8) key(2, 0)
assert(not St.fill, "fill outlived STOP")
frame()
-- KITS: tap one for every track; hold one and press tracks for only those
tap(2, 7)
for t = 1, S.NTRACKS do assert(S.kit_of(t) == 2, "kit tap missed track " .. t) end
assert(last.kit[1] == 7 and last.kit[2] == 1, "engine not told the kit")
press(3, 7) frame() tap(5, 8) tap(11, 8) release(3, 7)
assert(S.kit_of(1) == 3 and S.kit_of(7) == 3 and S.kit_of(2) == 2, "hold + track did not pick tracks")
-- each kit has its own T params, and a hit sends the playing kit's
assert(St.pid(1, "T2a") == "t1_k3_T2a" and St.pid(2, "T2a") == "t2_k2_T2a")
params:set("t1_k3_T1a", 80)
St.audition(1)
assert(last.set and calls.trig, "no hit")
assert(math.abs(params:get("t1_T1a") - S.VOICES[1].tone.T1.a.def) < 1e-6, "FM pitch moved WARM's")
-- a snapshot carries the kits; INIT puts every track back on WARM
key(2, 1) press(5, 1)
for _ = 1, 8 do pump(1) end
release(5, 1) key(2, 0)
tap(2, 7)
tap(5, 1)
assert(S.kit_of(1) == 3 and S.kit_of(2) == 2 and math.abs(params:get("t1_k3_T1a") - 80) < 1e-6,
  "snapshot did not restore kits")
tap(10, 1)
for t = 1, S.NTRACKS do assert(S.kit_of(t) == 1, "init left track " .. t .. " off WARM") end
press(1, 7) release(1, 7)
frame()
key(2, 1) tap(1, 8) key(2, 0)
assert(St.page == "main")
tap(1, 8)
pump(4)

-- FILL is momentary: on with SHIFT + STOP, off with STOP, whatever SHIFT does
assert(St.page == "main" and St.playing)
key(2, 1) press(2, 8)
assert(St.fill and St.playing, "shift + stop should fill, not stop")
key(2, 0)
assert(St.fill, "fill should last as long as STOP")
frame()
release(2, 8)
assert(not St.fill and St.playing, "fill not released with STOP")

-- SHIFT (K2) + K3 is play / stop, at once, and nothing else
key(2, 1) key(3, 1)
assert(not St.playing, "K2 + K3 did not stop")
key(3, 0) key(2, 0)
assert(St.page == "main", "K2 + K3 also turned the page")
key(2, 1) key(3, 1) key(3, 0) key(2, 0)
assert(St.playing, "K2 + K3 did not play")
-- K2 tapped alone goes home from any page, and is nothing on MAIN
tap(15, 8) key(2, 1) key(2, 0)
assert(St.page == "main", "K2 tap did not go back to MAIN")
key(2, 1) key(2, 0)
assert(St.page == "main" and St.playing, "K2 tap on MAIN did something")
tap(15, 8)
params:set("t1_pan", 0.6)
params:set("t1_tilt", -0.4)
St.select(1)
tap(14, 8)
assert(params:get("t1_pan") == 0 and params:get("t1_tilt") == 0, "CLEAR did not reset pan/tilt")
assert(St.playing and St.page == "mix", "CLEAR also did K2's or K3's job")
tap(15, 8)
-- on a control: the track's values, or the held steps' locks
params:set("t1_T2a", 3.5)
press(2, 6) tap(14, 8) release(2, 6)
assert(math.abs(params:get("t1_T2a") - S.VOICES[1].tone.T2.a.def) < 1e-6, "CLEAR did not reset T2")
press(5, 1) press(1, 6) enc(3, 4) release(1, 6)
assert(St.tracks[1].steps[5].locks.T1b, "lock for the reset test")
press(1, 6) tap(14, 8) release(1, 6) release(5, 1)
assert(St.tracks[1].steps[5] and not St.tracks[1].steps[5].locks, "CLEAR did not clear locks")
tap(5, 1)  -- close the lock left open on step 5
-- TC over the template
St.tracks[1].tpl.prob = 40
press(9, 6) tap(14, 8) release(9, 6)
assert(St.tracks[1].tpl.prob == 100, "CLEAR did not reset the template")
-- swing, an LFO, a COLOUR cell, the main page's speed
press(3, 8) enc(2, 5) tap(14, 8) release(3, 8)
assert(params:get("swing") == 50, "CLEAR did not reset swing")
press(14, 6) enc(2, 5) enc(3, 5) tap(14, 8) release(14, 6)
assert(math.abs(params:get("t1_l1_rate") - 0.5) < 1e-6 and math.abs(params:get("t1_l1_depth") - 0.4) < 1e-6,
  "CLEAR did not reset the LFO")
tap(16, 8)
St.col_sel = 1
enc(2, 20) enc(3, 1)
tap(14, 8)
assert(params:get("col_drive") == 0 and params:get("col_drivetype") == 1, "CLEAR did not reset the cell")
tap(16, 8)
St.tracks[1].speed = 6
tap(14, 8)
assert(St.tracks[1].speed == 3 and St.playing, "CLEAR on main")

-- PERFORM: SHIFT + MIX
local F = dd.perform
key(2, 1) tap(15, 8) key(2, 0)
assert(St.page == "perform", "shift + mix did not open PERFORM")
-- REPEAT: a pad punches, a second takes over, letting it go hands back
press(1, 1)
assert(last.punch[1] == 0 and last.punch[2] == "loop", "repeat did not punch")
local L1 = last.punch[4]
press(5, 1)
assert(last.punch[4] < L1, "second repeat pad did not take over")
release(5, 1)
assert(math.abs(last.punch[4] - L1) < 1e-9, "letting go did not hand back to the held pad")
frame()
release(1, 1)
assert(last.unpunch[1] == 0, "repeat not let go")
-- a filter is moved, not restarted, while held
local np = calls.punch
press(1, 2) press(6, 2)
assert(calls.punch == np + 1 and last.punchSet[1] == 5, "lowpass should glide, not re-punch")
release(6, 2) release(1, 2)
assert(last.unpunch[1] == 5)
-- GATE keeps its bar phase when its chop changes
press(9, 1)
local c0 = last.punch[5]
pump(3)
press(12, 1)
assert(last.punchSet[4] == c0, "gate lost its phase")
release(12, 1) release(9, 1)
-- every pad of every strip punches and lets go
for f = 1, #F.STRIPS do
  for i = 1, 8 do
    local x, y = F.pad_xy(f, i)
    press(x, y) frame() release(x, y)
    assert(F.active[f] == nil, "strip " .. f .. " pad " .. i .. " stuck")
  end
end
-- DROP latched with SHIFT, through a page change, cleared by CLEAR
key(2, 1) tap(9, 4) key(2, 0)
assert(St.pmute[1] and St.pmute[2] and not St.pmute[3], "DROP did not take the kicks out")
assert(last.strip[2] == "pmute", "DROP not sent")
key(2, 1) tap(16, 3) key(2, 0)   -- CRUSH latched too
press(13, 1)                              -- a held GATE
tap(15, 8) tap(15, 8)                     -- off to MIX and back to MAIN
assert(F.active[2] == nil, "a held pad outlived the page")
assert(F.active[8] and F.active[6], "latches did not survive the page")
key(2, 1) tap(15, 8) key(2, 0)
frame()
tap(14, 8)
assert(not St.pmute[1] and F.active[8] == nil and F.active[6] == nil, "CLEAR did not clear PERFORM")
key(2, 1) tap(15, 8) key(2, 0)
assert(St.page == "main")

-- the hidden TAPE: SHIFT + COLOUR, held
key(2, 1) press(16, 8)
assert(St.page == "main", "SHIFT + COLOUR should not change page")
assert(G.overlay() == "tape" and last.punch[1] == 2, "tape did not start")
key(2, 0)
enc(2, -3) enc(3, -1)
assert(params:get("tape_pitch") == -15 and params:get("tape_len") == 4, "tape encoders")
assert(last.punchSet[1] == 2 and math.abs(last.punchSet[5] - 2 ^ (-15 / 12)) < 1e-9, "tape pitch not sent")
key(2, 1) key(2, 0)
assert(St.playing, "K2 under the TAPE should be quiet")
frame()
tap(14, 8)
assert(params:get("tape_pitch") == -12 and params:get("tape_len") == 5, "CLEAR did not reset the tape")
release(16, 8)
assert(last.unpunch[1] == 2 and G.overlay() == nil and St.page == "main", "tape not let go")

-- A:B conditions fire on the A-th of every B passes, and only then
do
  local Qs = dd.seq
  local want = {
    ["1:2"] = { true, false, true, false }, ["2:2"] = { false, true, false, true },
    ["1:3"] = { true, false, false, true }, ["3:3"] = { false, false, true, false },
    ["2:4"] = { false, true, false, false }, ["4:4"] = { false, false, false, true },
  }
  for ci, name in ipairs(S.CONDS) do
    local w = want[name]
    if w then
      for loop = 0, 3 do
        local tr = { loop = loop, pre = false }
        local got = Qs.cond(tr, 1, { cond = ci, prob = 100 })
        assert(got == w[loop + 1], name .. " on pass " .. (loop + 1) .. " gave " .. tostring(got))
      end
    end
  end
end

-- directions, straight off the sequencer's advance
do
  local Q = dd.seq
  local function walk(dir, len, n)
    local tr = { pos = 0, pulse = 1, npulses = 1, loop = 0, len = len, dir = dir,
      steps = {}, pdir = 1, count = 0, dw = 0 }
    local out = {}
    for k = 1, n do Q.advance(tr) out[k] = tr.pos end
    return table.concat(out, ","), tr.loop
  end
  local o, l = walk(1, 4, 9)
  assert(o == "1,2,3,4,1,2,3,4,1" and l == 2, "FWD: " .. o .. " loop " .. l)
  o, l = walk(2, 4, 9)
  assert(o == "4,3,2,1,4,3,2,1,4" and l == 2, "BWD: " .. o .. " loop " .. l)
  o, l = walk(3, 4, 10)
  assert(o == "1,2,3,4,3,2,1,2,3,4" and l == 1, "PEND: " .. o .. " loop " .. l)
  o = walk(3, 1, 3)
  assert(o == "1,1,1", "PEND of one: " .. o)
  for _, d in ipairs({ 4, 5 }) do
    local seq, lp = walk(d, 8, 64)
    for v in seq:gmatch("%d+") do
      local x = tonumber(v)
      assert(x >= 1 and x <= 8, S.DIRS[d] .. " left the pattern: " .. x)
    end
    assert(lp == 7, S.DIRS[d] .. " counts passes wrong: " .. lp)
  end
end

-- MAIN: E1 picks the pair, E2/E3 turn it, CLEAR resets it; E1 leaves the track
tap(1, 8)
local sel0 = St.sel
enc(1, -5)
assert(St.main_pair == 1 and St.sel == sel0, "E1 on MAIN moved the track")
local trm = St.track()
enc(2, 3) assert(trm.len == 19, "E2 did not set length")
enc(3, 2) assert(trm.speed == 5, "E3 did not set timing")
tap(14, 8)
assert(trm.len == 16 and trm.speed == 3, "CLEAR did not reset length/timing")
enc(1, 1)
enc(2, 2) enc(3, 30) redraw()
assert(trm.dir == 3 and trm.dilla == 30, "pair 2 not turned")
-- DILLA moves hits off the grid, never further than S.DILLA_MAX of a pulse
params:set("swing", 50)
for i = 1, 16 do trm.steps[i] = S.new_step() end
trm.mute = false
if not St.playing then tap(1, 8) end
assert(St.playing)
local function dillaed()
  trig_log = {}
  pump(64)
  local off, worst, n = false, 0, 0
  for _, e in ipairs(trig_log) do
    if e.t == St.sel then
      n = n + 1
      local o = off_grid(e.beat, 0.25)
      if o > TOL then off = true end
      worst = math.max(worst, o)
    end
  end
  assert(n > 4, "the DILLA track hardly played")
  return off, worst
end
local d0 = trm.dilla
trm.dilla = 0
assert(not dillaed(), "hits off the grid with no DILLA")
trm.dilla = d0
local off, worst = dillaed()
assert(off, "DILLA did not move anything")
assert(worst <= (0.25 * S.DILLA_MAX * 0.3) + TOL, "DILLA went too far: " .. worst)
tap(14, 8)
assert(trm.dir == 1 and trm.dilla == 0, "CLEAR did not reset direction/DILLA")
-- the character, not just the size: at 100 % the hats' off-beats sit near
-- the triplet and the snare lays back behind the beat
do
  local hat, snr = St.tracks[7], St.tracks[4]
  local saved = { hat.steps, snr.steps, hat.mute, snr.mute, hat.speed, snr.speed, hat.len, snr.len }
  hat.steps, snr.steps = {}, {}
  for i = 1, 16 do hat.steps[i] = S.new_step() snr.steps[i] = S.new_step() end
  hat.mute, snr.mute, hat.speed, snr.speed, hat.len, snr.len = false, false, 3, 3, 16, 16
  hat.dilla, snr.dilla = 100, 100
  trig_log = {}
  pump(64)
  local function mean(t, odd)
    local sum, n = 0, 0
    for _, e in ipairs(trig_log) do
      if e.t == t then
        local line = math.floor((e.beat / 0.25) + 0.5)
        local o = (e.beat - (line * 0.25)) / 0.25
        -- an off-beat dragged late rounds onto its own line; keep it there
        if o < -0.5 then o = o + 1 line = line - 1 end
        if (line % 2 == 1) == odd then sum, n = sum + o, n + 1 end
      end
    end
    return (n > 0) and (sum / n) or 0
  end
  local h_off, h_on = mean(7, true), mean(7, false)
  assert(math.abs(h_off - (1 / 3)) < 0.08, "hat off-beats not near the triplet: " .. h_off)
  assert(math.abs(h_on) < 0.06, "hat on-beats strayed: " .. h_on)
  assert(mean(4, false) > 0.07, "snare not laid back: " .. mean(4, false))
  hat.dilla, snr.dilla = 0, 0
  hat.steps, snr.steps, hat.mute, snr.mute, hat.speed, snr.speed, hat.len, snr.len = table.unpack(saved)
end
enc(1, -1)

-- sample walk
press(4, 6) enc(2, 1) release(4, 6)
pump(4)

-- sampler: hold S1, tap a step to arm, the REC panel, a take landing
do
  local R = dd.sampler
  local t = St.sel
  local before = calls.sampListen or 0
  local had = St.tracks[t].steps[16]
  -- S1 + step on its own is a lock like any control, not a recording
  press(4, 6) tap(15, 4) release(4, 6)
  assert(not R.active(), "S1 + step armed without SHIFT")
  St.tracks[t].steps[63] = nil
  press(4, 6)
  key(2, 1)
  frame()                       -- the length picker
  tap(16, 1)
  key(2, 0)
  assert(R.t == t and R.steps == 16, "S1 + SHIFT + step did not arm")
  assert(St.tracks[t].steps[16] == had, "S1 + SHIFT + step touched the step")
  assert((calls.sampListen or 0) == before + 1, "THRESH did not listen")
  assert(math.abs(last.sampListen[1] - (16 * 0.25 * BS)) < 1e-6, "wrong take length")
  release(4, 6)
  assert(G.overlay() == "rec", "no REC panel")
  frame()
  -- PLAY while playing: on the next bar
  enc(1, 1)
  assert(R.MODES[params:get("rec_mode")] == "PLAY")
  assert(R.status() == "NEXT BAR", R.status())
  local starts = calls.sampStart or 0
  pump(20)
  assert((calls.sampStart or 0) == starts + 1, "PLAY never started the take")
  -- the engine's side, by hand
  R.on_done(0)
  R.on_state(3) R.prog = 0.5
  frame()
  R.on_state(4) frame()
  R.on_state(0)
  params:set(St.pid(t, "S1b"), 0)
  R.on_done(1)
  assert(R.take == nil, "take still pending")
  assert(params:get(St.pid(t, "file")):match("drumdrum/rec/.+%.wav$"), "take not loaded")
  assert(params:get(St.pid(t, "S1b")) == 1, "first take did not raise the level")
  assert(not R.active() and G.overlay() == nil)
  -- the same step twice disarms; CLEAR cancels; K3 starts now
  press(4, 6) key(2, 1) tap(3, 2) tap(3, 2) key(2, 0) release(4, 6)
  assert(not R.active(), "second tap did not disarm")
  press(4, 6) key(2, 1) tap(3, 2) key(2, 0) release(4, 6)
  tap(14, 8)
  assert(not R.active() and St.playing, "CLEAR should cancel, not stop")
  enc(1, -1)
  press(4, 6) key(2, 1) tap(3, 2) key(2, 0) release(4, 6)
  starts = calls.sampStart or 0
  key(3, 1) key(3, 0)
  assert((calls.sampStart or 0) == starts + 1 and St.page == "main", "K3 should start now")
  R.cancel()
  for _ = 1, 3 do enc(3, 1) frame() end
  params:set("rec_src", #R.SRCS) frame()
end

-- CLEAR + step: back to a plain hit, still there
do
  St.page = "main"
  G.release_all()
  local tr = St.track()
  local s9 = S.new_step()
  s9.prob, s9.cond, s9.locks = 30, 3, { T1a = 0.9 }
  tr.steps[9] = s9
  press(14, 8) tap(9, 1) release(14, 8)
  local st9 = tr.steps[9]
  assert(st9 and st9.on and st9.prob == 100 and st9.cond == 1 and not st9.locks,
    "CLEAR + step did not make a plain hit")
  -- CLEAR + empty step places nothing
  tr.steps[10] = nil
  press(14, 8) tap(10, 1) release(14, 8)
  assert(tr.steps[10] == nil, "CLEAR + empty step placed one")

  -- CLEAR + track: a short hold keeps the pattern, a long one clears it
  local t = St.sel
  press(14, 8) press(4 + t, 8) pump(1) G.redraw() release(4 + t, 8) release(14, 8)
  assert(next(tr.steps) ~= nil, "short CLEAR + track wiped")
  press(14, 8) press(4 + t, 8)
  for _ = 1, 8 do pump(1) G.redraw() end
  release(4 + t, 8) release(14, 8)
  assert(next(tr.steps) == nil, "CLEAR + track hold did not wipe")
  assert(St.page == "main" and St.sel == t, "the wipe did more than wipe")
  tr.steps[1] = S.new_step()

  -- SHIFT + E2 on a sound control: every track
  local before = {}
  for u = 1, S.NTRACKS do before[u] = params:get_raw(St.pid(u, "N1b")) end
  press(7, 6) key(2, 1) enc(3, 5) frame() key(2, 0) release(7, 6)
  for u = 1, S.NTRACKS do
    assert(params:get_raw(St.pid(u, "N1b")) > before[u], "SHIFT + E3 missed track " .. u)
  end
  -- CLEAR + control resets it
  press(14, 8) tap(7, 6) release(14, 8)
  assert(params:get(St.pid(t, "N1b")) == St.DEFAULTS[St.pid(t, "N1b")], "CLEAR + control did not reset")

  -- the template lights TC brighter (drawn, not asserted on an LED)
  tr.tpl.prob = 50 frame() tr.tpl.prob = 100

  -- MIX: SHIFT + E2 pans every track; CLEAR + a pan button centres
  tap(15, 8)
  key(2, 1) enc(2, 3) frame() key(2, 0)
  for u = 1, S.NTRACKS do
    assert(params:get(St.pid(u, "pan")) > 0, "SHIFT + E2 on MIX missed track " .. u)
  end
  press(14, 8) tap(2, 1) release(14, 8)
  assert(params:get("t1_pan") == 0, "CLEAR + pan did not centre")
  tap(14, 8)
  assert(params:get("t1_pan") == 0, "CLEAR on MIX did not reset")
  for u = 1, S.NTRACKS do params:set(St.pid(u, "pan"), 0) end
  tap(15, 8)

  -- PERFORM: track buttons mute; CLEAR + pad drops that strip's latch
  key(2, 1) tap(15, 8) key(2, 0)
  assert(St.page == "perform")
  tap(7, 8)
  assert(St.tracks[3].mute, "PERFORM track button did not mute")
  tap(7, 8)
  key(2, 1) tap(16, 3) key(2, 0)
  assert(dd.perform.active[6], "latch for the CLEAR test")
  press(14, 8) tap(15, 3) release(14, 8)
  assert(dd.perform.active[6] == nil and St.page == "perform", "CLEAR + pad did not unlatch")
  key(2, 1) key(2, 0)
  assert(St.page == "main")
end

-- stop resets
assert(St.playing)
tap(2, 8)
assert(not St.playing and St.tracks[1].pos == 0)

-- persistence round trip
local d = St.serialize()
St.deserialize(d)

-- every kit's voice names and descriptions, every pair, every colour cell
-- and every control overlay, so the overlap check sees all the strings
local page0, sel0, pair0, col0 = St.page, St.sel, St.main_pair, St.col_sel
for kit = 1, #S.KITS do
  for t = 1, 8 do params:set("t" .. t .. "_kit", kit) end
  for t = 1, 8 do
    St.sel = t
    for _, pg in ipairs({ "main", "mix" }) do
      St.page = pg
      for mp = 1, #S.MAIN_PAIRS do St.main_pair = mp frame() end
    end
    St.page = "main"
    for _, b in pairs(S.BTN) do press(b.x, b.y) frame() release(b.x, b.y) end
  end
end
for t = 1, 8 do params:set("t" .. t .. "_kit", 1) end
St.page = "colour"
for i = 1, #S.COLOUR do St.col_sel = i frame() end
St.page, St.sel, St.main_pair, St.col_sel = page0, sel0, pair0, col0

for _, k in ipairs(overlaps) do print("OVERLAP " .. k) end
assert(#overlaps == 0, #overlaps .. " overlapping strings on screen")

cleanup()
print(string.format("ok  draws=%d leds=%d set=%d trig=%d strip=%d",
  draws, leds, calls.set or 0, calls.trig or 0, calls.strip or 0))
