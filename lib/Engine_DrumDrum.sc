// Engine_DrumDrum
// warm, dusty drum machine for norns -- 8 voices, each a synth and a sampler
//
//   voice (one-shot, per hit) -> track bus -> STRIP (per track, always on)
//     -> mix bus -> PERFORM (punch-ins, only while held) -> COLOUR -> out
//   STRIP -> delay send -> DELAY  \
//   STRIP -> spring send -> SPRING -> mix bus (so COLOUR colours the space too)
//   STRIP envelopes -> DUCK -> ducks the other strips and the returns
//   mix bus -> TAPE RECORDER, a running buffer the loop punch-ins play back
//   inputs / out / one track -> SAMPLER, a take written to disk (hold S1 + step)
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
// The STRIP is where the per-track COLOUR buttons live (drive, warmth and
// the delay and spring sends) along with level, pan, tilt and mute, and it
// writes the meter. COLOUR on the master is a drum buss after Ableton's
// Drum Buss into Pappus' colour stage. DELAY and SPRING are shared by every
// track, and any one track can DUCK the rest. PERFORM is the punch-in
// effects, each a synth that lives only while its pad is held.
//
// ANALOGUE: nothing here is meant to sound the same twice. Three kinds of
// imperfection, the way a real box has them:
//   tolerance  every voice is built from parts that are a little off their
//              nominal value -- partials slightly mistuned, the clap's
//              bursts unevenly spaced. These are rolled once, from a fixed
//              seed, when the SynthDefs are built, so this unit always has
//              the same character, the way one 808 differs from the next.
//   drift      each STRIP runs a slow, wandering pitch offset its voices read,
//              so a track goes a few cents flat and sharp over minutes, like
//              a warming circuit, and consecutive hits drift together.
//   variance   every hit rolls its own pitch, decay, level and brightness,
//              and free-running oscillators start wherever they happen to be.
// Then the voice goes through a VCA that is not quite linear: velocity goes
// in before it, so harder hits round over and grow a little second
// harmonic. ANALOG scales all of it, 0 being a clean digital box. Each
// STRIP adds VCA HISS under its fader, so it rises with the level, pumps
// with the duck and stops with the mute.

