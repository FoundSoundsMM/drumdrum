-- drumdrum / screen
--
-- Six pages and four overlays. The pages are what the grid's MIX and
-- COLOUR buttons (and SHIFT + PLAY for SNAP, SHIFT + MIX for PERFORM,
-- SHIFT + SWING for CLIPS, whose E2 is the RAIN)
-- choose between; the overlays are momentary and sit on top of whichever
-- page is open:
--
--   CONTROL  a held (or latched) track control: two parameters, E2 and E3
--   LFO      a held LFO button: its shape, RATE on E2, DEPTH on E3
--   SWING    the held SWING button: AMOUNT on E2, GRID on E3
--   TAPE     SHIFT + COLOUR held: PITCH on E2, LENGTH on E3
--   REC      on MAIN while a sample take is armed (lib/sampler): START on
--            E1, LEVEL on E2, SOURCE on E3, K2 cancel, K3 now / stop
--
-- K2+K3 together puts back whatever the open screen's E2 and E3 turn.

local S = include("drumdrum/lib/spec")

local U = {}
local St, G, L, N, F, C, R

function U.init(state, grid_ui, lfo, snap, perform, clips, sampler)
  St, G, L, N, F, C, R = state, grid_ui, lfo, snap, perform, clips, sampler
end

local SHORT = { "BD1", "BD2", "CLP", "SNR", "PR1", "PR2", "HAT", "CYM" }
U.SHORT = SHORT

-- s trimmed (with a ~) until it is no wider than w pixels in the current
-- font. Measured, not counted: 04B_03 is proportional, so "m" and "i" differ.
local function fit(s, w)
  if screen.text_extents(s) <= w then return s end
  while #s > 1 and screen.text_extents(s .. "~") > w do s = s:sub(1, -2) end
  return s .. "~"
end

local function header(left, right)
  screen.font_face(1)
  screen.font_size(8)
  if St.old_engine then right = "RESTART NORNS" end
  local has_right = right and right ~= ""
  -- the right side is the live readout, so the title gives way to it
  if has_right then left = fit(left, 124 - screen.text_extents(right)) end
  screen.level(15)
  screen.move(0, 7)
  screen.text(left)
  if has_right then
    screen.level(5)
    screen.move(128, 7)
    screen.text_right(right)
  end
end

local function clip_text(s, n)
  if #s <= n then return s end
  return s:sub(1, n - 1) .. "~"
end

local function bar(x, y, w, h, r, mark, ghost)
  screen.level(2)
  screen.rect(x + 0.5, y + 0.5, w - 1, h - 1)
  screen.stroke()
  local fw = math.floor(util.clamp(r, 0, 1) * (w - 2) + 0.5)
  if fw > 0 then
    screen.level(8)
    screen.rect(x + 1, y + 1, fw, h - 2)
    screen.fill()
  end
  -- ghost: where the track's own value is, under a step's lock
  if ghost then
    local gx = x + 1 + math.floor(util.clamp(ghost, 0, 1) * (w - 3) + 0.5)
    screen.level(4)
    screen.move(gx + 0.5, y - 2)
    screen.line(gx + 0.5, y)
    screen.stroke()
  end
  -- mark: where an LFO has it right now
  if mark then
    local mx = x + 1 + math.floor(util.clamp(mark, 0, 1) * (w - 3) + 0.5)
    screen.level(15)
    screen.move(mx + 0.5, y - 1)
    screen.line(mx + 0.5, y + h + 1)
    screen.stroke()
  end
end

-- ---------------------------------------------------------------- MAIN page

