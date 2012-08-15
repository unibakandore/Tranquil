#import "TQHeaderParser.h"
#import "../Tranquil.h"
#import "../TQDebug.h"
#import "../Runtime/NSString+TQAdditions.h"
#import <objc/runtime.h>

using namespace llvm;

@interface TQHeaderParser ()
- (const char *)_encodingForFunPtrCursor:(CXCursor)cursor;
- (const char *)_encodingForCursor:(CXCursor)cursor;
- (void)_parseTranslationUnit:(CXTranslationUnit)translationUnit;
@end

@implementation TQHeaderParser
- (id)init
{
    if(!(self = [super init]))
        return nil;

    _functions        = [NSMutableDictionary new];
    _literalConstants = [NSMutableDictionary new];
    _constants        = [NSMutableDictionary new];
    _classes          = [NSMutableDictionary new];
    _protocols        = [NSMutableDictionary new];
    _typedefs         = [NSMutableDictionary new];
    _index            = clang_createIndex(0, 1);

    return self;
}

- (void)dealloc
{
    [_functions release];
    [_classes release];
    [_constants release];
    [_literalConstants release];
    [_protocols release];
    [_typedefs release];
    clang_disposeIndex(_index);

    [super dealloc];
}

- (id)parseHeader:(NSString *)aPath
{
    const char *args[] = { "-x", "objective-c" };
    CXTranslationUnit translationUnit = clang_parseTranslationUnit(_index, [aPath fileSystemRepresentation], args, 2, NULL, 0,
                                                                   CXTranslationUnit_DetailedPreprocessingRecord|CXTranslationUnit_SkipFunctionBodies);
    if (!translationUnit) {
        TQLog(@"Couldn't parse header %@\n", aPath);
        return nil;
    }
    [self _parseTranslationUnit:translationUnit];
    clang_disposeTranslationUnit(translationUnit);
    return TQValid;
}

- (id)parsePCH:(NSString *)aPath
{
    CXTranslationUnit translationUnit = clang_createTranslationUnit(_index, [aPath fileSystemRepresentation]);
    if (!translationUnit) {
        TQLog(@"Couldn't parse pch %@\n", aPath);
        return nil;
    }
    [self _parseTranslationUnit:translationUnit];
    clang_disposeTranslationUnit(translationUnit);
    return TQValid;
}

