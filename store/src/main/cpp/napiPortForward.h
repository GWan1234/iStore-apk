#ifndef NAPI_PORT_FORWARD_H
#define NAPI_PORT_FORWARD_H

#include "napi/native_api.h"

// 暴露端口转发相关的函数到NAPI
void RegisterPortForwardingFunctions(napi_env env, napi_value exports);

#endif // NAPI_PORT_FORWARD_H 