function U.main()
  local t = St.sel
  local tr = St.track()
  local v = S.voice(t)
  local right = string.format("%s %d", St.playing and ">" or "||",
    math.floor(params:get("clock_tempo") + 0.5))
  if St.fill then right = "FILL  " .. right end
  if tr.mute then right = "MUTED  " .. right end
  header("drumdrum " .. S.KITS[S.kit_of(t)]:lower(), right)

  screen.font_size(16)
  screen.level(tr.mute and 4 or 15)
  screen.move(0, 27)
  screen.text(v.name)
  screen.font_size(8)
  screen.level(5)
  -- the left column ends where the step miniature and the E2/E3 pair start
  screen.move(0, 36)
  screen.text(fit(v.desc, 61))
  screen.level(3)
  screen.move(0, 45)
  screen.text(fit(St.sample_name(t), 61))

  -- the 64 steps in miniature
  for i = 1, S.NSTEPS do
    local cx = 64 + (((i - 1) % 16) * 4)
    local cy = 13 + (math.floor((i - 1) / 16) * 4)
    local st = tr.steps[i]
    local lv = 0
    if i <= tr.len then
      lv = ((i - 1) % 16 == 0) and 3 or 1
      if st and st.on then lv = 9 end
      if St.playing and tr.ph == i then lv = 15 end
    end
    if lv > 0 then
      screen.level(lv)
      screen.rect(cx, cy, 3, 3)
      screen.fill()
    end
  end
  -- the pair E2 and E3 turn, and which of the pairs E1 is on
  local pair = S.MAIN_PAIRS[St.main_pair]
  local vals
  if St.main_pair == 1 then vals = { tostring(tr.len), S.SPEEDS[tr.speed] }
  else vals = { S.DIRS[tr.dir] or "FWD", tr.dilla .. "%" } end
  for k = 1, 2 do
    local y = 36 + ((k - 1) * 9)
    screen.level(4)
    screen.move(64, y)
    screen.text(pair[k])
    screen.level(15)
    screen.move(128, y)
    screen.text_right(vals[k])
  end
  for k = 1, #S.MAIN_PAIRS do
    screen.level((k == St.main_pair) and 15 or 3)
    screen.rect(64 + ((k - 1) * 4), 30, 2, 2)
    screen.fill()
  end

  -- the eight tracks, flashing as they fire
  for k = 1, S.NTRACKS do
    local x = (k - 1) * 16
    local f = St.tracks[k].flash
    if f > 0.05 then
      screen.level(math.floor(f * 10 + 0.5))
      screen.rect(x + 1, 50, 14, 13)
      screen.fill()
    end
    if k == t then
      screen.level(15)
      screen.rect(x + 1.5, 50.5, 13, 12)
      screen.stroke()
    end
    screen.level(St.tracks[k].mute and 2 or ((f > 0.5) and 0 or 10))
    screen.move(x + 8, 59)
    screen.text_center(SHORT[k])
  end
end

-- ----------------------------------------------------------------- MIX page

function U.mix()
  local t = St.sel
  header("MIX  " .. S.VOICES[t].name, string.format("P %+.2f  T %+.2f",
    params:get(St.pid(t, "pan")), params:get(St.pid(t, "tilt"))))
  for k = 1, S.NTRACKS do
    local x0 = (k - 1) * 16
    local sel = (k == t)
    local mute = St.tracks[k].mute
    screen.level(sel and 15 or (mute and 2 or 5))
    screen.move(x0 + 8, 16)
    screen.text_center(SHORT[k])

    -- fader + meter
    local fx, fy, fh = x0 + 5, 19, 28
    local lvl = params:get(St.pid(k, "level"))
    screen.level(sel and 3 or 1)
    screen.rect(fx + 0.5, fy + 0.5, 6, fh)
    screen.stroke()
    local m = St.meter[k] or 0
    local db = (m > 0.00001) and (20 * math.log(m, 10)) or -96
    local mh = math.floor(util.clamp((db + 42) / 42, 0, 1) * (fh - 1) + 0.5)
    if mh > 0 then
      screen.level(mute and 3 or 12)
      screen.rect(fx + 2, fy + fh - mh, 3, mh)
      screen.fill()
    end
    local ly = fy + fh - math.floor(lvl * (fh - 1) + 0.5)
    screen.level(sel and 15 or 7)
    screen.move(fx - 1, ly + 0.5)
    screen.line(fx + 8, ly + 0.5)
    screen.stroke()

    -- pan: a dot either side of centre
    local pan = params:get(St.pid(k, "pan"))
    screen.level(2)
    screen.move(x0 + 2, 53.5)
    screen.line(x0 + 14, 53.5)
    screen.stroke()
    screen.level(sel and 15 or 8)
    screen.rect(x0 + 7 + math.floor(pan * 5 + 0.5), 52, 2, 3)
    screen.fill()

    -- tilt: the slope of the spectrum
    local tilt = params:get(St.pid(k, "tilt"))
    screen.level(sel and 12 or 5)
    screen.move(x0 + 3, 60.5 + (tilt * 3))
    screen.line(x0 + 13, 60.5 - (tilt * 3))
    screen.stroke()
  end
end

