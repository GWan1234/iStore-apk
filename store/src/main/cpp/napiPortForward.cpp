#include "napiWrapper.hpp"
#include "command.h"
#include "napi/native_api.h"
#include <hilog/log.h>
#include <string>
#include <vector>       // For std::vector in ListActivePortForwardings
#include <tuple>        // For std::tuple in ListActivePortForwardings
#include "protocol/ssh/SshSession.h" // Include SshSession to call methods
#include "protocol/SessionManager/SessionManager.h"
#include <system_error> // For std::system_error

#undef LOG_DOMAIN 
#undef LOG_TAG 
#define LOG_DOMAIN 0x3200
#define LOG_TAG "PORT_FORWARD_ASYNC_TAG" // Updated Log Tag

// extern std::shared_ptr<Session> SessionHandle; // 移除全局会话句柄
// extern napi_env mainEnv; // mainEnv might not be needed if using env from callback_info

// --- Helper Functions ---

// Helper to create a NAPI string from std::string
static napi_value CreateNapiString(napi_env env, const std::string& s) {
    napi_value result;
    napi_create_string_utf8(env, s.c_str(), NAPI_AUTO_LENGTH, &result);
    return result;
}

// Helper to create a NAPI error object
static napi_value CreateNapiError(napi_env env, const std::string& msg, const char* code = nullptr) {
    napi_value error_msg, error_code, error;
    napi_create_string_utf8(env, msg.c_str(), NAPI_AUTO_LENGTH, &error_msg);
    if (code) {
        napi_create_string_utf8(env, code, NAPI_AUTO_LENGTH, &error_code);
        napi_create_error(env, error_code, error_msg, &error);
    }
    else {
        napi_create_error(env, nullptr, error_msg, &error);
    }
    return error;
}

// 获取 Session
static SshSession* GetSshSessionById(int sessionId) {
    auto& sessionManager = SessionManager::getInstance();
    auto session = sessionManager.getSession(sessionId);
    // Add null check for the shared_ptr itself
    if (!session) {
        OH_LOG_WARN(LOG_APP, "GetSshSessionById (PortForward): Session ID %{public}d not found.", sessionId);
        return nullptr;
    }
    // dynamic_cast will return nullptr if the cast fails or if session.get() is already null
    SshSession* sshSession = dynamic_cast<SshSession*>(session.get());
    if (!sshSession) {
         OH_LOG_WARN(LOG_APP, "GetSshSessionById (PortForward): Session ID %{public}d is not an SSH session.", sessionId);
    }
    return sshSession;
}

// --- Async Work Data Structures ---

struct PortForwardBoolResult {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    bool success = false;
    std::string error_message;
    // Input parameters specific to the operation
    int port = 0;
    std::string targetHost;
    int targetPort = 0;
    bool anyInterface = false;
    bool isRemote = false;
    int sessionId = 0;
};

struct PortForwardListResult {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::vector<std::tuple<int, std::string, int, bool, bool>> forwardings;
    std::string error_message;
    int sessionId = 0;
};

// --- Async Execute/Complete Functions ---

// Generic Execute for operations returning bool
void ExecuteBoolWork(napi_env env, void* data) {
    PortForwardBoolResult* workData = static_cast<PortForwardBoolResult*>(data);

    SshSession* sshSession = GetSshSessionById(workData->sessionId);
    if (!sshSession) {
        workData->error_message = "No active session";
        return;
    }

    try {
        // Determine which function to call based on context (we'll differentiate later)
        // This is a placeholder, specific execute functions are better
        // workData->success = sshSession->someBoolPortForwardOp(...);
        OH_LOG_WARN(LOG_APP, "ExecuteBoolWork needs specific implementation per function.");
        workData->error_message = "Generic ExecuteBoolWork called - needs specialization";
    } catch (const std::exception& e) {
        workData->error_message = std::string("Exception during port forward operation: ") + e.what();
    } catch (...) {
        workData->error_message = "Unknown exception during port forward operation";
    }
}

