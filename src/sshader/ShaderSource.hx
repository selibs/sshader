package sshader;

import sshader.transpiler.Types;

enum AuxInterp {
	NONE;
	CENTROID;
	SAMPLE;
}

enum VaryingInterp {
	FLAT;
	SMOOTH(a:AuxInterp);
	NOPERSPECTIVE(a:AuxInterp);
}

typedef Varying = {
	name:String,
	type:TypeDef,
	location:Int,
	interp:VaryingInterp
}

typedef Uniform = {
	name:String,
	type:TypeDef
}

typedef TypeDef = {
	def:Array<String>,
	name:String
}

class ShaderSource {
	static function formatShaderSource(src:String):String {
		var out = new StringBuf();
		var lines = src.split("\n");
		var depth = 0;
		var prevBlank = true;
		for (raw in lines) {
			var line = StringTools.rtrim(raw);
			if (line.length == 0) {
				if (!prevBlank) {
					out.add("\n");
					prevBlank = true;
				}
				continue;
			}
			var trimmed = StringTools.ltrim(line);
			trimmed = ~/\)\s+\{/.replace(trimmed, ") {");
			if (StringTools.startsWith(trimmed, "#")) {
				out.add(trimmed + "\n");
				prevBlank = false;
				continue;
			}
			var indentDepth = depth;
			if (StringTools.startsWith(trimmed, "}"))
				indentDepth--;
			if (StringTools.startsWith(trimmed, "case ") || StringTools.startsWith(trimmed, "default:"))
				indentDepth = depth - 1;
			if (indentDepth < 0)
				indentDepth = 0;
			for (_ in 0...indentDepth)
				out.add("\t");
			out.add(trimmed + "\n");
			prevBlank = false;
			var opens = 0;
			var closes = 0;
			for (i in 0...trimmed.length) {
				var c = trimmed.charCodeAt(i);
				if (c == "{".code)
					opens++;
				else if (c == "}".code)
					closes++;
			}
			depth += opens - closes;
			if (depth < 0)
				depth = 0;
		}
		return out.toString();
	}

	public var version:String = "450";
	public var uniforms:Array<Uniform> = [];
	public var varIn:Array<Varying> = [];
	public var varOut:Array<Varying> = [];
	public var statics:Array<String> = [];
	public var body:String = "";

	public function new() {}

	public function toString(format:Bool = false) {
		var buf = new StringBuf();

		function addTypeDef(t:TypeDef) {
			statics = statics.concat(t.def);
			return t.name;
		}

		function addVarying(v:Varying, d:String) {
			var interp = switch v.interp {
				case FLAT:
					"flat";
				case SMOOTH(v):
					"smooth" + switch v {
						case NONE: "";
						case CENTROID: " centroid";
						case SAMPLE: " sample";
					}
				case NOPERSPECTIVE(v):
					"noperspective" + switch v {
						case NONE: "";
						case CENTROID: " centroid";
						case SAMPLE: " sample";
					}
			}
			buf.add('layout(location = ${v.location}) $interp $d ${addTypeDef(v.type)} ${v.name};\n');
		}

		// version
		if (version != null)
			buf.add('#version $version\n\n');

		// uniforms
		if (uniforms.length > 0) {
			for (u in uniforms)
				buf.add('uniform ${addTypeDef(u.type)} ${u.name};\n');
			buf.add("\n");
		}

		// in
		if (varIn.length > 0) {
			for (v in varIn)
				addVarying(v, "in");
			buf.add("\n");
		}

		// out
		if (varOut.length > 0) {
			for (v in varOut)
				addVarying(v, "out");
			buf.add("\n");
		}

		// statics
		var unique = [];
		for (s in statics) {
			if (unique.contains(s))
				continue;
			buf.add(s + "\n");
			unique.push(s);
		}

		// body
		if (body.length > 0) {
			buf.add("void main() ");
			buf.add(body);
			buf.add("\n");
		}

		var result = buf.toString();
		return format ? formatShaderSource(result) : result;
	}
}
