#!/usr/bin/env bash
# Offline check for lib/Engine_DrumDrum.sc: compiles the class against the
# real SuperCollider class library and builds every SynthDef graph, with no
# norns and no server. Catches UGen-level mistakes, not just syntax.
#
# With --render it then renders each voice through scsynth in NRT mode, using
# the defaults lua actually sends (tools/dump-defaults.lua), and reports the
# peak, the RMS and how long each one rings (with the strip's hiss off).
# DD_KEEP=dir keeps the WAVs.
set -euo pipefail
SC=${SC:-/Applications/SuperCollider.app/Contents/MacOS/sclang}
SCSYNTH=${SCSYNTH:-/Applications/SuperCollider.app/Contents/Resources/scsynth}
LIB=${LIB:-/Applications/SuperCollider.app/Contents/Resources/SCClassLibrary}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
RENDER=${1:-}
mkdir -p "$WORK/classes"
cp "$ROOT/lib/Engine_DrumDrum.sc" "$WORK/classes/"
cat > "$WORK/classes/_stubs.sc" <<'STUB'
CroneEngine {
	var <context, <doneCallback;
	*new { arg context, doneCallback; ^super.newCopyArgs(context, doneCallback) }
	addCommand { arg name, format, func; ^nil }
	addPoll { arg name, func; ^nil }
	alloc {} free {}
}
QuartzComposerView { }
STUB
cat > "$WORK/conf.yaml" <<CONF
includePaths:
  - $LIB
  - $WORK/classes
excludePaths:
  - $LIB/deprecated
  - $HOME/Library/Application Support/SuperCollider/Extensions
postInlineWarnings: false
CONF

lua "$ROOT/tools/dump-defaults.lua" ${DD_KIT:+kit=$DD_KIT} ${OVERRIDES:-} > "$WORK/defaults.txt"

cat > "$WORK/run.scd" <<'RUN'
var n = 0, bad = 0, dir = thisProcess.argv[0], render = thisProcess.argv[1] == "render";
try { Engine_DrumDrum.buildDefs } { |err| bad = 1; "\n!! BUILD ERROR: %\n".postf(err.errorString) };
SynthDescLib.global.synthDescs.keysDo { |k|
	if(k.asString.beginsWith("dd_")) { n = n + 1 } };
"\n== synthdefs built: % (want 46)  errors: %\n".postf(n, bad);
if(n != 46) { bad = bad + 1 };

