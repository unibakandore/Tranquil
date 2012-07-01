#import "TQNodeMessage.h"
#import "TQProgram.h"
#import "TQNodeArgument.h"
#import "TQNodeVariable.h"

using namespace llvm;

@implementation TQNodeMessage
@synthesize receiver=_receiver, arguments=_arguments;

+ (TQNodeMessage *)nodeWithReceiver:(TQNode *)aNode
{
	return [[[self alloc] initWithReceiver:aNode] autorelease];
}

- (id)initWithReceiver:(TQNode *)aNode
{
	if(!(self = [super init]))
		return nil;

	_receiver = [aNode retain];
	_arguments = [[NSMutableArray alloc] init];

	return self;
}

- (void)dealloc
{
	[_receiver release];
	[_arguments release];
	[super dealloc];
}

- (NSString *)description
{
	NSMutableString *out = [NSMutableString stringWithString:@"<msg@ "];
	[out appendFormat:@"%@ ", _receiver];

	for(TQNodeArgument *arg in _arguments) {
		[out appendFormat:@"%@ ", arg];
	}

	[out appendString:@".>"];
	return out;
}

- (NSString *)selector
{
	NSMutableString *selStr = [NSMutableString string];
	if(_arguments.count == 1 && ![[_arguments objectAtIndex:0] passedNode])
		[selStr appendString:[[_arguments objectAtIndex:0] identifier]];
	else {
		for(TQNodeArgument *arg in _arguments) {
			[selStr appendFormat:@"%@:", arg.identifier ? arg.identifier : @""];
		}
	}
	return selStr;
}

- (llvm::Value *)generateCodeInProgram:(TQProgram *)aProgram block:(TQNodeBlock *)aBlock error:(NSError **)aoErr
{
	llvm::IRBuilder<> *builder = aBlock.builder;

	NSString *selStr = [self selector];
	BOOL needsAutorelease = NO;
	if([selStr hasPrefix:@"init"])
		needsAutorelease = YES;
	else if([selStr hasPrefix:@"copy"])
		needsAutorelease = YES;
	else if([selStr isEqualToString:@"new"])
		needsAutorelease = YES;

	// Cache the selector into a global
	Module *mod = aProgram.llModule;
	Value *selectorGlobal = mod->getGlobalVariable([selStr UTF8String], false);
	if(!selectorGlobal) {
		Function *rootFunction = aProgram.root.function;
		IRBuilder<> rootBuilder(&rootFunction->getEntryBlock(), rootFunction->getEntryBlock().begin());
		Value *selector =  rootBuilder.CreateGlobalStringPtr([selStr UTF8String], "selector");
		CallInst *selReg = rootBuilder.CreateCall(aProgram.sel_registerName, selector);
		selectorGlobal =  new GlobalVariable(*mod, aProgram.llInt8PtrTy, false, GlobalVariable::InternalLinkage,
		                                     ConstantPointerNull::get(aProgram.llInt8PtrTy), [selStr UTF8String]);
		rootBuilder.CreateStore(selReg, selectorGlobal);
	}
	selectorGlobal = builder->CreateLoad(selectorGlobal);

	std::vector<Value*> args;
	args.push_back([_receiver generateCodeInProgram:aProgram block:aBlock error:aoErr]);
	args.push_back(selectorGlobal);

	for(TQNodeArgument *arg in _arguments) {
		if(!arg.passedNode)
			break;
		args.push_back([arg generateCodeInProgram:aProgram block:aBlock error:aoErr]);
	}

	Value *ret;
	if([_receiver isMemberOfClass:[TQNodeSuper class]])
		return NULL; // TODO: implement super calls
	else
		ret = builder->CreateCall(aProgram.objc_msgSend, args);
	if(needsAutorelease)
		ret = builder->CreateCall(aProgram.TQAutoreleaseObject, ret);
	return ret;
}

@end
