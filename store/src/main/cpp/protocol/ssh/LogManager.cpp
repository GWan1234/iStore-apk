#include "LogManager.h"
#include <unistd.h>
#include <cstring>
#include <cerrno>
#include <algorithm>
#include <cctype>
#include <chrono>
#include <ctime>
#include <iomanip>
#include <sstream>
#include "hilog/log.h"

#undef LOG_DOMAIN 
#undef LOG_TAG 
#define LOG_DOMAIN 0x3200  // 全局domain宏，标识业务领域
#define LOG_TAG "MY_TAG"   // 全局tag宏，标识模块日志tag

void LogManager::init(int fd, int logType, int existOperation, bool includeHeader, bool omitKnownPassword, bool omitSessionData) {
    std::lock_guard<std::mutex> lock(mutex);
    
    if (fd < 0) {
        OH_LOG_ERROR(LOG_APP, "无效的文件描述符: %{public}d", fd);
        throw std::runtime_error("Invalid file descriptor");
    }
    
    this->logFd = fd;
    this->currentLogType = logType;
    this->currentExistOperation = existOperation;
    this->includeHeader = includeHeader;
    this->omitKnownPassword = omitKnownPassword;
    this->omitSessionData = omitSessionData;
    
    // --- 新增：重置行缓冲状态 --- 
    this->currentLineBuffer.clear();
    this->cursorPosition = 0;
    // ---------------------------
    
    // --- 新增：重置头部写入状态 ---
    this->headerWritten = false;
    // ---------------------------

    // 重置跨块检测尾部，避免上一会话/文件的残留干扰本次检测
    this->detectionTail.clear();

    // 可选的截断支持（通常由 ETS 侧负责以打开文件模式实现，这里作为兜底）
    // 当 existOperation == 0 (Overwrite) 时，尝试将文件截断为 0。
    if (this->currentExistOperation == 0) {
        if (ftruncate(this->logFd, 0) != 0) {
            OH_LOG_WARN(LOG_APP, "ftruncate failed on fd %{public}d: %{public}s", this->logFd, strerror(errno));
        }
    }
    
    OH_LOG_INFO(LOG_APP, "日志管理器初始化成功: fd=%{public}d, logType=%{public}d, existOperation=%{public}d, includeHeader=%{public}d, omitKnownPassword=%{public}d, omitSessionData=%{public}d",
        fd, logType, existOperation, includeHeader, omitKnownPassword, omitSessionData);
}