// Specific Execute Functions (with enhanced error messages)
void ExecuteStartLocal(napi_env env, void* data) {
    PortForwardBoolResult* workData = static_cast<PortForwardBoolResult*>(data);
    SshSession* sshSession = GetSshSessionById(workData->sessionId);
    if (!sshSession) { workData->error_message = "Session not found or inactive (ID: " + std::to_string(workData->sessionId) + ")"; return; }
    try {
        OH_LOG_INFO(LOG_APP, "Async Execute: startLocalPortForwarding(session=%{public}d, port=%{public}d, target=%{public}s:%{public}d, anyInterface=%{public}d)",
                    workData->sessionId, workData->port, workData->targetHost.c_str(), workData->targetPort, workData->anyInterface);
        workData->success = sshSession->startLocalPortForwarding(workData->port, workData->targetHost, workData->targetPort, workData->anyInterface);
        if (!workData->success) {
            // Attempt to provide a more specific reason if possible (e.g., check errno after failure?)
            // For now, use a clearer message than just "false"
             workData->error_message = "Failed to start local port forwarding on port " + std::to_string(workData->port) + ". Port might be in use or SSH channel error.";
             OH_LOG_ERROR(LOG_APP, "%s", workData->error_message.c_str());
        }
    } catch (const std::system_error& e) {
        workData->error_message = "System error starting local forward: " + std::string(e.what()) + " (code: " + std::to_string(e.code().value()) + ")";
        OH_LOG_ERROR(LOG_APP, "%s", workData->error_message.c_str());
    } catch (const std::exception& e) {
        workData->error_message = "Exception starting local forward: " + std::string(e.what());
        OH_LOG_ERROR(LOG_APP, "%s", workData->error_message.c_str());
     } catch (...) {
        workData->error_message = "Unknown exception starting local port forwarding.";
        OH_LOG_ERROR(LOG_APP, "%s", workData->error_message.c_str());
    }
}

void ExecuteStartRemote(napi_env env, void* data) {
    PortForwardBoolResult* workData = static_cast<PortForwardBoolResult*>(data);
    SshSession* sshSession = GetSshSessionById(workData->sessionId);
     if (!sshSession) { workData->error_message = "Session not found or inactive (ID: " + std::to_string(workData->sessionId) + ")"; return; }
    try {
        OH_LOG_INFO(LOG_APP, "Async Execute: startRemotePortForwarding(session=%{public}d, remotePort=%{public}d, target=%{public}s:%{public}d)",
                    workData->sessionId, workData->port, workData->targetHost.c_str(), workData->targetPort);
        workData->success = sshSession->startRemotePortForwarding(workData->port, workData->targetHost, workData->targetPort);
        if (!workData->success) {
            workData->error_message = "Failed to start remote port forwarding for port " + std::to_string(workData->port) + ". Remote server might have refused or SSH channel error.";
             OH_LOG_ERROR(LOG_APP, "%s", workData->error_message.c_str());
        }
     } catch (const std::system_error& e) {
        workData->error_message = "System error starting remote forward: " + std::string(e.what()) + " (code: " + std::to_string(e.code().value()) + ")";
        OH_LOG_ERROR(LOG_APP, "%s", workData->error_message.c_str());
    } catch (const std::exception& e) {
        workData->error_message = "Exception starting remote forward: " + std::string(e.what());
         OH_LOG_ERROR(LOG_APP, "%s", workData->error_message.c_str());
     } catch (...) {
        workData->error_message = "Unknown exception starting remote port forwarding.";
         OH_LOG_ERROR(LOG_APP, "%s", workData->error_message.c_str());
    }
}

