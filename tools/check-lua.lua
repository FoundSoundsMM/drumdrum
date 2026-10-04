-- Smoke test for the lua side, run on a desktop with plain lua:
--
--   lua tools/check-lua.lua
--
-- Stubs enough of norns to actually run the script: init, a few bars of
-- every sequencer, grid presses on all three faces, step holds with locks,
-- LFO patching, every overlay, every page redrawn. Parsing does not catch
-- nil fields and wrong call shapes; running does.

local ROOT = (arg[0]:match("(.*)/tools/") or ".")

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
screen = setmetatable({}, { __index = function()
  return function() draws = draws + 1 end
end })

local calls, last = {}, {}
engine = setmetatable({ name = "" }, { __index = function(_, k)
  return function(...)
    calls[k] = (calls[k] or 0) + 1
    last[k] = { ... }
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

-- a clock that runs coroutines when told to
local coros = {}
local beats = 0
clock = {
  run = function(f, ...)
    local co = coroutine.create(f)
    coros[#coros + 1] = co
    local ok, err = coroutine.resume(co, ...)
    if not ok then error(err) end
    return #coros
  end,
  sleep = function() coroutine.yield() end,
  sync = function() coroutine.yield() end,
  cancel = function(id) coros[id] = false end,
  get_beat_sec = function() return 0.5 end,
  get_beats = function() return beats end,
  get_tempo = function() return 120 end,
  transport = {},
}
local function pump(n)
  for _ = 1, n do
    beats = beats + 0.25
    now = now + 0.125
    for i = 1, #coros do
      local co = coros[i]
      if co and coroutine.status(co) == "suspended" then
        local ok, err = coroutine.resume(co)
        if not ok then error(err) end
      end
    end
  end
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

local function frame()
  screen_tick = screen_tick or 0
  redraw()
  G.redraw()
end

local function press(x, y) G.key(x, y, 1) end
local function release(x, y) G.key(x, y, 0) end
local function tap(x, y) press(x, y) release(x, y) end

-- play a few bars
tap(1, 8)
assert(St.playing, "PLAY did not start")
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

-- shift + step sets length, shift + track mutes, shift + control latches
press(14, 8) tap(8, 2) tap(6, 8) tap(4, 6) release(14, 8)
assert(St.tracks[1].len == 24, "length not set")
assert(St.tracks[2].mute, "mute not toggled")
assert(G.latched == "S1", "latch not set")
frame()
press(14, 8) tap(4, 6) release(14, 8)
assert(G.latched == nil, "latch not cleared")

-- LFO patching
press(14, 6)
tap(1, 6)
assert(L.st[1][1].target and L.st[1][1].target.btn == "T1" and L.st[1][1].target.side == "a")
tap(1, 6)
assert(L.st[1][1].target.side == "b")
tap(4, 6)                   -- S1: side a is the sample select, not modulatable
assert(L.st[1][1].target.btn == "S1" and L.st[1][1].target.side == "b")
frame()
release(14, 6)
for _ = 1, 40 do L.step(1 / 30) St.push_modulated() end

-- swing
press(3, 8) enc(2, 8) enc(3, 1) frame() release(3, 8)
assert(params:get("swing") > 50)
pump(32)

-- mix page
tap(15, 8)
assert(St.page == "mix")
tap(6, 3) tap(2, 1) tap(15, 4)
enc(1, 1) enc(2, 3) enc(3, -2)
for i = 1, 8 do St.meter[i] = i / 10 end
frame()
tap(15, 8)

-- colour page
tap(16, 8)
assert(St.page == "colour")
for i = 1, 6 do tap(8, i) end
tap(16, 7)
for _ = 1, 6 do enc(1, 1) enc(2, 2) enc(3, 1) end
St.outamp = 0.4
for _ = 1, 30 do
  dd.ui.vis_update(1 / 30)
  St.hit(1, 1, 0, 1, 0)
  frame()
end
tap(16, 8)

-- sample walk
press(4, 6) enc(2, 1) release(4, 6)
pump(4)

-- stop, stop again resets
tap(2, 8) tap(2, 8)
assert(not St.playing and St.tracks[1].pos == 0)

-- persistence round trip
local d = St.serialize()
St.deserialize(d)

cleanup()
print(string.format("ok  draws=%d leds=%d set=%d trig=%d strip=%d",
  draws, leds, calls.set or 0, calls.trig or 0, calls.strip or 0))