void LogManager::writeLog(const char* data, size_t length) {
    // 在获取锁之前快速检查，减少锁竞争
    if (logFd < 0 || currentLogType == 0 || !data || length == 0) {
        return;
    }
    
    std::lock_guard<std::mutex> lock(mutex);
     // 再次检查，防止在等待锁期间状态改变
     if (logFd < 0 || currentLogType == 0) {
         return;
     }
    
    // --- 新增：写入头部信息（如果需要且尚未写入） ---
    if (includeHeader && !headerWritten) {
        writeHeader();
        headerWritten = true;
    }
    // ------------------------------------------
    
    // --- 新增：检查和过滤敏感数据 ---
    bool shouldSkip = false;
    bool sanitizeControl = omitSessionData; // 历史兼容：若开启，则对会话输出做控制序列剥离
    // 组合跨块检测缓冲，避免提示被拆分在不同块中时漏检
    if (omitKnownPassword) {
        std::string detectionBuf;
        detectionBuf.reserve(detectionTail.size() + length);
        detectionBuf.append(detectionTail);
        detectionBuf.append(data, length);
        if (containsPassword(detectionBuf.data(), detectionBuf.size())) {
            OH_LOG_INFO(LOG_APP, "检测到密码数据，跳过记录");
            shouldSkip = true;
        }
        // 更新尾部缓冲
        if (detectionBuf.size() > DETECTION_TAIL_MAX) {
            detectionTail.assign(detectionBuf.end() - DETECTION_TAIL_MAX, detectionBuf.end());
        } else {
            detectionTail = detectionBuf;
        }
    } else {
        // 未开启省略密码时，清空尾部缓冲
        if (!detectionTail.empty()) detectionTail.clear();
    }
    // 旧逻辑：检测到控制数据则整段跳过；优化为后续对原始文本内容进行剥离，而不是整体跳过
    
    if (shouldSkip) {
        return; // 跳过记录此数据
    }
    // ---------------------------
    
    try {
        if (currentLogType == 1) { // 只记录可打印输出 (行模拟)
            processLineData(data, length);
        } else if (currentLogType == 2) { // 记录所有会话输出
            // If switching from type 1 to 2, ensure the line buffer is flushed
            if (!currentLineBuffer.empty()) {
                 // Decide if flushing makes sense here or just clear?
                 // Flushing might add an incomplete line.
                 // Let's just clear it for now when switching to raw.
                 // flushLineBuffer(); // Optionally flush before switching
                 currentLineBuffer.clear();
                 cursorPosition = 0;
            }
            if (sanitizeControl) {
                std::string cleaned = stripAnsiAndControl(data, length);
                if (!cleaned.empty()) writeRawData(cleaned.data(), cleaned.size());
            } else {
                writeRawData(data, length);
            }
        } else if (currentLogType == 3) { // SSH数据包
            // 清理行缓冲区
            if (!currentLineBuffer.empty()) {
                currentLineBuffer.clear();
                cursorPosition = 0;
            }
            // 记录SSH协议层数据包信息
            writeSSHPacketData(data, length);
        } else if (currentLogType == 4) { // SSH数据包和原始数据
            // 清理行缓冲区
            if (!currentLineBuffer.empty()) {
                currentLineBuffer.clear();
                cursorPosition = 0;
            }
            // 记录SSH数据包信息
            writeSSHPacketData(data, length);
            // 若勾选“省略会话数据”，则不追加 RAW-DATA 部分
            if (!omitSessionData) {
                // 然后写入原始数据（根据配置决定是否剥离控制序列）
                std::string rawHeader = "[RAW-DATA] ";
                writeRawData(rawHeader.c_str(), rawHeader.size());
                if (sanitizeControl) {
                    std::string cleaned = stripAnsiAndControl(data, length);
                    if (!cleaned.empty()) writeRawData(cleaned.data(), cleaned.size());
                } else {
                    writeRawData(data, length);
                }
                writeRawData("\n", 1);
            } else {
                OH_LOG_INFO(LOG_APP, "已启用 omitSessionData，跳过 RAW-DATA 输出");
            }
        } else {
             // Handle other log types or default case if necessary
             // Maybe clear buffer for type 0 (disabled)?
             if (!currentLineBuffer.empty()) {
                 currentLineBuffer.clear();
                 cursorPosition = 0;
             }
        }
    } catch (const std::exception& e) {
        OH_LOG_ERROR(LOG_APP, "写入日志失败: %{public}s", e.what());
    }
}

void LogManager::writeRawData(const char* data, size_t length) {
    // 确保写满全部数据，处理部分写入情况
    size_t totalWritten = 0;
    while (totalWritten < length) {
        ssize_t n = write(logFd, data + totalWritten, length - totalWritten);
        if (n < 0) {
            OH_LOG_ERROR(LOG_APP, "写入原始数据失败: %{public}s", strerror(errno));
            break; // 发生错误时中断循环，避免死循环
        }
        if (n == 0) {
            // 非预期：write 返回 0，防止死循环
            OH_LOG_WARN(LOG_APP, "写入原始数据返回0，提前结束写入");
            break;
        }
        totalWritten += static_cast<size_t>(n);
    }
}

// State machine for filtering ANSI/OSC escape codes
enum class AnsiState {
    NORMAL,       // Processing regular text
    SEEN_ESC,     // Seen ESC (27), expecting '[' (CSI), ']' (OSC), or other sequence starter
    IN_CSI,       // Inside a CSI sequence (ESC [ ... letter)
    IN_OSC,       // Inside an OSC sequence (ESC ] ... BEL or ESC \\)
    OSC_SEEN_ESC  // Seen ESC while inside OSC, expecting '\\' to terminate
};

