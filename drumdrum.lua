-- drumdrum
--
-- warm, dusty drum machine
-- for norns + grid 128
--
-- 8 voices, synth + sample each
-- BD1 BD2 CLP SNR PRC1 PRC2 HAT CYM
--
-- E1 track (COLOUR: cell)
-- E2 / E3 the open screen's pair
-- main: E2 tempo  E3 speed
-- mix:  E2 pan    E3 tilt
-- K2 play/stop  K3 next page
-- K1 held: fine adjust
--
-- grid: see README

engine.name = "DrumDrum"

local S  = include("drumdrum/lib/spec")
local St = include("drumdrum/lib/state")
local Q  = include("drumdrum/lib/seq")
local L  = include("drumdrum/lib/lfo")
local G  = include("drumdrum/lib/gridui")
local U  = include("drumdrum/lib/ui")

local k1 = false
local screen_metro, grid_metro, lfo_metro
local FPS = 30
local polls = {}

-- the live modules, for the maiden repl
drumdrum = { state = St, seq = Q, lfo = L, grid = G, ui = U, spec = S }

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
end

function init()
  St.init()
  L.init()
  St.lfo = L
  Q.init(St)
  G.init(St, Q, L)
  U.init(St, G, L)
  St.on_hit = function(t, vel) U.ripple(t, vel) end

  St.build_params()

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

  -- a starting beat, so the first press of PLAY says something
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
  put(3, { 13 }, { cond = 10 })   -- 1:2

  clock.transport.start = function() Q.play() end
  clock.transport.stop = function() Q.stop() end

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
    if kind == "ctrl" or St.page == "mix" then St.dirty = true end
    if St.dirty then
      redraw()
      St.dirty = false
    end
  end, 1 / FPS)
  screen_metro:start()

  grid_metro = metro.init(function() G.redraw() end, 1 / 30)
  grid_metro:start()

  lfo_metro = metro.init(function()
    L.step(1 / 30)
    St.push_modulated()
  end, 1 / 30)
  lfo_metro:start()
end

function cleanup()
  Q.stop()
  for _, m in ipairs({ screen_metro, grid_metro, lfo_metro }) do
    if m then m:stop() end
  end
  for _, p in ipairs(polls) do p:stop() end
end

-- ---------------------------------------------------------------------- keys

function key(n, z)
  if n == 1 then
    k1 = (z == 1)
    return
  end
  if z == 0 then return end

  local kind, btn = G.overlay()
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
    St.page = order[St.page] or "main"
    G.release_all()
  end
  St.dirty = true
end

-- ------------------------------------------------------------------ encoders

function enc(n, d)
  local kind, btn = G.overlay()

  if n == 1 then
    if St.page == "colour" and not kind then
      St.col_sel = util.clamp(St.col_sel + d, 1, #S.COLOUR)
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

  if kind == "ctrl" then
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
  else
    if n == 2 then
      params:delta("clock_tempo", d)
    else
      local tr = St.track()
      tr.speed = util.clamp(tr.speed + d, 1, #S.SPEEDS)
    end
  end
  St.dirty = true
end

function redraw()
  U.redraw()
end
