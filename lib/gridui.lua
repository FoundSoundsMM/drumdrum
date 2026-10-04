-- drumdrum / grid
--
-- Three faces on the same bottom row:
--
--   MAIN    rows 1-4 the selected track's 64 steps, rows 6-7 its controls
--   MIX     a fader with a meter over each track's button, pan to the sides
--   COLOUR  one row per master COLOUR cell, the row is the value
--
-- Row 8 never changes: PLAY STOP SWING . [tracks 1-8] . SHIFT MIX COLOUR.
--
-- Steps: a press on an empty step places one at once. A press on a placed
-- step holds it; let go quickly without having turned anything and it is
-- removed. While steps are held, any control you open edits THOSE steps --
-- TONE / SAMPLE / NOISE / COLOUR become parameter locks, TRIG and PULSE edit
-- the steps' own conditions.
--
-- Controls are momentary: the screen is open while the button is held.
-- SHIFT + control latches it open; the same again, or another latch, closes.

local S = include("drumdrum/lib/spec")

local G = {}
local g, St, Q, L

G.held = {}        -- held steps, oldest first: { i, t0, new, edited }
G.stack = {}       -- control buttons physically held, oldest first
G.latched = nil
G.shift = false
G.swing = false
G.bypass_flash = 0

local PANV = { -1, -1 / 3, 1 / 3, 1 }

function G.init(state, seq, lfo)
  St, Q, L = state, seq, lfo
  g = grid.connect()
  g.key = function(x, y, z) G.key(x, y, z) end
end

-- ------------------------------------------------------------------ queries

