# drumdrum

A warm, dusty drum machine for [norns](https://monome.org/norns) and a grid 128.

Eight voices. Each one is a synthesised drum with a sample slot underneath it.
At rest it sounds organic and mellow: round lows, soft tops, analogue drift.
The COLOUR controls, per track and on the master, take it into dirt, grit and
filth, and a shared delay and spring reverb give it somewhere to live. A
PERFORM page of punch-in effects is there for playing it live.

> **Install the folder as `drumdrum`** (lowercase) in `~/dust/code/`. The
> `include()` paths depend on it. Restart norns after the first install, and
> after any update that changes the engine, so the engine class compiles.
> If the screen says RESTART NORNS, the engine running is older than the
> script (the kits will not switch until you do).

## Voices

| # | | |
|---|---|---|
| 1 | **BD1** | The Tanzbar's zap kick: the pitch falls from `SWEEP` octaves above `PITCH` like a capacitor discharging (fast, then a long settle), `S.TIME` is how long that takes. `BODY` drives the oscillator until its 3rd harmonic comes up, `PUNCH` is the attack click. |
| 2 | **BD2** | The 808 side of the Tanzbar: a bridged-T pinged by the trigger. It has a short `SWEEP`, a long tail and a clean sine that rings slightly sharp while it is loud. `CLICK` is the accent pulse, `DRIVE` leans the output stage into a 2nd harmonic. |
| 3 | **CLP** | A dense run of noise bursts about 4 ms apart, unevenly spaced and fading, then a tail. `SPREAD` sets the spacing, `GRAINS` how many bursts (up to 20). `SIZZLE` scatters fine crackle over the tail. |
| 4 | **SNR** | Two oscillators an octave apart (`RING` is the upper one) with a quick pitch drop, plus bright wires: a high-pass at `W.TONE`, open past 8 kHz, on their own longer decay. |
| 5 | **PRC1** | The Tanzbar's small percussion on one `MODE` knob: CLAVE (one short resonance) > RIM (two clipped resonances) > COWBELL (the 808's two square waves, `DETUNE` apart, a fifth by default, through a band at `TONE`). |
| 6 | **PRC2** | Tom / conga: an oscillator through a stage (`DRIVE` brings in the 2nd and 3rd harmonics), a zap at the strike, then a slow `BEND` down over `B.TIME`. `NOISE` adds a conga slap. |
| 7 | **HAT** | `FOLD` sweeps clean (filtered noise) > metallic (six squares between harmonic and the 808's ratios) > dirty (wavefolded and decimated), in a band centred on `TONE` (around 8 kHz, like the Tanzbar's). |
| 8 | **CYM** | Eight phase-modulated partials plus air. `DUST` ages it with crackle, lost bits, a lower sample rate and a duller top. `SWELL` slows the attack into a reverse bloom. |