// Helper to write the buffered line to the file descriptor
void LogManager::flushLineBuffer() {
    if (!currentLineBuffer.empty()) {
        // Append a newline before writing to the log file for clarity
        currentLineBuffer += '\n';
        if (write(logFd, currentLineBuffer.c_str(), currentLineBuffer.length()) < 0) {
            OH_LOG_ERROR(LOG_APP, "写入行缓冲数据失败: %{public}s", strerror(errno));
        }
    }
    // Reset buffer and cursor after flushing
    currentLineBuffer.clear();
    cursorPosition = 0;
}

// Core logic for simulating line editing for logType=1
void LogManager::processLineData(const char* data, size_t length) {
    AnsiState currentState = AnsiState::NORMAL;
    constexpr char ESC = 27;
    constexpr char BEL = 7;
    constexpr char CSI_START = '[';
    constexpr char OSC_START = ']';
    std::string csiParams;
    char csiCommand = 0;

    for (size_t i = 0; i < length; ++i) {
        const char currentChar = data[i];

        switch (currentState) {
            case AnsiState::NORMAL:
                if (currentChar == ESC) {
                    currentState = AnsiState::SEEN_ESC;
                } else if (currentChar == '\n') {
                    // Newline: Flush the current buffer and reset
                    flushLineBuffer();
                } else if (currentChar == '\r') {
                    // Carriage Return: Move cursor to beginning of line
                    cursorPosition = 0;
                } else if (currentChar == '\b') {
                    // Backspace: Move cursor left (simple version)
                    if (cursorPosition > 0) {
                        cursorPosition--;
                        // More complex: currentLineBuffer.erase(cursorPosition, 1);
                    }
                } else if (currentChar == '\t') {
                    // Tab: Handle as multiple spaces (e.g., 8)
                    int spaces = 8 - (cursorPosition % 8);
                    for (int s = 0; s < spaces; ++s) {
                         if (cursorPosition >= currentLineBuffer.length()) {
                             currentLineBuffer += ' ';
                         } else {
                             currentLineBuffer[cursorPosition] = ' ';
                         }
                         cursorPosition++;
                    }
                } else if (currentChar >= 32 && currentChar <= 126) { // Basic printable ASCII - Use currentChar
                    // Printable character
                    if (cursorPosition >= currentLineBuffer.length()) {
                        // Append character
                        currentLineBuffer += currentChar;
                    } else {
                        // Overwrite character
                        currentLineBuffer[cursorPosition] = currentChar;
                    }
                    cursorPosition++;
                }
                // Ignore other non-printable characters in NORMAL state
                break;

            case AnsiState::SEEN_ESC:
                csiParams.clear(); // Clear params for new sequence
                csiCommand = 0;
                if (currentChar == CSI_START) {
                    currentState = AnsiState::IN_CSI;
                } else if (currentChar == OSC_START) {
                    currentState = AnsiState::IN_OSC;
                } else {
                    // Other ESC sequences (e.g., ESC D, ESC M) - ignore for now
                    currentState = AnsiState::NORMAL;
                }
                break;

            case AnsiState::IN_CSI:
                if (currentChar >= '0' && currentChar <= '9' || currentChar == ';' || currentChar == '?') {
                    // Collect parameter bytes
                    csiParams += currentChar;
                } else if (currentChar >= 0x40 && currentChar <= 0x7E) {
                    // Final command byte
                    csiCommand = currentChar;
                    currentState = AnsiState::NORMAL;

                    // --- Handle specific CSI sequences affecting the line ---
                    if (csiCommand == 'K') { // Erase in Line (EL)
                        // Default (0) or 0K: Erase from cursor to end of line
                        // 1K: Erase from beginning of line to cursor
                        // 2K: Erase entire line
                        int code = 0;
                        if (!csiParams.empty()) {
                           try { code = std::stoi(csiParams); } catch(...) { code = 0; }
                        }
                        if (code == 0) {
                            if (cursorPosition < currentLineBuffer.length()) {
                                currentLineBuffer.resize(cursorPosition);
                            }
                        } else if (code == 1) {
                            if (cursorPosition < currentLineBuffer.length()) {
                                for(size_t p=0; p<cursorPosition; ++p) currentLineBuffer[p] = ' ';
                            } else {
                                // Cursor past end, erase beginning up to length
                                for(size_t p=0; p<currentLineBuffer.length(); ++p) currentLineBuffer[p] = ' ';
                            }
                            // Doesn't move cursor in most terminals
                        } else if (code == 2) {
                            // Erase entire line and move cursor to start
                            currentLineBuffer.clear();
                            cursorPosition = 0;
                        }
                    } else if (csiCommand == 'C') { // Cursor Forward
                         int count = 1;
                         if (!csiParams.empty()) { try { count = std::stoi(csiParams); } catch(...) { count = 1; } }
                         cursorPosition += count; // Simple move right
                         // Ensure cursor doesn't go beyond reasonable bounds if needed
                    } else if (csiCommand == 'D') { // Cursor Backward
                         int count = 1;
                         if (!csiParams.empty()) { try { count = std::stoi(csiParams); } catch(...) { count = 1; } }
                         if (cursorPosition >= count) cursorPosition -= count;
                         else cursorPosition = 0;
                    } // Add more CSI handlers as needed (e.g., 'A' up, 'B' down - tricky for line buffer)
                    // --------------------------------------------------------

                } else {
                    // Intermediate bytes (ignore for now)
                }
                break;

            case AnsiState::IN_OSC:
                if (currentChar == BEL) {
                    currentState = AnsiState::NORMAL;
                } else if (currentChar == ESC) {
                    currentState = AnsiState::OSC_SEEN_ESC;
                }
                // Consume content bytes of OSC
                break;

            case AnsiState::OSC_SEEN_ESC:
                if (currentChar == '\\') {
                    currentState = AnsiState::NORMAL;
                } else {
                    currentState = AnsiState::IN_OSC; // Revert, not a terminator
                }
                break;
        }
    }
    // Note: Buffer is only flushed on newline '\n' currently.
    // Consider if flushing is needed at the end of the data chunk if no newline was seen.
}

