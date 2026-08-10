#include "jsonAnalyse.h"

SessionAnalyse* encapsulateSSHFromJson(std::string inputSessionJson) {
    
    SessionAnalyse* SessionHandle = (SessionAnalyse*)malloc(sizeof(SessionAnalyse));
    if (SessionHandle == NULL) {
        return NULL;
    }

    cJSON *sesionJson = NULL;
    cJSON *connection = NULL;
    cJSON *session = NULL;
    cJSON *item = NULL;
    std::string authType;

    sesionJson = cJSON_Parse(inputSessionJson.c_str());
    if (sesionJson == NULL) {
        const char *error_ptr = cJSON_GetErrorPtr();
        if (error_ptr != NULL) {
            fprintf(stderr, "Error before: %s\n", error_ptr);
        }
        goto error;
    }

    session = cJSON_GetObjectItemCaseSensitive(sesionJson, "Session");
    if (!cJSON_IsObject(session)) {
        goto error;
    }
    
    connection = cJSON_GetObjectItemCaseSensitive(sesionJson, "Connection");
    if (!cJSON_IsObject(connection)) {
        goto error;
    }

    item = cJSON_GetObjectItemCaseSensitive(session, "hostName");
    if (!(cJSON_IsString(item) && item->valuestring != NULL)) {
        goto error;
    }
    SessionHandle->hostName = strdup(item->valuestring);

    item = cJSON_GetObjectItemCaseSensitive(session, "port");
    if (!(cJSON_IsString(item) && item->valuestring != NULL)) {
        goto error;
    }
    SessionHandle->port = atoi(item->valuestring);

    item = cJSON_GetObjectItemCaseSensitive(session, "password");
    if (!(cJSON_IsString(item) && item->valuestring != NULL)) {
        goto error;
    }
    SessionHandle->password = strdup(item->valuestring);

    item = cJSON_GetObjectItemCaseSensitive(session, "userName");
    if (!(cJSON_IsString(item) && item->valuestring != NULL)) {
        goto error;
    }
    SessionHandle->userName = strdup(item->valuestring);

    // 解析认证方式
    item = cJSON_GetObjectItemCaseSensitive(session, "authType");
    if (!(cJSON_IsString(item) && item->valuestring != NULL)) {
        goto error;
    }
    authType = item->valuestring;
    if (authType == "password") {
        SessionHandle->authType = AUTH_PASSWORD;
    } else if (authType == "publickey") {
        SessionHandle->authType = AUTH_PUBLICKEY;
    } else {
        goto error;
    }

    // 解析私钥文件描述符
    item = cJSON_GetObjectItemCaseSensitive(session, "privateKeyFd");
    if (item && item->type == cJSON_Number) {
        SessionHandle->privateKeyFd = item->valueint;
    }
    
    item = cJSON_GetObjectItemCaseSensitive(connection, "keepalive");
    if (!(cJSON_IsNumber(item))) {
        goto error;
    }
    SessionHandle->keepAlive = item->valueint;
    
    item = cJSON_GetObjectItemCaseSensitive(connection, "version");
    if (!(cJSON_IsString(item) && item->valuestring != NULL)) {
        goto error;
    }
    SessionHandle->version = strdup(item->valuestring);

    cJSON_Delete(sesionJson);
    return SessionHandle;

error:
    free(SessionHandle);
    cJSON_Delete(sesionJson);
    return NULL;
}

PROTOCOL analyseProtocol(std::string input) {
    
    cJSON *sesionJson = NULL;
    cJSON *session = NULL;
    cJSON *item = NULL;

    sesionJson = cJSON_Parse(input.c_str());
    if (sesionJson == NULL) {
        const char *error_ptr = cJSON_GetErrorPtr();
        if (error_ptr != NULL) {
            fprintf(stderr, "Error before: %s\n", error_ptr);
        }
        cJSON_Delete(sesionJson);
        return ERROR;
    }

    session = cJSON_GetObjectItemCaseSensitive(sesionJson, "Session");
    if (!cJSON_IsObject(session)) {
        cJSON_Delete(sesionJson);
        return ERROR;
    }

    item = cJSON_GetObjectItemCaseSensitive(session, "connectionType");
    if (!(cJSON_IsString(item) && item->valuestring != NULL)) {
        cJSON_Delete(sesionJson);
        return ERROR;
    }
    std::string protocol = item->valuestring;
    
    if(protocol == "SSH") {
        cJSON_Delete(sesionJson);
        return SSH;
    } else if (protocol == "Serial") {
        cJSON_Delete(sesionJson);
        return SERIAL;
    } else if (protocol == "Telnet") {
        cJSON_Delete(sesionJson);
        return TELNET;
    }
     
    cJSON_Delete(sesionJson);
    return ERROR;
}