-- -------------------------------------------------------------- COLOUR page
--
-- Pappus' wave field: one surface the width of the screen, a stack of lines
-- each the same travelling wave sampled a little further along. Every control
-- owns one axis of the surface:
--
--   DRIVE   sharpens the crests       CRUNCH  terraces the field
--   LOSS    breaks lines into dashes  WOW     shears the sheet
--   NOISE   a hit throws a ripple across it, N.DEC is how far it travels
--   N.TONE  the spatial frequency     COMP    squeezes the stack together
--   BOOM    swells the whole surface  DUCK    a source hit pulls it flat
--   TILT    leans the light: dark and heavy one way, bright the other
--
-- and the output level sets the amplitude, so the surface breathes with the
-- drums. A hit throws its ripple from where that track sits on the grid.

local vis = { env = 0, drive = 0, crunch = 0, noise = 0, loss = 0, rot = 0,
              comp = 0, ndec = 0, tone = 0, wow = 0, wob = 0, tilt = 0,
              boom = 0, duck = 0, chorus = 0, cph = 0 }
local kpulse = {}
local KPULSE_MAX = 6
local KLINES = 6
local kY, kLV = {}, {}

local function ease(a, b, k) return a + ((b - a) * k) end

local function craw(arg) return params:get_raw("col_" .. arg) end

function U.ripple(t, vel)
  if St.page ~= "colour" then return end
  -- the duck's source pulls the surface flat for a moment
  local src = params:get("col_scsrc") - 1
  if t == src then
    vis.duck = math.max(vis.duck, params:get("col_scamt") * (vel or 1))
  end
  if vis.noise < 0.02 then return end
  if #kpulse >= KPULSE_MAX then table.remove(kpulse, 1) end
  local x0 = ((t - 1) * 16) + 8
  kpulse[#kpulse + 1] = { x = x0, dir = (t % 2 == 0) and -1 or 1, age = 0,
                          amp = vis.noise * (0.4 + (vel or 1) * 0.6) }
end

function U.vis_update(dt)
  local k = math.min(dt * 6, 1)
  vis.env   = ease(vis.env, math.min(St.outamp * 2.2, 1), math.min(dt * 9, 1))
  vis.drive = ease(vis.drive, craw("drive"), k)
  vis.crunch = ease(vis.crunch, craw("crunch"), k)
  vis.boom  = ease(vis.boom, craw("boom"), k)
  vis.noise = ease(vis.noise, craw("noise"), k)
  vis.loss  = ease(vis.loss, craw("loss"), k)
  vis.comp  = ease(vis.comp, craw("comp"), k)
  vis.duck  = math.max(vis.duck - (dt * 4), 0)
  vis.ndec  = ease(vis.ndec, craw("noisedecay"), k)
  vis.tone  = ease(vis.tone, craw("noisetone"), k)
  vis.wow   = ease(vis.wow, craw("wow"), k)
  vis.chorus = ease(vis.chorus, craw("chorus"), k)
  vis.cph   = (vis.cph + (dt * params:get("col_chrate") * math.pi * 2)) % (math.pi * 2)
  vis.tilt  = ease(vis.tilt, (craw("ctilt") * 2) - 1, k)
  vis.rot   = (vis.rot + (dt * (0.10 + (vis.env * 0.35)))) % (math.pi * 2)
  vis.wob   = (vis.wob + (dt * (0.13 + (vis.wow * 0.9)))) % (math.pi * 2)
  local life = 0.55 + (vis.ndec * 1.5)
  for i = #kpulse, 1, -1 do
    local p = kpulse[i]
    p.age = p.age + (dt / life)
    if p.age >= 1 then table.remove(kpulse, i) end
  end
end

