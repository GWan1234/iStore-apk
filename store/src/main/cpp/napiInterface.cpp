#include "napiWrapper.hpp"
#include "command.h"
#include "napi/native_api.h"
#include "napiPortForward.h"
#include "napiSftp.h"
#include "protocol/ssh/SshSession.h"
#include "key_manager.h"
#include <hilog/log.h>
#include <string>
#include <uv.h>
#include <thread>
#include <memory>
#include <libssh2.h>
#include <atomic>
#include <chrono>


#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3200 // 全局domain宏，标识业务领域
#define LOG_TAG "MY_TAG"  // 全局tag宏，标识模块日志tag
extern SessionManager& sessionManager;

// --- Directory Tracking 相关结构体 ---
struct DirectoryTrackingWorkData {
    int sessionId; // <-- Add sessionId
    bool enable;
    bool success;
    std::string errorMsg;
    napi_async_work work;
    napi_deferred deferred;
};

struct DirectoryChangeCallbackWorkData {
    napi_ref callbackRef;
    napi_async_work work;
    napi_value result;
};

// --- Directory Change Notification 结构体 (修改) ---
struct DirectoryChangeNotifyData {
    int sessionId; // <-- 新增 sessionId
    std::string directory;
    napi_ref callbackRef; // 仍然是全局回调引用
};

// 目录变更回调全局状态 - 将这些移到文件前面
static napi_ref g_directoryChangeCallbackRef = nullptr;
static napi_env g_directoryChangeEnv = nullptr;
static std::atomic<bool> g_directoryCallbackRegistered{false};
static std::mutex g_directoryCallbackMutex;
static napi_threadsafe_function g_directoryChangeTsfn = nullptr;

static napi_env mainEnv = nullptr;
static uv_loop_t* mainLoop = nullptr;
static napi_ref dataCallbackRef = nullptr;
static std::atomic<bool> isCallbackValid{false};
static std::mutex g_callbackMutex;

static napi_threadsafe_function tsfn = nullptr;
static std::atomic<bool> tsfnCreated{false};

static std::atomic<bool> g_isSessionBusy{false};

struct AsyncData {
    std::string data;
    bool status;
    napi_ref callbackRef;
    napi_async_work work;
};

// 在文件开头添加日志相关结构体
struct LoggingWorkData {
    int sessionId; // <-- Add sessionId
    int fd;
    int logType;
    int existOperation;
    // 新增的配置字段
    bool includeHeader;        // Include header
    bool omitKnownPassword;    // Omit known password fields
    bool omitSessionData;      // Omit session data
    bool success;
    std::string errorMsg;
    napi_ref callback;
    napi_async_work work;
};


// 为 ResizeTerminal 添加新的工作数据结构
struct ResizeWorkData {
    int sessionId; // <-- Add sessionId
    int width;
    int height;
    bool success;
    std::string errorMsg;
    napi_async_work work;
    napi_deferred deferred; // 用于 Promise
};

// --- 新增: 密钥生成异步工作数据结构 ---
struct GenerateKeyWorkData {
    std::string algorithm;
    std::string password;
    int private_key_fd;
    int public_key_fd;
    int key_bits = 2048; // Default key size
    KeyOperationResult result; // Store the result from C++ function
    napi_async_work work;
    napi_deferred deferred;
};

// --- 新增: 密钥解密异步工作数据结构 ---
struct DecryptKeyWorkData {
    int private_key_fd;
    std::string password;
    KeyOperationResult result; // Store the result from C++ function
    napi_async_work work;
    napi_deferred deferred;
};

// 创建NAPI错误辅助函数
static napi_value CreateNapiError(napi_env env, const char* message) {
    napi_value error_msg;
    napi_value error;
    napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &error_msg);
    napi_create_error(env, nullptr, error_msg, &error);
    return error;
}

// 工作数据结构 for openProtocol
struct OpenConnectWorkData {
    std::string napiInput;
    bool success;
    std::string errorMsg;
    napi_async_work work;
    napi_deferred deferred;
    int sessionId; // 新增sessionId
};

// --- Helper to get string from NAPI value (modified for safety) ---
static std::string SafeGetStringFromNapi(napi_env env, napi_value value) {
    napi_valuetype valuetype;
    napi_status status = napi_typeof(env, value, &valuetype);
    if (status != napi_ok || valuetype != napi_string) {
        OH_LOG_WARN(LOG_APP, "SafeGetStringFromNapi: Expected string, got type %d", valuetype);
        return ""; // Return empty string if not a string
    }
    size_t len = 0;
    status = napi_get_value_string_utf8(env, value, nullptr, 0, &len);
    if (status != napi_ok || len == 0) {
        // Don't log error if length is 0, it might be an intentional empty string
        if (status != napi_ok) {
             OH_LOG_WARN(LOG_APP, "SafeGetStringFromNapi: Failed to get string length (status %d)", status);
        }
        return "";
    }
    std::string str(len, '\0');
    status = napi_get_value_string_utf8(env, value, &str[0], len + 1, &len);
     if (status != napi_ok) {
        OH_LOG_ERROR(LOG_APP, "SafeGetStringFromNapi: Failed to get string value (status %d)", status);
        return ""; // Return empty on error
    }
    return str;
}

// --- Helper to get int32 from NAPI value (for fd) ---
static int SafeGetInt32FromNapi(napi_env env, napi_value value, int default_val = -1) {
    napi_valuetype valuetype;
    napi_status status = napi_typeof(env, value, &valuetype);
    if (status != napi_ok || valuetype != napi_number) {
         OH_LOG_WARN(LOG_APP, "SafeGetInt32FromNapi: Expected number, got type %d", valuetype);
        return default_val;
    }
    int32_t int_val;
    status = napi_get_value_int32(env, value, &int_val);
     if (status != napi_ok) {
        OH_LOG_ERROR(LOG_APP, "SafeGetInt32FromNapi: Failed to get int32 value (status %d)", status);
        return default_val;
    }
    return static_cast<int>(int_val);
}

// --- Helper to get bool from NAPI value ---
static bool SafeGetBoolFromNapi(napi_env env, napi_value value, bool default_val = false) {
    napi_valuetype valuetype;
    napi_status status = napi_typeof(env, value, &valuetype);
    if (status != napi_ok) {
        OH_LOG_WARN(LOG_APP, "SafeGetBoolFromNapi: napi_typeof failed with status %d", status);
        return default_val;
    }
    
    OH_LOG_INFO(LOG_APP, "SafeGetBoolFromNapi: 值类型为 %d (期望 %d=boolean)", valuetype, napi_boolean);
    
    if (valuetype == napi_undefined || valuetype == napi_null) {
        OH_LOG_INFO(LOG_APP, "SafeGetBoolFromNapi: 值为undefined或null，使用默认值 %d", default_val);
        return default_val;
    }
    
    if (valuetype != napi_boolean) {
        OH_LOG_WARN(LOG_APP, "SafeGetBoolFromNapi: Expected boolean, got type %d", valuetype);
        return default_val;
    }
    
    bool bool_val;
    status = napi_get_value_bool(env, value, &bool_val);
    if (status != napi_ok) {
        OH_LOG_ERROR(LOG_APP, "SafeGetBoolFromNapi: Failed to get bool value (status %d)", status);
        return default_val;
    }
    
    OH_LOG_INFO(LOG_APP, "SafeGetBoolFromNapi: 成功获取布尔值 %d", bool_val);
    return bool_val;
}

static std::unique_ptr<char[]> getStringFromInfo(napi_env env, napi_callback_info info) {
    napi_status status;

    size_t argc = 1;
    napi_value argv[1];
    status = napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to get callback arguments");
        return nullptr;
    }

    if (argc < 1) {
        napi_throw_error(env, nullptr, "Expected at least one argument");
        return nullptr;
    }

    // Check argument type - should be string
    napi_valuetype argType;
    status = napi_typeof(env, argv[0], &argType);
    if (status != napi_ok || argType != napi_string) {
         napi_throw_type_error(env, nullptr, "Argument must be a string (JSON connection parameters)");
         return nullptr;
    }

    size_t str_len;
    status = napi_get_value_string_utf8(env, argv[0], nullptr, 0, &str_len);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to get string length");
        return nullptr;
    }

    std::unique_ptr<char[]> str(new char[str_len + 1]);
    status = napi_get_value_string_utf8(env, argv[0], str.get(), str_len + 1, &str_len);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to get string value");
        return nullptr;
    }

    return str;
}

