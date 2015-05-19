/*
 *  wax_instance.c
 *  Lua
 *
 *  Created by ProbablyInteractive on 5/18/09.
 *  Copyright 2009 Probably Interactive. All rights reserved.
 *
 */

#import "wax_instance.h"
#import "wax_class.h"
#import "wax.h"
#import "wax_helpers.h"

#import "lauxlib.h"
#import "lobject.h"

#define METHODE_SWIZZLING_ORIG_TAG  "ORIG"

static int __index(lua_State *L);
static int __newindex(lua_State *L);
static int __gc(lua_State *L);
static int __tostring(lua_State *L);
static int __eq(lua_State *L);

static int methods(lua_State *L);

static int methodClosure(lua_State *L);
static int superMethodClosure(lua_State *L);
static int customInitMethodClosure(lua_State *L);

static BOOL overrideMethod(lua_State *L, wax_instance_userdata *instanceUserdata);
//static int pcallUserdata(lua_State *L, id self, SEL selector, va_list args);

static const struct luaL_Reg metaFunctions[] = {
    {"__index", __index},
    {"__newindex", __newindex},
    {"__gc", __gc},
    {"__tostring", __tostring},
    {"__eq", __eq},
    {NULL, NULL}
};

static const struct luaL_Reg functions[] = {
    {"methods", methods},
    {NULL, NULL}
};

int luaopen_wax_instance(lua_State *L) {
    BEGIN_STACK_MODIFY(L);
    
    luaL_newmetatable(L, WAX_INSTANCE_METATABLE_NAME);
    luaL_register(L, NULL, metaFunctions);
    luaL_register(L, WAX_INSTANCE_METATABLE_NAME, functions);    
    
    END_STACK_MODIFY(L, 0)
    
    return 1;
}

#pragma mark Instance Utils

static NSMutableDictionary *pluginActionRecord = nil;

bool recordPluginActions(const char *pluginID, const char *className);
bool replaceMethodIMP(Class className, SEL selector, IMP newimp, const char *typeDesc, const char *moduleID);

#pragma mark -------------------

// Creates userdata object for obj-c instance/class and pushes it onto the stack
wax_instance_userdata *wax_instance_create(lua_State *L, id instance, BOOL isClass) {
    BEGIN_STACK_MODIFY(L)
    
    // Does user data already exist?
    wax_instance_pushUserdata(L, instance);
   
    if (lua_isnil(L, -1)) {
        //wax_log(LOG_GC, @"Creating %@ for %@(%p)", isClass ? @"class" : @"instance", [instance class], instance);
        lua_pop(L, 1); // pop nil stack
    }
    else {
        //wax_log(LOG_GC, @"Found existing userdata %@ for %@(%p)", isClass ? @"class" : @"instance", [instance class], instance);
        return lua_touserdata(L, -1);
    }
    
    size_t nbytes = sizeof(wax_instance_userdata);
    wax_instance_userdata *instanceUserdata = (wax_instance_userdata *)lua_newuserdata(L, nbytes);
    instanceUserdata->instance = instance;
    instanceUserdata->isClass = isClass;
    instanceUserdata->isSuper = nil;
	instanceUserdata->actAsSuper = NO;
    instanceUserdata->waxRetain = NO;
     
    if (!isClass) {
        //wax_log(LOG_GC, @"Retaining %@ for %@(%p -> %p)", isClass ? @"class" : @"instance", [instance class], instance, instanceUserdata);
        [instanceUserdata->instance retain];
    }
    
    // set the metatable
    luaL_getmetatable(L, WAX_INSTANCE_METATABLE_NAME);
    lua_setmetatable(L, -2);

    // give it a nice clean environment
    lua_newtable(L); 
    lua_setfenv(L, -2);
    
    wax_instance_pushUserdataTable(L);

    // register the userdata table in the metatable (so we can access it from obj-c)
    //wax_log(LOG_GC, @"Storing reference of %@ to userdata table %@(%p -> %p)", isClass ? @"class" : @"instance", [instance class], instance, instanceUserdata);        
    lua_pushlightuserdata(L, instanceUserdata->instance);
    lua_pushvalue(L, -3); // Push userdata
    lua_rawset(L, -3);
        
    lua_pop(L, 1); // Pop off userdata table

    
    wax_instance_pushStrongUserdataTable(L);
    lua_pushlightuserdata(L, instanceUserdata->instance);
    lua_pushvalue(L, -3); // Push userdata
    lua_rawset(L, -3);
    
    //wax_log(LOG_GC, @"Storing reference to strong userdata table %@(%p -> %p)", [instance class], instance, instanceUserdata);        
    
    lua_pop(L, 1); // Pop off strong userdata table
    
    END_STACK_MODIFY(L, 1)
    
    return instanceUserdata;
}

// Creates pseudo-super userdata object for obj-c instance and pushes it onto the stack
wax_instance_userdata *wax_instance_createSuper(lua_State *L, wax_instance_userdata *instanceUserdata) {
    BEGIN_STACK_MODIFY(L)
    
    size_t nbytes = sizeof(wax_instance_userdata);
    wax_instance_userdata *superInstanceUserdata = (wax_instance_userdata *)lua_newuserdata(L, nbytes);
    superInstanceUserdata->instance = instanceUserdata->instance;
    superInstanceUserdata->isClass = instanceUserdata->isClass;
	superInstanceUserdata->actAsSuper = YES;
    superInstanceUserdata->waxRetain = NO;
	
	// isSuper not only stores whether the class is a super, but it also contains the value of the next superClass
	if (instanceUserdata->isSuper) {
		superInstanceUserdata->isSuper = [instanceUserdata->isSuper superclass];
	}
	else {
		superInstanceUserdata->isSuper = [instanceUserdata->instance superclass];
	}

    
    // set the metatable
    luaL_getmetatable(L, WAX_INSTANCE_METATABLE_NAME);
    lua_setmetatable(L, -2);
        
    wax_instance_pushUserdata(L, instanceUserdata->instance);
    if (lua_isnil(L, -1)) { // instance has no lua object, push empty env table (This shouldn't happen, tempted to remove it)
        lua_pop(L, 1); // Remove nil and superclass userdata
        lua_newtable(L); 
    }
    else {
        lua_getfenv(L, -1);
        lua_remove(L, -2); // Remove nil and superclass userdata
    }

	// Give it the instance's metatable
    lua_setfenv(L, -2);
    
    END_STACK_MODIFY(L, 1)
    
    return superInstanceUserdata;
}

// The userdata table holds weak references too all the instance userdata
// created. This is used to manage all instances of Objective-C objects created
// via Lua so we can release/gc them when both Lua and Objective-C are finished with
// them.
void wax_instance_pushUserdataTable(lua_State *L) {
    BEGIN_STACK_MODIFY(L)
    static const char* userdataTableName = "__wax_userdata";
    luaL_getmetatable(L, WAX_INSTANCE_METATABLE_NAME);
    lua_getfield(L, -1, userdataTableName);
    
    if (lua_isnil(L, -1)) { // Create new userdata table, add it to metatable
        lua_pop(L, 1); // Remove nil
        
        lua_pushstring(L, userdataTableName); // Table name
        lua_newtable(L);        
        lua_rawset(L, -3); // Add userdataTableName table to WAX_INSTANCE_METATABLE_NAME      
        lua_getfield(L, -1, userdataTableName);
        
        lua_pushvalue(L, -1);
        lua_setmetatable(L, -2); // userdataTable is it's own metatable
        
        lua_pushstring(L, "v");
        lua_setfield(L, -2, "__mode");  // Make weak table
    }
    
    END_STACK_MODIFY(L, 1)
}

// Holds strong references to userdata created by wax... if the retain count dips below
// 2, then we can remove it because we know obj-c doesn't care about it anymore
void wax_instance_pushStrongUserdataTable(lua_State *L) {
    BEGIN_STACK_MODIFY(L)
    static const char* userdataTableName = "__wax_strong_userdata";
    luaL_getmetatable(L, WAX_INSTANCE_METATABLE_NAME);
    lua_getfield(L, -1, userdataTableName);
    
    if (lua_isnil(L, -1)) { // Create new userdata table, add it to metatable
        lua_pop(L, 1); // Remove nil
        
        lua_pushstring(L, userdataTableName); // Table name
        lua_newtable(L);        
        lua_rawset(L, -3); // Add userdataTableName table to WAX_INSTANCE_METATABLE_NAME      
        lua_getfield(L, -1, userdataTableName);
    }
    
    END_STACK_MODIFY(L, 1)
}


// First look in the object's userdata for the function, then look in the object's class's userdata
BOOL wax_instance_pushFunction(lua_State *L, id self, SEL selector, NSArray *exTypes) {
    BEGIN_STACK_MODIFY(L)
    
    wax_instance_pushUserdata(L, self);
    if (lua_isnil(L, -1)) {
        // TODO:
        // quick and dirty solution to let obj-c call directly into lua
        // cause a obj-c leak, should we release it later?
        wax_instance_userdata *data = wax_instance_create(L, self, NO);
        if (data->instance)
        {
            NSLog(@"wax push function wax retain:%@.", data->instance);
        }
        data->waxRetain = YES;
//        [self release];
//        END_STACK_MODIFY(L, 0)
//        return NO; // userdata doesn't exist
    }
    
    lua_getfenv(L, -1);
    wax_pushMethodNameFromSelector(L, selector, exTypes);
    lua_rawget(L, -2);
    
    BOOL result = YES;
    
    if (!lua_isfunction(L, -1)) { // function not found in userdata
        lua_pop(L, 3); // Remove userdata, env and non-function
        if ([self class] == self) { // This is a class, not an instance
            result = wax_instance_pushFunction(L, [self superclass], selector, exTypes); // Check to see if the super classes know about this function
        }
        else {
            result = wax_instance_pushFunction(L, [self class], selector, exTypes);
        }
    }
    
    END_STACK_MODIFY(L, 1)
    
    return result;
}

