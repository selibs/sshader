package sshader;

import haxe.macro.Compiler;
#if macro
import haxe.macro.Type;
import haxe.macro.Expr;
import haxe.macro.Context;
import sshader.transpiler.Types;
import sshader.transpiler.Transpiler;
#end

class ShaderSourceBuilder {
	public static var VERSION = "450";

	#if macro
	public static function build() {
		function isShaderSource(field:{name:String, meta:Array<MetadataEntry>}) {
			var isShader = field.name == "vert" || field.name == "frag";
			if (!isShader)
				for (m in field.meta)
					switch m.name {
						case ":shader.source":
							isShader = true;
							break;
						default:
							continue;
					}
			return isShader;
		}

		var fields = Context.getBuildFields();

		for (field in fields)
			if (isShaderSource(field))
				switch field.kind {
					case FFun(f):
                        var e = macro return null;
						f.expr = {
							expr: switch f.expr.expr {
								case EBlock(exprs):
									EBlock(exprs.concat([e]));
								default:
									EBlock([f.expr, e]);
							},
							pos: f.expr.pos
						}
					default:
						Context.error(field.name + " must be function", field.pos);
				}

		Context.onAfterTyping(_ -> {
			var cls = Context.getLocalClass()?.get();
			if (cls == null)
				return;

			for (field in cls.fields.get())
				if (isShaderSource({name: field.name, meta: field.meta.get()})) {
					var src = Transpiler.buildShaderSource(field);
					trace(src);
				}
		});

		return fields;
	}
	#end
}