// Asynchronous version of NAPI_Global_openProtocol
static napi_value NAPI_Global_openProtocol(napi_env env, napi_callback_info info) {
    OH_LOG_INFO(LOG_APP, "NAPI_Global_openProtocol: Entry (Async)");

    // --- 检查会话是否繁忙 ---
    bool expected_busy = false;
    if (!g_isSessionBusy.compare_exchange_strong(expected_busy, true)) {
        OH_LOG_WARN(LOG_APP, "NAPI_Global_openProtocol: Session is busy (connecting or disconnecting). Rejecting.");
        napi_deferred deferred_busy;
        napi_value promise_busy;
        napi_create_promise(env, &deferred_busy, &promise_busy);
        napi_value error_busy = CreateNapiError(env, "会话正在连接或关闭中，请稍后重试 (Session busy, try again later)");
        napi_reject_deferred(env, deferred_busy, error_busy);
        return promise_busy;
    }
    OH_LOG_INFO(LOG_APP, "NAPI_Global_openProtocol: Acquired busy lock.");

    // 1. Get input string argument
    auto str_ptr = getStringFromInfo(env, info);
    if (!str_ptr) {
        OH_LOG_ERROR(LOG_APP, "NAPI_Global_openProtocol: Failed to get input string.");
        OH_LOG_INFO(LOG_APP, "NAPI_Global_openProtocol: Releasing busy lock due to input string failure.");
        g_isSessionBusy.store(false);
        napi_value undefined_val;
        napi_get_undefined(env, &undefined_val);
        return undefined_val;
    }
    std::string napiInputStr = str_ptr.get();
    OH_LOG_INFO(LOG_APP, "NAPI_Global_openProtocol: Input received.");

    // 2. Create Promise and Deferred objects
    napi_deferred deferred;
    napi_value promise;
    napi_status status = napi_create_promise(env, &deferred, &promise);
    if (status != napi_ok) {
        OH_LOG_ERROR(LOG_APP, "NAPI_Global_openProtocol: Failed to create promise.");
        OH_LOG_INFO(LOG_APP, "NAPI_Global_openProtocol: Releasing busy lock due to promise creation failure.");
        g_isSessionBusy.store(false);
        napi_throw_error(env, nullptr, "Failed to create promise");
        return nullptr;
    }
    OH_LOG_INFO(LOG_APP, "NAPI_Global_openProtocol: Promise created.");

    // 3. Create async work data
    auto* workData = new OpenConnectWorkData();
    workData->napiInput = napiInputStr;
    workData->deferred = deferred;
    workData->success = false;

    // 4. Create async work
    napi_value resourceName;
    napi_create_string_utf8(env, "OpenProtocolAsync", NAPI_AUTO_LENGTH, &resourceName);

    status = napi_create_async_work(
        env,
        nullptr,
        resourceName,
        // Execute lambda (后台线程)
        [](napi_env env, void* data) {
            auto* wd = static_cast<OpenConnectWorkData*>(data);
            OH_LOG_INFO(LOG_APP, "OpenProtocolAsync Execute: Running in background thread.");

            OH_LOG_INFO(LOG_APP, "OpenProtocolAsync Execute: Calling C++ openProtocol...");
            try {
                wd->sessionId = openProtocol(wd->napiInput); // openProtocol返回sessionId
                wd->success = (wd->sessionId >= 0);
                OH_LOG_INFO(LOG_APP, "OpenProtocolAsync Execute: C++ openProtocol returned sessionId=%d", wd->sessionId);
                if (!wd->success) {
                    wd->errorMsg = "连接失败 (Connection failed in native code)";
                    OH_LOG_ERROR(LOG_APP, "OpenProtocolAsync Execute: C++ openProtocol failed.");
                }
            } catch (const std::exception& e) {
                wd->success = false;
                wd->errorMsg = std::string("连接异常 (Connection exception): ") + e.what();
                OH_LOG_ERROR(LOG_APP, "OpenProtocolAsync Execute: Exception during openProtocol: %s", e.what());
            } catch (...) {
                wd->success = false;
                wd->errorMsg = "连接时发生未知异常 (Unknown exception during connection)";
                OH_LOG_ERROR(LOG_APP, "OpenProtocolAsync Execute: Unknown exception during openProtocol.");
            }
            OH_LOG_INFO(LOG_APP, "OpenProtocolAsync Execute: Background work finished.");
        },
        // Complete lambda (JS 主线程)
        [](napi_env env, napi_status async_status, void* data) {
            auto* wd = static_cast<OpenConnectWorkData*>(data);
            OH_LOG_INFO(LOG_APP, "OpenProtocolAsync Complete: Running in JS thread. Success: %d", wd->success);

            OH_LOG_INFO(LOG_APP, "OpenProtocolAsync Complete: Releasing busy lock.");
            g_isSessionBusy.store(false);

            if (async_status != napi_ok) {
                OH_LOG_ERROR(LOG_APP, "OpenProtocolAsync Complete: Async work failed with status %d.", async_status);
                napi_value error = CreateNapiError(env, "异步操作失败或被取消 (Async operation failed or cancelled).");
                napi_reject_deferred(env, wd->deferred, error);
            } else {
                if (wd->success) {
                    OH_LOG_INFO(LOG_APP, "OpenProtocolAsync Complete: Resolving promise with sessionId=%d", wd->sessionId);
                    napi_value result;
                    napi_create_int32(env, wd->sessionId, &result);
                    napi_resolve_deferred(env, wd->deferred, result);
                } else {
                    OH_LOG_ERROR(LOG_APP, "OpenProtocolAsync Complete: Rejecting promise. Error: %s", wd->errorMsg.c_str());
                    napi_value error = CreateNapiError(env, wd->errorMsg.c_str());
                    napi_reject_deferred(env, wd->deferred, error);
                }
            }

            OH_LOG_INFO(LOG_APP, "OpenProtocolAsync Complete: Deleting async work.");
            napi_delete_async_work(env, wd->work);
            OH_LOG_INFO(LOG_APP, "OpenProtocolAsync Complete: Deleting work data.");
            delete wd;
            OH_LOG_INFO(LOG_APP, "OpenProtocolAsync Complete: Finished.");
        },
        workData,
        &workData->work
    );

    if (status != napi_ok) {
        OH_LOG_ERROR(LOG_APP, "NAPI_Global_openProtocol: Failed to create async work.");
        OH_LOG_INFO(LOG_APP, "NAPI_Global_openProtocol: Releasing busy lock due to async work creation failure.");
        g_isSessionBusy.store(false);
        delete workData;
        napi_value error = CreateNapiError(env, "无法创建异步连接任务 (Failed to create async connection task)");
        napi_reject_deferred(env, deferred, error);
        return promise;
    }

    // 5. Queue the async work
    status = napi_queue_async_work(env, workData->work);
    if (status != napi_ok) {
        OH_LOG_ERROR(LOG_APP, "NAPI_Global_openProtocol: Failed to queue async work.");
        OH_LOG_INFO(LOG_APP, "NAPI_Global_openProtocol: Releasing busy lock due to async work queueing failure.");
        g_isSessionBusy.store(false);
        napi_value error = CreateNapiError(env, "无法调度异步连接任务 (Failed to queue async connection task)");
        napi_reject_deferred(env, deferred, error);
    }
    OH_LOG_INFO(LOG_APP, "NAPI_Global_openProtocol: Async work queued.");

    // 6. Return the Promise to JS
    OH_LOG_INFO(LOG_APP, "NAPI_Global_openProtocol: Returning promise.");
    return promise;
}

// 数据回调结构体
struct CallbackData {
    int sessionId; // <-- 新增 sessionId
    std::string data;
    bool status;
};

// 用于 sendTerminalCommand 的异步工作数据结构
struct SendCommandWorkData {
    int sessionId; // 新增sessionId
    std::string command;
    bool success;
    std::string output; // 命令输出
    std::string errorMsg; // 可选的错误信息
    napi_async_work work;
    napi_deferred deferred; // 用于 Promise
};

// 前向声明SendDataToArkTS函数，解决"use of undeclared identifier"错误
void SendDataToArkTS(int sessionId, const std::string &data, bool status);

static napi_value NAPI_Global_sendTerminalCommand(napi_env env, napi_callback_info info) {
    OH_LOG_INFO(LOG_APP, "NAPI_Global_sendTerminalCommand: Entry");

    // 1. 获取命令参数
    size_t argc = 2;
    napi_value args[2];
    napi_status status = napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (status != napi_ok || argc < 2) {
        napi_throw_error(env, nullptr, "Expected two arguments (sessionId, command).");
        return nullptr;
    }

    int sessionId = SafeGetInt32FromNapi(env, args[0]);
    if (sessionId < 0) {
        napi_throw_type_error(env, nullptr, "Invalid sessionId.");
        return nullptr;
    }
    std::string commandStr = SafeGetStringFromNapi(env, args[1]);
    if (commandStr.empty()) { // 增加检查，虽然 SafeGetStringFromNapi 内部有日志，但这里可以更明确
        // 检查 args[1] 是否真的是字符串类型，如果不是，则抛出更合适的错误
        napi_valuetype type_command;
        napi_typeof(env, args[1], &type_command);
        if (type_command != napi_string) {
            OH_LOG_ERROR(LOG_APP, "NAPI_Global_sendTerminalCommand: Second argument (command) must be a string.");
            napi_throw_type_error(env, nullptr, "Second argument (command) must be a string.");
            return nullptr;
        }
        // 如果是空字符串，可能也是有效的（例如发送回车），所以只记录日志，不抛出错误
         OH_LOG_WARN(LOG_APP, "NAPI_Global_sendTerminalCommand: Received empty command string.");
    }
    OH_LOG_INFO(LOG_APP, "NAPI_Global_sendTerminalCommand: Command to send: %s", commandStr.c_str());

    // 2. 创建 Promise 和 Deferred 对象
    napi_deferred deferred;
    napi_value promise;
    status = napi_create_promise(env, &deferred, &promise);
    if (status != napi_ok) {
        OH_LOG_ERROR(LOG_APP, "NAPI_Global_sendTerminalCommand: Failed to create promise.");
        napi_throw_error(env, nullptr, "Failed to create promise");
        return nullptr;
    }
    OH_LOG_INFO(LOG_APP, "NAPI_Global_sendTerminalCommand: Promise created.");

    // 3. 创建异步工作数据
    auto* workData = new SendCommandWorkData();
    workData->sessionId = sessionId;
    workData->command = commandStr;
    workData->deferred = deferred;
    workData->success = false;

    // 4. 创建异步工作
    napi_value resourceName;
    napi_create_string_utf8(env, "SendCommandAsync", NAPI_AUTO_LENGTH, &resourceName);

    status = napi_create_async_work(
        env,
        nullptr,
        resourceName,
        // Execute lambda (后台线程)
        [](napi_env env, void* data) {
            auto* wd = static_cast<SendCommandWorkData*>(data);
            OH_LOG_INFO(LOG_APP, "SendCommandAsync Execute: Running in background thread.");

            auto session = sessionManager.getSession(wd->sessionId);
            // Add null check here
            if (!session) {
                wd->success = false;
                wd->errorMsg = "Session not found or handle is invalid (ID: " + std::to_string(wd->sessionId) + ")";
                OH_LOG_ERROR(LOG_APP, "SendCommandAsync Execute: %s", wd->errorMsg.c_str());
                return; // Exit early if session not found
            }
            // channel exec 模式：直接执行并取回输出（Xshell 同款，绕开回调链路）
            SshSession* sshSession = dynamic_cast<SshSession*>(session.get());
            if (sshSession) {
                try {
                    wd->output = sshSession->execCommand(wd->command, 15000);
                    wd->success = true;
                    OH_LOG_INFO(LOG_APP, "SendCommandAsync Execute: execCommand done, output %zu bytes", wd->output.length());
                } catch (const std::exception& e) {
                    wd->success = false;
                    wd->errorMsg = std::string("Exception during execCommand: ") + e.what();
                    OH_LOG_ERROR(LOG_APP, "SendCommandAsync Execute: Exception: %s", e.what());
                } catch (...) {
                    wd->success = false;
                    wd->errorMsg = "Unknown exception during execCommand.";
                    OH_LOG_ERROR(LOG_APP, "SendCommandAsync Execute: Unknown exception.");
                }
            } else {
                wd->success = false;
                wd->errorMsg = "Session is not SSH type";
                OH_LOG_ERROR(LOG_APP, "SendCommandAsync Execute: Session is not SSH type.");
            }
            OH_LOG_INFO(LOG_APP, "SendCommandAsync Execute: Background work finished.");
        },
        // Complete lambda (JS 主线程)
        [](napi_env env, napi_status async_status, void* data) {
            auto* wd = static_cast<SendCommandWorkData*>(data);
            OH_LOG_INFO(LOG_APP, "SendCommandAsync Complete: Running in JS thread. Success: %d", wd->success);

            if (async_status != napi_ok) {
                OH_LOG_ERROR(LOG_APP, "SendCommandAsync Complete: Async work failed with status %d.", async_status);
                napi_value error = CreateNapiError(env, "Async operation failed or was cancelled.");
                napi_reject_deferred(env, wd->deferred, error);
            } else {
                if (wd->success) {
                    OH_LOG_INFO(LOG_APP, "SendCommandAsync Complete: Resolving promise with output %zu bytes.", wd->output.length());
                    napi_value output_result;
                    napi_create_string_utf8(env, wd->output.c_str(), wd->output.size(), &output_result);
                    napi_resolve_deferred(env, wd->deferred, output_result);
                } else {
                    OH_LOG_ERROR(LOG_APP, "SendCommandAsync Complete: Rejecting promise. Error: %s", wd->errorMsg.c_str());
                    napi_value error = CreateNapiError(env, wd->errorMsg.c_str());
                    napi_reject_deferred(env, wd->deferred, error);
                }
            }

            OH_LOG_INFO(LOG_APP, "SendCommandAsync Complete: Deleting async work.");
            napi_delete_async_work(env, wd->work);
            OH_LOG_INFO(LOG_APP, "SendCommandAsync Complete: Deleting work data.");
            delete wd;
            OH_LOG_INFO(LOG_APP, "SendCommandAsync Complete: Finished.");
        },
        workData,
        &workData->work
    );

    if (status != napi_ok) {
        OH_LOG_ERROR(LOG_APP, "NAPI_Global_sendTerminalCommand: Failed to create async work.");
        delete workData;
        napi_throw_error(env, nullptr, "Failed to create async work");
        napi_value error = CreateNapiError(env, "Failed to create async work");
        napi_reject_deferred(env, deferred, error);
        return promise;
    }

    // 5. 启动异步工作
    status = napi_queue_async_work(env, workData->work);
    if (status != napi_ok) {
         OH_LOG_ERROR(LOG_APP, "NAPI_Global_sendTerminalCommand: Failed to queue async work.");
         napi_value error = CreateNapiError(env, "Failed to queue async work");
         napi_reject_deferred(env, deferred, error);
    }
    OH_LOG_INFO(LOG_APP, "NAPI_Global_sendTerminalCommand: Async work queued.");

    // 6. 返回 Promise 给 JS
    OH_LOG_INFO(LOG_APP, "NAPI_Global_sendTerminalCommand: Returning promise.");
    return promise;
}

