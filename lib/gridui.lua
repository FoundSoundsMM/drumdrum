-- drumdrum / grid
--
-- Five faces on the same bottom row:
--
--   MAIN    rows 1-4 the selected track's 64 steps, rows 6-7 its controls
--   MIX     a fader with a meter over each track's button, pan to the sides
--   COLOUR  the screen is the master COLOUR; the grid is the CLIP
--           LAUNCHER: the seven rows above each track's button are its
--           clip slots (see lib/clips). Tap launches on the next bar, hold
--           one + tap another copies. The columns either side show the
--           RAIN. Row 7: columns 1 and 2 step back and forward through the
--           colour banks (BUSS DUCK TEXTURE SPACE), column 16 is BYPASS
--   SNAP    rows 1-4 are 64 snapshots (SHIFT + PLAY opens it): tap loads on
--           the beat (a blank cell loads the init patch), SHIFT + hold
--           saves. Row 7, columns 1-4 are the kits WARM WOOD FM ADD: tap
--           one for every track, or hold one and press track buttons to
--           move only those
--   PERFORM rows 1-4 are 64 punch-in effects (SHIFT + MIX opens it), eight
--           strips of eight, held or SHIFT-latched; see lib/perform
--
-- Row 8 never changes: PLAY STOP SWING . [tracks 1-8] . CLEAR MIX COLOUR.
--
-- SHIFT is norns K2 (G.shift is set from drumdrum.lua). SHIFT + track plays
-- the track's sound, SHIFT + STOP is FILL while STOP is held, SHIFT +
-- COLOUR held is the hidden TAPE. On MIX and PERFORM the track buttons mute.
--
-- CLEAR takes things away. CLEAR + step: the step back to a plain hit.
-- CLEAR + track, held: the track's pattern gone. CLEAR + control: that
-- control reset (or its locks off the held steps). CLEAR + snapshot, held:
-- deleted. CLEAR + clip slot: emptied. CLEAR + pad: its latch off. CLEAR on
-- its own, let go without having done any of those: the open screen reset
-- (G.on_clear, from drumdrum.lua).
--
-- SAMPLER: hold S1 and SHIFT and the steps are a record length
-- (lib/sampler). Tap one to arm the selected track for that many steps, the
-- same one again to disarm. A take recording fills the steps as it goes.
--
-- Steps: a press on an empty step places one at once. A press on a placed
-- step holds it; let go quickly without having turned anything and it is
-- removed. While steps are held, any control you open edits THOSE steps --
-- TONE / SAMPLE / NOISE / COLOUR become parameter locks, TRIG and PULSE edit
-- the steps' own conditions.
--
-- Controls are momentary: the screen is open while the button is held.
-- SHIFT + control latches it open; the same again, or another latch, closes.
-- Hold an LFO and a sound control together and E2 / E3 patch it.

local S = include("drumdrum/lib/spec")

local G = {}
local g, St, Q, L, N, F, C, R

G.held = {}        -- held steps, oldest first: { i, t0, new, edited }
G.stack = {}       -- control buttons physically held, oldest first
G.latched = nil
G.lock = nil       -- a sound control opened over held steps, kept open on
                   -- those steps after letting go: { btn, steps = { i... } }
G.swallow = {}     -- steps whose press closed the lock: their release does nothing
G.shift = false    -- norns K2 held
G.shift_used = false  -- something was done with SHIFT: its release is not a tap
G.clear = false    -- CLEAR held
G.clear_used = false  -- CLEAR + something happened: its release resets nothing
G.wipe = nil       -- CLEAR + track held: { t, t0, done }, the pattern goes at WIPE_HOLD
G.patch = nil      -- an LFO and a sound control held together: { lfo, btn }
G.on_clear = nil       -- CLEAR on its own (drumdrum.lua: reset the open screen)
G.on_clear_ctrl = nil  -- CLEAR + control (drumdrum.lua: reset that control)
G.swing = false
G.fill = false     -- FILL is on because SHIFT + STOP went down: off with STOP
G.tape = false     -- the hidden TAPE: SHIFT + COLOUR, on while COLOUR is held
G.bypass_flash = 0
G.kit = nil        -- SNAP: a kit button held, { k, used }: let go unused, it is every track

