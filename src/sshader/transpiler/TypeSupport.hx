package sshader.transpiler;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;
import sshader.ShaderSource;
import sshader.transpiler.Types;

using haxe.macro.TypeTools;
using haxe.macro.TypedExprTools;

@:allow(sshader.transpiler.Transpiler)
class TypeSupport {
	static final typeDefCache:Map<String, TypeDef> = new Map();
	static final typeDefBuildInProgress:Map<String, Bool> = new Map();
	static final shaderSourcePack = ["sshader"];
	static final shaderSourceName = "ShaderSource";
	static final glslReserved = [
		"attribute",
		"const",
		"uniform",
		"varying",
		"buffer",
		"shared",
		"coherent",
		"volatile",
		"restrict",
		"readonly",
		"writeonly",
		"atomic_uint",
		"layout",
		"centroid",
		"flat",
		"smooth",
		"noperspective",
		"patch",
		"sample",
		"break",
		"continue",
		"do",
		"for",
		"while",
		"switch",
		"case",
		"default",
		"if",
		"else",
		"subroutine",
		"in",
		"out",
		"inout",
		"float",
		"double",
		"int",
		"void",
		"bool",
		"true",
		"false",
		"invariant",
		"discard",
		"return",
		"mat2",
		"mat3",
		"mat4",
		"dmat2",
		"dmat3",
		"dmat4",
		"mat2x2",
		"mat2x3",
		"mat2x4",
		"mat3x2",
		"mat3x3",
		"mat3x4",
		"mat4x2",
		"mat4x3",
		"mat4x4",
		"dmat2x2",
		"dmat2x3",
		"dmat2x4",
		"dmat3x2",
		"dmat3x3",
		"dmat3x4",
		"dmat4x2",
		"dmat4x3",
		"dmat4x4",
		"vec2",
		"vec3",
		"vec4",
		"ivec2",
		"ivec3",
		"ivec4",
		"bvec2",
		"bvec3",
		"bvec4",
		"uvec2",
		"uvec3",
		"uvec4",
		"dvec2",
		"dvec3",
		"dvec4",
		"lowp",
		"mediump",
		"highp",
		"precision",
		"sampler1D",
		"sampler2D",
		"sampler3D",
		"samplerCube",
		"sampler1DShadow",
		"sampler2DShadow",
		"samplerCubeShadow",
		"sampler1DArray",
		"sampler2DArray",
		"sampler1DArrayShadow",
		"sampler2DArrayShadow",
		"isampler1D",
		"isampler2D",
		"isampler3D",
		"isamplerCube",
		"isampler1DArray",
		"isampler2DArray",
		"usampler1D",
		"usampler2D",
		"usampler3D",
		"usamplerCube",
		"usampler1DArray",
		"usampler2DArray",
		"sampler2DRect",
		"sampler2DRectShadow",
		"isampler2DRect",
		"usampler2DRect",
		"samplerBuffer",
		"isamplerBuffer",
		"usamplerBuffer",
		"sampler2DMS",
		"isampler2DMS",
		"usampler2DMS",
		"sampler2DMSArray",
		"isampler2DMSArray",
		"usampler2DMSArray",
		"samplerCubeArray",
		"samplerCubeArrayShadow",
		"isamplerCubeArray",
		"usamplerCubeArray",
		"image1D",
		"iimage1D",
		"uimage1D",
		"image2D",
		"iimage2D",
		"uimage2D",
		"image3D",
		"iimage3D",
		"uimage3D",
		"image2DRect",
		"iimage2DRect",
		"uimage2DRect",
		"imageCube",
		"iimageCube",
		"uimageCube",
		"imageBuffer",
		"iimageBuffer",
		"uimageBuffer",
		"image1DArray",
		"iimage1DArray",
		"uimage1DArray",
		"image2DArray",
		"iimage2DArray",
		"uimage2DArray",
		"imageCubeArray",
		"iimageCubeArray",
		"uimageCubeArray",
		"image2DMS",
		"iimage2DMS",
		"uimage2DMS",
		"image2DMSArray",
		"iimage2DMSArray",
		"uimage2DMSArray",
		"struct",
		"asm",
		"class",
		"union",
		"enum",
		"typedef",
		"template",
		"this",
		"packed",
		"goto",
		"inline",
		"noinline",
		"public",
		"static",
		"extern",
		"external",
		"interface",
		"long",
		"short",
		"half",
		"fixed",
		"unsigned",
		"superp",
		"input",
		"output",
		"hvec2",
		"hvec3",
		"hvec4",
		"fvec2",
		"fvec3",
		"fvec4",
		"sampler3DRect",
		"filter",
		"sizeof",
		"cast",
		"namespace",
		"using"
	];