bool LogManager::isPrintable(char c) {
    // return (c >= 32 && c <= 126) || c == '\n' || c == '\r' || c == '\t'; // Original
    return (c >= 32 && c <= 126) || c == '\n' || c == '\t'; // Exclude CR ('\r')
}

LogManager& LogManager::getInstance() {
    static LogManager instance;
    return instance;
}

void LogManager::disable() {
    std::lock_guard<std::mutex> lock(mutex);
    OH_LOG_INFO(LOG_APP, "禁用日志管理器。");
    if (logFd >= 0) {
        // 若处于行模式且仍有尾行未写出，尝试刷出（附加换行）
        if (currentLogType == 1 && !currentLineBuffer.empty()) {
            flushLineBuffer();
        }
        // 如果之前有打开的文件描述符，可以选择关闭它，但这取决于 fd 的所有权。
        // close(logFd); // 谨慎使用，确保不会关闭不属于管理器的 fd
    }
    logFd = -1;
    currentLogType = 0;
    currentLineBuffer.clear(); // 清空可能存在的缓冲
    cursorPosition = 0;
    headerWritten = false; // 重置头部写入状态
    detectionTail.clear();
}

// 写入头部信息
void LogManager::writeHeader() {
    if (logFd < 0) return;
    
    // 获取当前时间（线程安全版本）
    time_t rawtime;
    struct tm timeinfo_buf{};
    char timeBuffer[80];
    
    time(&rawtime);
    struct tm* timeinfo = localtime_r(&rawtime, &timeinfo_buf);
    if (!timeinfo) {
        // 回退：极端情况下无法获取本地时间
        snprintf(timeBuffer, sizeof(timeBuffer), "unknown-time");
    } else {
        // 构建头部信息 - PuTTY风格
        strftime(timeBuffer, sizeof(timeBuffer), "%Y.%m.%d %H:%M:%S", timeinfo);
    }
    
    std::string header = "=~=~=~=~=~=~=~=~=~=~=~= CrossShellNext log " + std::string(timeBuffer) + " =~=~=~=~=~=~=~=~=~=~=~=\n";
    
    // 写入头部信息
    if (write(logFd, header.c_str(), header.length()) < 0) {
        OH_LOG_ERROR(LOG_APP, "写入头部信息失败: %{public}s", strerror(errno));
    }
}

