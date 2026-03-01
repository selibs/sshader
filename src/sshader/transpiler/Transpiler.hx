package sshader.transpiler;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;
import sshader.transpiler.Types;

using haxe.macro.TypeTools;
using haxe.macro.ComplexTypeTools;
using haxe.macro.TypedExprTools;

class Transpiler {
	public static function buildShaderSource(field:ClassField) {
		switch field.expr().expr {
			case TFunction(tfunc):
				var prevEntryTypes = TypeSupport.curDefinedTypes;
				var prevDispatchers = TypeSupport.curDispatchers;
				var prevDispatcherSeq = TypeSupport.curDispatcherSeq;
				var prevHelperSeq = TypeSupport.curHelperSeq;
				TypeSupport.curDefinedTypes = new Map();
				TypeSupport.curDispatchers = new Map();
				TypeSupport.curDispatcherSeq = 0;
				TypeSupport.curHelperSeq = 0;

				var buf = new StringBuf();
				var p = Transpiler.entryPoint(tfunc, field.pos);
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
				if (ShaderSourceBuilder.VERSION != null)
					buf.add('#version ${ShaderSourceBuilder.VERSION}\n\n');

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
				TypeSupport.curDefinedTypes = prevEntryTypes;
				TypeSupport.curDispatchers = prevDispatchers;
				TypeSupport.curDispatcherSeq = prevDispatcherSeq;
				TypeSupport.curHelperSeq = prevHelperSeq;

				return result;
			default:
				Context.error("Shader entry point should be function", field.pos);
				return null;
		}
	}

