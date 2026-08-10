#ifndef PUTTYLIB_JSONANALYSE_H
#define PUTTYLIB_JSONANALYSE_H

#include <iostream>
#include <string>

extern "C"{
#include "cJSON.h"
}

typedef enum {
    SSH,
    SERIAL,
    TELNET,
    RAW,
    ERROR
}PROTOCOL;

typedef enum {
    AUTH_PASSWORD,
    AUTH_PUBLICKEY
} AUTH_TYPE;

typedef struct SessionAnalyseStr{
    const char* hostName;
    const char* password;
    const char* userName;
    const char* version;
    int port;
    int keepAlive;
    AUTH_TYPE authType;  // 认证方式
    int privateKeyFd;    // 私钥文件描述符
}SessionAnalyse;

SessionAnalyse* encapsulateSSHFromJson(std::string inputSessionJson);

PROTOCOL analyseProtocol(std::string input);

#endif //PUTTYLIB_JSONANALYSE_H