local function draw_field(top, h)
  local bot = top + h
  local cy = top + (h / 2)
  local byp = (params:get("col_bypass") == 2)
  local STEPS = 24
  local dx = 128 / STEPS

  local amp = (h * 0.5) * (0.20 + (vis.env * 0.62)) * (1 + (vis.boom * 0.3))
    * (1 - (vis.duck * 0.6))
  if byp then amp = amp * 0.1 end
  local spread = (h - 1) * (1 - ((amp / (h * 0.5)) * 0.52))
  local kx = (math.pi * 2) * (0.55 + (vis.tone * 1.5)) / 128
  local pa = vis.rot * 2.3
  local pb = vis.rot * -1.41
  local squash = 1 - (vis.comp * 0.28)
  local terr = (vis.crunch > 0.02) and (0.5 + (vis.crunch * 4.5)) or 0
  local sharp = 1 - (vis.drive * 0.68)
  local pspan = 34 + (vis.ndec * 110)
  local pwide = 9 + (vis.ndec * 13)
  local dash = math.floor(vis.rot * 2.4)
  local off = util.clamp(
    0.62 * (spread * squash) / (math.max(amp, 1) * (KLINES - 1)) * 4, 0.5, 2.6)

  for li = 1, KLINES do
    kY[li] = kY[li] or {}
    kLV[li] = kLV[li] or {}
    local tt = (li - 1) / (KLINES - 1)
    local base = cy + ((tt - 0.5) * spread * squash)
    local lamp = amp * (0.76 + (0.32 * math.sin(tt * math.pi)))
    local sa = tt * off
    local sb = tt * -off * 0.6
    local ww = math.sin(vis.wob + (tt * 2.7)) * vis.wow * off * 0.7
    for s = 0, STEPS do
      local x = s * dx
      local u = (math.sin((x * kx) + pa + sa + ww) * 0.6)
        + (math.sin((x * kx * 0.63) + pb + sb - ww) * 0.4)
      if sharp < 0.995 then
        u = ((u < 0) and -1 or 1) * (math.abs(u) ^ sharp)
      end
      local gg = 0
      for _, p in ipairs(kpulse) do
        local d = (x - (p.x + (p.dir * p.age * pspan))) / pwide
        if d > -2.6 and d < 2.6 then
          gg = gg + (math.exp(-(d * d)) * p.amp * (1 - p.age))
        end
      end
      kY[li][s] = base + (u * lamp * (1 - (gg * 0.5)))
        + (gg * (tt - 0.5) * spread * 0.32)
      local lv = 6 + (u * 6.4) + (vis.env * 4) + (gg * 7)
        - (math.abs(tt - 0.5) * 2.2) + (vis.tilt * 2.5)
      if byp then lv = 4 end
      kLV[li][s] = util.clamp(math.floor((lv / 3) + 0.5) * 3, 1, 15)
    end
  end

  local gap = math.max(2.6, (spread * squash) / (KLINES - 1) * 0.4) * (1 - vis.crunch)
  if gap > 0.2 then
    for s = 0, STEPS do
      for li = 2, KLINES do
        local mn = kY[li - 1][s] + gap
        if kY[li][s] < mn then kY[li][s] = mn end
      end
      local over = kY[KLINES][s] - bot
      if over > 0 then
        for li = KLINES, 1, -1 do
          kY[li][s] = kY[li][s] - over
          if li > 1 and (kY[li][s] - kY[li - 1][s]) >= gap then break end
        end
      end
    end
  end

  -- CHORUS: each line doubled by a faint twin that drifts up and down
  -- with the sweep, further the deeper it goes, under the lines themselves
  if vis.chorus > 0.02 and not byp then
    local cd = vis.chorus * (1 + (params:get_raw("col_chdepth") * 3))
    screen.level(math.max(1, math.floor(1 + (vis.chorus * 3) + 0.5)))
    for li = 1, KLINES do
      local tt = (li - 1) / (KLINES - 1)
      local oy = math.sin(vis.cph + (tt * 2.1)) * cd
      local ox = math.cos(vis.cph + (tt * 1.3)) * cd * 0.6
      for s = 0, STEPS do
        local y = util.clamp(kY[li][s] + oy, top, bot)
        if s == 0 then screen.move(ox, y) else screen.line((s * dx) + ox, y) end
      end
      screen.stroke()
    end
  end

  for li = 1, KLINES do
    local px, py, plv
    local open = false
    for s = 0, STEPS do
      local x = s * dx
      local y = util.clamp(kY[li][s], top, bot)
      if terr > 0 then y = util.clamp(math.floor(y / terr + 0.5) * terr, top, bot) end
      local lv = kLV[li][s]
      local keep = true
      if vis.loss > 0.02 then
        keep = (((s * 29) + (li * 53) + dash) % 100) >= (vis.loss * 70)
      end
      if s > 0 then
        if keep and lv > 1 then
          if open and lv == plv then
            screen.line(x, y)
          else
            if open then screen.stroke() end
            screen.level(lv)
            screen.move(px, py)
            screen.line(x, y)
            open, plv = true, lv
          end
        elseif open then
          screen.stroke()
          open = false
        end
      end
      px, py = x, y
    end
    if open then screen.stroke() end
  end