void ExecuteStartDynamic(napi_env env, void* data) {
    PortForwardBoolResult* workData = static_cast<PortForwardBoolResult*>(data);
    SshSession* sshSession = GetSshSessionById(workData->sessionId);
     if (!sshSession) { workData->error_message = "Session not found or inactive (ID: " + std::to_string(workData->sessionId) + ")"; return; }
    try {
        OH_LOG_INFO(LOG_APP, "Async Execute: startDynamicPortForwarding(session=%{public}d, port=%{public}d, anyInterface=%{public}d)",
                    workData->sessionId, workData->port, workData->anyInterface);
        workData->success = sshSession->startDynamicPortForwarding(workData->port, workData->anyInterface);
        if (!workData->success) {
             workData->error_message = "Failed to start dynamic (SOCKS) port forwarding on port " + std::to_string(workData->port) + ". Port might be in use or SSH error.";
              OH_LOG_ERROR(LOG_APP, "%s", workData->error_message.c_str());
        }
     } catch (const std::system_error& e) {
        workData->error_message = "System error starting dynamic forward: " + std::string(e.what()) + " (code: " + std::to_string(e.code().value()) + ")";
        OH_LOG_ERROR(LOG_APP, "%s", workData->error_message.c_str());
    } catch (const std::exception& e) {
        workData->error_message = "Exception starting dynamic forward: " + std::string(e.what());
         OH_LOG_ERROR(LOG_APP, "%s", workData->error_message.c_str());
     } catch (...) {
        workData->error_message = "Unknown exception starting dynamic port forwarding.";
         OH_LOG_ERROR(LOG_APP, "%s", workData->error_message.c_str());
    }
}

void ExecuteStop(napi_env env, void* data) {
    PortForwardBoolResult* workData = static_cast<PortForwardBoolResult*>(data);
    SshSession* sshSession = GetSshSessionById(workData->sessionId);
     if (!sshSession) { workData->error_message = "Session not found or inactive (ID: " + std::to_string(workData->sessionId) + ")"; return; }
    try {
        OH_LOG_INFO(LOG_APP, "Async Execute: stopPortForwarding(session=%{public}d, port=%{public}d, isRemote=%{public}d)",
                     workData->sessionId, workData->port, workData->isRemote);
        // stopPortForwarding returns false if the rule wasn't found.
        // It doesn't typically return false for errors *during* stopping,
        // as it tries to clean up best-effort. So, we mainly check if it was found.
        workData->success = sshSession->stopPortForwarding(workData->port, workData->isRemote);
        if (!workData->success) {
            workData->error_message = "Failed to stop port forwarding: Rule for port " + std::to_string(workData->port) + (workData->isRemote ? " (remote)" : " (local/dynamic)") + " not found or already stopped.";
             OH_LOG_WARN(LOG_APP, "%s", workData->error_message.c_str()); // Log as warning if not found
        }
     } catch (const std::system_error& e) {
        // Errors during stopping are less common but possible
        workData->error_message = "System error stopping port forward: " + std::string(e.what()) + " (code: " + std::to_string(e.code().value()) + ")";
        OH_LOG_ERROR(LOG_APP, "%s", workData->error_message.c_str());
        workData->success = false; // Mark as failure if exception occurs
    } catch (const std::exception& e) {
        workData->error_message = "Exception stopping port forward: " + std::string(e.what());
         OH_LOG_ERROR(LOG_APP, "%s", workData->error_message.c_str());
         workData->success = false;
     } catch (...) {
        workData->error_message = "Unknown exception stopping port forwarding.";
         OH_LOG_ERROR(LOG_APP, "%s", workData->error_message.c_str());
         workData->success = false;
    }
}

void ExecuteIsActive(napi_env env, void* data) {
    PortForwardBoolResult* workData = static_cast<PortForwardBoolResult*>(data);
    SshSession* sshSession = GetSshSessionById(workData->sessionId);
     if (!sshSession) { workData->error_message = "Session not found or inactive (ID: " + std::to_string(workData->sessionId) + ")"; return; }
    try {
        OH_LOG_INFO(LOG_APP, "Async Execute: isPortForwardingActive(session=%{public}d, port=%{public}d, isRemote=%{public}d)",
                     workData->sessionId, workData->port, workData->isRemote);
        workData->success = sshSession->isPortForwardingActive(workData->port, workData->isRemote);
        // No error message needed if workData->success is false
    } catch (const std::exception& e) {
        workData->error_message = "Exception checking port forwarding status: " + std::string(e.what());
         OH_LOG_ERROR(LOG_APP, "%s", workData->error_message.c_str());
     } catch (...) {
        workData->error_message = "Unknown exception checking port forwarding status.";
         OH_LOG_ERROR(LOG_APP, "%s", workData->error_message.c_str());
    }
}

