#ifndef LOG_MANAGER_H
#define LOG_MANAGER_H

#include <mutex>
#include <string>
#include <vector>

class LogManager {
public:
    // 现在按会话持有实例，需要公开构造/析构
    LogManager() = default;
    ~LogManager() = default;

    static LogManager& getInstance();

    // 初始化日志管理器
    void init(int fd, int logType, int existOperation, bool includeHeader = false, bool omitKnownPassword = false, bool omitSessionData = false);

    // 写入日志
    void writeLog(const char* data, size_t length);

    // 新增：禁用日志管理器
    void disable();

private:
    LogManager(const LogManager&) = delete;
    LogManager& operator=(const LogManager&) = delete;

    // 写入原始数据
    void writeRawData(const char* data, size_t length);
    // 写入可打印数据
    void writePrintableData(const char* data, size_t length);
    // 写入SSH数据包信息 (logType=3)
    void writeSSHPacketData(const char* data, size_t length);
    // 检查字符是否可打印
    static bool isPrintable(char c);

    int logFd = -1;                    // 日志文件描述符
    int currentLogType = 0;            // 当前日志类型
    int currentExistOperation = 0;     // 当前文件存在时的操作
    bool includeHeader = false;        // 是否包含头部信息
    bool omitKnownPassword = false;    // 是否忽略已知密码
    bool omitSessionData = false;      // 是否忽略会话数据
    std::mutex mutex;                  // 线程安全锁

    // --- Members for Line-Based Terminal Simulation (logType=1) ---
    std::string currentLineBuffer;     // Buffer for the current line being processed
    size_t cursorPosition = 0;         // Cursor position within the currentLineBuffer
    // -------------------------------------------------------------

    // Helper method for the line simulation logic
    void processLineData(const char* data, size_t length);
    // Helper to write the line buffer to the actual file
    void flushLineBuffer();
    
    // 新增：实现配置功能的辅助方法
    void writeHeader();                                    // 写入头部信息
    bool containsPassword(const char* data, size_t length); // 检测是否包含密码
    bool isSessionControlData(const char* data, size_t length); // 检测是否为会话控制数据
    std::string filterSensitiveData(const char* data, size_t length); // 过滤敏感数据
    std::string stripAnsiAndControl(const char* data, size_t length); // 移除ANSI转义与控制字符，保留可打印/\n/\t
    
    // 新增：状态跟踪
    bool headerWritten = false;        // 是否已写入头部信息

    // 为关键字检测保留跨块的尾部缓冲，避免提示被拆分导致漏检
    std::string detectionTail;
    static constexpr size_t DETECTION_TAIL_MAX = 64; // 持有最近的尾部字节数
};

#endif // LOG_MANAGER_H
