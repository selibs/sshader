package sshader;

#if macro
import haxe.macro.Type;
import haxe.macro.Expr;
import haxe.macro.Context;

using haxe.macro.TypeTools;
using haxe.macro.ComplexTypeTools;
using haxe.macro.TypedExprTools;

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

typedef TypeDef = {
	def:Array<String>,
	name:String
}

typedef EntryPointBody = {
	statics:Array<String>,
	expr:String
}

typedef EntryPoint = {
	varIn:Array<Varying>,
	varOut:Array<Varying>,
	body:EntryPointBody
}

typedef TransContext = {
	locals:Map<Int, String>,
	usedLocalNames:Map<String, Int>
}

typedef FunctionDispatcherCase = {
	id:Int,
	target:String,
	makeName:Null<String>,
	captureTypes:Array<String>,
	captureVars:Array<String>
}

typedef FunctionDispatcher = {
	name:String,
	retType:String,
	argTypes:Array<String>,
	cases:Array<FunctionDispatcherCase>,
	caseIds:Map<String, FunctionDispatcherCase>,
	nextId:Int
}
#end

class ShaderSourceBuilder {
	public static var VERSION = "450";

	#if macro
	static final typeDefCache:Map<String, TypeDef> = new Map();
	static final typeDefBuildInProgress:Map<String, Bool> = new Map();
	static var currentEntryDefinedTypes:Map<String, Bool> = null;
	static var currentEntryDispatchers:Map<String, FunctionDispatcher> = null;
	static var currentEntryDispatcherSeq:Int = 0;
	static var currentEntryHelperSeq:Int = 0;

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
		if (currentEntryDefinedTypes == null || type.name == null)
			return cloneTypeDef(type);
		if (currentEntryDefinedTypes.exists(type.name)) {
			return {
				name: type.name,
				def: []
			};
		}
		currentEntryDefinedTypes.set(type.name, true);
		return cloneTypeDef(type);
	}

	static function dispatcherKey(retType:String, argTypes:Array<String>):String
		return retType + "(" + argTypes.join(",") + ")";

	static function ensureDispatcher(retType:String, argTypes:Array<String>):FunctionDispatcher {
		if (currentEntryDispatchers == null)
			currentEntryDispatchers = new Map();
		var key = dispatcherKey(retType, argTypes);
		var existing = currentEntryDispatchers.get(key);
		if (existing != null)
			return existing;

		currentEntryDispatcherSeq++;
		var created:FunctionDispatcher = {
			name: "__fn_dispatch_" + currentEntryDispatcherSeq,
			retType: retType,
			argTypes: argTypes.copy(),
			cases: [],
			caseIds: new Map(),
			nextId: 1
		};
		currentEntryDispatchers.set(key, created);
		return created;
	}

	static function registerDispatcherTarget(retType:String, argTypes:Array<String>, target:String, captureTypes:Array<String>,
			siteKey:String):FunctionDispatcherCase {
		var dispatcher = ensureDispatcher(retType, argTypes);
		var key = target + "|" + captureTypes.join(",") + "|" + (captureTypes.length == 0 ? "" : siteKey);
		var existing = dispatcher.caseIds.get(key);
		if (existing != null)
			return existing;

		var id = dispatcher.nextId++;
		var captureVars = [];
		for (i in 0...captureTypes.length)
			captureVars.push("__fn_cap_" + dispatcher.name + "_" + id + "_" + i);
		var c:FunctionDispatcherCase = {
			id: id,
			target: target,
			makeName: captureTypes.length == 0 ? null : "__fn_make_" + dispatcher.name + "_" + id,
			captureTypes: captureTypes.copy(),
			captureVars: captureVars
		};
		dispatcher.caseIds.set(key, c);
		dispatcher.cases.push(c);
		return c;
	}

	static function defaultValueExpr(typeName:String):String {
		return switch typeName {
			case "bool":
				"false";
			case "int", "uint":
				"0";
			case "float", "double":
				"0.0";
			default:
				null;
		}
	}

	static function buildDispatchers():Array<String> {
		if (currentEntryDispatchers == null || !currentEntryDispatchers.iterator().hasNext())
			return [];

		var defs = [];
		for (d in currentEntryDispatchers) {
			var b = new StringBuf();
			var argNames = [];
			var signature = ["int __fn"];
			for (i in 0...d.argTypes.length) {
				var argName = "__a" + i;
				argNames.push(argName);
				signature.push(d.argTypes[i] + " " + argName);
			}

			for (c in d.cases) {
				if (c.captureTypes.length == 0)
					continue;
				for (i in 0...c.captureTypes.length)
					b.add(c.captureTypes[i] + " " + c.captureVars[i] + ";\n");
				var makeSig = [];
				for (i in 0...c.captureTypes.length)
					makeSig.push(c.captureTypes[i] + " __cap" + i);
				b.add("int " + c.makeName + "(" + makeSig.join(", ") + ") {\n");
				for (i in 0...c.captureTypes.length)
					b.add("\t" + c.captureVars[i] + " = __cap" + i + ";\n");
				b.add("\treturn " + c.id + ";\n");
				b.add("}\n");
			}

			b.add(d.retType + " " + d.name + "(" + signature.join(", ") + ") {\n");
			b.add("\tswitch (__fn) {\n");
			for (c in d.cases) {
				b.add("\t\tcase " + c.id + ":\n");
				b.add("\t\t{\n");
				var callArgs = c.captureVars.copy().concat(argNames);
				if (d.retType == "Void" || d.retType == "void") {
					b.add("\t\t\t" + c.target + "(" + callArgs.join(", ") + ");\n");
					b.add("\t\t\treturn;\n");
				} else {
					b.add("\t\t\treturn " + c.target + "(" + callArgs.join(", ") + ");\n");
				}
				b.add("\t\t}\n");
			}
			b.add("\t\tdefault:\n");
			b.add("\t\t{\n");
			if (d.retType == "Void" || d.retType == "void")
				b.add("\t\t\treturn;\n");
			else {
				var def = defaultValueExpr(d.retType);
				if (def != null)
					b.add("\t\t\treturn " + def + ";\n");
				else {
					b.add("\t\t\t" + d.retType + " __fallback;\n");
					b.add("\t\t\treturn __fallback;\n");
				}
			}
			b.add("\t\t}\n");
			b.add("\t}\n");
			b.add("}\n");
			defs.push(b.toString());
		}
		return defs;
	}

	public static function build() {
		var fields = Context.getBuildFields();

		for (field in fields)
			if (field.name == "__vert__" || field.name == "__frag__") {
				switch field.kind {
					case FFun(f):
						f.expr = {
							expr: switch f.expr.expr {
								case EBlock(exprs):
									EBlock(exprs.concat([macro return null]));
								default:
									EBlock([f.expr, macro return null]);
							},
							pos: f.expr.pos
						}
					default:
				}
			}

		Context.onAfterTyping(_ -> {
			var cls = Context.getLocalClass()?.get();
			if (cls == null)
				return;

			for (field in cls.fields.get())
				if (field.name == "__vert__" || field.name == "__frag__") {
					var src = buildShaderSource(field);
					trace(src);
				}
		});

		return fields;
	}

	static function buildShaderSource(field:ClassField) {
		switch field.expr().expr {
			case TFunction(tfunc):
				var prevEntryTypes = currentEntryDefinedTypes;
				var prevDispatchers = currentEntryDispatchers;
				var prevDispatcherSeq = currentEntryDispatcherSeq;
				var prevHelperSeq = currentEntryHelperSeq;
				currentEntryDefinedTypes = new Map();
				currentEntryDispatchers = new Map();
				currentEntryDispatcherSeq = 0;
				currentEntryHelperSeq = 0;
				var buf = new StringBuf();

				var p = parseEntryPoint(tfunc, field.pos);
				var body = p.body.expr;
				var statics = p.body.statics;

				function addVarying(v:Varying, d:String) {
					function addTypeDef(t:TypeDef) {
						statics = statics.concat(t.def);
						return t.name;
					}

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
				if (VERSION != null)
					buf.add('#version $VERSION\n\n');

				// in
				var vin = p.varIn;
				if (vin.length > 0) {
					for (i in 0...vin.length)
						addVarying(vin[i], "in");
					buf.add("\n");
				}

				// out
				var vout = p.varOut;
				if (vout.length > 0) {
					for (i in 0...vout.length)
						addVarying(vout[i], "out");
					buf.add("\n");
				}

				// statics
				statics = statics.concat(buildDispatchers());
				var uniqueStatics = new Map<String, Bool>();
				for (s in statics) {
					if (s.length == 0 || uniqueStatics.exists(s))
						continue;
					uniqueStatics.set(s, true);
					buf.add(s + "\n");
				}

				// body
				if (body.length > 0) {
					buf.add("void main() ");
					buf.add(body);
					buf.add("\n");
				}

				var result = buf.toString();
				currentEntryDefinedTypes = prevEntryTypes;
				currentEntryDispatchers = prevDispatchers;
				currentEntryDispatcherSeq = prevDispatcherSeq;
				currentEntryHelperSeq = prevHelperSeq;
				return result;
			default:
				Context.error("Shader entry point should be function", field.pos);
				return null;
		}
	}

	static function parseEntryPoint(func:TFunc, pos:Position):EntryPoint {
		function parseVarying(args:Array<{name:String, type:TypeDef, meta:MetaAccess}>) {
			var varyings = [];
			for (i in 0...args.length) {
				var a = args[i];
				var name = a.name;
				var type = a.type;
				var meta = a.meta;

				function getParam(p:String, d:Expr) {
					if (!meta.has(p))
						return d;
					var m = meta.extract(p)[0];
					var params = m.params;
					if (params == null || params.length == 0) {
						Context.warning("Value expected", m.pos);
						return d;
					}
					if (params.length > 1) {
						Context.warning("Too much values", m.pos);
						return d;
					}
					return m.params[0];
				}

				function getInterp(q:String) {
					var aux = getParam(q, macro none);
					return switch aux.expr {
						case EConst(CIdent(s)):
							switch s {
								case "none":
									NONE;
								case "sample":
									SAMPLE;
								case "centroid":
									CENTROID;
								default:
									Context.warning("Invalid auxiliary qualifier", aux.pos);
									NONE;
							}
						default:
							Context.warning("Invalid auxiliary qualifier", aux.pos);
							NONE;
					}
				}

				varyings.push({
					name: name,
					type: type,
					interp: {
						if (meta.has("flat"))
							FLAT;
						else if (meta.has("smooth"))
							SMOOTH(getInterp("smooth"));
						else if (meta.has("noperspective"))
							NOPERSPECTIVE(getInterp("noperspective"));
						else
							SMOOTH(NONE);
					},
					location: {
						var loc = getParam("location", macro $v{i});
						switch loc.expr {
							case EConst(CInt(s)):
								var l = Std.parseInt(s);
								if (l == null) {
									l = i;
									Context.warning("Invalid location", loc.pos);
								}
								l;
							default:
								Context.warning("Invalid location", loc.pos);
								i;
						}
					}
				});
			}

			return varyings;
		}

		function getVarOut(type:Type) {
			return switch type {
				case TAnonymous(a):
					parseVarying(a.get().fields.map(f -> {
						name: f.name,
						type: defType(f.type, f.pos),
						meta: f.meta
					}));
				case TType(t, _):
					getVarOut(t.get().type);
				default:
					Context.error("Invalid return type", pos);
			}
		}

		return {
			varIn: parseVarying(func.args.map(a -> {
				name: a.v.name,
				type: defType(a.v.t, pos),
				meta: a.v.meta
			})),
			varOut: getVarOut(func.t),
			body: transBody(func.expr)
		}
	}

	// expressions

	static function transBody(expr:TypedExpr, endLine:Bool = false, breakLine:Bool = false, depth:Int = 0, makeIdent = true,
			ctx:TransContext = null):EntryPointBody {
		if (ctx == null)
			ctx = {
				locals: new Map(),
				usedLocalNames: new Map()
			};

		final statics = [];
		final buf = new StringBuf();

		function indent(?d:Int)
			for (_ in 0...(d ?? depth))
				buf.add("\t");

		function addExpr(expr:TypedExpr, endLine:Bool = false, breakLine:Bool = false, depth:Int = 0, makeIdent = true) {
			var body = transBody(expr, endLine, breakLine, depth, makeIdent, ctx);
			for (s in body.statics)
				statics.push(s);
			return body.expr;
		}

		function addInline(expr:TypedExpr)
			return addExpr(expr, false, false, 0, false);

		function addTypeDef(type:TypeDef) {
			for (s in type.def)
				statics.push(s);
			return type.name;
		}

		function addType(t:Type)
			return addTypeDef(defType(t, expr.pos));

		function addClassType(t:Ref<ClassType>, params:Array<Type>)
			return addTypeDef(defType(TInst(t, params), expr.pos));

		function addModuleType(t:ModuleType)
			return addTypeDef(defModuleType(t));

		function isFunctionType(t:Type):Bool {
			return switch t.follow() {
				case TFun(_, _):
					true;
				default:
					false;
			}
		}

		function functionSignature(t:Type) {
			return switch t.follow() {
				case TFun(args, ret):
					var retDef = defType(ret, expr.pos);
					for (s in retDef.def)
						statics.push(s);
					var argDefs = [];
					for (a in args) {
						var d = defType(a.t, expr.pos);
						for (s in d.def)
							statics.push(s);
						argDefs.push(d.name);
					}
					{
						retType: retDef.name,
						argTypes: argDefs
					};
				default:
					null;
			}
		}

		function unwrapWrapperExpr(e:TypedExpr):TypedExpr {
			var cur = e;
			while (true)
				switch cur.expr {
					case TMeta(_, inner):
						cur = inner;
					case TParenthesis(inner):
						cur = inner;
					case TCast(inner, null):
						cur = inner;
					case TBlock(el) if (el.length == 1):
						cur = el[0];
					default:
						return cur;
				}
			return cur;
		}

		function needsSemicolon(e:TypedExpr):Bool {
			return switch e.expr {
				case TMeta(_, inner):
					needsSemicolon(inner);
				case TBlock(_), TIf(_, _, _), TWhile(_, _, _), TFor(_, _, _), TSwitch(_, _, _):
					false;
				default:
					true;
			}
		}

		function reserveLocalName(raw:String):String {
			var base = sanitizeIdent(raw);
			if (base == "_" || base == "this" || base == "__self")
				base = "__tmp";

			var count = ctx.usedLocalNames.get(base);
			if (count == null) {
				ctx.usedLocalNames.set(base, 1);
				return base;
			}

			var name = base + "_" + count;
			var i = count + 1;
			while (ctx.usedLocalNames.exists(name)) {
				name = base + "_" + i;
				i++;
			}
			ctx.usedLocalNames.set(base, i);
			ctx.usedLocalNames.set(name, 1);
			return name;
		}

		function localName(v:TVar):String {
			if (ctx.locals.exists(v.id))
				return ctx.locals.get(v.id);
			var name = reserveLocalName(v.name);
			ctx.locals.set(v.id, name);
			return name;
		}

		function canInlineValueExpr(e:TypedExpr):Bool {
			var v = unwrapWrapperExpr(e);
			return switch v.expr {
				case TBlock(_), TFor(_, _, _), TWhile(_, _, _), TSwitch(_, _, _), TReturn(_), TBreak, TContinue:
					false;
				default:
					true;
			}
		}

		function nextHelperName(prefix:String):String {
			currentEntryHelperSeq++;
			return prefix + currentEntryHelperSeq;
		}

		function functionTypeParts(t:Type, p:Position):{args:Array<{name:String, opt:Bool, t:Type}>, ret:Type} {
			return switch t.follow() {
				case TFun(args, ret):
					{args: args, ret: ret};
				default:
					Context.error("Function type expected", p);
					{args: [], ret: Context.typeof(macro 0)};
			}
		}

		function typeNameOfExprType(t:Type, p:Position):String {
			var td = defType(t, p);
			for (s in td.def)
				statics.push(s);
			return td.name;
		}

		function makeFunctionCase(retType:String, argTypes:Array<String>, target:String, captures:Array<{t:Type, expr:String}>, p:Position):String {
			var capTypes = [];
			var capExprs = [];
			for (c in captures) {
				capTypes.push(typeNameOfExprType(c.t, p));
				capExprs.push(c.expr);
			}
			var pos = Context.getPosInfos(p);
			var c = registerDispatcherTarget(retType, argTypes, target, capTypes, pos.min + "_" + pos.max);
			if (capExprs.length == 0 || c.makeName == null)
				return Std.string(c.id);
			return c.makeName + "(" + capExprs.join(", ") + ")";
		}

		function buildBoundMethodWrapper(name:String, retType:String, fieldName:String, selfType:String, argTypes:Array<String>, isExtern:Bool):String {
			var b = new StringBuf();
			var argsDecl = [selfType + " __self_cap"];
			var argsCall = [];
			for (i in 0...argTypes.length) {
				argsDecl.push(argTypes[i] + " __a" + i);
				argsCall.push("__a" + i);
			}
			b.add(retType + " " + name + "(" + argsDecl.join(", ") + ") {\n");
			var call = isExtern ? ("__self_cap." + fieldName + "(" + argsCall.join(", ") + ")") : (fieldName + "(__self_cap"
				+ (argsCall.length > 0 ? ", " + argsCall.join(", ") : "") + ")");
			if (retType == "Void" || retType == "void")
				b.add("\t" + call + ";\n\treturn;\n");
			else
				b.add("\treturn " + call + ";\n");
			b.add("}\n");
			return b.toString();
		}

		function lowerLambdaFunction(func:TFunc, sigType:Type, p:Position):{target:String, captures:Array<{t:Type, expr:String}>} {
			var parts = functionTypeParts(sigType, p);
			var hasThis = false;
			var argIds = new Map<Int, Bool>();
			for (a in func.args)
				argIds.set(a.v.id, true);
			var capById:Map<Int, TVar> = new Map();

			function visitCaptureExpr(e:TypedExpr) {
				switch e.expr {
					case TConst(TThis), TConst(TSuper):
						hasThis = true;
					case TLocal(v):
						if (!argIds.exists(v.id) && ctx.locals.exists(v.id))
							capById.set(v.id, v);
					default:
				}
				e.iter(visitCaptureExpr);
			}

			visitCaptureExpr(func.expr);
			if (hasThis)
				Context.error("this/super captures in lambda function values are not supported in GLSL", p);

			var captures = [for (v in capById) v];
			captures.sort((a, b) -> a.id - b.id);

			var lambdaName = nextHelperName("__fn_lambda_");
			var argsDecl = [];
			var capExprs:Array<{t:Type, expr:String}> = [];
			var lambdaCtx:TransContext = {
				locals: new Map(),
				usedLocalNames: new Map()
			};

			for (i in 0...captures.length) {
				var v = captures[i];
				var tname = typeNameOfExprType(v.t, p);
				var aname = "__cap" + i;
				argsDecl.push(tname + " " + aname);
				lambdaCtx.locals.set(v.id, aname);
				lambdaCtx.usedLocalNames.set(aname, 1);
				var outerName = ctx.locals.exists(v.id) ? ctx.locals.get(v.id) : localName(v);
				capExprs.push({t: v.t, expr: outerName});
			}

			for (i in 0...parts.args.length) {
				var a = parts.args[i];
				var tname = typeNameOfExprType(a.t, p);
				var aname = "__a" + i;
				argsDecl.push(tname + " " + aname);
				if (i < func.args.length)
					lambdaCtx.locals.set(func.args[i].v.id, aname);
				lambdaCtx.usedLocalNames.set(aname, 1);
			}

			var retType = typeNameOfExprType(parts.ret, p);
			var body = transBody(func.expr, false, false, 0, false, lambdaCtx);
			for (s in body.statics)
				statics.push(s);

			var b = new StringBuf();
			b.add(retType + " " + lambdaName + "(" + argsDecl.join(", ") + ") ");
			if (body.expr.length > 0 && body.expr.charAt(0) == "{")
				b.add(body.expr + "\n");
			else
				b.add("{\n\t" + body.expr + ";\n}\n");
			statics.push(b.toString());

			return {
				target: lambdaName,
				captures: capExprs
			};
		}

		function lowerFunctionTarget(e:TypedExpr, sigType:Type):{target:String, captures:Array<{t:Type, expr:String}>} {
			var parts = functionTypeParts(sigType, e.pos);
			var retType = typeNameOfExprType(parts.ret, e.pos);
			var argTypes = [];
			for (a in parts.args)
				argTypes.push(typeNameOfExprType(a.t, e.pos));
			var u = unwrapWrapperExpr(e);

			return switch u.expr {
				case TFunction(func):
					lowerLambdaFunction(func, sigType, u.pos);
				case TField(_, FStatic(c, cf)):
					if (c.get().isExtern || cf.get().meta.has(":native")) {
						target: fieldNativeName(cf.get()),
						captures: []
					} else {
						var className = addClassType(c, []);
						{
							target: classMemberName(className, cf.get().name),
							captures: []
						};
					}
				case TField(_, FEnum(enumRef, ef)):
					var enumTypeName = addTypeDef(defEnum(enumRef.get(), []));
					{
						target: enumCtorFunctionName(enumTypeName, ef.name),
						captures: []
					};
				case TField(target, FInstance(c, params, cf)):
					var owner = c.get();
					var selfType = typeNameOfExprType(target.t, target.pos);
					if (owner.isExtern || cf.get().meta.has(":native")) {
						var helperName = nextHelperName("__fn_bound_");
						statics.push(buildBoundMethodWrapper(helperName, retType, fieldNativeName(cf.get()), selfType, argTypes, true));
						{
							target: helperName,
							captures: [{t: target.t, expr: addInline(target)}]
						};
					} else {
						var className = addClassType(c, params);
						{
							target: classMemberName(className, cf.get().name),
							captures: [{t: target.t, expr: addInline(target)}]
						};
					}
				case TField(target, FClosure(c, cf)):
					switch c {
						case null:
							Context.error("Unsupported function value", u.pos);
							{
								target: "__invalid_fn",
								captures: []
							};
						case cc:
							var owner = cc.c.get();
							var selfType = typeNameOfExprType(target.t, target.pos);
							if (owner.isExtern || cf.get().meta.has(":native")) {
								var helperName = nextHelperName("__fn_bound_");
								statics.push(buildBoundMethodWrapper(helperName, retType, fieldNativeName(cf.get()), selfType, argTypes, true));
								{
									target: helperName,
									captures: [{t: target.t, expr: addInline(target)}]
								};
							} else {
								var className = addClassType(cc.c, cc.params);
								{
									target: classMemberName(className, cf.get().name),
									captures: [{t: target.t, expr: addInline(target)}]
								};
							}
					}
				default:
					Context.error("Unsupported function value", u.pos);
					{
						target: "__invalid_fn",
						captures: []
					};
			}
		}

		function assertFunctionCompatible(actual:Type, expected:Type, p:Position) {
			switch [actual.follow(), expected.follow()] {
				case [TFun(aArgs, aRet), TFun(eArgs, eRet)]:
					if (aArgs.length != eArgs.length)
						Context.error("Function arity mismatch in function value assignment/call", p);
					for (i in 0...aArgs.length)
						if (!Context.unify(aArgs[i].t, eArgs[i].t))
							Context.error("Function argument type mismatch in function value assignment/call", p);
					if (!Context.unify(aRet, eRet))
						Context.error("Function return type mismatch in function value assignment/call", p);
				default:
					Context.error("Function type expected", p);
			}
		}

		function functionValueExpr(e:TypedExpr, expected:Type = null):String {
			function switchExpr(es:TypedExpr, cases:Array<{values:Array<TypedExpr>, expr:Null<TypedExpr>}>, edef:Null<TypedExpr>, p:Position,
					?subjectOverride:String):String {
				var isEnumSwitch = switch es.t.follow() {
					case TEnum(_, _):
						true;
					default:
						false;
				}
				var subject = subjectOverride != null ? subjectOverride : addInline(es);
				if (isEnumSwitch)
					subject += "." + enumTagFieldName();
				var current = edef != null ? functionValueExpr(edef, expected) : "0";
				for (i in 0...cases.length) {
					var c = cases[cases.length - 1 - i];
					if (c.expr == null)
						Context.error("Switch function-value case should return a function", p);
					var branch = functionValueExpr(c.expr, expected);
					var checks = [];
					for (v in c.values) {
						var caseValue = isEnumSwitch ? enumCaseValueIndex(v) : addInline(v);
						checks.push(subject + " == " + caseValue);
					}
					var cond = checks.length == 0 ? "false" : (checks.length == 1 ? checks[0] : "(" + checks.join(" || ") + ")");
					current = "(" + cond + " ? " + branch + " : " + current + ")";
				}
				return current;
			}

			var u = unwrapWrapperExpr(e);
			switch u.expr {
				case TIf(cond, eif, eelse) if (eelse != null):
					return "(" + addInline(cond) + " ? " + functionValueExpr(eif, expected) + " : " + functionValueExpr(eelse, expected) + ")";
				case TSwitch(es, cases, edef):
					return switchExpr(es, cases, edef, u.pos);
				case TBlock(el) if (el.length > 0):
					var restored:Array<{id:Int, had:Bool, name:String}> = [];
					for (i in 0...el.length - 1) {
						var pre = unwrapWrapperExpr(el[i]);
						switch pre.expr {
							case TVar(tv, einit) if (einit != null):
								restored.push({
									id: tv.id,
									had: ctx.locals.exists(tv.id),
									name: ctx.locals.get(tv.id)
								});
								ctx.locals.set(tv.id, "(" + addInline(einit) + ")");
							default:
								Context.error("Unsupported statements in function-value expression block", pre.pos);
						}
					}
					var result = functionValueExpr(el[el.length - 1], expected);
					for (i in 0...restored.length) {
						var r = restored[restored.length - 1 - i];
						if (r.had)
							ctx.locals.set(r.id, r.name);
						else
							ctx.locals.remove(r.id);
					}
					return result;
				default:
			}

			switch u.expr {
				case TLocal(v) if (isFunctionType(v.t)):
					if (expected != null)
						assertFunctionCompatible(v.t, expected, u.pos);
					return localName(v);
				default:
			}

			if (expected != null)
				assertFunctionCompatible(u.t, expected, u.pos);

			var sigType = expected != null ? expected : u.t;
			var sig = functionSignature(sigType);
			if (sig == null)
				Context.error("Function value is expected", u.pos);

			var lowered = lowerFunctionTarget(u, sigType);
			return makeFunctionCase(sig.retType, sig.argTypes, lowered.target, lowered.captures, u.pos);
		}

		function callArgs(args:Array<TypedExpr>, expected:Array<{name:String, opt:Bool, t:Type}>):Array<String> {
			var out = [];
			for (i in 0...args.length) {
				var exp = (expected != null && i < expected.length) ? expected[i].t : null;
				if (exp != null && isFunctionType(exp))
					out.push(functionValueExpr(args[i], exp));
				else
					out.push(addInline(args[i]));
			}
			return out;
		}

		function directCallSig(e:TypedExpr):Array<{name:String, opt:Bool, t:Type}> {
			return switch e.t.follow() {
				case TFun(args, _):
					args;
				default:
					[];
			}
		}

		function isFunctionValueCallee(e:TypedExpr):Bool {
			var u = unwrapWrapperExpr(e);
			return switch u.expr {
				case TLocal(v):
					isFunctionType(v.t);
				case TField(_, FClosure(_, _)):
					true;
				case TFunction(_):
					true;
				case TIf(_, _, _):
					true;
				case TSwitch(_, _, _):
					true;
				default:
					false;
			}
		}

		function emitStatement(e:TypedExpr, d:Int) {
			var stmt = unwrapWrapperExpr(e);
			var needsSemi = needsSemicolon(stmt);
			buf.add(addExpr(stmt, needsSemi, !needsSemi, d));
		}

		function emitAsBlock(e:TypedExpr, d:Int) {
			var branch = unwrapWrapperExpr(e);
			switch branch.expr {
				case TBlock(_):
					buf.add(addExpr(branch, false, false, d));
				default:
					buf.add("{\n");
					emitStatement(branch, d + 1);
					indent(d);
					buf.add("}");
			}
		}

		if (makeIdent)
			indent();

		switch expr.expr {
			case TConst(TInt(v)):
				buf.add(v);
			case TConst(TFloat(v)):
				buf.add(v);
			case TConst(TString(v)):
				buf.add(v);
			case TConst(TBool(v)):
				buf.add(v);
			case TConst(TNull):
				buf.add("0");
			case TConst(TThis):
				buf.add("__self");
			case TConst(TSuper):
				buf.add("__self");
			case TLocal(v):
				buf.add(localName(v));
			case TArray(e1, e2):
				buf.add(addInline(e1) + "[" + addInline(e2) + "]");
			case TBinop(op, e1, e2):
				if (op == OpAssign && isFunctionType(e1.t))
					buf.add(addInline(e1) + " = " + functionValueExpr(e2, e1.t));
				else
					buf.add(addInline(e1) + " " + transBinOp(op, expr.pos) + " " + addInline(e2));
			case TField(e, fa):
				switch fa {
					case FInstance(c, params, cf):
						var field = cf.get();
						var owner = c.get();
						switch field.kind {
							case FVar(_, _):
								buf.add(addInline(e) + "." + fieldNativeName(field));
							case FMethod(_):
								if (owner.isExtern || field.meta.has(":native")) buf.add(addInline(e) + "." + fieldNativeName(field)); else {
									var className = addClassType(c, params);
									buf.add(classMemberName(className, field.name));
								}
						}
					case FStatic(c, cf):
						var owner = c.get();
						var field = cf.get();
						if (owner.isExtern || field.meta.has(":native")) buf.add(fieldNativeName(field)); else {
							var className = addClassType(c, []);
							buf.add(classMemberName(className, field.name));
						}
					case FAnon(cf):
						buf.add(addInline(e) + "." + sanitizeIdent(cf.get().name));
					case FDynamic(s):
						buf.add(addInline(e) + "." + sanitizeIdent(s));
					case FClosure(c, cf):
						var owner = switch c {
							case null:
								null;
							case v:
								addClassType(v.c, v.params);
						}
						if (owner == null) buf.add(sanitizeIdent(cf.get()
							.name)); else if (c != null
							&& (c.c.get()
								.isExtern || cf.get()
								.meta.has(":native"))) buf.add(fieldNativeName(cf.get())); else buf.add(classMemberName(owner, cf.get().name));
					case FEnum(enumRef, ef):
						var enumTypeName = addTypeDef(defEnum(enumRef.get(), []));
						var ctorName = enumCtorFunctionName(enumTypeName, ef.name);
						if (enumFieldArgs(ef).length == 0) buf.add(ctorName + "()"); else buf.add(ctorName);
				}
			case TTypeExpr(m):
				buf.add(addModuleType(m));
			case TParenthesis(e):
				buf.add("(" + addInline(e) + ")");
			case TObjectDecl(fields):
				var anonTypeName = addType(expr.t);
				var byName = new Map<String, TypedExpr>();
				for (f in fields)
					byName.set(f.name, f.expr);

				function fieldOrder(type:Type):Array<String> {
					return switch type.follow() {
						case TAnonymous(a):
							a.get().fields.map(f -> f.name);
						case TType(t, _):
							fieldOrder(t.get().type);
						default:
							fields.map(f -> f.name);
					}
				}

				var values = [];
				for (name in fieldOrder(expr.t)) {
					var value = byName.get(name);
					if (value == null)
						Context.error('Object literal field "$name" is missing', expr.pos);
					values.push(addInline(value));
				}
				buf.add(anonTypeName + "(" + values.join(", ") + ")");
			case TArrayDecl(values):
				buf.add("[" + values.map(e -> addInline(e)).join(", ") + "]");
			case TCall(e, el):
				var callee = unwrapWrapperExpr(e);
				var directSig = directCallSig(callee);
				var args = callArgs(el, directSig);

				function emitDispatch() {
					var sig = functionSignature(callee.t);
					if (sig == null)
						Context.error("Function-value call expects function type", callee.pos);
					var fnExpr = isFunctionValueCallee(callee) ? functionValueExpr(callee, callee.t) : addInline(callee);
					var call = ensureDispatcher(sig.retType, sig.argTypes).name + "(" + fnExpr;
					if (args.length > 0)
						call += ", " + args.join(", ");
					call += ")";
					buf.add(call);
				}

				switch callee.expr {
					case TIdent("enumIndex") if (el.length == 1):
						buf.add(addInline(el[0]) + "." + enumTagFieldName());
					case TField(target, FInstance(c, params, cf)):
						switch cf.get().kind {
							case FMethod(_):
								if (c.get()
									.isExtern || cf.get()
									.meta.has(":native")) buf.add(addInline(target) + "." + fieldNativeName(cf.get()) + "(" + args.join(", ") + ")"); else {
									var className = addClassType(c, params);
									args.unshift(addInline(target));
									buf.add(classMemberName(className, cf.get().name) + "(" + args.join(", ") + ")");
								}
							case FVar(_, _):
								emitDispatch();
						}
					case TField(_, FStatic(_, cf)):
						switch cf.get().kind {
							case FMethod(_):
								buf.add(addInline(callee) + "(" + args.join(", ") + ")");
							case FVar(_, _):
								emitDispatch();
						}
					case TField(_, FEnum(_, _)):
						buf.add(addInline(callee) + "(" + args.join(", ") + ")");
					default:
						if (isFunctionValueCallee(callee)) emitDispatch(); else buf.add(addInline(callee) + "(" + args.join(", ") + ")");
				}
			case TNew(c, params, el):
				var typeName = addClassType(c, params);
				buf.add(typeName + "(" + el.map(e -> addInline(e)).join(", ") + ")");
			case TUnop(op, postFix, e):
				if (postFix)
					buf.add(addInline(e) + transUnOp(op, expr.pos));
				else
					buf.add(transUnOp(op, expr.pos) + addInline(e));
			case TFunction(_):
				if (isFunctionType(expr.t))
					buf.add(functionValueExpr(expr, expr.t));
				else
					Context.error("Invalid lambda expression", expr.pos);
			case TVar(v, einit):
				buf.add(addType(v.t) + " " + localName(v));
				if (einit != null)
					buf.add(" = " + (isFunctionType(v.t) ? functionValueExpr(einit, v.t) : addInline(einit)));
			case TBlock(el):
				buf.add("{\n");
				var terminated = false;
				for (e in el) {
					if (terminated)
						continue;
					var stmt = unwrapWrapperExpr(e);
					emitStatement(stmt, depth + 1);
					terminated = switch stmt.expr {
						case TReturn(_), TBreak, TContinue:
							true;
						default:
							false;
					}
				}
				indent();
				buf.add("}");
			case TFor(v, e1, e2):
				var s = localName(v);
				switch e1.expr {
					case TBinop(OpInterval, eFrom, eTo):
						buf.add('for (${addType(v.t)} $s = ${addInline(eFrom)}; $s < ${addInline(eTo)}; $s++) ');
						emitAsBlock(e2, depth);
					default:
						var p = Context.getPosInfos(expr.pos);
						var iterName = "__iter_" + p.min + "_" + p.max;
						buf.add("{\n");
						indent(depth + 1);
						buf.add(addType(e1.t) + " " + iterName + " = " + addInline(e1) + ";\n");
						indent(depth + 1);
						buf.add("while (" + iterName + ".hasNext()) {\n");
						indent(depth + 2);
						buf.add(addType(v.t) + " " + s + " = " + iterName + ".next();\n");
						var loopBody = unwrapWrapperExpr(e2);
						switch loopBody.expr {
							case TBlock(el):
								for (stmt in el)
									emitStatement(stmt, depth + 2);
							default:
								emitStatement(loopBody, depth + 2);
						}
						indent(depth + 1);
						buf.add("}\n");
						indent(depth);
						buf.add("}");
				}
			case TIf(econd, eif, eelse):
				var isInlineContext = !makeIdent && !endLine && !breakLine;
				if (isInlineContext && eelse != null && canInlineValueExpr(eif) && canInlineValueExpr(eelse)) {
					buf.add("(" + addInline(econd) + " ? " + addInline(unwrapWrapperExpr(eif)) + " : " + addInline(unwrapWrapperExpr(eelse)) + ")");
				} else {
					buf.add("if (" + addInline(econd) + ") ");
					emitAsBlock(eif, depth);
					if (eelse != null) {
						buf.add(" else ");
						emitAsBlock(eelse, depth);
					}
				}
			case TWhile(econd, e, normalWhile):
				if (normalWhile) {
					buf.add("while (" + addInline(econd) + ") ");
					emitAsBlock(e, depth);
				} else {
					buf.add("do ");
					emitAsBlock(e, depth);
					buf.add(" while (" + addInline(econd) + ");");
				}
			case TSwitch(e, cases, edef):
				var isEnumSwitch = switch e.t.follow() {
					case TEnum(_, _):
						true;
					default:
						false;
				}
				var switchExpr = addInline(e);
				if (isEnumSwitch)
					switchExpr += "." + enumTagFieldName();
				buf.add("switch (" + switchExpr + ") {\n");
				for (c in cases) {
					for (v in c.values) {
						indent(depth + 1);
						var caseValue = isEnumSwitch ? enumCaseValueIndex(v) : addInline(v);
						buf.add("case " + caseValue + ":\n");
					}
					indent(depth + 1);
					buf.add("{\n");
					if (c.expr != null) {
						var caseExpr = unwrapWrapperExpr(c.expr);
						switch caseExpr.expr {
							case TBlock(el):
								for (stmt in el)
									emitStatement(stmt, depth + 2);
							default:
								emitStatement(caseExpr, depth + 2);
						}
					}
					indent(depth + 2);
					buf.add("break;\n");
					indent(depth + 1);
					buf.add("}\n");
				}
				if (edef != null) {
					indent(depth + 1);
					buf.add("default:\n");
					indent(depth + 1);
					buf.add("{\n");
					var defaultExpr = unwrapWrapperExpr(edef);
					switch defaultExpr.expr {
						case TBlock(el):
							for (stmt in el)
								emitStatement(stmt, depth + 2);
						default:
							emitStatement(defaultExpr, depth + 2);
					}
					indent(depth + 2);
					buf.add("break;\n");
					indent(depth + 1);
					buf.add("}\n");
				}
				indent();
				buf.add("}");
			case TReturn(e):
				buf.add("return");
				if (e != null)
					switch e.expr {
						case TConst(TNull):
						default:
							buf.add(" " + addInline(e));
					}
			case TBreak:
				buf.add("break");
			case TContinue:
				buf.add("continue");
			case TCast(e, m):
				if (m != null)
					buf.add(addModuleType(m) + "(" + addInline(e) + ")");
				else
					buf.add(addInline(e));
			case TMeta(_, e):
				buf.add(addInline(e));
			case TEnumParameter(e1, ef, index):
				buf.add(addInline(e1) + "." + enumPayloadFieldName(ef.name, index));
			case TEnumIndex(e1):
				buf.add(addInline(e1) + "." + enumTagFieldName());
			case TIdent(v):
				buf.add(sanitizeIdent(v));
			default:
				Context.error("Invalid expression", expr.pos);
		}
		if (endLine)
			buf.add(";\n");
		if (breakLine)
			buf.add("\n");

		return {
			statics: statics,
			expr: buf.toString()
		}
	}

	static function transBinOp(op:Binop, pos:Position) {
		return switch op {
			case OpAdd: "+";
			case OpMult: "*";
			case OpDiv: "/";
			case OpSub: "-";
			case OpAssign: "=";
			case OpEq: "==";
			case OpNotEq: "!=";
			case OpGt: ">";
			case OpGte: ">=";
			case OpLt: "<";
			case OpLte: "<=";
			case OpAnd: "&";
			case OpOr: "|";
			case OpXor: "^";
			case OpBoolAnd: "&&";
			case OpBoolOr: "||";
			case OpShl: "<<";
			case OpShr: ">>";
			case OpMod: "%";
			case OpAssignOp(op): transBinOp(op, pos) + "=";
			default:
				Context.error("Invalid operation", pos);
		}
	}

	static function transUnOp(op:Unop, pos:Position) {
		return switch op {
			case OpIncrement: "++";
			case OpDecrement: "--";
			case OpNot: "!";
			case OpNeg: "-";
			case OpNegBits: "~";
			default:
				Context.error("Invalid operation", pos);
		}
	}

	static inline function enumTagFieldName()
		return "__tag";

	static inline function enumPayloadFieldName(ctorName:String, index:Int)
		return "__" + ctorName + "_" + index;

	static inline function enumCtorFunctionName(enumTypeName:String, ctorName:String)
		return enumTypeName + "_" + ctorName;

	static inline function classMemberName(classTypeName:String, fieldName:String)
		return classTypeName + "_" + sanitizeIdent(fieldName);

	static function fieldNativeName(field:ClassField):String {
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

	static function sanitizeIdent(name:String):String {
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

		return id;
	}

	static function enumFieldArgs(field:EnumField):Array<{name:String, t:Type}> {
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

	static function enumCaseValueIndex(expr:TypedExpr):String {
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

	static function defFunctionType(args:Array<{name:String, opt:Bool, t:Type}>, ret:Type, pos:Position):TypeDef {
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

	static function defAnonymousType(type:AnonType, pos:Position):TypeDef {
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

	static function resolveTypeDefAlias(type:DefType, params:Array<Type>):Type
		return type.type.applyTypeParameters(type.params, params).follow();

	static function resolveAbstractAlias(type:AbstractType, params:Array<Type>):Type
		return type.type.applyTypeParameters(type.params, params).follow();

	// types

	static function defType(type:Type, pos:Position):TypeDef {
		var key = typeCacheKey(type, pos);
		var cached = typeDefCache.get(key);
		if (cached != null)
			return consumeTypeDefForEntry(cached);
		if (typeDefBuildInProgress.exists(key))
			return {
				name: typeNameOf(type, pos),
				def: []
			};

		var prevEntryTypes = currentEntryDefinedTypes;
		currentEntryDefinedTypes = null;
		typeDefBuildInProgress.set(key, true);

		var canonical = switch type {
			case TEnum(t, params):
				defEnum(t.get(), params);
			case TInst(t, params):
				defClassType(t.get(), params);
			case TType(t, params):
				defTypeDef(t.get(), params);
			case TFun(args, ret):
				defFunctionType(args, ret, pos);
			case TAnonymous(a):
				defAnonymousType(a.get(), pos);
			case TAbstract(t, params):
				defAbstract(t.get(), params);
			default:
				Context.error('Type $type is not allowed', pos);
		}

		typeDefBuildInProgress.remove(key);
		currentEntryDefinedTypes = prevEntryTypes;
		typeDefCache.set(key, cloneTypeDef(canonical));
		return consumeTypeDefForEntry(canonical);
	}

	static function defModuleType(type:ModuleType):TypeDef {
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

	static function defEnum(type:EnumType, params:Array<Type>) {
		return defBaseType(type, "enum", params, base -> {
			var b = new StringBuf();

			function addType(t:Type) {
				var tdef = defType(t, type.pos);
				base.def = base.def.concat(tdef.def);
				return tdef.name;
			}

			b.add("struct " + base.name + " {\n");
			b.add('\tint ${enumTagFieldName()};\n');
			for (nameIndex in 0...type.names.length) {
				var f = type.names[nameIndex];
				var c = type.constructs.get(f);
				var args = enumFieldArgs(c);
				for (argIndex in 0...args.length) {
					var argType = addType(args[argIndex].t);
					b.add('\t${argType} ${enumPayloadFieldName(c.name, argIndex)};\n');
				}
			}
			b.add("};\n");

			for (nameIndex in 0...type.names.length) {
				var f = type.names[nameIndex];
				var c = type.constructs.get(f);
				var args = enumFieldArgs(c);
				var ctorParams = [];
				for (i in 0...args.length) {
					var argName = "__arg" + i;
					var argType = addType(args[i].t);
					ctorParams.push(argType + " " + argName);
				}

				var ctorName = enumCtorFunctionName(base.name, c.name);
				b.add('${base.name} ${ctorName}(${ctorParams.join(", ")}) {\n');
				b.add('\t${base.name} __value;\n');
				var ctorIndex = safeEnumFieldIndex(c, nameIndex);
				b.add('\t__value.${enumTagFieldName()} = ${ctorIndex};\n');
				for (i in 0...args.length)
					b.add('\t__value.${enumPayloadFieldName(c.name, i)} = __arg${i};\n');
				b.add("\treturn __value;\n");
				b.add("}\n");
			}

			return b.toString();
		});
	}

	static function defClassType(type:ClassType, params:Array<Type>):TypeDef {
		return defBaseType(type, "class", params, base -> {
			var b = new StringBuf();
			var instanceVars:Array<ClassField> = [];
			var instanceMethods:Array<ClassField> = [];
			var staticVars:Array<ClassField> = [];
			var staticMethods:Array<ClassField> = [];

			function classifyField(field:ClassField, isStatic:Bool) {
				// Entry points are emitted separately as `main()` bodies.
				if (field.name == "__vert__" || field.name == "__frag__")
					return;
				switch field.kind {
					case FVar(_, _):
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
				var typeDef = defType(field.type, field.pos);
				base.def = base.def.concat(typeDef.def);
				var varName = isStatic ? classMemberName(base.name, field.name) : sanitizeIdent(field.name);
				b.add(typeDef.name + " " + varName);

				var initExpr = field.expr();
				if (initExpr != null) {
					var init = transBody(initExpr, false, false, 0, false);
					base.def = base.def.concat(init.statics);
					b.add(" = " + init.expr);
				}
				b.add(";\n");
			}

			function emitMethod(field:ClassField, isStatic:Bool) {
				var signature = switch field.type.follow() {
					case TFun(args, ret):
						{
							args: args,
							ret: ret
						};
					default:
						Context.error('Expected function type for method ${field.name}', field.pos);
						{
							args: [],
							ret: field.type
						};
				}

				var retType = defType(signature.ret, field.pos);
				base.def = base.def.concat(retType.def);

				var methodCtx:TransContext = {
					locals: new Map(),
					usedLocalNames: new Map()
				};
				if (!isStatic)
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
				if (!isStatic)
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
						transBody(func.expr, false, false, 0, false, methodCtx);
					default:
						transBody(expr, false, false, 0, false, methodCtx);
				}
				base.def = base.def.concat(body.statics);

				b.add(retType.name + " " + classMemberName(base.name, field.name) + "(" + argsDecl.join(", ") + ") ");
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

			b.add("struct " + base.name + " {\n");
			for (field in instanceVars)
				emitVariable(field, false);
			b.add("};\n");

			for (field in staticVars)
				emitVariable(field, true);
			for (field in instanceMethods)
				emitMethod(field, false);
			for (field in staticMethods)
				emitMethod(field, true);

			return b.toString();
		});
	}

	static function defTypeDef(type:DefType, params:Array<Type>):TypeDef {
		return defBaseType(type, "typedef", params, base -> {
			var alias = defType(resolveTypeDefAlias(type, params), type.pos);
			base.def = base.def.concat(alias.def);
			base.name = alias.name;
			return "";
		});
	}

	static function defAbstract(type:AbstractType, params:Array<Type>):TypeDef {
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
					var body = transBody(expr, false, false, 0, false);
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
			var alias = defType(resolveAbstractAlias(type, params), type.pos);
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
	#end
}