// 添加新的工作数据结构
struct CloseConnectWorkData {
    int sessionId; // 新增sessionId
    bool success;
    std::string errorMsg;
    napi_async_work work;
    napi_deferred deferred;
};

// 修改 NAPI_Global_closeProtocol 函数
static napi_value NAPI_Global_closeProtocol(napi_env env, napi_callback_info info) {
    OH_LOG_INFO(LOG_APP, "NAPI_Global_closeProtocol: Entry (Async)");

    // 1. 获取sessionId参数
    size_t argc = 1;
    napi_value args[1];
    napi_status status = napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (status != napi_ok || argc < 1) {
        napi_throw_error(env, nullptr, "Expected one argument (sessionId).");
        return nullptr;
    }

    int sessionId = SafeGetInt32FromNapi(env, args[0]);
    if (sessionId < 0) {
        napi_throw_type_error(env, nullptr, "Invalid sessionId.");
        return nullptr;
    }

    // 2. 创建 Promise 和 Deferred 对象
    napi_deferred deferred;
    napi_value promise;
    status = napi_create_promise(env, &deferred, &promise);
    if (status != napi_ok) {
        OH_LOG_ERROR(LOG_APP, "NAPI_Global_closeProtocol: Failed to create promise.");
        napi_throw_error(env, nullptr, "Failed to create promise");
        return nullptr;
    }
    OH_LOG_INFO(LOG_APP, "NAPI_Global_closeProtocol: Promise created for sessionId=%d.", sessionId);

    // 注意：不再在此处设置 g_isSessionBusy，因为关闭单个会话不应阻塞其他会话的操作。
    // 底层的 closeConnect 应该处理好并发问题。如果需要防止对 *同一个* session ID 的并发关闭，
    // sessionManager 内部应该处理。
    // OH_LOG_INFO(LOG_APP, "NAPI_Global_closeProtocol: Setting session busy flag.");
    // g_isSessionBusy.store(true); // <-- REMOVED

    // --- 3. 移除此处的同步 NAPI 资源清理 ---
    // 这些全局资源不应在关闭单个会话时被清理
    // OH_LOG_INFO(LOG_APP, "NAPI_Global_closeProtocol: Starting synchronous NAPI resource cleanup.");
    // isCallbackValid = false; // <-- REMOVED
    //
    // if (tsfnCreated && tsfn != nullptr) { ... } // <-- REMOVED Block
    // else { ... }
    //
    // if (dataCallbackRef != nullptr) { ... } // <-- REMOVED Block
    // else { ... }
    // OH_LOG_INFO(LOG_APP, "NAPI_Global_closeProtocol: Synchronous NAPI cleanup finished."); // <-- REMOVED

    // 4. 创建异步工作数据
    auto workDataPtr = std::make_unique<CloseConnectWorkData>();
    workDataPtr->sessionId = sessionId;
    workDataPtr->deferred = deferred;
    workDataPtr->success = false;

    // 5. 创建异步工作
    napi_value resourceName;
    napi_create_string_utf8(env, "CloseProtocolAsync", NAPI_AUTO_LENGTH, &resourceName);

    CloseConnectWorkData* rawWorkData = workDataPtr.release();

    status = napi_create_async_work(
        env,
        nullptr,
        resourceName,
        // Execute lambda (后台线程)
        [](napi_env env, void* data) {
            CloseConnectWorkData* wd = static_cast<CloseConnectWorkData*>(data);
            OH_LOG_INFO(LOG_APP, "CloseProtocolAsync Execute: Running in background thread for sessionId=%{public}d.", wd->sessionId);

            try {
                OH_LOG_INFO(LOG_APP, "CloseProtocolAsync Execute: Calling C++ closeConnect for sessionId=%{public}d...", wd->sessionId);
                
                bool closeConnectResult = closeConnect(wd->sessionId); // 直接存储 closeConnect 的结果
                OH_LOG_INFO(LOG_APP, "CloseProtocolAsync Execute: C++ closeConnect function returned: %{public}d", closeConnectResult); // 单独打印 closeConnect 的结果
                
                wd->success = closeConnectResult; // 直接赋值
                OH_LOG_INFO(LOG_APP, "CloseProtocolAsync Execute: Assigned wd->success = %{public}d", wd->success); // 单独打印赋值后的 wd->success

                // bool closeConnectError = !closeConnect(wd->sessionId); // 旧逻辑
                // wd->success = !closeConnectError; // 旧逻辑
                // OH_LOG_INFO(LOG_APP, "CloseProtocolAsync Execute: C++ closeConnect for sessionId=%{public}d returned error=%{public}d, success=%{public}d", wd->sessionId, closeConnectError, wd->success); // 旧日志，移除

                if (!wd->success) {
                    wd->errorMsg = "关闭连接失败 (Failed to close connection in native code)";
                    OH_LOG_ERROR(LOG_APP, "CloseProtocolAsync Execute: closeConnect indicated failure (wd->success is false) for sessionId=%{public}d.", wd->sessionId);
                } else {
                    OH_LOG_INFO(LOG_APP, "CloseProtocolAsync Execute: closeConnect successful (wd->success is true) for sessionId=%{public}d.", wd->sessionId);
                }
            } catch (const std::exception& e) {
                wd->success = false; 
                wd->errorMsg = std::string("关闭连接时发生异常 (Exception during close): ") + e.what();
                OH_LOG_ERROR(LOG_APP, "CloseProtocolAsync Execute: Exception during closeConnect for sessionId=%{public}d: %{public}s", wd->sessionId, e.what());
            } catch (...) {
                wd->success = false; 
                wd->errorMsg = "关闭连接时发生未知异常 (Unknown exception during close)";
                OH_LOG_ERROR(LOG_APP, "CloseProtocolAsync Execute: Unknown exception during closeConnect for sessionId=%{public}d.", wd->sessionId);
            }
            OH_LOG_INFO(LOG_APP, "CloseProtocolAsync Execute: Background work finished for sessionId=%{public}d. Final wd->success = %{public}d", wd->sessionId, wd->success); // 添加最终状态日志
        },
        // Complete lambda (JS 主线程)
        [](napi_env env, napi_status async_status, void* data) {
            std::unique_ptr<CloseConnectWorkData> wd(static_cast<CloseConnectWorkData*>(data));
            OH_LOG_INFO(LOG_APP, "CloseProtocolAsync Complete: Running in JS thread for sessionId=%{public}d. Success: %{public}d", wd->sessionId, wd->success);

            // 注意：不再需要在这里释放 g_isSessionBusy
            // OH_LOG_INFO(LOG_APP, "CloseProtocolAsync Complete: Releasing busy lock.");
            // g_isSessionBusy.store(false); // <-- REMOVED

            if (async_status != napi_ok) {
                 OH_LOG_ERROR(LOG_APP, "CloseProtocolAsync Complete: Async work failed for sessionId=%d with status %d.", wd->sessionId, async_status);
                 napi_value error = CreateNapiError(env, "异步关闭操作失败或被取消 (Async close operation failed or cancelled).");
                 if (wd->deferred) {
                      napi_reject_deferred(env, wd->deferred, error);
                 } else {
                     OH_LOG_WARN(LOG_APP, "CloseProtocolAsync Complete: Deferred is null for sessionId=%d, cannot reject promise.", wd->sessionId);
                 }
            } else {
                 if (wd->deferred) {
                     if (wd->success) {
                         OH_LOG_INFO(LOG_APP, "CloseProtocolAsync Complete: Resolving promise with true for sessionId=%d.", wd->sessionId);
                         napi_value result_value;
                         napi_get_boolean(env, true, &result_value);
                         napi_resolve_deferred(env, wd->deferred, result_value);
                     } else {
                         OH_LOG_ERROR(LOG_APP, "CloseProtocolAsync Complete: Rejecting promise for sessionId=%d. Error: %s", wd->sessionId, wd->errorMsg.c_str());
                         napi_value error = CreateNapiError(env, wd->errorMsg.c_str());
                         napi_reject_deferred(env, wd->deferred, error);
                     }
                 } else {
                      OH_LOG_WARN(LOG_APP, "CloseProtocolAsync Complete: Deferred is null for sessionId=%d, cannot resolve/reject promise.", wd->sessionId);
                 }
            }

             OH_LOG_INFO(LOG_APP, "CloseProtocolAsync Complete: Deleting async work handle for sessionId=%d.", wd->sessionId);
             napi_delete_async_work(env, wd->work);

             OH_LOG_INFO(LOG_APP, "CloseProtocolAsync Complete: Finished for sessionId=%d.", wd->sessionId);
        },
        rawWorkData,
        &rawWorkData->work
    );

    if (status != napi_ok) {
        OH_LOG_ERROR(LOG_APP, "NAPI_Global_closeProtocol: Failed to create async work for sessionId=%d.", sessionId);
        // 注意：不再需要在这里释放 g_isSessionBusy
        // OH_LOG_INFO(LOG_APP, "NAPI_Global_closeProtocol: Releasing busy lock due to async work creation failure.");
        // g_isSessionBusy.store(false); // <-- REMOVED
        delete rawWorkData;
        napi_value error = CreateNapiError(env, "无法创建异步关闭任务 (Failed to create async close task)");
        napi_reject_deferred(env, deferred, error);
        return promise;
    }

    // 6. 将异步工作加入队列
    status = napi_queue_async_work(env, rawWorkData->work);
    if (status != napi_ok) {
         OH_LOG_ERROR(LOG_APP, "NAPI_Global_closeProtocol: Failed to queue async work for sessionId=%d.", sessionId);
         // 注意：不再需要在这里释放 g_isSessionBusy
         // OH_LOG_INFO(LOG_APP, "NAPI_Global_closeProtocol: Releasing busy lock due to async work queueing failure.");
         // g_isSessionBusy.store(false); // <-- REMOVED
         napi_value error = CreateNapiError(env, "无法调度异步关闭任务 (Failed to queue async close task)");
         napi_reject_deferred(env, deferred, error);
    } else {
        OH_LOG_INFO(LOG_APP, "NAPI_Global_closeProtocol: Async work queued for sessionId=%d.", sessionId);
    }


    // 7. 返回 Promise 给 JS
    OH_LOG_INFO(LOG_APP, "NAPI_Global_closeProtocol: Returning promise for sessionId=%d.", sessionId);
    return promise;
}