// Retrieves associated userdata for an object from the wax instance userdata table
void wax_instance_pushUserdata(lua_State *L, id object) {
    BEGIN_STACK_MODIFY(L);
    
    wax_instance_pushUserdataTable(L);
    lua_pushlightuserdata(L, object);
    lua_rawget(L, -2);
    lua_remove(L, -2); // remove userdataTable
    
    
    END_STACK_MODIFY(L, 1)
}

BOOL wax_instance_isWaxClass(id instance) {
     // If this is a wax class, or an instance of a wax class, it has the userdata ivar set
    return class_getInstanceVariable([instance class], WAX_CLASS_INSTANCE_USERDATA_IVAR_NAME) != nil;
}


#pragma mark Override Metatable Functions
#pragma mark ---------------------------------

static int __index(lua_State *L) {
    wax_instance_userdata *instanceUserdata = (wax_instance_userdata *)luaL_checkudata(L, 1, WAX_INSTANCE_METATABLE_NAME);    
    
    if (lua_isstring(L, 2) && strcmp("super", lua_tostring(L, 2)) == 0) { // call to super!        
        wax_instance_createSuper(L, instanceUserdata);        
        return 1;
    }
    
    // Check instance userdata, unless we are acting like a super
	if (!instanceUserdata->actAsSuper) {
		lua_getfenv(L, -2);
		lua_pushvalue(L, -2);
		lua_rawget(L, 3);
	}
	else {
		lua_pushnil(L);
	}

    // Check instance's class userdata, or if it is a super, check the super's class data
    Class classToCheck = instanceUserdata->actAsSuper ? instanceUserdata->isSuper : [instanceUserdata->instance class];	
	while (lua_isnil(L, -1) && wax_instance_isWaxClass(classToCheck)) {
		// Keep checking superclasses if they are waxclasses, we want to treat those like they are lua
		lua_pop(L, 1);
		wax_instance_pushUserdata(L, classToCheck);
		
		// If there is no userdata for this instance's class, then leave the nil on the stack and don't anything else
		if (!lua_isnil(L, -1)) {
			lua_getfenv(L, -1);
			lua_pushvalue(L, 2);
			lua_rawget(L, -2);
			lua_remove(L, -2); // Get rid of the userdata env
			lua_remove(L, -2); // Get rid of the userdata
		}
		
		classToCheck = class_getSuperclass(classToCheck);
    }
            
    if (lua_isnil(L, -1)) { // If we are calling a super class, or if we couldn't find the index in the userdata environment table, assume it is defined in obj-c classes
        SEL foundSelectors[2] = {nil, nil};
        BOOL foundSelector = wax_selectorForInstance(instanceUserdata, foundSelectors, lua_tostring(L, 2), NO, nil);

        if (foundSelector) { // If the class has a method with this name, push as a closure
            lua_pushstring(L, sel_getName(foundSelectors[0]));
            foundSelectors[1] ? lua_pushstring(L, sel_getName(foundSelectors[1])) : lua_pushnil(L);
            lua_pushcclosure(L, instanceUserdata->actAsSuper ? superMethodClosure : methodClosure, 2);
        }
    }
    else if (!instanceUserdata->isSuper && instanceUserdata->isClass && wax_isInitMethod(lua_tostring(L, 2))) { // Is this an init method create in lua?
        lua_pushcclosure(L, customInitMethodClosure, 1);
    }
	
	// Always reset this, an object only acts like a super ONE TIME!
	instanceUserdata->actAsSuper = NO;
    
    return 1;
}

static int __newindex(lua_State *L) {
    wax_instance_userdata *instanceUserdata = (wax_instance_userdata *)luaL_checkudata(L, 1, WAX_INSTANCE_METATABLE_NAME);
    
    // If this already exists in a protocol, or superclass make sure it will call the lua functions
    if (instanceUserdata->isClass && lua_type(L, 3) == LUA_TFUNCTION) {
        overrideMethod(L, instanceUserdata);
    }
    
    // Add value to the userdata's environment table
    lua_getfenv(L, 1);
    lua_insert(L, 2);
    lua_rawset(L, 2);        
    
    return 0;
}

static int __gc(lua_State *L) {
    wax_instance_userdata *instanceUserdata = (wax_instance_userdata *)luaL_checkudata(L, 1, WAX_INSTANCE_METATABLE_NAME);
    
    //wax_log(LOG_GC, @"Releasing %@ %@(%p)", instanceUserdata->isClass ? @"Class" : @"Instance", [instanceUserdata->instance class], instanceUserdata->instance);
    
    if (!instanceUserdata->isClass && !instanceUserdata->isSuper) {
        // This seems like a stupid hack. But...
        // If we want to call methods on an object durring gc, we have to readd 
        // the instance/userdata to the userdata table. Why? Because it is 
        // removed from the weak table before GC is called.
        wax_instance_pushUserdataTable(L);        
        lua_pushlightuserdata(L, instanceUserdata->instance);        
        lua_pushvalue(L, -3);
        lua_rawset(L, -3);
        
        NSLog(@"wax __gc release:%@", instanceUserdata->instance);
        [instanceUserdata->instance release];
        
//        if(instanceUserdata->waxRetain) {
//            NSLog(@"wax gc release:%@", instanceUserdata->instance);
//            [instanceUserdata->instance release];
//            instanceUserdata->waxRetain = NO; // fix gc bad exec
//        }
        
        lua_pushlightuserdata(L, instanceUserdata->instance);
        lua_pushnil(L);
        lua_rawset(L, -3);
        lua_pop(L, 1);        
    }
    
    return 0;
}

static int __tostring(lua_State *L) {
    wax_instance_userdata *instanceUserdata = (wax_instance_userdata *)luaL_checkudata(L, 1, WAX_INSTANCE_METATABLE_NAME);
    lua_pushstring(L, [[NSString stringWithFormat:@"(%p => %p) %@", instanceUserdata, instanceUserdata->instance, instanceUserdata->instance] UTF8String]);
    
    return 1;
}

static int __eq(lua_State *L) {
    wax_instance_userdata *o1 = (wax_instance_userdata *)luaL_checkudata(L, 1, WAX_INSTANCE_METATABLE_NAME);
    wax_instance_userdata *o2 = (wax_instance_userdata *)luaL_checkudata(L, 2, WAX_INSTANCE_METATABLE_NAME);
    
    lua_pushboolean(L, [o1->instance isEqual:o2->instance]);
    return 1;
}

#pragma mark Userdata Functions
#pragma mark -----------------------

static int methods(lua_State *L) {
    wax_instance_userdata *instanceUserdata = (wax_instance_userdata *)luaL_checkudata(L, 1, WAX_INSTANCE_METATABLE_NAME);
    
    uint count;
    Method *methods = class_copyMethodList([instanceUserdata->instance class], &count);
    
    lua_newtable(L);
    
    for (int i = 0; i < count; i++) {
        Method method = methods[i];
        lua_pushstring(L, sel_getName(method_getName(method)));
        lua_rawseti(L, -2, i + 1);
    }

    return 1;
}

#pragma mark Function Closures
#pragma mark ----------------------

static int methodClosure(lua_State *L) {
    wax_instance_userdata *instanceUserdata = (wax_instance_userdata *)luaL_checkudata(L, 1, WAX_INSTANCE_METATABLE_NAME);    
    const char *selectorName = luaL_checkstring(L, lua_upvalueindex(1));

    // If the only arg is 'self' and there is a selector with no args. USE IT!
    if (lua_gettop(L) == 1 && lua_isstring(L, lua_upvalueindex(2))) {
        selectorName = luaL_checkstring(L, lua_upvalueindex(2));
    }
    
    SEL selector = sel_getUid(selectorName);
    id instance = instanceUserdata->instance;
    BOOL autoAlloc = NO;
        
    // If init is called on a class, auto-allocate it.    
    if (instanceUserdata->isClass && wax_isInitMethod(selectorName)) {
        autoAlloc = YES;
        instance = [instance alloc];
    }
    
    NSMethodSignature *signature = [instance methodSignatureForSelector:selector];
    if (!signature) {
        const char *className = [NSStringFromClass([instance class]) UTF8String];
        luaL_error(L, "'%s' has no method selector '%s'", className, selectorName);
    }
    
    NSInvocation *invocation = nil;
    invocation = [NSInvocation invocationWithMethodSignature:signature];
        
    [invocation setTarget:instance];
    [invocation setSelector:selector];
    
    int objcArgumentCount = (int)[signature numberOfArguments] - 2; // skip the hidden self and _cmd argument
    int luaArgumentCount = lua_gettop(L) - 1;
    
    
    if (objcArgumentCount > luaArgumentCount && !wax_instance_isWaxClass(instance)) { 
        luaL_error(L, "Not Enough arguments given! Method named '%s' requires %d argument(s), you gave %d. (Make sure you used ':' to call the method)", selectorName, objcArgumentCount + 1, lua_gettop(L));
    }
    
    void **arguements = calloc(sizeof(void*), objcArgumentCount);
    for (int i = 0; i < objcArgumentCount; i++) {
        arguements[i] = wax_copyToObjc(L, [signature getArgumentTypeAtIndex:i + 2], i + 2, nil);
        [invocation setArgument:arguements[i] atIndex:i + 2];
    }

    @try {
        [invocation invoke];
    }
    @catch (NSException *exception) {
        luaL_error(L, "Error invoking method '%s' on '%s' because %s", selector, class_getName([instance class]), [[exception description] UTF8String]);
    }
    
    for (int i = 0; i < objcArgumentCount; i++) {
        free(arguements[i]);
    }
    free(arguements);
    
    int methodReturnLength = (int)[signature methodReturnLength];
    if (methodReturnLength > 0) {
        void *buffer = calloc(1, methodReturnLength);
        [invocation getReturnValue:buffer];
            
        wax_fromObjc(L, [signature methodReturnType], buffer);
                
        if (autoAlloc) {
            if (lua_isnil(L, -1)) {
                // The init method returned nil... means initialization failed!
                // Remove it from the userdataTable (We don't ever want to clean up after this... it should have cleaned up after itself)
                wax_instance_pushUserdataTable(L);
                lua_pushlightuserdata(L, instance);
                lua_pushnil(L);
                lua_rawset(L, -3);
                lua_pop(L, 1); // Pop the userdataTable
                
                lua_pushnil(L);
                [instance release];
            }
            else {
                wax_instance_userdata *returnedInstanceUserdata = (wax_instance_userdata *)lua_topointer(L, -1);
                if (returnedInstanceUserdata) { // Could return nil
                    [returnedInstanceUserdata->instance release]; // Wax automatically retains a copy of the object, so the alloc needs to be released
                }
            }            
        }
        
        free(buffer);
    }
    
    return 1;
}

