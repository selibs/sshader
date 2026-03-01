package;

import sshader.ShaderSource;

enum ShaderMode {
	Disabled;
	Fill(v:Int);
	Mask(a:Int, b:Int);
	Blend(x:Int, y:Int, z:Int);
}

enum GenericResult<T> {
	Ok(value:T);
	Error(code:Int, extra:Int);
}

enum StressEnum<T> {
	SEmpty;
	SOne(v:T);
	STwo(a:T, b:T);
	SMany(seed:Int, payload:T);
}

enum abstract Quality(Int) from Int to Int {
	var Low = 0;
	var Medium = 1;
	var High = 2;
}

enum abstract Stage(Int) from Int to Int {
	var A = 0;
	var B = 1;
	var C = 2;

	public inline function next():Stage
		return switch (this) {
			case A:
				B;
			case B:
				C;
			default:
				A;
		}
}

abstract BitMask(Int) from Int to Int {
	public inline function new(v:Int)
		this = v;

	public inline function has(flag:Int):Bool
		return (this & flag) != 0;

	public inline function add(flag:Int):BitMask
		return this | flag;
}

class GlslExtern {
	@:native("gl_InstanceID") public static function instanceID():Int
		return 0;

	@:native("gl_VertexID") public static function vertexID():Int
		return 0;

	@:native("gl_DrawID") public static function drawID():Int
		return 0;
}

typedef FragOut = {
	a:Int,
	b:Float
}

typedef TypeDefTest<T:Float> = {
	foo:Int,
	bar:Int->T
}

function typedefTest<T:Float>(f:Int->T):TypeDefTest<T>
	return {
		foo: 0,
		bar: f
	}

function a(i:Int):Int
	return i + 1;

class StaticMath {
	public static var Base:Int = 7;
	public static var Step:Int = 3;

	public static inline function fastAdd(a:Int, b:Int):Int
		return a + b;

	public static function foldRange(start:Int, stop:Int):Int {
		var total = 0;
		for (i in start...stop)
			total += i;
		return total + Base;
	}

	public static function pickMode(seed:Int, quality:Quality):ShaderMode {
		var local = seed + quality;
		switch (local % 4) {
			case 0:
				return Disabled;
			case 1:
				return Fill(local + Step);
			case 2:
				return Mask(local, local + 1);
			default:
				return Blend(local, local + 1, local + 2);
		}
	}

	public static function applyMode(mode:ShaderMode, input:Int):Int {
		var out = input;
		switch (mode) {
			case Disabled:
				out = Base;
			case Fill(v):
				out = v + input;
			case Mask(a, b):
				out = input + a - b;
			case Blend(x, y, z):
				out = input + x + y + z;
		}
		return out;
	}
}

class Pair<T, U> {
	public var first:T;
	public var second:U;

	public function new(first:T, second:U) {
		this.first = first;
		this.second = second;
	}

	public inline function swap():Pair<U, T>
		return new Pair<U, T>(second, first);
}

class GenericTools {
	public static inline function identity<T>(value:T):T
		return value;

	public static function choose<T>(a:T, b:T, useA:Bool):T {
		if (useA)
			return a;
		return b;
	}

	public static inline function wrapResult<T>(value:T):GenericResult<T>
		return Ok(value);
}

class DummyCtor {
	public inline function new() {}

	public static inline function make(v:Int):Int
		return v + 1;
}

class NoThis {
	public inline function new() {}

	public inline function ping(v:Int):Int
		return v + 1;
}

class ZigIter {
	public var current:Int;
	public var limit:Int;
	public var step:Int;

	public inline function new(current:Int, limit:Int, step:Int) {
		this.current = current;
		this.limit = limit;
		this.step = step;
	}

	public inline function hasNext():Bool
		return step > 0?current<limit:current>

	limit;
	public inline function next():Int {
		var out = current;
		current += step;
		return out;
	}
}

class ZigRange {
	public var from:Int;
	public var to:Int;
	public var step:Int;

	public inline function new(from:Int, to:Int, step:Int) {
		this.from = from;
		this.to = to;
		this.step = step == 0 ? 1 : step;
	}

	public inline function iterator():ZigIter
		return new ZigIter(from, to, step);
}

class Chain<T> {
	public var head:T;
	public var tail:T;

	public inline function new(head:T, tail:T) {
		this.head = head;
		this.tail = tail;
	}

	public inline function flip():Chain<T>
		return new Chain<T>(tail, head);
}

class StressOps {
	public static var Bias:Int = 13;

	public static inline function tri(a:Int, b:Int, c:Int):Int
		return a * 3 + b * 2 + c + Bias;

	public static function choose(seed:Int, a:Int->Int, b:Int->Int, c:Int->Int):Int->Int {
		switch (seed % 3) {
			case 0:
				return a;
			case 1:
				return b;
			default:
				return c;
		}
	}