// 安全的线程间数据传输函数
void SendDataToArkTS(int sessionId, const std::string &data, bool status) {
    if (!tsfnCreated || tsfn == nullptr) {
        OH_LOG_ERROR(LOG_APP, "SendDataToArkTS: 线程安全函数未初始化");
        return;
    }

    // 创建 CallbackData 时包含 sessionId
    auto* callbackData = new CallbackData{sessionId, data, status};

    napi_status call_status = napi_call_threadsafe_function(tsfn, callbackData, napi_tsfn_nonblocking);
    if (call_status != napi_ok) {
        OH_LOG_ERROR(LOG_APP, "调用线程安全函数失败: %d", call_status);
        delete callbackData;
        if (call_status == napi_closing || call_status == napi_invalid_arg) {
             OH_LOG_WARN(LOG_APP, "SendDataToArkTS: TSFN is closing or invalid, cannot send data.");
        }
    }
}

static napi_value NAPI_Global_registerDataCallback(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_status status = napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (status != napi_ok || argc < 1) {
        napi_throw_error(env, nullptr, "Expected at least one argument (callback function).");
        return nullptr;
    }

    napi_valuetype valueType;
    status = napi_typeof(env, args[0], &valueType);
    if (status != napi_ok || valueType != napi_function) {
        napi_throw_type_error(env, nullptr, "Argument must be a function.");
        return nullptr;
    }

    mainEnv = env;

    if (mainLoop == nullptr) {
        napi_get_uv_event_loop(env, &mainLoop);
        if (mainLoop == nullptr) {
            napi_throw_error(env, nullptr, "Failed to get event loop.");
            return nullptr;
        }
    }

    if (tsfnCreated && tsfn != nullptr) {
        napi_release_threadsafe_function(tsfn, napi_tsfn_release);
        tsfn = nullptr;
        tsfnCreated = false;
    }

    if (dataCallbackRef != nullptr) {
        napi_delete_reference(env, dataCallbackRef);
        dataCallbackRef = nullptr;
    }

    status = napi_create_reference(env, args[0], 1, &dataCallbackRef);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to create reference for the callback.");
        return nullptr;
    }

    napi_value resource_name;
    status = napi_create_string_utf8(env, "terminalDataCallback", NAPI_AUTO_LENGTH, &resource_name);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to create resource name string.");
        return nullptr;
    }

    status = napi_create_threadsafe_function(
        env,
        args[0],
        nullptr,
        resource_name,
        0,
        1,
        nullptr,
        nullptr,
        nullptr,
        [](napi_env env, napi_value js_callback, void* context, void* data) {
            if (data == nullptr) {
                return;
            }

            auto* callbackData = static_cast<CallbackData*>(data);

            try {
                napi_value global = nullptr;
                // 使用 3 个参数：sessionId, data, status
                napi_value argv[3] = {nullptr, nullptr, nullptr};

                napi_get_global(env, &global);

                // 1. 创建 sessionId 参数
                napi_create_int32(env, callbackData->sessionId, &argv[0]);
                // 2. 创建 data 参数
                napi_create_string_utf8(env, callbackData->data.c_str(), callbackData->data.size(), &argv[1]);
                // 3. 创建 status 参数
                napi_get_boolean(env, callbackData->status, &argv[2]);

                napi_value result;
                // 传递 3 个参数给JS回调
                napi_status call_status = napi_call_function(env, global, js_callback, 3, argv, &result);
                if (call_status != napi_ok) {
                    OH_LOG_ERROR(LOG_APP, "Failed to call JS callback: %d", call_status);
                }
            } catch (...) {
                OH_LOG_ERROR(LOG_APP, "Exception in JS callback");
            }

            delete callbackData;
        },
        &tsfn
    );

    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to create threadsafe function.");
        return nullptr;
    }

    tsfnCreated = true;

    isCallbackValid = true; // Mark the TSFN as ready
    
    // 定义C++回调，它会调用 SendDataToArkTS
    auto globalCallback = [](int sessionId, const std::string& data, bool status) {
        SendDataToArkTS(sessionId, data, status);
    };
    
    try {
        // 1. 为将来的会话添加待处理回调
        sessionManager.addPendingDataCallback(globalCallback);
        OH_LOG_INFO(LOG_APP, "NAPI_Global_registerDataCallback: Added pending data callback for future sessions.");

        // 2. 为所有现有会话设置回调 (调用 SessionManager 的方法)
        //    (假设 SessionManager 提供了此方法)
        sessionManager.applyDataCallbackToExistingSessions(globalCallback);
        OH_LOG_INFO(LOG_APP, "NAPI_Global_registerDataCallback: Applied data callback to existing sessions via SessionManager.");

        // 移除旧的遍历逻辑:
        /* 
        for (int id = 0; id < 100; id++) { // 假设最多100个会话ID
            try {
                auto session = sessionManager.getSession(id);
                if (session) {
                    session->setDataCallbacks(globalCallback);
                    OH_LOG_INFO(LOG_APP, "注册回调到会话 ID=%d", id);
                }
            } catch (const std::exception&) {
                // 忽略不存在的会话ID
            }
        }
        */
    } catch (const std::exception& e) {
        OH_LOG_ERROR(LOG_APP, "NAPI_Global_registerDataCallback: Error setting data callback via SessionManager: %s", e.what());
        // 根据需要处理错误，例如向 JS 抛出异常或返回 false
        // 这里仅记录错误，与之前的行为保持一致
    }
    
    // 移除旧的为将来会话添加待处理回调的逻辑，因为它已移到 try 块中
    // sessionManager.addPendingDataCallback(globalCallback);

    napi_value result;
    napi_get_boolean(env, true, &result);
    return result;
}


// 添加日志设置函数
static napi_value SetLogging(napi_env env, napi_callback_info info) {
    OH_LOG_INFO(LOG_APP, "开始执行SetLogging函数");

    size_t argc = 3;  // sessionId, config, callback
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 3) {
        OH_LOG_ERROR(LOG_APP, "参数数量错误，期望3个参数，实际收到 %{public}zu 个参数", argc);
        napi_throw_type_error(env, nullptr, "需要3个参数: sessionId, config, callback");
        return nullptr;
    }

    int sessionId = SafeGetInt32FromNapi(env, args[0]);
    if (sessionId < 0) {
        napi_throw_type_error(env, nullptr, "Invalid sessionId.");
        return nullptr;
    }

    // 检查配置对象参数类型
    napi_valuetype configType;
    napi_typeof(env, args[1], &configType);
    if (configType != napi_object) {
        OH_LOG_ERROR(LOG_APP, "第二个参数必须是配置对象");
        napi_throw_type_error(env, nullptr, "第二个参数必须是配置对象");
        return nullptr;
    }

    // 检查回调函数参数类型
    napi_valuetype callbackType;
    napi_typeof(env, args[2], &callbackType);
    if (callbackType != napi_function) {
        OH_LOG_ERROR(LOG_APP, "第三个参数必须是回调函数");
        napi_throw_type_error(env, nullptr, "第三个参数必须是回调函数");
        return nullptr;
    }

    // 创建工作数据
    LoggingWorkData* workData = new LoggingWorkData();
    workData->sessionId = sessionId;

    // 从配置对象中解析参数
    napi_value config = args[1];
    
    // 获取 fd
    napi_value fdValue;
    napi_get_named_property(env, config, "fd", &fdValue);
    workData->fd = SafeGetInt32FromNapi(env, fdValue);

    // 获取 logType
    napi_value logTypeValue;
    napi_get_named_property(env, config, "logType", &logTypeValue);
    workData->logType = SafeGetInt32FromNapi(env, logTypeValue);

    // 获取 existOperation
    napi_value existOperationValue;
    napi_get_named_property(env, config, "existOperation", &existOperationValue);
    workData->existOperation = SafeGetInt32FromNapi(env, existOperationValue);

    // 获取新增的布尔配置项
    napi_value includeHeaderValue;
    napi_status includeHeaderStatus = napi_get_named_property(env, config, "includeHeader", &includeHeaderValue);
    if (includeHeaderStatus == napi_ok) {
        workData->includeHeader = SafeGetBoolFromNapi(env, includeHeaderValue, false);
        OH_LOG_INFO(LOG_APP, "获取includeHeader属性成功，值为: %{public}d", workData->includeHeader);
    } else {
        workData->includeHeader = false;
        OH_LOG_WARN(LOG_APP, "获取includeHeader属性失败，使用默认值false");
    }

    napi_value omitKnownPasswordValue;
    napi_status omitKnownPasswordStatus = napi_get_named_property(env, config, "omitKnownPassword", &omitKnownPasswordValue);
    if (omitKnownPasswordStatus == napi_ok) {
        workData->omitKnownPassword = SafeGetBoolFromNapi(env, omitKnownPasswordValue, false);
        OH_LOG_INFO(LOG_APP, "获取omitKnownPassword属性成功，值为: %{public}d", workData->omitKnownPassword);
    } else {
        workData->omitKnownPassword = false;
        OH_LOG_WARN(LOG_APP, "获取omitKnownPassword属性失败，使用默认值false");
    }

    napi_value omitSessionDataValue;
    napi_status omitSessionDataStatus = napi_get_named_property(env, config, "omitSessionData", &omitSessionDataValue);
    if (omitSessionDataStatus == napi_ok) {
        workData->omitSessionData = SafeGetBoolFromNapi(env, omitSessionDataValue, false);
        OH_LOG_INFO(LOG_APP, "获取omitSessionData属性成功，值为: %{public}d", workData->omitSessionData);
    } else {
        workData->omitSessionData = false;
        OH_LOG_WARN(LOG_APP, "获取omitSessionData属性失败，使用默认值false");
    }

    OH_LOG_INFO(LOG_APP, "设置日志参数: fd=%{public}d, logType=%{public}d, existOperation=%{public}d, includeHeader=%{public}d, omitKnownPassword=%{public}d, omitSessionData=%{public}d",
        workData->fd, workData->logType, workData->existOperation, 
        workData->includeHeader, workData->omitKnownPassword, workData->omitSessionData);

    // 保存回调函数引用
    napi_create_reference(env, args[2], 1, &workData->callback);

    // 创建异步工作
    napi_value resource_name;
    napi_create_string_utf8(env, "SetLogging", NAPI_AUTO_LENGTH, &resource_name);

    napi_create_async_work(
        env,
        nullptr,
        resource_name,
        // 执行函数（在工作线程中）
        [](napi_env env, void* data) {
            LoggingWorkData* workData = static_cast<LoggingWorkData*>(data);

            try {
                auto session = sessionManager.getSession(workData->sessionId);
                // Add null check here
                if (!session) {
                    workData->success = false;
                    workData->errorMsg = "找不到有效会话，会话ID: " + std::to_string(workData->sessionId);
                    OH_LOG_ERROR(LOG_APP, "SetLogging Execute: 找不到会话，ID=%d", workData->sessionId);
                    return; // Exit early
                }

                // --- 调用扩展的setLogging函数 ---
                OH_LOG_INFO(LOG_APP, "SetLogging Execute: 会话ID=%d, 正在调用session->setLogging...", workData->sessionId);
                workData->success = session->setLogging(
                    workData->fd,
                    workData->logType,
                    workData->existOperation,
                    workData->includeHeader,
                    workData->omitKnownPassword,
                    workData->omitSessionData
                );
                // ---------------------

                if (!workData->success) {
                    if (workData->errorMsg.empty()) {
                        workData->errorMsg = "在会话对象中设置日志记录失败 (ID: " + std::to_string(workData->sessionId) + ")";
                        OH_LOG_ERROR(LOG_APP, "SetLogging Execute: session->setLogging返回false，会话ID=%d", workData->sessionId);
                    }
                } else {
                    OH_LOG_INFO(LOG_APP, "SetLogging Execute: 成功设置日志，会话ID=%d", workData->sessionId);
                }
            } catch (const std::exception& e) {
                workData->success = false;
                workData->errorMsg = e.what();
                OH_LOG_ERROR(LOG_APP, "SetLogging Execute: Exception caught: %s", e.what());
            } catch (...) {
                workData->success = false;
                workData->errorMsg = "Unknown error while setting logging";
                OH_LOG_ERROR(LOG_APP, "SetLogging Execute: Unknown exception caught.");
            }
        },
        // 完成回调（在JS线程中）
        [](napi_env env, napi_status status, void* data) {
            LoggingWorkData* workData = static_cast<LoggingWorkData*>(data);

            // 调用回调
            napi_value callback, global, callResult;
            napi_get_reference_value(env, workData->callback, &callback);
            napi_get_global(env, &global);

            napi_value args[2];
            napi_get_boolean(env, workData->success, &args[0]);
            napi_create_string_utf8(env, workData->errorMsg.c_str(), NAPI_AUTO_LENGTH, &args[1]);

            napi_call_function(env, global, callback, 2, args, &callResult);

            // 清理资源
            napi_delete_reference(env, workData->callback);
            napi_delete_async_work(env, workData->work);
            delete workData;
        },
        workData,
        &workData->work
    );

    // 启动工作
    napi_queue_async_work(env, workData->work);

    return nullptr;
}