static int superMethodClosure(lua_State *L) {
    wax_instance_userdata *instanceUserdata = (wax_instance_userdata *)luaL_checkudata(L, 1, WAX_INSTANCE_METATABLE_NAME);
    const char *selectorName = luaL_checkstring(L, lua_upvalueindex(1));

    // If the only arg is 'self' and there is a selector with no args. USE IT!
    if (lua_gettop(L) == 1 && lua_isstring(L, lua_upvalueindex(2))) {
        selectorName = luaL_checkstring(L, lua_upvalueindex(2));
    }
    
    SEL selector = sel_getUid(selectorName);
    
    // Super Swizzle
    Method selfMethod = class_getInstanceMethod([instanceUserdata->instance class], selector);
    Method superMethod = class_getInstanceMethod(instanceUserdata->isSuper, selector);        
    
    if (superMethod && selfMethod != superMethod) { // Super's got what you're looking for
        IMP selfMethodImp = method_getImplementation(selfMethod);        
        IMP superMethodImp = method_getImplementation(superMethod);
        method_setImplementation(selfMethod, superMethodImp);
        
        methodClosure(L);
        
        method_setImplementation(selfMethod, selfMethodImp); // Swap back to self's original method
    }
    else {
        methodClosure(L);
    }
    
    return 1;
}

static int customInitMethodClosure(lua_State *L) {
    wax_instance_userdata *classInstanceUserdata = (wax_instance_userdata *)luaL_checkudata(L, 1, WAX_INSTANCE_METATABLE_NAME);
    wax_instance_userdata *instanceUserdata = nil;
	
    id instance = nil;
    BOOL shouldRelease = NO;
    if (classInstanceUserdata->isClass) {
        shouldRelease = YES;
        instance = [classInstanceUserdata->instance alloc];
        instanceUserdata = wax_instance_create(L, instance, NO);
        lua_replace(L, 1); // replace the old userdata with the new one!
    }
    else {
        luaL_error(L, "I WAS TOLD THIS WAS A CUSTOM INIT METHOD. BUT YOU LIED TO ME");
        return -1;
    }
    
    lua_pushvalue(L, lua_upvalueindex(1)); // Grab the function!
    lua_insert(L, 1); // push it up top
    
    if (wax_pcall(L, lua_gettop(L) - 1, 1)) {
        const char* errorString = lua_tostring(L, -1);
        luaL_error(L, "Custom init method on '%s' failed.\n%s", class_getName([instanceUserdata->instance class]), errorString);
    }
    
    if (shouldRelease) {
        [instance release];
    }
    
    if (lua_isnil(L, -1)) { // The init method returned nil... return the instanceUserdata instead
		luaL_error(L, "Init method must return the self");
    }
  
    return 1;
}

#pragma mark Override Methods
#pragma mark ---------------------

static int bba_pcallUserdata(lua_State *L, id self, SEL selector, NSArray * args, NSArray *argsTypeDescs)
{
    beginLuaExec();
    BEGIN_STACK_MODIFY(L)
    
    if (args.count != argsTypeDescs.count) goto error; // 参数个数必须参数类型描述个数相同
    
    // A WaxClass could have been created via objective-c (like via NSKeyUnarchiver)
    // In this case, no lua object was ever associated with it, so we've got to
    // create one.
    if (wax_instance_isWaxClass(self)) {
        BOOL isClass = self == [self class];
        wax_instance_create(L, self, isClass); // If it already exists, then it will just return without doing anything
        lua_pop(L, 1); // Pops userdata off
    }
    
    //NSString *exType = nil;
    //if (argsTypeDescs.count > 0) exType = argsTypeDescs[0];
    
    // Find the function... could be in the object or in the class
    if (!wax_instance_pushFunction(L, self, selector, argsTypeDescs)) {
        lua_pushfstring(L, "Could not find function named \"%s\" associated with object %s(%p).(It may have been released by the GC)", selector, class_getName([self class]), self);
        goto error; // function not found in userdata...
    }
    
    // Push userdata as the first argument
    wax_fromInstance(L, self);
    if (lua_isnil(L, -1)) {
        lua_pushfstring(L, "Could not convert '%s' into lua", class_getName([self class]));
        goto error;
    }
    
    NSMethodSignature *signature = [self methodSignatureForSelector:selector];
    int nargs = (int)[signature numberOfArguments] - 1; // Don't send in the _cmd argument, only self
    int nresults = [signature methodReturnLength] ? 1 : 0;
    
    for (int i = 2; i < [signature numberOfArguments]; i++) { // start at 2 because to skip the automatic self and _cmd arugments
        //const char *type = [signature getArgumentTypeAtIndex:i];
        bba_wax_fromObjc(L, [argsTypeDescs objectAtIndex:i-2], args, i - 2);
    }
    
    if (wax_pcall(L, nargs, nresults)) { // Userdata will allways be the first object sent to the function
        goto error;
    }
    
    END_STACK_MODIFY(L, nresults)
    
    endLuaExec();
    
    return nresults;
    
error:
    END_STACK_MODIFY(L, 1)
    endLuaExec();
    return -1;
}

/*
static int pcallUserdata(lua_State *L, id self, SEL selector, va_list args) {
    BEGIN_STACK_MODIFY(L)    
    
    if (![[NSThread currentThread] isEqual:[NSThread mainThread]]) NSLog(@"PCALLUSERDATA: OH NO SEPERATE THREAD");
    
    // A WaxClass could have been created via objective-c (like via NSKeyUnarchiver)
    // In this case, no lua object was ever associated with it, so we've got to
    // create one.
    if (wax_instance_isWaxClass(self)) {
        BOOL isClass = self == [self class];
        wax_instance_create(L, self, isClass); // If it already exists, then it will just return without doing anything
        lua_pop(L, 1); // Pops userdata off
    }
    
    // Find the function... could be in the object or in the class
    if (!wax_instance_pushFunction(L, self, selector)) {
        lua_pushfstring(L, "Could not find function named \"%s\" associated with object %s(%p).(It may have been released by the GC)", selector, class_getName([self class]), self);
        goto error; // function not found in userdata...
    }
    
    // Push userdata as the first argument
    wax_fromInstance(L, self);
    if (lua_isnil(L, -1)) {
        lua_pushfstring(L, "Could not convert '%s' into lua", class_getName([self class]));
        goto error;
    }
                
    NSMethodSignature *signature = [self methodSignatureForSelector:selector];
    int nargs = (int)[signature numberOfArguments] - 1; // Don't send in the _cmd argument, only self
    int nresults = [signature methodReturnLength] ? 1 : 0;
        
    for (int i = 2; i < [signature numberOfArguments]; i++) { // start at 2 because to skip the automatic self and _cmd arugments
        // 可变参数列表作64位适配
        if (wax_isproc64())
        {
 // x86_64和arm64的函数调用规则不同，因此需要分别对待
#if TARGET_IPHONE_SIMULATOR
            const char *type = [signature getArgumentTypeAtIndex:i];
            wax_fromObjcEx(L, type, args);
#else
            //todo
#endif
        }
        else
        {
            const char *type = [signature getArgumentTypeAtIndex:i];
            int size = wax_fromObjc(L, type, args);
            args += size; // HACK! Since va_arg requires static type, I manually increment the args
        }
    }

    if (wax_pcall(L, nargs, nresults)) { // Userdata will allways be the first object sent to the function  
        goto error;
    }
    
    END_STACK_MODIFY(L, nresults)
    return nresults;
    
error:
    END_STACK_MODIFY(L, 1)
    return -1;
}
*/

// 目前支持的函数原型

// 无参
#define BBA_WAX_METHOD_KIND_VOID            VOID_FLAG

// 一个参数
#define BBA_WAX_METHOD_KIND_1_INT           INT_FLAG
#define BBA_WAX_METHOD_KIND_1_ID            ID_FLAG
#define BBA_WAX_METHOD_KIND_1_FLOAT         FLOAT_FLAG
#define BBA_WAX_METHOD_KIND_1_BOOL          BOOL_FLAG

// 两个参数
#define BBA_WAX_METHOD_KIND_2_IDID          [NSString stringWithFormat:@"%@%@",ID_FLAG,ID_FLAG]
#define BBA_WAX_METHOD_KIND_2_INTINT        [NSString stringWithFormat:@"%@%@",INT_FLAG,INT_FLAG]
#define BBA_WAX_METHOD_KIND_2_BOOLBOOL      [NSString stringWithFormat:@"%@%@",INT_FLAG,INT_FLAG]
#define BBA_WAX_METHOD_KIND_2_IDINT         [NSString stringWithFormat:@"%@%@",ID_FLAG,INT_FLAG]
#define BBA_WAX_METHOD_KIND_2_IDFLOAT       [NSString stringWithFormat:@"%@%@",ID_FLAG,FLOAT_FLAG]
#define BBA_WAX_METHOD_KIND_2_FLOATFLOAT       [NSString stringWithFormat:@"%@%@",FLOAT_FLAG,FLOAT_FLAG]

// 三个参数
#define BBA_WAX_METHOD_KIND_3_IDIDID        [NSString stringWithFormat:@"%@%@%@",ID_FLAG,ID_FLAG,ID_FLAG]
#define BBA_WAX_METHOD_KIND_3_IDINTINT      [NSString stringWithFormat:@"%@%@%@",ID_FLAG,INT_FLAG,INT_FLAG]

// 四个参数
#define BBA_WAX_METHOD_KIND_4_IDIDIDID      [NSString stringWithFormat:@"%@%@%@%@",ID_FLAG,ID_FLAG,ID_FLAG,ID_FLAG]
#define BBA_WAX_METHOD_KIND_4_IDINTIDINT    [NSString stringWithFormat:@"%@%@%@%@",ID_FLAG,INT_FLAG,ID_FLAG,INT_FLAG]