Engine_DrumDrum : CroneEngine {

	classvar <nTracks = 8;
	classvar <defs;
	classvar <chokes;

	var <tBus, <driftBus, <mixBus, <dlyBus, <sprBus, <meterBus, <ampBus, <scBus, <duckBus, <posBus;
	var <voiceGroup, <stripGroup, <fxGroup, <perfGroup, <colourGroup;
	var <strips, <delayS, <springS, <colourS, <duckS, <recS;
	var <tape;       // the recorder's buffer
	var <stages;     // one group per punch-in stage, in signal order
	var <punches;    // per stage: the sounding punch-in synth, or nil
	var <args;        // per track: IdentityDictionary of the voice's next arguments
	var <bufs;        // per track: the loaded Buffer, or blank
	var <blank;
	var <live;        // per track: List of sounding voices, oldest first
	var <tails;      // punch-ins let go of but still ringing out
	var mlast, mtime = 0;
	var analog = 0.5;
	var <kits;       // per track: 0 WARM, 1 WOOD, 2 FM, 3 GLITCH
	// the SAMPLER: a ring the armed recorder writes, and where a take is.
	// sState: 0 off, 1 armed (lua will say when), 2 listening for a hit,
	// 3 recording, 4 writing the file. sDone counts finished takes.
	var <sRing, <sGroup, sSynth, sPosBus, sLvlBus, sHitFunc;
	var sState = 0, sDone = 0, sStart = 0, sT0 = 0, sDur = 1, sGen = 0, sPath = "";

	*initClass {
		// per kit, per track: WARM, WOOD, FM, GLITCH
		defs = [
			[\dd_bd1, \dd_bd2, \dd_clp, \dd_snr, \dd_prc1, \dd_prc2, \dd_hat, \dd_cym],
			[\dd_wbd1, \dd_wbd2, \dd_wclp, \dd_wsnr, \dd_wprc1, \dd_wprc2, \dd_what, \dd_wcym],
			[\dd_fbd1, \dd_fbd2, \dd_fclp, \dd_fsnr, \dd_fprc1, \dd_fprc2, \dd_fhat, \dd_fcym],
			[\dd_gbd1, \dd_gbd2, \dd_gclp, \dd_gsnr, \dd_gprc1, \dd_gprc2, \dd_ghat, \dd_gcym]
		];
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

	// WARM is voiced after the MFB Tanzbar, from measurements of its own
	// samples rather than its panel. What the analysis turned up, and what
	// these voices do about it:
	//   sweeps    a pitch envelope there is a capacitor discharging into an
	//             oscillator's CV, so it falls in Hz, not in octaves: fast
	//             at first and then a long, slow settle (the BD1 starts
	//             near 200 Hz and is still settling at 100 ms). *rc is that
	//             discharge, and harder hits charge it further.
	//   tails     envelopes are RC decays too: exponential, so DECAY is the
	//             time to -60 dB and the body hangs on the way a box does.
	//   waves     the oscillators are not sines. Kick and toms carry a 3rd
	//             (and on the toms a 2nd) harmonic 15-35 dB down, as a
	//             sine leaves a transistor stage that is starting to clip.
	//   loudness  a bridged-T rings a little sharp while it is loud, so the
	//             808-type voices bend down as they die away.

	// a capacitor discharging: 1 falling to nothing, time constant tau
	*rc { arg tau;
		^EnvGen.ar(Env([1, 0.001], [tau.max(0.0005) * 6.9], \exp))
	}

	// an RC decay to -60 dB after t60, with a short rounded attack. It has
	// to land on 0 at the end: an exponential never gets there, and a voice
	// left humming at -60 dB is never freed by its silence detector.
	*rcenv { arg atk, t60;
		^EnvGen.ar(Env([0, 1, 0.001, 0], [atk, t60.max(0.005), 0.005], [2, \exp, 0]))
	}

	// a sine through a transistor stage: GAIN grows the odd harmonics,
	// BIAS tips it so the halves clip differently and the even ones come in.
	// Peak stays at 1.
	*stage { arg x, gain, bias;
		^(((x * gain) + bias).tanh - bias.tanh) / ((gain + bias).tanh - bias.tanh)
	}

	// BD1: the Tanzbar's BD1, the one with the zap: an oscillator whose
	// pitch falls from SWEEP octaves above PITCH with time constant S.TIME
	// (the samples: ~200 Hz down to ~50 Hz, tau 25-45 ms). BODY drives the
	// stage, the 3rd harmonic going from -36 dB clean to under -20 dB.
	// PUNCH is the attack: a pulse and a breath of noise.
	*bd1 { arg t, pr, decm, g;
		var freq = t[0] * pr, dec = t[1] * decm;
		var sweep = t[2], swt = t[3], punch = t[4], body = t[5], tone = t[6], lvl = t[7];
		var vel = \vel.kr(1);
		var top = freq * ((2 ** sweep) - 1) * (0.75 + (vel * 0.25));
		var f = (freq + (top * Engine_DrumDrum.rc(swt))) * (1 + (g * 0.2));
		var aenv = Engine_DrumDrum.rcenv(0.0012, dec);
		var osc = Engine_DrumDrum.stage(SinOsc.ar(f), 0.4 + (body * 1.9), 0.01 + (body * 0.03));
		var click = (HPF.ar(WhiteNoise.ar, 1200) * EnvGen.ar(Env.perc(0.0002, 0.0035)) * 2)
			+ (HPF.ar(Decay2.ar(Impulse.ar(0), 0.0001, 0.0009), 800) * 3);
		var sig = LPF.ar((osc * aenv) + (click * punch * vel), tone.clip(40, 18000));
		^[LeakDC.ar(sig) * lvl, aenv, 0.002]
	}

	// BD2: the 808 side of the Tanzbar: a bridged-T pinged by the trigger.
	// Hardly any sweep, a clean sine, a long tail, sharp while it is loud.
	// CLICK is the accent pulse coming through, DRIVE the output stage
	// leaning over, which is a 2nd harmonic first.
	*bd2 { arg t, pr, decm, g;
		var freq = t[0] * pr, dec = t[1] * decm;
		var sweep = t[2], swt = t[3], click = t[4], drive = t[5], tone = t[6], lvl = t[7];
		var vel = \vel.kr(1);
		var aenv = Engine_DrumDrum.rcenv(0.0008, dec);
		var zap = ((2 ** sweep) - 1) * Engine_DrumDrum.rc(swt) * (0.6 + (vel * 0.4));
		var f = freq * (1 + zap) * (1 + (aenv.squared * 0.05 * vel)) * (1 + (g * 0.3));
		var x = SinOsc.ar(f) * aenv;
		var sig = Engine_DrumDrum.stage(x, 0.6 + (drive * 4), drive * 0.5);
		var pulse = HPF.ar(LPF.ar(Decay2.ar(Impulse.ar(0), 0.0002, 0.0018), 4000), 700) * 4;
		sig = LPF.ar(sig + (pulse * click * vel), tone.clip(40, 18000));
		^[LeakDC.ar(sig) * lvl, aenv, 0.002]
	}

	// CLP: not three or four claps and a tail but a dense run of them: the
	// samples hold 12-19 bursts about 4 ms apart, unevenly, falling ~16 dB
	// across the run, then the tail. SPREAD is the spacing, GRAINS how many,
	// SIZZLE fine crackle over the tail, WIDTH the band's rq.
	*clp { arg t, pr, decm, g;
		var freq = t[0] * pr, dec = t[1] * decm;
		var sp = t[2].max(0.0015), cnt = t[3], sizz = t[4], rq = t[5], snap = t[6], lvl = t[7];
		var an = \an.kr(0.5);
		var run = sp * cnt;
		var trig = Impulse.ar(sp.reciprocal * (1 + (LFNoise0.ar(sp.reciprocal) * (0.18 + (an * 0.25)))));
		var open = Sweep.ar(Impulse.ar(0), 1) < (run - (sp * 0.5));
		var bursts = Decay2.ar(trig * open, 0.0002, sp * 0.55)
			* EnvGen.ar(Env([1, 0.16], [run.max(0.002)], \exp));
		var tail = EnvGen.ar(Env([0, 0, 0.1, 0.0001, 0], [run * 0.85, sp * 2, dec, 0.005], [0, 0, \exp, 0]));
		var n = WhiteNoise.ar;
		var body = (BPF.ar(n, (freq * (1 + (g * 0.3))).clip(100, 16000), rq) * rq.reciprocal.sqrt * 1.6)
			+ (HPF.ar(n, 5000) * 0.12);
		var grains = Decay2.ar(Dust.ar(300 + (sizz * 3500)), 0.0002, 0.0015 + (sizz * 0.004));
		var sizzle = BPF.ar(n, (freq * 2.3).clip(200, 15000), 0.25) * grains * sizz * 5;
		var crack = HPF.ar(n, 3000) * EnvGen.ar(Env.perc(0.0002, 0.003)) * snap * 2;
		var env = (bursts + tail).min(1);
		var sig = (body * env) + (sizzle * tail) + crack;
		^[sig * lvl, env, 0.001]
	}

	// SNR: two oscillators an octave apart (the samples: 1.97-2.0), RING
	// the upper one, with a quick zap down at the strike. The wires are
	// bright: a high-pass at W.TONE (falling away under 2 kHz),
	// flat past 8 kHz with a peak near 11 kHz, and they outlast the shell.
	*snr { arg t, pr, decm, g;
		var freq = t[0] * pr, dec = t[1] * decm;
		var snap = t[2], ndec = t[3] * decm, wtone = t[4], ring = t[5], crack = t[6], lvl = t[7];
		var vel = \vel.kr(1), an = \an.kr(0.5);
		var f = freq * (1 + (Engine_DrumDrum.rc(0.006) * 0.5 * (0.6 + (vel * 0.4)))) * (1 + (g * 0.25));
		var aenv = Engine_DrumDrum.rcenv(0.0008, dec);
		var renv = Engine_DrumDrum.rcenv(0.0008, dec * 0.8);
		var nenv = Engine_DrumDrum.rcenv(0.001, ndec);
		var n = WhiteNoise.ar;
		var shell = (SinOsc.ar(f) * aenv)
			+ (SinOsc.ar(f * 1.98 * (1 + (rrand(-0.008, 0.008) * an))) * renv * ring);
		var wires = LPF.ar(HPF.ar(n, wtone.clip(200, 12000)) + (BPF.ar(n, 10900, 0.6) * 0.5), 18000) * 1.3;
		var cr = HPF.ar(n, 2500) * EnvGen.ar(Env.perc(0.0002, 0.005)) * crack * 1.5;
		var sig = ((shell * 1.2).tanh * 0.8) + (wires * nenv * snap) + cr;
		^[sig * lvl * 0.8, aenv.max(nenv), 0.001]
	}

	// PRC1: the Tanzbar's small percussion on one MODE knob:
	//   CLAVE    one resonance, PITCH x 2.5 (the samples: 1.1-1.5 kHz),
	//            gone in 50 ms
	//   RIM      two resonances DETUNE x 1.55 apart (the samples: 2.3),
	//            clipped, with a click
	//   COWBELL  the 808's: two square waves DETUNE apart (the samples:
	//            exactly a fifth, 1.5), through a band around TONE
	// In between, the two either side are crossfaded. STRIKE is the click.
	*perc { arg t, pr, decm, g;
		var freq = t[0] * pr, dec = t[1] * decm;
		var mode = t[2], ratio = t[3], strike = t[4], tone = t[5], drive = t[6], lvl = t[7];
		var an = \an.kr(0.5);
		var f = freq * (1 + (g * 0.1));
		var n = WhiteNoise.ar;
		var exc = Engine_DrumDrum.strike(0.0004);
		var clave = Ringz.ar(exc, (f * 2.5).clip(20, 16000), dec * 0.25) * 0.5;
		var rim = ((Ringz.ar(exc, (f * 0.8).clip(20, 16000), dec * 0.22)
			+ (Ringz.ar(exc, (f * 0.8 * ratio * 1.55).clip(20, 16000), dec * 0.15) * 0.6)) * 1.5).tanh;
		var cenv = EnvGen.ar(Env([0, 1, 0.5, 0.001, 0], [0.0005, 0.01, dec, 0.005], [0, -3, \exp, 0]));
		var cow = Pulse.ar(f, 0.5 + (rrand(-0.03, 0.03) * an))
			+ Pulse.ar(f * ratio * (1 + (rrand(-0.004, 0.004) * an)), 0.5 + (rrand(-0.03, 0.03) * an));
		var env = EnvGen.ar(Env.perc(0.0005, dec, 1, -4));
		var k = 1 + (drive * 5);
		var sig;
		cow = HPF.ar(cow, (tone * 0.25).clip(80, 8000));
		cow = LPF.ar(cow + (BPF.ar(cow, (tone * 1.6).clip(200, 16000), 0.8) * 2.5), (tone * 5).clip(1000, 20000))
			* cenv * 0.3;
		sig = SelectX.ar(mode.clip(0, 1) * 2, [clave, rim, cow]);
		sig = (sig * k).tanh / k.tanh;
		sig = LPF.ar(sig, (tone * 6).clip(1000, 20000))
			+ (HPF.ar(n, 3000) * EnvGen.ar(Env.perc(0.0001, 0.002)) * strike * 0.8);
		^[sig * lvl, env, 0.001]
	}

	// PRC2: the Tanzbar's toms and congas: an oscillator through a stage
	// (2nd and 3rd harmonics 13-30 dB down in the samples), a little zap at
	// the strike and then, after a moment, the slow BEND down by up to half
	// over B.TIME (the samples: 125 Hz holding, then down to 98 by 150 ms).
	// DRIVE is the stage, NOISE the conga's slap.
	*tom { arg t, pr, decm, g;
		var freq = t[0] * pr, dec = t[1] * decm;
		var bend = t[2], btime = t[3], strike = t[4], drive = t[5], noise = t[6], lvl = t[7];
		var vel = \vel.kr(1);
		var glide = EnvGen.ar(Env([1, 1, 1 - (bend * 0.5)], [btime * 0.35, btime], [0, \sin]));
		var f = freq * glide * (1 + (Engine_DrumDrum.rc(0.0025) * 1.5 * vel)) * (1 + (g * 0.15));
		var aenv = Engine_DrumDrum.rcenv(0.001, dec);
		var osc = Engine_DrumDrum.stage(SinOsc.ar(f), 0.6 + (drive * 2.6), drive * 0.7);
		var n = WhiteNoise.ar;
		var slap = BPF.ar(n, (f * 3).clip(100, 12000), 0.5) * EnvGen.ar(Env.perc(0.0005, 0.035)) * noise * 3;
		var click = HPF.ar(n, 2500) * EnvGen.ar(Env.perc(0.0001, 0.003)) * strike * 1.5;
		var sig = LeakDC.ar((osc * aenv) + slap + click);
		^[sig * lvl, aenv, 0.001]
	}

	// HAT: FOLD walks clean (filtered noise) > metal (six square waves at
	// SPREAD between harmonic and the 808's ratios) > dirty (wavefolded and
	// decimated). CURVE runs the envelope from a tight choke to a round one.
	// The Tanzbar's hats sit in a band: almost nothing under 4.5 kHz, a
	// dense cluster around 7-8 kHz, so TONE is that band's centre and RES
	// how hard it peaks.
	*hat { arg t, pr, decm, g;
		var freq = t[0] * pr, dec = t[1] * decm;
		var fold = t[2], spread = t[3], tone = t[4], res = t[5], curve = t[6], lvl = t[7];
		var i808 = [1, 1.483, 1.8, 2.546, 2.63, 3.897];
		var harm = [1, 2, 3, 4, 5, 6];
		var f = freq * (1 + (g * 0.1));
		var metal = Mix.fill(6, { |k|
			// six oscillators, none quite where it was set
			Pulse.ar(f * (harm[k] + ((i808[k] - harm[k]) * spread))
				* (1 + (rrand(-0.008, 0.008) * \an.kr(0.5))), 0.5 + (rrand(-0.04, 0.04) * \an.kr(0.5)))
		}) / 6;
		var a = (fold * 2).clip(0, 1);
		var dirt = ((fold - 0.5) * 2).clip(0, 1);
		var src = (WhiteNoise.ar * (1 - a)) + (metal * a * 1.6);
		var env = EnvGen.ar(Env([0, 1, 0], [0.0005, dec], [1, curve.linlin(0, 1, -9, -2)]));
		var sig;
		src = (src * (1 + (dirt * 10))).fold2(1);
		src = XFade2.ar(src, Latch.ar(src, Impulse.ar(SampleRate.ir * (0.5 - (dirt * 0.38)))),
			(dirt * 2) - 1);
		sig = RHPF.ar(RHPF.ar(src, (tone * 0.7).clip(500, 16000), 0.8), (tone * 0.7).clip(500, 16000), 0.8);
		sig = sig + (BPF.ar(src, tone.clip(500, 18000), 0.3) * res * 3);
		sig = LPF.ar(sig, (tone * 1.6).clip(2000, 20000));
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
			var fk = f * (1 + ((base[k] - 1) * (0.6 + (spread * 0.8))))
				* (1 + (rrand(-0.006, 0.006) * \an.kr(0.5)));
			// free-running: every hit catches them at a different phase
			var ph = Rand(0, 2pi) * (\an.kr(0.5) > 0.01);
			SinOsc.ar(fk, (SinOsc.ar(fk * 1.41, ph * 1.3) * 2) + ph) + (Pulse.ar(fk * 0.5, 0.5) * 0.3)
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

	// ------------------------------------------------------------ WOOD kit
	//
	// Wooden, organic percussion: a cajon, a slit log, clappers, a wood
	// block, a balafon, a shaker and a rainstick. What makes them wood
	// rather than metal or skin:
	//   damping   wood loses its high frequencies fast. Every mode here
	//             dies sooner the higher it sits, by WOOD: 0 is green, damp
	//             wood that only thocks, 1 dry hardwood (rosewood, a clave)
	//             that rings
	//   contact   what strikes it and how hard is how long it stays in
	//             contact: a palm for several milliseconds, so only the low
	//             modes move, a stick for a fraction of one, with a little
	//             scrape of fibre in it
	//   air       most of them are hollow, and the air inside rings too:
	//             the cajon's port, the log's slot, the temple block, the
	//             balafon's gourd
	//   hands     nothing is struck the same way twice: every hit lands in
	//             a slightly different place, so its modes come out in a
	//             slightly different balance, by ANALOG
	// The modes are summed one at a time so a voice stays well inside the
	// server's 64 wire buffers.

	// a rounded pulse of unit area: a mode low down rings at about 1
	// whatever the contact time
	*strike { arg w;
		^Decay2.ar(Impulse.ar(0), w * 0.25, w) * (6.9 / (w * 0.75 * SampleRate.ir))
	}

	// HARD, 0-1: a palm at 0 (6 ms of contact), a hard stick at 1 (0.24 ms)
	*knock { arg hard;
		var c = 0.006 * (0.04 ** hard);
		^Engine_DrumDrum.strike(c) + (WhiteNoise.ar * EnvGen.ar(Env.perc(0.0001, c)) * hard * 0.06)
	}

	// how fast the upper modes die against the fundamental, from WOOD
	*damp { arg wood; ^2.5 * (0.12 ** wood) }

	// modes at RATIOS of F, each AMPS loud, the fundamental ringing DEC and
	// the rest shorter by DAMP. Each hit lands somewhere a little different.
	*wmodes { arg exc, f, ratios, amps, dec, damp;
		var an = \an.kr(0.5);
		^ratios.size.collect({ |k|
			var r = ratios[k];
			var fk = (f * r * (1 + (rrand(-0.006, 0.006) * k.sign * an))).clip(20, 18000);
			var dk = (dec / (1 + (damp * (r - 1)))).max(0.004);
			var ak = amps[k] * (1 + (Rand(-0.35, 0.35) * an * k.sign)) * (fk < 17000);
			[fk, dk, ak]
		}).inject(0, { |sum, m| sum + (Ringz.ar(exc, m[0], m[1]) * m[2]) })
	}

	// BD1: a cajon's bass, a palm in the middle of the face. The face is a
	// plywood plate, its modes dying fast; the box's air booms out of the
	// port at PITCH, dropping a little as the face settles. HAND runs from
	// a soft palm to firm fingers, BOX from all face to all port, FACE is
	// the plate's pitch above the port, SLAP the wires inside catching it.
	*cajon { arg t, pr, decm, g;
		var freq = t[0] * pr * (1 + (g * 0.2)), dec = t[1] * decm;
		var hand = t[2], box = t[3], face = t[4], slap = t[5], wood = t[6], lvl = t[7];
		var exc = Engine_DrumDrum.knock(hand * 0.55);
		var bend = EnvGen.kr(Env([1.07, 1], [0.035], -4));
		var port = Ringz.ar(exc, freq * bend, dec);
		var plate = Engine_DrumDrum.wmodes(exc, freq * (1.6 + (face * 2.4)),
			[1, 1.59, 2.14, 2.65, 3.16], [1, 0.6, 0.5, 0.35, 0.25], dec * 0.3, Engine_DrumDrum.damp(wood));
		var wires = HPF.ar(WhiteNoise.ar, 2500) * Amplitude.ar(plate, 0.0005, 0.03) * slap * 1.5;
		var env = EnvGen.ar(Env.perc(0.001, dec, 1, -4));
		var sig = (port * box * 1.1) + (plate * (1 - (box * 0.6)) * 0.6) + wires;
		^[(sig * 1.2).tanh * lvl * 1.5, env, 0.002]
	}

	// BD2: a slit log drum, a tongue of the log struck with a soft mallet.
	// TONGUE stretches its modes, wider for a long thin tongue; HOLLOW is
	// the log's air ringing under it; BEND the mallet pressing the tongue
	// down for a moment, so it starts a little sharp.
	*slitlog { arg t, pr, decm, g;
		var freq = t[0] * pr * (1 + (g * 0.2)), dec = t[1] * decm;
		var mallet = t[2], tongue = t[3], hollow = t[4], bend = t[5], wood = t[6], lvl = t[7];
		var exc = Engine_DrumDrum.knock(mallet * 0.7);
		var b = EnvGen.kr(Env([1 + (bend * 0.12), 1], [0.06], -4));
		var ratios = [1, 2.76, 4.1, 5.4, 7.2].collect { |r| 1 + ((r - 1) * (0.7 + (tongue * 0.6))) };
		var tng = Engine_DrumDrum.wmodes(exc, freq * b, ratios, [1, 0.45, 0.3, 0.2, 0.12], dec,
			Engine_DrumDrum.damp(wood));
		var air = (Ringz.ar(exc, freq * 0.985, dec * 1.3) * 0.7) + (Resonz.ar(tng, freq * 1.52, 0.25) * 1.5);
		var env = EnvGen.ar(Env.perc(0.001, dec, 1, -4));
		var sig = (tng * (1 - (hollow * 0.4))) + (air * hollow);
		^[(sig * 1.1).tanh * lvl * 0.8, env, 0.002]
	}

	// CLP: clappers, two boards slapped together. They never meet flat, so
	// a slap is GRAINS knocks SPREAD apart, unevenly, each ringing the
	// boards at TONE; CRACK is the air squeezed out between them, SIZE the
	// boards, bigger ones lower and rounder.
	*clapper { arg t, pr, decm, g;
		var freq = t[0] * pr * (1 + (g * 0.3)), dec = t[1] * decm;
		var sp = t[2].max(0.001), cnt = t[3], crack = t[4], size = t[5], wood = t[6], lvl = t[7];
		var t0 = Impulse.ar(0);
		var hits = Mix.fill(6, { |k|
			DelayN.ar(t0, 0.2, sp * k * (1 + (Rand(-0.25, 0.25) * \an.kr(0.5) * k.sign)))
				* (cnt > k) * (1 - (k * 0.12)) * (1 + (Rand(-0.2, 0.2) * k.sign))
		});
		var exc = LPF.ar(hits, 9000 - (size * 6000)) * 2;
		var boards = Engine_DrumDrum.wmodes(exc, freq * (1.3 - (size * 0.6)),
			[1, 1.71, 2.47, 3.3, 4.6], [1, 0.7, 0.5, 0.4, 0.25], dec, Engine_DrumDrum.damp(wood));
		var air = HPF.ar(WhiteNoise.ar, 1500) * Decay2.ar(hits, 0.0002, 0.004) * crack * 1.5;
		var env = Decay2.ar(hits, 0.0005, dec).min(1);
		^[((boards * 0.6) + air).tanh * lvl * 0.55, env, 0.001]
	}

	// SNR: a cajon slap, a hard hand at the top edge of the face: its
	// higher modes, a little of the box under them, and the snare WIRES
	// inside buzzing against the face for as long as it moves (W.DEC
	// longer still). SLAP is how hard, W.TONE the wires' colour.
	*cajonslap { arg t, pr, decm, g;
		var freq = t[0] * pr * (1 + (g * 0.25)), dec = t[1] * decm;
		var slap = t[2], wires = t[3], wt = t[4], wdec = t[5] * decm, wood = t[6], lvl = t[7];
		var exc = Engine_DrumDrum.knock(0.45 + (slap * 0.5));
		var face = Engine_DrumDrum.wmodes(exc, freq, [1, 1.59, 2.14, 2.3, 2.65, 2.92],
			[0.7, 1, 0.8, 0.6, 0.5, 0.35], dec, Engine_DrumDrum.damp(wood));
		var box = Ringz.ar(exc, freq * 0.3, dec * 0.8) * 0.3;
		var wenv = EnvGen.ar(Env([0, 1, 0], [0.001, wdec], [0, -5]));
		var moving = (Amplitude.ar(face, 0.0005, 0.04) * 3).clip(0, 1);
		var n = WhiteNoise.ar;
		var buzz = ((BPF.ar(n, wt, 0.9) * 1.6) + (HPF.ar(n, wt * 1.5) * 0.5))
			* ((wenv * 0.6) + (moving * 0.6)) * wires;
		var env = EnvGen.ar(Env([0, 1, 0], [0.0008, dec], [0, -5]));
		^[(((face * 0.55) + box).tanh + buzz) * lvl, env.max(wenv), 0.001]
	}

	// mode tables: a solid block, a hollow temple block, a clave rod
	*blocks { ^[
		[1, 1.58, 2.73, 3.9, 5.1],
		[1, 2.04, 3.3, 4.7, 6.3],
		[1, 2.756, 5.404, 8.933, 13.34]
	] }

	// PRC1: a wood block. SHAPE walks solid block > temple block > clave;
	// HOLLOW is the air inside ringing on and darkening the strike, a
	// temple block's "tok"; STICK how hard; POS where it lands.
	*woodblock { arg t, pr, decm, g;
		var freq = t[0] * pr * (1 + (g * 0.15)), dec = t[1] * decm;
		var hollow = t[2], stick = t[3], shape = t[4], pos = t[5], wood = t[6], lvl = t[7];
		var idx = shape.clip(0, 1) * 2;
		var lo = idx.floor.min(1), w = idx - lo;
		var table = Engine_DrumDrum.blocks;
		var exc = Engine_DrumDrum.knock(0.3 + (stick * 0.7));
		var ratios = 5.collect { |k|
			var r0 = Select.kr(lo, table.collect { |row| row[k] });
			var r1 = Select.kr(lo + 1, table.collect { |row| row[k] });
			r0 + ((r1 - r0) * w)
		};
		var amps = 5.collect { |k| sin(pi * (k + 1) * (0.05 + (pos * 0.45))).abs.max(0.1) / ((k + 1) ** 0.5) };
		var body = Engine_DrumDrum.wmodes(exc, freq, ratios, amps, dec, Engine_DrumDrum.damp(wood));
		var air = Ringz.ar(exc, freq * 1.01, dec * 2.5) * hollow * 0.6;
		var env = EnvGen.ar(Env.perc(0.0005, dec * (1 + (hollow * 1.5)), 1, -4));
		body = LPF.ar(body, (16000 * (0.25 ** hollow)).clip(1500, 18000));
		^[((body * 0.7) + air).tanh * lvl * 1.3, env, 0.001]
	}

	// PRC2: a balafon key. TUNE walks a carved, tuned key (its overtones
	// at 4x and 10x, as a marimba's are) to a plain bar of wood; GOURD is
	// the gourd under it, holding the fundamental on; BUZZ is the gourd's
	// mirliton, a skin over a hole that rattles once the air in the gourd
	// moves hard enough, the balafon's own sound.
	*balafon { arg t, pr, decm, g;
		var freq = t[0] * pr * (1 + (g * 0.15)), dec = t[1] * decm;
		var mallet = t[2], gourd = t[3], buzz = t[4], tune = t[5], wood = t[6], lvl = t[7];
		var exc = Engine_DrumDrum.knock(0.2 + (mallet * 0.7));
		var tuned = [1, 3.99, 9.2, 15.8], plain = [1, 2.756, 5.404, 8.933];
		var ratios = 4.collect { |k| tuned[k] + ((plain[k] - tuned[k]) * tune) };
		var bar = Engine_DrumDrum.wmodes(exc, freq, ratios, [1, 0.45, 0.25, 0.12], dec,
			Engine_DrumDrum.damp(wood));
		var air = Resonz.ar(bar, freq, 0.04) * 8 * gourd;
		var lvlair = Amplitude.ar(air, 0.001, 0.04);
		var rattle = (BPF.ar((air * 10).clip2(0.4), 1800, 1.2) * 2)
			+ (BPF.ar(WhiteNoise.ar, 2400, 1) * (lvlair * 4).clip(0, 1) * 0.4);
		var env = EnvGen.ar(Env.perc(0.001, dec * (1 + gourd), 1, -4));
		^[((bar * 0.7) + (air * 0.5) + (rattle * buzz)).tanh * lvl * 0.7, env, 0.001]
	}

	// HAT: a shaker, seeds in a gourd, after Perry Cook's PhISEM. A shake
	// is energy rising over ATTACK and draining over DECAY; the seeds
	// collide as often as the energy allows (BEANS is how many), each
	// collision a click that rings the shell at PITCH and two more
	// resonances SPREAD above it. SHELL is how much the shell rings, GRAIN
	// how hard the seeds are: sand to dried beans.
	*shaker { arg t, pr, decm, g;
		var freq = t[0] * pr * (1 + (g * 0.1)), dec = t[1] * decm;
		var beans = t[2], shell = t[3], spread = t[4], atk = t[5], grain = t[6], lvl = t[7];
		var env = EnvGen.ar(Env([0, 1, 0], [atk, dec], [2, -4]));
		var coll = Dust2.ar((30 * (60 ** beans)) * env);
		var click = Decay.ar(coll, 0.00015 + ((1 - grain) * 0.0008));
		var rq = 0.5 * (0.06 ** shell);
		var sig = [1, 1 + (spread * 0.6), 1 + (spread * 1.5)].collect({ |r, k|
			Resonz.ar(click, (freq * r).clip(500, 17000), rq) * (1 - (k * 0.25))
		}).inject(0, { |a, b| a + b }) * rq.reciprocal.sqrt * 4;
		sig = sig + (HPF.ar(click, 6000) * grain * 2);
		^[sig * lvl * 0.85, env, atk]
	}

	// CYM: a rainstick: pebbles falling down a cactus tube over DECAY, each
	// one ticking a spine at its own pitch somewhere around PITCH (SPREAD
	// is how far apart). DENSITY is how many pebbles, RING how long a spine
	// rings, TUBE the hollow of the tube under them, SWELL the tilt that
	// starts them falling.
	*rainstick { arg t, pr, decm, g;
		var freq = t[0] * pr * (1 + (g * 0.08)), dec = t[1] * decm;
		var dens = t[2], spread = t[3], tube = t[4], ring = t[5], swell = t[6], lvl = t[7];
		var env = EnvGen.ar(Env([0, 1, 0], [swell, dec], [2, -3]));
		var rate = (20 * (40 ** dens)) * env / 3;
		var sig = 3.collect({ |k|
			var d = Dust.ar(rate);
			var fr = TRand.ar(freq * (1 - (spread * 0.5)), freq * (1 + (spread * 1.5)), d);
			Ringz.ar(d * TRand.ar(0.2, 1, d), fr, 0.004 + (ring * 0.04))
		}).inject(0, { |a, b| a + b });
		var body = Resonz.ar(sig, (freq * 0.17).clip(150, 900), 0.3) * 4 * tube;
		^[((sig * 0.5) + body) * lvl * 2, env, swell]
	}

	// -------------------------------------------------------------- FM kit
	//
	// After the Yamaha YMF262 (OPL3), the way ALM's Akemie's Taiko plays it
	// as a drum: two- and four-operator FM from the chip's own parts.
	//   operators  a 10-bit phase, reset at key-on as the chip does (so
	//              every hit starts the same), through one of the OPL3's
	//              eight waveforms: sine, half, abs, quarter, alternating,
	//              camel, square, derived square. Nothing is band-limited
	//              and the chip was not either: the high sidebands fold back
	//   feedback   operator 1 feeds back on itself, sine to saw to noise,
	//              as the chip's FB 0-7 does
	//   RATIO      the chip's MULT: 1/2, 1-10, 12, 15
	//   rhythm     the hat, snare and cymbal use the OPL's rhythm mode:
	//              phase bits of two operators XORed into a metallic
	//              square, the noise generator flipping it, read out
	//              through the sine table at the chip's own phases
	//   the DAC    a 10-bit mantissa and a 3-bit exponent (the YM3014
	//              the chip feeds), so the grain rides the signal down
	// Phase modulation is in cycles: FM all the way is two of them.

	*oplwave { arg p, wave;
		var s = (2pi * p).sin, s2 = (4pi * p).sin, first = p < 0.5;
		var x = (p * 2).frac;
		^Select.ar(wave.clip(0, 7).round, [
			s,
			s.max(0),
			s.abs,
			s.abs * (x < 0.5),
			s2 * first,
			s2.abs * first,
			(first * 2) - 1,
			Select.ar(first, [(2 ** ((1 - x) * -12)).neg, 2 ** (x * -12)])
		])
	}

	*op { arg freq, pm = 0, wave = 0;
		var p = Phasor.ar(0, freq * SampleDur.ir, 0, 1);
		p = ((p + pm).wrap(0, 1) * 1024).floor / 1024;
		^Engine_DrumDrum.oplwave(p, wave)
	}

	*mult { arg i;
		^Select.kr(i.clip(0, 12).round, [0.5, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 15])
	}

	*dac { arg sig;
		var e = sig.abs.max(1e-6).log2.floor.clip(-7, 0);
		var q = 2 ** (e - 9);
		^((sig / q).round * q).clip2(1)
	}

	// bit k of a 10-bit phase
	*bit { arg p, k; ^(p * (2 ** (10 - k))).floor % 2 }

	// the rhythm mode's metal: bits 2, 3 and 7 of the hat operator against
	// bits 3 and 5 of the top cymbal's, 1 or 0
	*metal { arg p1, p2;
		var b = Engine_DrumDrum;
		var r1 = (b.bit(p1, 2) - b.bit(p1, 7)).abs.max(b.bit(p1, 3));
		^r1.max((b.bit(p2, 3) - b.bit(p2, 5)).abs)
	}

	*phase { arg f; ^Phasor.ar(0, f * SampleDur.ir, 0, 1) }

	// BD1: two operators, a modulator with a little feedback into the
	// carrier, SWEEPing down over S.TIME. The FM closes faster than the
	// pitch falls, so the click is FM and the body a WAVE.
	*fkick { arg t, pr, decm, g;
		var freq = t[0] * pr, dec = t[1] * decm;
		var sweep = t[2], swt = t[3], fm = t[4], ratio = Engine_DrumDrum.mult(t[5]), wave = t[6], lvl = t[7];
		var penv = EnvGen.ar(Env([2 ** sweep, 1], [swt], -6));
		var f = freq * penv * (1 + (g * 0.2));
		var aenv = EnvGen.ar(Env([0, 1, 0], [0.0008, dec], [0, -5]));
		var menv = EnvGen.ar(Env([1, 0], [(swt * 3) + 0.03], -4));
		var mod = SinOscFB.ar(f * ratio, 0.35);
		var car = Engine_DrumDrum.op(f, mod * fm.squared * 2 * menv, wave);
		^[Engine_DrumDrum.dac(LeakDC.ar(car) * aenv) * lvl * 1.3, aenv, 0.002]
	}

	// BD2: four operators, the chip's FM-FM with one beside it: operator 1
	// feeds back (FDBK) into 2 at RATIO, 2 into the carrier, and a plain
	// sine under them all for the weight. Pushed into the chip's clip.
	*fkick4 { arg t, pr, decm, g;
		var freq = t[0] * pr, dec = t[1] * decm;
		var sweep = t[2], swt = t[3], fm = t[4], fb = t[5], ratio = Engine_DrumDrum.mult(t[6]), lvl = t[7];
		var penv = EnvGen.ar(Env([2 ** sweep, 1], [swt], -5));
		var f = freq * penv * (1 + (g * 0.3));
		var aenv = EnvGen.ar(Env([0, 1, 0], [0.0008, dec], [0, -4]));
		var menv = EnvGen.ar(Env([1, 0], [(swt * 4) + 0.04], -3));
		var o1 = SinOscFB.ar(f * ratio, fb * 1.5) * menv;
		var o2 = Engine_DrumDrum.op(f * ratio, o1 * 0.8);
		var o3 = Engine_DrumDrum.op(f, o2 * fm.squared * 2 * menv);
		var o4 = Engine_DrumDrum.op(f);
		var sig = (((o3 * 0.75) + (o4 * 0.5)) * aenv * 1.3).clip2(1);
		^[Engine_DrumDrum.dac(LeakDC.ar(sig)) * lvl * 0.85, aenv, 0.002]
	}

	// CLP: the clap's bursts gating a carrier at TONE, modulated by an
	// operator fed back almost to noise: FM is how far, from a buzz to a
	// hiss with a pitch in it.
	*fclap { arg t, pr, decm, g;
		var freq = t[0] * pr, dec = t[1] * decm;
		var sp = t[2].max(0.002), cnt = t[3], fm = t[4], ratio = Engine_DrumDrum.mult(t[5]), wave = t[6], lvl = t[7];
		var t0 = Impulse.ar(0);
		var bursts = Mix.fill(6, { |k|
			Decay2.ar(DelayN.ar(t0, 0.2, sp * k * (1 + (Rand(-0.18, 0.18) * \an.kr(0.5) * k.sign))),
				0.0004, sp * 0.85) * ((cnt - 1) > k) * (1 - (k * 0.07))
		});
		var tail = Decay2.ar(DelayN.ar(t0, 0.2, sp * (cnt - 1)), 0.001, dec);
		var env = (bursts + tail).min(1);
		var f = (freq * (1 + (g * 0.3))).clip(100, 12000);
		var mod = SinOscFB.ar(f * ratio, 1.2 + (fm * 0.6));
		var car = Engine_DrumDrum.op(f, mod * fm.squared * 3, wave);
		var sig = HPF.ar(LeakDC.ar(car), 250) * env;
		^[Engine_DrumDrum.dac(sig) * lvl * 0.8, env, 0.001]
	}

	// SNR: a two-operator body, and the rhythm mode's snare: bit 8 of the
	// hat operator's phase, a square, with the noise generator knocking it
	// about. SNAP is how much, N.DEC how long.
	*fsnare { arg t, pr, decm, g;
		var freq = t[0] * pr, dec = t[1] * decm;
		var snap = t[2], ndec = t[3] * decm, fm = t[4], ratio = Engine_DrumDrum.mult(t[5]), wave = t[6], lvl = t[7];
		var penv = EnvGen.ar(Env([1.5, 1], [0.015], -4));
		var f = freq * penv * (1 + (g * 0.25));
		var aenv = EnvGen.ar(Env([0, 1, 0], [0.0008, dec], [0, -5]));
		var nenv = EnvGen.ar(Env([0, 1, 0], [0.0008, ndec], [0, -6]));
		var mod = SinOscFB.ar(f * ratio, 0.5) * EnvGen.ar(Env([1, 0.2], [dec * 0.5], -3));
		var body = LeakDC.ar(Engine_DrumDrum.op(f, mod * fm.squared * 2, wave));
		var b8 = Engine_DrumDrum.bit(Engine_DrumDrum.phase(f * 2.79), 8);
		var sd = LeakDC.ar(1 - b8 - (WhiteNoise.ar > 0));
		var sig = (body * aenv) + (sd * nenv * snap * 0.6);
		^[Engine_DrumDrum.dac(sig) * lvl, aenv.max(nenv), 0.001]
	}

	// PRC1: two operators as a tom or a bell: RATIO and FDBK set the
	// colour, FM how much of it, M.DEC how fast it closes to the WAVE.
	*ftom { arg t, pr, decm, g;
		var freq = t[0] * pr, dec = t[1] * decm;
		var fm = t[2], mdec = t[3], ratio = Engine_DrumDrum.mult(t[4]), fb = t[5], wave = t[6], lvl = t[7];
		var f = freq * (1 + (g * 0.15));
		var aenv = EnvGen.ar(Env([0, 1, 0], [0.0008, dec], [0, -5]));
		var menv = EnvGen.ar(Env([0, 1, 0], [0.0005, mdec], [0, -4]));
		var mod = SinOscFB.ar(f * ratio, fb * 1.5);
		var car = Engine_DrumDrum.op(f, mod * fm.squared * 2 * menv, wave);
		^[Engine_DrumDrum.dac(LeakDC.ar(car) * aenv) * lvl, aenv, 0.001]
	}

	// PRC2: the taiko: a two-operator drum that SWEEPs into its pitch,
	// the FM closing fast over M.DEC, and the stick: a click of noise.
	*ftaiko { arg t, pr, decm, g;
		var freq = t[0] * pr, dec = t[1] * decm;
		var fm = t[2], mdec = t[3], sweep = t[4], ratio = Engine_DrumDrum.mult(t[5]), wave = t[6], lvl = t[7];
		var penv = EnvGen.ar(Env([2 ** sweep, 1], [0.03 + (dec * 0.2)], -4));
		var f = freq * penv * (1 + (g * 0.15));
		var aenv = EnvGen.ar(Env([0, 1, 0], [0.0008, dec], [0, -4]));
		var menv = EnvGen.ar(Env([0, 1, 0], [0.0005, mdec], [0, -4]));
		var mod = SinOscFB.ar(f * ratio, 0.6) * menv;
		var car = LeakDC.ar(Engine_DrumDrum.op(f, mod * fm.squared * 2, wave));
		var stick = HPF.ar(WhiteNoise.ar, 2000) * EnvGen.ar(Env.perc(0.0003, 0.006)) * 0.3;
		^[Engine_DrumDrum.dac((car * aenv) + stick) * lvl, aenv, 0.001]
	}

	// HAT: the rhythm mode's hi-hat. The hat operator at PITCH, the top
	// cymbal's at RATIO times it; their metal flipped by the noise
	// generator (NOISE) and read out of the sine table at the chip's four
	// phases, so it is lopsided. FM puts the metal into a carrier as
	// phase, rougher still; TONE is a highpass.
	*fhat { arg t, pr, decm, g;
		var freq = t[0] * pr, dec = t[1] * decm;
		var ratio = t[2], noise = t[3], fm = t[4], tone = t[5], curve = t[6], lvl = t[7];
		var f1 = freq * (1 + (g * 0.1));
		var r = Engine_DrumDrum.metal(Engine_DrumDrum.phase(f1), Engine_DrumDrum.phase(f1 * ratio));
		var n = WhiteNoise.ar.abs < (noise * 0.5);
		var hh = LeakDC.ar((1 - (r * 2)) * (0.316 + (0.641 * (1 - (r - n).abs))));
		var env = EnvGen.ar(Env([0, 1, 0], [0.0005, dec], [1, curve.linlin(0, 1, -9, -2)]));
		var car = Engine_DrumDrum.op(f1 * 6, hh * fm.squared * 2);
		var sig = HPF.ar((hh * (1 - (fm * 0.5))) + (car * fm), tone.clip(500, 16000));
		^[Engine_DrumDrum.dac(sig * env) * lvl * 2.2, env, 0.001]
	}

	// CYM: the rhythm mode's top cymbal: the same metal with no noise in
	// it, a hard square, so it is harsher than the hat. NOISE is air laid
	// over it, FM as on the hat, TREM the chip's 3.7 Hz tremolo.
	*fcym { arg t, pr, decm, g;
		var freq = t[0] * pr, dec = t[1] * decm;
		var ratio = t[2], noise = t[3], fm = t[4], tone = t[5], trem = t[6], lvl = t[7];
		var f1 = freq * (1 + (g * 0.08));
		var r = Engine_DrumDrum.metal(Engine_DrumDrum.phase(f1), Engine_DrumDrum.phase(f1 * ratio));
		var cy = LeakDC.ar(1 - (r * 2));
		var car = Engine_DrumDrum.op(f1 * 3, cy * fm.squared * 2);
		var env = EnvGen.ar(Env([0, 1, 0], [0.001, dec], [2, -4]));
		var am = 1 - (trem * 0.42 * (SinOsc.kr(3.7) + 1) * 0.5);
		var sig = (cy * (1 - (fm * 0.5))) + (car * fm) + (HPF.ar(WhiteNoise.ar, 6000) * noise * 0.5);
		sig = HPF.ar(sig, tone.clip(500, 16000));
		^[Engine_DrumDrum.dac(sig * env * am) * lvl * 0.8, env, 0.001]
	}

	// ---------------------------------------------------------- GLITCH kit
	//
	// Soft glitch drums after Matmos and Björk's Vespertine, where the beat
	// is microsound: snow underfoot, a deck of cards, water, breath, the
	// tiny clicks a sound file makes when it is cut. Everything here starts
	// as noise, and stays quiet and close, like a contact mic:
	//   grains    most voices are clouds of tiny filtered noise grains, each
	//             landing at its own random pitch and loudness, so no two
	//             hits are the same even before ANALOG
	//   stutter   STUTTER / GAP retrigger the hit as an edit would, a few
	//             repeats a few milliseconds to a beat apart, each quieter
	//   soft      exciters are noise breaths of a few milliseconds rather
	//             than clicks, the tops are rounded, and nothing is driven
	//             harder than a gentle soft clip

	// a stutter: n triggers gap apart, each quieter until the last is at
	// FALL, the gaps a touch uneven by ANALOG
	*stutter { arg n, gap, fall;
		var g = gap.max(0.001), nn = n.round.max(1);
		var trig = Impulse.ar(g.reciprocal * (1 + (LFNoise0.ar(g.reciprocal) * 0.1 * \an.kr(0.5))));
		var open = Sweep.ar(Impulse.ar(0), 1) < ((nn - 0.5) * g);
		^trig * open * EnvGen.ar(Env([1, fall.max(0.001)], [(nn * g).max(0.002)], \exp))
	}

	// BD1: a hush of a kick. A breath of pink noise, SOFT long, pings a low
	// resonance that falls SWEEP octaves into PITCH; BREATH is that noise
	// heard on its own, the air around the thump.
	*hush { arg t, pr, decm, g;
		var freq = t[0] * pr, dec = t[1] * decm;
		var soft = t[2], breath = t[3], stut = t[4], gap = t[5], sweep = t[6], lvl = t[7];
		var train = Engine_DrumDrum.stutter(stut, gap, 0.35);
		var w = 0.0015 + (soft * 0.012);
		// a breath with a steady push under it: the noise is the texture, the
		// push (unit area, whatever SOFT) is what makes every thump as big
		var push = Decay2.ar(train, w * 0.3, w) / (0.7 * w * SampleRate.ir);
		var exc = push * (1 + (LPF.ar(PinkNoise.ar, 500 + ((1 - soft) * 5000)) * 1.5));
		var f = (freq * (1 + (((2 ** sweep) - 1) * Engine_DrumDrum.rc(0.025))) * (1 + (g * 0.2))).clip(20, 2000);
		var body = Ringz.ar(exc, f, dec) * 9;
		var air = HPF.ar(exc, 1200) * breath * 0.5;
		var hold = (stut.round.max(1) - 1) * gap;
		var env = EnvGen.ar(Env([0, 1, 1, 0.001, 0], [0.003, hold, dec, 0.005], [2, 0, \exp, 0]));
		var sig = LPF.ar(body.softclip + air, 4000);
		^[LeakDC.ar(sig) * lvl, env, 0.005 + hold]
	}

	// BD2: a heartbeat, lub-dub. Two soft thumps GAP apart, the second DUB
	// as loud and a little higher; GRIT is a crackle in the flesh of it.
	*heart { arg t, pr, decm, g;
		var freq = t[0] * pr, dec = t[1] * decm;
		var dub = t[2], gap = t[3], soft = t[4], grit = t[5], tone = t[6], lvl = t[7];
		var t0 = Impulse.ar(0);
		var t1 = DelayN.ar(t0, 0.5, gap.clip(0.01, 0.5)) * dub;
		var w = 0.003 + (soft * 0.02);
		var n = 1 + LPF.ar(PinkNoise.ar, 900);
		var lub = Ringz.ar(n * Decay2.ar(t0, w * 0.3, w) / (0.7 * w * SampleRate.ir),
			(freq * (1 + (g * 0.2))).clip(20, 2000), dec);
		var dubs = Ringz.ar(n * Decay2.ar(t1, w * 0.3, w * 0.8) / (0.5 * w * SampleRate.ir),
			(freq * 1.15).clip(20, 2000), dec * 0.8);
		var env = Decay2.ar(t0 + t1, 0.003, dec * 0.6).min(1);
		var crack = Decay2.ar(Dust.ar(180), 0.0002, 0.002) * BPF.ar(WhiteNoise.ar, 2500, 1) * grit * 3;
		var sig = LPF.ar(((lub + dubs) * 7).softclip, tone.clip(80, 16000)) + (crack * env);
		^[LeakDC.ar(sig) * lvl, env, gap + 0.01]
	}

	// CLP: a footstep in snow. A cloud of tiny grains, DENSITY a second at
	// the peak of the step, each GRAIN long, at its own pitch SPREAD around
	// TONE and its own loudness (CRUNCH makes most of them small and a few
	// big). The step presses, gives, then settles. SQUEAK is packed snow.
	*snow { arg t, pr, decm, g;
		var freq = t[0] * pr, dec = t[1] * decm;
		var dens = t[2], grain = t[3], crunch = t[4], spread = t[5], squeak = t[6], lvl = t[7];
		var denv = EnvGen.ar(Env([0, 1, 0.45, 0.8, 0], [0.006, dec * 0.25, dec * 0.15, dec * 0.6], [2, -2, 1, -3]));
		// a floor under the density so the settle still crackles, but none
		// once the step is over, or the voice would never fall silent
		var dust = Dust.ar(dens * denv.max(0.02)) * (denv > 0.0005);
		var amp = TRand.ar(0, 1, dust) ** (1 + (crunch * 3));
		var sp = 1 + (spread * 2);
		var fk = (freq * (1 + (g * 0.3)) * TExpRand.ar(sp.reciprocal, sp, dust)).clip(100, 16000);
		var n = WhiteNoise.ar;
		var grains = BPF.ar(n, fk, 0.6) * Decay2.ar(dust * amp, 0.0002, grain);
		var hiss = BPF.ar(n, (freq * 0.7).clip(100, 16000), 1.5) * denv * 0.05;
		var sq = Ringz.ar(BPF.ar(n, (freq * 0.5).clip(100, 16000), 0.3) * denv,
			(freq * 0.45 * (1 + (LFNoise1.kr(20) * 0.05))).clip(100, 8000), 0.03) * squeak * 0.02;
		var sig = (((grains * 4) + hiss + sq)).softclip;
		^[sig * lvl, denv, dec * 0.4]
	}

	// SNR: a riffle of cards. Cards flick past at RATE a second, speeding up
	// or slowing down by CURVE across DECAY, JITTER apart; SNAP the deck's
	// first soft slap, PAPER the rustle under the flicks. Each flick is a
	// rounded tick of pink noise at its own pitch around TONE, rather than a
	// click of white noise, so the riffle purrs instead of buzzing, and the
	// whole thing is closed down above TONE.
	*cards { arg t, pr, decm, g;
		var freq = t[0] * pr, dec = t[1] * decm;
		var rate = t[2], curve = t[3], snap = t[4], paper = t[5], jit = t[6], lvl = t[7];
		var renv = EnvGen.ar(Env([rate.max(1), rate.max(1) * (4 ** curve)], [dec], \exp));
		var trig = Impulse.ar(renv * (1 + (LFNoise0.ar(renv) * jit * 0.6)));
		var win = EnvGen.ar(Env([0, 1, 0.7, 0], [0.002, dec, 0.01], [0, -1, -3]));
		var amp = trig * win * TRand.ar(0.3, 1, trig);
		var n = PinkNoise.ar;
		var f = (freq * (1 + (g * 0.3))).clip(200, 12000);
		var flick = BPF.ar(n, (f * TExpRand.ar(0.7, 1.4, trig)).clip(200, 12000), 1.2)
			* Decay2.ar(amp, 0.0004, 0.0025) * 11;
		var bed = BPF.ar(n, (f * 0.5).clip(200, 12000), 1.5) * win * paper * 0.5;
		// the slap: the deck's edge, a papery knock with a little low thud
		var senv = EnvGen.ar(Env.perc(0.001, 0.04));
		var snp = ((BPF.ar(n, (f * 0.4).clip(200, 6000), 1) * 4)
			+ (Ringz.ar(Decay2.ar(Impulse.ar(0), 0.001, 0.004), 190, 0.06) * 0.03)) * senv * snap;
		var sig = LPF.ar(LPF.ar(flick + bed + snp, (f * 1.8).clip(1500, 14000)), 9000);
		^[sig * lvl, win.max(senv), dec]
	}

	// PRC1: a drop of water. A breath of noise rings a resonance that RISES
	// as it dies, the way a bubble does; SCATTER more, smaller drops over
	// WINDOW, SPREAD in pitch; SPLASH the hiss of it landing.
	*drop { arg t, pr, decm, g;
		var freq = t[0] * pr, dec = t[1] * decm;
		var rise = t[2], splash = t[3], scat = t[4], spread = t[5], win = t[6], lvl = t[7];
		var t0 = Impulse.ar(0);
		var n = WhiteNoise.ar;
		var exc = HPF.ar(n, 500) * Decay2.ar(t0, 0.0001, 0.0008);
		var fenv = EnvGen.ar(Env([1, 2 ** rise], [dec.max(0.005)], 3));
		var main = Ringz.ar(exc, (freq * fenv * (1 + (g * 0.2))).clip(50, 16000), dec);
		var open = EnvGen.ar(Env([1, 1, 0], [win, 0.001]));
		var sd = Dust.ar(scat.squared * 40) * open;
		var sp = 1 + (spread * 2);
		var sf = (freq * TExpRand.ar(sp.reciprocal, sp, sd)).clip(50, 16000);
		var scatter = Ringz.ar(HPF.ar(n, 500) * Decay2.ar(sd * TRand.ar(0.2, 0.7, sd), 0.0001, 0.0006), sf, dec * 0.7);
		var spl = HPF.ar(n, 3000) * EnvGen.ar(Env.perc(0.0003, 0.012)) * splash * 0.5;
		var env = EnvGen.ar(Env([0, 1, 1, 0], [0.001, win, dec]));
		var sig = (((main + (scatter * 0.6)) * 2.3).softclip) + spl;
		^[sig * lvl, env, win]
	}

	// PRC2: a music box tine plucked by noise. A tine is nearly a pure tone:
	// a breath BODY long rings its fundamental at PITCH, and BRIGHT is the
	// glassy ping of its upper mode (6.27 times up, inharmonic, gone in a
	// moment). STUTTER repeats it GAP apart, each repeat STEP semitones on
	// from the last, the way a cut-up loop steps. The repeats take turns on
	// two tines, so each note keeps ringing at its own pitch under the next
	// instead of being dragged up to it.
	*pluck { arg t, pr, decm, g;
		var freq = t[0] * pr, dec = t[1] * decm;
		var bright = t[2], body = t[3], stut = t[4], gap = t[5], step = t[6], lvl = t[7];
		var train = Engine_DrumDrum.stutter(stut, gap, 0.35);
		var k = (PulseCount.ar(train) - 1).max(0);
		var f = (freq * (1 + (g * 0.1)) * (2 ** ((k * step) / 12))).clip(30, 5000);
		var w = 0.0008 + (body * 0.006);
		var n = LPF.ar(PinkNoise.ar, 1500 + (bright * 5000));
		var even = (k % 2) < 0.5;
		var tine = [train * even, train * (1 - even)].collect { |tr|
			// held from its own trigger; Ringz reads its frequency once a
			// block, so before the first latch it must already be at PITCH
			var lt = Latch.ar(f, tr);
			var ft = Select.ar(lt > 1, [f, lt]).max(30);
			// a steady push with the breath on it: noise alone swings the
			// level a lot from note to note
			var exc = (1 + (n * 2)) * Decay2.ar(tr, w * 0.3, w) / (0.7 * w * SampleRate.ir);
			Ringz.ar(exc, ft, dec)
				+ (Ringz.ar(exc, (ft * 6.27).clip(30, 16000), (dec * 0.04).clip(0.005, 0.15)) * bright * 0.6)
		}.sum;
		var hold = (stut.round.max(1) - 1) * gap;
		var env = EnvGen.ar(Env([0, 1, 1, 0.001, 0], [0.001, hold, dec, 0.005], [2, 0, \exp, 0]));
		var sig = LPF.ar(tine, 9000) * 4.5;
		^[LeakDC.ar(sig) * lvl, env, 0.005 + hold]
	}

	// HAT: the clicks a cut sound file makes. A tick of noise at TONE, then
	// GRAINS more scattered over SPREAD, each at its own pitch; BITS and
	// RATE crush them; AIR a breath of hiss after, on DECAY.
	*ticks { arg t, pr, decm, g;
		var tone = t[0] * pr, dec = t[1] * decm;
		var grains = t[2], spread = t[3], bits = t[4], rate = t[5], air = t[6], lvl = t[7];
		var t0 = Impulse.ar(0);
		var span = 0.005 + (spread * 0.15);
		var d = Dust.ar(grains.squared * 400) * EnvGen.ar(Env([1, 1, 0], [span, 0.001]));
		var trig = t0 + (d * TRand.ar(0.15, 0.8, d));
		var n = WhiteNoise.ar;
		var tk = BPF.ar(n, (tone * (1 + (g * 0.1)) * TExpRand.ar(0.7, 1.4, trig)).clip(200, 18000), 1)
			* Decay2.ar(trig, 0.00005, 0.001);
		var aenv = Engine_DrumDrum.rcenv(0.0005, dec);
		var sig = (tk * 4) + (HPF.ar(n, (tone * 0.8).clip(200, 16000)) * aenv * air * 0.15);
		var q = 2 ** bits.clip(2, 16);
		sig = (Latch.ar(sig, Impulse.ar(SampleRate.ir * (0.5 ** (rate * 5)))) * q).round / q;
		^[sig * lvl, EnvGen.ar(Env([1, 1, 0], [span, dec])), span]
	}

	// CYM: a whisper. Breath through three vowel formants (VOWEL walks
	// A E I O U, PITCH moves them all), SWELLing in; SHIMMER a soft comb
	// that turns it glassy, CRACKLE ice, AIR the hiss on top. The formants
	// are wide, as a whisper's are: narrow ones whistle.
	*breath { arg t, pr, decm, g;
		var freq = t[0] * pr, dec = t[1] * decm;
		var swell = t[2], vowel = t[3], crack = t[4], shim = t[5], air = t[6], lvl = t[7];
		var env = EnvGen.ar(Env([0, 1, 0.001, 0], [swell, dec, 0.01], [2, \exp, 0]));
		var v = vowel.clip(0, 1) * 4, s = freq * (1 + (g * 0.2)) / 800;
		var f1 = SelectX.kr(v, [800, 400, 270, 450, 325]) * s;
		var f2 = SelectX.kr(v, [1150, 1600, 2300, 800, 700]) * s;
		var f3 = SelectX.kr(v, [2900, 2700, 3000, 2830, 2530]) * s;
		var n = PinkNoise.ar;
		var voice = BPF.ar(n, f1.clip(80, 12000), 0.4) + (BPF.ar(n, f2.clip(80, 12000), 0.35) * 0.5)
			+ (BPF.ar(n, f3.clip(80, 12000), 0.3) * 0.2);
		var hiss = LPF.ar(HPF.ar(n, 3500), 9000);
		var src = (voice * 7.5) + (hiss * air * 1.5);
		// the comb is fed and filtered dark, and rings short, so it glistens
		// rather than clangs
		var glass = LPF.ar(CombC.ar(LPF.ar(src, 3000), 0.05, (f2 * 0.5).reciprocal.clip(0.0002, 0.05), 0.2),
			4000) * shim * 0.35;
		var cd = Dust.ar(6 + (crack * 60));
		var cr = Decay2.ar(cd * TRand.ar(0.2, 1, cd), 0.0003, 0.0015) * BPF.ar(n, 4500, 1) * crack * 3;
		var sig = LPF.ar(((src + glass) * env) + (cr * env), 8000);
		^[sig * lvl, env, swell]
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
			// ANALOG: this hit's pitch (semitones), decay, level and
			// brightness, the strip's drift, and this unit's own tuning
			var an = \an.kr(0.5);
			var semi = (Rand(-1, 1) * 0.07) + In.kr(\drift.kr(60)) + rrand(-0.12, 0.12);
			var hdec = 1 + (Rand(-1, 1) * 0.12 * an);
			var hamp = 1 + (Rand(-1, 1) * 0.1 * an);
			var res = body.value(t, (pitch + (semi * an)).midiratio, decm * hdec, nz * ngrain);
			var syn = res[0], env = res[1], atk = res[2];
			var vk, vb, bright;
			var smp = Engine_DrumDrum.sampler(\buf.kr(0), \sstart.kr(0), sdec * decm,
				pitch + \spitch.kr(0), \stone.kr(0), satk, \srev.kr(0)) * slvl;
			// MIX: -1 is synth alone, +1 the sample alone, 0 both at full
			var sg = (1 - smix).clip(0, 1), mg = (1 + smix).clip(0, 1);
			var sig = (((syn + (nz * env * nlvl)) * sg) + (smp * mg)) * (vel ** 1.4) * hamp;
			var hold = atk + satk + 0.08;
			// the VCA: a biased tanh, unity slope at rest, so quiet hits pass
			// clean and loud ones round over, one half sooner than the other
			vk = 0.2 + (an * 1.1);
			vb = an * 0.14;
			sig = LeakDC.ar((((sig * vk) + vb).tanh - vb.tanh) / (vk * (1 - vb.tanh.squared)), 0.9995);
			// softer hits are darker, and no two are quite as bright
			bright = (20000 * ((0.4 + (vel * 0.6)) ** (an * 1.6)) * (1 + (Rand(-1, 1) * 0.15 * an)));
			sig = LPF.ar(sig, bright.clip(3000, 20000));
			// audio rate: a control-rate gate ramps up across the first block
			// (64 samples, 1.3 ms), which ate the front of every attack
			sig = sig * EnvGen.ar(Env.asr(0, 1, 0.012), gate, doneAction: 2);
			// a bad sample (NaN, inf, denormal) goes out as silence: one that
			// got into a strip would wedge its filters and, through the
			// returns and COLOUR, mute everything until a restart. It also
			// lets the silence detector free a voice that went bad.
			sig = Select.ar(CheckBadValues.ar(sig, 0, 0) > 0, [sig, DC.ar(0)]);
			DetectSilence.ar(sig.abs.max(Line.ar(1, 0, hold)), 0.0002, 0.12, doneAction: 2);
			Out.ar(out, sig);
		}).add;
	}

	*buildDefs {
		// the parts this unit was built from: the same every boot
		thisThread.randSeed = 808;
		Engine_DrumDrum.build(\dd_bd1, { |t, pr, d, g| Engine_DrumDrum.bd1(t, pr, d, g) });
		Engine_DrumDrum.build(\dd_bd2, { |t, pr, d, g| Engine_DrumDrum.bd2(t, pr, d, g) });
		Engine_DrumDrum.build(\dd_clp, { |t, pr, d, g| Engine_DrumDrum.clp(t, pr, d, g) });
		Engine_DrumDrum.build(\dd_snr, { |t, pr, d, g| Engine_DrumDrum.snr(t, pr, d, g) });
		Engine_DrumDrum.build(\dd_prc1, { |t, pr, d, g| Engine_DrumDrum.perc(t, pr, d, g) });
		Engine_DrumDrum.build(\dd_prc2, { |t, pr, d, g| Engine_DrumDrum.tom(t, pr, d, g) });
		// the old voices up to here rolled 12 parts; roll the seed back to
		// where they left it, so the hat, the cymbal and the WOOD and FM kits
		// keep exactly the parts they were built from before
		thisThread.randSeed = 808;
		12.do { rrand(-1.0, 1.0) };
		Engine_DrumDrum.build(\dd_hat, { |t, pr, d, g| Engine_DrumDrum.hat(t, pr, d, g) });
		Engine_DrumDrum.build(\dd_cym, { |t, pr, d, g| Engine_DrumDrum.cym(t, pr, d, g) });

		// WOOD and FM after WARM, so WARM's parts roll the same as before
		[
			[\dd_wbd1, \cajon], [\dd_wbd2, \slitlog], [\dd_wclp, \clapper], [\dd_wsnr, \cajonslap],
			[\dd_wprc1, \woodblock], [\dd_wprc2, \balafon], [\dd_what, \shaker], [\dd_wcym, \rainstick],
			[\dd_fbd1, \fkick], [\dd_fbd2, \fkick4], [\dd_fclp, \fclap], [\dd_fsnr, \fsnare],
			[\dd_fprc1, \ftom], [\dd_fprc2, \ftaiko], [\dd_fhat, \fhat], [\dd_fcym, \fcym],
			[\dd_gbd1, \hush], [\dd_gbd2, \heart], [\dd_gclp, \snow], [\dd_gsnr, \cards],
			[\dd_gprc1, \drop], [\dd_gprc2, \pluck], [\dd_ghat, \ticks], [\dd_gcym, \breath]
		].do { |e|
			Engine_DrumDrum.build(e[0], { |t, pr, d, g| Engine_DrumDrum.perform(e[1], t, pr, d, g) });
		};

		// ---- STRIP: one per track, always running ----
		// idx is the track, 1-8; sc is where it writes its envelope for the
		// sidechain, duck where it reads the DUCK's reduction back
		SynthDef(\dd_strip, { |in = 0, out = 0, meter = 0, dbus = 0, sbus = 0, idx = 0, sc = 0, duck = 0,
			drift = 60, level = 0.8, pan = 0, tilt = 0, drive = 0, warmth = 0.3, dsend = 0, ssend = 0,
			mute = 0, pmute = 0, hiss = 0.35|
			var lagt = 0.05;
			var sig = In.ar(in, 1);
			var dr = Lag.kr(drive, lagt), wm = Lag.kr(warmth, lagt), tl = Lag.kr(tilt, lagt);
			var dgain, dx, dy, mk, amp, st, dk, mt, hs;
			// the voices already guard their own output; this catches anything
			// else on the bus before it can wedge the filters below
			sig = Select.ar(CheckBadValues.ar(sig, 0, 0) > 0, [sig, DC.ar(0)]);

			// DRIFT, for this track's voices to read, in semitones: a slow
			// wander like a circuit warming and cooling, a little faster
			// flutter on top. The voices scale it by ANALOG.
			Out.kr(drift, (LFNoise2.kr(0.04 + (idx * 0.006)) * 0.22)
				+ (LFNoise1.kr(0.7 + (idx * 0.05)) * 0.025));

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

			// TILT: one knob leaning the spectrum around 700 Hz
			sig = BLowShelf.ar(sig, 700, 0.6, tl * -9);
			sig = BHiShelf.ar(sig, 700, 0.6, tl * 9);

			// the sidechain hears the track before its fader and after its
			// mute: the level does not change how hard it ducks, a mute stops it.
			// PMUTE is the PERFORM page's DROP, a mute of its own so it never
			// touches the one you set
			mt = Lag.kr((1 - mute) * (1 - pmute), 0.01);
			Out.kr(sc, Amplitude.kr(sig * mt, 0.001, 0.02));
			dk = In.kr(duck, 3);
			amp = Lag.kr(level.squared * 1.5, 0.02) * mt * (1 - (dk[0] * ((dk[2] - idx).abs > 0.5)));
			// VCA HISS: under the fader, so it rides the level, the duck and
			// the mute. Mostly white with the extremes rolled off, about
			// -80 dB at the default.
			hs = LPF.ar(HPF.ar(WhiteNoise.ar + (PinkNoise.ar * 0.6), 250), 13000);
			sig = sig + (hs * Lag.kr(hiss, 0.1).squared * 0.0011);
			sig = sig * amp;
			Out.kr(meter, Amplitude.kr(sig, 0.005, 0.25));
			st = Pan2.ar(sig, Lag.kr(pan, lagt));
			Out.ar(out, st);

			// SENDS: after the fader, the pan and the mute, so a muted track's
			// tail rings out in the space rather than stopping dead. Squared,
			// so the bottom half of the knob is the fine end.
			Out.ar(dbus, st * Lag.kr(dsend, lagt).squared);
			Out.ar(sbus, st * Lag.kr(ssend, lagt).squared);
		}).add;

		// ---- DELAY: shared by every track ----
		// a tape-ish stereo echo. TONE closes a lowpass inside the loop so
		// every repeat is darker than the last, the loop saturates softly so
		// FEEDBACK past 100% blooms rather than explodes, and PING puts the
		// input in on the left and crosses each repeat to the other side.
		// TIME glides when it changes, the way a tape delay's does.
		SynthDef(\dd_delay, { |in = 0, out = 0, duck = 0, dtime = 0.375, fdbk = 0.35, dtone = 3500,
			ping = 0.6, dret = 0.8|
			var lagt = 0.08;
			var x = In.ar(in, 2);
			var p = Lag.kr(ping, lagt), fb = Lag.kr(fdbk, lagt);
			var mono = (x[0] + x[1]) * 0.5;
			var src = [(x[0] * (1 - p)) + (mono * p), x[1] * (1 - p)];
			var back = LocalIn.ar(2);
			var cross = [(back[0] * (1 - p)) + (back[1] * p), (back[1] * (1 - p)) + (back[0] * p)];
			// the loop already costs a block, so the delay is a block short of TIME
			var dt = (Lag.kr(dtime, 0.25) - ControlDur.ir + (LFNoise2.kr(0.4) * 0.0003))
				.clip(0.002, 2.9);
			var d = DelayC.ar(src + (cross * fb), 3, dt);
			d = LPF.ar(d, Lag.kr(dtone, lagt).clip(200, 18000));
			d = HPF.ar(d, 60);
			d = (d * 0.8).tanh * 1.25;
			LocalOut.ar(d);
			Out.ar(out, d * Lag.kr(dret, lagt) * (1 - In.kr(duck + 1)));
		}).add;

		// ---- SPRING: shared by every track ----
		// a three-spring tank, after Parker and Valimaki's dispersive model.
		// A spring is a waveguide that carries low frequencies SLOWER than
		// high ones, so every echo arrives as a falling chirp -- the drip --
		// and the echoes come back round every few tens of milliseconds as
		// the wave runs end to end. Each spring here is a loop of:
		//
		//   a cascade of stretched allpasses  the dispersion: each one is
		//                       (a + z^-K) / (1 + a z^-K), so below fs/2K
		//                       the lows are held back more than the highs.
		//                       DRIP is a: how far the lows lag, how long
		//                       and how wet the chirp is
		//   a lowpass           TONE, which also takes out the images the
		//                       stretch puts above fs/2K
		//   a delay             the rest of the transit, wobbling a little
		//                       the way a spring swings in its can
		//
		// The springs are three lengths, so their echoes never line up.
		// DWELL is the drive into the tank's input transducer, as on a
		// Fender: more of it is louder, longer and dirtier. The lows are
		// taken out first because a spring cannot hold them anyway, and the
		// kick going in is what makes a real one crash.
		SynthDef(\dd_spring, { |in = 0, out = 0, duck = 0, sdecay = 2.2, stone = 3800,
			dwell = 0.4, drip = 0.5, sret = 0.8|
			var lagt = 0.1;
			var x = In.ar(in, 2);
			var dw = Lag.kr(dwell, lagt);
			var a = Lag.kr(drip, lagt).linlin(0, 1, 0.35, 0.82);
			var nap = 30;
			// K = 4 at 48k: the chirp lives below 6 kHz, where a spring's does
			var apd = 4 / SampleRate.ir;
			// AllpassN is (z^-K - g) / (1 - g z^-K) with g set by a decay
			// time, so a positive decay time is a negative coefficient: the
			// sign that holds the LOWS back, the way a spring does
			var apdec = apd * -6.907755 / a.log;
			var tone = Lag.kr(stone, lagt).clip(300, 9000);
			var dec = Lag.kr(sdecay, lagt).max(0.1);
			// the allpasses' delay at the middle of the band, which is part
			// of each spring's transit as far as the decay is concerned
			var disp = nap * apd * 0.5 * (1 + a) / (1 - a);
			var drv = 1 + (dw.squared * 12);
			var lens = [0.0367, 0.0431, 0.0503];
			var ins, back, outs, l, r;

			x = HPF.ar(HPF.ar(x, 170), 170);
			x = LPF.ar(x, 5500);
			x = (x * drv).tanh * drv.sqrt.reciprocal * 1.6;
			ins = [x[0], (x[0] + x[1]) * 0.5, x[1]];
			back = LocalIn.ar(3);
			outs = 3.collect { |k|
				var len = lens[k];
				// the loop costs a block already
				var dt = (len * (1 + (LFNoise2.kr(0.37 + (k * 0.21)) * 0.004))) - ControlDur.ir;
				var g = 0.001 ** ((len + disp) / dec);
				var v = ins[k] + (back[k] * g);
				nap.do { v = AllpassN.ar(v, 0.0002, apd, apdec) };
				v = LPF.ar(v, tone);
				v = LPF.ar(v, (tone * 1.5).min(12000));
				v = HPF.ar(v, 90);
				// the steel saturates a little when it is driven hard
				v = (v * 0.6).tanh * 1.6667;
				DelayC.ar(v, 0.1, dt)
			};
			LocalOut.ar(outs);
			// the middle spring in both sides, the outer two one each
			l = outs[0] + (outs[1] * 0.6);
			r = outs[2] + (outs[1] * 0.6);
			Out.ar(out, [l, r] * 0.55 * Lag.kr(sret, lagt) * (1 - In.kr(duck + 1)));
		}).add;

		// ---- DUCK: the sidechain ----
		// every strip writes its own envelope (before the fader, after the
		// mute) to a control bus; this picks the SOURCE track's and turns it
		// into a gain reduction for the other seven strips and, by FX, for
		// the delay and spring returns. It runs after the strips, so a strip
		// hears the duck a block late: about a millisecond, nothing to hear.
		// It writes reductions, not gains, so a bus nobody writes is no duck.
		//   out + 0  reduction for the strips (0 none, 1 silence)
		//   out + 1  reduction for the returns
		//   out + 2  the source track, 1-8, 0 off: that strip does not duck
		SynthDef(\dd_duck, { |sc = 0, out = 0, scsrc = 0, scamt = 0, screl = 0.25, scfx = 0.5|
			var on = scsrc > 0;
			var env = Select.kr((scsrc - 1).clip(0, 7), In.kr(sc, 8)) * on;
			// AMOUNT is depth in dB: all the way is -30 dB on a full hit
			var db = (env * 3).clip(0, 1) * Lag.kr(scamt, 0.05) * -30;
			// down fast, back up over RELEASE
			var g = LagUD.kr(db.dbamp, Lag.kr(screl, 0.05), 0.004);
			var red = 1 - g;
			Out.kr(out, [red, red * Lag.kr(scfx, 0.05), scsrc]);
		}).add;

		// ---- PERFORM: the punch-ins ----
		// Each one lives only while its pad is held: it reads the mix bus,
		// replaces what is on it, and frees itself once let go. All of them
		// fade in and out over a few milliseconds, so a punch never clicks.
		// Lua works every time out from the tempo and sends seconds, as the
		// generic a b c d; each def says what its four mean. They sit after
		// the returns and before COLOUR, so the buss, the texture and the
		// limiter are still the last word.
		//
		// The loop and tape-stop punch-ins play back the TAPE RECORDER: the
		// mix written into a 30 second ring buffer all the time, with its
		// write position on a control bus so a punch knows where "now" is.
		// A reader starts a block behind the write head (LAT), which nobody
		// can hear and keeps the interpolation off samples not yet written.

		SynthDef(\dd_rec, { |in = 0, buf = 0, pos = 0|
			var ph = Phasor.ar(0, 1, 0, BufFrames.kr(buf));
			BufWr.ar(In.ar(in, 2), buf, ph);
			Out.kr(pos, A2K.kr(ph));
		}).add;

		// The SAMPLER's recorder (hold S1, tap a step). While armed it
		// writes its source into a ring all the time, so a take can begin a
		// moment BEFORE the hit that started it. src: 0 inputs L+R, 1 L,
		// 2 R, 3 the mix as you hear it, 4 one track's voices (tbus). With
		// det on, the first time the level crosses thr it reports where the
		// ring was, and sclang takes it from there (see sampBegin).
		SynthDef(\dd_samp, { |inl = 0, inr = 0, mix = 0, tbus = 0, src = 0, buf = 0,
				pos = 0, lvl = 0, det = 0, thr = 0.03|
			var l = In.ar(inl), r = In.ar(inr), m = In.ar(mix, 2);
			var sig = Select.ar(src.clip(0, 4),
				[(l + r) * 0.5, l, r, (m[0] + m[1]) * 0.5, In.ar(tbus)]);
			var ph = Phasor.ar(0, 1, 0, BufFrames.kr(buf));
			var amp = Amplitude.ar(sig, 0.0002, 0.08);
			BufWr.ar(sig, buf, ph);
			Out.kr(pos, A2K.kr(ph));
			Out.kr(lvl, Amplitude.kr(sig, 0.005, 0.25));
			SendReply.ar(Trig1.ar((amp > thr) * (det > 0.5), 0.5), '/dd_samp_hit', ph);
		}).add;

		// LOOP: a = how far back from the press the loop starts (s), b = its
		// length (s), c = where in it playback begins (s), d = rate, negative
		// for reverse. REPEAT starts it on the last grid line with c the time
		// since that line, so the first pass IS the live mix and only then
		// does it come round. The hidden TAPE loops the last LENGTH and
		// varispeeds it, gliding between rates the way tape does. Each pass
		// is windowed over 3 ms where it wraps.
		SynthDef(\dd_pf_loop, { |bus = 0, buf = 0, pos = 0, gate = 1, a = 0, b = 0.5, c = 0, d = 1|
			var sr = SampleRate.ir, frames = BufFrames.kr(buf);
			var p0 = Latch.kr(In.kr(pos), Impulse.kr(0));
			var len = (Lag.kr(b, 0.05).max(0.005) * sr);
			var rate = Lag.kr(d, 0.12);
			var ph = (Sweep.ar(0, sr * rate) + (c * sr)).wrap(0, len);
			var base = p0 - (Lag.kr(a, 0.05) * sr) - 64;
			var fade = 0.003 * sr;
			var win = (ph / fade).min((len - ph) / fade).clip(0, 1);
			var wet = BufRd.ar(2, buf, (base + ph).wrap(0, frames), 1, 4) * win;
			var dry = In.ar(bus, 2);
			var env = EnvGen.kr(Env.asr(0.004, 1, 0.012), gate, doneAction: 2);
			ReplaceOut.ar(bus, (dry * (1 - env)) + (wet * env));
		}).add;

		// STOP: tape stop and spin-back. The read head starts on the write
		// head and its speed goes from 1 to b over a seconds: b = 0 is a
		// tape stop, 0.5 a drop to half speed, below 0 a spin-back. Slower
		// than the write head it falls behind it, so this is the live mix
		// slowing down, not a loop. The top closes as it slows, and it fades
		// out as it stops so nothing is left hanging on one sample.
		SynthDef(\dd_pf_stop, { |bus = 0, buf = 0, pos = 0, gate = 1, a = 0.5, b = 0|
			var sr = SampleRate.ir, frames = BufFrames.kr(buf);
			var p0 = Latch.kr(In.kr(pos), Impulse.kr(0));
			var rate = EnvGen.ar(Env([1, b], [a.max(0.01)], -3));
			var idx = (p0 - 64 + Sweep.ar(0, sr * rate)).wrap(0, frames);
			var amp = Select.ar(b < 0, [
				(rate.abs * 3).clip(0, 1),
				EnvGen.ar(Env([1, 1, 0], [a * 0.3, a * 0.7], -2))
			]);
			var wet = BufRd.ar(2, buf, idx, 1, 4);
			var dry = In.ar(bus, 2);
			var env = EnvGen.kr(Env.asr(0.004, 1, 0.012), gate, doneAction: 2);
			wet = LPF.ar(wet, (rate.abs * 18000).clip(150, 20000)) * amp;
			ReplaceOut.ar(bus, (dry * (1 - env)) + (wet * env));
		}).add;

		// GATE: chops the mix on the beat grid. a = a chop's length in
		// beats, b = the length of a beat (s), c = where in the bar the press
		// landed (beats), d = how much of each chop is open. Counted from
		// the bar, so a new a while held stays on the grid.
		SynthDef(\dd_pf_gate, { |bus = 0, gate = 1, a = 0.25, b = 0.5, c = 0, d = 0.5|
			var beats = c + Sweep.ar(0, b.reciprocal);
			var open = Lag.ar(((beats / a).frac < d), 0.0015);
			var dry = In.ar(bus, 2);
			var env = EnvGen.kr(Env.asr(0.004, 1, 0.012), gate, doneAction: 2);
			ReplaceOut.ar(bus, dry * (1 - (env * (1 - open))));
		}).add;

		// CRUSH: a = bits, b = sample rate (Hz)
		SynthDef(\dd_pf_crush, { |bus = 0, gate = 1, a = 8, b = 8000|
			var dry = In.ar(bus, 2);
			var q = 2 ** (Lag.kr(a, 0.02) - 1);
			var wet = Latch.ar(dry, Impulse.ar(Lag.kr(b, 0.02)));
			var env = EnvGen.kr(Env.asr(0.004, 1, 0.012), gate, doneAction: 2);
			wet = (wet * q).round / q;
			ReplaceOut.ar(bus, (dry * (1 - env)) + (wet * env * 0.9));
		}).add;

		// LOWPASS / HIGHPASS: a = cutoff (Hz), b = rq. A press sweeps in from
		// wide open; a new cutoff while held glides there.
		SynthDef(\dd_pf_lpf, { |bus = 0, gate = 1, a = 1000, b = 0.4|
			var f = Lag.kr(a, 0.1);
			var fc = f * ((20000 / f) ** EnvGen.kr(Env([1, 0], [0.15], -3)));
			var dry = In.ar(bus, 2);
			var env = EnvGen.kr(Env.asr(0.004, 1, 0.03), gate, doneAction: 2);
			var wet = RLPF.ar(dry, fc.clip(30, 20000), b);
			ReplaceOut.ar(bus, (dry * (1 - env)) + (wet * env));
		}).add;

		SynthDef(\dd_pf_hpf, { |bus = 0, gate = 1, a = 1000, b = 0.4|
			var f = Lag.kr(a, 0.1);
			var fc = f * ((20 / f) ** EnvGen.kr(Env([1, 0], [0.15], -3)));
			var dry = In.ar(bus, 2);
			var env = EnvGen.kr(Env.asr(0.004, 1, 0.03), gate, doneAction: 2);
			var wet = RHPF.ar(dry, fc.clip(20, 18000), b);
			ReplaceOut.ar(bus, (dry * (1 - env)) + (wet * env));
		}).add;

		// ECHO: a dub throw. While held the mix goes into a ping-pong echo;
		// let go and the input closes but the echoes ring on, fading over c
		// seconds before the synth frees. a = time (s), b = feedback.
		SynthDef(\dd_pf_echo, { |bus = 0, gate = 1, a = 0.25, b = 0.6, c = 4|
			var dry = In.ar(bus, 2);
			var life = EnvGen.kr(Env.asr(0, 1, c, -4), gate, doneAction: 2);
			var send = EnvGen.kr(Env.asr(0.003, 1, 0.01), gate);
			var fb = LocalIn.ar(2);
			var mono = (dry[0] + dry[1]) * 0.5 * send;
			var d = DelayC.ar([mono + (fb[1] * b), fb[0] * b], 2, (a - ControlDur.ir).clip(0.005, 1.95));
			d = LPF.ar(HPF.ar(d, 220), 5000);
			d = (d * 0.9).tanh / 0.9;
			LocalOut.ar(d);
			ReplaceOut.ar(bus, dry + (d * life));
		}).add;

		// ---- COLOUR: the master ----
		// BUSS, after Ableton's Drum Buss:
		//   comp > drive > crunch > damp > transients > boom, then MIX
		// then Pappus' colour stage: tilt > loss > envelope-following
		// noise > wow, then a chorus and the level, always wet; BYPASS is
		// the way out.
		SynthDef(\dd_colour, { |in = 0, out = 0, ampBus = 0,
			drive = 0, drivetype = 1, crunch = 0, bussdamp = 20000, trans = 0, comp = 0,
			boom = 0, boomfreq = 55, boomdecay = 0.4, ctilt = 0, bussmix = 1,
			loss = 0, wow = 0, noise = 0, noisetype = 2, noisedecay = 0.25, noisetone = 1200,
			chorus = 0, chrate = 0.5, chdepth = 0.5, chbbd = 0.3,
			outlvl = 1, bypass = 0|
			var lagt = 0.08, envref = 0.25;
			var dry = In.ar(in, 2);
			var sig = dry;
			var dr = Lag.kr(drive, lagt), cn = Lag.kr(crunch, lagt), tr = Lag.kr(trans, lagt);
			var cp = Lag.kr(comp, lagt), bm = Lag.kr(boom, lagt), bmix = Lag.kr(bussmix, lagt);
			var ls = Lag.kr(loss, lagt).clip(0, 1), ns = Lag.kr(noise, lagt);
			var kw = Lag.kr(wow, lagt).clip(0, 1);
			var tl = Lag.kr(ctilt, lagt);
			var dtype = (drivetype - 1).clip(0, 2);
			var env, mono, cthr, cslope, dg, half, sx, soft, mx, med, hx, hard, shaped;
			var lo, hi, cg, chi, tlo, thi, tmono, fast, slow, att, pres, gdb;
			var bf, brq, bsrc, bring;
			var lmono, lchain, lthr, lossmono, ldry, lmix, lon, nwash, kwd, kwf, kwm;
			var cm, cb, cdt, cwet, cgn;
			var outsig;

			env = Amplitude.ar((dry[0] + dry[1]) * 0.5, 0.002, Lag.kr(noisedecay, lagt)).clip(0, 1);
			env = (envref * ((env / envref).max(0) ** 2)).clip(0, 1);

			// ---- COMP ----
			// one knob, the way Drum Buss has one button: a fast peak
			// compressor whose threshold falls and ratio climbs together
			// (-21 dB at 6:1 at the top), with most of the level made back
			mono = (sig[0] + sig[1]) * 0.5;
			cthr = 0.5 ** (cp * 3.5);
			cslope = (1 + (cp * 5)).reciprocal;
			sig = Compander.ar(sig, mono, cthr, 1, cslope, 0.001, 0.12)
				* (cthr.reciprocal ** ((1 - cslope) * 0.7));

			// ---- DRIVE ----
			// three circuits, each with makeup fitted so a peak at -9 dB
			// stays there: turning DRIVE mostly changes density, and the mix
			// gets a few dB louder over the knob, not ten.
			//   SOFT    waveshaping: a biased tanh, so the halves round off
			//           differently and a little second harmonic comes up
			//   MEDIUM  limiting: a hard-kneed limiter after a lift at 2.4k,
			//           so the high mids push into it first
			//   HARD    clipping after a low shelf, so the low end hits it
			dg = 1 + (dr.squared * 30);
			half = dg * 0.36;
			sx = sig * dg;
			soft = ((sx + 0.15).tanh - 0.15.tanh) * (0.36 / ((half + 0.15).tanh - 0.15.tanh));
			mx = BPeakEQ.ar(sig, 2400, 0.9, dr * 7) * dg;
			med = (mx / (((mx.abs ** 4) + 1) ** 0.25)) * (0.36 / (half / (((half ** 4) + 1) ** 0.25)));
			hx = BLowShelf.ar(sig, 110, 1, dr * 9) * dg;
			hard = hx.clip2(1) * (0.36 / half.min(1));
			shaped = 2.collect { |c| Select.ar(dtype, [soft[c], med[c], hard[c]]) };
			shaped = LPF.ar(LeakDC.ar(shaped), (18000 - (dr * 6000)) * (1 - (dtype * 0.1)));
			sig = XFade2.ar(sig, shaped, ((dr * 4).clip(0, 1) * 2) - 1);

			// ---- CRUNCH ----
			// sine-shaped distortion on the mid-highs only: split at 1.4k,
			// the top half through a sine shaper that folds over a little
			// past its peak, the bottom left alone
			lo = LPF.ar(LPF.ar(sig, 1400), 1400);
			hi = sig - lo;
			cg = 1 + (cn.squared * 16);
			chi = (hi * cg).clip2(2.2).sin * (0.25 / (cg * 0.25).clip(0, 1.5).sin);
			sig = lo + XFade2.ar(hi, chi, (cn.sqrt * 2) - 1);

			// ---- DAMP ----
			sig = LPF.ar(sig, Lag.kr(bussdamp, lagt).clip(200, 20000));

			// ---- TRANSIENTS ----
			// above 100 Hz. A fast envelope over a slow one finds the
			// attack; either way round TRANS adds attack, then positive
			// lifts what follows (fuller) and negative takes it away
			// (tighter, less room and rattle)
			tlo = LPF.ar(LPF.ar(sig, 100), 100);
			thi = sig - tlo;
			tmono = (thi[0] + thi[1]) * 0.5;
			fast = Amplitude.ar(tmono, 0.0005, 0.03);
			slow = Amplitude.ar(tmono, 0.02, 0.3);
			att = ((fast + 0.0003) / (slow + 0.0003)).ampdb.clip(0, 18);
			pres = (slow * 30).clip(0, 1);
			gdb = (att * tr.abs * 0.5) + (tr * 5 * (1 - (att / 6).clip(0, 1)) * pres);
			sig = tlo + (thi * gdb.clip(-18, 14).dbamp);

			// ---- BOOM ----
			// a resonator at FREQ that every hit's low end rings, ringing
			// for DECAY, soft-limited so a long one cannot run away
			bf = Lag.kr(boomfreq, 0.1);
			brq = (2.2 / (Lag.kr(boomdecay, 0.1) * bf)).clip(0.005, 1);
			bsrc = LPF.ar(LPF.ar((sig[0] + sig[1]) * 0.5, bf * 3), bf * 3);
			bring = (Resonz.ar(bsrc, bf, brq) * bm.squared * 12).tanh * 0.4;
			sig = sig + bring;

			// ---- MIX ----
			sig = (dry * (1 - bmix)) + (sig * bmix);

			// ---- TILT ----
			sig = BLowShelf.ar(sig, 900, 0.7, tl * -6);
			sig = BHiShelf.ar(sig, 900, 0.7, tl * 6);

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
			// FFT > IFFT comes out one window less one control block late
			// (448 samples at 512 / 64), measured. Delaying the dry side a
			// whole window left it 64 samples (1.3 ms) off, a comb with
			// notches every 750 Hz: LOSS flanged where the two blend evenly.
			// DelayN rounds to a whole sample and an exact 448 sits on the
			// edge (it came out 447; asking 449 gave 450), so ask for half a
			// sample more: with nothing thrown away the blend nulls to -135 dB
			ldry = DelayN.ar(sig, 0.05, (512 - BlockSize.ir + 0.5) / SampleRate.ir);
			lmix = (ls * 1.6).clip(0, 1);
			// that alignment is 9.3 ms of latency on everything, so with LOSS
			// at zero the stage is left out altogether: the undelayed signal,
			// crossfaded in and out as LOSS leaves and comes back to zero
			lon = Lag.kr(loss > 0, 0.05);
			sig = (sig * (1 - lon))
				+ (((ldry * (1 - lmix)) + ([lossmono, lossmono] * lmix)) * lon);

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

			// ---- CHORUS ----
			// after the Juno's: each side through a bucket-brigade delay of a
			// few milliseconds swept by a triangle, left and right swept the
			// opposite way, so it widens as it thickens. DEPTH is how far it
			// sweeps, RATE how fast. BBD is how much of the bucket brigade
			// comes with it: the top rolling off, its compander rounding the
			// peaks, a breath of clock hiss. CHORUS all the way is half and
			// half, as the Juno's is.
			cm = Lag.kr(chorus, lagt);
			cb = Lag.kr(chbbd, lagt);
			cdt = 0.0035 + (LFTri.kr(Lag.kr(chrate, lagt), [0, 2]) * Lag.kr(chdepth, lagt) * 0.0025);
			cwet = DelayC.ar(sig, 0.01, cdt);
			cwet = LPF.ar(LPF.ar(cwet, 14000 * (0.22 ** cb)), 14000 * (0.22 ** cb));
			cgn = 1 + (cb * 2);
			cwet = ((cwet * cgn).tanh / cgn.tanh) + (PinkNoise.ar([1, 1]) * cb * 0.0015);
			sig = sig + ((cwet - sig) * cm * 0.5);

			outsig = sig * Lag.kr(outlvl, lagt);
			outsig = [
				Select.ar(bypass, [outsig[0], dry[0]]),
				Select.ar(bypass, [outsig[1], dry[1]])
			];
			// a safety, not a sound: Limiter delays by twice its window, so a
			// 1 ms window keeps it to 2 ms (10 ms was 20 ms late)
			outsig = Limiter.ar(outsig, 0.95, 0.001);
			Out.kr(ampBus, Amplitude.kr((outsig[0] + outsig[1]) * 0.5, 0.01, 0.2));
			Out.ar(out, outsig);
		}).add;
	}

	// ---------------------------------------------------------------- alloc

	alloc {
		var s = context.server;

		Engine_DrumDrum.buildDefs;

		tBus = Array.fill(nTracks, { Bus.audio(s, 1) });
		driftBus = Bus.control(s, nTracks);
		mixBus = Bus.audio(s, 2);
		dlyBus = Bus.audio(s, 2);
		sprBus = Bus.audio(s, 2);
		posBus = Bus.control(s, 1);
		meterBus = Bus.control(s, nTracks);
		ampBus = Bus.control(s, 1);
		scBus = Bus.control(s, nTracks);
		duckBus = Bus.control(s, 3);
		mlast = Array.fill(nTracks, { 0 });

		voiceGroup = Group.new(context.xg, \addToHead);
		stripGroup = Group.after(voiceGroup);
		fxGroup = Group.after(stripGroup);
		perfGroup = Group.after(fxGroup);
		colourGroup = Group.after(perfGroup);
		sGroup = Group.after(colourGroup);   // last: MIX is what you hear

		blank = Buffer.alloc(s, 2, 1);
		bufs = Array.fill(nTracks, { blank });
		args = Array.fill(nTracks, { IdentityDictionary.new });
		live = Array.fill(nTracks, { List.new });
		kits = Array.fill(nTracks, { 0 });
		tape = Buffer.alloc(s, (s.sampleRate ? 48000) * 30, 2);
		// 20 seconds of take, and room either side for the pre-roll
		sRing = Buffer.alloc(s, (s.sampleRate ? 48000) * 22, 1);
		sPosBus = Bus.control(s, 1);
		sLvlBus = Bus.control(s, 1);
		s.sync;
		sSynth = Synth.newPaused(\dd_samp, [\inl, context.in_b[0].index,
			\inr, context.in_b[1].index, \mix, context.out_b.index,
			\tbus, tBus[0].index, \buf, sRing.bufnum,
			\pos, sPosBus.index, \lvl, sLvlBus.index], sGroup);
		sHitFunc = OSCFunc({ |msg|
			if (sState == 2) {
				// 10 ms before the crossing: the attack that tripped it
				this.sampBegin((msg[3] - (s.sampleRate * 0.01)).wrap(0, sRing.numFrames), sDur);
			};
		}, '/dd_samp_hit', s.addr);
		punches = Array.newClear(8);
		tails = List.new;

		s.sync;

		strips = nTracks.collect { |i|
			Synth(\dd_strip, [\in, tBus[i].index, \out, mixBus.index,
				\meter, meterBus.index + i, \dbus, dlyBus.index, \sbus, sprBus.index,
				\idx, i + 1, \sc, scBus.index + i, \duck, duckBus.index,
				\drift, driftBus.index + i],
				stripGroup, \addToTail)
		};
		// the DUCK first in the fx group: after every strip, before the returns
		duckS = Synth(\dd_duck, [\sc, scBus.index, \out, duckBus.index], fxGroup);
		delayS = Synth(\dd_delay, [\in, dlyBus.index, \out, mixBus.index,
			\duck, duckBus.index], fxGroup, \addToTail);
		springS = Synth(\dd_spring, [\in, sprBus.index, \out, mixBus.index,
			\duck, duckBus.index], fxGroup, \addToTail);
		// the recorder first, then the stages in signal order
		recS = Synth(\dd_rec, [\in, mixBus.index, \buf, tape.bufnum, \pos, posBus.index], perfGroup);
		stages = 8.collect { Group.tail(perfGroup) };
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
		syn = Synth(defs[kits[t]][t], args[t].getPairs ++ [
			\out, tBus[t].index, \vel, vel, \pitch, pitch, \decm, decm, \smix, smix,
			\buf, bufs[t].bufnum, \an, analog, \drift, driftBus.index + t
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

		// strip(track, name, value): level pan tilt mute drive warmth dsend rsend
		this.addCommand(\strip, "isf", { |msg|
			var t = msg[1].asInteger;
			if (t >= 0 and: { t < nTracks }) { strips[t].set(msg[2].asSymbol, msg[3]) };
		});

		this.addCommand(\colour, "sf", { |msg|
			colourS.set(msg[1].asSymbol, msg[2]);
		});

		// duck(name, value): scsrc (0 off, 1-8 a track) scamt screl scfx
		this.addCommand(\duck, "sf", { |msg|
			duckS.set(msg[1].asSymbol, msg[2]);
		});

		// fx(name, value): the delay's and the spring's names do not overlap,
		// so both hear every message and each takes its own
		this.addCommand(\fx, "sf", { |msg|
			delayS.set(msg[1].asSymbol, msg[2]);
			springS.set(msg[1].asSymbol, msg[2]);
		});

		// kit(track, kit): 0 WARM, 1 WOOD, 2 FM, 3 GLITCH, from the track's next hit.
		// A voice still ringing on the old kit rings out.
		this.addCommand(\kit, "ii", { |msg|
			var t = msg[1].asInteger;
			if (t >= 0 and: { t < nTracks }) { kits[t] = msg[2].asInteger.clip(0, defs.size - 1) };
		});

		// analog(amount): tolerance, drift, per-hit variance and VCA bend,
		// 0 to 1. Takes effect from the next hit.
		this.addCommand(\analog, "f", { |msg| analog = msg[1] });

		// hiss(amount): every strip's VCA hiss, 0 to 1
		this.addCommand(\hiss, "f", { |msg| strips.do { |st| st.set(\hiss, msg[1]) } });

		// punch(stage, def, a, b, c, d): start a punch-in on a stage, letting
		// go of whatever that stage was playing. def is the dd_pf_ name.
		// The stages run in this order, whatever order they were pressed in:
		//   0 REPEAT  1 SPEED  2 TAPE  3 GATE  4 CRUSH  5 LOWPASS  6 HIGHPASS  7 ECHO
		this.addCommand(\punch, "isffff", { |msg|
			var st = msg[1].asInteger;
			if (st >= 0 and: { st < stages.size }) {
				this.unpunch(st);
				punches[st] = Synth(("dd_pf_" ++ msg[2]).asSymbol, [\bus, mixBus.index,
					\buf, tape.bufnum, \pos, posBus.index,
					\a, msg[3], \b, msg[4], \c, msg[5], \d, msg[6]], stages[st], \addToTail);
			};
		});

		// punchSet(stage, a, b, c, d): move the stage's sounding punch-in
		this.addCommand(\punchSet, "iffff", { |msg|
			var n = punches[msg[1].asInteger.clip(0, 7)];
			if (n.notNil) { n.set(\a, msg[2], \b, msg[3], \c, msg[4], \d, msg[5]) };
		});

		// unpunch(stage): let go
		this.addCommand(\unpunch, "i", { |msg| this.unpunch(msg[1].asInteger) });

		// ---- the SAMPLER (lib/sampler). A take is written to `path`, and
		// lua loads it onto the track like any other file once sDone moves.
		//
		// sampArm(src, track, threshold, path): the recorder on, writing
		// its ring, not yet taking. Again while armed, it moves the source.
		this.addCommand(\sampArm, "iifs", { |msg|
			var src = msg[1].asInteger.clip(0, 4);
			var tb = tBus[msg[2].asInteger.clip(0, nTracks - 1)].index;
			if (sState < 3) {
				sPath = msg[4].asString;
				sSynth.set(\src, src, \tbus, tb, \thr, msg[3]);
				sSynth.run(true);
				if (sState < 1) { sState = 1 };
			};
		});
		// sampListen(seconds): take that long from the next hit
		this.addCommand(\sampListen, "f", { |msg|
			if (sState == 1 or: { sState == 2 }) {
				sDur = msg[1].clip(0.01, 20);
				sState = 2;
				sSynth.set(\det, 1);
			};
		});
		// sampStart(seconds): take that long from now
		this.addCommand(\sampStart, "f", { |msg|
			if (sState == 1 or: { sState == 2 }) {
				this.sampBegin(sPosBus.getSynchronous, msg[1]);
			};
		});
		// sampStop: end the take early, and keep it
		this.addCommand(\sampStop, "", { |msg| this.sampFinish(sGen) });
		// sampCancel: no take; a take being written still lands
		this.addCommand(\sampCancel, "", { |msg|
			if (sState < 4) { this.sampOff };
		});

		this.addCommand(\panic, "", { |msg|
			live.do { |l| l.do { |n| n.set(\gate, 0) }; l.clear };
		});
	}

	// A punch-in that is let go of fades (an echo rings on) and frees
	// itself. Only a few tails are kept: hammering ECHO must not pile up
	// delay lines until the server runs out of memory.
	unpunch { arg st;
		var n;
		if (st < 0 or: { st >= punches.size }) { ^nil };
		n = punches[st];
		if (n.isNil) { ^nil };
		punches[st] = nil;
		n.set(\gate, 0);
		tails.add(n);
		n.onFree({ tails.remove(n) });
		while { tails.size > 4 } { tails.removeAt(0).free };
	}

	// ------------------------------------------------------------ sampler

	// The recorder is one synth for the engine's life, paused while
	// nothing is armed. Paused, its Phasor holds where it was and so does
	// the position bus, so a take started the moment it wakes is measured
	// from the right place -- a new synth would start at 0 under a bus
	// still saying where the last one stopped.
	sampOff {
		sGen = sGen + 1;
		sSynth.set(\det, 0);
		sSynth.run(false);
		sState = 0;
	}

	// a take from frame `start` of the ring, `dur` seconds long
	sampBegin { arg start, dur;
		var gen;
		sGen = sGen + 1;
		gen = sGen;
		sSynth.set(\det, 0);
		sStart = start.asInteger;
		sDur = dur.clip(0.01, 20);
		sT0 = Main.elapsedTime;
		sState = 3;
		SystemClock.sched(sDur, { this.sampFinish(gen); nil });
	}

	// Copy the take out of the ring (round the end if it wraps), bring it
	// up to just under full scale, round off both ends so it neither
	// clicks in nor out, and write it. The ring is 22 s, the longest take
	// 20 s, so the write head is nowhere near the take while it is copied.
	sampFinish { arg gen;
		var s = context.server, frames = sRing.numFrames, n, path = sPath;
		if (gen != sGen or: { sState != 3 }) { ^nil };
		sGen = sGen + 1;
		n = (sPosBus.getSynchronous.asInteger - sStart).wrap(0, frames);
		if (n < 64) { this.sampOff; ^nil };
		sState = 4;
		Routine {
			var b = Buffer.alloc(s, n, 1), first = (frames - sStart).min(n);
			var fi = 48.min(n.div(4)), fo = 480.min(n.div(4));
			var c = Condition.new, vin, vout;
			s.sync;
			sRing.copyData(b, 0, sStart, first);
			if (n > first) { sRing.copyData(b, first, 0, n - first) };
			s.sync;
			sSynth.run(false);
			b.normalize(0.9);
			s.sync;
			b.getn(0, fi, { |v| vin = v; c.unhang });
			c.hang;
			b.getn(n - fo, fo, { |v| vout = v; c.unhang });
			c.hang;
			b.setn(0, vin.collect { |x, i| x * (i / fi) },
				n - fo, vout.collect { |x, i| x * (1 - ((i + 1) / fo)) });
			s.sync;
			b.write(path, "wav", "int24");
			s.sync;
			b.free;
			sDone = sDone + 1;
			sState = 0;
		}.play(SystemClock);
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
		// the sampler: its state, finished takes, the source's level and
		// how far through a take it is
		this.addPoll(\sampstate, { sState });
		this.addPoll(\sampdone, { sDone });
		this.addPoll(\samplvl, { if (sState > 0) { sLvlBus.getSynchronous } { 0 } });
		this.addPoll(\sampprog, {
			if (sState == 3) { ((Main.elapsedTime - sT0) / sDur).clip(0, 1) } { 0 }
		});
	}

	free {
		live.do { |l| l.do(_.free) };
		strips.do(_.free);
		delayS.free; springS.free; duckS.free;
		recS.free; perfGroup.free; tape.free; posBus.free;
		colourS.free;
		sHitFunc.free; sSynth.free;
		sGroup.free; sRing.free; sPosBus.free; sLvlBus.free;
		voiceGroup.free; stripGroup.free; fxGroup.free; colourGroup.free;
		tBus.do(_.free);
		driftBus.free;
		mixBus.free; dlyBus.free; sprBus.free; meterBus.free; ampBus.free;
		scBus.free; duckBus.free;
		bufs.do { |b| if (b !== blank) { b.free } };
		blank.free;
	}
}
