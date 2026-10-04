-- drumdrum
--
-- warm, dusty drum machine
-- for norns + grid 128
--
-- 8 voices, synth + sample each
-- BD1 BD2 CLP SNR PRC1 PRC2 HAT CYM
--
-- E1 track (COLOUR: cell, through
--    BUSS DUCK TEXTURE SPACE;
--    MAIN: the pair below)
-- E2 / E3 the open screen's pair
-- main: LENGTH / TIMING,
--    DIRECTION / DILLA
-- grid track buttons: track
-- mix:  E2 pan    E3 tilt
-- swing (hold grid SWING):
--    E1 rain  E2 amount  E3 grid
-- colour: the grid is the clip
--    launcher
-- K2 play/stop  K3 next page
-- K2+K3 reset what E2/E3 turn
-- K1 held: fine adjust
--
-- sampler: hold S1 + tap a step
--    to record that many steps;
--    E1 start E2 level E3 source
--    K2 cancel K3 now / stop
--
-- grid: see README

engine.name = "DrumDrum"

local S  = include("drumdrum/lib/spec")
local St = include("drumdrum/lib/state")
local Q  = include("drumdrum/lib/seq")
local L  = include("drumdrum/lib/lfo")
local G  = include("drumdrum/lib/gridui")
local N  = include("drumdrum/lib/snap")
local F  = include("drumdrum/lib/perform")
local C  = include("drumdrum/lib/clips")
local R  = include("drumdrum/lib/sampler")
local U  = include("drumdrum/lib/ui")

local k1 = false
local keys = {}         -- K2, K3 down
local chord = false     -- K2 and K3 went down together: neither does its own job
local screen_metro, grid_metro, lfo_metro
local FPS = 30
local polls = {}

-- the live modules, for the maiden repl
drumdrum = { state = St, seq = Q, lfo = L, grid = G, ui = U, spec = S, snap = N, perform = F, clips = C, sampler = R }

-- -------------------------------------------------------------------- edits

