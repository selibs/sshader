package sshader.transpiler;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;
import sshader.ShaderSource;
import sshader.transpiler.Types;

using haxe.macro.TypeTools;
using haxe.macro.TypedExprTools;

class Transpiler {
	public static inline function wrapFunctionBody(bodyExpr:String):String {
		return bodyExpr.length > 0 && bodyExpr.charAt(0) == "{" ? bodyExpr : "{" + bodyExpr + ";}";
	}

	static inline function isVertEntryName(name:String):Bool {
		return name == "vert" || name == "_vert_";
	}

	static inline function isFragEntryName(name:String):Bool {
		return name == "frag" || name == "_frag_";
	}

	static inline function isGlslInterfaceTypeName(name:String):Bool {
		return switch name {
			case "bool", "int", "uint", "float", "double", "bvec2", "bvec3", "bvec4", "ivec2", "ivec3", "ivec4", "uvec2", "uvec3", "uvec4", "vec2",
				"vec3", "vec4", "dvec2", "dvec3", "dvec4", "mat2", "mat3", "mat4", "mat2x2", "mat2x3", "mat2x4", "mat3x2", "mat3x3", "mat3x4", "mat4x2",
				"mat4x3", "mat4x4", "dmat2", "dmat3", "dmat4", "dmat2x2", "dmat2x3", "dmat2x4", "dmat3x2", "dmat3x3", "dmat3x4", "dmat4x2", "dmat4x3",
				"dmat4x4":
				true;
			default:
				false;
		}
	}

	public static function collectEntryVaryingLayout(func:TFunc, pos:Position):Array<{
		name:String,
		location:Int,
		typeSig:String,
		typeName:String,
		interp:VaryingInterp
	}> {
		return collectVaryingLayoutFromReturn(func.t, pos);
	}

	public static function buildShaderSource(owner:ClassType, entryName:String, entryPos:Position, func:TFunc, ?linkedVertOut:Array<{
		name:String,
		location:Int,
		typeSig:String,
		typeName:String,
		interp:VaryingInterp
	}>):ShaderSource {
		var snapshot = TypeSupport.beginEntryContext(owner);
		var p = Transpiler.entryPoint(owner, func, entryPos, isFragEntryName(entryName), linkedVertOut);
		var s = new ShaderSource();
		s.stage = isFragEntryName(entryName) ? "frag" : "vert";
		s.uniforms = TypeSupport.usedUniforms();
		s.varIn = p.varIn;
		s.varOut = p.varOut;
		s.statics = p.body.statics;
		s.main = p.body.expr;
		TypeSupport.endEntryContext(snapshot);
		return s;
	}

