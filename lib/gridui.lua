-- drumdrum / grid
--
-- Five faces on the same bottom row:
--
--   MAIN    rows 1-4 the selected track's 64 steps, rows 6-7 its controls
--   MIX     a fader with a meter over each track's button, pan to the sides
--   COLOUR  the screen is the master COLOUR; the grid is the CLIP
--           LAUNCHER: the seven rows above each track's button are its
--           clip slots (see lib/clips). Tap launches on the next bar, hold
--           one + tap another copies, SHIFT + STOP + slot empties. The
--           columns either side show the RAIN. Row 7: columns 1 and 2 step
--           back and forward through the colour banks (BUSS DUCK TEXTURE
--           SPACE), column 16 is BYPASS
--   SNAP    rows 1-4 are 64 snapshots (SHIFT + PLAY opens it): tap loads on
--           the beat (a blank cell loads the init patch), SHIFT + hold
--           saves, SHIFT + STOP + hold deletes. Row 7, columns 1-4 are the
--           kits WARM WOOD FM GLITCH: tap one for every track, or hold one and
--           press track buttons to move only those
--   PERFORM rows 1-4 are 64 punch-in effects (SHIFT + MIX opens it), eight
--           strips of eight, held or SHIFT-latched; see lib/perform
--
-- Row 8 never changes: PLAY STOP SWING . [tracks 1-8] . SHIFT MIX COLOUR.
-- SHIFT + track plays the track's sound. SHIFT + STOP is FILL for as long
-- as STOP is held. SHIFT + COLOUR, held, is the hidden TAPE. On MIX the
-- track buttons mute.
--
-- SAMPLER: hold S1 and the steps are a record length (lib/sampler). Tap
-- one to arm the selected track for that many steps, the same one again to
-- disarm. A take recording fills the steps as it goes.
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
local g, St, Q, L, N, F, C, R

G.held = {}        -- held steps, oldest first: { i, t0, new, edited }
G.stack = {}       -- control buttons physically held, oldest first
G.latched = nil
G.shift = false
G.swing = false
G.stop = false     -- STOP physically held: SHIFT + STOP + cell deletes on SNAP
G.fill = false     -- FILL is on because SHIFT + STOP went down: off with STOP
G.tape = false     -- the hidden TAPE: SHIFT + COLOUR, on while COLOUR is held
G.bypass_flash = 0
G.kit = nil        -- SNAP: a kit button held, { k, used }: let go unused, it is every track

-- pan: three buttons a track, nudge left, centre, nudge right
local PAN_STEP = 0.1

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
  if G.latched then return "ctrl", G.latched end
  if R and R.active() and St.page == "main" then return "rec" end
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
  G.held, G.stack, G.kit = {}, {}, nil
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
    -- meanwhile. On SNAP it is also the delete chord: a delete starting
    -- ends the fill (see snap_key).
    G.stop = (z == 1)
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
    if z == 1 then
      local t = x - R.track0
      if G.kit then
        -- holding a kit on SNAP: this track to it, the rest left alone
        St.set_kit(t, G.kit.k)
        G.kit.used = true
      elseif G.shift then
        St.audition(t)
      elseif St.page == "mix" then
        St.toggle_mute(t)
      elseif t ~= St.sel then
        G.held = {}
        St.select(t)
      end
    end
  elseif x == R.shift then
    G.shift = (z == 1)
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

-- S1 held on its own: the steps are the sampler's lengths
local function rec_pick()
  return R and G.stack[#G.stack] == "S1" and #G.held == 0
end

local function step_key(x, y, z)
  local i = ((y - 1) * 16) + x
  local tr = St.track()
  if z == 1 and rec_pick() then
    R.arm(St.sel, i)
    return
  end
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
  if x <= 3 then t, slot = y, x
  elseif x >= 14 then t, slot = y + 4, x - 13 end
  if not t then return end
  local id = St.pid(t, "pan")
  if slot == 2 then
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
    if G.shift and G.stop then
      -- a delete, not a fill: the fill this chord started stops here
      G.fill = false
      St.fill = false
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
  elseif G.stop then
    -- an empty, not a fill: the fill this chord started stops here
    G.fill = false
    St.fill = false
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
  if z == 1 then F.press(f, i, G.shift)
  else F.release(f, i) end
end

function G.key(x, y, z)
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
  local show_len = G.shift and not G.stop and #G.held == 0 and #G.stack == 0
  local flash = (math.floor(util.time() * 6) % 2) == 0
  for _, h in ipairs(G.held) do heldset[h.i] = true end

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
      if on then lv = has_extras(st) and 11 or 7 end
      if St.playing and tr.ph == i then lv = on and 15 or 4 end
    end
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
    if G.kit then lv = (S.kit_of(t) == G.kit.k) and 15 or 2
    -- on MIX these buttons are the mutes, so a mute shows even when selected
    elseif (tr.mute or St.pmute[t]) and (St.page == "mix" or t ~= St.sel) then lv = 1
    elseif t == St.sel then lv = 15
    else lv = 4 + math.floor(tr.flash * 7 + 0.5) end
    g:led(R.track0 + t, 8, lv)
  end
  g:led(R.shift, 8, G.shift and 15 or 4)
  g:led(R.mix, 8, (St.page == "mix") and 15 or ((St.page == "perform") and 10 or 4))
  g:led(R.colour, 8, (G.tape or St.page == "colour") and 15 or 4)
end

function G.redraw()
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
