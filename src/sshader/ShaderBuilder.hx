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
		function typeEntryFunction(field:Field):TFunc {
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
			return switch field.kind {
				case FFun(f):
					var typed = Context.typeExpr({
						pos: field.pos,
						expr: EFunction(FAnonymous, f)
					});
					switch unwrapTyped(typed).expr {
						case TFunction(tf):
							tf;
						default:
							Context.error('Failed to type shader entry "${field.name}"', field.pos);
							null;
					}
				default:
					Context.error(field.name + " must be function", field.pos);
					null;
			}
		}

		var vertField:Null<Field> = null;
		var fragField:Null<Field> = null;
		for (field in fields) {
			if (field.name == "vert") {
				patchEntryBody(field);
				vertField = field;
			} else if (field.name == "frag") {
				patchEntryBody(field);
				fragField = field;
			}
		}

		var vertTyped:Null<TFunc> = null;
		var fragTyped:Null<TFunc> = null;
		if (vertField != null)
			vertTyped = typeEntryFunction(vertField);
		if (fragField != null)
			fragTyped = typeEntryFunction(fragField);

		var vertLayout = null;
		if (vertTyped != null) {
			var src = Transpiler.buildShaderSource(cls, "vert", vertField.pos, vertTyped);
			File.saveContent(cls.name + ".vert.glsl", src.toString());
			vertLayout = Transpiler.collectEntryVaryingLayout(vertTyped, vertField.pos);
		}
		if (fragTyped != null) {
			var src = Transpiler.buildShaderSource(cls, "frag", fragField.pos, fragTyped, vertLayout);
			File.saveContent(cls.name + ".frag.glsl", src.toString());
		}

		var out:Array<Field> = [];
		for (field in fields)
			if (field.name != "vert" && field.name != "frag")
				out.push(field);
		return fields;
	}
	#end
}