	static function parseLocation(meta:MetaAccess, i:Int):Int {
		if (!meta.has("location"))
			return i;

		var m = meta.extract("location")[0];
		var params = m.params;
		if (params == null || params.length == 0)
			return i;

		if (params.length > 1) {
			Context.warning("Too much values", m.pos);
			return i;
		}

		return switch params[0].expr {
			case EConst(CInt(s)):
				var l = Std.parseInt(s);
				if (l == null) {
					Context.warning("Invalid location", params[0].pos);
					i;
				} else l;
			default:
				Context.warning("Invalid location", params[0].pos);
				i;
		}
	}
	static function parseInterp(meta:MetaAccess):VaryingInterp {
		function getParam(p:String, d:Expr) {
			if (!meta.has(p))
				return d;

			var m = meta.extract(p)[0];
			var params = m.params;
			if (params == null || params.length == 0)
				return d;

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
		return if (meta.has("flat"))
			FLAT;
		else if (meta.has("smooth"))
			SMOOTH(getInterp("smooth"));
		else if (meta.has("noperspective"))
			NOPERSPECTIVE(getInterp("noperspective"));
		else
			SMOOTH(NONE);
	}
	static inline function hasInterpMeta(meta:MetaAccess):Bool {
		return meta.has("flat") || meta.has("smooth") || meta.has("noperspective");
	}

	static function collectVaryingLayoutFromReturn(type:Type, pos:Position):Array<{
		name:String,
		location:Int,
		typeSig:String,
		typeName:String,
		interp:VaryingInterp
	}> {
		var fields = switch type {
			case TAnonymous(a):
				a.get().fields;
			case TType(t, _):
				return collectVaryingLayoutFromReturn(t.get().type, pos);
			default:
				Context.error("Invalid return type", pos);
				[];
		}
		var out:Array<{
			name:String,
			location:Int,
			typeSig:String,
			typeName:String,
			interp:VaryingInterp
		}> = [];
		for (i in 0...fields.length) {
			var f = fields[i];
			var typeDef = TypeSupport.defType(f.type, f.pos);
			out.push({
				name: TypeSupport.sanitizeIdent(f.name),
				location: parseLocation(f.meta, i),
				typeSig: Context.signature(f.type.follow()),
				typeName: typeDef.name,
				interp: parseInterp(f.meta)
			});
		}
		return out;
	}

	public static function entryPoint(owner:ClassType, func:TFunc, pos:Position, isFrag:Bool = false, vertOutLayout:Null<Array<{
		name:String,
		location:Int,
		typeSig:String,
		typeName:String,
		interp:VaryingInterp
	}>> = null):EntryPoint {
		function parseVarying(args:Array<{
			name:String,
			type:TypeDef,
			typeSig:String,
			meta:MetaAccess,
			pos:Position
		}>, forFragInput:Bool, kind:String) {
			var varyings = [];
			var vertOutByName = new Map<String, Int>();
			var vertOutByLocation = new Map<Int, {name:String, typeSig:String, typeName:String, interp:VaryingInterp}>();
			var usedLocationNames = new Map<Int, String>();
			if (forFragInput && vertOutLayout != null) {
				for (v in vertOutLayout) {
					if (!vertOutByName.exists(v.name))
						vertOutByName.set(v.name, v.location);
					vertOutByLocation.set(v.location, {
						name: v.name,
						typeSig: v.typeSig,
						typeName: v.typeName,
						interp: v.interp
					});
				}
			}
			for (i in 0...args.length) {
				var a = args[i];
				var name = TypeSupport.sanitizeIdent(a.name);
				var type = a.type;
				var argPos = a.pos;
				if (!isGlslInterfaceTypeName(type.name))
					Context.error('Unsupported GLSL interface type "${type.name}" for $kind varying "$name". Use scalar/vector/matrix types.', argPos);
				var typeSig = a.typeSig;
				var meta = a.meta;
				var location = if (forFragInput) {
					if (meta.has("location")) {
						var l = parseLocation(meta, i);
						if (!vertOutByLocation.exists(l))
							Context.error('No vertex output varying with location $l was found.', argPos);
						l;
					} else {
						var l = vertOutByName.get(name);
						if (l == null)
							Context.error('No vertex output varying with name "$name" was found.', argPos);
						l;
					}
				} else parseLocation(meta, i);
				var prevAtLocation = usedLocationNames.get(location);
				if (prevAtLocation != null)
					Context.error('Duplicate $kind varying location $location for "$name" and "$prevAtLocation".', argPos);
				usedLocationNames.set(location, name);
				if (forFragInput) {
					var vert = vertOutByLocation.get(location);
					if (vert != null && vert.typeSig != typeSig)
						Context.error('Type mismatch at location $location: fragment input "$name" (${type.name}) is incompatible with vertex output "${vert.name}" (${vert.typeName}).',
							argPos);
				}
				var interp = parseInterp(meta);
				if (forFragInput && !hasInterpMeta(meta)) {
					var vert = vertOutByLocation.get(location);
					if (vert != null)
						interp = vert.interp;
				}
				varyings.push({
					name: name,
					type: type,
					interp: interp,
					location: location
				});
			}
			return varyings;
		}
		function uniquifyInterfaceNames(varIn:Array<Varying>, varOut:Array<Varying>):Void {
			var usedOut = new Map<String, Bool>();
			for (v in varOut)
				usedOut.set(v.name, true);
			var usedAll = new Map<String, Bool>();
			for (v in varOut)
				usedAll.set(v.name, true);
			function nextName(base:String):String {
				var candidate = base + "_in";
				var i = 1;
				while (usedAll.exists(candidate)) {
					candidate = base + "_in_" + i;
					i++;
				}
				return candidate;
			}
			for (v in varIn) {
				var current = v.name;
				if (usedOut.exists(current))
					current = nextName(current);
				while (usedAll.exists(current))
					current = nextName(current);
				v.name = current;
				usedAll.set(current, true);
			}
		}
		function getVarOut(type:Type) {
			return switch type {
				case TAnonymous(a):
					parseVarying(a.get().fields.map(f -> {
						name: f.name,
						type: TypeSupport.defType(f.type, f.pos),
						typeSig: Context.signature(f.type.follow()),
						meta: f.meta,
						pos: f.pos
					}), false, "output");
				case TType(t, _):
					getVarOut(t.get().type);
				default:
					Context.error("Invalid return type", pos);
			}
		}
		function prependPrologue(body:String, prologue:Array<String>):String {
			if (prologue == null || prologue.length == 0)
				return body;
			var pref = new StringBuf();
			for (line in prologue)
				pref.add(line + ";");
			if (body.length > 0 && body.charAt(0) == "{")
				return "{" + pref.toString() + body.substr(1);
			return "{" + pref.toString() + body + ";}";
		}
		if (isFrag && func.args.length > 0 && vertOutLayout == null)
			Context.error('Fragment entry point requires vertex entry point "vert" with output varyings.', pos);
		var argEntries = func.args.map(a -> {
			var argPos = a.value != null ? a.value.pos : pos;
			return {
				id: a.v.id,
				name: a.v.name,
				type: TypeSupport.defType(a.v.t, argPos),
				typeSig: Context.signature(a.v.t.follow()),
				meta: a.v.meta,
				pos: argPos
			};
		});
		var varIn = parseVarying(argEntries, isFrag, "input");
		var varOut = getVarOut(func.t);
		uniquifyInterfaceNames(varIn, varOut);
		var ctx:TransContext = {
			locals: new Map(),
			usedLocalNames: new Map(),
			prologue: [],
			uniformLocals: new Map(),
			enableUniformLocalAlias: true
		};
		for (v in varIn)
			ctx.usedLocalNames.set(TypeSupport.sanitizeIdent(v.name), 1);
		for (uniformName in TypeSupport.usedUniformNames())
			ctx.usedLocalNames.set(uniformName, 1);
		for (i in 0...argEntries.length) {
			var arg = argEntries[i];
			var local = TypeSupport.reserveLocalName(ctx.usedLocalNames, arg.name, "_tmp");
			ctx.locals.set(arg.id, local);
			ctx.prologue.push(varIn[i].type.name + " " + local + " = " + varIn[i].name);
		}
		var body = transExpr(func.expr, ctx);
		var mergedStatics = body.statics.copy();
		var dispatcherDecls = buildDispatcherDecls();
		var declInsertAt = dispatcherDeclInsertIndex(mergedStatics);
		for (i in 0...dispatcherDecls.length)
			mergedStatics.insert(declInsertAt + i, dispatcherDecls[i]);
		var dispatchers = buildDispatchers();
		for (d in dispatchers)
			mergedStatics.push(d);
		var ep = {
			varIn: varIn,
			varOut: varOut,
			body: {
				statics: mergedStatics,
				expr: prependPrologue(body.expr, ctx.prologue)
			}
		}
		return ep;
	}

	public static function transExpr(expr:TypedExpr, ctx:TransContext = null, isInlineContext:Bool = false):EntryPointBody {
		if (ctx == null)
			ctx = {
				locals: new Map(),
				usedLocalNames: new Map()
			};
		final statics = [];
		final buf = new StringBuf();
		inline function appendStatics(items:Array<String>) {
			if (items == null)
				return;
			for (s in items)
				statics.push(s);
		}
		function addExpr(expr:TypedExpr, isInlineContext:Bool = false) {
			var body = transExpr(expr, ctx, isInlineContext);
			appendStatics(body.statics);
			return body.expr;
		}
		function addInline(expr:TypedExpr)
			return addExpr(expr, true);
		function addTypeDef(type:TypeDef) {
			appendStatics(type.def);
			return type.name;
		}
		function addType(t:Type)
			return addTypeDef(TypeSupport.defType(t, expr.pos));
		function addClassType(t:Ref<ClassType>, params:Array<Type>)
			return addTypeDef(TypeSupport.defType(TInst(t, params), expr.pos));
		function addModuleType(t:ModuleType)
			return addTypeDef(TypeSupport.defModuleType(t));
		function isVarField(field:ClassField):Bool {
			return switch field.kind {
				case FVar(_, _):
					true;
				default:
					false;
			}
		}
		inline function markUsed(owner:ClassType, field:ClassField, isStatic:Bool):Void {
			TypeSupport.markClassFieldUsed(owner, field, isStatic);
		}
		function assertNonLocalVarAccess(field:ClassField, owner:ClassType, p:Position) {
			if (TypeSupport.useUniformField(owner, field) != null || field.isFinal)
				return;
			if (TypeSupport.isShaderSourceClass(owner))
				Context.error('Non-local mutable field "${owner.name}.${field.name}" is not allowed in shader code.', p);
		}
		function isNoThisInlineMethod(owner:ClassType, field:ClassField):Bool {
			if (owner.isExtern || field.meta.has(":native"))
				return false;
			return TypeSupport.isNoThisInlineMethod(owner, field);
		}
		function isNoThisMethod(owner:ClassType, field:ClassField):Bool {
			if (owner.isExtern || field.meta.has(":native"))
				return false;
			return TypeSupport.isNoThisMethod(owner, field);
		}
		function inlineNoThisMethodKey(owner:ClassType, field:ClassField):String {
			var p = Context.getPosInfos(field.pos);
			return TypeSupport.classBaseName(owner) + ":" + field.name + ":" + p.min + ":" + p.max;
		}
		function ensureNoThisInlineMethod(owner:ClassType, field:ClassField):String {
			var helperKey = inlineNoThisMethodKey(owner, field);
			if (TypeSupport.curInlineNoThisMethods == null)
				TypeSupport.curInlineNoThisMethods = new Map();
			var existing = TypeSupport.curInlineNoThisMethods.get(helperKey);
			if (existing != null)
				return existing;
			var helperName = TypeSupport.sanitizeIdent(TypeSupport.classBaseName(owner) + "_" + field.name + "_inline_nothis");
			TypeSupport.curInlineNoThisMethods.set(helperKey, helperName);
			function helperTypeName(t:Type, p:Position):String {
				var td = TypeSupport.defType(t, p);
				appendStatics(td.def);
				return td.name;
			}
			var signature = switch field.type.follow() {
				case TFun(args, ret):
					{
						args: args,
						ret: ret
					};
				default:
					Context.error('Expected function type for inline method ${field.name}', field.pos);
					{
						args: [],
						ret: field.type
					};
			}
			var retType = helperTypeName(signature.ret, field.pos);
			var methodCtx:TransContext = {
				locals: new Map(),
				usedLocalNames: new Map()
			};
			var argsDecl = [];
			var argNames:Array<String> = [];
			for (arg in signature.args) {
				var argType = helperTypeName(arg.t, field.pos);
				var argName = TypeSupport.reserveLocalName(methodCtx.usedLocalNames, arg.name, "_arg");
				argNames.push(argName);
				argsDecl.push(argType + " " + argName);
			}
			var methodExpr = field.expr();
			if (methodExpr == null)
				Context.error('Method ${field.name} should have a body', field.pos);
			function unwrapInlineExpr(e:TypedExpr):TypedExpr {
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
			function extractInlineValue(e:TypedExpr):Null<TypedExpr> {
				var u = unwrapInlineExpr(e);
				return switch u.expr {
					case TReturn(v):
						v;
					case TBlock(el) if (el.length == 1):
						extractInlineValue(el[0]);
					default:
						null;
				}
			}
			var methodFunc:Null<TFunc> = switch methodExpr.expr {
				case TFunction(func):
					func;
				default:
					null;
			}
			if (methodFunc != null)
				for (i in 0...methodFunc.args.length)
					if (i < argNames.length)
						methodCtx.locals.set(methodFunc.args[i].v.id, argNames[i]);
			var bodyExpr = methodFunc != null ? methodFunc.expr : methodExpr;
			var inlineValueExpr = extractInlineValue(bodyExpr);
			if (inlineValueExpr != null) {
				var inlined = transExpr(inlineValueExpr, methodCtx);
				appendStatics(inlined.statics);
				statics.push("#define " + helperName + "(" + argNames.join(", ") + ") (" + inlined.expr + ")");
				return helperName;
			}
			var body = switch methodExpr.expr {
				case TFunction(func):
					transExpr(func.expr, methodCtx);
				default:
					transExpr(methodExpr, methodCtx);
			}
			appendStatics(body.statics);
			var b = new StringBuf();
			b.add(retType + " " + helperName + "(" + argsDecl.join(", ") + ") ");
			b.add(wrapFunctionBody(body.expr));
			statics.push(b.toString());
			return helperName;
		}
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
					var retDef = TypeSupport.defType(ret, expr.pos);
					appendStatics(retDef.def);
					var argDefs = [];
					for (a in args) {
						var d = TypeSupport.defType(a.t, expr.pos);
						appendStatics(d.def);
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
		function localName(v:TVar):String {
			if (ctx.locals.exists(v.id))
				return ctx.locals.get(v.id);
			var name = TypeSupport.reserveLocalName(ctx.usedLocalNames, v.name, "_tmp");
			ctx.locals.set(v.id, name);
			return name;
		}
		function ensureUniformLocal(owner:ClassType, field:ClassField, uniformName:String, fieldType:Type):String {
			if (ctx.enableUniformLocalAlias != true)
				return uniformName;
			if (ctx.uniformLocals == null)
				ctx.uniformLocals = new Map();
			var key = TypeSupport.uniformFieldKey(owner, field);
			var existing = ctx.uniformLocals.get(key);
			if (existing != null)
				return existing;
			var local = TypeSupport.reserveLocalName(ctx.usedLocalNames, field.name, "_tmp");
			var typeName = addType(fieldType);
			if (ctx.prologue == null)
				ctx.prologue = [];
			ctx.prologue.push(typeName + " " + local + " = " + uniformName);
			ctx.uniformLocals.set(key, local);
			return local;
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
			TypeSupport.curHelperSeq++;
			return prefix + TypeSupport.curHelperSeq;
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
			var td = TypeSupport.defType(t, p);
			appendStatics(td.def);
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
			var argsDecl = [selfType + " _self_cap"];
			var argsCall = [];
			for (i in 0...argTypes.length) {
				argsDecl.push(argTypes[i] + " _a" + i);
				argsCall.push("_a" + i);
			}
			b.add(retType + " " + name + "(" + argsDecl.join(", ") + "){");
			var call = isExtern ? ("_self_cap." + fieldName + "(" + argsCall.join(", ") + ")") : (fieldName + "(_self_cap"
				+ (argsCall.length > 0 ? ", " + argsCall.join(", ") : "") + ")");
			if (retType == "Void" || retType == "void")
				b.add(call + ";return;");
			else
				b.add("return " + call + ";");
			b.add("}");
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
			var lambdaName = nextHelperName("_fn_lambda_");
			var argsDecl = [];
			var capExprs:Array<{t:Type, expr:String}> = [];
			var lambdaCtx:TransContext = {
				locals: new Map(),
				usedLocalNames: new Map()
			};
			for (i in 0...captures.length) {
				var v = captures[i];
				var tname = typeNameOfExprType(v.t, p);
				var aname = "_cap" + i;
				argsDecl.push(tname + " " + aname);
				lambdaCtx.locals.set(v.id, aname);
				lambdaCtx.usedLocalNames.set(aname, 1);
				var outerName = ctx.locals.exists(v.id) ? ctx.locals.get(v.id) : localName(v);
				capExprs.push({t: v.t, expr: outerName});
			}
			for (i in 0...parts.args.length) {
				var a = parts.args[i];
				var tname = typeNameOfExprType(a.t, p);
				var aname = "_a" + i;
				argsDecl.push(tname + " " + aname);
				if (i < func.args.length)
					lambdaCtx.locals.set(func.args[i].v.id, aname);
				lambdaCtx.usedLocalNames.set(aname, 1);
			}
			var retType = typeNameOfExprType(parts.ret, p);
			var body = transExpr(func.expr, lambdaCtx);
			appendStatics(body.statics);
			var b = new StringBuf();
			b.add(retType + " " + lambdaName + "(" + argsDecl.join(", ") + ") ");
			b.add(wrapFunctionBody(body.expr));
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
					markUsed(c.get(), cf.get(), true);
					if (isVarField(cf.get()))
						assertNonLocalVarAccess(cf.get(), c.get(), u.pos);
					if (c.get().isExtern || cf.get().meta.has(":native")) {
						target: TypeSupport.fieldNativeName(cf.get()),
						captures: []
						} else {
							var className = addClassType(c, []);
							{
								target: TypeSupport.memberSymbol(className, cf.get().name),
								captures: []
							};
						}
				case TField(_, FEnum(enumRef, ef)):
					var enumTypeName = addTypeDef(TypeSupport.defEnum(enumRef.get(), []));
					{
						target: enumTypeName + "_" + ef.name,
						captures: []
					};
				case TField(target, FInstance(c, params, cf)):
					markUsed(c.get(), cf.get(), false);
					if (isVarField(cf.get()))
						assertNonLocalVarAccess(cf.get(), c.get(), u.pos);
					var owner = c.get();
					if (owner.isExtern || cf.get().meta.has(":native")) {
						var selfType = typeNameOfExprType(target.t, target.pos);
						var helperName = nextHelperName("_fn_bound_");
						statics.push(buildBoundMethodWrapper(helperName, retType, TypeSupport.fieldNativeName(cf.get()), selfType, argTypes, true));
						{
							target: helperName,
							captures: [{t: target.t, expr: addInline(target)}]
						};
					} else if (isNoThisInlineMethod(owner, cf.get())) {
						{
							target: ensureNoThisInlineMethod(owner, cf.get()),
							captures: []
						};
						} else if (isNoThisMethod(owner, cf.get())) {
							var className = addClassType(c, params);
							{
								target: TypeSupport.memberSymbol(className, cf.get().name),
								captures: []
							};
						} else {
							var className = addClassType(c, params);
							{
								target: TypeSupport.memberSymbol(className, cf.get().name),
								captures: [{t: target.t, expr: addInline(target)}]
							};
						}
				case TField(target, FClosure(c, cf)):
					switch c {
						case null:
							Context.error("Unsupported function value", u.pos);
							{
								target: "_invalid_fn",
								captures: []
							};
						case cc:
							var owner = cc.c.get();
							if (owner.isExtern || cf.get().meta.has(":native")) {
								var selfType = typeNameOfExprType(target.t, target.pos);
								var helperName = nextHelperName("_fn_bound_");
								statics.push(buildBoundMethodWrapper(helperName, retType, TypeSupport.fieldNativeName(cf.get()), selfType, argTypes, true));
								{
									target: helperName,
									captures: [{t: target.t, expr: addInline(target)}]
								};
							} else if (isNoThisInlineMethod(owner, cf.get())) {
								{
									target: ensureNoThisInlineMethod(owner, cf.get()),
									captures: []
								};
								} else if (isNoThisMethod(owner, cf.get())) {
									var className = addClassType(cc.c, cc.params);
									{
										target: TypeSupport.memberSymbol(className, cf.get().name),
										captures: []
									};
								} else {
									var className = addClassType(cc.c, cc.params);
									{
										target: TypeSupport.memberSymbol(className, cf.get().name),
										captures: [{t: target.t, expr: addInline(target)}]
									};
								}
					}
				default:
					Context.error("Unsupported function value", u.pos);
					{
						target: "_invalid_fn",
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
					subject += "." + "_tag";
				var current = edef != null ? functionValueExpr(edef, expected) : "0";
				for (i in 0...cases.length) {
					var c = cases[cases.length - 1 - i];
					if (c.expr == null)
						Context.error("Switch function-value case should return a function", p);
					var branch = functionValueExpr(c.expr, expected);
					var checks = [];
					for (v in c.values) {
						var caseValue = isEnumSwitch ? TypeSupport.enumCaseValueIndex(v) : addInline(v);
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
		function emitStatement(e:TypedExpr) {
			var stmt = unwrapWrapperExpr(e);
			var needsSemi = needsSemicolon(stmt);
			buf.add(addExpr(stmt, false));
			if (needsSemi)
				buf.add(";");
		}
		function emitAsBlock(e:TypedExpr) {
			var branch = unwrapWrapperExpr(e);
			switch branch.expr {
				case TBlock(_):
					buf.add(addExpr(branch, false));
				default:
					buf.add("{");
					emitStatement(branch);
					buf.add("}");
			}
		}
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
				buf.add("_self");
			case TConst(TSuper):
				buf.add("_self");
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
						markUsed(owner, field, false);
						switch field.kind {
							case FVar(_, _):
								assertNonLocalVarAccess(field, owner, expr.pos);
								var uniformName = TypeSupport.uniformNameForField(owner, field);
								if (uniformName != null) {
									var fieldType = owner.params.length == params.length ? field.type.applyTypeParameters(owner.params, params) : field.type;
									buf.add(ensureUniformLocal(owner, field, uniformName, fieldType));
								} else buf.add(addInline(e) + "." + TypeSupport.fieldNativeName(field));
							case FMethod(_):
								if (owner.isExtern || field.meta.has(":native")) buf.add(addInline(e) + "." + TypeSupport.fieldNativeName(field)); else {
									if (isNoThisInlineMethod(owner, field))
										buf.add(ensureNoThisInlineMethod(owner, field));
									else {
										var className = addClassType(c, params);
										buf.add(TypeSupport.memberSymbol(className, field.name));
									}
								}
						}
					case FStatic(c, cf):
						var owner = c.get();
						var field = cf.get();
						markUsed(owner, field, true);
						if (isVarField(field))
							assertNonLocalVarAccess(field, owner, expr.pos);
						var uniformName = TypeSupport.uniformNameForField(owner, field);
							if (uniformName != null) buf.add(ensureUniformLocal(owner, field, uniformName,
								field.type)); else if (owner.isExtern || field.meta.has(":native")) buf.add(TypeSupport.fieldNativeName(field)); else {
								var className = addClassType(c, []);
								buf.add(TypeSupport.memberSymbol(className, field.name));
							}
					case FAnon(cf):
						buf.add(addInline(e) + "." + TypeSupport.sanitizeIdent(cf.get().name));
					case FDynamic(s):
						buf.add(addInline(e) + "." + TypeSupport.sanitizeIdent(s));
					case FClosure(c, cf):
						if (c == null) buf.add(TypeSupport.sanitizeIdent(cf.get().name)); else {
							markUsed(c.c.get(), cf.get(), false);
							var owner = c.c.get();
							if (owner.isExtern || cf.get().meta.has(":native"))
								buf.add(TypeSupport.fieldNativeName(cf.get()));
								else if (isNoThisInlineMethod(owner, cf.get()))
									buf.add(ensureNoThisInlineMethod(owner, cf.get()));
								else {
									var ownerName = addClassType(c.c, c.params);
									buf.add(TypeSupport.memberSymbol(ownerName, cf.get().name));
								}
							}
					case FEnum(enumRef, ef):
						var enumTypeName = addTypeDef(TypeSupport.defEnum(enumRef.get(), []));
						var ctorName = enumTypeName + "_" + ef.name;
						if (TypeSupport.enumFieldArgs(ef).length == 0) buf.add(ctorName + "()"); else buf.add(ctorName);
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
						buf.add(addInline(el[0]) + "." + "_tag");
					case TField(target, FInstance(c, params, cf)):
						markUsed(c.get(), cf.get(), false);
						switch cf.get().kind {
							case FMethod(_):
								if (c.get()
									.isExtern || cf.get()
									.meta.has(":native")) buf.add(addInline(target) + "." + TypeSupport.fieldNativeName(cf.get()) + "(" + args.join(", ") +
										")"); else {
									var owner = c.get();
										if (isNoThisInlineMethod(owner, cf.get()))
											buf.add(ensureNoThisInlineMethod(owner, cf.get()) + "(" + args.join(", ") + ")");
										else if (isNoThisMethod(owner, cf.get())) {
											var className = addClassType(c, params);
											buf.add(TypeSupport.memberSymbol(className, cf.get().name) + "(" + args.join(", ") + ")");
										} else {
											var className = addClassType(c, params);
											args.unshift(addInline(target));
											buf.add(TypeSupport.memberSymbol(className, cf.get().name) + "(" + args.join(", ") + ")");
										}
									}
							case FVar(_, _):
								assertNonLocalVarAccess(cf.get(), c.get(), callee.pos);
								emitDispatch();
						}
					case TField(_, FStatic(c, cf)):
						markUsed(c.get(), cf.get(), true);
						switch cf.get().kind {
							case FMethod(_):
								buf.add(addInline(callee) + "(" + args.join(", ") + ")");
							case FVar(_, _):
								assertNonLocalVarAccess(cf.get(), c.get(), callee.pos);
								emitDispatch();
						}
						case TField(_, FEnum(_, _)):
							buf.add(addInline(callee) + "(" + args.join(", ") + ")");
						default:
							if (isFunctionType(callee.t) || isFunctionValueCallee(callee))
								emitDispatch();
							else
								buf.add(addInline(callee) + "(" + args.join(", ") + ")");
					}
			case TNew(c, params, el):
				TypeSupport.markClassConstructed(c.get());
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
				buf.add("{");
				var terminated = false;
				for (e in el) {
					if (terminated)
						continue;
					var stmt = unwrapWrapperExpr(e);
					emitStatement(stmt);
					terminated = switch stmt.expr {
						case TReturn(_), TBreak, TContinue:
							true;
						default:
							false;
					}
				}
				buf.add("}");
			case TFor(v, e1, e2):
				var s = localName(v);
				switch e1.expr {
					case TBinop(OpInterval, eFrom, eTo):
						buf.add('for (${addType(v.t)} $s = ${addInline(eFrom)}; $s < ${addInline(eTo)}; $s++) ');
						emitAsBlock(e2);
					default:
						var p = Context.getPosInfos(expr.pos);
						var iterName = "_iter_" + p.min + "_" + p.max;
						buf.add("{");
						buf.add(addType(e1.t) + " " + iterName + " = " + addInline(e1) + ";");
						buf.add("while (" + iterName + ".hasNext()) {");
						buf.add(addType(v.t) + " " + s + " = " + iterName + ".next();");
						var loopBody = unwrapWrapperExpr(e2);
						switch loopBody.expr {
							case TBlock(el):
								for (stmt in el)
									emitStatement(stmt);
							default:
								emitStatement(loopBody);
						}
						buf.add("}");
						buf.add("}");
				}
			case TIf(econd, eif, eelse):
				var allowTernaryInline = isInlineContext;
				if (allowTernaryInline && eelse != null && canInlineValueExpr(eif) && canInlineValueExpr(eelse)) {
					buf.add("(" + addInline(econd) + " ? " + addInline(unwrapWrapperExpr(eif)) + " : " + addInline(unwrapWrapperExpr(eelse)) + ")");
				} else {
					buf.add("if (" + addInline(econd) + ") ");
					emitAsBlock(eif);
					if (eelse != null) {
						buf.add(" else ");
						emitAsBlock(eelse);
					}
				}
			case TWhile(econd, e, normalWhile):
				if (normalWhile) {
					buf.add("while (" + addInline(econd) + ") ");
					emitAsBlock(e);
				} else {
					buf.add("do ");
					emitAsBlock(e);
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
					switchExpr += "." + "_tag";
				buf.add("switch (" + switchExpr + ") {");
				for (c in cases) {
					for (v in c.values) {
						var caseValue = isEnumSwitch ? TypeSupport.enumCaseValueIndex(v) : addInline(v);
						buf.add("case " + caseValue + ":");
					}
					buf.add("{");
					if (c.expr != null) {
						var caseExpr = unwrapWrapperExpr(c.expr);
						switch caseExpr.expr {
							case TBlock(el):
								for (stmt in el)
									emitStatement(stmt);
							default:
								emitStatement(caseExpr);
						}
					}
					buf.add("break;");
					buf.add("}");
				}
				if (edef != null) {
					buf.add("default:");
					buf.add("{");
					var defaultExpr = unwrapWrapperExpr(edef);
					switch defaultExpr.expr {
						case TBlock(el):
							for (stmt in el)
								emitStatement(stmt);
						default:
							emitStatement(defaultExpr);
					}
					buf.add("break;");
					buf.add("}");
				}
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
				buf.add(addInline(e1) + "." + ("_" + ef.name + "_" + index));
			case TEnumIndex(e1):
				buf.add(addInline(e1) + "." + "_tag");
			case TIdent(v):
				buf.add(TypeSupport.sanitizeIdent(v));
			default:
				Context.error("Invalid expression", expr.pos);
		}
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

	static function ensureDispatcher(retType:String, argTypes:Array<String>):FunctionDispatcher {
		if (TypeSupport.curDispatchers == null)
			TypeSupport.curDispatchers = new Map();
		var key = retType + "(" + argTypes.join(",") + ")";
		var existing = TypeSupport.curDispatchers.get(key);
		if (existing != null)
			return existing;
		TypeSupport.curDispatcherSeq++;
		var created:FunctionDispatcher = {
			name: "_fn_dispatch_" + TypeSupport.curDispatcherSeq,
			retType: retType,
			argTypes: argTypes.copy(),
			cases: [],
			caseIds: new Map(),
			nextId: 1
		};
		TypeSupport.curDispatchers.set(key, created);
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
		var dispatcherStem = dispatcher.name;
		while (StringTools.startsWith(dispatcherStem, "_"))
			dispatcherStem = dispatcherStem.substr(1);
		var captureVars = [];
		for (i in 0...captureTypes.length)
			captureVars.push("_fn_cap_" + dispatcherStem + "_" + id + "_" + i);
		var c:FunctionDispatcherCase = {
			id: id,
			target: target,
			makeName: captureTypes.length == 0 ? null : "_fn_make_" + dispatcherStem + "_" + id,
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
		if (TypeSupport.curDispatchers == null || !TypeSupport.curDispatchers.iterator().hasNext())
			return [];
		var defs = [];
		for (d in TypeSupport.curDispatchers) {
			var b = new StringBuf();
			var argNames = [];
			var signature = ["int _fn"];
			for (i in 0...d.argTypes.length) {
				var argName = "_a" + i;
				argNames.push(argName);
				signature.push(d.argTypes[i] + " " + argName);
			}
			for (c in d.cases) {
				if (c.captureTypes.length == 0)
					continue;
				for (i in 0...c.captureTypes.length)
					b.add(c.captureTypes[i] + " " + c.captureVars[i] + ";");
				var makeSig = [];
				for (i in 0...c.captureTypes.length)
					makeSig.push(c.captureTypes[i] + " _cap" + i);
				b.add("int " + c.makeName + "(" + makeSig.join(", ") + "){");
				for (i in 0...c.captureTypes.length)
					b.add(c.captureVars[i] + " = _cap" + i + ";");
				b.add("return " + c.id + ";");
				b.add("}");
			}
			b.add(d.retType + " " + d.name + "(" + signature.join(", ") + "){");
			b.add("switch (_fn){");
			for (c in d.cases) {
				b.add("case " + c.id + ":{");
				var callArgs = c.captureVars.copy().concat(argNames);
				if (d.retType == "Void" || d.retType == "void") {
					b.add(c.target + "(" + callArgs.join(", ") + ");");
					b.add("return;");
				} else {
					b.add("return " + c.target + "(" + callArgs.join(", ") + ");");
				}
				b.add("}");
			}
			b.add("default:{");
			if (d.retType == "Void" || d.retType == "void")
				b.add("return;");
			else {
				var def = defaultValueExpr(d.retType);
				if (def != null)
					b.add("return " + def + ";");
				else {
					b.add(d.retType + " _fallback;");
					b.add("return _fallback;");
				}
			}
			b.add("}");
			b.add("}");
			b.add("}");
			defs.push(b.toString());
		}
		return defs;
	}

	static function buildDispatcherDecls():Array<String> {
		if (TypeSupport.curDispatchers == null || !TypeSupport.curDispatchers.iterator().hasNext())
			return [];
		var out = [];
		for (d in TypeSupport.curDispatchers) {
			for (c in d.cases) {
				if (c.captureTypes.length == 0)
					continue;
				var makeSig = [];
				for (i in 0...c.captureTypes.length)
					makeSig.push(c.captureTypes[i] + " _cap" + i);
				out.push("int " + c.makeName + "(" + makeSig.join(", ") + ");");
			}
			var signature = ["int _fn"];
			for (i in 0...d.argTypes.length)
				signature.push(d.argTypes[i] + " _a" + i);
			out.push(d.retType + " " + d.name + "(" + signature.join(", ") + ");");
		}
		return out;
	}

	static function dispatcherDeclInsertIndex(statics:Array<String>):Int {
		if (TypeSupport.curDispatchers == null || !TypeSupport.curDispatchers.iterator().hasNext() || statics == null || statics.length == 0)
			return 0;
		function isBuiltinTypeName(name:String):Bool {
			if (name == null || name.length == 0)
				return true;
			var first = name.charCodeAt(0);
			return (first >= "a".code && first <= "z".code) || name == "void" || name == "Void";
		}
		function declTypeName(s:String):Null<String> {
			if (s == null)
				return null;
			var t = StringTools.ltrim(s);
			function readName(rest:String):Null<String> {
				var i = 0;
				while (i < rest.length) {
					var c = rest.charCodeAt(i);
					var isDigit = c >= "0".code && c <= "9".code;
					var isUpper = c >= "A".code && c <= "Z".code;
					var isLower = c >= "a".code && c <= "z".code;
					if (isDigit || isUpper || isLower || c == "_".code)
						i++;
					else
						break;
				}
				return i == 0 ? null : rest.substr(0, i);
			}
			if (StringTools.startsWith(t, "struct "))
				return readName(t.substr("struct ".length));
			if (StringTools.startsWith(t, "#define "))
				return readName(t.substr("#define ".length));
			return null;
		}
		var declPosByType = new Map<String, Int>();
		for (i in 0...statics.length) {
			var n = declTypeName(statics[i]);
			if (n != null && !declPosByType.exists(n))
				declPosByType.set(n, i);
		}
		var out = 0;
		for (d in TypeSupport.curDispatchers) {
			var typeNames = [d.retType];
			for (t in d.argTypes)
				typeNames.push(t);
			for (c in d.cases)
				for (t in c.captureTypes)
					typeNames.push(t);
			for (t in typeNames) {
				if (isBuiltinTypeName(t))
					continue;
				var p = declPosByType.get(t);
				if (p == null)
					p = -1;
				if (p >= out)
					out = p + 1;
			}
		}
		return out;
	}
}
#end