// 检测是否包含密码
bool LogManager::containsPassword(const char* data, size_t length) {
    if (!data || length == 0) return false;

    // 先拷贝原始数据
    std::string lowered(data, length);
    // 仅对 ASCII 字母安全地转换为小写，避免对非 ASCII（例如中文 UTF-8）造成未定义行为
    for (size_t i = 0; i < lowered.size(); ++i) {
        unsigned char uc = static_cast<unsigned char>(lowered[i]);
        if (uc >= 'A' && uc <= 'Z') {
            lowered[i] = static_cast<char>(uc + 32);
        }
    }

    // 规范化：将常见的全角标点替换为半角，避免 "密码：" 这种提示漏检
    // 全角冒号：U+FF1A (UTF-8: EF BC 9A) -> ':'
    // 全角问号：U+FF1F (UTF-8: EF BC 9F) -> '?'
    auto normalizeFullWidthPunct = [](std::string& s) {
        const std::string FULLWIDTH_COLON = u8"：";
        const std::string FULLWIDTH_QUESTION = u8"？";
        size_t pos = std::string::npos;
        while ((pos = s.find(FULLWIDTH_COLON)) != std::string::npos) {
            s.replace(pos, FULLWIDTH_COLON.size(), ":");
        }
        while ((pos = s.find(FULLWIDTH_QUESTION)) != std::string::npos) {
            s.replace(pos, FULLWIDTH_QUESTION.size(), "?");
        }
    };
    normalizeFullWidthPunct(lowered);

    // 常见的密码提示关键词（统一用半角标点表示，前面已做规范化）
    const std::vector<std::string> passwordKeywords = {
        // 英文常见形式
        "password:", "password?", "password", "passwd:", "pass:", "pwd:",
        "enter password", "enter your password", "password for", "password required",
        // 私钥口令/短语等
        "passphrase:", "enter passphrase", "pass phrase", "private key passphrase",
        // PIN/验证码/二次验证等
        "pin:", "enter pin", "verification code", "auth code", "one-time password", "otp:", "2fa code",
        // 中文常见形式（经过规范化后统一匹配半角冒号）
        "密码:", "请输入密码", "输入密码", "口令:", "请输入口令", "输入口令", "私钥口令:", "动态口令:", "验证码:", "请输入验证码",
        // 兼容繁体中文
        "密碼:", "請輸入密碼", "輸入密碼", "口令:", "請輸入口令", "輸入口令", "私鑰口令:", "動態口令:", "驗證碼:", "請輸入驗證碼"
    };

    for (const auto& keyword : passwordKeywords) {
        if (lowered.find(keyword) != std::string::npos) {
            return true;
        }
    }
    
    return false;
}