	static var curDefinedTypes:Map<String, Bool> = null;
	static var curDispatchers:Map<String, FunctionDispatcher> = null;
	static var curDispatcherSeq:Int = 0;
	static var curHelperSeq:Int = 0;
	static var curUniformFields:Map<String, String> = null;
	static var curInlineNoThisMethods:Map<String, String> = null;
	static final noThisMethodCache:Map<String, Bool> = new Map();
	static final noThisMethodInProgress:Map<String, Bool> = new Map();

	static inline function cloneTypeDef(type:TypeDef):TypeDef {
		return {
			name: type.name,
			def: type.def.copy()
		};
	}

	static inline function typeCacheKey(type:Type, pos:Position):String {
		function paramsSig(params:Array<Type>) {
			if (params == null || params.length == 0)
				return "";
			return "<" + params.map(p -> Context.signature(p)).join(",") + ">";
		}
		return switch type {
			case TEnum(t, params):
				"E:" + baseTypeName(t.get()) + paramsSig(params);
			case TInst(t, params):
				"C:" + baseTypeName(t.get()) + paramsSig(params);
			case TType(t, params):
				"T:" + baseTypeName(t.get()) + paramsSig(params);
			case TAbstract(t, params):
				"A:" + baseTypeName(t.get()) + paramsSig(params);
			case TFun(args, ret):
				"F:(" + args.map(a -> Context.signature(a.t)).join(",") + ")->" + Context.signature(ret);
			case TAnonymous(a):
				"N:" + a.get().fields.map(f -> f.name + ":" + Context.signature(f.type)).join("|");
			default:
				"X:" + typeNameOf(type, pos);
		}
	}

	static function baseTypeName(type:BaseType):String {
		if (type.meta.has(":native")) {
			var meta = type.meta.extract(":native")[0];
			if (meta != null && meta.params != null && meta.params.length > 0)
				switch meta.params[0].expr {
					case EConst(CString(s)):
						return s;
					default:
				}
		}
		var path = type.pack.copy();
		path.push(type.module);
		if (type.name != type.module)
			path.push(type.name);
		return path.join("_");
	}

	public static inline function classBaseName(type:ClassType):String {
		return baseTypeName(type);
	}

	static inline function classFieldKey(owner:ClassType, field:ClassField):String {
		return baseTypeName(owner) + ":" + field.name;
	}

	static inline function isVarField(field:ClassField):Bool {
		return switch field.kind {
			case FVar(_, _):
				true;
			default:
				false;
		}
	}

	static function typeNameOf(type:Type, pos:Position):String {
		return switch type {
			case TEnum(t, _):
				baseTypeName(t.get());
			case TInst(t, _):
				baseTypeName(t.get());
			case TType(t, _):
				baseTypeName(t.get());
			case TAbstract(t, _):
				baseTypeName(t.get());
			case TFun(_, _):
				"_Function";
			case TAnonymous(_):
				var p = Context.getPosInfos(pos);
				"_Anon_" + p.min + "_" + p.max;
			default:
				"_UnknownType";
		}
	}

	static function consumeTypeDefForEntry(type:TypeDef):TypeDef {
		if (curDefinedTypes == null || type.name == null)
			return cloneTypeDef(type);
		if (curDefinedTypes.exists(type.name)) {
			return {
				name: type.name,
				def: []
			};
		}
		curDefinedTypes.set(type.name, true);
		return cloneTypeDef(type);
	}

	public static function fieldNativeName(field:ClassField):String {
		if (field.meta.has(":native")) {
			var m = field.meta.extract(":native")[0];
			if (m != null && m.params != null && m.params.length > 0)
				switch m.params[0].expr {
					case EConst(CString(s)):
						return s;
					default:
				}
		}
		return sanitizeIdent(field.name);
	}