// 安全清理函数，确保所有资源在进程退出前被释放
static void CleanupResources() {
    OH_LOG_INFO(LOG_APP, "开始清理NAPI资源");

    try {
        // 标记回调无效
        isCallbackValid = false;

        // 清理目录跟踪相关资源
        {
            std::lock_guard<std::mutex> lock(g_directoryCallbackMutex);
            g_directoryCallbackRegistered = false;
            if (g_directoryChangeEnv && g_directoryChangeCallbackRef) {
                OH_LOG_INFO(LOG_APP, "CleanupResources: 清理目录变更回调引用");
                // 使用保存的环境清理引用
                napi_status delete_ref_status = napi_delete_reference(g_directoryChangeEnv, g_directoryChangeCallbackRef);
                 if (delete_ref_status != napi_ok) {
                     OH_LOG_ERROR(LOG_APP, "CleanupResources: 删除目录变更回调引用失败: %d", delete_ref_status);
                 }
                g_directoryChangeCallbackRef = nullptr;
            }
            // g_directoryChangeEnv = nullptr; // 在最后清理 mainEnv 时一起处理

            // 清理线程安全函数(如果存在) - 如果目录变更也用TSFN，则需要在这里清理
            // if (g_directoryChangeTsfn != nullptr) { ... }
        }
        // 注意: 如果使用了 uv_async_t，理论上关联的 uv_loop_t (mainLoop) 关闭时会自动处理，
        // 但确保在清理期间没有新的 uv_async_send 调用是重要的。

        // 释放会话管理器中的资源
        SessionManager::getInstance().clearPendingCallbacks();

        // 清理线程安全函数资源 (Terminal data TSFN)
        if (tsfnCreated && tsfn != nullptr) {
            OH_LOG_INFO(LOG_APP, "CleanupResources: 清理终端数据 TSFN");
            tsfnCreated = false;
            napi_release_threadsafe_function(tsfn, napi_tsfn_abort);
            tsfn = nullptr; // NAPI docs suggest setting to null after abort/release.
        } else {
             OH_LOG_INFO(LOG_APP, "CleanupResources: No Terminal data TSFN to clean.");
        }
        // Note: We might need to track and cleanup upload/download TSFNs if they could exist during cleanup


        // 如果环境有效，清理引用 (Terminal data callback ref)
        if (mainEnv != nullptr && dataCallbackRef != nullptr) {
            OH_LOG_INFO(LOG_APP, "CleanupResources: 清理终端数据回调引用");
             napi_status delete_status = napi_delete_reference(mainEnv, dataCallbackRef);
             if (delete_status != napi_ok) {
                 OH_LOG_ERROR(LOG_APP, "CleanupResources: Failed to delete terminal data callback reference: %d", delete_status);
             }
            dataCallbackRef = nullptr;
        } else {
            OH_LOG_INFO(LOG_APP, "CleanupResources: No terminal data callback reference to clean or env invalid.");
        }
        // Note: Need to cleanup upload/download callback refs if they exist


        // 确保释放全局环境引用
        mainEnv = nullptr; // 这个赋值会影响 dataCallbackRef 的清理
        g_directoryChangeEnv = nullptr; // 也清理目录变更环境引用
        mainLoop = nullptr;

        // --- 在所有其他清理之后调用 libssh2_exit ---
        OH_LOG_INFO(LOG_APP, "CleanupResources: 调用 libssh2_exit()");
        libssh2_exit();
        // ------------------------------------------

    } catch (const std::exception& e) {
        OH_LOG_ERROR(LOG_APP, "资源清理异常: %{public}s", e.what());
        // 在异常情况下也尝试调用 libssh2_exit
        OH_LOG_INFO(LOG_APP, "CleanupResources: 调用 libssh2_exit() (异常路径)");
        libssh2_exit();
    } catch (...) {
        OH_LOG_ERROR(LOG_APP, "资源清理时发生未知异常");
        // 在异常情况下也尝试调用 libssh2_exit
        OH_LOG_INFO(LOG_APP, "CleanupResources: 调用 libssh2_exit() (未知异常路径)");
        libssh2_exit();
    }

    OH_LOG_INFO(LOG_APP, "NAPI资源清理完成");
}

// 新增 NAPI 函数：ResizeTerminal
static napi_value ResizeTerminal(napi_env env, napi_callback_info info) {
    OH_LOG_INFO(LOG_APP, "NAPI_ResizeTerminal: Entry");

    // 1. 解析参数 (sessionId, width, height)
    size_t argc = 3;
    napi_value args[3];
    napi_status status = napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (status != napi_ok || argc < 3) {
        OH_LOG_ERROR(LOG_APP, "NAPI_ResizeTerminal: 参数数量不足 (需要 3 个)");
        napi_throw_type_error(env, nullptr, "需要 3 个参数: sessionId, width 和 height");
        return nullptr;
    }

    int sessionId = SafeGetInt32FromNapi(env, args[0]);
    if (sessionId < 0) {
        napi_throw_type_error(env, nullptr, "Invalid sessionId.");
        return nullptr;
    }

    // 检查参数类型
    napi_valuetype type_width, type_height;
    napi_typeof(env, args[1], &type_width);
    napi_typeof(env, args[2], &type_height);
    if (type_width != napi_number || type_height != napi_number) {
        OH_LOG_ERROR(LOG_APP, "NAPI_ResizeTerminal: 参数类型错误 (需要 number, number)");
        napi_throw_type_error(env, nullptr, "width 和 height 都必须是数字类型");
        return nullptr;
    }

    // 获取参数值
    int width_val, height_val;
    status = napi_get_value_int32(env, args[1], &width_val);
    if (status != napi_ok) {
        OH_LOG_ERROR(LOG_APP, "NAPI_ResizeTerminal: 获取 width 值失败");
        napi_throw_error(env, nullptr, "无法获取 width 参数的值");
        return nullptr;
    }
    status = napi_get_value_int32(env, args[2], &height_val);
    if (status != napi_ok) {
        OH_LOG_ERROR(LOG_APP, "NAPI_ResizeTerminal: 获取 height 值失败");
        napi_throw_error(env, nullptr, "无法获取 height 参数的值");
        return nullptr;
    }
    OH_LOG_INFO(LOG_APP, "NAPI_ResizeTerminal: 解析到参数 width=%{public}d, height=%{public}d", width_val, height_val);

    // 2. 创建 Promise 和 Deferred 对象
    napi_deferred deferred;
    napi_value promise;
    status = napi_create_promise(env, &deferred, &promise);
    if (status != napi_ok) {
        OH_LOG_ERROR(LOG_APP, "NAPI_ResizeTerminal: 创建 Promise 失败");
        napi_throw_error(env, nullptr, "无法创建 Promise");
        return nullptr; // 返回 null 或让错误传播
    }
    OH_LOG_INFO(LOG_APP, "NAPI_ResizeTerminal: Promise 已创建");

    // 3. 创建异步工作数据
    auto workDataPtr = std::make_unique<ResizeWorkData>();
    workDataPtr->sessionId = sessionId; // <-- Assign sessionId
    workDataPtr->width = width_val;
    workDataPtr->height = height_val;
    workDataPtr->deferred = deferred;
    workDataPtr->success = false; // 默认失败

    // 4. 创建异步工作
    napi_value resourceName;
    napi_create_string_utf8(env, "ResizeTerminalAsync", NAPI_AUTO_LENGTH, &resourceName);

    ResizeWorkData* rawWorkData = workDataPtr.release();

    status = napi_create_async_work(
        env,
        nullptr,
        resourceName,
        // Execute lambda (后台线程)
        [](napi_env env, void* data) {
            ResizeWorkData* wd = static_cast<ResizeWorkData*>(data);
            OH_LOG_INFO(LOG_APP, "ResizeTerminalAsync Execute: 在后台线程运行，调整大小为 %{public}dx%{public}d", wd->width, wd->height);

            auto session = sessionManager.getSession(wd->sessionId);
            // Add null check here
            if (!session) {
                wd->success = false;
                wd->errorMsg = "无法调整大小：找不到会话 (Session not found ID: " + std::to_string(wd->sessionId) + ")";
                OH_LOG_ERROR(LOG_APP, "ResizeTerminalAsync Execute: %{public}s", wd->errorMsg.c_str());
                return; // Exit early
            }

            try {
                // --- 直接调用虚函数 ---
                OH_LOG_INFO(LOG_APP, "ResizeTerminalAsync Execute: Calling session->resizeTerminal directly...");
                wd->success = session->resizeTerminal(wd->width, wd->height);
                // ---------------------
                if (!wd->success) {
                     // 可以保留之前的错误信息生成逻辑，但不需要检查类型了
                     wd->errorMsg = "原生代码调整终端大小失败 (Failed to resize terminal in native code)";
                     // 可以在子类实现中设置更具体的错误信息
                }
            } catch (const std::exception& e) {
                wd->success = false;
                wd->errorMsg = std::string("调整大小时发生异常 (Exception during resize): ") + e.what();
                OH_LOG_ERROR(LOG_APP, "ResizeTerminalAsync Execute: %{public}s", wd->errorMsg.c_str());
            } catch (...) {
                wd->success = false;
                wd->errorMsg = "调整大小时发生未知异常 (Unknown exception during resize)";
                OH_LOG_ERROR(LOG_APP, "ResizeTerminalAsync Execute: %{public}s", wd->errorMsg.c_str());
            }
            OH_LOG_INFO(LOG_APP, "ResizeTerminalAsync Execute: 后台工作完成");
        },
        // Complete lambda (JS 主线程)
        [](napi_env env, napi_status async_status, void* data) {
            std::unique_ptr<ResizeWorkData> wd(static_cast<ResizeWorkData*>(data));
            OH_LOG_INFO(LOG_APP, "ResizeTerminalAsync Complete: 在 JS 线程运行。成功: %{public}d", wd->success);

            if (async_status != napi_ok) {
                OH_LOG_ERROR(LOG_APP, "ResizeTerminalAsync Complete: 异步工作失败，状态码 %{public}d", async_status);
                napi_value error = CreateNapiError(env, "异步调整大小操作失败或被取消 (Async resize operation failed or cancelled)");
                napi_reject_deferred(env, wd->deferred, error);
            } else {
                if (wd->success) {
                    OH_LOG_INFO(LOG_APP, "ResizeTerminalAsync Complete: 解析 Promise 为 true");
                    napi_value result_value;
                    napi_get_boolean(env, true, &result_value);
                    napi_resolve_deferred(env, wd->deferred, result_value);
                } else {
                    OH_LOG_ERROR(LOG_APP, "ResizeTerminalAsync Complete: 拒绝 Promise。错误: %{public}s", wd->errorMsg.c_str());
                    napi_value error = CreateNapiError(env, wd->errorMsg.c_str());
                    napi_reject_deferred(env, wd->deferred, error);
                }
            }

             OH_LOG_INFO(LOG_APP, "ResizeTerminalAsync Complete: 删除 async work 句柄");
             napi_delete_async_work(env, wd->work);

            OH_LOG_INFO(LOG_APP, "ResizeTerminalAsync Complete: 完成");
        },
        rawWorkData,
        &rawWorkData->work
    );

    if (status != napi_ok) {
        OH_LOG_ERROR(LOG_APP, "NAPI_ResizeTerminal: 创建异步工作失败");
        delete rawWorkData;
        napi_value error = CreateNapiError(env, "无法创建异步调整大小任务 (Failed to create async resize task)");
        napi_reject_deferred(env, deferred, error);
        return promise;
    }

    // 5. 将异步工作加入队列
    status = napi_queue_async_work(env, rawWorkData->work);
    if (status != napi_ok) {
         OH_LOG_ERROR(LOG_APP, "NAPI_ResizeTerminal: 无法将异步工作加入队列");
         napi_value error = CreateNapiError(env, "无法调度异步调整大小任务 (Failed to queue async resize task)");
         napi_reject_deferred(env, deferred, error);
    }
    OH_LOG_INFO(LOG_APP, "NAPI_ResizeTerminal: 异步工作已加入队列");

    // 6. 返回 Promise 给 JS
    OH_LOG_INFO(LOG_APP, "NAPI_ResizeTerminal: 返回 Promise");
    return promise;
}

