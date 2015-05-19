//
//  wax_utility.m
//  BBAPods
//
//  Created by canyingwushang on 14/12/16.
//  Copyright (c) 2014年 Baidu. All rights reserved.
//

#import "wax_utility.h"
#import <objc/runtime.h>
#import "CGRectObject.h"

@implementation wax_utility

+ (instancetype)sharedInstance
{
    static wax_utility *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [wax_utility new];
    });
    return instance;
}

- (instancetype)init
{
    self = [super init];
    if (self)
    {
        
    }
    return self;
}

- (SEL)selectorFromString:(NSString *)selector
{
    if (selector == nil || selector.length == 0) return nil;
    
    return NSSelectorFromString(selector);
}

- (void)performSelectorOnMainThreadAsync:(id)instance Selctor:(SEL) selector WithObject:(id)obj
{
    if (instance && [instance respondsToSelector:@selector(performSelectorOnMainThread:withObject:waitUntilDone:)])
    {
        [instance performSelectorOnMainThread:selector withObject:obj waitUntilDone:NO];
    }
}

@end
