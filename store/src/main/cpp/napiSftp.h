#ifndef NAPI_SFTP_H
#define NAPI_SFTP_H

#include "napi/native_api.h"

// 声明 SFTP N-API 函数的注册函数
void RegisterSftpFunctions(napi_env env, napi_value exports);

#endif // NAPI_SFTP_H 