-- pan: three buttons a track, nudge left, centre, nudge right
local PAN_STEP = 0.1
local WIPE_HOLD = 0.5

function G.init(state, seq, lfo, snap, perform, clips, sampler)
  St, Q, L, N, F, C, R = state, seq, lfo, snap, perform, clips, sampler
  g = grid.connect()
  g.key = function(x, y, z) G.key(x, y, z) end
end

-- ------------------------------------------------------------------ queries

-- what the screen should show over the page, if anything
function G.overlay()
  if G.tape then return "tape" end
  local top = G.stack[#G.stack]
  if top then return "ctrl", top end
  if G.swing then return "swing" end
  if G.lock then return "ctrl", G.lock.btn end
  if G.latched then return "ctrl", G.latched end
  if R and R.active() and St.page == "main" then return "rec" end
  return nil
end

-- the steps a control edits: the ones under a finger, plus a lock's
function G.held_steps()
  local out, seen = {}, {}
  for _, h in ipairs(G.held) do out[#out + 1] = h.i; seen[h.i] = true end
  if G.lock then
    for _, i in ipairs(G.lock.steps) do
      if not seen[i] then out[#out + 1] = i end
    end
  end
  return out
end

function G.drop_held()
  G.held, G.lock, G.swallow = {}, nil, {}
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
  G.held, G.stack, G.kit = {}, {}, nil
  G.wipe, G.patch = nil, nil
  G.lock, G.swallow = nil, {}
  C.hold = nil
  F.release_held()
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
      if G.shift then
        St.page = (St.page == "snap") and "main" or "snap"
        G.release_all()
      else
        Q.play()
      end
    end
  elseif x == R.stop then
    -- SHIFT + STOP is FILL while STOP stays down, however SHIFT moves
    -- meanwhile
    if z == 1 then
      if G.shift then
        G.fill = true
        St.fill = true
      else
        Q.stop()
      end
    elseif G.fill then
      G.fill = false
      St.fill = false
    end
  elseif x == R.swing then
    G.swing = (z == 1)
  elseif x > R.track0 and x <= R.track0 + S.NTRACKS then
    local t = x - R.track0
    if z == 0 then
      if G.wipe and G.wipe.t == t then G.wipe = nil end
    else
      if G.clear then
        -- held long enough, the pattern goes (see G.redraw)
        G.wipe = { t = t, t0 = util.time() }
        G.clear_used = true
      elseif G.kit then
        -- holding a kit on SNAP: this track to it, the rest left alone
        St.set_kit(t, G.kit.k)
        G.kit.used = true
      elseif G.shift then
        St.audition(t)
      elseif St.page == "mix" or St.page == "perform" then
        St.toggle_mute(t)
      elseif t ~= St.sel then
        G.drop_held()
        St.select(t)
      end
    end
  elseif x == R.clear then
    G.clear = (z == 1)
    if z == 1 then
      G.clear_used = false
    else
      G.wipe = nil
      if not G.clear_used and G.on_clear then G.on_clear() end
    end
  elseif x == R.colour and (G.tape or (G.shift and z == 1)) then
    -- the hidden TAPE: on with SHIFT, off with COLOUR, whatever SHIFT does
    G.tape = (z == 1)
    if G.tape then F.tape_on() else F.tape_off() end
  elseif x == R.mix or x == R.colour then
    if z == 1 then
      local want = (x == R.mix) and "mix" or "colour"
      if G.shift and x == R.mix then want = "perform" end
      St.page = (St.page == want) and "main" or want
      G.release_all()
    end
  end
end

-- S1 and SHIFT held, no steps: the steps are the sampler's lengths.
-- SHIFT + step is always a length: the track's, or with S1 the take's.
local function rec_pick()
  return R and G.shift and G.stack[#G.stack] == "S1" and #G.held == 0
end

local function step_key(x, y, z)
  local i = ((y - 1) * 16) + x
  local tr = St.track()
  if z == 1 and rec_pick() then
    R.arm(St.sel, i)
    return
  end
  if z == 1 then
    if G.clear then
      -- the step back to a plain hit: no locks, conditions or pulses
      G.clear_used = true
      if tr.steps[i] then tr.steps[i] = S.new_step() end
      G.swallow[i] = true
      return
    end
    if G.shift then
      tr.len = i
      return
    end
    -- a lock open and no step under a finger: this press only closes it
    if G.lock and #G.held == 0 then
      G.lock = nil
      G.swallow[i] = true
      return
    end
    local st = tr.steps[i]
    if st and st.on then
      G.held[#G.held + 1] = { i = i, t0 = util.time(), new = false, edited = false }
    else
      tr.steps[i] = S.new_step(tr.tpl)
      G.held[#G.held + 1] = { i = i, t0 = util.time(), new = true, edited = false }
    end
    -- another step joining the ones a lock is open on
    if G.lock then
      G.lock.steps[#G.lock.steps + 1] = i
      G.held[#G.held].edited = true
    end
  else
    if G.swallow[i] then
      G.swallow[i] = nil
      return
    end
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
    if G.clear then
      G.clear_used = true
      if G.on_clear_ctrl then G.on_clear_ctrl(id) end
      return
    end
    local li = G.held_lfo()
    if li and S.SOUND_KIND[b.kind] then
      -- E2 / E3 patch it while both are held
      G.patch = { lfo = li, btn = id }
      return
    end
    if b.kind == "lfo" then
      -- the other way round: a sound control already down
      for k = #G.stack, 1, -1 do
        if S.SOUND_KIND[S.BTN[G.stack[k]].kind] then
          G.patch = { lfo = b.lfo, btn = G.stack[k] }
          break
        end
      end
    end
    if G.shift then
      G.latched = (G.latched ~= id) and id or nil
      return
    end
    if S.SOUND_KIND[b.kind] then
      if G.lock and G.lock.btn == id and #G.held == 0 then
        -- the open lock's own button again: close it
        G.lock = nil
        return
      end
      if #G.held > 0 or G.lock then
        -- over held steps: stays open on them once the fingers come off
        G.lock = { btn = id, steps = G.held_steps() }
        G.mark_edited()
        return
      end
    end
    G.stack[#G.stack + 1] = id
  else
    remove(G.stack, function(e) return e == id end)
    if G.patch and (G.patch.btn == id or (b.kind == "lfo" and G.patch.lfo == b.lfo)) then
      G.patch = nil
    end
  end
end

local function mix_key(x, y, z)
  if z == 0 then return end
  local R = S.ROW8
  if x > R.track0 and x <= R.track0 + S.NTRACKS then
    local t = x - R.track0
    if G.clear then
      G.clear_used = true
      St.reset(St.pid(t, "level"))
    else
      params:set(St.pid(t, "level"), (8 - y) / 7)
    end
    St.select(t)
    return
  end
  if y > 4 then return end
  local t, slot
  if x <= 3 then t, slot = y, x
  elseif x >= 14 then t, slot = y + 4, x - 13 end
  if not t then return end
  local id = St.pid(t, "pan")
  if G.clear then
    G.clear_used = true
    St.reset(id)
  elseif slot == 2 then
    params:set(id, 0)
  else
    local d = (slot == 1) and -PAN_STEP or PAN_STEP
    -- land on the increments, so ten presses from centre is hard over
    local v = (math.floor((params:get(id) / PAN_STEP) + 0.5) * PAN_STEP) + d
    params:set(id, util.clamp(v, -1, 1))
  end
  St.select(t)
end

local function snap_key(x, y, z)
  if y == 7 and x <= #S.KITS then
    -- decided on release: a track pressed meanwhile means only those
    if z == 1 then
      G.kit = { k = x, used = false }
    elseif G.kit and G.kit.k == x then
      if not G.kit.used then St.set_kit_all(x) end
      G.kit = nil
    end
    return
  end
  if y > S.SEQ_ROWS then return end
  local i = ((y - 1) * 16) + x
  if z == 1 then
    if G.clear then
      G.clear_used = true
      N.hold_start(i, "delete")
    elseif G.shift then N.hold_start(i)
    else N.recall(i) end
  else
    N.hold_end(i)
  end
end

local function launch_key(x, y, z)
  local t, c = C.at(x, y)
  if not t then return end
  if z == 0 then
    C.release(t, c)
  elseif G.clear then
    G.clear_used = true
    C.press(t, c, true)
  else
    C.press(t, c)
  end
end

-- COLOUR: the launcher, with the bank pager and BYPASS on row 7
local COL_BACK, COL_FWD, COL_BYPASS = 1, 2, 16

local function colour_key(x, y, z)
  if y == 7 and (x == COL_BACK or x == COL_FWD or x == COL_BYPASS) then
    if z == 0 then return end
    if x == COL_BYPASS then
      params:set("col_bypass", (params:get("col_bypass") == 2) and 1 or 2)
    else
      -- round and round: forward from SPACE is BUSS again
      local nb = #S.COLOUR_BANKS
      local b = S.COLOUR[St.col_sel].bank + ((x == COL_FWD) and 1 or -1)
      St.col_sel = S.BANK_CELLS[((b - 1) % nb) + 1][1]
    end
    return
  end
  launch_key(x, y, z)
end

local function perform_key(x, y, z)
  local f, i = F.strip_at(x, y)
  if not f then return end
  if z == 1 and G.clear then
    G.clear_used = true
    F.unlatch(f)
  elseif z == 1 then F.press(f, i, G.shift)
  else F.release(f, i) end
end

function G.key(x, y, z)
  if z == 1 and G.shift then G.shift_used = true end
  if y == 8 then
    row8(x, z)
  elseif St.page == "perform" then
    perform_key(x, y, z)
  elseif St.page == "mix" then
    mix_key(x, y, z)
  elseif St.page == "colour" then
    colour_key(x, y, z)
  elseif St.page == "snap" then
    snap_key(x, y, z)
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

local draw_ctrls   -- the two control rows, below

-- S1 held: every length that fits in 20 s, beats brighter, the armed
-- length blinking. A take recording: the steps fill as it goes.
local function draw_rec()
  local blink = (math.floor(util.time() * 4) % 2) == 0
  local rec = R.t and R.eng >= 3
  local n = rec and R.steps or R.max_steps(St.sel)
  local done = rec and math.floor((R.prog * R.steps) + 0.5) or 0
  for i = 1, n do
    local x, y = ((i - 1) % 16) + 1, math.floor((i - 1) / 16) + 1
    local lv = ((i - 1) % 4 == 0) and 3 or 1
    if rec then lv = (i <= done) and 12 or 2
    elseif R.t == St.sel and i == R.steps then lv = blink and 15 or 6 end
    g:led(x, y, lv)
  end
end

local function draw_main()
  if rec_pick() or (R and R.t and R.eng >= 3) then
    draw_rec()
    draw_ctrls()
    return
  end
  local tr = St.track()
  local heldset = {}
  -- SHIFT on its own flashes the last step, where SHIFT + step would move it
  local show_len = G.shift and #G.held == 0 and #G.stack == 0
  local flash = (math.floor(util.time() * 6) % 2) == 0
  for _, h in ipairs(G.held) do heldset[h.i] = true end
  local lockset = {}
  if G.lock then for _, i in ipairs(G.lock.steps) do lockset[i] = true end end
  -- CLEAR + this track held: the steps fade out as the wipe comes
  local fade = 1
  if G.wipe and G.wipe.t == St.sel then
    fade = 1 - util.clamp((util.time() - G.wipe.t0) / WIPE_HOLD, 0, 1)
  end

  for i = 1, S.NSTEPS do
    local x, y = ((i - 1) % 16) + 1, math.floor((i - 1) / 16) + 1
    local lv = 0
    local st = tr.steps[i]
    local on = st and st.on
    if i <= tr.len then
      -- every beat (four steps) dimly, the first of each bar a touch
      -- brighter, so the grid has somewhere to count from
      if (i - 1) % 16 == 0 then lv = 3
      elseif (i - 1) % 4 == 0 then lv = 2 end
      if on then lv = math.floor(((has_extras(st) and 11 or 7) * fade) + 0.5) end
      if St.playing and tr.ph == i then lv = on and 15 or 4 end
    end
    if lockset[i] then lv = flash and 15 or 4 end
    if heldset[i] then lv = 15 end
    if show_len and i == tr.len then lv = flash and 15 or 5 end
    if lv > 0 then g:led(x, y, lv) end
  end

  draw_ctrls()
end

draw_ctrls = function()
  local tr = St.track()
  local _, open = G.overlay()
  local li = G.held_lfo()
  -- which buttons have a lock on any held step
  local locked = {}
  for _, i in ipairs(G.held_steps()) do
    local st = tr.steps[i]
    if st and st.locks then
      for k in pairs(st.locks) do locked[k:sub(1, -2)] = true end
    end
  end

  for id, b in pairs(S.BTN) do
    local lv = 3
    -- TC and P a touch brighter while new steps would not be plain
    if S.STEP_KIND[b.kind] then
      local pair = S.pair(St.sel, id)
      if (tr.tpl[pair.a.key] or pair.a.def) ~= pair.a.def
        or (tr.tpl[pair.b.key] or pair.b.def) ~= pair.b.def then lv = 6 end
    end
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
    if G.lock and G.lock.btn == id and not G.stack[1] then lv = 15 end
    if G.patch and G.patch.btn == id then lv = 15 end
    -- S1 pulses while a take is armed or recording on this track
    if id == "S1" and R and R.t == St.sel and lv < 15 then
      lv = 6 + math.floor((math.sin(util.time() * 6) + 1) * 4 + 0.5)
    end
    g:led(b.x, b.y, lv)
  end
end

-- the launcher: a column of seven slots over each track's button. Empty
-- slots dim, full ones half, the one playing bright and flashing with its
-- hits, a launch waiting for its bar blinking. Either side, the rain.
local function draw_launch()
  local now = util.time()
  local blink = (math.floor(now * 8) % 2) == 0
  for t = 1, S.NTRACKS do
    local tr = St.tracks[t]
    local x = S.ROW8.track0 + t
    local nc = tr.next_clip and tr.next_clip.c
    for c = 1, C.COUNT do
      local lv = C.has(t, c) and 5 or 1
      if c == tr.clip then
        lv = tr.mute and 6 or (10 + math.floor(tr.flash * 5 + 0.5))
      end
      if c == nc then lv = blink and 15 or 3 end
      if C.hold and C.hold.t == t and C.hold.c == c then lv = 15 end
      g:led(x, c, lv)
    end
  end
  local keep = {}
  for _, d in ipairs(C.drops) do
    local y = 1 + math.floor((now - d.t0) * 16)
    if y <= C.COUNT then
      keep[#keep + 1] = d
      g:led(d.x, y, 12)
      if y > 1 then g:led(d.x, y - 1, 3) end
    end
  end
  C.drops = keep
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
  -- pan: tracks 1-4 on the left, 5-8 on the right, three buttons a row.
  -- The centre is bright at centre; each side lights as far as it is over.
  for t = 1, S.NTRACKS do
    local pan = params:get(St.pid(t, "pan"))
    local y = (t <= 4) and t or (t - 4)
    local x0 = (t <= 4) and 0 or 13
    local sel = (t == St.sel)
    local top, floor = sel and 15 or 9, sel and 3 or 1
    local function lv(a) return floor + math.floor((a * (top - floor)) + 0.5) end
    g:led(x0 + 1, y, lv(math.max(-pan, 0)))
    g:led(x0 + 2, y, lv(1 - math.abs(pan)))
    g:led(x0 + 3, y, lv(math.max(pan, 0)))
  end
end

local function draw_snap()
  local blink = (math.floor(util.time() * 8) % 2) == 0
  local pend = N.pending and N.pending.slot
  local hold = N.act and N.act.slot
  local deleting = N.act and N.act.kind == "delete"
  for i = 1, N.COUNT do
    local x, y = ((i - 1) % 16) + 1, math.floor((i - 1) / 16) + 1
    local lv = N.has(i) and 6 or 1
    if i == N.last then lv = 12 end
    if i == pend then lv = blink and 15 or 4 end
    if i == hold and deleting then
      -- the cell drains as the delete hold goes on
      lv = math.floor(((1 - N.progress()) * 15) + 0.5)
    elseif i == hold and N.has(i) then
      -- an overwrite: the full cell goes dark and refills, so the hold
      -- shows even on a cell that was already lit
      lv = math.floor((N.progress() * 15) + 0.5)
    elseif i == hold then
      lv = math.max(lv, 2 + math.floor((N.progress() * 13) + 0.5))
    end
    lv = math.max(lv, math.floor((N.pulse[i] or 0) * 15 + 0.5))
    g:led(x, y, lv)
  end
  -- the kits: bright when every track is on it, half when some are
  for k = 1, #S.KITS do
    local n = 0
    for t = 1, S.NTRACKS do if S.kit_of(t) == k then n = n + 1 end end
    local lv = (n == S.NTRACKS) and 12 or ((n > 0) and 6 or 2)
    if G.kit and G.kit.k == k then lv = 15 end
    g:led(k, 7, lv)
  end
end

-- the launcher, then row 7's pager and BYPASS over any rain falling there
local function draw_colour()
  draw_launch()
  g:led(COL_BACK, 7, 6)
  g:led(COL_FWD, 7, 6)
  g:led(COL_BYPASS, 7, (params:get("col_bypass") == 2) and 15 or 4)
end

-- each strip dim, its first pad a little brighter so the eight read apart;
-- what is sounding bright, a latch a step below
local function draw_perform()
  for f, s in ipairs(F.STRIPS) do
    local want = F.want(f)
    local held = {}
    for _, i in ipairs(F.held[f]) do held[i] = true end
    for i = 1, #s.pads do
      local x, y = F.pad_xy(f, i)
      local lv = (i == 1) and 4 or 2
      if held[i] then lv = 8 end
      if F.latched[f] == i then lv = 10 end
      if want == i then lv = held[i] and 15 or 12 end
      g:led(x, y, lv)
    end
  end
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
    -- holding a kit on SNAP: the tracks on it bright, the rest dim
    local mutes = (St.page == "mix" or St.page == "perform")
    if G.kit then lv = (S.kit_of(t) == G.kit.k) and 15 or 2
    -- CLEAR + track held: blinking until the pattern goes
    elseif G.wipe and G.wipe.t == t then lv = blink and 15 or 0
    -- on MIX and PERFORM these buttons are the mutes, so a mute shows even
    -- when selected
    elseif (tr.mute or St.pmute[t]) and (mutes or t ~= St.sel) then lv = 1
    elseif t == St.sel then lv = 15
    else lv = 4 + math.floor(tr.flash * 7 + 0.5) end
    g:led(R.track0 + t, 8, lv)
  end
  g:led(R.clear, 8, G.clear and 15 or 4)
  g:led(R.mix, 8, (St.page == "mix") and 15 or ((St.page == "perform") and 10 or 4))
  g:led(R.colour, 8, (G.tape or St.page == "colour") and 15 or 4)
end

-- CLEAR + track held long enough: the playing clip's steps go
local function wipe_tick()
  local w = G.wipe
  if w and not w.done and (util.time() - w.t0) >= WIPE_HOLD then
    w.done = true
    C.clear_slot(w.t, St.tracks[w.t].clip)
    if w.t == St.sel then G.drop_held() end
  end
end

function G.redraw()
  wipe_tick()
  if not g then return end
  g:all(0)
  if St.page == "mix" then draw_mix()
  elseif St.page == "colour" then draw_colour()
  elseif St.page == "snap" then draw_snap()
  elseif St.page == "perform" then draw_perform()
  else draw_main() end
  draw_row8()
  g:refresh()
end

return G