// 5个参数
#define BBA_WAX_METHOD_KIND_5_IDIDIDIDID    [NSString stringWithFormat:@"%@%@%@%@%@",ID_FLAG,ID_FLAG,ID_FLAG,ID_FLAG,ID_FLAG]


// 无参数的路由函数
#define BBA_WAX_METHOD_NAME_P0_ID(_type_) bba_wax_##_type_##_call_P0_ID

#define BBA_WAX_METHOD_P0_ID(_type_) \
static _type_ BBA_WAX_METHOD_NAME_P0_ID(_type_)(id self, SEL _cmd) { \
NSMutableArray *paramsArray = [NSMutableArray array]; \
NSMutableArray *paramsTypeDescArray = [NSMutableArray array]; \
lua_State *L = wax_currentLuaState(); \
BEGIN_STACK_MODIFY(L); \
int result = bba_pcallUserdata(L, self, _cmd, paramsArray, paramsTypeDescArray); \
if (result == -1) { \
luaL_error(L, "Error calling '%s' on '%s'\n%s", _cmd, [[self description] UTF8String], lua_tostring(L, -1)); \
} \
else if (result == 0) { \
_type_ returnValue; \
bzero(&returnValue, sizeof(_type_)); \
END_STACK_MODIFY(L, 0) \
return returnValue; \
} \
\
NSMethodSignature *signature = [self methodSignatureForSelector:_cmd]; \
_type_ *pReturnValue = (_type_ *)wax_copyToObjc(L, [signature methodReturnType], -1, nil); \
_type_ returnValue = *pReturnValue; \
free(pReturnValue); \
END_STACK_MODIFY(L, 0) \
return returnValue; \
}

// 一个整型参数的路由函数
#define BBA_WAX_METHOD_NAME_P1_INT(_type_) bba_wax_##_type_##_call_P1_INT

#define BBA_WAX_METHOD_P1_INT(_type_) \
static _type_ BBA_WAX_METHOD_NAME_P1_INT(_type_)(id self, SEL _cmd, NSInteger p1) { \
NSMutableArray *paramsArray = [NSMutableArray array]; \
[paramsArray addObject:[NSNumber numberWithInteger:p1]]; \
NSMutableArray *paramsTypeDescArray = [NSMutableArray array]; \
[paramsTypeDescArray addObject:METHOD_PARAMTYPE_DESC_INT]; \
lua_State *L = wax_currentLuaState(); \
BEGIN_STACK_MODIFY(L); \
int result = bba_pcallUserdata(L, self, _cmd, paramsArray, paramsTypeDescArray); \
if (result == -1) { \
luaL_error(L, "Error calling '%s' on '%s'\n%s", _cmd, [[self description] UTF8String], lua_tostring(L, -1)); \
} \
else if (result == 0) { \
_type_ returnValue; \
bzero(&returnValue, sizeof(_type_)); \
END_STACK_MODIFY(L, 0) \
return returnValue; \
} \
\
NSMethodSignature *signature = [self methodSignatureForSelector:_cmd]; \
_type_ *pReturnValue = (_type_ *)wax_copyToObjc(L, [signature methodReturnType], -1, nil); \
_type_ returnValue = *pReturnValue; \
free(pReturnValue); \
END_STACK_MODIFY(L, 0) \
return returnValue; \
}

// 一个浮点参数的路由函数
#define BBA_WAX_METHOD_NAME_P1_FLOAT(_type_) bba_wax_##_type_##_call_P1_FLOAT

#define BBA_WAX_METHOD_P1_FLOAT(_type_) \
static _type_ BBA_WAX_METHOD_NAME_P1_FLOAT(_type_)(id self, SEL _cmd, CGFloat p1) { \
NSMutableArray *paramsArray = [NSMutableArray array]; \
[paramsArray addObject:[NSNumber numberWithDouble:p1]]; \
NSMutableArray *paramsTypeDescArray = [NSMutableArray array]; \
[paramsTypeDescArray addObject:METHOD_PARAMTYPE_DESC_FLOAT]; \
lua_State *L = wax_currentLuaState(); \
BEGIN_STACK_MODIFY(L); \
int result = bba_pcallUserdata(L, self, _cmd, paramsArray, paramsTypeDescArray); \
if (result == -1) { \
luaL_error(L, "Error calling '%s' on '%s'\n%s", _cmd, [[self description] UTF8String], lua_tostring(L, -1)); \
} \
else if (result == 0) { \
_type_ returnValue; \
bzero(&returnValue, sizeof(_type_)); \
END_STACK_MODIFY(L, 0) \
return returnValue; \
} \
\
NSMethodSignature *signature = [self methodSignatureForSelector:_cmd]; \
_type_ *pReturnValue = (_type_ *)wax_copyToObjc(L, [signature methodReturnType], -1, nil); \
_type_ returnValue = *pReturnValue; \
free(pReturnValue); \
END_STACK_MODIFY(L, 0) \
return returnValue; \
}

// 一个id参数的路由函数
#define BBA_WAX_METHOD_NAME_P1_ID(_type_) bba_wax_##_type_##_call_P1_ID

#define BBA_WAX_METHOD_P1_ID(_type_) \
static _type_ BBA_WAX_METHOD_NAME_P1_ID(_type_)(id self, SEL _cmd, id param1) { \
NSMutableArray *paramsArray = [NSMutableArray array]; \
if (param1==nil) \
{[paramsArray addObject:[NSNull null]];} \
else \
{[paramsArray addObject:param1];} \
NSMutableArray *paramsTypeDescArray = [NSMutableArray array]; \
[paramsTypeDescArray addObject:METHOD_PARAMTYPE_DESC_ID]; \
lua_State *L = wax_currentLuaState(); \
BEGIN_STACK_MODIFY(L); \
int result = bba_pcallUserdata(L, self, _cmd, paramsArray, paramsTypeDescArray); \
if (result == -1) { \
luaL_error(L, "Error calling '%s' on '%s'\n%s", _cmd, [[self description] UTF8String], lua_tostring(L, -1)); \
} \
else if (result == 0) { \
_type_ returnValue; \
bzero(&returnValue, sizeof(_type_)); \
END_STACK_MODIFY(L, 0) \
return returnValue; \
} \
\
NSMethodSignature *signature = [self methodSignatureForSelector:_cmd]; \
_type_ *pReturnValue = (_type_ *)wax_copyToObjc(L, [signature methodReturnType], -1, nil); \
_type_ returnValue = *pReturnValue; \
free(pReturnValue); \
END_STACK_MODIFY(L, 0) \
return returnValue; \
}

// 两个id参数的路由函数
#define BBA_WAX_METHOD_NAME_P2_IDID(_type_) bba_wax_##_type_##_call_P2_IDID

#define BBA_WAX_METHOD_P2_IDID(_type_) \
static _type_ BBA_WAX_METHOD_NAME_P2_IDID(_type_)(id self, SEL _cmd, id param1, id param2) { \
NSMutableArray *paramsArray = [NSMutableArray array]; \
if (param1==nil) \
{[paramsArray addObject:[NSNull null]];} \
else \
{[paramsArray addObject:param1];} \
if (param2==nil) \
{[paramsArray addObject:[NSNull null]];} \
else \
{[paramsArray addObject:param2];} \
NSMutableArray *paramsTypeDescArray = [NSMutableArray array]; \
[paramsTypeDescArray addObject:METHOD_PARAMTYPE_DESC_ID]; \
[paramsTypeDescArray addObject:METHOD_PARAMTYPE_DESC_ID]; \
lua_State *L = wax_currentLuaState(); \
BEGIN_STACK_MODIFY(L); \
int result = bba_pcallUserdata(L, self, _cmd, paramsArray, paramsTypeDescArray); \
if (result == -1) { \
luaL_error(L, "Error calling '%s' on '%s'\n%s", _cmd, [[self description] UTF8String], lua_tostring(L, -1)); \
} \
else if (result == 0) { \
_type_ returnValue; \
bzero(&returnValue, sizeof(_type_)); \
END_STACK_MODIFY(L, 0) \
return returnValue; \
} \
\
NSMethodSignature *signature = [self methodSignatureForSelector:_cmd]; \
_type_ *pReturnValue = (_type_ *)wax_copyToObjc(L, [signature methodReturnType], -1, nil); \
_type_ returnValue = *pReturnValue; \
free(pReturnValue); \
END_STACK_MODIFY(L, 0) \
return returnValue; \
}

// 两个NSInteger参数的路由函数
#define BBA_WAX_METHOD_NAME_P2_INTINT(_type_) bba_wax_##_type_##_call_P2_INTINT

#define BBA_WAX_METHOD_P2_INTINT(_type_) \
static _type_ BBA_WAX_METHOD_NAME_P2_INTINT(_type_)(id self, SEL _cmd, NSInteger param1, NSInteger param2) { \
NSMutableArray *paramsArray = [NSMutableArray array]; \
[paramsArray addObject:[NSNumber numberWithInteger:param1]];\
[paramsArray addObject:[NSNumber numberWithInteger:param2]];\
NSMutableArray *paramsTypeDescArray = [NSMutableArray array]; \
[paramsTypeDescArray addObject:METHOD_PARAMTYPE_DESC_INT]; \
[paramsTypeDescArray addObject:METHOD_PARAMTYPE_DESC_INT]; \
lua_State *L = wax_currentLuaState(); \
BEGIN_STACK_MODIFY(L); \
int result = bba_pcallUserdata(L, self, _cmd, paramsArray, paramsTypeDescArray); \
if (result == -1) { \
luaL_error(L, "Error calling '%s' on '%s'\n%s", _cmd, [[self description] UTF8String], lua_tostring(L, -1)); \
} \
else if (result == 0) { \
_type_ returnValue; \
bzero(&returnValue, sizeof(_type_)); \
END_STACK_MODIFY(L, 0) \
return returnValue; \
} \
\
NSMethodSignature *signature = [self methodSignatureForSelector:_cmd]; \
_type_ *pReturnValue = (_type_ *)wax_copyToObjc(L, [signature methodReturnType], -1, nil); \
_type_ returnValue = *pReturnValue; \
free(pReturnValue); \
END_STACK_MODIFY(L, 0) \
return returnValue; \
}