	public static function isShaderSourceClass(type:ClassType):Bool {
		var seen = new Map<String, Bool>();
		function keyOf(t:ClassType):String
			return t.pack.join(".") + ":" + t.module + ":" + t.name;
		function visit(t:ClassType):Bool {
			var key = keyOf(t);
			if (seen.exists(key))
				return false;
			seen.set(key, true);
			if (t.name == shaderSourceName && t.pack.length == shaderSourcePack.length) {
				var ok = true;
				for (i in 0...shaderSourcePack.length)
					if (t.pack[i] != shaderSourcePack[i]) {
						ok = false;
						break;
					}
				if (ok)
					return true;
			}
			for (it in t.interfaces)
				if (visit(it.t.get()))
					return true;
			var sup = t.superClass;
			return sup != null && visit(sup.t.get());
		}
		return visit(type);
	}

	static function unwrapAnalysisExpr(e:TypedExpr):TypedExpr {
		var cur = e;
		while (true)
			switch cur.expr {
				case TMeta(_, inner):
					cur = inner;
				case TParenthesis(inner):
					cur = inner;
				case TCast(inner, null):
					cur = inner;
				default:
					return cur;
			}
		return cur;
	}

	static function exprUsesThis(e:TypedExpr):Bool {
		var found = false;
		function visit(node:TypedExpr) {
			if (found)
				return;
			var cur = unwrapAnalysisExpr(node);
			var skipIter = false;
			switch cur.expr {
				case TConst(TThis), TConst(TSuper):
					found = true;
					return;
				case TField(target, fa):
					var uTarget = unwrapAnalysisExpr(target);
					switch uTarget.expr {
						case TConst(TThis), TConst(TSuper):
							var usesSelf = switch fa {
								case FInstance(c, _, cf):
									var owner = c.get();
									switch cf.get().kind {
										case FVar(_, _):
											uniformNameForField(owner, cf.get()) == null;
										case FMethod(_):
											!isNoThisMethod(owner, cf.get());
									}
								case FClosure(c, cf):
									c == null ? true : !isNoThisMethod(c.c.get(), cf.get());
								default:
									true;
							}
							if (usesSelf) {
								found = true;
								return;
							}
							skipIter = true;
						default:
					}
				default:
			}
			if (!skipIter)
				cur.iter(visit);
		}
		visit(e);
		return found;
	}

	public static function isNoThisInlineMethod(owner:ClassType, field:ClassField):Bool {
		if (!isNoThisMethod(owner, field))
			return false;
		switch field.kind {
			case FMethod(MethInline):
				return true;
			default:
				return false;
		}
	}

	public static function isNoThisMethod(owner:ClassType, field:ClassField):Bool {
		var key = classFieldKey(owner, field) + ":method";
		var cached = noThisMethodCache.get(key);
		if (cached != null)
			return cached;
		if (noThisMethodInProgress.exists(key))
			return false;
		var eligible = switch field.kind {
			case FMethod(MethMacro):
				false;
			case FMethod(_):
				true;
			default:
				false;
		}
		if (!eligible)
			return false;
		noThisMethodInProgress.set(key, true);
		var expr = field.expr();
		if (expr == null) {
			noThisMethodInProgress.remove(key);
			return false;
		}
		var body = switch expr.expr {
			case TFunction(func):
				func.expr;
			default:
				expr;
		}
		var out = !exprUsesThis(body);
		noThisMethodInProgress.remove(key);
		noThisMethodCache.set(key, out);
		return out;
	}

	static function isTrivialCtorStmt(e:TypedExpr):Bool {
		var cur = unwrapAnalysisExpr(e);
		return switch cur.expr {
			case TReturn(null):
				true;
			case TCall(callee, args):
				var uCallee = unwrapAnalysisExpr(callee);
				switch uCallee.expr {
					case TConst(TSuper):
						args.length == 0;
					default:
						false;
				}
			case TBlock(el):
				var ok = true;
				for (stmt in el)
					if (!isTrivialCtorStmt(stmt)) {
						ok = false;
						break;
					}
				ok;
			default:
				false;
		}
	}

	static function isEmptyCtorBodyExpr(e:TypedExpr):Bool {
		var cur = unwrapAnalysisExpr(e);
		return switch cur.expr {
			case TFunction(func):
				isEmptyCtorBodyExpr(func.expr);
			case TBlock(el):
				var ok = true;
				for (stmt in el)
					if (!isTrivialCtorStmt(stmt)) {
						ok = false;
						break;
					}
				ok;
			case TReturn(null), TCall(_, _):
				isTrivialCtorStmt(cur);
			default:
				false;
		}
	}

