# drumdrum

An eight-voice drum machine for norns and a grid 128.

Each track is a synth voice with a sample under it. There are four kits,
per-step locks and conditions, clips, snapshots and a page of live effects.

## Install

Copy the folder to `~/dust/code/drumdrum`, then restart norns. Restart again
after any update that changes the engine. If the screen says RESTART NORNS,
do that.

## Tracks and kits

The tracks are BD1, BD2, CLP, SNR, PRC1, PRC2, HAT and CYM. Each one can use
any kit:

- **WARM**: after the MFB Tanzbar
- **WOOD**: cajon, tabla, wood block, balafon, shaker, cymbal
- **FM**: after the OPL3 chip
- **ADD**: additive sine-partial drums, after Autechre

## Grid

```
rows 1-4   the selected track's 64 steps
rows 6-7   T1-T4  S1-S4  N1 N2  TC1-TC4  P1 P2  L1 L2  C1 C2
row 8      PLAY STOP SWING . [tracks 1-8] . CLEAR MIX COLOUR
```

- **Steps:** tap to add or remove a step. Hold steps and turn a control to
  lock values to those steps.
- **Controls:** hold one and turn E2 / E3. T is the voice, S the sample,
  N noise, TC conditions, P pulses (ratchets), L the LFOs, C drive and
  sends.
- **LFO:** hold L1 or L2 together with a control, then turn E2 or E3 to
  patch it to that side. Keep turning to set the depth.
- **SWING** (held): E2 sets the amount, E3 the grid, E1 the RAIN of random
  hits.

## SHIFT and CLEAR

SHIFT is **K2** on norns. CLEAR is grid row 8, column 14.

| SHIFT + | |
|---|---|
| step | set the track length |
| S1 + step | record a sample that many steps long |
| control | keep it open |
| track | hear the track |
| PLAY / MIX | the SNAP / PERFORM page |
| STOP | FILL while held |
| COLOUR | TAPE loop while held |
| E2 / E3 | change every track |
| K3 | play / stop |
| tap on its own | back to the main page |

| CLEAR + | |
|---|---|
| step | turn it back into a plain hit |
| track (hold) | clear the track's pattern |
| control | reset it, or remove its locks from held steps |
| snapshot (hold) | delete it |
| clip slot | empty it |
| PERFORM pad | release its latch |
| tap on its own | reset what E2 / E3 are editing |

## Pages

- **MAIN:** E1 picks LENGTH / TIMING or DIRECTION / DILLA, and E2 / E3 set
  them.
- **MIX:** faders and meters above the track buttons, with pan on the
  sides. Track buttons mute. E2 pans and E3 tilts.
- **COLOUR:** the screen shows the master buss, ducker, texture, delay and
  spring reverb. E1 picks a setting. On the grid, the seven buttons above
  each track button are its clip slots. Row 7 columns 1-2 change the bank
  and column 16 is BYPASS.
- **SNAP:** 64 snapshots. Tap one to load it on the next beat (every track
  restarts from step 1 there), SHIFT + hold
  to save. Row 7 columns 1-4 pick the kit: tap one for every track, or hold
  it and press track buttons.
- **PERFORM:** 64 punch-in effects. Hold a pad to play it, SHIFT + pad to
  latch it. Track buttons mute.

## norns

| | |
|---|---|
| K2 | SHIFT |
| K3 | next page (main, mix, colour) |
| K2 + K3 | play / stop |
| K1 held | fine adjust |
| E1 | track, or what the page offers |
| E2 / E3 | the two values on screen |

drumdrum follows norns' clock settings: internal, MIDI, Link or crow.

Under Link or MIDI clock, every hit is sent early by `PARAMS > SYNC > sync
lead` (30 ms by default) to make up for the delay in norns' audio output. To
set it, record a kick into your DAW. If it lands late, raise the lead by
that many milliseconds; if early, lower it. LOSS on the COLOUR page adds
about 9 ms of delay while it's above zero.

The HISS floor (`PARAMS > ANALOG`) only plays while the sequencer runs.

## Development

```
lua lib/tools/check-lua.lua        # run the script headless
lib/tools/check-engine.sh        # build the engine offline
```