// 两个CGFloat参数的路由函数
#define BBA_WAX_METHOD_NAME_P2_FLOATFLOAT(_type_) bba_wax_##_type_##_call_P2_FLOATFLOAT

#define BBA_WAX_METHOD_P2_FLOATFLOAT(_type_) \
static _type_ BBA_WAX_METHOD_NAME_P2_FLOATFLOAT(_type_)(id self, SEL _cmd, CGFloat param1, CGFloat param2) { \
NSMutableArray *paramsArray = [NSMutableArray array]; \
[paramsArray addObject:[NSNumber numberWithDouble:param1]];\
[paramsArray addObject:[NSNumber numberWithDouble:param2]];\
NSMutableArray *paramsTypeDescArray = [NSMutableArray array]; \
[paramsTypeDescArray addObject:METHOD_PARAMTYPE_DESC_FLOAT]; \
[paramsTypeDescArray addObject:METHOD_PARAMTYPE_DESC_FLOAT]; \
lua_State *L = wax_currentLuaState(); \
BEGIN_STACK_MODIFY(L); \
int result = bba_pcallUserdata(L, self, _cmd, paramsArray, paramsTypeDescArray); \
if (result == -1) { \
luaL_error(L, "Error calling '%s' on '%s'\n%s", _cmd, [[self description] UTF8String], lua_tostring(L, -1)); \
} \
else if (result == 0) { \
_type_ returnValue; \
bzero(&returnValue, sizeof(_type_)); \
END_STACK_MODIFY(L, 0) \
return returnValue; \
} \
\
NSMethodSignature *signature = [self methodSignatureForSelector:_cmd]; \
_type_ *pReturnValue = (_type_ *)wax_copyToObjc(L, [signature methodReturnType], -1, nil); \
_type_ returnValue = *pReturnValue; \
free(pReturnValue); \
END_STACK_MODIFY(L, 0) \
return returnValue; \
}

// 两个参数(id INT)的路由函数
#define BBA_WAX_METHOD_NAME_P2_IDINT(_type_) bba_wax_##_type_##_call_P2_IDINT

#define BBA_WAX_METHOD_P2_IDINT(_type_) \
static _type_ BBA_WAX_METHOD_NAME_P2_IDINT(_type_)(id self, SEL _cmd, id param1, NSInteger param2) { \
NSMutableArray *paramsArray = [NSMutableArray array]; \
if (param1==nil) \
{[paramsArray addObject:[NSNull null]];} \
else \
{[paramsArray addObject:param1];} \
[paramsArray addObject:[NSNumber numberWithInteger:param2]];\
NSMutableArray *paramsTypeDescArray = [NSMutableArray array]; \
[paramsTypeDescArray addObject:METHOD_PARAMTYPE_DESC_ID]; \
[paramsTypeDescArray addObject:METHOD_PARAMTYPE_DESC_INT]; \
lua_State *L = wax_currentLuaState(); \
BEGIN_STACK_MODIFY(L); \
int result = bba_pcallUserdata(L, self, _cmd, paramsArray, paramsTypeDescArray); \
if (result == -1) { \
luaL_error(L, "Error calling '%s' on '%s'\n%s", _cmd, [[self description] UTF8String], lua_tostring(L, -1)); \
} \
else if (result == 0) { \
_type_ returnValue; \
bzero(&returnValue, sizeof(_type_)); \
END_STACK_MODIFY(L, 0) \
return returnValue; \
} \
\
NSMethodSignature *signature = [self methodSignatureForSelector:_cmd]; \
_type_ *pReturnValue = (_type_ *)wax_copyToObjc(L, [signature methodReturnType], -1, nil); \
_type_ returnValue = *pReturnValue; \
free(pReturnValue); \
END_STACK_MODIFY(L, 0) \
return returnValue; \
}

// 两个参数(id FLOAT)的路由函数
#define BBA_WAX_METHOD_NAME_P2_IDFLOAT(_type_) bba_wax_##_type_##_call_P2_IDFLOAT

#define BBA_WAX_METHOD_P2_IDFLOAT(_type_) \
static _type_ BBA_WAX_METHOD_NAME_P2_IDFLOAT(_type_)(id self, SEL _cmd, id param1, CGFloat param2) { \
NSMutableArray *paramsArray = [NSMutableArray array]; \
if (param1==nil) \
{[paramsArray addObject:[NSNull null]];} \
else \
{[paramsArray addObject:param1];} \
[paramsArray addObject:[NSNumber numberWithDouble:param2]];\
NSMutableArray *paramsTypeDescArray = [NSMutableArray array]; \
[paramsTypeDescArray addObject:METHOD_PARAMTYPE_DESC_ID]; \
[paramsTypeDescArray addObject:METHOD_PARAMTYPE_DESC_FLOAT]; \
lua_State *L = wax_currentLuaState(); \
BEGIN_STACK_MODIFY(L); \
int result = bba_pcallUserdata(L, self, _cmd, paramsArray, paramsTypeDescArray); \
if (result == -1) { \
luaL_error(L, "Error calling '%s' on '%s'\n%s", _cmd, [[self description] UTF8String], lua_tostring(L, -1)); \
} \
else if (result == 0) { \
_type_ returnValue; \
bzero(&returnValue, sizeof(_type_)); \
END_STACK_MODIFY(L, 0) \
return returnValue; \
} \
\
NSMethodSignature *signature = [self methodSignatureForSelector:_cmd]; \
_type_ *pReturnValue = (_type_ *)wax_copyToObjc(L, [signature methodReturnType], -1, nil); \
_type_ returnValue = *pReturnValue; \
free(pReturnValue); \
END_STACK_MODIFY(L, 0) \
return returnValue; \
}

// 三个id参数的路由函数
#define BBA_WAX_METHOD_NAME_P3_IDIDID(_type_) bba_wax_##_type_##_call_P3_IDIDID

#define BBA_WAX_METHOD_P3_IDIDID(_type_) \
static _type_ BBA_WAX_METHOD_NAME_P3_IDIDID(_type_)(id self, SEL _cmd, id param1, id param2, id param3) { \
NSMutableArray *paramsArray = [NSMutableArray array]; \
if (param1==nil) \
{[paramsArray addObject:[NSNull null]];} \
else \
{[paramsArray addObject:param1];} \
if (param2==nil) \
{[paramsArray addObject:[NSNull null]];} \
else \
{[paramsArray addObject:param2];} \
if (param3==nil) \
{[paramsArray addObject:[NSNull null]];} \
else \
{[paramsArray addObject:param3];} \
NSMutableArray *paramsTypeDescArray = [NSMutableArray array]; \
[paramsTypeDescArray addObject:METHOD_PARAMTYPE_DESC_ID]; \
[paramsTypeDescArray addObject:METHOD_PARAMTYPE_DESC_ID]; \
[paramsTypeDescArray addObject:METHOD_PARAMTYPE_DESC_ID]; \
lua_State *L = wax_currentLuaState(); \
BEGIN_STACK_MODIFY(L); \
int result = bba_pcallUserdata(L, self, _cmd, paramsArray, paramsTypeDescArray); \
if (result == -1) { \
luaL_error(L, "Error calling '%s' on '%s'\n%s", _cmd, [[self description] UTF8String], lua_tostring(L, -1)); \
} \
else if (result == 0) { \
_type_ returnValue; \
bzero(&returnValue, sizeof(_type_)); \
END_STACK_MODIFY(L, 0) \
return returnValue; \
} \
\
NSMethodSignature *signature = [self methodSignatureForSelector:_cmd]; \
_type_ *pReturnValue = (_type_ *)wax_copyToObjc(L, [signature methodReturnType], -1, nil); \
_type_ returnValue = *pReturnValue; \
free(pReturnValue); \
END_STACK_MODIFY(L, 0) \
return returnValue; \
}

// 三个参数(id INT INT)的路由函数
#define BBA_WAX_METHOD_NAME_P3_IDINTINT(_type_) bba_wax_##_type_##_call_P3_IDINTINT

#define BBA_WAX_METHOD_P3_IDINTINT(_type_) \
static _type_ BBA_WAX_METHOD_NAME_P3_IDINTINT(_type_)(id self, SEL _cmd, id param1, NSInteger param2, NSInteger param3) { \
NSMutableArray *paramsArray = [NSMutableArray array]; \
if (param1==nil) \
{[paramsArray addObject:[NSNull null]];} \
else \
{[paramsArray addObject:param1];} \
[paramsArray addObject:[NSNumber numberWithInteger:param2]];\
[paramsArray addObject:[NSNumber numberWithInteger:param3]];\
NSMutableArray *paramsTypeDescArray = [NSMutableArray array]; \
[paramsTypeDescArray addObject:METHOD_PARAMTYPE_DESC_ID]; \
[paramsTypeDescArray addObject:METHOD_PARAMTYPE_DESC_INT]; \
[paramsTypeDescArray addObject:METHOD_PARAMTYPE_DESC_INT]; \
lua_State *L = wax_currentLuaState(); \
BEGIN_STACK_MODIFY(L); \
int result = bba_pcallUserdata(L, self, _cmd, paramsArray, paramsTypeDescArray); \
if (result == -1) { \
luaL_error(L, "Error calling '%s' on '%s'\n%s", _cmd, [[self description] UTF8String], lua_tostring(L, -1)); \
} \
else if (result == 0) { \
_type_ returnValue; \
bzero(&returnValue, sizeof(_type_)); \
END_STACK_MODIFY(L, 0) \
return returnValue; \
} \
\
NSMethodSignature *signature = [self methodSignatureForSelector:_cmd]; \
_type_ *pReturnValue = (_type_ *)wax_copyToObjc(L, [signature methodReturnType], -1, nil); \
_type_ returnValue = *pReturnValue; \
free(pReturnValue); \
END_STACK_MODIFY(L, 0) \
return returnValue; \
}