	public static function isStatelessTrivialCtorClass(type:ClassType):Bool {
		var seen = new Map<String, Bool>();
		function keyOf(t:ClassType):String
			return t.pack.join(".") + ":" + t.module + ":" + t.name;
		function visit(t:ClassType):Bool {
			var key = keyOf(t);
			if (seen.exists(key))
				return true;
			seen.set(key, true);
			for (field in t.fields.get())
				switch field.kind {
					case FVar(_, _):
						return false;
					default:
				}
			var ctorRef = t.constructor;
			if (ctorRef != null) {
				var ctor = ctorRef.get();
				var ctorExpr = ctor.expr();
				if (ctorExpr != null && !isEmptyCtorBodyExpr(ctorExpr))
					return false;
			}
			var sup = t.superClass;
			return sup == null || visit(sup.t.get());
		}
		return visit(type);
	}

	static function implicitUniformFieldName(owner:ClassType, field:ClassField):String {
		return sanitizeIdent(baseTypeName(owner) + "_" + field.name);
	}

	public static function uniformNameForField(owner:ClassType, field:ClassField):Null<String> {
		if (curUniformFields == null)
			return null;
		return curUniformFields.get(classFieldKey(owner, field));
	}

	public static function collectUniforms(type:ClassType, bindContext:Bool = false):Array<Uniform> {
		var out:Array<Uniform> = [];
		var usedNames = new Map<String, Bool>();
		var fieldUniforms = new Map<String, String>();
		var chain:Array<ClassType> = [];
		var cur:ClassType = type;
		while (cur != null) {
			chain.unshift(cur);
			var next = cur.superClass;
			cur = next == null ? null : next.t.get();
		}
		function add(owner:ClassType, field:ClassField) {
			if (!isVarField(field))
				return;
			var uniformName = implicitUniformFieldName(owner, field);
			fieldUniforms.set(classFieldKey(owner, field), uniformName);
			if (usedNames.exists(uniformName))
				return;
			usedNames.set(uniformName, true);
			out.push({
				name: uniformName,
				type: defType(field.type, field.pos)
			});
		}
		for (t in chain) {
			for (field in t.fields.get())
				add(t, field);
			for (field in t.statics.get())
				add(t, field);
		}
		if (bindContext)
			curUniformFields = fieldUniforms;
		return out;
	}

	public static function sanitizeIdent(name:String):String {
		var out = new StringBuf();
		for (i in 0...name.length) {
			var c = name.charCodeAt(i);
			var isDigit = c >= "0".code && c <= "9".code;
			var isUpper = c >= "A".code && c <= "Z".code;
			var isLower = c >= "a".code && c <= "z".code;
			if (isDigit || isUpper || isLower || c == "_".code)
				out.addChar(c);
			else
				out.add("_");
		}
		var id = out.toString();
		if (id.length == 0)
			id = "_";
		var first = id.charCodeAt(0);
		if (first >= "0".code && first <= "9".code)
			id = "_" + id;
		if (StringTools.startsWith(id, "gl_"))
			id = "_" + id;
		while (glslReserved.contains(id))
			id = id + "_";
		return id;
	}

	public static function enumFieldArgs(field:EnumField):Array<{name:String, t:Type}> {
		return switch field.type {
			case TFun(args, _):
				args.map(a -> ({name: a.name, t: a.t}));
			default:
				[];
		}
	}

	static function safeEnumFieldIndex(field:Dynamic, fallback:Int):Int {
		try {
			if (Reflect.hasField(field, "index")) {
				var idx = Reflect.field(field, "index");
				if (Std.isOfType(idx, Int))
					return idx;
			}
		} catch (_:Dynamic) {}
		return fallback;
	}

	public static function enumCaseValueIndex(expr:TypedExpr):String {
		return switch expr.expr {
			case TField(_, FEnum(_, ef)):
				Std.string(safeEnumFieldIndex(ef, 0));
			case TCall(callee, _):
				switch callee.expr {
					case TField(_, FEnum(_, ef)):
						Std.string(safeEnumFieldIndex(ef, 0));
					default:
						Context.error("Enum switch case should be enum constructor", expr.pos);
						"0";
				}
			case TParenthesis(e):
				enumCaseValueIndex(e);
			case TCast(e, _):
				enumCaseValueIndex(e);
			default:
				Context.error("Enum switch case should be enum constructor", expr.pos);
				"0";
		}
	}