Each voice also has a **sample layer**. Choose any audio file for a track in
`PARAMS > [track] > sample`. That points the track at the file's folder, and
S1's E2 then steps through every file in it. The sample layer starts at level
0, so the synth is the voice and the sample is something you bring in. By
default each track is pointed at the matching file in norns' own
`audio/common/808/`, if it is there. You can also record one: see
[Recording a sample](#recording-a-sample).

### Analogue behaviour

No two hits are quite the same, the way it is on a real analogue box:

- **Tolerance.** Each voice is built from parts that are slightly off spec:
  the hat's six oscillators and the cymbal's partials are a little mistuned,
  the cowbell's two squares are not quite a fifth apart, and each voice is a few
  cents off its nominal tuning. These are fixed for the unit, so it has the
  same character every time you boot it.
- **Drift.** Each track wanders a few cents sharp and flat over minutes, like
  a circuit warming up. Hits close together drift together.
- **Hit to hit.** Every hit gets its own small changes to pitch, decay, level
  and brightness. The clap's bursts land unevenly, and the cymbal's
  oscillators run free, so each hit starts at a different phase.
- **VCA.** The voice goes through a VCA that is not quite linear. Velocity is
  applied before it, so hard hits round over and pick up some second
  harmonic, and soft hits come out darker.
- **Hiss.** Each strip adds a little VCA hiss under its fader. It rises with
  the level, pumps with the duck and goes away when the track is muted.

`PARAMS > ANALOG` has two controls: `analog` sets how far the voices stray
(0 sounds like a clean digital box) and `hiss` sets the noise floor.

## Kits

The eight voices come in four voicings, and each track can be on any one:

| | |
|---|---|
| **WARM** | the voices above, voiced after the MFB Tanzbar |
| **WOOD** | wooden, organic percussion: a cajon, a slit log, clappers, a wood block, a balafon, a shaker and a rainstick. Every mode dies sooner the higher it sits, as wood's do, and how hard a voice is struck is how long the hand, mallet or stick stays in contact. Most of them are hollow, and the air inside rings too. No two hits land in quite the same place, so each comes out a little differently |
| **FM** | after the Yamaha YMF262 (OPL3), as ALM's Akemie's Taiko plays it: two- and four-operator FM on the chip's eight waveforms, its MULT ratios and operator feedback. The hat, snare and cymbal use the chip's rhythm mode (two operators' phase bits XORed into metal, flipped by its noise generator). Phases reset on every hit as the chip's do, nothing is band-limited, and it all goes out through the chip's 10-bit floating-point DAC |
| **GLITCH** | soft glitch drums after Matmos and Björk's Vespertine, where the beat is microsound. Every voice starts as noise: clouds of tiny grains, each at its own pitch and loudness, noise breaths ringing resonators, clicks. Several voices STUTTER, retriggering the hit a few times like an edit |

Pick them on the SNAP page (below). Each kit has its own T1-T4 settings per
track, so a kit is how you left it when you come back to it. The rest of
a track (sample, noise, colour, mix, LFOs, steps and locks) carries over.
T1 is PITCH / DECAY and T4's E3 is LEVEL in every kit; a lock or LFO on another T
control stays on the same knob, which turns something else in another
kit. Each track's kit is the `kit` param in its PARAMS group; WOOD's,
FM's and GLITCH's T params have groups of their own.

| WOOD | T2 | T3 | T4 |
|---|---|---|---|
| BD1 | HAND / BOX | FACE / SLAP | WOOD / LEVEL |
| BD2 | MALLET / TONGUE | HOLLOW / BEND | WOOD / LEVEL |
| CLP | SPREAD / GRAINS | CRACK / SIZE | WOOD / LEVEL |
| SNR | SLAP / WIRES | W.TONE / W.DEC | WOOD / LEVEL |
| PRC1 | HOLLOW / STICK | SHAPE / POS | WOOD / LEVEL |
| PRC2 | MALLET / GOURD | BUZZ / TUNE | WOOD / LEVEL |
| HAT | BEANS / SHELL | SPREAD / ATTACK | GRAIN / LEVEL |
| CYM | DENSITY / SPREAD | TUBE / RING | SWELL / LEVEL |

- **WOOD** is the wood itself: GREEN (damp, it only thocks), SEASONED,
  HARD (dry hardwood that rings, like a clave).
- **BD1** a cajon's bass, a palm in the middle of the face. The face's
  modes die fast and the box's air booms out of the port at PITCH. HAND
  runs from a soft palm to firm fingers, BOX from all face to all port,
  FACE is the face's pitch above the port, and SLAP the wires inside
  catching it.
- **BD2** a slit log drum: a tongue of the log struck with a soft mallet.
  TONGUE stretches its overtones, HOLLOW is the log's air under it, BEND
  the mallet pressing it sharp for a moment.
- **CLP** clappers: two boards that never meet flat, so a slap is GRAINS
  knocks SPREAD apart. CRACK is the air squeezed out between them, SIZE
  the boards.
- **SNR** a cajon slap at the top edge, with the snare wires inside
  buzzing against the face for as long as it moves.
- **PRC1** a wood block. SHAPE walks BLOCK > TEMPLE > CLAVE; HOLLOW is the
  air inside ringing on, the temple block's "tok".
- **PRC2** a balafon key over a gourd. TUNE walks a carved, tuned key to a
  plain bar of wood. BUZZ is the gourd's mirliton, a skin over a hole that
  rattles once the air moves hard enough.
- **HAT** a shaker (after Perry Cook's PhISEM): seeds colliding in a shell
  as often as the shake's energy allows. BEANS is how many, GRAIN sand to
  dried beans, ATTACK the shake coming on.
- **CYM** a rainstick: pebbles falling past cactus spines over DECAY, each
  ticking one at its own pitch around PITCH. DENSITY is how many, RING how
  long a spine rings, TUBE the hollow of the tube, SWELL the tilt.

| FM | T2 | T3 | T4 |
|---|---|---|---|
| BD1 | SWEEP / S.TIME | FM / RATIO | WAVE / LEVEL |
| BD2 | SWEEP / S.TIME | FM / FDBK | RATIO / LEVEL |
| CLP | SPREAD / GRAINS | FM / RATIO | WAVE / LEVEL |
| SNR | SNAP / N.DEC | FM / RATIO | WAVE / LEVEL |
| PRC1 | FM / M.DEC | RATIO / FDBK | WAVE / LEVEL |
| PRC2 | FM / M.DEC | SWEEP / RATIO | WAVE / LEVEL |
| HAT | RATIO / NOISE | FM / TONE | CURVE / LEVEL |
| CYM | RATIO / NOISE | FM / TONE | TREM / LEVEL |

WAVE is the OPL3's: SINE, HALF, ABS, QUART, ALT, CAMEL, SQUARE, LOGSAW.
RATIO on the operators is the chip's MULT (x1/2 to x15); on the hat and
cymbal it is the second rhythm operator against the first. FM is the
modulation depth and M.DEC how fast it closes; FDBK is operator 1 feeding
back on itself, sine to saw to noise. PRC2 is the taiko: a drum that
sweeps into its pitch with a stick click on top. TREM is the chip's 3.7 Hz
tremolo.

| GLITCH | T2 | T3 | T4 |
|---|---|---|---|
| BD1 | SOFT / BREATH | STUTTER / GAP | SWEEP / LEVEL |
| BD2 | DUB / GAP | SOFT / GRIT | TONE / LEVEL |
| CLP | DENSITY / GRAIN | CRUNCH / SPREAD | SQUEAK / LEVEL |
| SNR | RATE / CURVE | SNAP / PAPER | JITTER / LEVEL |
| PRC1 | RISE / SPLASH | SCATTER / SPREAD | WINDOW / LEVEL |
| PRC2 | BRIGHT / BODY | STUTTER / GAP | STEP / LEVEL |
| HAT | GRAINS / SPREAD | BITS / RATE | AIR / LEVEL |
| CYM | SWELL / VOWEL | CRACKLE / SHIMMER | AIR / LEVEL |

- **STUTTER / GAP** (BD1, PRC2) retrigger the hit STUTTER times, GAP apart,
  each repeat quieter, the way a cut-up edit repeats a sliver of sound.
- **BD1** a hush of a kick: a breath of noise (SOFT is how long it lasts)
  rings a low resonance that falls SWEEP octaves into PITCH. BREATH is the
  noise on its own, the air around the thump.
- **BD2** a heartbeat: two soft thumps GAP apart, the second DUB as loud and
  a little higher. GRIT is a crackle in it.
- **CLP** a footstep in snow: a cloud of tiny grains (DENSITY a second, each
  GRAIN long) at pitches SPREAD around TONE. CRUNCH makes most grains small
  and a few big. The step presses, gives and settles. SQUEAK is packed snow.
- **SNR** a riffle of cards: clicks at RATE a second, CURVE speeding them up
  or slowing them down, JITTER making them uneven. SNAP is the paper's first
  slap, PAPER the rustle underneath.
- **PRC1** a drop of water: a resonance that RISES as it dies, the way a
  bubble does. SCATTER adds smaller drops over WINDOW, SPREAD in pitch.
  SPLASH is the hiss of it landing.
- **PRC2** a music box tine plucked by noise. Each STUTTER repeat is STEP
  semitones on from the last, so +12 climbs in octaves, a sparkle.
- **HAT** the clicks a cut sound file makes: a tick, then GRAINS more
  scattered over SPREAD. BITS and RATE crush them; AIR is hiss after.
- **CYM** a whisper: breath through three vowel formants (VOWEL walks A E I
  O U, PITCH moves them), swelling in over SWELL. SHIMMER turns it glassy,
  CRACKLE is ice.

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
and COLOUR. STOP stops and resets every track to the top.

**Steps (rows 1-4)** show the selected track's 64 steps. Every beat (each
fourth step) is dimly lit, the first of each bar a little brighter; steps past
the track's length are dark. Hold **SHIFT** on its own and the track's last
step flashes brightly. The script starts with an empty pattern.

- Press an empty step to place one.
- Press a placed step and let go quickly to remove it.
- Hold one or more steps, then open a control, to edit those steps (see below).
- **SHIFT + step** sets the track's length to that step.

**Track controls (rows 6-7)** are momentary. Hold one and the screen shows its
two parameters, E2 and E3. Let go and the screen closes.

- **SHIFT + control** latches it open. Do the same again (or latch another)
  to close it.
- **SHIFT + track** plays that track's sound, to preview it.
- **SHIFT + STOP** is FILL for as long as you hold STOP, for the `FILL` /
  `!FILL` conditions. You can let go of SHIFT once it is on. PLAY blinks
  while it is.
- **SHIFT + PLAY** opens the SNAP page (see below).
- **SHIFT + MIX** opens the PERFORM page (see below).
- **SHIFT + COLOUR** is the hidden TAPE while you hold COLOUR (see below).
- **COLOUR** also turns the grid into the clip launcher (see
  [Clips and RAIN](#clips-and-rain)).

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
| **C2** | DELAY / SPRING: the track's sends to the shared delay and spring (see SPACE) |

| | T2 | T3 | T4 |
|---|---|---|---|
| BD1 | SWEEP / S.TIME | PUNCH / BODY | TONE / LEVEL |
| BD2 | SWEEP / S.TIME | CLICK / DRIVE | TONE / LEVEL |
| CLP | SPREAD / GRAINS | SIZZLE / WIDTH | SNAP / LEVEL |
| SNR | SNAP / WIRES | W.TONE / RING | CRACK / LEVEL |
| PRC1 | MODE / DETUNE | STRIKE / TONE | DRIVE / LEVEL |
| PRC2 | BEND / B.TIME | STRIKE / DRIVE | NOISE / LEVEL |
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

### Recording a sample

**Hold S1 and tap a step** to arm the selected track to record that many of
its own steps, at its own speed: step 16 on a 1/16 track is one bar, step 64
is four. Takes are capped at 20 seconds, so at slow tempos the steps beyond
that stay dark while S1 is held. Tap the same step again to disarm.

While a take is armed, the main page shows the REC panel:

| | |
|---|---|
| E1 | START: **THRESH** (the first hit louder than LEVEL, keeping the 10 ms before it so the attack is not cut), **PLAY** (step 1: the next PLAY, or the next bar if already playing) or **NOW** |
| E2 | LEVEL, the THRESH threshold, drawn as a line over the source's meter |
| E3 | SOURCE: the inputs **IN L+R**, **IN L** or **IN R**, the **MIX** as you hear it, or one track's own voices (locks and LFOs included) |
| K2 | cancel |
| K3 | start now, or end a take early and keep it |
| K2 + K3 | LEVEL back to -30 dB |

While it records, the steps fill up and S1 pulses. Each take is normalised,
faded at both ends, written to `dust/audio/drumdrum/rec/` and loaded onto the
track like any chosen file. It saves with PSETs and snapshots, and S1's E2
then steps through your takes. If the track's sample LEVEL is at 0, the
first take turns it up to full.

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

### Track settings (main page)

On the main screen **E1** picks a pair and **E2 / E3** turn it, for the
selected track (pick the track with the grid's track buttons):

| pair | E2 | E3 |
|---|---|---|
| 1 | LENGTH: 1-64 steps | TIMING: 1/32, 1/16T, 1/16, 1/8T, 1/8, 1/4 |
| 2 | DIRECTION: FWD, BWD, PEND, WALK, RND | DILLA: 0-100 % |

**DIRECTION** is the order the steps play in. FWD and BWD go round forwards
or backwards. PEND goes there and back without playing either end twice.
WALK is a drunk's walk: each step goes on one, back one, or stays put,
wrapping at the ends. RND picks any step. For the A:B and 1ST conditions, a
pass is one lap (FWD, BWD), there and back (PEND), or LENGTH steps (WALK,
RND).

**DILLA** gives the track that J Dilla feel: a beat played in by hand on an
MPC with the quantise off. It is not random shake. Each voice has its own
place against the beat: the kicks push a hair early, the claps and snares
lay back late, and every off-beat is dragged part of the way towards where a
triplet would put it. Hats go almost all the way, kicks only a little, so the
groove sits somewhere between straight and swung and the voices rub against
each other instead of locking. On top of that, each track slowly wanders
early or late for a bar or two the way a player does, with a touch of
hit-to-hit looseness. Low amounts gently loosen things; 100 % is properly
drunk. Turn it up on several tracks together for the full effect.

All four go with the clip, so each clip slot can have its own. A small dot
under the steps on the screen shows which pair you are on.

### Swing

Hold **SWING**: E2 is the amount (50-75 %), E3 the grid (1/16 or 1/8), and
E1 is RAIN (see below). The
whole pair of units is warped, so every pulse inside moves in proportion
rather than only the off-beat.

### Clips and RAIN

The clip launcher is the grid on the **COLOUR** page (the norns screen there
is the master COLOUR, see below). The seven rows above each track button are
that track's seven clip slots, like Ableton's session view: row 1 at the
top, row 7 just above the button. On row 7, columns 1 and 2 page back and
forward through the COLOUR banks and column 16 is BYPASS.

```
      1   2   3   4   5   6   7   8   9  10  11  12  13  14  15  16
  1   ·   ·   ·   ·  [1   2   3   4   5   6   7   8]  ·   ·   ·   ·    slot 1
  .                                                                      ...
  7   <   >   ·   ·  [1   2   3   4   5   6   7   8]  ·   ·   ·   BYP  slot 7
  8   PLAY STOP SWNG .  [1   2   3   4   5   6   7   8]  .  SHFT MIX COL
          (· = rain falls here, < > = COLOUR bank back / forward)
```

A clip is a track's sequence: its steps (with their locks, conditions and
pulses), its LENGTH, TIMING, DIRECTION and DILLA. The sound, template, LFOs and mute stay
with the track, so a clip plays in whatever the track sounds like now.

- **Tap a slot** to launch it. While playing, it waits for the next bar
  (blinking) and the track starts the clip from its first step on that bar;
  stopped, it switches at once. STOP drops any launch still waiting.
- **Tap an empty slot** to start a new sequence there: an empty 16-step
  forwards pattern at the timing and DILLA the track was running.
- **Hold a slot and tap another** (any track) to copy the first into it.
- **SHIFT + STOP + slot** empties it (and does not start FILL).

The playing slot is bright and flickers with the track's hits; slots with
steps in are half lit; empty ones are dim.

**RAIN** is **E1** while you hold **SWING**. Random hits scatter
across all eight voices like rain on a roof: each track may drop one into
any of its own pulses that would otherwise be silent, so the drops sit on
the grid and swing with it. Both the chance and the loudness grow with the
square of the amount, so 10 % is a quiet ghost note every few bars and
100 % is a downpour. Muted tracks stay dry. The four columns either side of
the launcher show the drops falling. RAIN is a norns param (SEQUENCER > rain), so it maps to MIDI
and saves with PSETs and snapshots.

## MIX

Press **MIX**. Above each track button is a fader: its column is the track's
level, with the meter running over it. Press a row to set the level.

The track buttons are mutes on this page: tap one to mute or unmute it.

Pan is to the sides, three buttons a track. Tracks 1-4 have a row each on the
left (columns 1-3) and tracks 5-8 on the right (columns 14-16). The middle
button centres the track; the outer two nudge it a tenth left or right each
press, so ten presses from centre is hard over. The middle button is bright
at centre and each side lights as far as the track is panned that way.

On norns: **E1** picks the track, **E2** pans it, **E3** tilts it (a
one-knob tilt EQ around 700 Hz). Grid SHIFT + E2 trims the level finely.

## SNAP

**SHIFT + PLAY** opens it (and closes it again). Rows 1-4 are 64 snapshots,
one per sequencer cell. A snapshot is the whole machine: every sound (every kit's, and which kit each track is on), sample,
mix, LFO, swing, ANALOG / HISS and master COLOUR / SPACE setting, plus the
patterns, lengths, timings, directions, DILLAs, mutes, templates, LFO patch points, every
track's clip slots and the selected track. Tempo is included but only
applied while the clock source is internal.

- **SHIFT + hold a cell** saves into it, as in Pappus: the cell fills while
  you hold and saves when it is full. Let go early and nothing is written.
- **Tap a cell** loads it. While playing, the load waits for the next beat:
  each track takes its new pattern in time to play it on that beat, and the
  sound changes just before it. Stopped, it loads at once. The waiting cell
  blinks.
- **Tap a blank cell** loads the INIT patch: every setting at its default and
  nothing on the sequencer, the same way (on the beat while playing).
- **Row 7, columns 1-4 are the kits:** WARM, WOOD, FM, GLITCH. Tap one and every
  track goes to it. Hold one and press track buttons to move only those
  tracks: the tracks already on it light up while you hold. A kit is
  bright when every track is on it and half lit when some are. The screen
  shows each track's kit along the bottom (WA, WO, FM, GL). A change is heard
  from each track's next hit.
- **SHIFT + STOP + hold a cell** deletes it: the cell drains while you hold
  and is removed when it is empty. Let go early and it stays. (SHIFT + STOP
  is still FILL here; touching a cell to delete it turns the fill off.)

Saved cells are lit, the last one used brightest. Snapshots are kept in
`drumdrum-snapshots.data` in the script's data folder, apart from PSETs.
PERFORM latches are not part of a snapshot.

## PERFORM

**SHIFT + MIX** opens it (and closes it again). Rows 1-4 are 64 punch-in
effects, after the TE EP-133 and OP-XY: eight strips of eight pads, one
effect a strip, getting stronger or shorter to the right.

```
         columns 1-8                        columns 9-16
  1   REPEAT    1/4 3/16 1/8 1/8T ... 1/64   GATE      1/8 1/8T 1/16 ... 1/128
  2   LOWPASS   5k ... 180 Hz                HIGHPASS  150 Hz ... 6k
  3   SPEED     STOP 2, STOP 1, STOP.5,      CRUSH     12 bit / 16k ... 3 bit / 1.2k
                HALF, REV 1, REV.5,
                OCT UP, SPIN
  4   ECHO      1/32 ... 1/2                 DROP      NO BD, NO SN, NO PRC, NO HAT,
                                                       BD ONLY, BD+SN, TOPS, BREAK
```

- **Hold a pad** and the effect is on until you let go.
- **Strips stack.** Hold REPEAT and LOWPASS together and the repeat is
  filtered. They are always applied in the same order, whatever order you
  press them in: REPEAT, SPEED, TAPE, GATE, CRUSH, LOWPASS, HIGHPASS, ECHO.
- **Within a strip the newest pad wins.** Let it go and the strip goes back
  to the pad you are still holding. The filters, GATE and CRUSH glide to the
  new setting; the rest start again.
- **SHIFT + pad** latches it. Do it again to unlatch. Latches stay on when you
  leave the page. **K2+K3** on the page unlatches everything.

What the strips do:

| | |
|---|---|
| **REPEAT** | Loops the last stretch of its length, starting on the grid line. The first pass is what was already playing, so it always comes in on time. |
| **GATE** | Chops the mix in time, counted from the bar. |
| **LOWPASS / HIGHPASS** | Resonant filters that sweep in from open when pressed. |
| **SPEED** | Tape stops over 2, 1 or ½ beats; a drop to half speed; the last beat or half beat played backwards; the last half beat an octave up; a record spun back. |
| **CRUSH** | Bit depth and sample rate down together. |
| **ECHO** | A dub throw. While held, the mix goes into a ping-pong echo. When you let go it stops taking input but the echoes keep ringing. |
| **DROP** | Takes tracks out. It has its own mute, so it never changes the mutes you set on MIX. Dropped tracks show dim on the bottom row. |

Everything timed follows the tempo at the moment you press. The effects sit
after the delay and spring returns and before the master COLOUR, so the
buss, the texture and the limiter still come last.

### TAPE (hidden)

Hold **SHIFT + COLOUR**. The last LENGTH of whatever is playing loops back,
varispeeded to PITCH like a tape loop. You can let go of SHIFT once it has
started; it stops when you let go of COLOUR. While it is held the screen
shows two reels, and:

| | |
|---|---|
| E2 | PITCH, ±24 semitones (−12 to start). Changes glide, as on tape |
| E3 | LENGTH: 1/16, 1/8, 1/4, 1/2, 1 BAR, 2 BAR |
| K2+K3 | back to −12 and 1 BAR |

Both are in `PARAMS > TAPE` and in snapshots.

## COLOUR

Press **COLOUR**. The master is a drum buss after Ableton's Drum Buss, then
Pappus' colour stage, in four banks of cells:

    BUSS     comp > drive > crunch > damp > transients > boom > mix > level
    DUCK     one track's hits duck the other seven
    TEXTURE  tilt > loss > envelope-following noise > wow > chorus
    SPACE    the shared delay and spring reverb

It is always wet; BYPASS is the way out.

### BUSS

| cell | E2 | E3 |
|---|---|---|
| DRV | DRIVE, with makeup, so it adds density more than level | TYPE: SOFT waveshaping, MEDIUM limiting that pushes the high mids, HARD clipping that pushes the lows |
| CRN | CRUNCH: sine-shaped distortion on the mid-highs only | DAMP: a lowpass to tame what drive and crunch add |
| TRN | TRANS: above 100 Hz. Both ways add attack; + lifts the sustain (fuller), − cuts it (tighter, less room and rattle) | COMP: a fast bus compressor, threshold and ratio on one knob |
| BOM | BOOM: a low resonator every hit rings | FREQ: 30-120 Hz |
| B.D | DECAY: how long the boom rings | TILT |
| OUT | MIX: the buss against the dry bus | LEVEL |

### DUCK

| cell | E2 | E3 |
|---|---|---|
| DCK | SOURCE: OFF, or the track that does the ducking | AMOUNT: up to -30 dB on a full hit |
| REL | RELEASE: how long the rest takes to come back | FX: how much the delay and spring returns duck too |

The source hears its track before the fader and after the mute: its fader
does not change how hard it ducks, so a source pulled all the way down still
pumps the rest (a ghost trigger), but muting it stops the ducking. The source
itself never ducks.

### TEXTURE

| cell | E2 | E3 |
|---|---|---|
| LOS | LOSS: a codec falling apart, with spectral holes and the top closing off | WOW: tape drift, flutter at the top of the knob |
| NOI | NOISE: rides the drums' own envelope, opening with every hit | TYPE: white, pink, dust, crackle, hiss |
| N.S | N.DEC: how long the noise hangs on | N.TONE |
| CHO | CHORUS: a Juno's, off at 0, half and half at the top | RATE: 0.05 to 8 Hz |
| C.S | DEPTH: how far it sweeps | BBD: how much of the bucket brigade comes with it, darker, softer, a breath of hiss |

The CHORUS sends each side through a delay of a few milliseconds swept by
a triangle, left and right swept opposite ways, so it widens the mix as it
thickens it. It comes after everything else in TEXTURE, and BYPASS takes
it out with the rest.

### SPACE

The delay and spring reverb every track's **C2** sends into. Their returns
join the mix ahead of the buss, so drive, crunch and wow colour the echoes and
the spring too. BYPASS bypasses the colour stage only.

**SPRING** models a three-spring tank. A real spring carries low frequencies
more slowly than high ones, so each echo arrives as a falling chirp (the
"drip"), and the echoes come round every few tens of milliseconds as the wave
runs up and down the spring. Each spring here is a chain of dispersive
allpass filters (after Parker and Välimäki's spring model) and a delay that
wobbles slightly, as a spring does in its can. The three springs have
different lengths, so their echoes never line up. The lows are cut before the
tank, because a spring cannot hold them.

| cell | E2 | E3 |
|---|---|---|
| DLY | TIME: 1/16 to 1/2 in beats, following the tempo, gliding like tape when it changes | FEEDBK: up to 110 %, where it blooms but stays bounded |
| D.S | D.TONE: a lowpass inside the loop, so every repeat is darker | PING: how far the repeats bounce left and right |
| SPR | DECAY: how long the spring rings, 0.3 to 8 s | TONE: where the spring's top rolls off |
| S.S | DWELL: how hard the tank is driven, as on a Fender: louder, longer, dirtier | DRIP: how far each echo smears into a chirp |
| RET | DELAY return level | SPRING return level |

The sends are post-fader and after the mute, so muting a track lets its tail
ring out. Like every C button they take step locks and LFOs: lock a big
DELAY send on one snare for a dub throw.

On norns, **E1** picks the cell and **E2/E3** turn its two halves. The grid
on this page is the clip launcher (see [Clips and RAIN](#clips-and-rain)),
apart from row 7: columns 1 and 2 page back and forward through BUSS, DUCK,
TEXTURE and SPACE (round at the ends), and column 16 is BYPASS.

The screen is Pappus' wave field. Drive sharpens the crests, crunch terraces
them, comp squeezes the stack, boom swells it, each of the duck source's hits
pulls it flat for a moment, loss breaks the lines into dashes, wow shears the sheet, the chorus doubles every line with a drifting twin, and each hit
throws a ripple across it from where its track sits on the grid.

## norns

| | |
|---|---|
| E1 | main page: the pair (LENGTH / TIMING, DIRECTION / DILLA). COLOUR page: cell, through BUSS, DUCK, TEXTURE, SPACE. Elsewhere: track |
| E2 / E3 | the open screen's pair. SNAP and PERFORM pages: E2 is tempo |
| K2 | play / stop |
| K3 | next page: main > mix > colour |
| K2 + K3 | reset what the open screen's E2 and E3 turn (see below) |
| K1 held | fine adjustment |

K2 and K3 act when you let go of them, so that pressing both together can
be told apart from pressing one.

When a control screen is open, K2 and K3 only do that screen's work: LFO
shape, or clearing locks. A thumb resting on K2 will not stop the music. The
same goes while the TAPE is held.

**K2 + K3** puts back whatever the open screen's E2 and E3 turn:

| screen | resets |
|---|---|
| a control | its two parameters. With steps held: a sound control loses those steps' locks, TC / P go back to a plain step's values. With no steps held, TC / P reset the template |
| an LFO | its rate, depth and shape (the patch stays) |
| SWING | amount and grid (not RAIN) |
| TAPE | pitch and length |
| MAIN | the open pair: LENGTH 16 and TIMING 1/16, or FWD and DILLA 0 |
| MIX | the track's pan and tilt (not its level) |
| COLOUR | the selected cell's two parameters |
| PERFORM | unlatches every pad |
| REC | the threshold |

### Clock and transport

drumdrum follows SYSTEM > CLOCK > source, and starts on the beat it is given:

| source | START / STOP |
|---|---|
| internal | PLAY restarts the norns clock, so step 1 is the moment you press it |
| midi | the DAW's START plays step 1 on its first clock tick; its STOP stops and resets. A START while playing sends us back to the top with it. PLAY here joins on the next bar of the DAW's count |
| link | with *link start/stop sync* on, PLAY and STOP start and stop the whole session and step 1 is the session's beat 0. Otherwise PLAY joins on the next quantum line |
| crow | PLAY joins on the next bar |

Every step is placed on norns' beat, not counted in seconds from when the
script got round to it, so the pattern does not drift against the other
machine. Only swing and nudge, the deliberately off-grid parts, are timed in
seconds, and those are measured from the beat.

## Files

```
drumdrum.lua            entry point: init, keys, encoders
lib/Engine_DrumDrum.sc  voices (four kits), channel strips, duck, delay, spring, punch-ins, master COLOUR
lib/spec.lua            grid layout, voices, every parameter and its range
lib/state.lua           tracks, params, the hit that turns a step into sound
lib/seq.lua             sequencers, conditions, pulses, swing
lib/lfo.lua             LFOs and patching
lib/gridui.lua          the grid's five faces
lib/ui.lua              screen pages and overlays
lib/snap.lua            snapshots: capture, save, load on the beat
lib/clips.lua           clip slots per track, bar-quantised launches, RAIN
lib/perform.lua         PERFORM punch-ins and the hidden TAPE
lib/sampler.lua         recording a track's sample (hold S1 + step)
tools/check-lua.lua     desktop smoke test of the lua side   (lua tools/check-lua.lua)
tools/check-engine.sh   compile the engine and build every SynthDef offline
                        --render  each voice through scsynth NRT, with levels
                                  (DD_KIT=2 or 3 for WOOD or FM)
                        --demo    a few bars through the whole chain
                                  (DD_COLOUR="drive 0.5 boom 0.3" overrides the
                                  master, DD_NODUCK / DD_GHOST / DD_DRY too,
                                  DD_PUNCH to throw in some punch-ins)
```

Lua does all the range mapping and the engine receives physical units, so a
parameter's range lives in exactly one place (`lib/spec.lua`). Sound is in
norns params, so it saves with a PSET and maps to MIDI. Patterns, lengths,
speeds, mutes, templates, LFO patch points and every track's clip slots go
in a data file beside the PSET.