void ExecuteListActive(napi_env env, void* data) {
    PortForwardListResult* workData = static_cast<PortForwardListResult*>(data);
    SshSession* sshSession = GetSshSessionById(workData->sessionId);
    if (!sshSession) { workData->error_message = "Session not found or inactive (ID: " + std::to_string(workData->sessionId) + ")"; return; }
    try {
        OH_LOG_INFO(LOG_APP, "Async Execute: listActivePortForwardings(session=%{public}d)", workData->sessionId);
        workData->forwardings = sshSession->listActivePortForwardings();
    } catch (const std::exception& e) {
        workData->error_message = "Exception listing active port forwardings: " + std::string(e.what());
         OH_LOG_ERROR(LOG_APP, "%s", workData->error_message.c_str());
     } catch (...) {
        workData->error_message = "Unknown exception listing active port forwardings.";
         OH_LOG_ERROR(LOG_APP, "%s", workData->error_message.c_str());
    }
}

// Generic Complete for bool results
void CompleteBoolWork(napi_env env, napi_status status, void* data) {
    PortForwardBoolResult* workData = static_cast<PortForwardBoolResult*>(data);

    if (status != napi_ok) {
        // Handle cancellation or other async work error ONLY if no specific error is already set
        if (workData->error_message.empty()) {
            workData->error_message = "Async work failed or cancelled (status: " + std::to_string(status) + ")";
        }
    }

    if (!workData->error_message.empty()) {
        napi_value error = CreateNapiError(env, workData->error_message);
        napi_reject_deferred(env, workData->deferred, error);
        OH_LOG_ERROR(LOG_APP, "Async Complete Error: %s", workData->error_message.c_str());
    } else {
        napi_value result;
        napi_get_boolean(env, workData->success, &result);
        napi_resolve_deferred(env, workData->deferred, result);
        OH_LOG_INFO(LOG_APP, "Async Complete Success: %{public}d", workData->success);
    }

    // Clean up
    napi_delete_async_work(env, workData->work);
    delete workData;
}

// Complete function for ListActive
void CompleteListActive(napi_env env, napi_status status, void* data) {
    PortForwardListResult* workData = static_cast<PortForwardListResult*>(data);

     if (status != napi_ok) {
         if (workData->error_message.empty()) {
            workData->error_message = "Async work failed or cancelled (status: " + std::to_string(status) + ")";
         }
    }

    if (!workData->error_message.empty()) {
        napi_value error = CreateNapiError(env, workData->error_message);
        napi_reject_deferred(env, workData->deferred, error);
        OH_LOG_ERROR(LOG_APP, "Async List Complete Error: %s", workData->error_message.c_str());
    } else {
        napi_value resultArray;
        napi_create_array_with_length(env, workData->forwardings.size(), &resultArray);

        for (size_t i = 0; i < workData->forwardings.size(); ++i) {
            napi_value item;
            napi_create_object(env, &item);

            const auto& [port, targetHost, targetPort, isRemote, isDynamic] = workData->forwardings[i];

            napi_value portValue, hostValue, targetPortValue, isRemoteValue, isDynamicValue;
            napi_create_int32(env, port, &portValue);
            napi_create_string_utf8(env, targetHost.c_str(), NAPI_AUTO_LENGTH, &hostValue);
            napi_create_int32(env, targetPort, &targetPortValue);
            napi_get_boolean(env, isRemote, &isRemoteValue);
            napi_get_boolean(env, isDynamic, &isDynamicValue);

            napi_set_named_property(env, item, "port", portValue);
            napi_set_named_property(env, item, "targetHost", hostValue);
            napi_set_named_property(env, item, "targetPort", targetPortValue);
            napi_set_named_property(env, item, "isRemote", isRemoteValue);
            napi_set_named_property(env, item, "isDynamic", isDynamicValue);

            napi_set_element(env, resultArray, i, item);
        }
        napi_resolve_deferred(env, workData->deferred, resultArray);
        OH_LOG_INFO(LOG_APP, "Async List Complete Success: %{public}zu items", workData->forwardings.size());
    }

    // Clean up
    napi_delete_async_work(env, workData->work);
    delete workData;
}