// 四个参数的路由函数
#define BBA_WAX_METHOD_NAME_P4_IDIDIDID(_type_) bba_wax_##_type_##_call_P4_IDIDIDID

#define BBA_WAX_METHOD_P4_IDIDIDID(_type_) \
static _type_ BBA_WAX_METHOD_NAME_P4_IDIDIDID(_type_)(id self, SEL _cmd, id param1, id param2, id param3, id param4) { \
NSMutableArray *paramsArray = [NSMutableArray array]; \
if (param1==nil) \
{[paramsArray addObject:[NSNull null]];} \
else \
{[paramsArray addObject:param1];} \
if (param2==nil) \
{[paramsArray addObject:[NSNull null]];} \
else \
{[paramsArray addObject:param2];} \
if (param3==nil) \
{[paramsArray addObject:[NSNull null]];} \
else \
{[paramsArray addObject:param3];} \
if (param4==nil) \
{[paramsArray addObject:[NSNull null]];} \
else \
{[paramsArray addObject:param4];} \
NSMutableArray *paramsTypeDescArray = [NSMutableArray array]; \
[paramsTypeDescArray addObject:METHOD_PARAMTYPE_DESC_ID]; \
[paramsTypeDescArray addObject:METHOD_PARAMTYPE_DESC_ID]; \
[paramsTypeDescArray addObject:METHOD_PARAMTYPE_DESC_ID]; \
[paramsTypeDescArray addObject:METHOD_PARAMTYPE_DESC_ID]; \
lua_State *L = wax_currentLuaState(); \
BEGIN_STACK_MODIFY(L); \
int result = bba_pcallUserdata(L, self, _cmd, paramsArray, paramsTypeDescArray); \
if (result == -1) { \
luaL_error(L, "Error calling '%s' on '%s'\n%s", _cmd, [[self description] UTF8String], lua_tostring(L, -1)); \
} \
else if (result == 0) { \
_type_ returnValue; \
bzero(&returnValue, sizeof(_type_)); \
END_STACK_MODIFY(L, 0) \
return returnValue; \
} \
\
NSMethodSignature *signature = [self methodSignatureForSelector:_cmd]; \
_type_ *pReturnValue = (_type_ *)wax_copyToObjc(L, [signature methodReturnType], -1, nil); \
_type_ returnValue = *pReturnValue; \
free(pReturnValue); \
END_STACK_MODIFY(L, 0) \
return returnValue; \
}

// 四个参数的路由函数
#define BBA_WAX_METHOD_NAME_P4_IDINTIDINT(_type_) bba_wax_##_type_##_call_P4_IDINTIDINT

#define BBA_WAX_METHOD_P4_IDINTIDINT(_type_) \
static _type_ BBA_WAX_METHOD_NAME_P4_IDINTIDINT(_type_)(id self, SEL _cmd, id param1, NSInteger param2, id param3, NSInteger param4) { \
NSMutableArray *paramsArray = [NSMutableArray array]; \
if (param1==nil) \
{[paramsArray addObject:[NSNull null]];} \
else \
{[paramsArray addObject:param1];} \
[paramsArray addObject:[NSNumber numberWithInteger:param2]];\
if (param3==nil) \
{[paramsArray addObject:[NSNull null]];} \
else \
{[paramsArray addObject:param3];} \
[paramsArray addObject:[NSNumber numberWithInteger:param4]];\
NSMutableArray *paramsTypeDescArray = [NSMutableArray array]; \
[paramsTypeDescArray addObject:METHOD_PARAMTYPE_DESC_ID]; \
[paramsTypeDescArray addObject:METHOD_PARAMTYPE_DESC_INT]; \
[paramsTypeDescArray addObject:METHOD_PARAMTYPE_DESC_ID]; \
[paramsTypeDescArray addObject:METHOD_PARAMTYPE_DESC_INT]; \
lua_State *L = wax_currentLuaState(); \
BEGIN_STACK_MODIFY(L); \
int result = bba_pcallUserdata(L, self, _cmd, paramsArray, paramsTypeDescArray); \
if (result == -1) { \
luaL_error(L, "Error calling '%s' on '%s'\n%s", _cmd, [[self description] UTF8String], lua_tostring(L, -1)); \
} \
else if (result == 0) { \
_type_ returnValue; \
bzero(&returnValue, sizeof(_type_)); \
END_STACK_MODIFY(L, 0) \
return returnValue; \
} \
\
NSMethodSignature *signature = [self methodSignatureForSelector:_cmd]; \
_type_ *pReturnValue = (_type_ *)wax_copyToObjc(L, [signature methodReturnType], -1, nil); \
_type_ returnValue = *pReturnValue; \
free(pReturnValue); \
END_STACK_MODIFY(L, 0) \
return returnValue; \
}

// 五个参数的路由函数
#define BBA_WAX_METHOD_NAME_P5_IDIDIDIDID(_type_) bba_wax_##_type_##_call_P5_IDIDIDIDID

#define BBA_WAX_METHOD_P5_IDIDIDIDID(_type_) \
static _type_ BBA_WAX_METHOD_NAME_P5_IDIDIDIDID(_type_)(id self, SEL _cmd, id param1, id param2, id param3, id param4, id param5) { \
NSMutableArray *paramsArray = [NSMutableArray array]; \
if (param1==nil) \
{[paramsArray addObject:[NSNull null]];} \
else \
{[paramsArray addObject:param1];} \
if (param2==nil) \
{[paramsArray addObject:[NSNull null]];} \
else \
{[paramsArray addObject:param2];} \
if (param3==nil) \
{[paramsArray addObject:[NSNull null]];} \
else \
{[paramsArray addObject:param3];} \
if (param4==nil) \
{[paramsArray addObject:[NSNull null]];} \
else \
{[paramsArray addObject:param4];} \
if (param5==nil) \
{[paramsArray addObject:[NSNull null]];} \
else \
{[paramsArray addObject:param5];} \
NSMutableArray *paramsTypeDescArray = [NSMutableArray array]; \
[paramsTypeDescArray addObject:METHOD_PARAMTYPE_DESC_ID]; \
[paramsTypeDescArray addObject:METHOD_PARAMTYPE_DESC_ID]; \
[paramsTypeDescArray addObject:METHOD_PARAMTYPE_DESC_ID]; \
[paramsTypeDescArray addObject:METHOD_PARAMTYPE_DESC_ID]; \
[paramsTypeDescArray addObject:METHOD_PARAMTYPE_DESC_ID]; \
lua_State *L = wax_currentLuaState(); \
BEGIN_STACK_MODIFY(L); \
int result = bba_pcallUserdata(L, self, _cmd, paramsArray, paramsTypeDescArray); \
if (result == -1) { \
luaL_error(L, "Error calling '%s' on '%s'\n%s", _cmd, [[self description] UTF8String], lua_tostring(L, -1)); \
} \
else if (result == 0) { \
_type_ returnValue; \
bzero(&returnValue, sizeof(_type_)); \
END_STACK_MODIFY(L, 0) \
return returnValue; \
} \
\
NSMethodSignature *signature = [self methodSignatureForSelector:_cmd]; \
_type_ *pReturnValue = (_type_ *)wax_copyToObjc(L, [signature methodReturnType], -1, nil); \
_type_ returnValue = *pReturnValue; \
free(pReturnValue); \
END_STACK_MODIFY(L, 0) \
return returnValue; \
}


#define WAX_METHOD_NAME(_type_) wax_##_type_##_call

#define WAX_METHOD(_type_) \
static _type_ WAX_METHOD_NAME(_type_)(id self, SEL _cmd, ...){ \
va_list args; \
va_start(args, _cmd); \
va_list args_copy; \
va_copy(args_copy, args); \
/* Grab the static L... this is a hack */ \
lua_State *L = wax_currentLuaState(); \
BEGIN_STACK_MODIFY(L); \
int result = pcallUserdata(L, self, _cmd, args_copy); \
va_end(args_copy); \
va_end(args); \
if (result == -1) { \
    luaL_error(L, "Error calling '%s' on '%s'\n%s", _cmd, [[self description] UTF8String], lua_tostring(L, -1)); \
} \
else if (result == 0) { \
    _type_ returnValue; \
    bzero(&returnValue, sizeof(_type_)); \
    END_STACK_MODIFY(L, 0) \
    return returnValue; \
} \
\
NSMethodSignature *signature = [self methodSignatureForSelector:_cmd]; \
_type_ *pReturnValue = (_type_ *)wax_copyToObjc(L, [signature methodReturnType], -1, nil); \
_type_ returnValue = *pReturnValue; \
free(pReturnValue); \
END_STACK_MODIFY(L, 0) \
return returnValue; \
}

typedef struct _buffer_16 {char b[16];} buffer_16;

BBA_WAX_METHOD_P0_ID(id)
BBA_WAX_METHOD_P0_ID(int)
BBA_WAX_METHOD_P0_ID(long)
BBA_WAX_METHOD_P0_ID(float)
BBA_WAX_METHOD_P0_ID(BOOL)

BBA_WAX_METHOD_P1_INT(id)
BBA_WAX_METHOD_P1_INT(int)
BBA_WAX_METHOD_P1_INT(long)
BBA_WAX_METHOD_P1_INT(float)
BBA_WAX_METHOD_P1_INT(BOOL)

BBA_WAX_METHOD_P1_FLOAT(id)
BBA_WAX_METHOD_P1_FLOAT(int)
BBA_WAX_METHOD_P1_FLOAT(long)
BBA_WAX_METHOD_P1_FLOAT(float)
BBA_WAX_METHOD_P1_FLOAT(BOOL)

BBA_WAX_METHOD_P1_ID(id)
BBA_WAX_METHOD_P1_ID(int)
BBA_WAX_METHOD_P1_ID(long)
BBA_WAX_METHOD_P1_ID(float)
BBA_WAX_METHOD_P1_ID(BOOL)

BBA_WAX_METHOD_P2_IDID(id)
BBA_WAX_METHOD_P2_IDID(int)
BBA_WAX_METHOD_P2_IDID(long)
BBA_WAX_METHOD_P2_IDID(float)
BBA_WAX_METHOD_P2_IDID(BOOL)