// 写入SSH数据包信息 (logType=3)
void LogManager::writeSSHPacketData(const char* data, size_t length) {
    if (!data || length == 0) return;
    
    // 创建SSH数据包信息的格式化输出
    std::string packetInfo = "[SSH-PACKET] ";
    
    // 添加时间戳
    auto now = std::chrono::system_clock::now();
    auto time_sec = std::chrono::system_clock::to_time_t(now);
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        now.time_since_epoch()) % 1000;
    
    char timeBuffer[64];
    struct tm tm_buf{};
    struct tm* tm_ptr = localtime_r(&time_sec, &tm_buf);
    if (!tm_ptr) {
        strncpy(timeBuffer, "1970-01-01 00:00:00", sizeof(timeBuffer));
        timeBuffer[sizeof(timeBuffer)-1] = '\0';
    } else {
        std::strftime(timeBuffer, sizeof(timeBuffer), "%Y-%m-%d %H:%M:%S", tm_ptr);
    }
    packetInfo += std::string(timeBuffer) + "." + std::to_string(ms.count()) + " ";
    
    // 添加数据包长度信息
    packetInfo += "Length=" + std::to_string(length) + " ";
    
    // 分析数据包类型（简单的启发式分析）
    if (length > 0) {
        unsigned char firstByte = static_cast<unsigned char>(data[0]);
        if (firstByte >= 1 && firstByte <= 97) {
            packetInfo += "Type=SSH_MSG_" + std::to_string(firstByte) + " ";
        }
    }
    
    // 添加数据包数据展示（受 omitSessionData 控制）
    if (omitSessionData) {
        packetInfo += "Data=(omitted)"; // 与 PuTTY 选项语义对齐：省略会话数据
    } else {
        packetInfo += "Data=";
        for (size_t i = 0; i < length; ++i) {
            char hex[4];
            snprintf(hex, sizeof(hex), "%02X ", static_cast<unsigned char>(data[i]));
            packetInfo += hex;
        }
    }
    packetInfo += "\n";
    
    // 写入到日志文件
    writeRawData(packetInfo.c_str(), packetInfo.length());

    // 在 logType=3 且未省略会话数据时，追加可读翻译（去除控制序列，尽量保留 UTF-8 文本）
    if (!omitSessionData && (currentLogType == 3 || currentLogType == 4)) {
        std::string translated = stripAnsiAndControl(data, length);
        if (!translated.empty()) {
            std::string textLine = std::string("[TEXT] ") + translated + "\n";
            writeRawData(textLine.c_str(), textLine.length());
        }
    }
}

// (已移除 writeSSHPacketAndRawData：类型4逻辑已在 writeLog 内联实现)

// 检测是否为会话控制数据
bool LogManager::isSessionControlData(const char* data, size_t length) {
    if (!data || length == 0) return false;
    
    // 检测ANSI转义序列和控制字符
    for (size_t i = 0; i < length; ++i) {
        unsigned char c = static_cast<unsigned char>(data[i]);
        
        // 检测ESC序列开始
        if (c == 27 && i + 1 < length) { // ESC
            char next = data[i + 1];
            if (next == '[' || next == ']' || next == '(' || next == ')') {
                return true; // 这是ANSI控制序列
            }
        }
        
        // 检测其他控制字符（除了常见的可打印控制字符）
        if (c < 32 && c != '\n' && c != '\r' && c != '\t') {
            return true;
        }
    }
    
    return false;
}

// 过滤敏感数据（预留方法，目前主要通过跳过记录实现）
std::string LogManager::filterSensitiveData(const char* data, size_t length) {
    if (!data || length == 0) return "";
    
    std::string result(data, length);
    
    // 这里可以实现更复杂的过滤逻辑
    // 比如替换密码字符为星号等
    
    return result;
}

