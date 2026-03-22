package s;

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
		var preEmittedSet:Map<String, Bool> = new Map();
		function addUnique(dst:Array<String>, seen:Map<String, Bool>, item:String):Void {
			if (seen.exists(item))
				return;
			seen.set(item, true);
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

		function declaredTypeName(def:String):Null<String> {
			var s = StringTools.ltrim(def);
			if (StringTools.startsWith(s, "struct ")) {
				var rest = s.substr("struct ".length);
				var i = 0;
				while (i < rest.length) {
					var c = rest.charCodeAt(i);
					if (!((c >= "0".code && c <= "9".code) || (c >= "A".code && c <= "Z".code) || (c >= "a".code && c <= "z".code) || c == "_".code))
						break;
					i++;
				}
				return i > 0 ? rest.substr(0, i) : null;
			}
			if (StringTools.startsWith(s, "#define ")) {
				var rest = s.substr("#define ".length);
				var i = 0;
				while (i < rest.length) {
					var c = rest.charCodeAt(i);
					if (!((c >= "0".code && c <= "9".code) || (c >= "A".code && c <= "Z".code) || (c >= "a".code && c <= "z".code) || c == "_".code))
						break;
					i++;
				}
				return i > 0 ? rest.substr(0, i) : null;
			}
			return null;
		}
		function collectTypeDef(types:Array<String>, typesSeen:Map<String, Bool>, typeNames:Array<String>, typeNamesSeen:Map<String, Bool>, t:TypeDef):Void {
			addUnique(typeNames, typeNamesSeen, t.name);
			for (d in t.def)
				addUnique(types, typesSeen, d);
		}

		// version
		if (version != null)
			buf.add('#version $version\n\n');

		var headerTypes:Array<String> = [];
		var headerTypesSeen:Map<String, Bool> = new Map();
		var headerTypeNames:Array<String> = [];
		var headerTypeNamesSeen:Map<String, Bool> = new Map();
		for (u in uniforms)
			collectTypeDef(headerTypes, headerTypesSeen, headerTypeNames, headerTypeNamesSeen, u.type);
		for (v in varIn)
			collectTypeDef(headerTypes, headerTypesSeen, headerTypeNames, headerTypeNamesSeen, v.type);
		for (v in varOut)
			collectTypeDef(headerTypes, headerTypesSeen, headerTypeNames, headerTypeNamesSeen, v.type);
		var headerDeclaredTypeNames:Map<String, Bool> = new Map();
		for (d in headerTypes) {
			var name = declaredTypeName(d);
			if (name != null)
				headerDeclaredTypeNames.set(name, true);
		}
		var staticTypeDefs:Map<String, String> = new Map();
		for (s in statics) {
			var name = declaredTypeName(s);
			if (name != null && !staticTypeDefs.exists(name))
				staticTypeDefs.set(name, s);
		}
		for (typeName in headerTypeNames)
			if (!headerDeclaredTypeNames.exists(typeName)) {
				var lifted = staticTypeDefs.get(typeName);
				if (lifted != null)
					addUnique(headerTypes, headerTypesSeen, lifted);
			}
		for (d in headerTypes) {
			buf.add(d + "\n");
			preEmittedSet.set(d, true);
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
		var emittedStatics:Map<String, Bool> = new Map();
		for (s in statics) {
			if (preEmittedSet.exists(s))
				continue;
			if (emittedStatics.exists(s))
				continue;
			buf.add(s + "\n");
			emittedStatics.set(s, true);
		}

		// body
		if (main.length > 0) {
			buf.add("void main() ");
			buf.add(main);
			buf.add("\n");
		}

		var result = buf.toString();
		return result;
	}
}