// --- NAPI Function Implementations (Async Wrappers) ---

static napi_value StartLocalPortForwarding(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 4) {
        napi_throw_type_error(env, nullptr, "Requires at least 4 arguments: sessionId, localPort, targetHost, targetPort");
        return nullptr;
    }

    // Create Promise and Deferred
    napi_deferred deferred;
    napi_value promise;
    napi_create_promise(env, &deferred, &promise);

    // Prepare async work data
    PortForwardBoolResult* workData = new PortForwardBoolResult();
    workData->deferred = deferred;
    workData->isRemote = false; // Mark operation type if needed later

    // Parse arguments
    napi_get_value_int32(env, args[0], &workData->sessionId);
    napi_get_value_int32(env, args[1], &workData->port);
    size_t hostLen;
    char targetHostBuf[1024];
    napi_get_value_string_utf8(env, args[2], targetHostBuf, sizeof(targetHostBuf), &hostLen);
    workData->targetHost = std::string(targetHostBuf, hostLen);
    napi_get_value_int32(env, args[3], &workData->targetPort);
    if (argc >= 5) {
        napi_get_value_bool(env, args[4], &workData->anyInterface);
    }

    // Create and queue async work
    napi_value resource_name = CreateNapiString(env, "StartLocalPortForwardingAsync");
    napi_create_async_work(env, nullptr, resource_name,
                           ExecuteStartLocal, // Use specific execute function
                           CompleteBoolWork,
                           workData,
                           &workData->work);
    napi_queue_async_work(env, workData->work);

    return promise;
}

static napi_value StartRemotePortForwarding(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 4) {
        napi_throw_type_error(env, nullptr, "Requires 4 arguments: sessionId, remotePort, targetHost, targetPort");
        return nullptr;
    }

    napi_deferred deferred;
    napi_value promise;
    napi_create_promise(env, &deferred, &promise);

    PortForwardBoolResult* workData = new PortForwardBoolResult();
    workData->deferred = deferred;
    workData->isRemote = true; // Mark operation type

    napi_get_value_int32(env, args[0], &workData->sessionId);
    napi_get_value_int32(env, args[1], &workData->port); // remotePort stored in workData->port
    size_t hostLen;
    char targetHostBuf[1024];
    napi_get_value_string_utf8(env, args[2], targetHostBuf, sizeof(targetHostBuf), &hostLen);
    workData->targetHost = std::string(targetHostBuf, hostLen);
    napi_get_value_int32(env, args[3], &workData->targetPort);

    napi_value resource_name = CreateNapiString(env, "StartRemotePortForwardingAsync");
    napi_create_async_work(env, nullptr, resource_name,
                           ExecuteStartRemote,
                           CompleteBoolWork,
                           workData,
                           &workData->work);
    napi_queue_async_work(env, workData->work);

    return promise;
}

static napi_value StartDynamicPortForwarding(napi_env env, napi_callback_info info) {
     size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 2) {
        napi_throw_type_error(env, nullptr, "Requires at least 2 arguments: sessionId, localPort");
        return nullptr;
    }

    napi_deferred deferred;
    napi_value promise;
    napi_create_promise(env, &deferred, &promise);

    PortForwardBoolResult* workData = new PortForwardBoolResult();
    workData->deferred = deferred;
    workData->isRemote = false; // Mark operation type

    napi_get_value_int32(env, args[0], &workData->sessionId);
    napi_get_value_int32(env, args[1], &workData->port);
    if (argc >= 3) {
        napi_get_value_bool(env, args[2], &workData->anyInterface);
    }

    napi_value resource_name = CreateNapiString(env, "StartDynamicPortForwardingAsync");
    napi_create_async_work(env, nullptr, resource_name,
                           ExecuteStartDynamic,
                           CompleteBoolWork,
                           workData,
                           &workData->work);
    napi_queue_async_work(env, workData->work);

    return promise;
}