// 去除 ANSI 转义序列与控制字符，仅保留可打印字符以及换行/制表
std::string LogManager::stripAnsiAndControl(const char* data, size_t length) {
    if (!data || length == 0) return {};

    enum class State { NORMAL, SEEN_ESC, IN_CSI, IN_OSC, OSC_SEEN_ESC };
    State state = State::NORMAL;
    std::string out;
    out.reserve(length);
    std::string csiParams;

    const char ESC = 27;
    const char BEL = 7;

    for (size_t i = 0; i < length; ++i) {
        unsigned char ch = static_cast<unsigned char>(data[i]);
        switch (state) {
            case State::NORMAL:
                if (ch == ESC) {
                    state = State::SEEN_ESC;
                } else if (ch == '\n' || ch == '\t') {
                    out.push_back(static_cast<char>(ch));
                } else if (ch >= 32 || ch >= 128) {
                    // 保留 ASCII 可打印以及非 ASCII 字节
                    if (ch >= 32) {
                        out.push_back(static_cast<char>(ch));
                    } else if (ch >= 128) {
                        out.push_back(static_cast<char>(ch));
                    }
                } else {
                    // 其他控制字符（含 CR）丢弃
                }
                break;
            case State::SEEN_ESC:
                if (ch == '[') {
                    state = State::IN_CSI; csiParams.clear();
                } else if (ch == ']') {
                    state = State::IN_OSC;
                } else if (ch == '(' || ch == ')') {
                    // 选择字符集序列，忽略一个后续字符
                    state = State::NORMAL; // 简化：直接忽略
                } else {
                    // 未识别的 ESC 序列，直接忽略并回到 NORMAL
                    state = State::NORMAL;
                }
                break;
            case State::IN_CSI:
                if ((ch >= '0' && ch <= '9') || ch == ';' || ch == '?') {
                    csiParams.push_back(static_cast<char>(ch));
                } else if (ch >= 0x40 && ch <= 0x7E) {
                    // 终结符，结束 CSI
                    state = State::NORMAL;
                } else {
                    // 其他中间字节，忽略
                }
                break;
            case State::IN_OSC:
                if (ch == BEL) {
                    state = State::NORMAL;
                } else if (ch == ESC) {
                    state = State::OSC_SEEN_ESC;
                } else {
                    // 忽略 OSC 内容
                }
                break;
            case State::OSC_SEEN_ESC:
                if (ch == '\\') {
                    state = State::NORMAL; // ESC \\ 结束 OSC
                } else {
                    state = State::IN_OSC; // 非终结，回到 OSC
                }
                break;
        }
    }
    // 第二阶段：按 UTF-8 解码，去除 C0/C1 控制字符（保留 \n 和 \t）以及 DEL
    std::string utf8Clean;
    utf8Clean.reserve(out.size());
    const unsigned char* bytes = reinterpret_cast<const unsigned char*>(out.data());
    size_t i = 0, n = out.size();
    while (i < n) {
        uint32_t cp = 0; // codepoint
        size_t start = i;
        unsigned char b0 = bytes[i++];
        if (b0 < 0x80) {
            cp = b0;
        } else if (b0 >= 0xC2 && b0 <= 0xDF && i < n) {
            unsigned char b1 = bytes[i++];
            if ((b1 & 0xC0) != 0x80) { // 非法续字节
                // 回退：按原字节保留
                utf8Clean.push_back(static_cast<char>(b0));
                continue;
            }
            cp = ((b0 & 0x1F) << 6) | (b1 & 0x3F);
        } else if (b0 >= 0xE0 && b0 <= 0xEF && i + 1 < n) {
            unsigned char b1 = bytes[i++];
            unsigned char b2 = bytes[i++];
            if (((b1 & 0xC0) != 0x80) || ((b2 & 0xC0) != 0x80)) {
                utf8Clean.append(reinterpret_cast<const char*>(bytes + start), i - start);
                continue;
            }
            cp = ((b0 & 0x0F) << 12) | ((b1 & 0x3F) << 6) | (b2 & 0x3F);
        } else if (b0 >= 0xF0 && b0 <= 0xF4 && i + 2 < n) {
            unsigned char b1 = bytes[i++];
            unsigned char b2 = bytes[i++];
            unsigned char b3 = bytes[i++];
            if (((b1 & 0xC0) != 0x80) || ((b2 & 0xC0) != 0x80) || ((b3 & 0xC0) != 0x80)) {
                utf8Clean.append(reinterpret_cast<const char*>(bytes + start), i - start);
                continue;
            }
            cp = ((b0 & 0x07) << 18) | ((b1 & 0x3F) << 12) | ((b2 & 0x3F) << 6) | (b3 & 0x3F);
        } else {
            // 非法起始字节，原样保留
            utf8Clean.push_back(static_cast<char>(b0));
            continue;
        }

        // 过滤 C0/C1 控制字符与 DEL（允许 \n 和 \t）
        if ((cp <= 0x1F && cp != 0x0A && cp != 0x09) || cp == 0x7F || (cp >= 0x80 && cp <= 0x9F)) {
            // 丢弃该 codepoint
            continue;
        }

        // 回写原始字节区段（保持原有 UTF-8 编码）
        utf8Clean.append(reinterpret_cast<const char*>(bytes + start), i - start);
    }

    return utf8Clean;
}