BBA_WAX_METHOD_P2_INTINT(id)
BBA_WAX_METHOD_P2_INTINT(int)
BBA_WAX_METHOD_P2_INTINT(long)
BBA_WAX_METHOD_P2_INTINT(float)
BBA_WAX_METHOD_P2_INTINT(BOOL)

BBA_WAX_METHOD_P2_FLOATFLOAT(id)
BBA_WAX_METHOD_P2_FLOATFLOAT(int)
BBA_WAX_METHOD_P2_FLOATFLOAT(long)
BBA_WAX_METHOD_P2_FLOATFLOAT(float)
BBA_WAX_METHOD_P2_FLOATFLOAT(BOOL)

BBA_WAX_METHOD_P2_IDINT(id)
BBA_WAX_METHOD_P2_IDINT(int)
BBA_WAX_METHOD_P2_IDINT(long)
BBA_WAX_METHOD_P2_IDINT(float)
BBA_WAX_METHOD_P2_IDINT(BOOL)

BBA_WAX_METHOD_P2_IDFLOAT(id)
BBA_WAX_METHOD_P2_IDFLOAT(int)
BBA_WAX_METHOD_P2_IDFLOAT(long)
BBA_WAX_METHOD_P2_IDFLOAT(float)
BBA_WAX_METHOD_P2_IDFLOAT(BOOL)

BBA_WAX_METHOD_P3_IDIDID(id)
BBA_WAX_METHOD_P3_IDIDID(int)
BBA_WAX_METHOD_P3_IDIDID(long)
BBA_WAX_METHOD_P3_IDIDID(float)
BBA_WAX_METHOD_P3_IDIDID(BOOL)

BBA_WAX_METHOD_P3_IDINTINT(id)
BBA_WAX_METHOD_P3_IDINTINT(int)
BBA_WAX_METHOD_P3_IDINTINT(long)
BBA_WAX_METHOD_P3_IDINTINT(float)
BBA_WAX_METHOD_P3_IDINTINT(BOOL)

BBA_WAX_METHOD_P4_IDIDIDID(id)
BBA_WAX_METHOD_P4_IDIDIDID(int)
BBA_WAX_METHOD_P4_IDIDIDID(long)
BBA_WAX_METHOD_P4_IDIDIDID(float)
BBA_WAX_METHOD_P4_IDIDIDID(BOOL)

BBA_WAX_METHOD_P4_IDINTIDINT(id)
BBA_WAX_METHOD_P4_IDINTIDINT(int)
BBA_WAX_METHOD_P4_IDINTIDINT(long)
BBA_WAX_METHOD_P4_IDINTIDINT(float)
BBA_WAX_METHOD_P4_IDINTIDINT(BOOL)

BBA_WAX_METHOD_P5_IDIDIDIDID(id)
BBA_WAX_METHOD_P5_IDIDIDIDID(int)
BBA_WAX_METHOD_P5_IDIDIDIDID(long)
BBA_WAX_METHOD_P5_IDIDIDIDID(float)
BBA_WAX_METHOD_P5_IDIDIDIDID(BOOL)


// Only allow classes to do this
static BOOL overrideMethod(lua_State *L, wax_instance_userdata *instanceUserdata) {
    BEGIN_STACK_MODIFY(L);
    BOOL success = NO;
    const char *methodName = lua_tostring(L, 2);

    SEL foundSelectors[2] = {nil, nil};
    
    NSString *paramType = nil; // 参数的类型列表，类似于 112 .etc
    wax_selectorForInstance(instanceUserdata, foundSelectors, methodName, YES, &paramType);
    if (paramType == nil)
    {
        END_STACK_MODIFY(L, 1);
        return NO;
    }
    
    SEL selector = foundSelectors[0];
    if (foundSelectors[1]) {
        //NSLog(@"Found two selectors that match %s. Defaulting to %s over %s", methodName, foundSelectors[0], foundSelectors[1]);
    }
    
    // 获取当前正在加载的模块（插件）的ID
    char *moduleIDTmp = wax_currentmoduleid();
    const char *moduleID = NULL;
    if (moduleIDTmp && strlen(moduleIDTmp) > 0)
    {
        NSString *moduleIDStr = [NSString stringWithCString:moduleIDTmp encoding:NSUTF8StringEncoding];
        moduleIDStr = [moduleIDStr stringByReplacingOccurrencesOfString:@"." withString:@""];
        free(moduleIDTmp);
        moduleID = [moduleIDStr cStringUsingEncoding:NSUTF8StringEncoding];
    }
    
    Class klass = [instanceUserdata->instance class];
    
    char *typeDescription = nil;
    char *returnType = nil;
    
    Method method = class_getInstanceMethod(klass, selector);
        
    if (method) { // Is method defined in the superclass?
        typeDescription = (char *)method_getTypeEncoding(method);        
        returnType = method_copyReturnType(method);
    }
    else { // Is this method implementing a protocol?
        Class currentClass = klass;
        
        while (!returnType && [currentClass superclass] != [currentClass class]) { // Walk up the object heirarchy
            uint count;
            Protocol **protocols = class_copyProtocolList(currentClass, &count);
                        
            SEL possibleSelectors[2];
            wax_selectorsForName(methodName, possibleSelectors);
            
            for (int i = 0; !returnType && i < count; i++) {
                Protocol *protocol = protocols[i];
                struct objc_method_description m_description;
                
                for (int j = 0; !returnType && j < 2; j++) {
                    selector = possibleSelectors[j];
                    if (!selector) continue; // There may be only one acceptable selector sent back
                    
                    m_description = protocol_getMethodDescription(protocol, selector, YES, YES);
                    if (!m_description.name) m_description = protocol_getMethodDescription(protocol, selector, NO, YES); // Check if it is not a "required" method
                    
                    if (m_description.name) {
                        typeDescription = m_description.types;
                        returnType = method_copyReturnType((Method)&m_description);
                    }
                }
            }
            
            free(protocols);
            
            currentClass = [currentClass superclass];
        }
    }
    
    if (returnType) { // Matching method found! Create an Obj-C method on the 
        if (!instanceUserdata->isClass) {
            luaL_error(L, "Trying to override method '%s' on an instance. You can only override classes", methodName);
        }            
        
        int argCount = 0;
        char *match = (char *)sel_getName(selector);
        while ((match = strchr(match, ':'))) {
            match += 1; // Skip past the matched char
            argCount++;
        }
        
        const char *simplifiedReturnType = wax_removeProtocolEncodings(returnType);
        IMP imp = nil;
        switch (simplifiedReturnType[0]) {
            case WAX_TYPE_VOID:
            case WAX_TYPE_ID:
            {
                if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_VOID])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P0_ID(id);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_1_INT])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P1_INT(id);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_1_ID])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P1_ID(id);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_1_FLOAT])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P1_FLOAT(id);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_1_BOOL])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P1_INT(id);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_2_IDID])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P2_IDID(id);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_2_INTINT])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P2_INTINT(id);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_2_FLOATFLOAT])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P2_FLOATFLOAT(id);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_2_BOOLBOOL])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P2_INTINT(id);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_2_IDINT])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P2_IDINT(id);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_2_IDFLOAT])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P2_IDFLOAT(id);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_3_IDIDID])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P3_IDIDID(id);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_3_IDINTINT])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P3_IDINTINT(id);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_4_IDIDIDID])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P4_IDIDIDID(id);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_4_IDINTIDINT])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P4_IDINTIDINT(id);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_5_IDIDIDIDID])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P5_IDIDIDIDID(id);
                }
                else
                {
                    imp = nil;
                }
                break;
            }
            case WAX_TYPE_CHAR:
            case WAX_TYPE_INT:
            case WAX_TYPE_SHORT:
            case WAX_TYPE_UNSIGNED_CHAR:
            case WAX_TYPE_UNSIGNED_INT:
            case WAX_TYPE_UNSIGNED_SHORT:
            {
                if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_VOID])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P0_ID(int);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_1_INT])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P1_INT(int);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_1_ID])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P1_ID(int);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_1_FLOAT])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P1_FLOAT(int);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_1_BOOL])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P1_INT(int);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_2_IDID])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P2_IDID(int);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_2_INTINT])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P2_INTINT(int);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_2_FLOATFLOAT])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P2_FLOATFLOAT(int);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_2_BOOLBOOL])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P2_INTINT(int);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_2_IDINT])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P2_IDINT(int);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_2_IDFLOAT])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P2_IDFLOAT(int);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_3_IDIDID])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P3_IDIDID(int);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_3_IDINTINT])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P3_IDINTINT(int);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_4_IDIDIDID])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P4_IDIDIDID(int);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_4_IDINTIDINT])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P4_IDINTIDINT(int);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_5_IDIDIDIDID])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P5_IDIDIDIDID(int);
                }
                else
                {
                    imp = nil;
                }
                break;
            }
            case WAX_TYPE_LONG:
            case WAX_TYPE_LONG_LONG:
            case WAX_TYPE_UNSIGNED_LONG:
            case WAX_TYPE_UNSIGNED_LONG_LONG:
            {
                if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_VOID])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P0_ID(long);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_1_INT])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P1_INT(long);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_1_ID])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P1_ID(long);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_1_FLOAT])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P1_FLOAT(long);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_1_BOOL])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P1_INT(long);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_2_IDID])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P2_IDID(long);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_2_INTINT])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P2_INTINT(long);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_2_FLOATFLOAT])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P2_FLOATFLOAT(long);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_2_BOOLBOOL])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P2_INTINT(long);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_2_IDINT])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P2_IDINT(long);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_2_IDFLOAT])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P2_IDFLOAT(long);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_3_IDIDID])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P3_IDIDID(long);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_3_IDINTINT])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P3_IDINTINT(long);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_4_IDIDIDID])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P4_IDIDIDID(long);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_4_IDINTIDINT])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P4_IDINTIDINT(long);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_5_IDIDIDIDID])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P5_IDIDIDIDID(long);
                }
                else
                {
                    imp = nil;
                }
                break;
            }
                
            case WAX_TYPE_FLOAT:
            {
                if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_VOID])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P0_ID(float);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_1_INT])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P1_INT(float);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_1_ID])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P1_ID(float);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_1_FLOAT])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P1_FLOAT(float);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_1_BOOL])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P1_INT(float);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_2_IDID])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P2_IDID(float);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_2_INTINT])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P2_INTINT(float);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_2_FLOATFLOAT])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P2_FLOATFLOAT(float);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_2_BOOLBOOL])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P2_INTINT(float);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_2_IDINT])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P2_IDINT(float);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_2_IDFLOAT])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P2_IDFLOAT(float);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_3_IDIDID])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P3_IDIDID(float);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_3_IDINTINT])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P3_IDINTINT(float);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_4_IDIDIDID])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P4_IDIDIDID(float);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_4_IDINTIDINT])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P4_IDINTIDINT(float);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_5_IDIDIDIDID])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P5_IDIDIDIDID(float);
                }
                else
                {
                    imp = nil;
                }
                break;
            }
                
            case WAX_TYPE_C99_BOOL:
            {
                if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_VOID])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P0_ID(BOOL);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_1_INT])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P1_INT(BOOL);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_1_ID])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P1_ID(BOOL);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_1_FLOAT])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P1_FLOAT(BOOL);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_1_BOOL])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P1_INT(BOOL);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_2_IDID])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P2_IDID(BOOL);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_2_INTINT])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P2_INTINT(BOOL);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_2_FLOATFLOAT])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P2_FLOATFLOAT(BOOL);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_2_BOOLBOOL])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P2_INTINT(BOOL);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_2_IDINT])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P2_IDINT(BOOL);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_2_IDFLOAT])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P2_IDFLOAT(BOOL);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_3_IDIDID])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P3_IDIDID(BOOL);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_3_IDINTINT])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P3_IDINTINT(BOOL);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_4_IDIDIDID])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P4_IDIDIDID(BOOL);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_4_IDINTIDINT])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P4_IDINTIDINT(BOOL);
                }
                else if ([paramType isEqualToString:BBA_WAX_METHOD_KIND_5_IDIDIDIDID])
                {
                    imp = (IMP)BBA_WAX_METHOD_NAME_P5_IDIDIDIDID(BOOL);
                }
                else
                {
                    imp = nil;
                }
                break;
            }
                
