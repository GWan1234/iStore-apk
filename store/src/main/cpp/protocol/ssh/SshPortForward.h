#ifndef SSH_PORT_FORWARD_H
#define SSH_PORT_FORWARD_H

#include <string>
#include <vector>
#include <thread>
#include <mutex>
#include <atomic>
#include <memory>
#include <functional>
#include <tuple>
#include <libssh2.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <hilog/log.h>

#define READ_MAX_BUFF_SIZE 4096

#undef LOG_DOMAIN 
#undef LOG_TAG 
#define LOG_DOMAIN 0x3200
#define LOG_TAG "MY_TAG"

class SshSession; // 前向声明

// 端口转发数据结构
struct PortForwardData {
    int localPort = 0;
    std::string targetHost;
    int targetPort = 0;
    bool isRemote = false;
    bool isDynamic = false;
    bool anyInterface = false; // Add this to track if the listener should bind to INADDR_ANY
    std::atomic<bool> shouldStop{false};
    std::atomic<bool> running{false};
    int listenSocket = -1;
    LIBSSH2_LISTENER* listener = nullptr; // For remote forwarding listener tracking
    std::thread forwardThread;
};

// --- Add SshPortForwardConfig struct ---
struct SshPortForwardConfig {
    std::string hostname;
    int port = 22;
    std::string username;
    std::string password; // Used for password auth OR key passphrase
    bool useKeyAuth = false;
    std::string privateKeyData;
    std::string passphrase; // Add passphrase member
    // No need for keepalive interval for the dedicated PF session
    int keepAliveInterval = 60; // Add keepAliveInterval member, default 60
};
// ---------------------------------------

class SshPortForward {
public:
    // --- Modify constructor signature ---
    explicit SshPortForward(SshSession* mainSession, const SshPortForwardConfig& config);
    // -----------------------------------
    ~SshPortForward();

    // 禁止拷贝
    SshPortForward(const SshPortForward&) = delete;
    SshPortForward& operator=(const SshPortForward&) = delete;

    // --- Make connection management methods public ---
    bool connectSession();
    void disconnectSession();
    bool isPfConnected() const { return m_pfConnected.load(); }
    // ----------------------------------------------

    // 端口转发管理接口
    bool startLocalPortForwarding(int localPort, const std::string& targetHost, int targetPort, bool anyInterface = false);
    bool startRemotePortForwarding(int remotePort, const std::string& targetHost, int targetPort);
    bool startDynamicPortForwarding(int localPort, bool anyInterface = false);
    bool stopPortForwarding(int port, bool isRemote);
    bool isPortForwardingActive(int port, bool isRemote);
    std::vector<std::tuple<int, std::string, int, bool, bool>> listActivePortForwardings();

private:
    SshSession* m_mainSession; // Renamed for clarity - primarily for ThreadPool access
    SshPortForwardConfig m_config; // Store connection config
    std::vector<std::shared_ptr<PortForwardData>> m_forwardingPorts;
    std::mutex m_forwardingMutex; // Mutex for m_forwardingPorts vector

    // --- Add members for isolated session ---
    std::unique_ptr<LIBSSH2_SESSION, decltype(&libssh2_session_free)> m_pfSession;
    std::unique_ptr<libssh2_socket_t> m_pfSock;
    std::recursive_mutex m_pfMutex; // Dedicated mutex for the PF session/socket
    std::atomic<bool> m_pfConnected{false};
    // ---------------------------------------

    // 工具函数
    int createListenSocket(int port, bool anyInterface);
    void closeListenSocket(int socket);
    int waitSocket(LIBSSH2_SESSION* session, libssh2_socket_t sock);

    // 端口转发线程函数
    void localPortForwardingThread(std::shared_ptr<PortForwardData> data);
    void remotePortForwardingThread(std::shared_ptr<PortForwardData> data);
    void dynamicPortForwardingThread(std::shared_ptr<PortForwardData> data);
    
    // 处理连接的线程函数
    void handleLocalForwardConnection(int clientSocket, std::shared_ptr<PortForwardData> data);
    void handleRemoteForwardConnection(LIBSSH2_CHANNEL* channel, std::shared_ptr<PortForwardData> data);
    void handleDynamicForwardConnection(int clientSocket, std::shared_ptr<PortForwardData> data);

    // 核心数据转发循环
    void forwardDataLoop(int socket_fd, LIBSSH2_CHANNEL* channel, std::shared_ptr<PortForwardData> data);
};

#endif // SSH_PORT_FORWARD_H 