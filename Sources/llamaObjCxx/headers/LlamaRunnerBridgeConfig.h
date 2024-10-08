//
//  LlamaRunnerBridgeConfig.h
//  llama
//
//  Created by Alex Rozanski on 13/03/2023.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface _LlamaRunnerBridgeConfig : NSObject

@property (nonatomic, assign) NSUInteger numberOfThreads;
@property (nonatomic, assign) NSUInteger numberOfTokens;

@property (nullable, copy) NSString *reversePrompt;

@end

NS_ASSUME_NONNULL_END
