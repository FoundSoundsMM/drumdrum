#!/usr/bin/env bash
# Offline check for lib/Engine_DrumDrum.sc: compiles the class against the
# real SuperCollider class library and builds every SynthDef graph, with no
# norns and no server. Catches UGen-level mistakes, not just syntax.
#
# With --render it then renders each voice through scsynth in NRT mode, using
# the defaults lua actually sends (tools/dump-defaults.lua), and reports the
# peak, the RMS and how long each one rings.
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

lua "$ROOT/tools/dump-defaults.lua" ${OVERRIDES:-} > "$WORK/defaults.txt"

cat > "$WORK/run.scd" <<'RUN'
var n = 0, bad = 0, dir = thisProcess.argv[0], render = thisProcess.argv[1] == "render";
try { Engine_DrumDrum.buildDefs } { |err| bad = 1; "\n!! BUILD ERROR: %\n".postf(err.errorString) };
SynthDescLib.global.synthDescs.keysDo { |k|
	if(k.asString.beginsWith("dd_")) { n = n + 1 } };
"\n== synthdefs built: % (want 10)  errors: %\n".postf(n, bad);
if(n != 10) { bad = bad + 1 };

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
			[0.0, ['/s_new', \dd_strip, 1001, 0, 0, \in, 16, \out, 0, \meter, 0]],
			[0.01, ['/s_new', def, 1000, 0, 0] ++ pairs ++ [\out, 16, \vel, 1, \buf, -1]],
			[4.0, ['/c_set', 0, 0]]
		]).write(dir ++ "/" ++ def ++ ".osc");
	};
};
// a few bars of groove through the whole chain: voices > strips > COLOUR
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
			++ [\out, 16 + t, \vel, vel] ++ (extra ? [])]) };
	ev.add([0.0, ['/g_new', 100, 0, 0]]);
	ev.add([0.001, ['/g_new', 101, 3, 100]]);
	ev.add([0.0015, ['/g_new', 102, 3, 101]]);
	(defsFor ++ [\dd_strip, \dd_colour]).do { |d|
		ev.add([0.0, ['/d_recv', SynthDescLib.global[d].def.asBytes]]) };
	8.do { |t| ev.add([0.002, ['/s_new', \dd_strip, 2000 + t, 1, 101,
		\in, 16 + t, \out, if("DD_NOCOLOUR".getenv.notNil) { 0 } { 24 }, \meter, 1 + t, \pan, [0, 0, 0.2, 0, -0.35, 0.4, 0.25, -0.2][t]]]) };
	if("DD_NOCOLOUR".getenv.isNil) { ev.add([0.002, ['/s_new', \dd_colour, 3000, 1, 102, \in, 24, \out, 0, \ampBus, 0,
		\drive, 0.22, \glue, 0.35, \noise, 0.12, \noisetype, 3, \wow, 0.12]]); };
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
  done
  python3 "$ROOT/tools/measure.py" "$WORK"/*.wav
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
