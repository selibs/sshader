package sshader;

#if macro
import sys.io.File;
import haxe.macro.Expr;
import haxe.macro.Context;
import sshader.transpiler.Transpiler;
#end

class ShaderBuilder {
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

		var isBuilt = false;
		Context.onAfterTyping(_ -> {
			var cls = Context.getLocalClass()?.get();
			if (isBuilt || cls == null)
				return;

			for (field in cls.fields.get())
				if (isShaderSource({name: field.name, meta: field.meta.get()})) {
					var src = Transpiler.buildShaderSource(cls, field);
					File.saveContent(cls.name + "." + field.name + ".glsl", src.toString());
				}
		});

		return fields;
	}
	#end
}