// --- 新增: NAPI 密钥生成函数 (Async with Promise) ---
static napi_value NAPI_GenerateKeyPairToFile(napi_env env, napi_callback_info info) {
    OH_LOG_INFO(LOG_APP, "NAPI_GenerateKeyPairToFile: Entry");
    napi_status status;

    // 1. 解析参数 (algorithm: string, password?: string, privateFd: number, publicFd: number)
    size_t argc = 4;
    napi_value args[4];
    status = napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (status != napi_ok || argc < 4) {
        OH_LOG_ERROR(LOG_APP, "NAPI_GenerateKeyPairToFile: 需要 4 个参数 (algorithm, password, privateFd, publicFd)");
        napi_throw_type_error(env, nullptr, "需要 4 个参数: algorithm (string), password (string, 可空), privateFd (number), publicFd (number)");
        return nullptr;
    }

    // 验证参数类型
    napi_valuetype type_alg, type_pass, type_privFd, type_pubFd;
    napi_typeof(env, args[0], &type_alg);
    napi_typeof(env, args[1], &type_pass);
    napi_typeof(env, args[2], &type_privFd);
    napi_typeof(env, args[3], &type_pubFd);

    if (type_alg != napi_string || (type_pass != napi_string && type_pass != napi_null && type_pass != napi_undefined) || type_privFd != napi_number || type_pubFd != napi_number) {
        OH_LOG_ERROR(LOG_APP, "NAPI_GenerateKeyPairToFile: 参数类型错误");
        napi_throw_type_error(env, nullptr, "参数类型错误: (string, string|null|undefined, number, number)");
        return nullptr;
    }

    // 2. 创建 Promise
    napi_deferred deferred;
    napi_value promise;
    status = napi_create_promise(env, &deferred, &promise);
    if (status != napi_ok) {
        OH_LOG_ERROR(LOG_APP, "NAPI_GenerateKeyPairToFile: 创建 Promise 失败");
        napi_throw_error(env, nullptr, "无法创建 Promise");
        return nullptr;
    }

    // 3. 创建并填充异步工作数据
    auto workData = std::make_unique<GenerateKeyWorkData>();
    workData->algorithm = SafeGetStringFromNapi(env, args[0]);
    workData->password = (type_pass == napi_string) ? SafeGetStringFromNapi(env, args[1]) : ""; // Handle null/undefined password
    workData->private_key_fd = SafeGetInt32FromNapi(env, args[2]);
    workData->public_key_fd = SafeGetInt32FromNapi(env, args[3]);
    workData->deferred = deferred;

    if (workData->private_key_fd < 0 || workData->public_key_fd < 0) {
         OH_LOG_ERROR(LOG_APP, "NAPI_GenerateKeyPairToFile: 无效的文件描述符 (fd < 0)");
         napi_value error = CreateNapiError(env, "无效的文件描述符 (fd < 0)");
         napi_reject_deferred(env, deferred, error);
         return promise; // Return the rejected promise
    }

    OH_LOG_INFO(LOG_APP, "NAPI_GenerateKeyPairToFile: Alg=%s, PrivFD=%d, PubFD=%d",
                workData->algorithm.c_str(), workData->private_key_fd, workData->public_key_fd);

    // 4. 创建异步工作
    napi_value resourceName;
    napi_create_string_utf8(env, "GenerateKeyPairAsync", NAPI_AUTO_LENGTH, &resourceName);

    GenerateKeyWorkData* rawWorkData = workData.release(); // Release unique_ptr to pass raw pointer

    status = napi_create_async_work(
        env, nullptr, resourceName,
        // Execute (Background Thread)
        [](napi_env env, void* data) {
            GenerateKeyWorkData* wd = static_cast<GenerateKeyWorkData*>(data);
            OH_LOG_INFO(LOG_APP, "GenerateKeyPairAsync Execute: 在后台线程生成密钥...");
            // 调用 C++ 密钥生成函数
            wd->result = generate_key_pair_to_fd(
                wd->algorithm,
                wd->password,
                wd->private_key_fd,
                wd->public_key_fd,
                wd->key_bits
            );
            OH_LOG_INFO(LOG_APP, "GenerateKeyPairAsync Execute: C++ 函数返回 success=%d", wd->result.success);
        },
        // Complete (JS Thread)
        [](napi_env env, napi_status async_status, void* data) {
            std::unique_ptr<GenerateKeyWorkData> wd(static_cast<GenerateKeyWorkData*>(data)); // Reclaim ownership
            OH_LOG_INFO(LOG_APP, "GenerateKeyPairAsync Complete: 在 JS 线程处理结果, async_status=%d", async_status);

            if (async_status != napi_ok) {
                OH_LOG_ERROR(LOG_APP, "GenerateKeyPairAsync Complete: 异步工作本身失败");
                napi_value error = CreateNapiError(env, "密钥生成异步任务失败");
                napi_reject_deferred(env, wd->deferred, error);
            } else if (wd->result.success) {
                OH_LOG_INFO(LOG_APP, "GenerateKeyPairAsync Complete: 密钥生成成功, 解析 Promise");
                napi_value success_value;
                napi_get_boolean(env, true, &success_value);
                napi_resolve_deferred(env, wd->deferred, success_value);
            } else {
                 OH_LOG_ERROR(LOG_APP, "GenerateKeyPairAsync Complete: 密钥生成失败: %s", wd->result.error_message.c_str());
                napi_value error = CreateNapiError(env, wd->result.error_message.c_str());
                    napi_reject_deferred(env, wd->deferred, error);
                }
            // 清理 async work handle
            napi_delete_async_work(env, wd->work);
             OH_LOG_INFO(LOG_APP, "GenerateKeyPairAsync Complete: 清理完毕");
            // unique_ptr wd is automatically deleted here
        },
        rawWorkData, &rawWorkData->work);

    if (status != napi_ok) {
        OH_LOG_ERROR(LOG_APP, "NAPI_GenerateKeyPairToFile: 创建异步工作失败");
        delete rawWorkData;
        napi_value error = CreateNapiError(env, "无法创建密钥生成异步任务");
        napi_reject_deferred(env, deferred, error);
        return promise;
    }

    // 5. 加入队列
    status = napi_queue_async_work(env, rawWorkData->work);
    if (status != napi_ok) {
        OH_LOG_ERROR(LOG_APP, "NAPI_GenerateKeyPairToFile: 无法将异步工作加入队列");
        // Don't delete rawWorkData here, Complete callback will handle it
        napi_value error = CreateNapiError(env, "无法调度密钥生成异步任务");
         napi_reject_deferred(env, deferred, error);
    }
    OH_LOG_INFO(LOG_APP, "NAPI_GenerateKeyPairToFile: 异步工作已加入队列");

    // 6. 返回 Promise
    return promise;
}

