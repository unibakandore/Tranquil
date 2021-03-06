#import <Tranquil/CodeGen/TQNode.h>

// A message to an object (object message: argument.)
@interface TQNodeMessage : TQNode
@property(readwrite, retain) TQNode *receiver;
@property(readwrite, copy) NSMutableArray *arguments, *cascadedMessages;
@property(readwrite, assign) BOOL needsAutorelease;
+ (TQNodeMessage *)nodeWithReceiver:(TQNode *)aNode;
- (id)initWithReceiver:(TQNode *)aNode;
- (NSString *)selector;
@end