- (void)_parseTranslationUnit:(CXTranslationUnit)translationUnit
{
    clang_visitChildrenWithBlock(clang_getTranslationUnitCursor(translationUnit), ^(CXCursor cursor, CXCursor parent) {
        const char *name = clang_getCString(clang_getCursorSpelling(cursor));
        if(!name)
            return CXChildVisit_Continue;
        NSString *nsName = [NSString stringWithUTF8String:name];

        switch(cursor.kind) {
            case CXCursor_ObjCInterfaceDecl: {
                TQBridgedClassInfo *info = [TQBridgedClassInfo new];
                info.name = nsName;
                [_classes setObject:info forKey:nsName];
                _currentClass = info;
                [info release];
                return CXChildVisit_Recurse;
            } break;
            case CXCursor_ObjCSuperClassRef: {
                if(parent.kind == CXCursor_ObjCInterfaceDecl)
                    _currentClass.superclass = [_classes objectForKey:nsName];
            } break;
            case CXCursor_ObjCProtocolRef: {
                if(parent.kind == CXCursor_ObjCInterfaceDecl) {
                    TQBridgedClassInfo *protocolInfo = [_protocols objectForKey:nsName];
                    if(!protocolInfo)
                        break;
                    [_currentClass.instanceMethods addEntriesFromDictionary:protocolInfo.instanceMethods];
                    [_currentClass.classMethods    addEntriesFromDictionary:protocolInfo.classMethods];
                }
            } break;
            case CXCursor_ObjCCategoryDecl: {
                return CXChildVisit_Recurse;
            } break;
            case CXCursor_ObjCClassRef: {
                if(parent.kind == CXCursor_ObjCCategoryDecl)
                    _currentClass = [_classes objectForKey:nsName];
            } break;
            case CXCursor_ObjCProtocolDecl: {
                 TQBridgedClassInfo *info = [TQBridgedClassInfo new];
                [_protocols setObject:info forKey:nsName];
                _currentClass = info;
                [info release];
                return CXChildVisit_Recurse;
            } break;
            case CXCursor_ObjCClassMethodDecl:
            case CXCursor_ObjCInstanceMethodDecl: {
                BOOL isClassMethod = cursor.kind == CXCursor_ObjCClassMethodDecl;
                NSString *selector = nsName;
                NSString *encoding = [NSString stringWithUTF8String:[self _encodingForCursor:cursor]];
                if(isClassMethod)
                    [_currentClass.classMethods    setObject:encoding forKey:selector];
                else
                    [_currentClass.instanceMethods setObject:encoding forKey:selector];
            } break;
            case CXCursor_FunctionDecl: {
                // TODO: Support bridging variadic functions. Support or ignore inlined functions
                const char *encoding = [self _encodingForCursor:cursor];
                TQBridgedFunction *fun = [TQBridgedFunction functionWithName:nsName
                                                                    encoding:encoding];
                [_functions setObject:fun
                               forKey:[nsName stringByCapitalizingFirstLetter]];

            } break;
            case CXCursor_MacroDefinition: {
                CXSourceRange macroRange = clang_getCursorExtent(cursor);
                CXToken *tokens = 0;
                unsigned int tokenCount = 0;
                clang_tokenize(translationUnit, macroRange, &tokens, &tokenCount);
                if(tokenCount >= 2) {
                    // TODO: Support string constants?
                    if(clang_getTokenKind(tokens[1]) == CXToken_Literal) {
                        const char *value = clang_getCString(clang_getTokenSpelling(translationUnit, tokens[1]));
                        [_literalConstants setObject:[TQNodeNumber nodeWithDouble:atof(value)] forKey:nsName];
                    }
                }
                clang_disposeTokens(translationUnit, tokens, tokenCount);
            } break;
            case CXCursor_VarDecl: {
                [_constants setObject:[TQBridgedConstant constantWithName:nsName encoding:[self _encodingForCursor:cursor]]
                               forKey:nsName];
            } break;
            case CXCursor_EnumDecl: {
                return CXChildVisit_Recurse;
            } break;
            case CXCursor_EnumConstantDecl: {
                [_literalConstants setObject:[TQNodeNumber nodeWithDouble:clang_getEnumConstantDeclValue(cursor)]
                                      forKey:nsName];
            } break;
            // Ignored
            case CXCursor_UnexposedAttr:
            case CXCursor_StructDecl:
            case CXCursor_TypedefDecl:
            case CXCursor_TypeRef:
            case CXCursor_ObjCIvarDecl:
            case CXCursor_ObjCPropertyDecl:
            case CXCursor_MacroExpansion:
            case CXCursor_InclusionDirective:
            case CXCursor_UnionDecl: {
            } break;
            default:
                TQLog(@"Unhandled Objective-C entity: %s of type %d %s = %s\n", name, cursor.kind, clang_getCString(clang_getCursorKindSpelling(cursor.kind)),
                      clang_getCString(clang_getTypeKindSpelling(clang_getCursorType(cursor).kind)));
                break;
        }
        return CXChildVisit_Continue;
    });
}

- (TQNode *)entityNamed:(NSString *)aName
{
    id ret = [self functionNamed:aName];
    if(ret)
        return ret;
    return [self constantNamed:aName];
}

- (TQBridgedFunction *)functionNamed:(NSString *)aName
{
    return [_functions objectForKey:aName];
}

- (TQBridgedConstant *)constantNamed:(NSString *)aName
{
    id literal = [_literalConstants objectForKey:aName];
    if(literal)
        return literal;
    return [_constants objectForKey:aName];
}

- (TQBridgedClassInfo *)classNamed:(NSString *)aName
{
    return [_classes objectForKey:aName];
}


#pragma mark - Objective-C encoding generator

// Because the clang-c api doesn't allow us to access the "extended" encoding stuff inside libclang we must roll our own (It's less work than using the C++ api)
- (const char *)_encodingForFunPtrCursor:(CXCursor)cursor
{
    CXType type = clang_getCursorType(cursor);
    NSMutableString *realEncoding = [NSMutableString stringWithString:@"<"];

    if(type.kind == CXType_Typedef)
        return "@?"; // TODO: Typedef'd pointers
    else if(type.kind == CXType_BlockPointer)
        [realEncoding appendString:@"@"];
    else if(type.kind == CXType_Pointer)
        [realEncoding appendString:@"^"];
    else
        assert(0); // Should never reach here..

    __block BOOL isFirstChild = YES;
    clang_visitChildrenWithBlock(cursor, ^(CXCursor child, CXCursor parent) {
        // If the function returns void, we don't have a node for the return type
        if(isFirstChild && child.kind == CXCursor_ParmDecl)
            [realEncoding appendString:@"v"];
        isFirstChild = NO;

        const char *childEnc = [self _encodingForCursor:child];
        if(strstr(childEnc, "@?") == childEnc || strstr(childEnc, "^?") == childEnc)
            [realEncoding appendFormat:@"%s", [self _encodingForFunPtrCursor:child]];
        else
            [realEncoding appendFormat:@"%s", childEnc];
        return CXChildVisit_Continue;
    });
    if(isFirstChild) // No children => void return and no args
        [realEncoding appendString:@"v"];
    [realEncoding appendString:@">"];
    return [realEncoding UTF8String];
}

