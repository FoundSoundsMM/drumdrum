# drumdrum

A warm, dusty drum machine for [norns](https://monome.org/norns) and a grid 128.

Eight voices. Each one is a synthesised drum with a sample slot underneath it.
At rest it sounds organic and mellow: round lows, soft tops, analogue drift.
The COLOUR controls, per track and on the master, take it into dirt, grit and
filth.

> **Install the folder as `drumdrum`** (lowercase) in `~/dust/code/`. The
> `include()` paths depend on it. Restart norns after the first install so the
> engine class compiles.

## Voices

| # | | |
|---|---|---|
| 1 | **BD1** | A smooth 808: a sine with a pitch drop. `BODY` pushes it into a soft saturator with some second harmonic, `PUNCH` is the beater. |
| 2 | **BD2** | Modelled on the Metasonix D-1000: an oscillator (sine > tri > pulse) into a tube stage. `TUBE` is the gain, `BIAS` moves the operating point so the two halves clip differently, and loud peaks make the stage sag. |
| 3 | **CLP** | A run of noise grains `SPREAD` apart, then a tail. `SIZZLE` scatters fine crackling grains over the tail. |
| 4 | **SNR** | Two shell tones a little over a fifth apart, with `RING` letting the upper one sustain, plus band-passed wires on their own decay. |
| 5 | **PRC1** | Modal: six resonators. `MATERL` morphs skin > wood > bar > bell, `STRIKE` goes from a soft mallet to a hard gritty click, `POS` is where the body is struck. |
| 6 | **PRC2** | The same modal core with a slack-skin pitch `BEND` and a detuned twin for each mode (`SPREAD`), so they beat. Defaults to a tom/tabla. |
| 7 | **HAT** | `FOLD` sweeps clean (filtered noise) > metallic (six squares between harmonic and the 808's ratios) > dirty (wavefolded and decimated). |
| 8 | **CYM** | Eight phase-modulated partials plus air. `DUST` ages it with crackle, lost bits, a lower sample rate and a duller top. `SWELL` slows the attack into a reverse bloom. |

Each voice also has a **sample layer**. Choose any audio file for a track in
`PARAMS > [track] > sample`. That points the track at the file's folder, and
S1's E2 then steps through every file in it. The sample layer starts at level
0, so the synth is the voice and the sample is something you bring in. By
default each track is pointed at the matching file in norns' own
`audio/common/808/`, if it is there.

## Grid

```
      1   2   3   4   5   6   7   8   9  10  11  12  13  14  15  16
  1   ─────────────────────────── steps  1-16 ───────────────────────────
  2   ─────────────────────────── steps 17-32 ───────────────────────────
  3   ─────────────────────────── steps 33-48 ───────────────────────────
  4   ─────────────────────────── steps 49-64 ───────────────────────────
  5   (divider)
  6   T1  T2  .   S1  S2  .   N1  .  TC1 TC2  .   P1  .   L1  .   C1
  7   T3  T4  .   S3  S4  .   N2  .  TC3 TC4  .   P2  .   L2  .   C2
  8   PLAY STOP SWNG .  [1   2   3   4   5   6   7   8]  .  SHFT MIX COL
```

**Bottom row:** PLAY, STOP, SWING (hold), the eight track buttons, SHIFT, MIX
and COLOUR. STOP stops where you are; STOP again while stopped goes back to the
top.

**Steps (rows 1-4)** show the selected track's 64 steps. The first step of each
bar is dimly lit; steps past the track's length are dark.

- Press an empty step to place one.
- Press a placed step and let go quickly to remove it.
- Hold one or more steps, then open a control, to edit those steps (see below).
- **SHIFT + step** sets the track's length to that step.

**Track controls (rows 6-7)** are momentary. Hold one and the screen shows its
two parameters, E2 and E3. Let go and the screen closes.

- **SHIFT + control** latches it open. Do the same again (or latch another)
  to close it.
- **SHIFT + track** mutes or unmutes it.
- **SHIFT + PLAY** toggles FILL, for the `FILL` / `!FILL` conditions.

### What each control does

| | E2 / E3 |
|---|---|
| **T1** | PITCH / DECAY. The same on every voice |
| **T2 T3 T4** | The voice's own shape controls (table below). T4's E3 is always LEVEL, the synth layer against the sample layer |
| **S1** | SAMPLE (step through the folder) / LEVEL |
| **S2** | START / DECAY |
| **S3** | PITCH / TONE (lowpass below centre, highpass above) |
| **S4** | ATTACK / DIR (forward or reverse) |
| **N1** | TYPE (white, pink, dust, tape, metal) / LEVEL: noise layered into the hit |
| **N2** | TONE / GRAIN: GRAIN feeds the same noise into the voice's pitch and filter, so the drum itself gets grainy rather than having noise next to it |
| **TC1** | COND / PROB |
| **TC2** | VEL / NUDGE (±50 % of a step, early or late) |
| **TC3** | PITCH / MIX (synth only ↔ both ↔ sample only) |
| **TC4** | FLAM / DECAY |
| **P1** | PULSES / MODE |
| **P2** | RAMP / BEND |
| **L1 L2** | the track's two LFOs: RATE / DEPTH, K2/K3 change the shape |
| **C1** | DRIVE / WARMTH |
| **C2** | CRUSH / DUST |

| | T2 | T3 | T4 |
|---|---|---|---|
| BD1 | SWEEP / S.TIME | PUNCH / BODY | TONE / LEVEL |
| BD2 | SWEEP / S.TIME | TUBE / BIAS | SHAPE / LEVEL |
| CLP | SPREAD / GRAINS | SIZZLE / WIDTH | SNAP / LEVEL |
| SNR | SNAP / WIRES | W.TONE / RING | CRACK / LEVEL |
| PRC1 | MATERL / DAMP | STRIKE / POS | INHARM / LEVEL |
| PRC2 | MATERL / DAMP | STRIKE / BEND | SPREAD / LEVEL |
| HAT | FOLD / SPREAD | TONE / RES | CURVE / LEVEL |
| CYM | DUST / SPREAD | TONE / SIZZLE | SWELL / LEVEL |

### Holding steps

With steps held, an open control edits *those steps* rather than the track:

- **T / S / N / C** become **parameter locks**. The bar shows the lock, with a
  small tick where the track's own value is. **K2** clears that control's
  locks from the held steps. (S1's sample select is not lockable.)
- **TC / P** edit the steps' trig conditions and pulses.

With no steps held, TC and P edit the track's *template*: the settings the
next step you place starts with. The screen says NEW STEPS.

A step with a lock, a condition, extra pulses, a flam or a nudge is lit
brighter than a plain one.

### Trig conditions (TC1)

`ALWAYS FILL !FILL PRE !PRE NEI !NEI 1ST !1ST 1:2 2:2 1:3 2:3 3:3 1:4 2:4 3:4 4:4`

`A:B` plays on the A-th of every B passes of the pattern. `PRE` follows whether
the last condition on this track passed. `NEI` does the same for the track to
the left. `PROB` is applied after the condition.

### Pulses (P1 / P2)

These come from the Metropolix. A step owns 1-8 pulses of the track's clock,
so a step with four pulses holds the playhead for four steps and the pattern
stretches around it. MODE sets what happens in that time:

| | |
|---|---|
| **WAIT** | one hit, then rest |
| **REPEAT** | a hit on every pulse |
| **SUSTAIN** | one hit with its decay stretched across the pulses |
| **EDGE** | a hit on the first and the last pulse |
| **SCATTER** | the first pulse always, each one after on a coin toss |

**RAMP** shapes velocity across the hits: up is a crescendo, down is a fade.
**BEND** walks their pitch, in semitones.

### LFOs (L1, L2)

Two per track. Hold an LFO button and the screen shows its shape, RATE (E2)
and DEPTH (E3). K2/K3 change the shape: sine, tri, ramp, square, S+H, drift.

**To patch,** keep holding the LFO and tap any T, S, N or C button. The first
tap patches that button's E2 parameter, the second its E3 parameter, the
third unpatches. While you hold an LFO, the button it is patched to lights up.
A patched LFO button pulses with the LFO. On a control screen, a patched
parameter shows `~` and a bright tick where the LFO has it right now.

### Swing

Hold **SWING**: E2 is the amount (50-75 %), E3 the grid (1/16 or 1/8). The
whole pair of units is warped, so every pulse inside moves in proportion
rather than only the off-beat.

## MIX

Press **MIX**. Above each track button is a fader: its column is the track's
level, with the meter running over it. Press a row to set the level.

Pan is to the sides. Tracks 1-4 have a row each on the left (columns 1-4) and
tracks 5-8 on the right (columns 13-16): hard left, left, right, hard right.
Press the lit position again to centre the track.

On norns: **E1** picks the track, **E2** pans it, **E3** tilts it (a
one-knob tilt EQ around 700 Hz). Grid SHIFT + E2 trims the level finely.

## COLOUR

Press **COLOUR**. This is Pappus' colour stage rebuilt for a drum bus:
drive > tilt > crush > loss > envelope-following noise > wow > glue > out. It
is always wet; BYPASS is the way out.

| cell | E2 | E3 |
|---|---|---|
| DRV | DRIVE: warm asymmetric fuzz with makeup, so it changes character rather than level | TILT |
| CRU | CRUSH | MODE: bits, redux, both |
| LOS | LOSS: a codec falling apart, with spectral holes and the top closing off | WOW: tape drift, flutter at the top of the knob |
| NOI | NOISE: rides the drums' own envelope, opening with every hit | TYPE: white, pink, dust, crackle, hiss |
| N.S | N.DEC: how long the noise hangs on | N.TONE |
| OUT | GLUE: bus compression | LEVEL |

On norns, **E1** picks the cell and **E2/E3** turn its two halves. On the
grid, each of rows 1-6 is a cell and the column you press sets its E2 value.
Row 7, column 16 is BYPASS.

The screen is Pappus' wave field. Drive sharpens the crests, crush terraces
them, loss breaks the lines into dashes, wow shears the sheet, and each hit
throws a ripple across it from where its track sits on the grid.

## norns

| | |
|---|---|
| E1 | track (COLOUR page: cell) |
| E2 / E3 | the open screen's pair. Main page: tempo / track speed (1/32 to 1/4) |
| K2 | play / stop |
| K3 | next page: main > mix > colour |
| K1 held | fine adjustment |

When a control screen is open, K2 and K3 only do that screen's work: LFO
shape, or clearing locks. A thumb resting on K2 will not stop the music.

## Files

```
drumdrum.lua            entry point: init, keys, encoders
lib/Engine_DrumDrum.sc  voices, channel strips, master COLOUR
lib/spec.lua            grid layout, voices, every parameter and its range
lib/state.lua           tracks, params, the hit that turns a step into sound
lib/seq.lua             sequencers, conditions, pulses, swing
lib/lfo.lua             LFOs and patching
lib/gridui.lua          the grid's three faces
lib/ui.lua              screen pages and overlays
tools/check-lua.lua     desktop smoke test of the lua side   (lua tools/check-lua.lua)
tools/check-engine.sh   compile the engine and build every SynthDef offline
                        --render  each voice through scsynth NRT, with levels
                        --demo    a few bars through the whole chain
```

Lua does all the range mapping and the engine receives physical units, so a
parameter's range lives in exactly one place (`lib/spec.lua`). Sound is in
norns params, so it saves with a PSET and maps to MIDI. Patterns, lengths,
speeds, mutes, templates and LFO patch points go in a data file beside the
PSET.