// --- 新增: NAPI 密钥解密函数 (Async with Promise) ---
static napi_value NAPI_DecryptPrivateKeyFromFile(napi_env env, napi_callback_info info) {
     OH_LOG_INFO(LOG_APP, "NAPI_DecryptPrivateKeyFromFile: Entry");
    napi_status status;

    // 1. 解析参数 (privateKeyFd: number, password: string)
    size_t argc = 2;
    napi_value args[2];
    status = napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
     if (status != napi_ok || argc < 2) {
        OH_LOG_ERROR(LOG_APP, "NAPI_DecryptPrivateKeyFromFile: 需要 2 个参数 (privateKeyFd, password)");
        napi_throw_type_error(env, nullptr, "需要 2 个参数: privateKeyFd (number), password (string)");
        return nullptr;
    }

    // 验证参数类型
    napi_valuetype type_fd, type_pass;
    napi_typeof(env, args[0], &type_fd);
    napi_typeof(env, args[1], &type_pass);

     if (type_fd != napi_number || type_pass != napi_string) {
         OH_LOG_ERROR(LOG_APP, "NAPI_DecryptPrivateKeyFromFile: 参数类型错误");
        napi_throw_type_error(env, nullptr, "参数类型错误: (number, string)");
        return nullptr;
    }

    // 2. 创建 Promise
    napi_deferred deferred;
    napi_value promise;
    status = napi_create_promise(env, &deferred, &promise);
    if (status != napi_ok) {
        OH_LOG_ERROR(LOG_APP, "NAPI_DecryptPrivateKeyFromFile: 创建 Promise 失败");
        napi_throw_error(env, nullptr, "无法创建 Promise");
        return nullptr;
    }

    // 3. 创建并填充异步工作数据
    auto workData = std::make_unique<DecryptKeyWorkData>();
    workData->private_key_fd = SafeGetInt32FromNapi(env, args[0]);
    workData->password = SafeGetStringFromNapi(env, args[1]);
    workData->deferred = deferred;

     if (workData->private_key_fd < 0) {
         OH_LOG_ERROR(LOG_APP, "NAPI_DecryptPrivateKeyFromFile: 无效的文件描述符 (fd < 0)");
         napi_value error = CreateNapiError(env, "无效的文件描述符 (fd < 0)");
         napi_reject_deferred(env, deferred, error);
         return promise;
    }
    if (workData->password.empty()) {
        OH_LOG_ERROR(LOG_APP, "NAPI_DecryptPrivateKeyFromFile: 解密密码不能为空");
        napi_value error = CreateNapiError(env, "解密密码不能为空");
        napi_reject_deferred(env, deferred, error);
        return promise;
    }
    OH_LOG_INFO(LOG_APP, "NAPI_DecryptPrivateKeyFromFile: PrivFD=%d", workData->private_key_fd);


    // 4. 创建异步工作
    napi_value resourceName;
    napi_create_string_utf8(env, "DecryptKeyAsync", NAPI_AUTO_LENGTH, &resourceName);

    DecryptKeyWorkData* rawWorkData = workData.release(); // Release unique_ptr

    status = napi_create_async_work(
        env, nullptr, resourceName,
        // Execute (Background Thread)
        [](napi_env env, void* data) {
            DecryptKeyWorkData* wd = static_cast<DecryptKeyWorkData*>(data);
             OH_LOG_INFO(LOG_APP, "DecryptKeyAsync Execute: 在后台线程解密密钥...");
            wd->result = decrypt_private_key_from_fd(wd->private_key_fd, wd->password);
            OH_LOG_INFO(LOG_APP, "DecryptKeyAsync Execute: C++ 函数返回 success=%d", wd->result.success);
        },
        // Complete (JS Thread)
        [](napi_env env, napi_status async_status, void* data) {
             std::unique_ptr<DecryptKeyWorkData> wd(static_cast<DecryptKeyWorkData*>(data)); // Reclaim ownership
            OH_LOG_INFO(LOG_APP, "DecryptKeyAsync Complete: 在 JS 线程处理结果, async_status=%{public}d", async_status);

             if (async_status != napi_ok) {
                OH_LOG_ERROR(LOG_APP, "DecryptKeyAsync Complete: 异步工作本身失败");
                napi_value error = CreateNapiError(env, "密钥解密异步任务失败");
                napi_reject_deferred(env, wd->deferred, error);
            } else if (wd->result.success) {
                 OH_LOG_INFO(LOG_APP, "DecryptKeyAsync Complete: 密钥解密成功, 解析 Promise");
                napi_value decrypted_pem_string;
                napi_create_string_utf8(env, wd->result.decrypted_pem.c_str(), wd->result.decrypted_pem.length(), &decrypted_pem_string);
                napi_resolve_deferred(env, wd->deferred, decrypted_pem_string);
            } else {
                OH_LOG_ERROR(LOG_APP, "DecryptKeyAsync Complete: 密钥解密失败: %{public}s", wd->result.error_message.c_str());
                napi_value error = CreateNapiError(env, wd->result.error_message.c_str());
                napi_reject_deferred(env, wd->deferred, error);
            }
             napi_delete_async_work(env, wd->work);
            OH_LOG_INFO(LOG_APP, "DecryptKeyAsync Complete: 清理完毕");
        },
        rawWorkData, &rawWorkData->work);

    if (status != napi_ok) {
        OH_LOG_ERROR(LOG_APP, "NAPI_DecryptPrivateKeyFromFile: 创建异步工作失败");
        delete rawWorkData;
        napi_value error = CreateNapiError(env, "无法创建密钥解密异步任务");
        napi_reject_deferred(env, deferred, error);
        return promise;
    }

    // 5. 加入队列
    status = napi_queue_async_work(env, rawWorkData->work);
     if (status != napi_ok) {
        OH_LOG_ERROR(LOG_APP, "NAPI_DecryptPrivateKeyFromFile: 无法将异步工作加入队列");
        napi_value error = CreateNapiError(env, "无法调度密钥解密异步任务");
        napi_reject_deferred(env, deferred, error);
    }
     OH_LOG_INFO(LOG_APP, "NAPI_DecryptPrivateKeyFromFile: 异步工作已加入队列");

    // 6. 返回 Promise
    return promise;
}

// --- 添加目录跟踪功能接口实现 ---
static napi_value NAPI_EnableDirectoryTracking(napi_env env, napi_callback_info info) {
    OH_LOG_INFO(LOG_APP, "NAPI_EnableDirectoryTracking: Entry");

    // 1. 解析参数 (sessionId, enable: boolean)
    size_t argc = 2;
    napi_value args[2];
    napi_status status = napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (status != napi_ok || argc < 2) {
        OH_LOG_ERROR(LOG_APP, "NAPI_EnableDirectoryTracking: 参数不足");
        napi_throw_type_error(env, nullptr, "需要两个参数: sessionId 和布尔参数表示是否启用目录跟踪");
        return nullptr;
    }

    int sessionId = SafeGetInt32FromNapi(env, args[0]);
    if (sessionId < 0) {
        napi_throw_type_error(env, nullptr, "Invalid sessionId.");
        return nullptr;
    }

    // 检查参数类型
    napi_valuetype valuetype;
    napi_typeof(env, args[1], &valuetype);
    if (valuetype != napi_boolean) {
        OH_LOG_ERROR(LOG_APP, "NAPI_EnableDirectoryTracking: 参数类型错误");
        napi_throw_type_error(env, nullptr, "参数必须是布尔类型");
        return nullptr;
    }

    // 获取布尔值
    bool enable_value;
    napi_get_value_bool(env, args[1], &enable_value);
    OH_LOG_INFO(LOG_APP, "NAPI_EnableDirectoryTracking: enable=%d", enable_value);

    // 2. 创建 Promise
    napi_deferred deferred;
    napi_value promise;
    status = napi_create_promise(env, &deferred, &promise);
    if (status != napi_ok) {
        OH_LOG_ERROR(LOG_APP, "NAPI_EnableDirectoryTracking: 创建 Promise 失败");
        napi_throw_error(env, nullptr, "无法创建 Promise");
        return nullptr;
    }

    // 3. 创建异步工作数据
    auto workData = std::make_unique<DirectoryTrackingWorkData>();
    workData->sessionId = sessionId; // <-- Assign sessionId
    workData->enable = enable_value;
    workData->deferred = deferred;
    workData->success = false;

    // 4. 创建异步工作
    napi_value resourceName;
    napi_create_string_utf8(env, "EnableDirectoryTrackingAsync", NAPI_AUTO_LENGTH, &resourceName);

    DirectoryTrackingWorkData* rawWorkData = workData.release();

    status = napi_create_async_work(
        env, nullptr, resourceName,
        // Execute (后台线程)
        [](napi_env env, void* data) {
            DirectoryTrackingWorkData* wd = static_cast<DirectoryTrackingWorkData*>(data);
            OH_LOG_INFO(LOG_APP, "EnableDirectoryTrackingAsync Execute: 在后台线程运行...");

            auto session = sessionManager.getSession(wd->sessionId);
            // Add null check here
            if (!session) {
                wd->success = false;
                wd->errorMsg = "无法启用目录跟踪：找不到会话 (Session not found ID: " + std::to_string(wd->sessionId) + ")";
                OH_LOG_ERROR(LOG_APP, "EnableDirectoryTrackingAsync Execute: %s", wd->errorMsg.c_str());
                return; // Exit early
            }

            try {
                SshSession* sshSession = dynamic_cast<SshSession*>(session.get());
                if (sshSession) {
                    OH_LOG_INFO(LOG_APP, "EnableDirectoryTrackingAsync Execute: 检测到SSH会话");
                    wd->success = sshSession->enableDirectoryTracking(wd->enable);
                    if (!wd->success) {
                        wd->errorMsg = "SSH会话启用目录跟踪失败";
                    }
                } else {
                    wd->success = false;
                    wd->errorMsg = "当前会话不是SSH会话，不支持目录跟踪";
                    OH_LOG_ERROR(LOG_APP, "EnableDirectoryTrackingAsync Execute: %s", wd->errorMsg.c_str());
                }
            } catch (const std::exception& e) {
                wd->success = false;
                wd->errorMsg = std::string("启用目录跟踪时发生异常: ") + e.what();
                OH_LOG_ERROR(LOG_APP, "EnableDirectoryTrackingAsync Execute: %s", wd->errorMsg.c_str());
            } catch (...) {
                wd->success = false;
                wd->errorMsg = "启用目录跟踪时发生未知异常";
                OH_LOG_ERROR(LOG_APP, "EnableDirectoryTrackingAsync Execute: %s", wd->errorMsg.c_str());
            }
            OH_LOG_INFO(LOG_APP, "EnableDirectoryTrackingAsync Execute: 后台工作完成");
        },
        // Complete (JS线程)
        [](napi_env env, napi_status async_status, void* data) {
            std::unique_ptr<DirectoryTrackingWorkData> wd(static_cast<DirectoryTrackingWorkData*>(data));
            OH_LOG_INFO(LOG_APP, "EnableDirectoryTrackingAsync Complete: 在JS线程处理结果, success=%d", wd->success);

            if (async_status != napi_ok) {
                OH_LOG_ERROR(LOG_APP, "EnableDirectoryTrackingAsync Complete: 异步工作失败");
                napi_value error = CreateNapiError(env, "目录跟踪异步任务失败");
                napi_reject_deferred(env, wd->deferred, error);
            } else if (wd->success) {
                OH_LOG_INFO(LOG_APP, "EnableDirectoryTrackingAsync Complete: 成功设置目录跟踪状态");
                napi_value result;
                napi_get_boolean(env, true, &result);
                napi_resolve_deferred(env, wd->deferred, result);
            } else {
                OH_LOG_ERROR(LOG_APP, "EnableDirectoryTrackingAsync Complete: 设置目录跟踪失败: %s", wd->errorMsg.c_str());
                napi_value error = CreateNapiError(env, wd->errorMsg.c_str());
                napi_reject_deferred(env, wd->deferred, error);
            }

            napi_delete_async_work(env, wd->work);
            OH_LOG_INFO(LOG_APP, "EnableDirectoryTrackingAsync Complete: 清理完毕");
        },
        rawWorkData, &rawWorkData->work);

    if (status != napi_ok) {
        OH_LOG_ERROR(LOG_APP, "NAPI_EnableDirectoryTracking: 创建异步工作失败");
        delete rawWorkData;
        napi_value error = CreateNapiError(env, "无法创建目录跟踪异步任务");
        napi_reject_deferred(env, deferred, error);
        return promise;
    }

    // 5. 启动异步工作
    status = napi_queue_async_work(env, rawWorkData->work);
    if (status != napi_ok) {
        OH_LOG_ERROR(LOG_APP, "NAPI_EnableDirectoryTracking: 无法将异步工作加入队列");
        napi_value error = CreateNapiError(env, "无法调度目录跟踪异步任务");
        napi_reject_deferred(env, deferred, error);
    }
    OH_LOG_INFO(LOG_APP, "NAPI_EnableDirectoryTracking: 异步工作已加入队列");

    // 6. 返回Promise
    return promise;
}

