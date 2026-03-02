package sshader.transpiler;

import sshader.ShaderSource;

#if macro
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
