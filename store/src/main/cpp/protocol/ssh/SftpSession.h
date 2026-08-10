#ifndef LIBSSH2_SFTPSESSION_H
#define LIBSSH2_SFTPSESSION_H

#include <libssh2.h>
#include <libssh2_sftp.h>
#include <string>
#include <memory>
#include <functional>
#include <vector>
#include <hilog/log.h>
#include <mutex>
#include <atomic>
#include <thread>
#include <chrono>

class SshSession; // 保留前向声明，用于旧接口兼容

// 文件信息结构
struct FileInfo {
    std::string name;           // 文件名
    bool isDirectory;           // 是否是目录
    uint64_t size;             // 文件大小
    uint32_t permissions;      // 权限
    uint64_t mtime;           // 修改时间
    uint64_t atime;           // 访问时间
    std::string owner;        // 所有者
    std::string group;        // 用户组
    std::string fullPath;     // 完整路径
};

// 目录状态结构
struct DirectoryState {
    std::string currentPath;    // 当前目录路径
    std::string parentPath;     // 父目录路径
    bool isRoot;               // 是否是根目录
};

// SFTP会话配置结构体
struct SftpConfig {
    std::string host;         // 主机地址
    int port = 22;            // 端口号，默认22
    std::string username;     // 用户名
    std::string password;     // 密码
    bool useKeyAuth = false;  // 是否使用密钥认证
    std::string privateKeyData; // 更改：私钥内容
    std::string passphrase;   // 私钥密码
    int keepAliveInterval = 60; // 新增：保活间隔（秒），默认60
};

// 设置SFTP会话超时时间
static constexpr int DEFAULT_TIMEOUT_MS = 10000;  // 默认10秒超时
static constexpr int DEFAULT_OPERATION_TIMEOUT_S = 60;  // 默认操作超时时间 60 秒
static constexpr int LARGE_FILE_OPERATION_TIMEOUT_S = 1800; // 大文件操作超时时间 1800 秒 (30分钟)
static constexpr int DEFAULT_MAX_EMPTY_RESULTS = 5;    // 默认最大连续空结果数
static constexpr size_t DEFAULT_BUFFER_SIZE = 131072;  // 默认缓冲区大小 128KB
static constexpr size_t LARGE_BUFFER_SIZE = 524288;   // 大文件缓冲区大小 512KB
static constexpr size_t HUGE_BUFFER_SIZE = 2097152;   // 特大文件缓冲区大小 2MB
static constexpr off_t LARGE_FILE_THRESHOLD = 50 * 1024 * 1024; // 大文件阈值 50MB
static constexpr off_t HUGE_FILE_THRESHOLD = 1024 * 1024 * 1024; // 特大文件阈值 1GB

class SftpSession {
public:
    // 新构造函数，使用配置结构体
    SftpSession(const SftpConfig& config, bool nonBlocking = true);
    ~SftpSession();

    // 连接到服务器
    bool connect();
    
    // 检查会话是否有效
    bool isValid() const {
        return (session.get() != nullptr && sftp != nullptr);
    }

    // 初始化SFTP会话 - 为兼容性保留，但内部已由connect()实现
    bool init();
    
    // 列出目录内容
    bool listDirectory(const std::string& path, std::function<void(const FileInfo&)> callback);
    
    // 获取文件详细信息
    bool getFileInfo(const std::string& path, FileInfo& info);
    
    // 上传文件
    bool uploadFile(int localFd, const std::string& remotePath, std::function<void(int)> progressCallback = nullptr);
    
    // 下载文件
    bool downloadFile(const std::string& remotePath, int localFd, std::function<void(off_t)> progressCallback);
    
    // 删除文件
    bool deleteFile(const std::string& path);
    
    // 创建目录
    bool createDirectory(const std::string& path);
    
    // 删除目录
    bool deleteDirectory(const std::string& path);
    
    // 重命名文件或目录
    bool rename(const std::string& oldPath, const std::string& newPath);
    
    // 修改文件权限
    bool setPermissions(const std::string& path, uint32_t permissions);
    
    // 修改文件时间戳
    bool setFileTime(const std::string& path, uint64_t mtime, uint64_t atime);

    // 修改文件权限 (使用 chmod 命令方式)
    bool changeFilePermissions(const std::string& path, int permissions);

    // 获取文件权限字符串
    std::string getPermissionString(uint32_t permissions);
    
    // 获取时间字符串
    std::string getTimeString(uint64_t timestamp);
    
    // 设置重试次数
    void setMaxRetryCount(int count) { maxRetryCount = count; }
    
    // 设置重试超时
    void setRetryTimeout(int seconds) { retryTimeout = seconds; }
    
    // 设置阻塞/非阻塞模式
    void setNonBlocking(bool nonBlock);