	public static function defFun(args:Array<{name:String, opt:Bool, t:Type}>, ret:Type, pos:Position):TypeDef {
		var intDef = defType(Context.typeof(macro 0), pos);
		var defs = intDef.def.copy();
		var retDef = defType(ret, pos);
		defs = defs.concat(retDef.def);
		for (arg in args) {
			var argDef = defType(arg.t, pos);
			defs = defs.concat(argDef.def);
		}
		return {
			name: intDef.name,
			def: defs
		};
	}

	public static function defAnon(type:AnonType, pos:Position):TypeDef {
		var p = Context.getPosInfos(pos);
		var name = "_Anon_" + p.min + "_" + p.max;
		var defs = [];
		var b = new StringBuf();
		b.add("struct " + name + " {\n");
		for (field in type.fields) {
			var fieldType = defType(field.type, field.pos);
			defs = defs.concat(fieldType.def);
			b.add("\t" + fieldType.name + " " + sanitizeIdent(field.name) + ";\n");
		}
		b.add("};");
		defs.push(b.toString());
		return {
			name: name,
			def: defs
		};
	}

	public static function defType(type:Type, pos:Position):TypeDef {
		var key = typeCacheKey(type, pos);
		var cached = typeDefCache.get(key);
		if (cached != null)
			return consumeTypeDefForEntry(cached);
		if (typeDefBuildInProgress.exists(key))
			return {
				name: typeNameOf(type, pos),
				def: []
			};
		var prevEntryTypes = curDefinedTypes;
		curDefinedTypes = null;
		typeDefBuildInProgress.set(key, true);
		var canonical = switch type {
			case TEnum(t, params):
				defEnum(t.get(), params);
			case TInst(t, params):
				defClassType(t.get(), params);
			case TType(t, params):
				defTypeDef(t.get(), params);
			case TFun(args, ret):
				defFun(args, ret, pos);
			case TAnonymous(a):
				defAnon(a.get(), pos);
			case TAbstract(t, params):
				defAbstract(t.get(), params);
			default:
				Context.error('Type $type is not allowed', pos);
		}
		typeDefBuildInProgress.remove(key);
		curDefinedTypes = prevEntryTypes;
		typeDefCache.set(key, cloneTypeDef(canonical));
		return consumeTypeDefForEntry(canonical);
	}

	public static function defModuleType(type:ModuleType):TypeDef {
		return switch type {
			case TClassDecl(c):
				defType(TInst(c, []), c.get().pos);
			case TEnumDecl(e):
				defType(TEnum(e, []), e.get().pos);
			case TTypeDecl(t):
				defType(TType(t, []), t.get().pos);
			case TAbstract(a):
				defType(TAbstract(a, []), a.get().pos);
		}
	}

	public static function defEnum(type:EnumType, params:Array<Type>) {
		return defBaseType(type, "enum", params, base -> {
			var b = new StringBuf();
			function addType(t:Type) {
				var tdef = defType(t, type.pos);
				base.def = base.def.concat(tdef.def);
				return tdef.name;
			}
			function applyEnumType(t:Type):Type {
				return type.params.length == params.length ? t.applyTypeParameters(type.params, params) : t;
			}
			function appliedArgs(field:EnumField):Array<{name:String, t:Type}> {
				return enumFieldArgs(field).map(a -> ({
					name: a.name,
					t: applyEnumType(a.t)
				}));
			}
			b.add("struct " + base.name + " {\n");
			b.add('\tint __tag;\n');
			for (nameIndex in 0...type.names.length) {
				var f = type.names[nameIndex];
				var c = type.constructs.get(f);
				var args = appliedArgs(c);
				for (argIndex in 0...args.length) {
					var argType = addType(args[argIndex].t);
					b.add('\t${argType} __${c.name + "_" + argIndex};\n');
				}
			}
			b.add("};\n");
			for (nameIndex in 0...type.names.length) {
				var f = type.names[nameIndex];
				var c = type.constructs.get(f);
				var args = appliedArgs(c);
				var ctorParams = [];
				for (i in 0...args.length) {
					var argName = "__arg" + i;
					var argType = addType(args[i].t);
					ctorParams.push(argType + " " + argName);
				}
				var ctorName = base.name + "_" + c.name;
				b.add('${base.name} ${ctorName}(${ctorParams.join(", ")}) {\n');
				b.add('\t${base.name} __value;\n');
				var ctorIndex = safeEnumFieldIndex(c, nameIndex);
				b.add('\t__value.__tag = ${ctorIndex};\n');
				for (i in 0...args.length)
					b.add('\t__value.__${c.name + "_" + i} = __arg${i};\n');
				b.add("\treturn __value;\n");
				b.add("}\n");
			}
			return b.toString();
		});
	}

