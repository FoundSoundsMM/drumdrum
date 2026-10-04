var dir = thisProcess.argv[0];
Engine_DrumDrum.buildDefs;
SynthDef(\imp, { Out.ar(16, Impulse.ar(0) ! 2); Line.kr(0, 0, 0.02, doneAction: 2) }).add;
SynthDef(\imp1, { Out.ar(16, Impulse.ar(0)); Line.kr(0, 0, 0.02, doneAction: 2) }).add;
[
  [\colour, [\in, 16, \out, 0]],
  [\strip, [\in, 16, \out, 0, \hiss, 0, \meter, 100, \sc, 101, \duck, 102, \dbus, 104, \sbus, 106, \drift, 108]]
].do { |e|
  var name = e[0], def = ("dd_" ++ name).asSymbol;
  var src = if(name == \strip) { \imp1 } { \imp };
  Score([
    [0.0, ['/d_recv', SynthDescLib.global[src].def.asBytes]],
    [0.0, ['/d_recv', SynthDescLib.global[def].def.asBytes]],
    [0.0, ['/s_new', def, 1001, 0, 0] ++ e[1]],
    [0.0, ['/s_new', src, 1000, 0, 0]],
    [0.5, ['/c_set', 0, 0]]
  ]).write(dir ++ "/" ++ name ++ ".osc");
};
0.exit;
