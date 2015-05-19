//
//  ObjLua.m
//  Lua
//
//  Created by ProbablyInteractive on 5/27/09.
//  Copyright 2009 Probably Interactive. All rights reserved.
//

#import "ProtocolLoader.h"

#import "wax.h"
#import "wax_class.h"
#import "wax_instance.h"
#import "wax_struct.h"
#import "wax_helpers.h"
#import "wax_gc.h"
#import "wax_stdlib32.h"
#import "wax_stdlib64.h"
#import "wax_filesystem.h"
#import "lauxlib.h"
#import "lobject.h"
#import "lualib.h"
#import "wax_utility.h"
#import <sys/sysctl.h>

static void addGlobals(lua_State *L);
static int waxRoot(lua_State *L);
static int waxPrint(lua_State *L);
static int tolua(lua_State *L);
static int toobjc(lua_State *L);
static int exitApp(lua_State *L);

static lua_State *currentL;
static bool wax_initstatus;

static dispatch_semaphore_t syncWaxLoad;
static dispatch_semaphore_t syncWaxUnLoad;
static dispatch_semaphore_t syncExec;

static int isProc64 = -1; // -1:未定义 1:64位进程 0:32位进程

lua_State *wax_currentLuaState() {
    
    if (!currentL) 
        currentL = lua_open();
    
    return currentL;
}

void uncaughtExceptionHandler(NSException *e) {
    NSLog(@"ERROR: Uncaught exception %@", [e description]);
    lua_State *L = wax_currentLuaState();
    
    if (L) {
        wax_getStackTrace(L);
        const char *stackTrace = luaL_checkstring(L, -1);
        NSLog(@"%s", stackTrace);
        lua_pop(L, -1); // remove the stackTrace
    }
}

int wax_panic(lua_State *L) {
	printf("Lua panicked and quit: %s\n", luaL_checkstring(L, -1));
	exit(EXIT_FAILURE);
}

lua_CFunction lua_atpanic (lua_State *L, lua_CFunction panicf);

void wax_setup() {
	NSSetUncaughtExceptionHandler(&uncaughtExceptionHandler); 
	
    NSFileManager *fileManager = [NSFileManager defaultManager];
    [fileManager changeCurrentDirectoryPath:[[NSBundle mainBundle] bundlePath]];
    
    lua_State *L = wax_currentLuaState();
	lua_atpanic(L, &wax_panic);
    
    luaL_openlibs(L); 

	luaopen_wax_class(L);
    luaopen_wax_instance(L);
    luaopen_wax_struct(L);
	
    addGlobals(L);
	
    dispatch_async(dispatch_get_main_queue(), ^{
        [wax_gc start];
    });
}

bool wax_isproc64()
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        pid_t pid = [[NSProcessInfo processInfo] processIdentifier];
        struct kinfo_proc proc = {NULL};
        size_t bufsize      = 0;
        size_t orig_bufsize = 0;
        int    local_error  = 0;
        int    mib[4]       = { CTL_KERN, KERN_PROC, KERN_PROC_PID, 0 };
        
        mib[3] = pid;
        orig_bufsize = bufsize = sizeof(struct kinfo_proc);
        local_error = 0;
        int retry_count = 0;
        bufsize = orig_bufsize;
        for (retry_count = 0; ; retry_count++)
        {
            if ((local_error = sysctl(mib, 4, &proc, &bufsize, NULL, 0)) < 0)
            {
                if (retry_count <= 11)
                {
                    sleep(1);
                    continue;
                }
                isProc64 = -1;
            }
            else if (local_error == 0)
            {
                isProc64 = ((proc.kp_proc.p_flag & P_LP64) > 0)?1:0;
                break;
            }
        }
    });
    return isProc64 == 1;
}

void wax_init()
{
    wax_isproc64();
    
    [wax_utility sharedInstance];
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        syncWaxLoad = dispatch_semaphore_create(1);
        syncWaxUnLoad = dispatch_semaphore_create(1);
        syncExec = dispatch_semaphore_create(1);
        
        wax_setup();
        
        lua_State *L = wax_currentLuaState();
        
        // Load extentions
        // ---------------
        luaopen_wax_filesystem(L);
        
        // Load stdlib
        char stdlib[] = WAX_STDLIB32;
        size_t stdlibSize = sizeof(stdlib);
        
        if (luaL_loadbuffer(L, stdlib, stdlibSize, "loading wax stdlib") || lua_pcall(L, 0, LUA_MULTRET, 0)) {
            char stdlib64[] = WAX_STDLIB64;
            size_t stdlibSize64 = sizeof(stdlib64);
            if (luaL_loadbuffer(L, stdlib64, stdlibSize64, "loading wax stdlib") || lua_pcall(L, 0, LUA_MULTRET, 0)) {
                wax_initstatus = false;
            }
            else
            {
                if (isProc64 == -1)
                {
                    isProc64 = 1;
                }
            }
        }
        else
        {
            if (isProc64 == -1)
            {
                isProc64 = 0;
            }
        }
        wax_initstatus = true;
    });
}

void beginLuaExec()
{
    //dispatch_wait(syncExec, DISPATCH_TIME_FOREVER);
}

void endLuaExec()
{
    //dispatch_semaphore_signal(syncExec);
}

bool wax_initsuccess()
{
    wax_init();
    return wax_initstatus;
}

