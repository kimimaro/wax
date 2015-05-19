//  Created by ProbablyInteractive.
//  Copyright 2009 Probably Interactive. All rights reserved.

#import <Foundation/Foundation.h>
#import "lua.h"

#define WAX_VERSION 0.93

/**
 *  加载插件文件，文件的寻址规则遵循Lua脚本的require指令
 *
 *  @param scriptfile 脚本文件
 */
bool wax_runfile(char* scriptfile);

/**
 *  加载二进制模块
 *
 *  @param buff 模块缓存数据
 *  @param size 模块数据大小
*   @param moduleID 模块标识
 */
bool wax_loadmobule(const char *pbuff, size_t size, const char *moduleID);

/**
 *  卸载指定标识的模块
 *
 *  @param moduleID 模块标识
 *
 *  @return true:成功 false:失败
 */
bool wax_unloadmodule(const char *moduleID);

/**
 *  获取当前Lua的上下文环境
 *
 *  @return 当前上下文环境
 */
lua_State *wax_currentLuaState();

/**
 *  获取当前wax初始化状态
 */
bool wax_initsuccess();

/**
 *  获取当前插件ID
 *
 *  @return PluginID 
 */
char *wax_currentmoduleid();

/**
 *  当前进程是否为64位进程
 *
 *  @return bool YES:64 No:32
 */
bool wax_isproc64();

/**
 *  开启Lua执行保护锁
 */
void beginLuaExec();

/**
 *  释放Lua执行保护锁
 */
void endLuaExec();