end

function U.colour()
  -- the open bank's cells, E1 walks them and on into the next bank
  screen.font_face(1)
  screen.font_size(8)
  local bank = S.COLOUR[St.col_sel].bank
  for _, i in ipairs(S.BANK_CELLS[bank]) do
    local cell = S.COLOUR[i]
    local x = (cell.row - 1) * 21 + 1
    if i == St.col_sel then
      screen.level(15)
      screen.rect(x - 1, 0, 20, 9)
      screen.fill()
      screen.level(0)
    else
      screen.level(4)
    end
    screen.move(x + 9, 7)
    screen.text_center(cell.short)
  end
  -- the bank's name, only when it fits beside the last cell
  local cells_end = (#S.BANK_CELLS[bank] * 21) + 2
  local bname = S.COLOUR_BANKS[bank]
  if 128 - screen.text_extents(bname) >= cells_end then
    screen.level(3)
    screen.move(128, 7)
    screen.text_right(bname)
  end

  screen.aa(1)
  draw_field(12, 34)
  screen.aa(0)

  local cell = S.COLOUR[St.col_sel]
  local byp = (params:get("col_bypass") == 2)
  for k, side in ipairs({ "a", "b" }) do
    local p = cell[side]
    local x = (k == 1) and 0 or 66
    local val = S.fmt(p, params:get("col_" .. p.arg))
    screen.level(5)
    screen.move(x, 55)
    screen.text(fit(p.name, 59 - screen.text_extents(val)))
    screen.level(15)
    screen.move(x + 62, 55)
    screen.text_right(val)
    bar(x, 59, 62, 4, params:get_raw("col_" .. p.arg))
  end
  if byp then
    screen.level(15)
    screen.rect(44, 22, 40, 11)
    screen.fill()
    screen.level(0)
    screen.move(64, 30)
    screen.text_center("BYPASS")
  end
end

-- --------------------------------------------------------- CONTROL overlay

-- the value a control shows: the first held step's, or the track's
local function shown(t, btn, side)
  local tr = St.track(t)
  local p = S.pair(t, btn)[side]
  local held = G.held_steps()
  local kind = S.BTN[btn].kind

  if S.STEP_KIND[kind] then
    local st = (#held > 0) and tr.steps[held[1]] or tr.tpl
    local v = (st and st[p.key]) or p.def
    return S.fmt(p, v), (v - p.lo) / (p.hi - p.lo), nil, nil
  end

  if p.special == "sample" then
    local n = #tr.files
    return St.sample_name(t), (n > 1) and ((tr.fidx - 1) / (n - 1)) or 0, nil, nil
  end

  local key = btn .. side
  local id = St.pid(t, key)
  local base = params:get_raw(id)
  local lock
  if #held > 0 then
    local st = tr.steps[held[1]]
    lock = st and st.locks and st.locks[key]
  end
  local r = lock or base
  local val = params:lookup_param(id).controlspec:map(r)
  local mark
  if L.targets(t, key) then mark = util.clamp(r + L.mod(t, key), 0, 1) end
  return S.fmt(p, val), r, mark, lock and base or nil
end

function U.ctrl(btn)
  local b = S.BTN[btn]
  if b.kind == "lfo" then return U.lfo(b.lfo) end
  local t = St.sel
  local v = S.VOICES[t]
  local held = G.held_steps()
  local right = ""
  if #held > 0 then
    right = (S.STEP_KIND[b.kind] and "STEP " or "LOCK ") .. #held
  elseif S.STEP_KIND[b.kind] then
    right = "NEW STEPS"
  elseif G.latched == btn and G.stack[#G.stack] ~= btn then
    right = "LATCHED"
  end
  header(v.name .. "  " .. b.label, right)
  screen.level(2)
  screen.move(0, 10.5)
  screen.line(128, 10.5)
  screen.stroke()

  local pair = S.pair(t, btn)
  for k, side in ipairs({ "a", "b" }) do
    local p = pair[side]
    local x = (k == 1) and 0 or 66
    local txt, r, mark, ghost = shown(t, btn, side)
    screen.level(6)
    screen.move(x, 21)
    screen.text(p.name)
    if L.targets(t, btn .. side) then
      screen.level(15)
      screen.move(x + 62, 21)
      screen.text_right("~")
    end
    screen.level(15)
    if #txt > 8 then
      screen.font_size(8)
      screen.move(x, 37)
      screen.text(clip_text(txt, 13))
    else
      screen.font_size(12)
      screen.move(x, 38)
      screen.text(txt)
      screen.font_size(8)
    end
    bar(x, 44, 62, 6, r, mark, ghost)
    screen.level(2)
    screen.move(x, 61)
    screen.text((k == 1) and "E2" or "E3")
  end
  if #held > 0 and S.SOUND_KIND[b.kind] then
    screen.level(3)
    screen.move(128, 61)
    screen.text_right("K2 clear")
  elseif btn == "S1" and G.stack[#G.stack] == "S1" then
    screen.level(3)
    screen.move(128, 61)
    screen.text_right("+step REC")
  end
end

-- -------------------------------------------------------------- LFO overlay

function U.lfo(i)
  local t = St.sel
  local o = L.st[t][i]
  local shape = L.shape(t, i)
  header(S.VOICES[t].name .. "  LFO " .. i, S.LFO_SHAPES[shape])

  -- the shape, one cycle, with where it is now
  local cy, amp = 26, 9
  screen.level(2)
  screen.move(0, cy + 0.5)
  screen.line(128, cy + 0.5)
  screen.stroke()
  screen.level(8)
  local fake = { sh = 0, d0 = -0.6, d1 = 0.7 }
  for x = 0, 127 do
    local ph = x / 127
    local w
    if shape == 5 then
      local seg = math.floor(ph * 6)
      w = math.sin((seg + 1) * 12.9898) * 0.9
    else
      w = L.wave(shape, ph, fake)
    end
    local y = cy - (w * amp)
    if x == 0 then screen.move(x, y) else screen.line(x, y) end
  end
  screen.stroke()
  local px = o.phase * 127
  screen.level(15)
  screen.circle(px, cy - (o.val * amp), 2)
  screen.fill()

  local tn = L.target_name(t, i)
  screen.level(tn and 15 or 4)
  screen.move(64, 45)
  screen.text_center(tn and ("> " .. tn) or "hold + tap a control")

  screen.level(6)
  screen.move(0, 55)
  screen.text("RATE")
  screen.move(66, 55)
  screen.text("DEPTH")
  screen.level(15)
  local rate = L.rate(t, i)
  screen.move(62, 55)
  screen.text_right(rate < 1 and string.format("%.2f Hz", rate) or string.format("%.1f Hz", rate))
  screen.move(128, 55)
  screen.text_right(string.format("%+.2f", L.depth(t, i)))
  screen.level(2)
  screen.move(0, 63)
  screen.text("E2")
  screen.move(66, 63)
  screen.text("E3")
  screen.move(128, 63)
  screen.text_right("K2/3 shape")
end

-- ------------------------------------------------------------ SWING overlay

function U.swing()
  local sw = params:get("swing")
  local gi = params:get("swing_grid")
  -- RAIN lives here now the launcher has no screen of its own
  header("SWING", string.format("E1 RAIN %d%%", math.floor(params:get("rain") * 100 + 0.5)))
  screen.font_size(16)
  screen.level(15)
  screen.move(0, 30)
  screen.text(string.format("%d%%", math.floor(sw + 0.5)))
  screen.move(128, 30)
  screen.text_right(S.SWING_GRID[gi])
  screen.font_size(8)

  -- eight pulses straight (dim ticks) and where swing puts them (bright)
  local u = S.SWING_UNIT[gi]
  local span = 8 * 0.25
  local s = sw / 100
  for k = 0, 7 do
    local beat = k * 0.25
    local p = beat % (2 * u)
    local w = (p < u) and (p * 2 * s) or ((2 * u * s) + ((p - u) * (2 - (2 * s))))
    local sx = 4 + ((beat / span) * 120)
    local wx = 4 + (((beat - p + w) / span) * 120)
    screen.level(2)
    screen.move(sx + 0.5, 38)
    screen.line(sx + 0.5, 44)
    screen.stroke()
    screen.level(15)
    screen.rect(wx, 46, 2, 6)
    screen.fill()
  end
  screen.level(2)
  screen.move(0, 63)
  screen.text("E2 amount")
  screen.move(128, 63)
  screen.text_right("E3 grid")
end

-- --------------------------------------------------------------- SNAP page
--
-- The grid's 64 cells, drawn the same way round: a square per slot.

function U.snap()
  local right
  local deleting = N.act and N.act.kind == "delete"
  if deleting then right = "DELETING " .. N.act.slot
  elseif N.act and N.has(N.act.slot) then right = "OVERWRITING " .. N.act.slot
  elseif N.act then right = "SAVING " .. N.act.slot
  elseif N.pending then right = "ON THE BEAT > " .. N.pending.slot
  elseif N.last > 0 then right = "LAST " .. N.last
  else right = "SHIFT+HOLD SAVES" end
  if G.kit then right = S.KITS[G.kit.k] .. ": PICK TRACKS" end
  header("SNAP", right)
  local blink = (math.floor(util.time() * 8) % 2) == 0
  for i = 1, N.COUNT do
    local x = 1 + (((i - 1) % 16) * 8)
    local y = 13 + (math.floor((i - 1) / 16) * 12)
    local lv = N.has(i) and 6 or 1
    if i == N.last then lv = 15 end
    if N.pending and N.pending.slot == i then lv = blink and 15 or 3 end
    if N.has(i) or lv > 1 then
      screen.level(lv)
      screen.rect(x, y, 6, 9)
      screen.fill()
    else
      screen.level(2)
      screen.rect(x + 0.5, y + 0.5, 5, 8)
      screen.stroke()
    end
    if deleting and N.act.slot == i then
      -- the bar runs down as the delete hold goes on
      local h = math.floor((1 - N.progress()) * 9 + 0.5)
      screen.level(0)
      screen.rect(x, y, 6, 9)
      screen.fill()
      screen.level(2)
      screen.rect(x + 0.5, y + 0.5, 5, 8)
      screen.stroke()
      screen.level(15)
      screen.rect(x, y + 9 - h, 6, h)
      screen.fill()
    elseif N.act and N.act.slot == i then
      local h = math.floor(N.progress() * 9 + 0.5)
      if N.has(i) then
        -- an overwrite: the old contents blanked, a bright outline, and the
        -- bar fills in a softer tone than a fresh save so it reads apart
        screen.level(0)
        screen.rect(x, y, 6, 9)
        screen.fill()
        screen.level(15)
        screen.rect(x + 0.5, y + 0.5, 5, 8)
        screen.stroke()
        screen.level(8)
      else
        screen.level(15)
      end
      screen.rect(x, y + 9 - h, 6, h)
      screen.fill()
    end
  end
  -- each track's kit along the bottom, tracks 1-8: WA, WO or FM
  for t = 1, S.NTRACKS do
    local k = S.kit_of(t)
    screen.level((G.kit and G.kit.k == k) and 15 or ((t == St.sel) and 10 or 4))
    screen.move(4 + ((t - 1) * 16), 64)
    screen.text_center(S.KITS[k]:sub(1, 2))
  end
end

-- ------------------------------------------------------------ PERFORM page
--
-- The eight strips the way the grid has them, two to a row. A strip that is
-- sounding is lit with the pad it is on: solid while held, dim when only
-- latched.

function U.perform()
  local n = 0
  for f = 1, #F.STRIPS do if F.active[f] then n = n + 1 end end
  header("PERFORM", (n > 0) and (n .. " ON") or "SHIFT+PAD LATCHES")
  for f, s in ipairs(F.STRIPS) do
    local x = ((f - 1) % 2) * 65
    local y = 11 + (math.floor((f - 1) / 2) * 13)
    local lab = F.label(f)
    local held = #F.held[f] > 0
    if lab then
      screen.level(held and 15 or 5)
      screen.rect(x, y, 63, 11)
      screen.fill()
      screen.level(held and 0 or 15)
    else
      screen.level(2)
      screen.rect(x + 0.5, y + 0.5, 62, 10)
      screen.stroke()
      screen.level(6)
    end
    screen.move(x + 3, y + 8)
    screen.text(lab and fit(s.name, 54 - screen.text_extents(lab)) or s.name)
    if lab then
      screen.move(x + 60, y + 8)
      screen.text_right(lab)
    end
  end
end

-- --------------------------------------------------------------- TAPE overlay
--
-- Two reels turning at the speed the loop plays at.

local reel = { ang = 0, t = nil }

function U.tape()
  local pitch = params:get("tape_pitch")
  local rate = 2 ^ (pitch / 12)
  local now = util.time()
  if reel.t then reel.ang = reel.ang + ((now - reel.t) * rate * 4) end
  reel.t = now
  header("TAPE", "held")
  for k, cx in ipairs({ 36, 92 }) do
    local cy = 27
    screen.level(4)
    screen.circle(cx, cy, 11)
    screen.stroke()
    screen.level(12)
    for sp = 0, 2 do
      local a = reel.ang + (sp * 2.0944) + (k * 0.6)
      screen.move(cx, cy)
      screen.line(cx + (math.cos(a) * 9), cy + (math.sin(a) * 9))
      screen.stroke()
    end
  end
  screen.level(6)
  screen.move(36, 38.5)
  screen.line(92, 38.5)
  screen.stroke()

  screen.level(6)
  screen.move(0, 52)
  screen.text("PITCH")
  screen.move(66, 52)
  screen.text("LENGTH")
  screen.level(15)
  screen.move(62, 52)
  screen.text_right(string.format("%+d st", math.floor(pitch + 0.5)))
  screen.move(128, 52)
  screen.text_right(F.TAPE_LENS[params:get("tape_len")])
  screen.level(2)
  screen.move(0, 62)
  screen.text("E2")
  screen.move(66, 62)
  screen.text("E3")
  screen.move(128, 62)
  screen.text_right("K2+3 reset")
end

-- --------------------------------------------------------------- REC overlay
--
-- The source's level across the top with the THRESH line through it (dB,
-- -60 to 0), how far through the take below, then START LEVEL SOURCE.

local function db_x(db) return math.floor(util.clamp((db + 60) / 60, 0, 1) * 126 + 0.5) end

function U.rec()
  local t = R.t
  header(string.format("REC  %s  %d st", S.VOICES[t].name, R.steps), R.status())
  local blink = (math.floor(util.time() * 3) % 2) == 0

  -- meter, and the threshold
  local lvl = R.level
  local db = (lvl > 0.000001) and (20 * math.log(lvl, 10)) or -96
  local thr = params:get("rec_thresh")
  screen.level(2)
  screen.rect(0.5, 12.5, 127, 7)
  screen.stroke()
  local w = db_x(db)
  if w > 0 then
    screen.level((db >= thr) and 15 or 7)
    screen.rect(1, 13, w, 6)
    screen.fill()
  end
  if R.MODES[params:get("rec_mode")] == "THRESH" then
    local tx = 1 + db_x(thr)
    screen.level(15)
    screen.move(tx + 0.5, 10)
    screen.line(tx + 0.5, 22)
    screen.stroke()
  end

  -- the take
  screen.level(2)
  screen.rect(0.5, 25.5, 127, 3)
  screen.stroke()
  if R.eng >= 3 then
    local pw = math.floor(((R.eng == 4) and 1 or R.prog) * 126 + 0.5)
    if pw > 0 then
      screen.level(12)
      screen.rect(1, 26, pw, 2)
      screen.fill()
    end
  elseif blink then
    screen.level(6)
    screen.rect(1, 26, 2, 2)
    screen.fill()
  end

  local cols = {
    { "START", R.MODES[params:get("rec_mode")], "E1" },
    { "LEVEL", string.format("%d dB", math.floor(thr + 0.5)), "E2" },
    { "SOURCE", R.SRCS[params:get("rec_src")], "E3" },
  }
  for k, c in ipairs(cols) do
    local x = (k - 1) * 44
    screen.level(6)
    screen.move(x, 38)
    screen.text(c[1])
    screen.level(15)
    screen.move(x, 48)
    screen.text(c[2])
    screen.level(2)
    screen.move(x, 56)
    screen.text(c[3])
  end
  screen.level(3)
  screen.move(0, 63)
  screen.text("K2 cancel")
  screen.move(128, 63)
  screen.text_right((R.eng == 3) and "K3 stop" or "K3 now")
end

-- ------------------------------------------------------------------- redraw

function U.redraw()
  screen.clear()
  screen.aa(0)
  screen.font_face(1)
  screen.font_size(8)
  screen.line_width(1)
  local kind, btn = G.overlay()
  if kind == "tape" then U.tape()
  elseif kind == "ctrl" then U.ctrl(btn)
  elseif kind == "rec" then U.rec()
  elseif kind == "swing" then U.swing()
  elseif St.page == "mix" then U.mix()
  elseif St.page == "colour" then U.colour()
  elseif St.page == "snap" then U.snap()
  elseif St.page == "perform" then U.perform()
  else U.main() end
  screen.update()
end

return U