- (const char *)_encodingForCursor:(CXCursor)cursor
{
    const char *vanillaEncoding = clang_getCString(clang_getDeclObjCTypeEncoding(cursor));
    CXCursorKind kind = cursor.kind;
    if(strstr(vanillaEncoding, "@?") || strstr(vanillaEncoding, "^?")) {
        // Contains a block argument so we need to manually create the encoding for it
        NSMutableString *realEncoding = [NSMutableString string];
        __block BOOL isFirstChild = YES;
        clang_visitChildrenWithBlock(cursor, ^(CXCursor child, CXCursor parent) {
            if(isFirstChild && child.kind == CXCursor_ParmDecl && (kind == CXCursor_FunctionDecl || kind == CXCursor_ObjCForCollectionStmt
                                                                   || kind == CXIdxEntity_ObjCClassMethod || kind == CXIdxEntity_ObjCInstanceMethod)) {
                [realEncoding appendString:@"v"];
            }
            const char *childEnc = clang_getCString(clang_getDeclObjCTypeEncoding(child));
            if(strstr(childEnc, "@?") == childEnc || strstr(childEnc, "^?") == childEnc)
                [realEncoding appendFormat:@"%s", [self _encodingForFunPtrCursor:child]];
            else
                [realEncoding appendFormat:@"%s", childEnc];
            return CXChildVisit_Continue;
        });
        return [realEncoding UTF8String];
    }
    return vanillaEncoding;
}
@end

@implementation TQBridgedClassInfo
@synthesize name=_name, instanceMethods=_instanceMethods, classMethods=_classMethods, superclass=_superclass;
- (id)init
{
    if(!(self = [super init]))
        return nil;
    _instanceMethods = [NSMutableDictionary new];
    _classMethods    = [NSMutableDictionary new];
    return self;
}

- (NSString *)typeForInstanceMethod:(NSString *)aSelector
{
    NSString *enc = [_instanceMethods objectForKey:aSelector];
    if(enc)
        return enc;
    return [_superclass typeForInstanceMethod:aSelector];
}

- (NSString *)typeForClassMethod:(NSString *)aSelector
{
    NSString *enc = [_classMethods objectForKey:aSelector];
    if(enc)
        return enc;
    return [_superclass typeForClassMethod:aSelector];
}

- (void)dealloc
{
    [_name release];
    [_instanceMethods release];
    [_classMethods release];
    [super dealloc];
}
@end

@implementation TQBridgedConstant
@synthesize name=_name, encoding=_encoding;

+ (TQBridgedConstant *)constantWithName:(NSString *)aName encoding:(const char *)aEncoding;
{
    TQBridgedConstant *cnst = (TQBridgedConstant *)[self node];
    cnst.name = aName;
    cnst.encoding = aEncoding;
    return cnst;
}

- (void)dealloc
{
    [_name release];
    [super dealloc];
}

- (Value *)generateCodeInProgram:(TQProgram *)aProgram block:(TQNodeBlock *)aBlock error:(NSError **)aoErr
{
    if(_global)
        return aBlock.builder->CreateLoad(_global);

    // With constants we just want to unbox them once and then keep that object around
    Module *mod = aProgram.llModule;
    Function *rootFunction = aProgram.rootBlock.function;
    IRBuilder<> rootBuilder(&rootFunction->getEntryBlock(), rootFunction->getEntryBlock().begin());
    Value *constant = mod->getOrInsertGlobal([_name UTF8String], [aProgram llvmTypeFromEncoding:_encoding]);
    constant = rootBuilder.CreateBitCast(constant, aProgram.llInt8PtrTy);
    Value *boxed = rootBuilder.CreateCall2(aProgram.TQBoxValue, constant, [aProgram getGlobalStringPtr:[NSString stringWithUTF8String:_encoding]
                                                                                           withBuilder:&rootBuilder]);
    _global = new GlobalVariable(*mod, aProgram.llInt8PtrTy, false, GlobalVariable::InternalLinkage,
                                 ConstantPointerNull::get(aProgram.llInt8PtrTy), [[@"TQBridgedConst_" stringByAppendingString:_name] UTF8String]);
    rootBuilder.CreateStore(boxed, _global);
    return aBlock.builder->CreateLoad(_global);
}
@end

