#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef void (*cb_clang_diagnostic_callback)(const char *severity,const char *message,const char *file,int32_t line,int32_t column,void *context);
int32_t cb_clang_compile(int32_t argc,const char * const *argv,cb_clang_diagnostic_callback callback,void *context);
const char *cb_clang_version(void);
#ifdef __cplusplus
}
#endif