// 内部回调函数，用于传递给SshSession (修改)
// 这个函数现在需要知道 sessionId
// 注意：这个函数本身如何被调用以及如何获取 sessionId 取决于 SshSession 的内部实现
// 这里我们假设调用它的地方能够提供 sessionId
static void OnDirectoryChange(int sessionId, const std::string& directory) {
    OH_LOG_INFO(LOG_APP, "OnDirectoryChange: Session %d 目录变更为 %s", sessionId, directory.c_str());

    std::lock_guard<std::mutex> lock(g_directoryCallbackMutex);

    if (!g_directoryCallbackRegistered || !g_directoryChangeCallbackRef || !g_directoryChangeEnv || !mainLoop) {
        OH_LOG_WARN(LOG_APP, "OnDirectoryChange: 回调未注册, 环境无效, 或事件循环丢失 (Session %d)", sessionId);
        return;
    }

    // 创建工作数据并发送到主线程 (包含 sessionId)
    auto* callbackData = new DirectoryChangeNotifyData{
        sessionId, // <-- 传递 sessionId
        directory,
        g_directoryChangeCallbackRef // 全局回调引用
    };

    // 使用 uv_async_t 在主线程中调用回调
    uv_async_t* async = new uv_async_t;
    if (!async) {
        OH_LOG_ERROR(LOG_APP, "OnDirectoryChange: 无法分配 uv_async_t (Session %d)", sessionId);
        delete callbackData;
        return;
    }
    async->data = callbackData;

    int init_status = uv_async_init(mainLoop, async, [](uv_async_t* handle) {
        auto* data = static_cast<DirectoryChangeNotifyData*>(handle->data);

        // 在 uv 回调内部加锁可能不是最佳实践，但鉴于我们要访问全局环境和引用，这里暂时保留
        // 更好的方法可能是使用 NAPI 线程安全函数 (TSFN)
        std::lock_guard<std::mutex> lock(g_directoryCallbackMutex);

        napi_env current_env = g_directoryChangeEnv; // 使用保存的环境

        if (!data) {
            OH_LOG_ERROR(LOG_APP, "Directory callback: 回调数据为空");
            uv_close((uv_handle_t*)handle, [](uv_handle_t* h) { delete (uv_async_t*)h; });
            return;
        }

        if (!current_env || !data->callbackRef) {
            OH_LOG_ERROR(LOG_APP, "Directory callback: 环境或回调引用无效 (Session %d)", data->sessionId);
            delete data;
            uv_close((uv_handle_t*)handle, [](uv_handle_t* h) { delete (uv_async_t*)h; });
            return;
        }

        // 获取 JS 回调函数
        napi_value global, callback, callResult;
        napi_status status = napi_get_global(current_env, &global);
        if (status != napi_ok) {
             OH_LOG_ERROR(LOG_APP, "Directory callback: 获取 global 对象失败 (Session %d)", data->sessionId);
             delete data;
             uv_close((uv_handle_t*)handle, [](uv_handle_t* h) { delete (uv_async_t*)h; });
             return;
        }
        status = napi_get_reference_value(current_env, data->callbackRef, &callback);
         if (status != napi_ok) {
             OH_LOG_ERROR(LOG_APP, "Directory callback: 获取回调函数引用值失败 (Session %d)", data->sessionId);
             delete data;
             uv_close((uv_handle_t*)handle, [](uv_handle_t* h) { delete (uv_async_t*)h; });
             return;
         }

        // 准备参数 (sessionId, directory)
        napi_value argv[2] = {nullptr, nullptr};
        status = napi_create_int32(current_env, data->sessionId, &argv[0]);
        if (status != napi_ok) {
             OH_LOG_ERROR(LOG_APP, "Directory callback: 创建 sessionId 参数失败 (Session %d)", data->sessionId);
             delete data;
             uv_close((uv_handle_t*)handle, [](uv_handle_t* h) { delete (uv_async_t*)h; });
             return;
        }
        status = napi_create_string_utf8(current_env, data->directory.c_str(),
                                         NAPI_AUTO_LENGTH, &argv[1]);
        if (status != napi_ok) {
            OH_LOG_ERROR(LOG_APP, "Directory callback: 创建 directory 参数失败 (Session %d)", data->sessionId);
            delete data;
            uv_close((uv_handle_t*)handle, [](uv_handle_t* h) { delete (uv_async_t*)h; });
            return;
        }


        // 调用 JS 回调 (传递 sessionId 和 directory)
        napi_status call_status = napi_call_function(current_env, global, callback, 2, argv, &callResult);
        if (call_status != napi_ok) {
            // 检查是否是异常挂起
             bool is_exception_pending = false;
             napi_is_exception_pending(current_env, &is_exception_pending);
             if (is_exception_pending) {
                 napi_value exception;
                 napi_get_and_clear_last_exception(current_env, &exception);
                 // 可以尝试获取异常信息并记录，但NAPI操作可能再次失败
                 OH_LOG_ERROR(LOG_APP, "Directory callback: 调用JS回调时发生异常 (Session %d)", data->sessionId);
             } else {
                 OH_LOG_ERROR(LOG_APP, "Directory callback: 调用JS回调失败，状态码: %d (Session %d)", call_status, data->sessionId);
             }
        } else {
             OH_LOG_INFO(LOG_APP, "Directory callback: JS回调成功调用 (Session %d)", data->sessionId);
        }


        // 清理资源
        delete data;
        uv_close((uv_handle_t*)handle, [](uv_handle_t* h) { delete (uv_async_t*)h; });
    });

    if (init_status != 0) {
        OH_LOG_ERROR(LOG_APP, "OnDirectoryChange: uv_async_init 失败: %s (Session %d)", uv_strerror(init_status), sessionId);
        delete callbackData;
        delete async; // 清理分配的 async 句柄
        return;
    }

    int send_status = uv_async_send(async);
     if (send_status != 0) {
        OH_LOG_ERROR(LOG_APP, "OnDirectoryChange: uv_async_send 失败: %s (Session %d)", uv_strerror(send_status), sessionId);
        // uv_async_send 失败后，uv_close 是否能被安全调用取决于具体错误和状态
        // 为了安全起见，先尝试关闭再删除
        uv_close((uv_handle_t*)async, [](uv_handle_t* h) { delete (uv_async_t*)h; });
        delete callbackData; // callbackData 尚未传递给 uv 回调
        // 注意：此时 async 可能已被 uv_close 删除，也可能没有，存在资源管理风险
    } else {
         OH_LOG_INFO(LOG_APP, "OnDirectoryChange: uv_async_send 成功 (Session %d)", sessionId);
    }

}

// NAPI接口：注册目录变更回调 (基本不变，但JS侧需要处理两个参数)
static napi_value NAPI_RegisterDirectoryChangeCallback(napi_env env, napi_callback_info info) {
    OH_LOG_INFO(LOG_APP, "NAPI_RegisterDirectoryChangeCallback: Entry (following registerDataCallback pattern)");

    size_t argc = 1;
    napi_value args[1];
    napi_status status = napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (status != napi_ok || argc < 1) {
        napi_throw_error(env, nullptr, "Expected one argument (callback function)");
        return nullptr;
    }

    // 检查参数类型
    napi_valuetype valuetype;
    status = napi_typeof(env, args[0], &valuetype);
    if (status != napi_ok || valuetype != napi_function) {
        napi_throw_type_error(env, nullptr, "Argument must be a function");
        return nullptr;
    }

    // 保存环境和回调
    std::lock_guard<std::mutex> lock(g_directoryCallbackMutex); // 加锁保护全局变量

    g_directoryChangeEnv = env; // 更新环境

    // 如果已有回调，先清理
    if (g_directoryChangeCallbackRef != nullptr) {
         OH_LOG_INFO(LOG_APP, "NAPI_RegisterDirectoryChangeCallback: Clearing old callback reference");
        napi_delete_reference(env, g_directoryChangeCallbackRef);
        g_directoryChangeCallbackRef = nullptr;
    }

    // 创建新的回调引用
    status = napi_create_reference(env, args[0], 1, &g_directoryChangeCallbackRef);
    if (status != napi_ok) {
        OH_LOG_ERROR(LOG_APP, "NAPI_RegisterDirectoryChangeCallback: Failed to create callback reference");
        g_directoryCallbackRegistered = false;
        napi_throw_error(env, nullptr, "Failed to create reference for callback");
        return nullptr;
    }

    g_directoryCallbackRegistered = true;
    OH_LOG_INFO(LOG_APP, "NAPI_RegisterDirectoryChangeCallback: New callback registered");


    // --- 设置 SshSession 回调 (参照 registerDataCallback 模式) ---
    // 定义 C++ 回调 lambda，它调用 OnDirectoryChange
    auto directoryChangeCallbackLambda = [](int sessionId, const std::string& directory) {
        // OnDirectoryChange 会处理线程切换和调用 JS 回调
        OnDirectoryChange(sessionId, directory);
    };

    try {
        sessionManager.addPendingDirectoryChangeCallback(directoryChangeCallbackLambda);
        OH_LOG_INFO(LOG_APP, "NAPI_RegisterDirectoryChangeCallback: Added pending directory change callback for future sessions.");

        sessionManager.applyDirectoryChangeCallbackToExistingSessions(directoryChangeCallbackLambda);
        OH_LOG_INFO(LOG_APP, "NAPI_RegisterDirectoryChangeCallback: Applied directory change callback to existing sessions.");

    } catch (const std::exception& e) {
        OH_LOG_ERROR(LOG_APP, "NAPI_RegisterDirectoryChangeCallback: Error setting directory change callback via SessionManager: %s", e.what());
        // 清理已创建的引用并报告错误
        napi_delete_reference(env, g_directoryChangeCallbackRef);
        g_directoryChangeCallbackRef = nullptr;
        g_directoryCallbackRegistered = false;
        napi_throw_error(env, "E_SESSION_CALLBACK", "Failed to register internal directory change callback handler.");
        return nullptr;
    }
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    // 保存主环境和事件循环
    mainEnv = env; // 保存初始环境，主要用于清理 dataCallbackRef
    if (mainLoop == nullptr) { // 只获取一次
        napi_get_uv_event_loop(env, &mainLoop);
         if (mainLoop == nullptr) {
             // 这是一个严重错误，可能需要抛出异常或阻止模块加载
             OH_LOG_ERROR(LOG_APP, "Init: 无法获取 UV 事件循环!");
         } else {
              OH_LOG_INFO(LOG_APP, "Init: UV 事件循环已获取");
         }
    }


    napi_add_env_cleanup_hook(env, [](void* arg) {
        OH_LOG_INFO(LOG_APP, "环境退出清理钩子被触发");
        CleanupResources();
    }, nullptr);

    napi_property_descriptor desc[] = {
        {"openProtocol", nullptr, NAPI_Global_openProtocol, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sendTerminalCommand", nullptr, NAPI_Global_sendTerminalCommand, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"closeProtocol", nullptr, NAPI_Global_closeProtocol, nullptr, nullptr, nullptr, napi_default, nullptr}, // 已修改
        {"registerDataCallback", nullptr, NAPI_Global_registerDataCallback, nullptr, nullptr, nullptr, napi_default, nullptr },
        {"resizeTerminal", nullptr, ResizeTerminal, nullptr, nullptr, nullptr, napi_default, nullptr},
        { "setLogging", nullptr, SetLogging, nullptr, nullptr, nullptr, napi_default, nullptr},
        { "generateKeyPair", nullptr, NAPI_GenerateKeyPairToFile, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "decryptPrivateKey", nullptr, NAPI_DecryptPrivateKeyFromFile, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "enableDirectoryTracking", nullptr, NAPI_EnableDirectoryTracking, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "registerDirectoryChangeCallback", nullptr, NAPI_RegisterDirectoryChangeCallback, nullptr, nullptr, nullptr, napi_default, nullptr }, // 已修改 (JS侧需适配)
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);

    RegisterPortForwardingFunctions(env, exports);

    RegisterSftpFunctions(env, exports);

    return exports;
}
EXTERN_C_END

static napi_module demoModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "entry",
    .nm_priv = ((void*)0),
    .reserved = { 0 },
};

extern "C" __attribute__((constructor)) void RegisterEntryModule(void)
{
    napi_module_register(&demoModule);
}