//          case WAX_TYPE_STRUCT:
//          {
//                int size = wax_sizeOfTypeDescription(simplifiedReturnType);
//                switch (size) {
//                    case 16:
//                        imp = (IMP)WAX_METHOD_NAME(buffer_16);
//                        break;
//                    default:
//                        luaL_error(L, "Trying to override a method that has a struct return type of size '%d'. There is no implementation for this size yet.", size);
//                        return NO;
//                        break;
//                }
//                break;
//          }
            default:
                luaL_error(L, "Can't override method with return type %s", simplifiedReturnType);
                return NO;
                break;
        }
		
		id metaclass = objc_getMetaClass(object_getClassName(klass));
        IMP instImp = class_respondsToSelector(klass, selector) ? class_getMethodImplementation(klass, selector) : NULL;
        IMP metaImp = class_respondsToSelector(metaclass, selector) ? class_getMethodImplementation(metaclass, selector) : NULL;
        if(instImp) {
            
            replaceMethodIMP(klass, selector, imp, typeDescription, moduleID);
            
            recordPluginActions(moduleID, object_getClassName(klass));
            
            success = YES;
        } else if(metaImp) {
            
            replaceMethodIMP(metaclass, selector, imp, typeDescription, moduleID);
            
            recordPluginActions(moduleID, object_getClassName(metaclass));
            
            success = YES;
        } else {
            // add to both instance and class method
            success = class_addMethod(klass, selector, imp, typeDescription) && class_addMethod(metaclass, selector, imp, typeDescription);
        }
        
        if (returnType) free(returnType);
    }
    else {
		SEL possibleSelectors[2];
        wax_selectorsForName(methodName, possibleSelectors);
		
		success = YES;
		for (int i = 0; i < 2; i++) {
			selector = possibleSelectors[i];
            if (!selector) continue; // There may be only one acceptable selector sent back
            
			int argCount = 0;
			char *match = (char *)sel_getName(selector);
			while ((match = strchr(match, ':'))) {
				match += 1; // Skip past the matched char
				argCount++;
			}
            
			size_t typeDescriptionSize = 3 + argCount;
			typeDescription = calloc(typeDescriptionSize + 1, sizeof(char));
			memset(typeDescription, '@', typeDescriptionSize);
			typeDescription[2] = ':'; // Never forget _cmd!
			
            IMP imp = nil;
            switch (argCount) {
                case 0:
                    imp = (IMP)BBA_WAX_METHOD_NAME_P0_ID(id);
                    break;
                case 1:
                    imp = (IMP)BBA_WAX_METHOD_NAME_P1_ID(id);
                    break;
                case 2:
                    imp = (IMP)BBA_WAX_METHOD_NAME_P2_IDID(id);
                    break;
                case 3:
                    imp = (IMP)BBA_WAX_METHOD_NAME_P3_IDIDID(id);
                    break;
                case 4:
                    imp = (IMP)BBA_WAX_METHOD_NAME_P4_IDIDIDID(id);
                    break;
                case 5:
                    imp = (IMP)BBA_WAX_METHOD_NAME_P5_IDIDIDIDID(id);
                    break;
                default:
                    break;
            }
            
			id metaclass = objc_getMetaClass(object_getClassName(klass));
            
            IMP instImp = class_respondsToSelector(klass, selector) ? class_getMethodImplementation(klass, selector) : NULL;
            IMP metaImp = class_respondsToSelector(metaclass, selector) ? class_getMethodImplementation(metaclass, selector) : NULL;
            if(instImp) {
                
                replaceMethodIMP(klass, selector, imp, typeDescription, moduleID);
                
                recordPluginActions(moduleID, object_getClassName(klass));
                
                success = YES;
            } else if(metaImp) {
                
                replaceMethodIMP(metaclass, selector, imp, typeDescription, moduleID);
                
                recordPluginActions(moduleID, object_getClassName(metaclass));
                
                success = YES;
            } else {
                // add to both instance and class method
                success = class_addMethod(klass, selector, imp, typeDescription) && class_addMethod(metaclass, selector, imp, typeDescription);
            }
			
			free(typeDescription);
		}
    }
    
    END_STACK_MODIFY(L, 1)
    return success;
}

bool replaceMethodIMP(Class className, SEL selector, IMP newimp, const char *typeDesc, const char *moduleID)
{
    if (newimp == nil || className == nil) return false;
    
    Method origMethod = class_getInstanceMethod(className, selector);
    IMP prevImp = method_getImplementation(origMethod);
    class_replaceMethod(className, selector, newimp, typeDesc);
    
    const char *selectorName = sel_getName(selector);
    size_t size = strlen(selectorName) + 10;
    if (moduleID && strlen(moduleID) > 0)
    {
        size += strlen(moduleID);
    }
    
    char newSelectorName[size];
    strcpy(newSelectorName, METHODE_SWIZZLING_ORIG_TAG);
    if (moduleID && strlen(moduleID) > 0)
    {
        strcat(newSelectorName, moduleID);
    }
    strcat(newSelectorName, selectorName);
    SEL newSelector = sel_getUid(newSelectorName);
    
    // 如果备份函数不存在，则添加新的备份函数并指向原始IMP
    if(!class_respondsToSelector(className, newSelector)) {
        return class_addMethod(className, newSelector, prevImp, typeDesc);
    }
    else // 如果备份函数存在，则直接替换IMP
    {
        return class_replaceMethod(className, newSelector, prevImp, typeDesc);
    }
}

bool recordPluginActions(const char *pluginID, const char *className)
{
    if (!pluginID || !className || strlen(pluginID) == 0 || strlen(className) == 0 ) return false;
    
    if (pluginActionRecord == nil)
    {
        pluginActionRecord = [[NSMutableDictionary dictionary] retain];
    }
    
    NSString *classNameStr = [NSString stringWithCString:className encoding:NSUTF8StringEncoding];
    NSString *pluginIDStr = [NSString stringWithCString:pluginID encoding:NSUTF8StringEncoding];
    
    
    NSMutableDictionary *classDict = [pluginActionRecord objectForKey:pluginIDStr];
    if (classDict == nil || ![classDict isKindOfClass:[NSMutableDictionary class]])
    {
        classDict = [NSMutableDictionary dictionary];
    }
    [classDict setValue:classNameStr forKey:classNameStr];
    [pluginActionRecord setObject:classDict forKey:pluginIDStr];
    
    return true;
}

bool wax_instance_unloadmodule(const char *moduleID)
{
    if (!moduleID || strlen(moduleID) == 0) return false;
    
    NSString *moduleIDStr = [[NSString stringWithCString:moduleID encoding:NSUTF8StringEncoding] stringByReplacingOccurrencesOfString:@"." withString:@""];
    const char *pmoduleID = [moduleIDStr cStringUsingEncoding:NSUTF8StringEncoding];
    
    NSDictionary *classDict = [pluginActionRecord objectForKey:moduleIDStr];
    for (NSString *className in [classDict allKeys])
    {
        const char *pclassName = [className cStringUsingEncoding:NSUTF8StringEncoding];
        Class class = objc_getClass(pclassName);
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(class, &methodCount);
        for (int i = 0; i < methodCount; i++)
        {
            Method method = methods[i];
            const char *methodName = sel_getName(method_getName(method));
            
            if (strstr(methodName, pmoduleID))
            {
                const char *origMethodName = methodName + strlen(pmoduleID) + strlen(METHODE_SWIZZLING_ORIG_TAG);
                
                Method origMethod = class_getInstanceMethod(class, sel_getUid(origMethodName));
                IMP imp1 = method_getImplementation(method);
                IMP imp2 = method_getImplementation(origMethod);
                method_setImplementation(method, imp2);
                method_setImplementation(origMethod, imp1);
            }
        }
    }
    [pluginActionRecord removeObjectForKey:moduleIDStr];
    return true;
}