static napi_value StopPortForwarding(napi_env env, napi_callback_info info) {
     size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 2) {
        napi_throw_type_error(env, nullptr, "Requires at least 2 arguments: sessionId, port");
        return nullptr;
    }

    napi_deferred deferred;
    napi_value promise;
    napi_create_promise(env, &deferred, &promise);

    PortForwardBoolResult* workData = new PortForwardBoolResult();
    workData->deferred = deferred;

    napi_get_value_int32(env, args[0], &workData->sessionId);
    napi_get_value_int32(env, args[1], &workData->port);
    if (argc >= 3) {
        napi_get_value_bool(env, args[2], &workData->isRemote);
    }

    napi_value resource_name = CreateNapiString(env, "StopPortForwardingAsync");
    napi_create_async_work(env, nullptr, resource_name,
                           ExecuteStop,
                           CompleteBoolWork,
                           workData,
                           &workData->work);
    napi_queue_async_work(env, workData->work);

    return promise;
}

static napi_value IsPortForwardingActive(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 2) {
        napi_throw_type_error(env, nullptr, "Requires at least 2 arguments: sessionId, port");
        return nullptr;
    }

    napi_deferred deferred;
    napi_value promise;
    napi_create_promise(env, &deferred, &promise);

    PortForwardBoolResult* workData = new PortForwardBoolResult();
    workData->deferred = deferred;

    int sessionId = 0;
    napi_get_value_int32(env, args[0], &sessionId);
    napi_get_value_int32(env, args[1], &workData->port);
    if (argc >= 3) {
        napi_get_value_bool(env, args[2], &workData->isRemote);
    }
    workData->sessionId = sessionId;

    napi_value resource_name = CreateNapiString(env, "IsPortForwardingActiveAsync");
    napi_create_async_work(env, nullptr, resource_name,
                           ExecuteIsActive,
                           CompleteBoolWork,
                           workData,
                           &workData->work);
    napi_queue_async_work(env, workData->work);

    return promise;
}

static napi_value ListActivePortForwardings(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 1) {
        napi_throw_type_error(env, nullptr, "Requires 1 argument: sessionId");
        return nullptr;
    }

    napi_deferred deferred;
    napi_value promise;
    napi_create_promise(env, &deferred, &promise);

    PortForwardListResult* workData = new PortForwardListResult();
    workData->deferred = deferred;

    napi_get_value_int32(env, args[0], &workData->sessionId);

    napi_value resource_name = CreateNapiString(env, "ListActivePortForwardingsAsync");
    napi_create_async_work(env, nullptr, resource_name,
                           ExecuteListActive, // Specific execute
                           CompleteListActive, // Specific complete
                           workData,
                           &workData->work);
    napi_queue_async_work(env, workData->work);

    return promise;
}

// --- Registration --- 

void RegisterPortForwardingFunctions(napi_env env, napi_value exports) {
    napi_property_descriptor portForwardDesc[] = {
        { "startLocalPortForwarding", nullptr, StartLocalPortForwarding, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "startRemotePortForwarding", nullptr, StartRemotePortForwarding, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "startDynamicPortForwarding", nullptr, StartDynamicPortForwarding, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "stopPortForwarding", nullptr, StopPortForwarding, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "isPortForwardingActive", nullptr, IsPortForwardingActive, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "listActivePortForwardings", nullptr, ListActivePortForwardings, nullptr, nullptr, nullptr, napi_default, nullptr },
    };
    
    napi_define_properties(env, exports, sizeof(portForwardDesc) / sizeof(portForwardDesc[0]), portForwardDesc);
}