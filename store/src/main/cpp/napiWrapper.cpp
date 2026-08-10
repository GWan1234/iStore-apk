#include "napiWrapper.hpp"
#include "command.h"

// 变量定义
SessionManager& sessionManager = SessionManager::getInstance();
// 移除全局SessionHandle

// 新接口：返回sessionId
int openProtocol(const std::string& napiInput) {
    PROTOCOL protocolType = analyseProtocol(napiInput);
    auto session = sessionManager.createSession(protocolType);
    if (!session) {
        OH_LOG_ERROR(LOG_APP, "openProtocol: Failed to create session for type %{public}d", protocolType);
        return -1;
    }
    sessionManager.applyPendingCallbacks(session);
    int sessionId = sessionManager.getSessionId(session);
    if (!session->openConnect(napiInput)) {
        sessionManager.destroySession(sessionId);
        return -1;
    }
    return sessionId;
}

bool sendCommand(int sessionId, const std::string& command) {
    try {
        auto session = sessionManager.getSession(sessionId);
        if (!session) {
            OH_LOG_ERROR(LOG_APP, "sendCommand: Session ID %{public}d not found.", sessionId);
            return false;
        }
        return session->sendData(command);
    } catch (...) {
        OH_LOG_ERROR(LOG_APP, "sendCommand: Caught unknown exception for ID %{public}d.", sessionId);
        return false;
    }
}

bool closeConnect(int sessionId) {
    try {
        auto session = sessionManager.getSession(sessionId);
        if (!session) {
            OH_LOG_ERROR(LOG_APP, "closeConnect: Failed to get session for ID %{public}d", sessionId);
            return false;
        }

        OH_LOG_INFO(LOG_APP, "closeConnect: Calling session->disconnect() for ID %{public}d", sessionId);
        bool disconnectResult = session->disconnect();
        OH_LOG_INFO(LOG_APP, "closeConnect: session->disconnect() for ID %{public}d returned: %{public}d", sessionId, disconnectResult);

        if (!disconnectResult) {
            OH_LOG_ERROR(LOG_APP, "closeConnect: disconnectResult is false for ID %{public}d, returning false.", sessionId);
            return false;
        }

        OH_LOG_INFO(LOG_APP, "closeConnect: disconnectResult is true for ID %{public}d. Destroying session...", sessionId);
        sessionManager.destroySession(sessionId);

        OH_LOG_INFO(LOG_APP, "closeConnect: About to return true for ID %{public}d", sessionId);
        return true;
    } catch (const std::exception& e) {
        OH_LOG_ERROR(LOG_APP, "closeConnect: Caught std::exception for ID %{public}d: %{public}s. Returning false.", sessionId, e.what());
        return false;
    } catch (...) {
        OH_LOG_ERROR(LOG_APP, "closeConnect: Caught unknown exception for ID %{public}d. Returning false.", sessionId);
        return false;
    }
}