if(render and: { bad == 0 }) {
	// one line per voice: "defname arg value arg value ..."
	File.readAllString(dir ++ "/defaults.txt").split($\n).reject(_.isEmpty).do { |line, i|
		var w = line.split($ );
		var def = w[0].asSymbol;
		var pairs = w[1..].clump(2).collect { |p| [p[0].asSymbol, p[1].asFloat] }.flatten;
		var sDef = SynthDescLib.global[def].def;
		var strip = SynthDescLib.global[\dd_strip].def;
		Score([
			[0.0, ['/d_recv', sDef.asBytes]],
			[0.0, ['/d_recv', strip.asBytes]],
			// voice on bus 16 into a strip at its defaults, out to 0
			[0.0, ['/s_new', \dd_strip, 1001, 0, 0, \in, 16, \out, 0, \meter, 0, \sc, 40, \duck, 50, \hiss, 0]],
			[0.01, ['/s_new', def, 1000, 0, 0] ++ pairs ++ [\out, 16, \vel, 1, \buf, -1]],
			[4.0, ['/c_set', 0, 0]]
		]).write(dir ++ "/" ++ def ++ ".osc");
	};
};
// a few bars of groove through the whole chain: voices > strips > DELAY +
// SPRING > COLOUR, with the kick ducking the rest. Set DD_DRY to leave the
// sends at zero, DD_NODUCK to leave the duck off, DD_GHOST to hear only
// what the kick does to the rest, DD_PUNCH to throw in a few PERFORM
// punch-ins (a repeat, a gate, a tape stop, an echo throw, the hidden TAPE).
if(thisProcess.argv[1] == "demo" and: { bad == 0 }) {
	var lines = File.readAllString(dir ++ "/defaults.txt").split($\n).reject(_.isEmpty);
	var argsFor = lines.collect { |line|
		line.split($ )[1..].clump(2).collect { |p| [p[0].asSymbol, p[1].asFloat] }.flatten };
	var defsFor = lines.collect { |line| line.split($ )[0].asSymbol };
	var ev = List.new, st = 60 / 96 / 4, swing = 0.56;
	var at = { |bar, step| var i = step - 1;
		(bar * 16 * st) + (i * st) + (if(i.odd) { (swing - 0.5) * 2 * st } { 0 }) + 0.05 };
	var hit = { |bar, step, t, vel, extra|
		ev.add([at.(bar, step), ['/s_new', defsFor[t], -1, 0, 100] ++ argsFor[t]
			++ [\out, 16 + t, \vel, vel, \drift, 60 + t] ++ (extra ? [])]) };
	ev.add([0.0, ['/g_new', 100, 0, 0]]);
	ev.add([0.001, ['/g_new', 101, 3, 100]]);
	ev.add([0.0015, ['/g_new', 102, 3, 101]]);
	(defsFor ++ [\dd_strip, \dd_duck, \dd_delay, \dd_spring, \dd_colour, \dd_rec,
		\dd_pf_loop, \dd_pf_stop, \dd_pf_gate, \dd_pf_echo]).do { |d|
		ev.add([0.0, ['/d_recv', SynthDescLib.global[d].def.asBytes]]) };
	8.do { |t| ev.add([0.002, ['/s_new', \dd_strip, 2000 + t, 1, 101,
		\in, 16 + t, \out, if("DD_NOCOLOUR".getenv.notNil) { 0 } { 24 }, \meter, 1 + t, \pan, [0, 0, 0.2, 0, -0.35, 0.4, 0.25, -0.2][t],
		\dbus, 26, \sbus, 28, \idx, t + 1, \sc, 40 + t, \duck, 50, \drift, 60 + t,
		// DD_GHOST: the kick's fader down, so only its ducking is heard
		\level, if(t == 0 and: { "DD_GHOST".getenv.notNil }) { 0 } { 0.8 },
		\dsend, if("DD_DRY".getenv.notNil) { 0 } { [0, 0, 0.5, 0.35, 0.6, 0, 0, 0][t] },
		\ssend, if("DD_DRY".getenv.notNil) { 0 } { [0, 0, 0.6, 0.55, 0.4, 0.5, 0.25, 0.3][t] }]]) };
	ev.add([0.002, ['/s_new', \dd_duck, 2099, 1, 101, \sc, 40, \out, 50,
		\scsrc, if("DD_NODUCK".getenv.notNil) { 0 } { 1 }, \scamt, 0.45, \screl, 0.2, \scfx, 0.6]]);
	// beat_sec at 96 BPM, so TIME 3/16 is 0.75 of it
	ev.add([0.002, ['/s_new', \dd_delay, 2100, 1, 101, \in, 26, \duck, 50,
		\out, if("DD_NOCOLOUR".getenv.notNil) { 0 } { 24 }, \dtime, 0.75 * 60 / 96]]);
	ev.add([0.002, ['/s_new', \dd_spring, 2101, 1, 101, \in, 28, \duck, 50,
		\out, if("DD_NOCOLOUR".getenv.notNil) { 0 } { 24 }]]);
	if("DD_NOCOLOUR".getenv.isNil) { ev.add([0.002, ['/s_new', \dd_colour, 3000, 1, 102, \in, 24, \out, 0, \ampBus, 0,
		\drive, 0.3, \drivetype, 1, \crunch, 0.25, \trans, 0.3, \comp, 0.4,
		\boom, 0.35, \boomfreq, 52, \boomdecay, 0.45, \bussdamp, 14000,
		\noise, 0.12, \noisetype, 3, \wow, 0.12]
		++ (("DD_COLOUR".getenv ? "").split($ ).reject(_.isEmpty).clump(2)
			.collect { |p| [p[0].asSymbol, p[1].asFloat] }.flatten)]); };
	4.do { |bar|
		[1, 7, 11].do { |s| hit.(bar, s, 0, 1) };
		if(bar == 3) { hit.(bar, 15, 0, 0.7) };
		if(bar.odd) { hit.(bar, 16, 1, 0.55) };
		[5, 13].do { |s| hit.(bar, s, 3, 0.9) };
		if(bar.odd) { hit.(bar, 13, 2, 0.8) };
		(1, 3 .. 15).do { |s| hit.(bar, s, 6, if((s - 1) % 4 == 2) { 0.75 } { 0.45 }) };
		[10, 16].do { |s| hit.(bar, s, 4, 0.55) };
		if(bar.odd) { [4, 12].do { |s| hit.(bar, s, 5, 0.6) } };
	};
	hit.(0, 1, 7, 0.7);
	// PERFORM, between the returns and COLOUR, as the engine has it: the
	// recorder into a buffer, then each punch-in for a while. 96 BPM, so a
	// sixteenth is 0.15625 s and a beat 0.625 s.
	if("DD_PUNCH".getenv.notNil) {
		var beat = 60 / 96, pg = 103, buf = 0;
		var punch = { |at, dur, id, def, args|
			ev.add([at, ['/s_new', def, id, 1, pg, \bus, 24, \buf, buf, \pos, 55] ++ args]);
			ev.add([at + dur, ['/n_set', id, \gate, 0]]) };
		ev.add([0.0, ['/b_alloc', buf, 48000 * 30, 2]]);
		ev.add([0.0016, ['/g_new', pg, 3, 101]]);
		ev.add([0.0017, ['/s_new', \dd_rec, 2200, 0, pg, \in, 24, \buf, buf, \pos, 55]]);
		// REPEAT 1/16 from the bar line, for two beats of bar 2
		punch.(at.(1, 9), 2 * beat, 2201, \dd_pf_loop, [\a, 0, \b, beat / 4, \c, 0, \d, 1]);
		// GATE 1/32 across the end of bar 2
		punch.(at.(1, 13), beat, 2202, \dd_pf_gate, [\a, 0.125, \b, beat, \c, 3, \d, 0.5]);
		// an echo throw on the bar 3 snare, ringing on after
		punch.(at.(2, 5) - 0.01, 0.2, 2203, \dd_pf_echo, [\a, beat * 0.75, \b, 0.6, \c, 3]);
		// the hidden TAPE, last bar an octave down, for the start of bar 4
		punch.(at.(3, 1), 2 * beat, 2204, \dd_pf_loop, [\a, 4 * beat, \b, 4 * beat, \c, 0, \d, 0.5]);
		// a tape stop over the last beat
		punch.(at.(3, 13), beat * 1.2, 2205, \dd_pf_stop, [\a, beat, \b, 0]);
	};
	ev.add([(4 * 16 * st) + 2.5, ['/c_set', 0, 0]]);
	// setup first in the order it was added, then the hits in time order:
	// a sort over everything is free to put a synth ahead of its own def
	Score(ev.select { |e| e[0] < 0.01 }.asArray
		++ ev.reject { |e| e[0] < 0.01 }.asArray.sort { |a, b| a[0] < b[0] })
		.write(dir ++ "/demo.osc");
};
"\n== errors: %\n".postf(bad);
if(bad > 0) { 1.exit } { 0.exit };
RUN
"$SC" -l "$WORK/conf.yaml" "$WORK/run.scd" "$WORK" "${RENDER#--}" 2>&1 \
  | grep -viE "^\s*(Found |Compiling director|NumPrimitives|Number of|Class tree|compile done|init_OSC|Cleaning|sclang|Requested|compiling class|numentries|[0-9]+ method|method table|Byte Code|compiled [0-9]+ files|localhost :|internal :|\*\*\* Welcome)" \
  | grep -v '^$'