-- what the screen should show over the page, if anything
function G.overlay()
  local top = G.stack[#G.stack]
  if top then return "ctrl", top end
  if G.swing then return "swing" end
  if G.latched then return "ctrl", G.latched end
  return nil
end

function G.held_steps()
  local out = {}
  for _, h in ipairs(G.held) do out[#out + 1] = h.i end
  return out
end

-- the LFO a finger is on, if any: patching only happens while held
function G.held_lfo()
  for k = #G.stack, 1, -1 do
    local b = S.BTN[G.stack[k]]
    if b.kind == "lfo" then return b.lfo end
  end
  return nil
end

function G.mark_edited()
  for _, h in ipairs(G.held) do h.edited = true end
end

function G.release_all()
  G.held, G.stack = {}, {}
end

local function remove(list, pred)
  for k = #list, 1, -1 do
    if pred(list[k]) then return table.remove(list, k) end
  end
end

-- -------------------------------------------------------------------- keys

local function row8(x, z)
  local R = S.ROW8
  if x == R.play then
    if z == 1 then
      if G.shift then St.fill = not St.fill else Q.play() end
    end
  elseif x == R.stop then
    if z == 1 then Q.stop() end
  elseif x == R.swing then
    G.swing = (z == 1)
  elseif x > R.track0 and x <= R.track0 + S.NTRACKS then
    if z == 1 then
      local t = x - R.track0
      if G.shift then
        St.toggle_mute(t)
      elseif t ~= St.sel then
        G.held = {}
        St.select(t)
      end
    end
  elseif x == R.shift then
    G.shift = (z == 1)
  elseif x == R.mix or x == R.colour then
    if z == 1 then
      local want = (x == R.mix) and "mix" or "colour"
      St.page = (St.page == want) and "main" or want
      G.release_all()
    end
  end
end

local function step_key(x, y, z)
  local i = ((y - 1) * 16) + x
  local tr = St.track()
  if z == 1 then
    if G.shift then
      tr.len = i
      return
    end
    local st = tr.steps[i]
    if st and st.on then
      G.held[#G.held + 1] = { i = i, t0 = util.time(), new = false, edited = false }
    else
      tr.steps[i] = S.new_step(tr.tpl)
      G.held[#G.held + 1] = { i = i, t0 = util.time(), new = true, edited = false }
    end
  else
    local h = remove(G.held, function(e) return e.i == i end)
    if h and not h.new and not h.edited and (util.time() - h.t0) < 0.4 then
      tr.steps[i] = nil
    end
  end
end

local function ctrl_key(x, y, z)
  local id = S.btn_at(x, y)
  if not id then return end
  local b = S.BTN[id]
  if z == 1 then
    local li = G.held_lfo()
    if li and S.SOUND_KIND[b.kind] then
      L.patch(St.sel, li, id)
      return
    end
    if G.shift then
      G.latched = (G.latched ~= id) and id or nil
      return
    end
    G.stack[#G.stack + 1] = id
  else
    remove(G.stack, function(e) return e == id end)
  end
end

local function mix_key(x, y, z)
  if z == 0 then return end
  local R = S.ROW8
  if x > R.track0 and x <= R.track0 + S.NTRACKS then
    local t = x - R.track0
    params:set(St.pid(t, "level"), (8 - y) / 7)
    St.select(t)
    return
  end
  if y > 4 then return end
  local t, slot
  if x <= 4 then t, slot = y, x
  elseif x >= 13 then t, slot = y + 4, x - 12 end
  if not t then return end
  local id = St.pid(t, "pan")
  local v = PANV[slot]
  -- pressing where it already is sends it back to the centre
  if math.abs(params:get(id) - v) < 0.01 then v = 0 end
  params:set(id, v)
  St.select(t)
end

local function colour_key(x, y, z)
  if z == 0 then return end
  local cell = S.COLOUR[y]
  if cell then
    params:set_raw("col_" .. cell.a.arg, (x - 1) / 15)
    St.col_sel = y
  elseif y == 7 and x == 16 then
    params:set("col_bypass", (params:get("col_bypass") == 2) and 1 or 2)
  end
end

function G.key(x, y, z)
  if y == 8 then
    row8(x, z)
  elseif St.page == "mix" then
    mix_key(x, y, z)
  elseif St.page == "colour" then
    colour_key(x, y, z)
  elseif y <= S.SEQ_ROWS then
    step_key(x, y, z)
  elseif y >= S.CTRL_ROW then
    ctrl_key(x, y, z)
  end
  St.dirty = true
end

-- ------------------------------------------------------------------ redraw

local function has_extras(st)
  if st.locks and next(st.locks) then return true end
  return (st.cond or 1) ~= 1 or (st.prob or 100) < 100 or (st.pulses or 1) > 1
    or (st.flam or 0) > 0 or (st.nudge or 0) ~= 0
end

local function draw_main()
  local tr = St.track()
  local heldset = {}
  for _, h in ipairs(G.held) do heldset[h.i] = true end

  for i = 1, S.NSTEPS do
    local x, y = ((i - 1) % 16) + 1, math.floor((i - 1) / 16) + 1
    local lv = 0
    local st = tr.steps[i]
    local on = st and st.on
    if i <= tr.len then
      -- the first beat of every bar, dimly, so the grid has somewhere to count from
      if (i - 1) % 16 == 0 then lv = 2 end
      if on then lv = has_extras(st) and 11 or 7 end
      if St.playing and tr.ph == i then lv = on and 15 or 4 end
    end
    if heldset[i] then lv = 15 end
    if lv > 0 then g:led(x, y, lv) end
  end

  -- controls
  local _, open = G.overlay()
  local li = G.held_lfo()
  -- which buttons have a lock on any held step
  local locked = {}
  for _, h in ipairs(G.held) do
    local st = tr.steps[h.i]
    if st and st.locks then
      for k in pairs(st.locks) do locked[k:sub(1, -2)] = true end
    end
  end

  for id, b in pairs(S.BTN) do
    local lv = 3
    if b.kind == "lfo" then
      local o = L.st[St.sel][b.lfo]
      if o.target then
        lv = 4 + math.floor((o.val + 1) * 4 + 0.5)
      end
    end
    if locked[id] then lv = 9 end
    if li and L.side_on(St.sel, li, id) then lv = 13 end
    if G.latched == id then lv = 11 end
    if open == id and G.stack[#G.stack] == id then lv = 15 end
    g:led(b.x, b.y, lv)
  end
end

local function draw_mix()
  local R = S.ROW8
  for t = 1, S.NTRACKS do
    local x = R.track0 + t
    local lvl = params:get(St.pid(t, "level"))
    local top = util.clamp(8 - math.floor((lvl * 7) + 0.5), 1, 7)
    local m = St.meter[t] or 0
    local db = (m > 0.00001) and (20 * math.log(m, 10)) or -96
    local mrows = util.clamp(math.floor(((db + 42) / 42) * 7 + 0.5), 0, 7)
    local sel = (t == St.sel)
    for y = 1, 7 do
      local lv = 0
      if y >= top then lv = sel and 4 or 2 end
      if y == top then lv = sel and 8 or 6 end
      if (8 - y) <= mrows then
        lv = math.max(lv, (y <= 1) and 15 or 11)
      end
      if lv > 0 then g:led(x, y, lv) end
    end
  end
  -- pan: tracks 1-4 on the left, 5-8 on the right, a row each
  for t = 1, S.NTRACKS do
    local pan = params:get(St.pid(t, "pan"))
    local y = (t <= 4) and t or (t - 4)
    local x0 = (t <= 4) and 0 or 12
    local sel = (t == St.sel)
    for slot = 1, 4 do
      local near = 1 - math.min(math.abs(pan - PANV[slot]) * 1.5, 1)
      local lv = math.floor((near * (sel and 12 or 8)) + 0.5) + (sel and 2 or 1)
      g:led(x0 + slot, y, lv)
    end
  end
end

local function draw_colour()
  for y, cell in ipairs(S.COLOUR) do
    local r = params:get_raw("col_" .. cell.a.arg)
    local n = math.floor(r * 15 + 0.5) + 1
    local sel = (y == St.col_sel)
    for x = 1, 16 do
      local lv = 0
      if x < n then lv = sel and 5 or 2 end
      if x == n then lv = sel and 15 or 9 end
      if lv > 0 then g:led(x, y, lv) end
    end
  end
  g:led(16, 7, (params:get("col_bypass") == 2) and 15 or 4)
end

local function draw_row8()
  local R = S.ROW8
  local blink = (math.floor(util.time() * 4) % 2) == 0
  local play = St.playing and 15 or 4
  if St.fill and blink then play = St.playing and 6 or 10 end
  g:led(R.play, 8, play)
  g:led(R.stop, 8, St.playing and 4 or 8)
  g:led(R.swing, 8, G.swing and 15 or 4)
  for t = 1, S.NTRACKS do
    local tr = St.tracks[t]
    local lv
    if t == St.sel then lv = 15
    elseif tr.mute then lv = 1
    else lv = 4 + math.floor(tr.flash * 7 + 0.5) end
    g:led(R.track0 + t, 8, lv)
  end
  g:led(R.shift, 8, G.shift and 15 or 4)
  g:led(R.mix, 8, (St.page == "mix") and 15 or 4)
  g:led(R.colour, 8, (St.page == "colour") and 15 or 4)
end

function G.redraw()
  if not g then return end
  g:all(0)
  if St.page == "mix" then draw_mix()
  elseif St.page == "colour" then draw_colour()
  else draw_main() end
  draw_row8()
  g:refresh()
end

return G