	public static function defClassType(type:ClassType, params:Array<Type>):TypeDef {
		return defBaseType(type, "class", params, base -> {
			var b = new StringBuf();
			var instanceVars:Array<ClassField> = [];
			var instanceMethods:Array<ClassField> = [];
			var staticVars:Array<ClassField> = [];
			var staticMethods:Array<ClassField> = [];
			function applyClassType(t:Type):Type
				return type.params.length == params.length ? t.applyTypeParameters(type.params, params) : t;
			function classifyField(field:ClassField, isStatic:Bool) {
				// Entry points are emitted separately as `main()` bodies.
				if (field.name == "__vert__" || field.name == "__frag__")
					return;
				if (!isStatic && isNoThisInlineMethod(type, field))
					return;
				switch field.kind {
					case FVar(_, _):
						if (uniformNameForField(type, field) != null)
							return;
						if (isStatic)
							staticVars.push(field);
						else
							instanceVars.push(field);
					case FMethod(kind):
						switch kind {
							case MethMacro:
								Context.error("Macro methods are not supported for GLSL transpilation", field.pos);
							case MethInline, MethDynamic, MethNormal:
								if (isStatic) staticMethods.push(field); else instanceMethods.push(field);
						}
				}
			}
			function emitVariable(field:ClassField, isStatic:Bool) {
				var typeDef = defType(applyClassType(field.type), field.pos);
				base.def = base.def.concat(typeDef.def);
				var varName = isStatic ? (base.name + "_" + sanitizeIdent(field.name)) : sanitizeIdent(field.name);
				if (!isStatic)
					b.add("\t");
				b.add(typeDef.name + " " + varName);
				var initExpr = field.expr();
				if (initExpr != null) {
					var init = Transpiler.transExpr(initExpr, false, false, 0, false);
					base.def = base.def.concat(init.statics);
					b.add(" = " + init.expr);
				}
				b.add(";\n");
			}
			function emitMethod(field:ClassField, isStatic:Bool) {
				var methodType = applyClassType(field.type);
				var signature = switch methodType.follow() {
					case TFun(args, ret):
						{
							args: args,
							ret: ret
						};
					default:
						Context.error('Expected function type for method ${field.name}', field.pos);
						{
							args: [],
							ret: methodType
						};
				}
				var retType = defType(signature.ret, field.pos);
				base.def = base.def.concat(retType.def);
				var methodCtx:TransContext = {
					locals: new Map(),
					usedLocalNames: new Map()
				};
				var needsSelf = !isStatic && !isNoThisMethod(type, field);
				if (needsSelf)
					methodCtx.usedLocalNames.set("__self", 1);
				function reserveArgName(raw:String):String {
					var base = sanitizeIdent(raw);
					if (base == "_" || base == "this" || base == "__self")
						base = "__arg";
					var count = methodCtx.usedLocalNames.get(base);
					if (count == null) {
						methodCtx.usedLocalNames.set(base, 1);
						return base;
					}
					var name = base + "_" + count;
					var i = count + 1;
					while (methodCtx.usedLocalNames.exists(name)) {
						name = base + "_" + i;
						i++;
					}
					methodCtx.usedLocalNames.set(base, i);
					methodCtx.usedLocalNames.set(name, 1);
					return name;
				}
				var argsDecl = [];
				if (needsSelf)
					argsDecl.push("inout " + base.name + " __self");
				var argNames:Array<String> = [];
				for (arg in signature.args) {
					var argType = defType(arg.t, field.pos);
					base.def = base.def.concat(argType.def);
					var argName = reserveArgName(arg.name);
					argNames.push(argName);
					argsDecl.push(argType.name + " " + argName);
				}
				var expr = field.expr();
				if (expr == null)
					Context.error('Method ${field.name} should have a body', field.pos);
				var body = switch expr.expr {
					case TFunction(func):
						for (i in 0...func.args.length)
							if (i < argNames.length)
								methodCtx.locals.set(func.args[i].v.id, argNames[i]);
						Transpiler.transExpr(func.expr, false, false, 0, false, methodCtx);
					default:
						Transpiler.transExpr(expr, false, false, 0, false, methodCtx);
				}
				base.def = base.def.concat(body.statics);
				b.add(retType.name + " " + (base.name + "_" + sanitizeIdent(field.name)) + "(" + argsDecl.join(", ") + ") ");
				if (body.expr.length > 0 && body.expr.charAt(0) == "{") {
					b.add(body.expr + "\n");
				} else {
					b.add("{\n");
					b.add("\t" + body.expr + ";\n");
					b.add("}\n");
				}
			}
			for (field in type.fields.get())
				classifyField(field, false);
			for (field in type.statics.get())
				classifyField(field, true);
			var hasSelfMethods = false;
			for (field in instanceMethods)
				if (!isNoThisMethod(type, field)) {
					hasSelfMethods = true;
					break;
				}
			var shouldEmitStruct = instanceVars.length > 0 || hasSelfMethods;
			if (shouldEmitStruct) {
				b.add("struct " + base.name + " {\n");
				for (field in instanceVars)
					emitVariable(field, false);
				b.add("};\n");
			} else if (!type.isExtern && !type.meta.has(":native")) {
				// Zero-state classes are represented as scalar aliases to avoid emitting empty structs.
				b.add("#define " + base.name + " int\n");
			}
			for (field in staticVars)
				emitVariable(field, true);
			for (field in instanceMethods)
				emitMethod(field, false);
			for (field in staticMethods)
				emitMethod(field, true);
			return b.toString();
		});
	}