	public static function consume(e:StressEnum<Int>, base:Int):Int {
		switch (e) {
			case SEmpty:
				return base;
			case SOne(v):
				return base + v;
			case STwo(a, b):
				return base + a - b;
			case SMany(seed, payload):
				return base + seed + payload;
		}
	}

	public static function pump(r:ZigRange):Int {
		var sum = 0;
		for (v in r)
			sum += v;
		return sum + Bias;
	}
}

class RectBase {
	public var baseBias:Int;

	public inline function new() {
		this.baseBias = 3;
	}

	public function shift(v:Int):Int
		return v + this.baseBias;

	public function modeWeight(mode:ShaderMode):Int {
		var w = 0;
		switch (mode) {
			case Disabled:
				w = 1;
			case Fill(v):
				w = v;
			case Mask(a, b):
				w = a + b;
			case Blend(x, y, z):
				w = x + y + z;
		}
		return w;
	}
}

class RectLayer extends RectBase {
	public var layerMul:Int;

	public inline function new() {
		super();
		this.layerMul = 2;
	}

	override public function shift(v:Int):Int {
		var fromSuper = super.shift(v);
		return fromSuper * this.layerMul;
	}

	public function superShift(v:Int):Int
		return super.shift(v);
}

class Tests extends RectLayer implements ShaderSource {
	public static inline function inlineTwist(v:Int):Int
		return (v * 3) ^ 5;

	public static function applyInt(v:Int, fn:Int->Int):Int
		return fn(v);

	public static inline function inlineClamp(v:Int):Int {
		if (v < -2048)
			return -2048;
		if (v > 2048)
			return 2048;
		return v;
	}

	override public function shift(v:Int):Int {
		var parent = super.shift(v);
		return parent + 1;
	}

	function vert(inputMode:ShaderMode, qualityIn:Quality, seed:Int):{
		@location(0) @flat var fragColor:Int;
		@location(1) @smooth(centroid) var fragPos:Float;
	} {
		var dummy = new DummyCtor();
		var noThis = new NoThis();
		var pingFn = DummyCtor.make;
		var boundFn:Int->Int = noThis.ping;
		var altFn:Int->Int = inlineTwist;
		var cap = seed + 11;
		var lambdaFn:Int->Int = function(v:Int):Int return v + cap;
		var localFn:Int->Int = function(v:Int):Int return v * 2 + cap;
		var dynFn:Int->Int = if ((seed & 1) == 0) pingFn else altFn;
		var switchFn:Int->Int = switch (seed & 3) {
			case 0:
				pingFn;
			case 1:
				altFn;
			case 2:
				DummyCtor.make;
			default:
				inlineTwist;
		}
		dynFn = if ((seed & 2) == 0) altFn else pingFn;

		var fillCtor = ShaderMode.Fill;
		var modeFromCtor = fillCtor(seed + 1);
		var modeTag = 0;
		switch (modeFromCtor) {
			case Disabled:
				modeTag = 0;
			case Fill(_):
				modeTag = 1;
			case Mask(_, _):
				modeTag = 2;
			case Blend(_, _, _):
				modeTag = 3;
		}

		var castSeed = cast(seed, Int);
		var castSeed2:Int = cast seed;
		var p = {x: castSeed, y: castSeed + 2};
		var parity = ([0, 1, 2, 3])[seed & 3];
		var stage:Stage = Stage.A;
		stage = stage.next();
		var stageN:Int = cast stage;

		var folded = StaticMath.foldRange(0, 5);
		var modeA = StaticMath.pickMode(seed + folded + DummyCtor.make(seed), qualityIn);
		var outColor = StaticMath.applyMode(inputMode, seed + folded);
		var tri = StressOps.tri(seed, folded, castSeed2);
		var zig = StressOps.pump(new ZigRange(-3, 7, 2));

		var seCtor = StressEnum.SOne;
		var se:StressEnum<Int> = switch (seed & 3) {
			case 0:
				seCtor(seed);
			case 1:
				StressEnum.STwo(seed, folded);
			case 2:
				StressEnum.SMany(seed, cap);
			default:
				StressEnum.SEmpty;
		}

		var selfShift = this.shift(seed);
		var superShift = super.shift(seed);
		var superOnly = super.superShift(seed);
		var weight = super.modeWeight(inputMode);
		var ext = GlslExtern.instanceID() + GlslExtern.vertexID() + GlslExtern.drawID();

		outColor += pingFn(seed) + selfShift + superShift + superOnly + weight;
		outColor += StaticMath.applyMode(modeFromCtor, seed);
		outColor += applyInt(seed, inlineTwist);
		outColor += applyInt(seed, pingFn);
		outColor += applyInt(seed, boundFn);
		outColor += applyInt(seed, lambdaFn);
		outColor += applyInt(seed, localFn);
		outColor += applyInt(seed, function(v:Int):Int return v - cap);
		outColor += applyInt(seed, dynFn);
		outColor += applyInt(seed, switch (seed % 3) {
			case 0:
				pingFn;
			case 1:
				boundFn;
			default:
				localFn;
		});
		outColor += applyInt(seed, if ((seed & 4) == 0) localFn else boundFn);
		outColor += applyInt(seed, switchFn);
		outColor += applyInt(seed, switch (seed & 1) {
			case 0:
				pingFn;
			default:
				altFn;
		});
		outColor += StressOps.consume(se, folded);
		var seTag = switch (se) {
			case SEmpty:
				0;
			case SOne(_):
				1;
			case STwo(_, _):
				2;
			case SMany(_, _):
				3;
		}
		outColor += seTag;
		outColor += tri + zig + stageN;
		outColor += p.x + p.y + parity + modeTag + ext + DummyCtor.make(0);
		outColor += inlineTwist(seed);
		outColor = inlineClamp(outColor);

		var pair = new Pair<Int, Int>(seed, folded);
		var swapped = pair.swap();
		var chain = new Chain<Int>(swapped.first, swapped.second).flip();
		outColor += chain.head + chain.tail;

		var neg = -seed;
		var bitNot = ~seed;
		var okRange = !(seed < 0);
		if (okRange && (seed >= neg || seed == castSeed))
			outColor += 1;
		else
			outColor -= 1;

		outColor += bitNot & 7;
		outColor |= (seed ^ 3);
		outColor &= 1023;
		outColor <<= 1;
		outColor >>= 1;
		outColor %= 997;

		switch (modeA) {
			case Disabled:
				outColor += 1;
			case Fill(v):
				outColor += v;
			case Mask(a, b):
				outColor += a - b;
			case Blend(x, y, z):
				outColor += x + y + z;
		}

		switch (seed & 3) {
			case 0:
				outColor += 4;
			case 1:
				outColor += 5;
			default:
				outColor += 6;
		}

		for (i in 0...10) {
			if (i == 1)
				continue;
			outColor += i;
			if (i > 6)
				break;
		}

		var w = 0;
		while (w < 3) {
			outColor += w;
			w++;
		}

		var d = 0;
		do {
			outColor += d;
			d++;
		} while (d < 2);

		@:privateAccess outColor += StaticMath.Base;
		return null;
	}