	public static function entryPoint(func:TFunc, pos:Position):EntryPoint {
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
						type: TypeSupport.defType(f.type, f.pos),
						meta: f.meta
					}));
				case TType(t, _):
					getVarOut(t.get().type);
				default:
					Context.error("Invalid return type", pos);
			}
		}

		var ep = {
			varIn: parseVarying(func.args.map(a -> {
				name: a.v.name,
				type: TypeSupport.defType(a.v.t, pos),
				meta: a.v.meta
			})),
			varOut: getVarOut(func.t),
			body: transExpr(func.expr)
		}

		return ep;
	}

	public static function transExpr(expr:TypedExpr, endLine:Bool = false, breakLine:Bool = false, depth:Int = 0, makeIdent = true,
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
			var body = transExpr(expr, endLine, breakLine, depth, makeIdent, ctx);
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
			return addTypeDef(TypeSupport.defType(t, expr.pos));
		function addClassType(t:Ref<ClassType>, params:Array<Type>)
			return addTypeDef(TypeSupport.defType(TInst(t, params), expr.pos));
		function addModuleType(t:ModuleType)
			return addTypeDef(TypeSupport.defModuleType(t));
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
					for (s in retDef.def)
						statics.push(s);
					var argDefs = [];
					for (a in args) {
						var d = TypeSupport.defType(a.t, expr.pos);
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
			var base = TypeSupport.sanitizeIdent(raw);
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
			var body = transExpr(func.expr, false, false, 0, false, lambdaCtx);
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
						target: TypeSupport.fieldNativeName(cf.get()),
						captures: []
					} else {
						var className = addClassType(c, []);
						{
							target: className + "_" + TypeSupport.sanitizeIdent(cf.get().name),
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
					var owner = c.get();
					var selfType = typeNameOfExprType(target.t, target.pos);
					if (owner.isExtern || cf.get().meta.has(":native")) {
						var helperName = nextHelperName("__fn_bound_");
						statics.push(buildBoundMethodWrapper(helperName, retType, TypeSupport.fieldNativeName(cf.get()), selfType, argTypes, true));
						{
							target: helperName,
							captures: [{t: target.t, expr: addInline(target)}]
						};
					} else {
						var className = addClassType(c, params);
						{
							target: className + "_" + TypeSupport.sanitizeIdent(cf.get().name),
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
								statics.push(buildBoundMethodWrapper(helperName, retType, TypeSupport.fieldNativeName(cf.get()), selfType, argTypes, true));
								{
									target: helperName,
									captures: [{t: target.t, expr: addInline(target)}]
								};
							} else {
								var className = addClassType(cc.c, cc.params);
								{
									target: className + "_" + TypeSupport.sanitizeIdent(cf.get().name),
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
					subject += "." + "__tag";
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
								buf.add(addInline(e) + "." + TypeSupport.fieldNativeName(field));
							case FMethod(_):
								if (owner.isExtern || field.meta.has(":native")) buf.add(addInline(e) + "." + TypeSupport.fieldNativeName(field)); else {
									var className = addClassType(c, params);
									buf.add(className + "_" + TypeSupport.sanitizeIdent(field.name));
								}
						}
					case FStatic(c, cf):
						var owner = c.get();
						var field = cf.get();
						if (owner.isExtern || field.meta.has(":native")) buf.add(TypeSupport.fieldNativeName(field)); else {
							var className = addClassType(c, []);
							buf.add(className + "_" + TypeSupport.sanitizeIdent(field.name));
						}
					case FAnon(cf):
						buf.add(addInline(e) + "." + TypeSupport.sanitizeIdent(cf.get().name));
					case FDynamic(s):
						buf.add(addInline(e) + "." + TypeSupport.sanitizeIdent(s));
					case FClosure(c, cf):
						var owner = switch c {
							case null:
								null;
							case v:
								addClassType(v.c, v.params);
						}
						if (owner == null) buf.add(TypeSupport.sanitizeIdent(cf.get()
							.name)); else if (c != null
							&& (c.c.get()
								.isExtern || cf.get()
								.meta.has(":native"))) buf.add(TypeSupport.fieldNativeName(cf.get())); else buf.add(owner + "_"
							+ TypeSupport.sanitizeIdent(cf.get().name));
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
						buf.add(addInline(el[0]) + "." + "__tag");
					case TField(target, FInstance(c, params, cf)):
						switch cf.get().kind {
							case FMethod(_):
								if (c.get()
									.isExtern || cf.get()
									.meta.has(":native")) buf.add(addInline(target) + "." + TypeSupport.fieldNativeName(cf.get()) + "(" + args.join(", ") +
										")"); else {
									var className = addClassType(c, params);
									args.unshift(addInline(target));
									buf.add((className + "_" + TypeSupport.sanitizeIdent(cf.get().name)) + "(" + args.join(", ") + ")");
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
					switchExpr += "." + "__tag";
				buf.add("switch (" + switchExpr + ") {\n");
				for (c in cases) {
					for (v in c.values) {
						indent(depth + 1);
						var caseValue = isEnumSwitch ? TypeSupport.enumCaseValueIndex(v) : addInline(v);
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
				buf.add(addInline(e1) + "." + ("__" + ef.name + "_" + index));
			case TEnumIndex(e1):
				buf.add(addInline(e1) + "." + "__tag");
			case TIdent(v):
				buf.add(TypeSupport.sanitizeIdent(v));
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

	static function ensureDispatcher(retType:String, argTypes:Array<String>):FunctionDispatcher {
		if (TypeSupport.curDispatchers == null)
			TypeSupport.curDispatchers = new Map();
		var key = retType + "(" + argTypes.join(",") + ")";
		var existing = TypeSupport.curDispatchers.get(key);
		if (existing != null)
			return existing;
		TypeSupport.curDispatcherSeq++;
		var created:FunctionDispatcher = {
			name: "__fn_dispatch_" + TypeSupport.curDispatcherSeq,
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
		if (TypeSupport.curDispatchers == null || !TypeSupport.curDispatchers.iterator().hasNext())
			return [];
		var defs = [];
		for (d in TypeSupport.curDispatchers) {
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
}
#end