    // 设置操作超时（秒）
    void setGlobalOperationTimeout(int seconds);

    // --- 新增: 取消请求方法 ---
    void requestCancel();
    // -------------------------

private:
    SftpConfig config;                                      // 连接配置
    std::mutex sessionMutex;                               // 会话互斥锁
    
    std::unique_ptr<LIBSSH2_SESSION, decltype(&libssh2_session_free)> session;  // libssh2会话
    LIBSSH2_SFTP* sftp;                                     // SFTP会话
    std::unique_ptr<libssh2_socket_t> socket_fd;            // 套接字
    
    std::string currentPath = "/";                         // 当前工作目录
    bool nonBlocking = true;                               // 默认使用非阻塞模式
    int maxRetryCount = 10;                                 // 最大重试次数
    int retryTimeout = 1;                                  // 每次等待超时秒数
    int globalOperationTimeout = DEFAULT_OPERATION_TIMEOUT_S; // 全局操作超时
    
    // --- 新增: 取消和超时标志 ---
    std::atomic<bool> cancelRequested{false};
    std::atomic<bool> operationTimedOut{false}; // Flag specifically set by the timeout thread
    std::shared_ptr<std::atomic<bool>> currentOperationActiveFlag{nullptr}; // Flag to signal if the monitored operation is still running
    // ---------------------------

    // --- 新增: keepalive相关成员变量 ---
    std::atomic<bool> stopThread{false};    // 控制线程停止的标志
    std::atomic<int> sessionId{0};          // 会话ID，用于日志标识
    void keepAliveThread();                 // keepalive线程方法
    // ---------------------------------
    
    // 等待socket就绪
    int waitSocket();
    
    // 错误检查和日志记录
    bool checkError(const char* operation);

    // 递归删除目录
    bool deleteDirectoryRecursive(const std::string& path);
    
    // 设置操作超时
    void setOperationTimeout(std::atomic<bool>& timedOutFlag, std::shared_ptr<std::atomic<bool>> activeFlag, int seconds);

    // 非阻塞操作模板方法 - 处理可能返回EAGAIN的函数调用
    template<typename Func>
    auto executeNonBlocking(Func operation, const char* opName) -> decltype(operation());
};

// 模板方法定义
template<typename Func>
auto SftpSession::executeNonBlocking(Func operation, const char* opName) -> decltype(operation()) {
    using ReturnType = decltype(operation());
    
    // 快速失败检查
    if (!session || !sftp) {
        OH_LOG_ERROR(LOG_APP, "执行 %{public}s 失败: 会话或SFTP上下文无效", opName);
        if constexpr (std::is_pointer<ReturnType>::value) {
            return nullptr;
        } else {
            return -1;
        }
    }
    
    // 尝试执行操作
    ReturnType result = operation();
    
    // 非阻塞模式下处理EAGAIN
    if (nonBlocking) {
        int retryCount = 0;
        // 操作超时：默认 8 秒（避免 SFTP 服务器无响应时无限等待，导致 UI 长时间转圈）；
        // 下载 read 放宽到 30 秒（慢网络/大文件时单次读可能超过 8 秒，防止下载中断）
        const int maxTimeoutSec = (strcmp(opName, "read") == 0) ? 30 : 8;
        time_t startTime = time(nullptr);
        
        // 针对指针类型返回值
        if constexpr (std::is_pointer<ReturnType>::value) {
            while (!result && 
                  libssh2_session_last_errno(session.get()) == LIBSSH2_ERROR_EAGAIN && 
                  retryCount < maxRetryCount) {
                
                if (time(nullptr) - startTime > maxTimeoutSec) {
                    OH_LOG_ERROR(LOG_APP, "操作 %{public}s 超时", opName);
                    break;
                }
                
                int wsResult = waitSocket();
                if (wsResult >= 0) {
                   result = operation();
                } else {
                   OH_LOG_ERROR(LOG_APP, "waitSocket failed during retry for %s (retrying pointer type)", opName);
                   break;
                }
                retryCount++;
            }
        } else {
            // 数值型返回值处理类似逻辑
            while ((result < 0) && 
                  libssh2_session_last_errno(session.get()) == LIBSSH2_ERROR_EAGAIN && 
                  retryCount < maxRetryCount) {
                
                if (time(nullptr) - startTime > maxTimeoutSec) {
                    OH_LOG_ERROR(LOG_APP, "操作 %{public}s 超时", opName);
                    break;
                }
                
                int wsResult = waitSocket();
                if (wsResult >= 0) {
                    result = operation();
                } else {
                    OH_LOG_ERROR(LOG_APP, "waitSocket failed during retry for %s (retrying numeric type)", opName);
                    result = -1;
                    break;
                }
                retryCount++;
            }
        }
    }
    
    return result;
}

#endif // LIBSSH2_SFTPSESSION_H