	function frag(inputMode:ShaderMode, qualityIn:Quality, seed:Int):FragOut {
		var base = StaticMath.foldRange(1, 4);
		var mixed = StaticMath.applyMode(inputMode, seed + base + qualityIn);
		var modeB = StaticMath.pickMode(mixed, qualityIn);
		var boxed = GenericTools.wrapResult(mixed);
		var take = GenericTools.choose(mixed, seed, true);
		var idValue = GenericTools.identity(take);
		var selfPart = this.shift(seed);
		var superPart = super.shift(seed);
		mixed += idValue + selfPart + superPart + super.modeWeight(modeB);
		var q:Stage = Stage.C;
		q = q.next();
		mixed += cast q;

		switch (modeB) {
			case Disabled:
				mixed += 2;
			case Fill(v):
				mixed += v;
			case Mask(a, b):
				mixed += a + b;
			case Blend(x, y, z):
				mixed += x * 2 + y + z;
		}

		switch (boxed) {
			case Ok(v):
				mixed += v;
			case Error(code, extra):
				mixed += code + extra;
		}

		var flags:BitMask = new BitMask(1);
		flags = flags.add(2);
		if (flags.has(2))
			mixed += 9;

		var pp = ({a: mixed, b: base});
		mixed += pp.a + pp.b;
		var mm = {
			p: mixed,
			f: function(v:Int):Int return v + base
		};
		mixed += mm.f(seed);

		var rng = new ZigRange(6, -3, -2);
		for (v in rng)
			mixed += v;

		var se2:StressEnum<Int> = if ((seed & 1) == 0) StressEnum.SOne(mixed) else StressEnum.STwo(seed, base);
		mixed += StressOps.consume(se2, seed);
		var se2Tag = switch (se2) {
			case SEmpty:
				0;
			case SOne(_):
				1;
			case STwo(_, _):
				2;
			case SMany(_, _):
				3;
		}
		mixed += se2Tag;

		var noThis2 = new NoThis();
		var bound2:Int->Int = noThis2.ping;
		mixed += applyInt(seed, switch ((seed + 1) % 3) {
			case 0:
				bound2;
			case 1:
				function(v:Int):Int return v + 3;
			default:
				DummyCtor.make;
		});

		var chain = new Chain<Int>(mixed, base).flip();
		mixed += chain.head + chain.tail;

		var t = typedefTest(a);
		var tt = typedefTest(function(v:Int):Float return v + 0.25);
		mixed += t.foo + Std.int(tt.bar(seed));

		var z = 0;
		while (z < 2) {
			z++;
			if (z == 1)
				continue;
			mixed += z;
		}
	}
}