if [ "$RENDER" = "--render" ]; then
  for osc in "$WORK"/*.osc; do
    name=$(basename "$osc" .osc)
    "$SCSYNTH" -N "$osc" _ "$WORK/$name.wav" 48000 WAV int16 -o 2 > "$WORK/$name.log" 2>&1 || { echo "render failed: $name"; tail -5 "$WORK/$name.log"; }
    # a synth the server refuses (too many wire buffers, say) renders silence
    grep -iE "fail|exceed|error" "$WORK/$name.log" | sort -u | sed "s/^/$name: /" || true
  done
  python3 "$ROOT/tools/measure.py" "$WORK"/*.wav
  # DD_KEEP=dir keeps the renders, e.g. to compare against reference hits
  if [ -n "${DD_KEEP:-}" ]; then mkdir -p "$DD_KEEP"; cp "$WORK"/*.wav "$DD_KEEP"/; fi
fi

if [ "$RENDER" = "--demo" ]; then
  OUT=${DEMO_OUT:-$ROOT/demo.wav}
  ok=1
  "$SCSYNTH" -N "$WORK/demo.osc" _ "$OUT" 48000 WAV int16 -o 2 > "$WORK/demo.log" 2>&1 || ok=0
  if [ -n "${DEMO_LOG:-}" ]; then cp "$WORK/demo.log" "$DEMO_LOG"; fi
  # scsynth 3.14.1 on macOS segfaults while tearing NRT down once any
  # RT-pool UGen (DelayC, FFT, Limiter) has run -- after the file is written.
  # So a crash only counts if it left no audio behind.
  if [ $ok = 0 ] && [ ! -s "$OUT" ]; then
    echo "demo render failed"; grep -v nextOSC "$WORK/demo.log" | sort | uniq -c | sort -rn | head; exit 1
  fi
  python3 "$ROOT/tools/measure.py" "$OUT"
  echo "wrote $OUT"
fi
