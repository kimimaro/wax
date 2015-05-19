//
//  wax_garbage_collection.m
//  WaxTests
//
//  Created by Corey Johnson on 2/23/10.
//  Copyright 2010 Probably Interactive. All rights reserved.
//

#import "wax_gc.h"

#import "lua.h"
#import "lauxlib.h"

#import "wax.h"
#import "wax_instance.h"
#import "wax_helpers.h"

#define WAX_GC_TIMEOUT 5.0f     // 垃圾回收的触发间隔为5.0s

@implementation wax_gc

static NSTimer* timer = nil;

+ (void)start {
    [timer invalidate];
    timer = [[NSTimer scheduledTimerWithTimeInterval:WAX_GC_TIMEOUT target:self selector:@selector(cleanupUnusedObject) userInfo:nil repeats:YES] retain];
}

+ (void)stop {
    [timer invalidate];
    timer = nil;
}

+ (void)cleanupUnusedObject {
    lua_State *L = wax_currentLuaState();
    BEGIN_STACK_MODIFY(L)
    
    wax_instance_pushStrongUserdataTable(L);
    
    beginLuaExec();

    lua_pushnil(L);  // first key
    while (lua_next(L, -2)) {
        wax_instance_userdata *instanceUserdata = (wax_instance_userdata *)luaL_checkudata(L, -1, WAX_INSTANCE_METATABLE_NAME);
        lua_pop(L, 1); // pops the value, keeps the key
            
        if (!instanceUserdata->isClass && !instanceUserdata->isSuper && [instanceUserdata->instance retainCount] <= 1) {
            NSLog(@"wax gc gonna release:%@", instanceUserdata->instance);
            lua_pushvalue(L, -1);
            lua_pushnil(L);
            lua_rawset(L, -4); // Clear it!
            if(instanceUserdata->waxRetain) {
                NSLog(@"wax gc release:%@", instanceUserdata->instance);
                [instanceUserdata->instance release];
                instanceUserdata->waxRetain = NO; // fix gc bad exec
            }
        }        
    }
    endLuaExec();
    END_STACK_MODIFY(L, 0);
}

@end
