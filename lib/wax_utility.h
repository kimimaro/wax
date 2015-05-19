//
//  wax_utility.h
//  BBAPods
//
//  Created by canyingwushang on 14/12/16.
//  Copyright (c) 2014年 Baidu. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface wax_utility : NSObject

+ (instancetype)sharedInstance;

- (SEL)selectorFromString:(NSString *)selector;

- (void)performSelectorOnMainThreadAsync:(id)instance Selctor:(SEL) selector WithObject:(id)obj;

@end
