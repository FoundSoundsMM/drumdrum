// Engine_DrumDrum
// warm, dusty drum machine for norns -- 8 voices, each a synth and a sampler
//
//   voice (one-shot, per hit) -> track bus -> STRIP (per track, always on)
//     -> mix bus -> COLOUR (master, always on) -> out
//
// Lua does every range mapping and sends physical units. A voice's arguments
// are cached here per track (\set) and the next \trig spawns a voice with
// whatever the cache holds, so a parameter lock is just "set, then trig" and
// costs nothing when nothing changed.
//
// Every voice shares one wrapper (*build): the voice's own body, a noise
// layer (N1/N2), a sample layer (S1-S4), the step's synth/sample MIX, the
// velocity curve, a choke gate and a silence detector that frees it.
//
// The STRIP is where the per-track COLOUR buttons live (drive, warmth,
// crush, dust) along with level, pan, tilt and mute, and it writes the meter.
// COLOUR on the master is Pappus' colour stage rebuilt for a drum bus.

Engine_DrumDrum : CroneEngine {

	classvar <nTracks = 8;
	classvar <defs;
	classvar <chokes;

	var <tBus, <mixBus, <meterBus, <ampBus;
	var <voiceGroup, <stripGroup, <colourGroup;
	var <strips, <colourS;
	var <args;        // per track: IdentityDictionary of the voice's next arguments
	var <bufs;        // per track: the loaded Buffer, or blank
	var <blank;
	var <live;        // per track: List of sounding voices, oldest first
	var mlast, mtime = 0;

	*initClass {
		defs = [\dd_bd1, \dd_bd2, \dd_clp, \dd_snr, \dd_prc1, \dd_prc2, \dd_hat, \dd_cym];
		// a choked voice cuts the one before it; the rest overlap, up to six
		chokes = [1, 1, 0, 1, 0, 0, 1, 0];
	}

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	// ------------------------------------------------------------- layers

	// N1 TYPE: white, pink, dust, tape, metal. Band-passed at N2 TONE.
	*noise { arg type, tone;
		var srcs = [
			WhiteNoise.ar,
			PinkNoise.ar * 1.6,
			(Dust2.ar(900) * 1.5) + (Decay2.ar(Dust.ar(30), 0.0002, 0.003) * WhiteNoise.ar * 3),
			LPF.ar(PinkNoise.ar * 2, 6000) * (1 + (LFNoise2.kr(5) * 0.3)),
			// clocked sample-and-hold noise: bitty and metallic, pitched by TONE
			Latch.ar(WhiteNoise.ar, Impulse.ar(tone.clip(100, 20000) * 0.5))
		];
		^BPF.ar(Select.ar(type.clip(0, 4), srcs), tone.clip(40, 16000), 0.9) * 2.2
	}

	// S2 START/DECAY, S3 PITCH/TONE, S4 ATTACK/DIR. TONE is one knob for
	// two filters: below centre a lowpass closes, above it a highpass opens.
	*sampler { arg buf, start, dec, pitch, tone, atk, rev;
		var frames = BufFrames.kr(buf);
		var r = (rev > 0.5);
		var pos = Select.kr(r, [start * frames, ((1 - start) * frames) - 2]).max(0);
		var sig = PlayBuf.ar(1, buf, BufRateScale.kr(buf) * pitch.midiratio * (1 - (r * 2)),
			1, pos, 0);
		var env = EnvGen.ar(Env([0, 1, 0], [atk, dec], [0, -4]));
		sig = LPF.ar(sig, (20000 * (0.015 ** tone.neg.max(0))).clip(80, 20000));
		sig = HPF.ar(sig, (20 * (200 ** tone.max(0))).clip(20, 8000));
		^sig * env
	}

	// --------------------------------------------------------------- voices
	//
	// Each body takes the eight TONE values (t: t1a t1b ... t4b), the pitch
	// ratio, the step's decay multiplier and the GRAIN noise (already scaled),
	// and returns [signal, amplitude envelope, attack time]. The envelope is
	// what the noise layer rides on; the attack time keeps the silence
	// detector from freeing a voice that has not got going yet.

	// BD1: an 808 -- a sine with a pitch drop. BODY pushes it into a soft
	// saturator with a little second harmonic; PUNCH is the beater.
	*bd1 { arg t, pr, decm, g;
		var freq = t[0] * pr, dec = t[1] * decm;
		var sweep = t[2], swt = t[3], punch = t[4], body = t[5], tone = t[6], lvl = t[7];
		var penv = EnvGen.ar(Env([2 ** sweep, 1], [swt], -6));
		var aenv = EnvGen.ar(Env([0, 1, 0], [0.0015, dec], [2, -5]));
		var osc = SinOsc.ar(freq * penv * (1 + (g * 0.2)));
		var sat = (osc * (1 + (body * 5))).tanh;
		var click = (HPF.ar(WhiteNoise.ar, 1500) * EnvGen.ar(Env.perc(0.0003, 0.004)) * 0.6)
			+ (SinOsc.ar(freq * 6) * EnvGen.ar(Env.perc(0.0002, 0.012)) * 0.5);
		var sig;
		sat = sat + ((sat * sat) * body * 0.25);
		sig = LPF.ar((sat * aenv) + (click * punch), tone.clip(40, 18000));
		^[LeakDC.ar(sig) * lvl, aenv, 0.002]
	}

	// BD2: after the Metasonix D-1000 -- an oscillator into a tube stage.
	// TUBE is the gain into it, BIAS shifts the operating point so the two
	// halves of the wave clip differently, and loud peaks sag the stage the
	// way grid current does. SHAPE morphs sine > triangle > pulse.
	*bd2 { arg t, pr, decm, g;
		var freq = t[0] * pr, dec = t[1] * decm;
		var sweep = t[2], swt = t[3], tube = t[4], bias = t[5], shape = t[6], lvl = t[7];
		var penv = EnvGen.ar(Env([2 ** sweep, 1], [swt], -4));
		var aenv = EnvGen.ar(Env([0, 1, 0], [0.001, dec], [1, -4]));
		var f = (freq * penv * (1 + (g * 0.3))).clip(10, 12000);
		var osc = SelectX.ar(shape * 2, [SinOsc.ar(f), LFTri.ar(f), Pulse.ar(f, 0.5)]);
		var x = (osc * aenv * (1 + (tube * 18))) + bias;
		var sig = x.tanh - bias.tanh;
		sig = LeakDC.ar(sig);
		sig = sig * (1 - (Amplitude.ar(sig, 0.0005, 0.04) * tube * 0.4));
		sig = RLPF.ar(sig, ((f * 10) + 600).clip(200, 14000), 0.8);
		^[sig * lvl * 0.8, aenv, 0.002]
	}

	// CLP: a run of noise grains SPREAD apart, then a tail. SIZZLE scatters
	// fine crackling grains over the tail; WIDTH is the band's rq.
	*clp { arg t, pr, decm, g;
		var freq = t[0] * pr, dec = t[1] * decm;
		var sp = t[2].max(0.002), cnt = t[3], sizz = t[4], rq = t[5], snap = t[6], lvl = t[7];
		var t0 = Impulse.ar(0);
		var bursts = Mix.fill(6, { |k|
			Decay2.ar(DelayN.ar(t0, 0.2, sp * k), 0.0004, sp * 0.85)
				* ((cnt - 1) > k) * (1 - (k * 0.07))
		});
		var tail = Decay2.ar(DelayN.ar(t0, 0.2, sp * (cnt - 1)), 0.001, dec);
		var n = WhiteNoise.ar;
		var body = BPF.ar(n, (freq * (1 + (g * 0.3))).clip(100, 16000), rq)
			* rq.reciprocal.sqrt * 1.6;
		var grains = Decay2.ar(Dust.ar(300 + (sizz * 3500)), 0.0002, 0.0015 + (sizz * 0.004));
		var sizzle = BPF.ar(n, (freq * 2.3).clip(200, 15000), 0.25) * grains * sizz * 5;
		var click = HPF.ar(n, 3000) * EnvGen.ar(Env.perc(0.0002, 0.003)) * snap * 2;
		var env = (bursts + tail).min(1);
		var sig = (body * env) + (sizzle * tail) + click;
		^[sig * lvl, env, 0.001]
	}

	// SNR: two shell tones a little over a fifth apart, RING letting the
	// upper one sing on, and band-passed wires on their own decay.
	*snr { arg t, pr, decm, g;
		var freq = t[0] * pr, dec = t[1] * decm;
		var snap = t[2], ndec = t[3] * decm, wtone = t[4], ring = t[5], crack = t[6], lvl = t[7];
		var penv = EnvGen.ar(Env([1.6, 1], [0.012], -4));
		var aenv = EnvGen.ar(Env([0, 1, 0], [0.0008, dec], [1, -5]));
		var renv = EnvGen.ar(Env([0, 1, 0], [0.0008, dec * (1 + (ring * 3))], [1, -4]));
		var nenv = EnvGen.ar(Env([0, 1, 0], [0.001, ndec], [1, -6]));
		var f = freq * penv * (1 + (g * 0.25));
		var n = WhiteNoise.ar;
		var shell = (SinOsc.ar(f) * aenv)
			+ (SinOsc.ar(f * 1.47) * renv * (0.3 + (ring * 0.5)))
			+ (SinOsc.ar(f * 2.13) * aenv * 0.15);
		var wires = (BPF.ar(n, wtone, 1.2) * 1.8) + (HPF.ar(n, wtone) * 0.5);
		var cr = HPF.ar(n, 2500) * EnvGen.ar(Env.perc(0.0002, 0.005)) * crack * 1.5;
		var sig = (shell * 0.9).tanh + (wires * nenv * snap) + cr;
		^[sig * lvl * 0.8, aenv.max(nenv), 0.001]
	}

	// mode ratios, six a material, MATERIAL morphing through them in order
	*modes { ^[
		[1, 1.594, 2.136, 2.296, 2.653, 2.918],     // skin: circular membrane
		[1, 3.99, 9.14, 10.65, 15.2, 19.1],         // wood: tuned bar
		[1, 2.756, 5.404, 8.933, 13.344, 18.64],    // bar: free metal bar
		[1, 2.32, 4.25, 6.63, 9.38, 12.5]           // bell
	] }

	// PRC1/PRC2: six resonators struck by an exciter. STRIKE runs from a
	// soft mallet (a long smooth pulse, the top modes barely move) to a hard
	// click with grit in it. DAMP shortens the upper modes against the
	// fundamental, POS is where on the body it is struck, BEND a pitch drop
	// like a slack skin, SPREAD a detuned twin for each mode, so they beat.
	*modal { arg t, pr, decm, g, pos, inh, bend, spread;
		var freq = t[0] * pr, dec = t[1] * decm;
		var mat = t[2], damp = t[3], strike = t[4], lvl = t[7];
		var idx = mat.clip(0, 1) * 3;
		var lo = idx.floor.min(2);
		var w = idx - lo;
		var table = Engine_DrumDrum.modes;
		var stime = 0.004 * (0.025 ** strike);
		var t0 = Impulse.ar(0);
		// unit area whatever its length, so a soft strike is not a quiet one
		var exc = (Decay.ar(t0, stime) * (6.9 / (stime * SampleRate.ir)))
			+ (WhiteNoise.ar * EnvGen.ar(Env.perc(0.0001, 0.002)) * strike * 0.25);
		var fenv = EnvGen.kr(Env([1 + (bend * 1.5), 1], [0.04 + (dec * 0.15)], -4));
		var f0 = freq * fenv * (1 + (g * 0.15));
		var env = EnvGen.ar(Env.perc(0.001, dec, 1, -4));
		var sig = Mix.fill(6, { |k|
			var r0 = Select.kr(lo, table.collect { |row| row[k] });
			var r1 = Select.kr(lo + 1, table.collect { |row| row[k] });
			var r = r0 + ((r1 - r0) * w);
			var fk = (f0 * r * (1 + (inh * (r - 1) * 0.06))).clip(20, 18000);
			var ak = sin(pi * (k + 1) * (0.05 + (pos * 0.45))).abs.max(0.08)
				* ((k + 1) ** 0.6).reciprocal * (fk < 17000);
			var dk = dec / (1 + (damp * k * 1.6));
			(Ringz.ar(exc, fk, dk) * ak)
				+ (Ringz.ar(exc, fk * (1 + (spread * 0.03)), dk * 0.9) * ak * spread * 0.8)
		});
		^[(sig * 0.9).tanh * lvl, env, 0.001]
	}

	// HAT: FOLD walks clean (filtered noise) > metal (six square waves at
	// SPREAD between harmonic and the 808's ratios) > dirty (wavefolded and
	// decimated). CURVE runs the envelope from a tight choke to a round one.
	*hat { arg t, pr, decm, g;
		var freq = t[0] * pr, dec = t[1] * decm;
		var fold = t[2], spread = t[3], tone = t[4], res = t[5], curve = t[6], lvl = t[7];
		var i808 = [1, 1.483, 1.8, 2.546, 2.63, 3.897];
		var harm = [1, 2, 3, 4, 5, 6];
		var f = freq * (1 + (g * 0.1));
		var metal = Mix.fill(6, { |k|
			Pulse.ar(f * (harm[k] + ((i808[k] - harm[k]) * spread)), 0.5)
		}) / 6;
		var a = (fold * 2).clip(0, 1);
		var dirt = ((fold - 0.5) * 2).clip(0, 1);
		var src = (WhiteNoise.ar * (1 - a)) + (metal * a * 1.6);
		var env = EnvGen.ar(Env([0, 1, 0], [0.0005, dec], [1, curve.linlin(0, 1, -9, -2)]));
		var sig;
		src = (src * (1 + (dirt * 10))).fold2(1);
		src = XFade2.ar(src, Latch.ar(src, Impulse.ar(SampleRate.ir * (0.5 - (dirt * 0.38)))),
			(dirt * 2) - 1);
		sig = RHPF.ar(src, tone.clip(500, 16000), (1 - (res * 0.9)).max(0.08));
		sig = sig + (BPF.ar(src, (tone * 1.4).clip(500, 18000), 0.3) * res);
		^[sig * env * lvl * 5, env, 0.001]
	}

	// CYM: eight phase-modulated partials and air. DUST ages it: crackle,
	// fewer bits, a lower rate, the top rolling away. SWELL slows the attack
	// right down for a reversed-cymbal bloom.
	*cym { arg t, pr, decm, g;
		var freq = t[0] * pr, dec = t[1] * decm;
		var dust = t[2], spread = t[3], tone = t[4], sizz = t[5], swell = t[6], lvl = t[7];
		var base = [1, 1.48, 1.81, 2.29, 2.71, 3.17, 3.88, 4.41];
		var f = freq * (1 + (g * 0.08));
		var partials = Mix.fill(8, { |k|
			var fk = f * (1 + ((base[k] - 1) * (0.6 + (spread * 0.8))));
			SinOsc.ar(fk, SinOsc.ar(fk * 1.41) * 2) + (Pulse.ar(fk * 0.5, 0.5) * 0.3)
		}) / 8;
		var n = WhiteNoise.ar;
		var env = EnvGen.ar(Env([0, 1, 0], [swell, dec], [2, -4]));
		var shimmer = BPF.ar(n, 9000, 0.4) * (0.6 + (LFNoise1.ar(40) * 0.4)) * sizz;
		var src = (partials * 1.2) + (HPF.ar(n, 6000) * 0.25) + shimmer;
		var sig, q, crackle;
		sig = RHPF.ar(src, tone.clip(800, 16000), 0.7);
		crackle = Decay2.ar(Dust.ar(20 + (dust * 400)), 0.0002, 0.003) * n * dust * 3;
		q = 2 ** (16 - (dust * 11));
		sig = XFade2.ar(sig,
			(Latch.ar(sig, Impulse.ar(SampleRate.ir * (0.5 - (dust * 0.35)))) * q).round / q,
			((dust * 2.5).clip(0, 1) * 2) - 1);
		sig = LPF.ar(sig, 16000 - (dust * 9000)) + crackle;
		^[sig * env * lvl * 0.8, env, swell]
	}

	// ------------------------------------------------------------- wrapper

	*build { arg name, body;
		SynthDef(name, {
			var out = \out.kr(0), vel = \vel.kr(1), gate = \gate.kr(1);
			var pitch = \pitch.kr(0), decm = \decm.kr(1), smix = \smix.kr(0);
			var t = [\t1a, \t1b, \t2a, \t2b, \t3a, \t3b, \t4a, \t4b].collect { |k| k.kr(0.5) };
			var nz = Engine_DrumDrum.noise(\ntype.kr(1), \ntone.kr(3000));
			var nlvl = \nlvl.kr(0), ngrain = \ngrain.kr(0);
			var slvl = \slvl.kr(0), satk = \satk.kr(0.0005), sdec = \sdec.kr(0.6);
			var res = body.value(t, pitch.midiratio, decm, nz * ngrain);
			var syn = res[0], env = res[1], atk = res[2];
			var smp = Engine_DrumDrum.sampler(\buf.kr(0), \sstart.kr(0), sdec * decm,
				pitch + \spitch.kr(0), \stone.kr(0), satk, \srev.kr(0)) * slvl;
			// MIX: -1 is synth alone, +1 the sample alone, 0 both at full
			var sg = (1 - smix).clip(0, 1), mg = (1 + smix).clip(0, 1);
			var sig = (((syn + (nz * env * nlvl)) * sg) + (smp * mg)) * (vel ** 1.4);
			var hold = atk + satk + 0.08;
			sig = sig * EnvGen.kr(Env.asr(0, 1, 0.012), gate, doneAction: 2);
			DetectSilence.ar(sig.abs.max(Line.ar(1, 0, hold)), 0.0002, 0.12, doneAction: 2);
			Out.ar(out, sig);
		}).add;
	}

	*buildDefs {
		Engine_DrumDrum.build(\dd_bd1, { |t, pr, d, g| Engine_DrumDrum.bd1(t, pr, d, g) });
		Engine_DrumDrum.build(\dd_bd2, { |t, pr, d, g| Engine_DrumDrum.bd2(t, pr, d, g) });
		Engine_DrumDrum.build(\dd_clp, { |t, pr, d, g| Engine_DrumDrum.clp(t, pr, d, g) });
		Engine_DrumDrum.build(\dd_snr, { |t, pr, d, g| Engine_DrumDrum.snr(t, pr, d, g) });
		Engine_DrumDrum.build(\dd_prc1, { |t, pr, d, g|
			Engine_DrumDrum.modal(t, pr, d, g, t[5], t[6], 0, 0) });
		Engine_DrumDrum.build(\dd_prc2, { |t, pr, d, g|
			Engine_DrumDrum.modal(t, pr, d, g, 0.3, 0, t[5], t[6]) });
		Engine_DrumDrum.build(\dd_hat, { |t, pr, d, g| Engine_DrumDrum.hat(t, pr, d, g) });
		Engine_DrumDrum.build(\dd_cym, { |t, pr, d, g| Engine_DrumDrum.cym(t, pr, d, g) });

		// ---- STRIP: one per track, always running ----
		SynthDef(\dd_strip, { |in = 0, out = 0, meter = 0, level = 0.8, pan = 0, tilt = 0,
			drive = 0, warmth = 0.3, crush = 0, dust = 0, mute = 0|
			var lagt = 0.05;
			var sig = In.ar(in, 1);
			var dr = Lag.kr(drive, lagt), wm = Lag.kr(warmth, lagt);
			var cr = Lag.kr(crush, lagt), ds = Lag.kr(dust, lagt), tl = Lag.kr(tilt, lagt);
			var dgain, dx, dy, mk, q, crushed, env, crackle, amp;

			// WARMTH: a broad low lift and the top rounded off
			sig = BLowShelf.ar(sig, 140, 1, wm * 5);
			sig = LPF.ar(sig, (18000 * (0.25 ** wm)).clip(2000, 20000));

			// DRIVE: Pappus' asymmetric fuzz and its fitted makeup, so the
			// knob changes character rather than level
			dgain = 1 + (dr.squared * 40);
			dx = sig * dgain;
			dy = dx / (1 + (dx.abs * (1 + (dr * 6 * (sig < 0)))));
			dy = LeakDC.ar(dy);
			mk = 1.00658 + (dr * -2.84907) + (dr.squared * 3.75126) + ((dr ** 3) * -1.62992);
			sig = XFade2.ar(sig, dy * mk, ((dr * 4).clip(0, 1) * 2) - 1);

			// CRUSH: bits and rate. The rate stays at or under half the
			// sample rate, where Latch still sees every trigger.
			q = 2 ** (15 - (cr * 11));
			crushed = Latch.ar((sig * q).round / q,
				Impulse.ar(SampleRate.ir * 0.5 * ((1 - cr) ** 2).linlin(0, 1, 0.04, 1)));
			sig = XFade2.ar(sig, crushed, ((cr * 20).clip(0, 1) * 2) - 1);

			// DUST: crackle that follows the hits, a little left over between
			env = Amplitude.ar(sig, 0.002, 0.25);
			crackle = Dust2.ar(30 + (ds * 600))
				+ (Decay2.ar(Dust.ar(4 + (ds * 30)), 0.0002, 0.003) * WhiteNoise.ar);
			crackle = HPF.ar(LPF.ar(crackle, 7000), 400);
			sig = sig + (crackle * ds * ((env * 3) + (ds.squared * 0.02)));

			// TILT: one knob leaning the spectrum around 700 Hz
			sig = BLowShelf.ar(sig, 700, 0.6, tl * -9);
			sig = BHiShelf.ar(sig, 700, 0.6, tl * 9);

			amp = Lag.kr(level.squared * 1.5 * (1 - mute), 0.02);
			sig = sig * amp;
			Out.kr(meter, Amplitude.kr(sig, 0.005, 0.25));
			Out.ar(out, Pan2.ar(sig, Lag.kr(pan, lagt)));
		}).add;

		// ---- COLOUR: the master ----
		// drive > tilt > crush > loss > envelope-following noise > wow >
		// glue > level, always wet; BYPASS is the way out.
		SynthDef(\dd_colour, { |in = 0, out = 0, ampBus = 0,
			drive = 0, ctilt = 0, crush = 0, crushmode = 3, loss = 0, wow = 0,
			noise = 0, noisetype = 2, noisedecay = 0.25, noisetone = 1200,
			glue = 0.2, outlvl = 1, bypass = 0|
			var lagt = 0.08, envref = 0.25;
			var dry = In.ar(in, 2);
			var sig = dry;
			var dr = Lag.kr(drive, lagt), cr = Lag.kr(crush, lagt);
			var ls = Lag.kr(loss, lagt).clip(0, 1), ns = Lag.kr(noise, lagt);
			var kw = Lag.kr(wow, lagt).clip(0, 1), gl = Lag.kr(glue, lagt);
			var tl = Lag.kr(ctilt, lagt);
			var env, dgain, dbias, dx, dy, mk, bits, q, bc, rd, br, crushed, jit, sr;
			var lmono, lchain, lthr, lossmono, ldry, lmix, nwash, kwd, kwf, kwm;
			var outsig, mono;

			env = Amplitude.ar((dry[0] + dry[1]) * 0.5, 0.002, Lag.kr(noisedecay, lagt)).clip(0, 1);
			env = (envref * ((env / envref).max(0) ** 2)).clip(0, 1);

			// ---- DRIVE ----
			dgain = 1 + (dr.squared * 40);
			dbias = 1 + (dr * 6.0 * (sig < 0));
			dx = sig * dgain;
			dy = dx / (1 + (dx.abs * dbias));
			dy = LeakDC.ar(dy);
			dy = LPF.ar(dy, (16000 - (dr * 10000)).clip(500, 18000));
			mk = 1.00658 + (dr * -2.84907) + (dr.squared * 3.75126) + ((dr ** 3) * -1.62992);
			sig = XFade2.ar(sig, dy * mk, ((dr * 4).clip(0, 1) * 2) - 1);

			// ---- TILT ----
			sig = BLowShelf.ar(sig, 900, 0.7, tl * -6);
			sig = BHiShelf.ar(sig, 900, 0.7, tl * 6);

			// ---- CRUSH ----
			bits = 16 - (cr * 13.5);
			q = 2 ** (bits - 1);
			bc = (sig.tanh * q).round / q;
			jit = K2A.ar(LFNoise2.kr([220, 190]).range(0.7, 1.0));
			sr = (SampleRate.ir * 0.5 * ((1 - cr) ** 3).linlin(0, 1, 0.008, 1.0) * jit)
				.clip(150, SampleRate.ir * 0.5);
			rd = Latch.ar(sig, Impulse.ar(sr));
			br = Latch.ar(bc, Impulse.ar(sr));
			crushed = [
				Select.ar(crushmode - 1, [bc[0], rd[0], br[0]]),
				Select.ar(crushmode - 1, [bc[1], rd[1], br[1]])
			];
			sig = XFade2.ar(sig, crushed, ((cr * 25).clip(0, 1) * 2) - 1);

			// ---- LOSS: a codec falling apart ----
			// bins under a level-tracking threshold are thrown away and the
			// bandwidth closes from the top. Mono, as joint stereo is at low
			// bitrates. Sine window at hop 0.5 is exactly COLA.
			lmono = (sig[0] + sig[1]) * 0.5;
			lchain = FFT(LocalBuf(512).clear, lmono, 0.5, 0);
			lthr = Amplitude.kr(lmono, 0.02, 0.15) * 163 * ls.squared * 0.45;
			lchain = PV_MagAbove(lchain, lthr);
			lchain = PV_BrickWall(lchain, 0 - ((ls ** 2.2) * 0.86));
			lossmono = IFFT(lchain);
			ldry = DelayN.ar(sig, 0.05, 512 / SampleRate.ir);
			lmix = (ls * 1.6).clip(0, 1);
			sig = (ldry * (1 - lmix)) + ([lossmono, lossmono] * lmix);

			// ---- NOISE ----
			// riding the drums' own envelope, so it opens with every hit and
			// N.DEC is how long it hangs on after
			nwash = 2.collect {
				Select.ar((noisetype - 1).clip(0, 4), [
					WhiteNoise.ar,
					PinkNoise.ar * 1.6,
					Dust2.ar(1800),
					(Decay2.ar(Dust.ar(12), 0.0003, 0.004) * WhiteNoise.ar * 6) + Dust2.ar(200),
					LPF.ar(HPF.ar(PinkNoise.ar * 2, 2000), 9000) * (1 + (LFNoise2.kr(3) * 0.3))
				])
			};
			nwash = BPF.ar(nwash, Lag.kr(noisetone, lagt).clip(60, 12000), 0.8) * 2.5;
			sig = sig + (nwash * env * ns * 4);

			// ---- WOW ----
			// cubic depth: the bottom of the knob is the slow unsteadiness
			// that stops a drum machine sounding rigid, only the top seasick
			kwd = ((kw * 0.0012) + ((kw ** 3) * 0.026));
			kwf = (kw ** 4) * 0.006;
			kwm = (LFNoise2.kr([0.08 + (kw * 0.7), 0.067 + (kw * 0.55)]) * kwd)
				+ (LFNoise2.kr([4.7, 6.1]) * kwf);
			sig = DelayC.ar(sig, 0.08, Lag.kr(0.0005 + kwd, 0.3) + kwm);

			// ---- GLUE ----
			mono = (sig[0] + sig[1]) * 0.5;
			sig = Compander.ar(sig, mono, 0.5 ** (gl * 4), 1, 1 / (1 + (gl * 3)), 0.005, 0.12)
				* (1 + (gl * 1.5));

			outsig = sig * Lag.kr(outlvl, lagt);
			outsig = [
				Select.ar(bypass, [outsig[0], dry[0]]),
				Select.ar(bypass, [outsig[1], dry[1]])
			];
			outsig = Limiter.ar(outsig, 0.95, 0.01);
			Out.kr(ampBus, Amplitude.kr((outsig[0] + outsig[1]) * 0.5, 0.01, 0.2));
			Out.ar(out, outsig);
		}).add;
	}

	// ---------------------------------------------------------------- alloc

	alloc {
		var s = context.server;

		Engine_DrumDrum.buildDefs;

		tBus = Array.fill(nTracks, { Bus.audio(s, 1) });
		mixBus = Bus.audio(s, 2);
		meterBus = Bus.control(s, nTracks);
		ampBus = Bus.control(s, 1);
		mlast = Array.fill(nTracks, { 0 });

		voiceGroup = Group.new(context.xg, \addToHead);
		stripGroup = Group.after(voiceGroup);
		colourGroup = Group.after(stripGroup);

		blank = Buffer.alloc(s, 2, 1);
		bufs = Array.fill(nTracks, { blank });
		args = Array.fill(nTracks, { IdentityDictionary.new });
		live = Array.fill(nTracks, { List.new });

		s.sync;

		strips = nTracks.collect { |i|
			Synth(\dd_strip, [\in, tBus[i].index, \out, mixBus.index,
				\meter, meterBus.index + i], stripGroup, \addToTail)
		};
		colourS = Synth(\dd_colour, [\in, mixBus.index, \out, context.out_b.index,
			\ampBus, ampBus.index], colourGroup);

		this.addCommands;
		this.addPolls;
	}

	trig { arg t, vel, pitch, decm, smix;
		var syn, list;
		if (t < 0 or: { t >= nTracks }) { ^nil };
		list = live[t];
		if (chokes[t] == 1) {
			list.do { |n| n.set(\gate, 0) };
			list.clear;
		} {
			while { list.size >= 6 } { list.removeAt(0).set(\gate, 0) };
		};
		syn = Synth(defs[t], args[t].getPairs ++ [
			\out, tBus[t].index, \vel, vel, \pitch, pitch, \decm, decm, \smix, smix,
			\buf, bufs[t].bufnum
		], voiceGroup);
		list.add(syn);
		syn.onFree({ list.remove(syn) });
	}

	addCommands {
		// set(track, argName, value): the next hit on that track uses it
		this.addCommand(\set, "isf", { |msg|
			var t = msg[1].asInteger;
			if (t >= 0 and: { t < nTracks }) { args[t][msg[2].asSymbol] = msg[3] };
		});

		// trig(track, velocity, pitch offset, decay multiplier, synth/sample mix)
		this.addCommand(\trig, "iffff", { |msg|
			this.trig(msg[1].asInteger, msg[2], msg[3], msg[4], msg[5]);
		});

		// sample(track, path): mono, the first channel. The old buffer is
		// freed late enough that a cymbal still ringing on it finishes.
		this.addCommand(\sample, "is", { |msg|
			var t = msg[1].asInteger, path = msg[2].asString;
			if (t >= 0 and: { t < nTracks } and: { File.exists(path) }) {
				Buffer.readChannel(context.server, path, channels: [0], action: { |b|
					var old = bufs[t];
					bufs[t] = b;
					if (old !== blank) { SystemClock.sched(10, { old.free; nil }) };
				});
			};
		});

		this.addCommand(\sampleClear, "i", { |msg|
			var t = msg[1].asInteger;
			var old;
			if (t >= 0 and: { t < nTracks }) {
				old = bufs[t];
				bufs[t] = blank;
				if (old !== blank) { SystemClock.sched(10, { old.free; nil }) };
			};
		});

		// strip(track, name, value): level pan tilt mute drive warmth crush dust
		this.addCommand(\strip, "isf", { |msg|
			var t = msg[1].asInteger;
			if (t >= 0 and: { t < nTracks }) { strips[t].set(msg[2].asSymbol, msg[3]) };
		});

		this.addCommand(\colour, "sf", { |msg|
			colourS.set(msg[1].asSymbol, msg[2]);
		});

		this.addCommand(\panic, "", { |msg|
			live.do { |l| l.do { |n| n.set(\gate, 0) }; l.clear };
		});
	}

	// One bus read shared by all eight meter polls: they fire as a batch,
	// so the read is cached for a few milliseconds.
	addPolls {
		nTracks.do { |i|
			this.addPoll(("meter" ++ (i + 1)).asSymbol, {
				var now = Main.elapsedTime;
				if ((now - mtime) > 0.005) {
					mlast = meterBus.getnSynchronous(nTracks);
					mtime = now;
				};
				mlast[i]
			});
		};
		this.addPoll(\outamp, { ampBus.getSynchronous });
	}

	free {
		live.do { |l| l.do(_.free) };
		strips.do(_.free);
		colourS.free;
		voiceGroup.free; stripGroup.free; colourGroup.free;
		tBus.do(_.free);
		mixBus.free; meterBus.free; ampBus.free;
		bufs.do { |b| if (b !== blank) { b.free } };
		blank.free;
	}
}