-- one encoder turn on an open control
local function ctrl_enc(btn, side, d)
  local t = St.sel
  local tr = St.track()
  local b = S.BTN[btn]
  local p = S.pair(t, btn)[side]
  local held = G.held_steps()

  if S.STEP_KIND[b.kind] then
    local targets = {}
    if #held > 0 then
      for _, i in ipairs(held) do
        if tr.steps[i] then targets[#targets + 1] = tr.steps[i] end
      end
      G.mark_edited()
    else
      targets[1] = tr.tpl
    end
    for _, st in ipairs(targets) do
      local v = (st[p.key] or p.def) + d
      st[p.key] = util.clamp(math.floor(v + 0.5), p.lo, p.hi)
    end
    return
  end

  if p.special == "sample" then
    St.sample_delta(t, d)
    return
  end

  local key = btn .. side
  local id = St.pid(t, key)
  if #held > 0 then
    local q = St.raw_step(id, k1)
    for _, i in ipairs(held) do
      local st = tr.steps[i]
      if st then
        st.locks = st.locks or {}
        local base = st.locks[key] or params:get_raw(id)
        st.locks[key] = util.clamp(base + (d * q), 0, 1)
      end
    end
    G.mark_edited()
  else
    St.delta(id, d, k1)
  end
end

-- K2 on a control with steps held: drop that button's locks from them
local function clear_locks(btn)
  local tr = St.track()
  for _, i in ipairs(G.held_steps()) do
    local st = tr.steps[i]
    if st and st.locks then
      st.locks[btn .. "a"] = nil
      st.locks[btn .. "b"] = nil
      if next(st.locks) == nil then st.locks = nil end
    end
  end
  G.mark_edited()
end

-- -------------------------------------------------------------------- reset
--
-- K2+K3: whatever the open screen's E2 and E3 turn goes back to where the
-- script starts it. Over held steps that means the steps: a sound control
-- loses its locks (back to the track's value), TC and P go back to a plain
-- step. With none held, TC and P reset the template.

local function reset_ctrl(btn)
  local t = St.sel
  local b = S.BTN[btn]
  if b.kind == "lfo" then
    local pre = St.pid(t, "l" .. b.lfo .. "_")
    for _, k in ipairs({ "rate", "depth", "shape" }) do St.reset(pre .. k) end
    return
  end
  local pair = S.pair(t, btn)
  local held = G.held_steps()
  local tr = St.track()
  if S.STEP_KIND[b.kind] then
    local targets = {}
    if #held > 0 then
      for _, i in ipairs(held) do targets[#targets + 1] = tr.steps[i] end
      G.mark_edited()
    else
      targets[1] = tr.tpl
    end
    for _, st in ipairs(targets) do
      st[pair.a.key] = pair.a.def
      st[pair.b.key] = pair.b.def
    end
  elseif #held > 0 then
    clear_locks(btn)
  else
    for _, side in ipairs({ "a", "b" }) do
      if not pair[side].special then St.reset(St.pid(t, btn .. side)) end
    end
  end
end

local function reset()
  local kind, btn = G.overlay()
  if kind == "tape" then
    St.reset("tape_pitch")
    St.reset("tape_len")
  elseif kind == "ctrl" then
    reset_ctrl(btn)
  elseif kind == "rec" then
    St.reset("rec_thresh")
  elseif kind == "swing" then
    St.reset("swing")
    St.reset("swing_grid")
  elseif St.page == "mix" then
    St.reset(St.pid(St.sel, "pan"))
    St.reset(St.pid(St.sel, "tilt"))
  elseif St.page == "colour" then
    local cell = S.COLOUR[St.col_sel]
    St.reset("col_" .. cell.a.arg)
    St.reset("col_" .. cell.b.arg)
  elseif St.page == "perform" then
    F.clear()
  elseif St.page == "main" then
    local tr = St.track()
    if St.main_pair == 1 then
      tr.len, tr.speed = 16, 3
    else
      tr.dir, tr.dilla = 1, 0
    end
  end
end

-- ---------------------------------------------------------------------- init

local function start_polls()
  for i = 1, S.NTRACKS do
    local p = poll.set("meter" .. i, function(v) St.meter[i] = v or 0 end)
    if p then
      p.time = 1 / 20
      p:start()
      polls[#polls + 1] = p
    end
  end
  local po = poll.set("outamp", function(v) St.outamp = v or 0 end)
  if po then
    po.time = 1 / 30
    po:start()
    polls[#polls + 1] = po
  end
  for name, f in pairs(R.POLLS) do
    local ps = poll.set(name, f)
    if ps then
      ps.time = 1 / 30
      ps:start()
      polls[#polls + 1] = ps
    end
  end
end

function init()
  St.init()
  -- the engine class only compiles when norns starts: an engine from before
  -- the kits has no kit command, and every track would stay on WARM
  St.old_engine = type(engine.commands) == "table" and engine.commands.kit == nil
  if St.old_engine then print("drumdrum: the engine is out of date -- SYSTEM > RESTART") end
  L.init()
  St.lfo = L
  Q.init(St)
  C.init(St, Q)
  St.clips = C
  N.init(St, Q, L, C)
  F.init(St)
  -- a snapshot first: one landing on this line replaces the clips as well
  Q.on_tick = function(t, b)
    N.on_tick(t, b)
    C.on_tick(t, b)
  end
  Q.on_halt = C.on_stop
  R.init(St, Q)
  Q.on_begin = R.on_begin
  Q.rain = C.rain
  Q.on_rain = C.splash
  G.init(St, Q, L, N, F, C, R)
  U.init(St, G, L, N, F, C, R)
  St.on_hit = function(t, vel) U.ripple(t, vel) end

  St.build_params()
  F.add_params()
  R.add_params()
  N.capture_init()   -- before any snapshot or PSET lands: this IS init
  N.load_file()

  params.action_write = function(filename, name, number)
    tab.save(St.serialize(), norns.state.data .. "drumdrum-" .. number .. ".data")
  end
  params.action_read = function(filename, silent, number)
    local d = tab.load(norns.state.data .. "drumdrum-" .. number .. ".data")
    if d then St.deserialize(d) end
  end
  params.action_delete = function(filename, name, number)
    os.remove(norns.state.data .. "drumdrum-" .. number .. ".data")
  end

  -- MIDI START/STOP, Link start/stop sync and internal restarts all arrive
  -- here; see "transport" in lib/seq
  clock.transport.start = function() Q.on_start() end
  clock.transport.stop = function() Q.on_stop() end

  -- give the engine a moment to finish alloc before pushing params at it
  clock.run(function()
    clock.sleep(0.3)
    params:bang()
    start_polls()
  end)

  screen_metro = metro.init(function()
    local dt = 1 / FPS
    for _, tr in ipairs(St.tracks) do
      if tr.flash > 0 then
        tr.flash = math.max(tr.flash - (dt * 4), 0)
        St.dirty = true
      end
    end
    if St.page == "colour" then
      U.vis_update(dt)
      St.dirty = true
    end
    local kind = G.overlay()
    if kind == "ctrl" or kind == "tape" or kind == "rec" or St.page == "mix" or St.page == "snap" then
      St.dirty = true
    end
    if St.dirty then
      redraw()
      St.dirty = false
    end
  end, 1 / FPS)
  screen_metro:start()

  grid_metro = metro.init(function()
    N.tick(1 / 30)
    G.redraw()
  end, 1 / 30)
  grid_metro:start()

  lfo_metro = metro.init(function()
    L.step(1 / 30)
    St.push_modulated()
    St.follow_tempo()
  end, 1 / 30)
  lfo_metro:start()
end

function cleanup()
  Q.halt()   -- not Q.stop: leaving the script must not stop a Link session
  for _, m in ipairs({ screen_metro, grid_metro, lfo_metro }) do
    if m then m:stop() end
  end
  for _, p in ipairs(polls) do p:stop() end
end

-- ---------------------------------------------------------------------- keys

-- K2 and K3 act when they come UP, so that pressing both together can be
-- told from pressing either: the chord resets, and then neither key's
-- release does anything else
local function press(n)
  local kind, btn = G.overlay()
  -- quiet under the TAPE: its hand is on the grid, the other on E2/E3
  if kind == "tape" then return end
  if kind == "rec" then
    if n == 2 then R.cancel() else R.now() end
    return
  end
  if kind == "ctrl" then
    local b = S.BTN[btn]
    if b.kind == "lfo" then
      local id = St.pid(St.sel, "l" .. b.lfo .. "_shape")
      local n_sh = #S.LFO_SHAPES
      local cur = math.floor(params:get(id) + 0.5)
      cur = ((cur - 1 + ((n == 3) and 1 or -1)) % n_sh) + 1
      params:set(id, cur)
      St.dirty = true
      return
    end
    if n == 2 and #G.held_steps() > 0 and S.SOUND_KIND[b.kind] then
      clear_locks(btn)
      St.dirty = true
    end
    -- otherwise the keys are quiet under an open control: a thumb resting
    -- on K2 while a finger holds a step should not stop the music
    return
  end

  if n == 2 then
    Q.toggle()
  elseif n == 3 then
    local order = { main = "mix", mix = "colour", colour = "main" }
    St.page = order[St.page] or "main"   -- SNAP and PERFORM go back to MAIN
    G.release_all()
  end
  St.dirty = true
end

function key(n, z)
  if n == 1 then
    k1 = (z == 1)
    return
  end
  keys[n] = (z == 1)
  if z == 1 then
    if keys[2] and keys[3] then
      chord = true
      reset()
      St.dirty = true
    end
    return
  end
  if chord then
    if not keys[2] and not keys[3] then chord = false end
    return
  end
  press(n)
end

-- ------------------------------------------------------------------ encoders

function enc(n, d)
  local kind, btn = G.overlay()

  if n == 1 then
    if kind == "rec" then
      params:delta("rec_mode", d)
    elseif kind == "swing" then
      St.delta("rain", d, k1)
    elseif St.page == "colour" and not kind then
      St.col_sel = util.clamp(St.col_sel + d, 1, #S.COLOUR)
    elseif St.page == "main" and not kind then
      St.main_pair = util.clamp(St.main_pair + d, 1, #S.MAIN_PAIRS)
    else
      local t = util.clamp(St.sel + d, 1, S.NTRACKS)
      if t ~= St.sel then
        G.held = {}
        St.select(t)
      end
    end
    St.dirty = true
    return
  end

  if kind == "rec" then
    if n == 2 then St.delta("rec_thresh", d, k1)
    else params:delta("rec_src", d) end
  elseif kind == "tape" then
    if n == 2 then St.delta("tape_pitch", d, k1)
    else params:delta("tape_len", d) end
  elseif kind == "ctrl" then
    local b = S.BTN[btn]
    if b.kind == "lfo" then
      local pre = St.pid(St.sel, "l" .. b.lfo .. "_")
      St.delta(pre .. ((n == 2) and "rate" or "depth"), d, k1)
    else
      ctrl_enc(btn, (n == 2) and "a" or "b", d)
    end
  elseif kind == "swing" then
    if n == 2 then params:delta("swing", d * (k1 and 0.25 or 1))
    else params:delta("swing_grid", d) end
  elseif St.page == "mix" then
    local t = St.sel
    if n == 2 then
      if G.shift then St.delta(St.pid(t, "level"), d, k1)
      else St.delta(St.pid(t, "pan"), d, k1) end
    else
      St.delta(St.pid(t, "tilt"), d, k1)
    end
  elseif St.page == "colour" then
    local cell = S.COLOUR[St.col_sel]
    local p = (n == 2) and cell.a or cell.b
    St.delta("col_" .. p.arg, d, k1)
  elseif St.page == "main" then
    local tr = St.track()
    if St.main_pair == 1 then
      if n == 2 then tr.len = util.clamp(tr.len + d, 1, S.NSTEPS)
      else tr.speed = util.clamp(tr.speed + d, 1, #S.SPEEDS) end
    else
      if n == 2 then tr.dir = util.clamp(tr.dir + d, 1, #S.DIRS)
      else tr.dilla = util.clamp(tr.dilla + d, 0, 100) end
    end
  else
    -- SNAP, PERFORM: the tempo
    if n == 2 then params:delta("clock_tempo", d) end
  end
  St.dirty = true
end

function redraw()
  U.redraw()
end