bool wax_loadmobule(const char *pbuff, size_t size, const char *moduleID)
{
    wax_init();
    
    dispatch_wait(syncWaxLoad, DISPATCH_TIME_FOREVER);
    lua_State *L = wax_currentLuaState();
    bool status = true;
    if (luaL_loadbuffer(L, pbuff, size, "loading extern script") || lua_pcall(L, 0, LUA_MULTRET, 0)) {
        status = false;
    }
    dispatch_semaphore_signal(syncWaxLoad);
    return status;
}

bool wax_unloadmodule(const char *moduleID)
{
    dispatch_wait(syncWaxUnLoad, DISPATCH_TIME_FOREVER);
    
    bool res = wax_instance_unloadmodule(moduleID);
    
    dispatch_semaphore_signal(syncWaxUnLoad);
    
    return res;
}

bool wax_runfile(char* initScript)
{
    wax_init();
    
    dispatch_wait(syncWaxLoad, DISPATCH_TIME_FOREVER);
    bool status = true;
    char appLoadString[512];
    snprintf(appLoadString, sizeof(appLoadString), "local f = '%s' require(f:gsub('%%.[^.]*$', ''))", initScript); // Strip the extension off the file.
    if (luaL_dostring(wax_currentLuaState(), appLoadString) != 0) {
        status = false;
    }
    dispatch_semaphore_signal(syncWaxLoad);
    return status;
}

char *wax_currentmoduleid()
{
    BEGIN_STACK_MODIFY(wax_currentLuaState());
    
    lua_getglobal(wax_currentLuaState(), "moduleid");
    const char *value = lua_tostring(wax_currentLuaState(), -1);
    char *pluginID = NULL;
    if (value != NULL)
    {
        pluginID = strdup(value);
    }
    END_STACK_MODIFY(wax_currentLuaState(), 0);
    return pluginID;
}

//void wax_startWithServer() {		
//	wax_setup();
//	[wax_server class]; // You need to load the class somehow via the wax.framework
//	lua_State *L = wax_currentLuaState();
//	
//	// Load all the wax lua scripts
//    if (luaL_dofile(L, WAX_SCRIPTS_DIR "/scripts/wax/init.lua") != 0) {
//        fprintf(stderr,"Fatal error opening wax scripts: %s\n", lua_tostring(L,-1));
//    }
//	
//	Class WaxServer = objc_getClass("WaxServer");
//	if (!WaxServer) [NSException raise:@"Wax Server Error" format:@"Could load Wax Server"];
//	
//	[WaxServer start];
//}
//
//void wax_end() {
//    [wax_gc stop];
//    lua_close(wax_currentLuaState());
//    currentL = 0;
//}

static void addGlobals(lua_State *L) {
    lua_getglobal(L, "wax");
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1); // Get rid of the nil
        lua_newtable(L);
        lua_pushvalue(L, -1);
        lua_setglobal(L, "wax");
    }
    
    lua_pushnumber(L, WAX_VERSION);
    lua_setfield(L, -2, "version");
    
    lua_pushstring(L, [[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] UTF8String]);
    lua_setfield(L, -2, "appVersion");
    
    lua_pushcfunction(L, waxRoot);
    lua_setfield(L, -2, "root");

    lua_pushcfunction(L, waxPrint);
    lua_setfield(L, -2, "print");    
    
#ifdef DEBUG
    lua_pushboolean(L, YES);
    lua_setfield(L, -2, "isDebug");
#endif
    
    lua_pop(L, 1); // pop the wax global off
    

    lua_pushcfunction(L, tolua);
    lua_setglobal(L, "tolua");
    
    lua_pushcfunction(L, toobjc);
    lua_setglobal(L, "toobjc");
    
    lua_pushcfunction(L, exitApp);
    lua_setglobal(L, "exitApp");
    
    lua_pushstring(L, [[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0] UTF8String]);
    lua_setglobal(L, "NSDocumentDirectory");
    
    lua_pushstring(L, [[NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) objectAtIndex:0] UTF8String]);
    lua_setglobal(L, "NSLibraryDirectory");
    
    NSString *cachePath = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) objectAtIndex:0];
    lua_pushstring(L, [cachePath UTF8String]);
    lua_setglobal(L, "NSCacheDirectory");

    NSError *error = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:cachePath withIntermediateDirectories:YES attributes: nil error:&error];
    if (error) {
        wax_log(LOG_DEBUG, @"Error creating cache path. %@", [error localizedDescription]);
    }
}

static int waxPrint(lua_State *L) {
    NSLog(@"%s", luaL_checkstring(L, 1));
    return 0;
}

static int waxRoot(lua_State *L) {
    luaL_Buffer b;
    luaL_buffinit(L, &b);
    luaL_addstring(&b, WAX_SCRIPTS_DIR);
    
    for (int i = 1; i <= lua_gettop(L); i++) {
        luaL_addstring(&b, "/");
        luaL_addstring(&b, luaL_checkstring(L, i));
    }

    luaL_pushresult(&b);
                       
    return 1;
}

static int tolua(lua_State *L) {
    if (lua_isuserdata(L, 1)) { // If it's not userdata... it's already lua!
        wax_instance_userdata *instanceUserdata = (wax_instance_userdata *)luaL_checkudata(L, 1, WAX_INSTANCE_METATABLE_NAME);
        wax_fromInstance(L, instanceUserdata->instance);
    }
    
    return 1;
}

static int toobjc(lua_State *L) {
    id *instancePointer = wax_copyToObjc(L, "@", 1, nil);
    id instance = *(id *)instancePointer;
    
    wax_instance_create(L, instance, NO);
    
    if (instancePointer) free(instancePointer);
    
    return 1;
}

static int exitApp(lua_State *L) {
    exit(0);
    return 0;
}