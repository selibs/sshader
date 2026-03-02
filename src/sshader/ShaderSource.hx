package sshader;

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
	public var stage:Null<String> = null;
	public var uniforms:Array<Uniform> = [];
	public var varIn:Array<Varying> = [];
	public var varOut:Array<Varying> = [];
	public var statics:Array<String> = [];
	public var main:String = "";

	public function new() {}

	public function toString(format:Bool = false) {
		var buf = new StringBuf();
		var preEmitted:Array<String> = [];
		function addUnique(dst:Array<String>, item:String):Void {
			if (!dst.contains(item))
				dst.push(item);
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
			var allowInterp = switch stage {
				case "vert":
					d == "out";
				case "frag":
					d == "in";
				default:
					true;
			}
			var prefix = allowInterp ? (interp + " ") : "";
			buf.add('layout(location = ${v.location}) $prefix$d ${v.type.name} ${v.name};\n');
		}

		function definesType(def:String, typeName:String):Bool {
			var s = StringTools.ltrim(def);
			return StringTools.startsWith(s, "struct " + typeName + " {") || StringTools.startsWith(s, "#define " + typeName + " ");
		}

		function hasTypeDef(defs:Array<String>, typeName:String):Bool {
			for (d in defs)
				if (definesType(d, typeName))
					return true;
			return false;
		}

		function findTypeDefInStatics(typeName:String):Null<String> {
			for (s in statics)
				if (definesType(s, typeName))
					return s;
			return null;
		}
		function collectTypeDef(types:Array<String>, typeNames:Array<String>, t:TypeDef):Void {
			addUnique(typeNames, t.name);
			for (d in t.def)
				addUnique(types, d);
		}

		// version
		if (version != null)
			buf.add('#version $version\n\n');

		var headerTypes:Array<String> = [];
		var headerTypeNames:Array<String> = [];
		for (u in uniforms)
			collectTypeDef(headerTypes, headerTypeNames, u.type);
		for (v in varIn)
			collectTypeDef(headerTypes, headerTypeNames, v.type);
		for (v in varOut)
			collectTypeDef(headerTypes, headerTypeNames, v.type);
		for (typeName in headerTypeNames)
			if (!hasTypeDef(headerTypes, typeName)) {
				var lifted = findTypeDefInStatics(typeName);
				if (lifted != null)
					addUnique(headerTypes, lifted);
			}
		for (d in headerTypes) {
			buf.add(d + "\n");
			preEmitted.push(d);
		}
		if (headerTypes.length > 0)
			buf.add("\n");

		// uniforms
		if (uniforms.length > 0) {
			buf.add("layout(set = 0, binding = 0) uniform shader_uniform_block {\n");
			for (u in uniforms)
				buf.add('\t${u.type.name} ${u.name};\n');
			buf.add("} shader_uniforms;\n");
			for (u in uniforms)
				buf.add('#define ${u.name} shader_uniforms.${u.name}\n');
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
			if (preEmitted.contains(s))
				continue;
			if (unique.contains(s))
				continue;
			buf.add(s + "\n");
			unique.push(s);
		}

		// body
		if (main.length > 0) {
			buf.add("void main() ");
			buf.add(main);
			buf.add("\n");
		}

		var result = buf.toString();
		return format ? formatShaderSource(result) : result;
	}
}
