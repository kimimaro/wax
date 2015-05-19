//
//  wax_helpers.h
//  Lua
//
//  Created by ProbablyInteractive on 5/18/09.
//  Copyright 2009 Probably Interactive. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "wax_instance.h"
#import "lua.h"

// 目前支持传递的参数类型, lua脚本中出现的OC函数名称必需指定每个参数的类型，否则会导致调用失败
// 如需传递CGRect，CGPoint等结构体，请参考CGRectObj等类进行转换
#define METHOD_PARAMTYPE_DESC_VOID          @"VOID"  // 代表函数无参数
#define VOID_FLAG     @"0"
#define METHOD_PARAMTYPE_DESC_ID            @"IID"   // 参数类型为id,之所以使用IID是为了防止与类似(xxxxPluginID:xx)函数名发生冲突
#define ID_FLAG       @"1"
#define METHOD_PARAMTYPE_DESC_INT           @"INT"   // 代表整形，在传递给Lua时会自动提升为long
#define INT_FLAG      @"2"
#define METHOD_PARAMTYPE_DESC_FLOAT         @"FLOAT" // 代表浮点型，在传递给Lua时会自动提升为double
#define FLOAT_FLAG    @"3"
#define METHOD_PARAMTYPE_DESC_BOOL          @"BOOL"  // 与INT相同
#define BOOL_FLAG     @"4"

//#define _C_ATOM     '%'
//#define _C_VECTOR   '!'
//#define _C_CONST    'r'

// ENCODINGS CAN BE FOUND AT http://developer.apple.com/documentation/Cocoa/Conceptual/ObjCRuntimeGuide/Articles/ocrtTypeEncodings.html
#define WAX_TYPE_CHAR _C_CHR
#define WAX_TYPE_INT _C_INT
#define WAX_TYPE_SHORT _C_SHT
#define WAX_TYPE_UNSIGNED_CHAR _C_UCHR
#define WAX_TYPE_UNSIGNED_INT _C_UINT
#define WAX_TYPE_UNSIGNED_SHORT _C_USHT

#define WAX_TYPE_LONG _C_LNG
#define WAX_TYPE_LONG_LONG _C_LNG_LNG
#define WAX_TYPE_UNSIGNED_LONG _C_ULNG
#define WAX_TYPE_UNSIGNED_LONG_LONG _C_ULNG_LNG
#define WAX_TYPE_FLOAT _C_FLT
#define WAX_TYPE_DOUBLE _C_DBL

#define WAX_TYPE_C99_BOOL _C_BOOL

#define WAX_TYPE_STRING _C_CHARPTR
#define WAX_TYPE_VOID _C_VOID
#define WAX_TYPE_ARRAY _C_ARY_B
#define WAX_TYPE_ARRAY_END _C_ARY_E
#define WAX_TYPE_BITFIELD _C_BFLD
#define WAX_TYPE_ID _C_ID
#define WAX_TYPE_CLASS _C_CLASS
#define WAX_TYPE_SELECTOR _C_SEL
#define WAX_TYPE_STRUCT _C_STRUCT_B
#define WAX_TYPE_STRUCT_END _C_STRUCT_E
#define WAX_TYPE_UNION _C_UNION_B
#define WAX_TYPE_UNION_END _C_UNION_E
#define WAX_TYPE_POINTER _C_PTR
#define WAX_TYPE_UNKNOWN _C_UNDEF

#define WAX_PROTOCOL_TYPE_CONST 'r'
#define WAX_PROTOCOL_TYPE_IN 'n'
#define WAX_PROTOCOL_TYPE_INOUT 'N'
#define WAX_PROTOCOL_TYPE_OUT 'o'
#define WAX_PROTOCOL_TYPE_BYCOPY 'O'
#define WAX_PROTOCOL_TYPE_BYREF 'R'
#define WAX_PROTOCOL_TYPE_ONEWAY 'V'

#define BEGIN_STACK_MODIFY(L) int __startStackIndex = lua_gettop((L));

#define END_STACK_MODIFY(L, i) while(lua_gettop((L)) > (__startStackIndex + (i))) lua_remove((L), __startStackIndex + 1);

#ifndef LOG_FLAGS
    #define LOG_FLAGS (LOG_FATAL | LOG_ERROR | LOG_DEBUG)
#endif

#define LOG_DEBUG	1 << 0
#define LOG_ERROR	1 << 1
#define LOG_FATAL	1 << 2

#define LOG_GC		1 << 5
#define LOG_NETWORK	1 << 6

// Debug Helpers
void wax_printStack(lua_State *L);
void wax_printStackAt(lua_State *L, int i);
void wax_printTable(lua_State *L, int t);
void wax_log(int flag, NSString *format, ...);
int wax_getStackTrace(lua_State *L);

// Convertion Helpers
int wax_fromObjcEx(lua_State *L, const char *typeDescription, va_list argsList);
int wax_fromObjc(lua_State *L, const char *typeDescription, void *buffer);
int bba_wax_fromObjc(lua_State *L, NSString *typeDesc, NSArray *args, int pindex);

void wax_fromInstance(lua_State *L, id instance);
void wax_fromStruct(lua_State *L, const char *typeDescription, void *buffer);
    
void *wax_copyToObjc(lua_State *L, const char *typeDescription, int stackIndex, int *outsize);

// Misc Helpers
NSString * wax_selectorsForName(const char *methodName, SEL possibleSelectors[2]);
BOOL wax_selectorForInstance(wax_instance_userdata *instanceUserdata, SEL* foundSelectors, const char *methodName, BOOL forceInstanceCheck, NSString **paramType);
void wax_pushMethodNameFromSelector(lua_State *L, SEL selector, NSArray *exTypes);
BOOL wax_isInitMethod(const char *methodName);

const char *wax_removeProtocolEncodings(const char *type_descriptions);

int wax_sizeOfTypeDescForVaPms(const char *full_type_description);
int wax_sizeOfTypeDescription(const char *full_type_description);
int wax_simplifyTypeDescription(const char *in, char *out);

int wax_errorFunction(lua_State *L);
int wax_pcall(lua_State *L, int argumentCount, int returnCount);