	public static function defTypeDef(type:DefType, params:Array<Type>):TypeDef {
		return defBaseType(type, "typedef", params, base -> {
			var alias = defType(type.type.applyTypeParameters(type.params, params).follow(), type.pos);
			base.def = base.def.concat(alias.def);
			base.name = alias.name;
			return "";
		});
	}

	public static function defAbstract(type:AbstractType, params:Array<Type>):TypeDef {
		// avoid recursive definition for core type abstracts
		// as their underlying type is the type itself
		type.isExtern = type.impl == null;
		return defBaseType(type, "abstract", params, base -> {
			function addType(t:Type) {
				var tdef = defType(t, type.pos);
				base.def = base.def.concat(tdef.def);
			}
			function addField(field:ClassField) {
				addType(field.type);
				var expr = field.expr();
				if (expr != null) {
					var body = Transpiler.transExpr(expr, false, false, 0, false);
					base.def = base.def.concat(body.statics);
				}
			}
			// implementation class contains real abstract methods/casts/operators
			if (type.impl != null) {
				var implDef = defType(TInst(type.impl, params), type.pos);
				base.def = base.def.concat(implDef.def);
			}
			// operator overload fields
			for (it in type.binops)
				addField(it.field);
			for (it in type.unops)
				addField(it.field);
			// implicit cast surfaces
			for (it in type.from) {
				addType(it.t);
				if (it.field != null)
					addField(it.field);
			}
			for (it in type.to) {
				addType(it.t);
				if (it.field != null)
					addField(it.field);
			}
			// array access and resolve hooks
			for (f in type.array)
				addField(f);
			if (type.resolve != null)
				addField(type.resolve);
			if (type.resolveWrite != null)
				addField(type.resolveWrite);
			// final value representation
			var alias = defType(type.type.applyTypeParameters(type.params, params).follow(), type.pos);
			base.def = base.def.concat(alias.def);
			base.name = alias.name;
			return "";
		});
	}

	static function defBaseType(type:BaseType, title:String, params:Array<Type>, build:TypeDef->String):TypeDef {
		var tdef:TypeDef = {
			def: [],
			name: null
		}
		// type name
		if (type.meta.has(":native")) {
			var m = type.meta.extract(":native")[0].params[0];
			if (m != null)
				switch m.expr {
					case EConst(CString(s)):
						tdef.name = s;
					default:
				}
		}
		if (tdef.name == null) {
			var path = type.pack.copy();
			path.push(type.module);
			if (type.name != type.module)
				path.push(type.name);
			tdef.name = path.join("_");
		}
		// type definition
		for (p in params ?? []) {
			var paramDef = defType(p, type.pos);
			tdef.name += "_" + paramDef.name;
			tdef.def = tdef.def.concat(paramDef.def);
		}
		if (!type.isExtern) {
			var t = build(tdef);
			if (t != null && t.length > 0)
				tdef.def.push(t);
		}
		return tdef;
	}
}
#end
