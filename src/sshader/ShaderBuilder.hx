package sshader;

#if macro
import sys.io.File;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;
import sshader.transpiler.Transpiler;
#end

class ShaderBuilder {
	#if macro
	public static function build() {
		var fields = Context.getBuildFields();

		var cls = Context.getLocalClass()?.get();
		if (cls == null)
			return fields;

		function patchEntryBody(field:Field):Void {
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
					};
				default:
					Context.error(field.name + " must be function", field.pos);
			}
		}
		function unwrapTyped(e:TypedExpr):TypedExpr {
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
		function typeEntryFunction(field:ClassField):TFunc {
			var methodExpr = field.expr();
			if (methodExpr == null)
				Context.error('Failed to type shader entry "${field.name}"', field.pos);
			return switch unwrapTyped(methodExpr).expr {
				case TFunction(tf):
					tf;
				default:
					Context.error('Failed to type shader entry "${field.name}"', field.pos);
					null;
			}
		}

		var hasVert = false;
		var hasFrag = false;
		for (field in fields) {
			if (field.name == "vert") {
				patchEntryBody(field);
				hasVert = true;
			} else if (field.name == "frag") {
				patchEntryBody(field);
				hasFrag = true;
			}
		}
		if (hasVert || hasFrag) {
			var targetModule = cls.module;
			var targetName = cls.name;
			Context.onAfterTyping(modules -> {
				var owner:Null<ClassType> = null;
				for (m in modules)
					switch m {
						case TClassDecl(c):
							var cur = c.get();
							if (cur.module == targetModule && cur.name == targetName) {
								owner = cur;
								break;
							}
						default:
					}
				if (owner == null)
					return;
				function findEntry(name:String):Null<ClassField> {
					for (f in owner.fields.get())
						if (f.name == name)
							return f;
					return null;
				}
				var vertField = findEntry("vert");
				var fragField = findEntry("frag");
				var vertTyped:Null<TFunc> = vertField == null ? null : typeEntryFunction(vertField);
				var fragTyped:Null<TFunc> = fragField == null ? null : typeEntryFunction(fragField);
				var vertLayout = null;
				if (vertTyped != null) {
					var src = Transpiler.buildShaderSource(owner, "vert", vertField.pos, vertTyped);
					File.saveContent(owner.name + ".vert.glsl", src.toString());
					vertLayout = Transpiler.collectEntryVaryingLayout(vertTyped, vertField.pos);
				}
				if (fragTyped != null) {
					var src = Transpiler.buildShaderSource(owner, "frag", fragField.pos, fragTyped, vertLayout);
					File.saveContent(owner.name + ".frag.glsl", src.toString());
				}
			});
		}

		return fields;
	}
	#end
}
