package sshader;

#if macro
import sys.io.File;
import haxe.io.Bytes;
import haxe.macro.Context;
import haxe.macro.Expr;
import sshader.transpiler.Transpiler;
#end

class ShaderBuilder {
	#if macro
	public static function build() {
		var fields = Context.getBuildFields();

		for (field in fields)
			if (field.name == "vert" || field.name == "frag")
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
						Context.error(field.name + " must be function", field.pos);
				}

		Context.onGenerate(_ -> {
			var cls = Context.getLocalClass()?.get();
			if (cls == null)
				return;

			for (field in cls.fields.get())
				if (field.name == "vert" || field.name == "frag") {
					var src = Transpiler.buildShaderSource(cls, field);
					File.saveContent(cls.name + "." + field.name + ".glsl", src.toString());
				}
		});

		return fields;
	}
	#end
}