@interface TQNodeBlock (Privates)
- (llvm::Value *)_generateBlockLiteralInProgram:(TQProgram *)aProgram parentBlock:(TQNodeBlock *)aParentBlock;
@end

@implementation TQBridgedFunction
@synthesize name=_name, encoding=_encoding;

+ (TQBridgedFunction *)functionWithName:(NSString *)aName encoding:(const char *)aEncoding
{
    return [[[self alloc] initWithName:aName encoding:aEncoding] autorelease];
}

- (id)initWithName:(NSString *)aName encoding:(const char *)aEncoding
{
    if(!(self = [super init]))
        return nil;

    _name     = [aName retain];
    _encoding = aEncoding;
    _argTypes = [NSMutableArray new];
    TQIterateTypesInEncoding(aEncoding, ^(const char *type, NSUInteger size, NSUInteger align, BOOL *stop) {
        if(!_retType)
            _retType = [[NSString stringWithUTF8String:type] retain];
        else
            [_argTypes addObject:[NSString stringWithUTF8String:type]];
    });
    return self;
}

- (void)dealloc
{
    [_name release];
    [super dealloc];
}

- (NSUInteger)argumentCount
{
    return [_argTypes count];
}

// Compiles a a wrapper block for the function
// The reason we don't use TQBoxedObject is that when the function is known at compile time
// we can generate a far more efficient wrapper that doesn't rely on libffi
- (llvm::Function *)_generateInvokeInProgram:(TQProgram *)aProgram error:(NSError **)aoErr
{
    if(_function)
        return _function;

    llvm::PointerType *int8PtrTy = aProgram.llInt8PtrTy;

    // Build the invoke function
    std::vector<Type *> paramObjTypes(_argTypes.count+1, int8PtrTy);
    FunctionType* wrapperFunType = FunctionType::get(int8PtrTy, paramObjTypes, false);

    Module *mod = aProgram.llModule;

    const char *wrapperFunctionName = [[NSString stringWithFormat:@"__tq_wrapper_%@", _name] UTF8String];

    _function = Function::Create(wrapperFunType, GlobalValue::ExternalLinkage, wrapperFunctionName, mod);

    BasicBlock *entryBlock    = BasicBlock::Create(mod->getContext(), "entry", _function, 0);
    IRBuilder<> *entryBuilder = new IRBuilder<>(entryBlock);

    BasicBlock *callBlock     = BasicBlock::Create(mod->getContext(), "call", _function);
    IRBuilder<> *callBuilder  = new IRBuilder<>(callBlock);

    BasicBlock *errBlock      = BasicBlock::Create(mod->getContext(), "invalidArgError", _function);
    IRBuilder<> *errBuilder   = new IRBuilder<>(errBlock);

    // Load the block pointer argument (must do this before captures, which must be done before arguments in case a default value references a capture)
    llvm::Function::arg_iterator argumentIterator = _function->arg_begin();
    // Ignore the block pointer
    ++argumentIterator;


    // Load the arguments
    NSString *argTypeEncoding;
    Type *argType;
    std::vector<Type *> argTypes;
    std::vector<Value *> args;
    NSUInteger typeSize;
    BasicBlock  *nextBlock;
    IRBuilder<> *currBuilder, *nextBuilder;
    currBuilder = entryBuilder;

    Type *retType = [aProgram llvmTypeFromEncoding:[_retType UTF8String]];
    AllocaInst *resultAlloca = NULL;
    // If it's a void return we don't allocate a return buffer
    if(![_retType hasPrefix:@"v"])
        resultAlloca = entryBuilder->CreateAlloca(retType);

    TQGetSizeAndAlignment([_retType UTF8String], &typeSize, NULL);
    // Return doesn't fit in a register so we must pass an alloca before the function arguments
    // TODO: Make this cross platform
    BOOL returningOnStack = TQStructSizeRequiresStret(typeSize);
    if(returningOnStack) {
        argTypes.push_back(PointerType::getUnqual(retType));
        args.push_back(resultAlloca);
        retType = aProgram.llVoidTy;
    }

    NSMutableArray *byValArgIndices = [NSMutableArray array];
    if([_argTypes count] > 0) {
        Value *sentinel = entryBuilder->CreateLoad(mod->getOrInsertGlobal("TQSentinel", aProgram.llInt8PtrTy));
        for(int i = 0; i < [_argTypes count]; ++i)
        {
            argTypeEncoding = [_argTypes objectAtIndex:i];
            TQGetSizeAndAlignment([argTypeEncoding UTF8String], &typeSize, NULL);
            argType = [aProgram llvmTypeFromEncoding:[argTypeEncoding UTF8String]];
            // Larger structs should be passed as pointers to their location on the stack
            if(TQStructSizeRequiresStret(typeSize)) {
                argTypes.push_back(PointerType::getUnqual(argType));
                [byValArgIndices addObject:[NSNumber numberWithInt:i+1]]; // Add one to jump over retval
            } else
                argTypes.push_back(argType);

            IRBuilder<> startBuilder(&_function->getEntryBlock(), _function->getEntryBlock().begin());
            Value *unboxedArgAlloca = startBuilder.CreateAlloca(argType, NULL, [[NSString stringWithFormat:@"arg%d", i] UTF8String]);

            // If the value is a sentinel we've not been passed enough arguments => jump to error
            Value *notPassedCond = currBuilder->CreateICmpEQ(argumentIterator, sentinel);

            // Create the block for the next argument check (or set it to the call block)
            if(i == [_argTypes count]-1) {
                nextBlock = callBlock;
                nextBuilder = callBuilder;
            } else {
                nextBlock = BasicBlock::Create(mod->getContext(), [[NSString stringWithFormat:@"check%d", i] UTF8String], _function, callBlock);
                nextBuilder = new IRBuilder<>(nextBlock);
            }

            currBuilder->CreateCondBr(notPassedCond, errBlock, nextBlock);

            nextBuilder->CreateCall3(aProgram.TQUnboxObject,
                                     argumentIterator,
                                     [aProgram getGlobalStringPtr:argTypeEncoding withBuilder:nextBuilder],
                                     nextBuilder->CreateBitCast(unboxedArgAlloca, aProgram.llInt8PtrTy));
            if(TQStructSizeRequiresStret(typeSize))
                args.push_back(unboxedArgAlloca);
            else
                args.push_back(nextBuilder->CreateLoad(unboxedArgAlloca));

            ++argumentIterator;
            currBuilder = nextBuilder;
        }
    } else {
        currBuilder->CreateBr(callBlock);
    }

    // Populate the error block
    // TODO: Come up with a global error reporting mechanism and make this crash
    [aProgram insertLogUsingBuilder:errBuilder withStr:[@"Invalid number of arguments passed to " stringByAppendingString:_name]];
    errBuilder->CreateRet(ConstantPointerNull::get(int8PtrTy));

    // Populate call block
    FunctionType *funType = FunctionType::get(retType, argTypes, false);
    Function *function = aProgram.llModule->getFunction([_name UTF8String]);
    if(!function) {
        function = Function::Create(funType, GlobalValue::ExternalLinkage, [_name UTF8String], aProgram.llModule);
        function->setCallingConv(CallingConv::C);
        if(returningOnStack)
            function->addAttribute(1, Attribute::StructRet);
        for(NSNumber *idx in byValArgIndices) {
            function->addAttribute([idx intValue], Attribute::ByVal);
        }
    }

    Value *callResult = callBuilder->CreateCall(function, args);
    if([_retType hasPrefix:@"v"])
        callBuilder->CreateRet(ConstantPointerNull::get(aProgram.llInt8PtrTy));
    else if([_retType hasPrefix:@"@"])
        callBuilder->CreateRet(callResult);
    else {
        if(!returningOnStack)
            callBuilder->CreateStore(callResult, resultAlloca);
        Value *boxed = callBuilder->CreateCall2(aProgram.TQBoxValue,
                                                callBuilder->CreateBitCast(resultAlloca, int8PtrTy),
                                                [aProgram getGlobalStringPtr:_retType withBuilder:callBuilder]);
        // Retain/autorelease to force a TQBoxedObject move to the heap in case the returned value is stored in stack memory
        boxed = callBuilder->CreateCall(aProgram.objc_retainAutoreleaseReturnValue, boxed);
        callBuilder->CreateRet(boxed);
    }
    return _function;
}

- (llvm::Value *)generateCodeInProgram:(TQProgram *)aProgram block:(TQNodeBlock *)aBlock error:(NSError **)aoErr
{
    if(![self _generateInvokeInProgram:aProgram error:aoErr])
        return NULL;

    Value *literal = (Value*)[self _generateBlockLiteralInProgram:aProgram parentBlock:aBlock];

    return literal;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<bridged function@ %@>", _name];
}
@end