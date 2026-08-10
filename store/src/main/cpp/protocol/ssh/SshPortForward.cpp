#include "SshPortForward.h"
#include "SshSession.h"
#include <fcntl.h>
#include <iostream>
#include <vector>
#include <sys/select.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <errno.h>
#include <cstring>
#include <algorithm>
#include <chrono>
#include <mutex>

#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif

SshPortForward::SshPortForward(SshSession* mainSession, const SshPortForwardConfig& config)
    : m_mainSession(mainSession),
      m_config(config),
      m_pfSession(nullptr, &libssh2_session_free),
      m_pfSock(std::make_unique<libssh2_socket_t>(LIBSSH2_INVALID_SOCKET)),
      m_pfConnected(false)
{
    OH_LOG_INFO(LOG_APP, "SshPortForward initialized for %{public}s@%{public}s:%{public}d.",
               m_config.username.c_str(), m_config.hostname.c_str(), m_config.port);
}

SshPortForward::~SshPortForward() {
    OH_LOG_INFO(LOG_APP, "SshPortForward destructor started.");
    std::vector<std::shared_ptr<PortForwardData>> portsToStop;
    {
        std::lock_guard<std::mutex> lock(m_forwardingMutex);
        portsToStop = m_forwardingPorts;
        m_forwardingPorts.clear();
    }

    OH_LOG_INFO(LOG_APP, "Stopping %zu port forwardings in destructor.", portsToStop.size());
    for (auto& data : portsToStop) {
        if (!data) continue;

        OH_LOG_INFO(LOG_APP, "Destructor: Signaling stop for port %{public}d (isRemote=%{public}d)", data->localPort, data->isRemote);
        data->shouldStop.store(true);

        if (!data->isRemote && data->listenSocket >= 0) {
            OH_LOG_INFO(LOG_APP, "Destructor: Closing listen socket %{public}d", data->listenSocket);
            closeListenSocket(data->listenSocket);
            data->listenSocket = -1;
        } else if (data->isRemote && data->listener && m_pfConnected.load()) {
            OH_LOG_INFO(LOG_APP, "Destructor: Cancelling remote listener for port %{public}d using PF session", data->localPort);
            std::lock_guard<std::recursive_mutex> pfLock(m_pfMutex);
            if (m_pfSession) {
                libssh2_channel_forward_cancel(data->listener);
            }
            data->listener = nullptr;
        }

        if (data->forwardThread.joinable()) {
            OH_LOG_INFO(LOG_APP, "Destructor: Joining forwarder thread for port %{public}d...", data->localPort);
            try {
                data->forwardThread.join();
                 OH_LOG_INFO(LOG_APP, "Destructor: Forwarder thread joined for port %{public}d.", data->localPort);
            } catch (const std::system_error& e) {
                OH_LOG_ERROR(LOG_APP, "Destructor: Exception joining forwarder thread for port %{public}d: %{public}s", data->localPort, e.what());
            }
        } else {
             OH_LOG_INFO(LOG_APP, "Destructor: Forwarder thread for port %{public}d was not joinable.", data->localPort);
        }
    }

    disconnectSession();

    OH_LOG_INFO(LOG_APP, "SshPortForward destructor finished.");
}

bool SshPortForward::connectSession() {
    OH_LOG_INFO(LOG_APP, "SshPortForward::connectSession() started.");
    std::lock_guard<std::recursive_mutex> lock(m_pfMutex); // Lock PF resources

    if (m_pfConnected.load()) {
        OH_LOG_INFO(LOG_APP, "connectSession: Already connected.");
        return true;
    }

    // --- Reset previous state if any ---
    m_pfSession.reset();
    if (*m_pfSock != LIBSSH2_INVALID_SOCKET) {
        close(*m_pfSock);
        *m_pfSock = LIBSSH2_INVALID_SOCKET;
    }
    // -----------------------------------

    // --- Declare variables needed before potential gotos ---
    int ret = 0;
    time_t startTime;
    int retryCount = 0; // Declare retryCount here
    const int handshakeTimeout = 15; // Declare and init handshakeTimeout here
    const int authTimeout = 15;      // Declare and init authTimeout here
    // -----------------------------------------------------

    // --- Address Resolution (Copied & Adapted from SftpSession::connect) ---
    struct sockaddr_storage addr;
    memset(&addr, 0, sizeof(addr));
    socklen_t addr_len = 0;
    int pton_ret = 0;

    OH_LOG_INFO(LOG_APP, "PF connectSession: Parsing hostname/IP: '%{public}s'", m_config.hostname.c_str());

    // Try IPv4
    pton_ret = inet_pton(AF_INET, m_config.hostname.c_str(), &(((struct sockaddr_in *)&addr)->sin_addr));
    if (pton_ret == 1) {
        OH_LOG_INFO(LOG_APP, "PF connectSession: Address recognized as IPv4");
        struct sockaddr_in *sin = (struct sockaddr_in *)&addr;
        sin->sin_family = AF_INET;
        sin->sin_port = htons(m_config.port);
        addr_len = sizeof(struct sockaddr_in);
    } else {
        if (pton_ret == -1) {
             OH_LOG_ERROR(LOG_APP, "PF connectSession: inet_pton(AF_INET) failed for '%{public}s': errno=%{public}d (%{public}s)", m_config.hostname.c_str(), errno, strerror(errno));
        }
        // Try IPv6
        pton_ret = inet_pton(AF_INET6, m_config.hostname.c_str(), &(((struct sockaddr_in6 *)&addr)->sin6_addr));
        if (pton_ret == 1) {
            OH_LOG_INFO(LOG_APP, "PF connectSession: Address recognized as IPv6");
            struct sockaddr_in6 *sin6 = (struct sockaddr_in6 *)&addr;
            sin6->sin6_family = AF_INET6;
            sin6->sin6_port = htons(m_config.port);
            addr_len = sizeof(struct sockaddr_in6);
        } else {
             if (pton_ret == -1) {
                 OH_LOG_ERROR(LOG_APP, "PF connectSession: inet_pton(AF_INET6) failed for '%{public}s': errno=%{public}d (%{public}s)", m_config.hostname.c_str(), errno, strerror(errno));
             } else { // pton_ret == 0
                 OH_LOG_INFO(LOG_APP, "PF connectSession: Input '%{public}s' not valid IPv6, trying DNS lookup...", m_config.hostname.c_str());
                 // --- DNS Fallback --- 
                 struct addrinfo hints, *res;
                 memset(&hints, 0, sizeof(hints));
                 hints.ai_family = AF_UNSPEC; // Allow IPv4 or IPv6
                 hints.ai_socktype = SOCK_STREAM;

                 int getaddrinfo_ret = getaddrinfo(m_config.hostname.c_str(), std::to_string(m_config.port).c_str(), &hints, &res);
                 if (getaddrinfo_ret == 0 && res != nullptr) {
                     OH_LOG_INFO(LOG_APP, "PF connectSession: DNS lookup successful, using first result (Family: %{public}d)", res->ai_family);
                     memcpy(&addr, res->ai_addr, res->ai_addrlen);
                     addr_len = res->ai_addrlen;
                     if (addr.ss_family == AF_INET) {
                         ((struct sockaddr_in *)&addr)->sin_port = htons(m_config.port);
                     } else if (addr.ss_family == AF_INET6) {
                         ((struct sockaddr_in6 *)&addr)->sin6_port = htons(m_config.port);
                     }
                     freeaddrinfo(res);
                 } else {
                    OH_LOG_ERROR(LOG_APP, "PF connectSession: Failed to resolve '%{public}s' as IP or via DNS (getaddrinfo error: %{public}s)", m_config.hostname.c_str(), gai_strerror(getaddrinfo_ret));
                    return false;
                 }
                 // --- DNS Fallback End ---
            }
        }
    }

    if (addr_len == 0) {
        OH_LOG_ERROR(LOG_APP, "PF connectSession: Invalid address length after parsing/lookup.");
        return false;
    }
    // --- Address Resolution End ---

    // --- Socket Creation (Adapted from SftpSession::connect) ---
    OH_LOG_INFO(LOG_APP, "PF connectSession: Creating socket with family %{public}d", addr.ss_family);
    *m_pfSock = socket(addr.ss_family, SOCK_STREAM, 0);
    if (*m_pfSock == LIBSSH2_INVALID_SOCKET) {
        OH_LOG_ERROR(LOG_APP, "PF connectSession: Failed to create socket: %{public}s", strerror(errno));
        return false;
    }
    OH_LOG_INFO(LOG_APP, "PF connectSession: Socket created (fd=%{public}d)", *m_pfSock);
    // --- Socket Creation End ---

    // --- Non-blocking connect (Adapted from SftpSession::connect) ---
    int flags = fcntl(*m_pfSock, F_GETFL, 0);
    fcntl(*m_pfSock, F_SETFL, flags | O_NONBLOCK);

    OH_LOG_INFO(LOG_APP, "PF connectSession: Attempting non-blocking connect to %{public}s:%{public}d...", m_config.hostname.c_str(), m_config.port);
    int connect_ret = connect(*m_pfSock, (struct sockaddr *)&addr, addr_len);
    bool sockConnected = false;
    if (connect_ret == 0) {
        sockConnected = true;
        fcntl(*m_pfSock, F_SETFL, flags); // Restore blocking
         OH_LOG_INFO(LOG_APP, "PF connectSession: Socket connected immediately.");
    } else if (errno == EINPROGRESS) {
        const int maxRetries = 3; // Use 3 retries like SFTP
        const int connectTimeout = 5; // Use 5 sec timeout like SFTP
        OH_LOG_INFO(LOG_APP, "PF connectSession: Connection in progress (EINPROGRESS), entering select loop (Max %{public}d attempts, %{public}d sec timeout)...", maxRetries, connectTimeout);
        while (retryCount < maxRetries && !sockConnected) {
            retryCount++;
            fd_set writefds;
            FD_ZERO(&writefds);
            FD_SET(*m_pfSock, &writefds);
            fd_set exceptfds = writefds;
            struct timeval timeout = {connectTimeout, 0};

            OH_LOG_INFO(LOG_APP, "PF connectSession: Waiting on select (Attempt %{public}d)...", retryCount);
            int select_ret = select(*m_pfSock + 1, NULL, &writefds, &exceptfds, &timeout);

            if (select_ret > 0) {
                 if (FD_ISSET(*m_pfSock, &writefds) || FD_ISSET(*m_pfSock, &exceptfds)) {
                    int error = 0;
                    socklen_t len = sizeof(error);
                    if (getsockopt(*m_pfSock, SOL_SOCKET, SO_ERROR, &error, &len) == 0 && error == 0) {
                        sockConnected = true;
                        fcntl(*m_pfSock, F_SETFL, flags); // Restore blocking
                        OH_LOG_INFO(LOG_APP, "PF connectSession: Select reported connection successful.");
                        // No break needed, condition !sockConnected handles loop exit
                    } else {
                        OH_LOG_ERROR(LOG_APP, "PF connectSession: Select reported connection error (SO_ERROR=%{public}d): %{public}s", error, strerror(error));
                        errno = error;
                        break; // Error, exit loop
                    }
                 } else {
                     OH_LOG_WARN(LOG_APP, "PF connectSession: select returned > 0 but socket not ready?");
                     std::this_thread::sleep_for(std::chrono::milliseconds(100));
                 }
            } else if (select_ret == 0) {
                 OH_LOG_INFO(LOG_APP, "PF connectSession: Select timed out (Attempt %{public}d).", retryCount);
                 // Continue loop
            } else {
                OH_LOG_ERROR(LOG_APP, "PF connectSession: Select error: %{public}s", strerror(errno));
                break; // Error, exit loop
            }
        }
    } else {
         OH_LOG_ERROR(LOG_APP, "PF connectSession: Initial connect failed: %{public}s", strerror(errno));
    }

    if (!sockConnected) {
        OH_LOG_ERROR(LOG_APP, "PF connectSession: Failed to connect socket after %{public}d attempts.", retryCount);
        if (*m_pfSock != LIBSSH2_INVALID_SOCKET) {
            close(*m_pfSock);
            *m_pfSock = LIBSSH2_INVALID_SOCKET;
        }
        return false;
    }
    OH_LOG_INFO(LOG_APP, "PF connectSession: Socket connected successfully.");
    // --- Non-blocking connect End ---

    // --- libssh2 Session Initialization and Handshake (Adapted from SftpSession::connect) ---
    m_pfSession.reset(libssh2_session_init());
    if (!m_pfSession) {
        OH_LOG_ERROR(LOG_APP, "PF connectSession: libssh2_session_init failed.");
        close(*m_pfSock);
        *m_pfSock = LIBSSH2_INVALID_SOCKET;
        return false;
    }
    OH_LOG_INFO(LOG_APP, "PF connectSession: libssh2 session initialized.");

    // Set blocking mode based on how PF session will be used (typically non-blocking for forwarding)
    OH_LOG_INFO(LOG_APP, "PF connectSession: Setting session to non-blocking mode.");
    libssh2_session_set_blocking(m_pfSession.get(), 0);

    // int ret = 0; // Moved declaration outside
    startTime = time(nullptr); // Initialize startTime here
    // const int handshakeTimeout = 15; // Moved declaration outside
    OH_LOG_INFO(LOG_APP, "PF connectSession: Starting handshake (Timeout: %{public}d sec)...", handshakeTimeout);

    do {
        ret = libssh2_session_handshake(m_pfSession.get(), *m_pfSock);
        if (ret == LIBSSH2_ERROR_EAGAIN) {
            // Since we set non-blocking, EAGAIN is expected
            int ws_rc = waitSocket(m_pfSession.get(), *m_pfSock);
            if (ws_rc < 0) {
                OH_LOG_ERROR(LOG_APP, "PF connectSession: waitSocket error during handshake.");
                goto cleanup_error;
            }
            if (time(nullptr) - startTime > handshakeTimeout) {
                OH_LOG_ERROR(LOG_APP, "PF connectSession: Handshake timed out.");
                goto cleanup_error;
            }
        } else if (ret != 0) {
            char* errmsg = nullptr;
            libssh2_session_last_error(m_pfSession.get(), &errmsg, nullptr, 0);
            OH_LOG_ERROR(LOG_APP, "PF connectSession: Handshake failed (ret=%{public}d): %{public}s", ret, errmsg ? errmsg : "N/A");
            goto cleanup_error;
        }
    } while (ret == LIBSSH2_ERROR_EAGAIN); // Loop only on EAGAIN

    OH_LOG_INFO(LOG_APP, "PF connectSession: Handshake successful.");

    // --- Authentication (Adapted from SftpSession::connect) --- //
    startTime = time(nullptr); // Re-initialize startTime for auth timeout
    // const int authTimeout = 15; // Moved declaration outside
    OH_LOG_INFO(LOG_APP, "PF connectSession: Starting authentication (User: %{public}s, useKey: %{public}d, Timeout: %{public}d sec)...", m_config.username.c_str(), m_config.useKeyAuth, authTimeout);

    if (m_config.useKeyAuth) {
        OH_LOG_INFO(LOG_APP, "PF connectSession: Attempting public key authentication.");
        if (m_config.privateKeyData.empty()) {
             OH_LOG_ERROR(LOG_APP, "PF connectSession: Public key auth failed: Private key data is empty.");
             goto cleanup_error;
        }
        do {
            ret = libssh2_userauth_publickey_frommemory(
                   m_pfSession.get(),
                   m_config.username.c_str(),
                   m_config.username.length(),
                   nullptr, 0, // Public key (optional)
                   m_config.privateKeyData.data(),
                   m_config.privateKeyData.length(),
                   m_config.passphrase.empty() ? nullptr : m_config.passphrase.c_str());

            if (ret == LIBSSH2_ERROR_EAGAIN) {
                int ws_rc = waitSocket(m_pfSession.get(), *m_pfSock);
                if (ws_rc < 0) {
                     OH_LOG_ERROR(LOG_APP, "PF connectSession: waitSocket error during public key auth.");
                     goto cleanup_error;
                }
                if (time(nullptr) - startTime > authTimeout) {
                    OH_LOG_ERROR(LOG_APP, "PF connectSession: Public key auth timed out.");
                    goto cleanup_error;
                }
            } else if (ret != 0) {
                char* errmsg = nullptr;
                libssh2_session_last_error(m_pfSession.get(), &errmsg, nullptr, 0);
                OH_LOG_ERROR(LOG_APP, "PF connectSession: Public key authentication failed (ret=%{public}d): %{public}s", ret, errmsg ? errmsg : "N/A");
                goto cleanup_error;
            }
        } while (ret == LIBSSH2_ERROR_EAGAIN);
        OH_LOG_INFO(LOG_APP, "PF connectSession: Public key authentication successful.");
    } else {
        OH_LOG_INFO(LOG_APP, "PF connectSession: Attempting password authentication.");
        do {
            ret = libssh2_userauth_password(
                   m_pfSession.get(),
                   m_config.username.c_str(),
                   m_config.password.c_str());

            if (ret == LIBSSH2_ERROR_EAGAIN) {
                int ws_rc = waitSocket(m_pfSession.get(), *m_pfSock);
                if (ws_rc < 0) {
                     OH_LOG_ERROR(LOG_APP, "PF connectSession: waitSocket error during password auth.");
                     goto cleanup_error;
                }
                if (time(nullptr) - startTime > authTimeout) {
                    OH_LOG_ERROR(LOG_APP, "PF connectSession: Password auth timed out.");
                    goto cleanup_error;
                }
            } else if (ret != 0) {
                 char* errmsg = nullptr;
                 libssh2_session_last_error(m_pfSession.get(), &errmsg, nullptr, 0);
                 OH_LOG_ERROR(LOG_APP, "PF connectSession: Password authentication failed (ret=%{public}d): %{public}s", ret, errmsg ? errmsg : "N/A");
                 goto cleanup_error;
            }
        } while (ret == LIBSSH2_ERROR_EAGAIN);
        OH_LOG_INFO(LOG_APP, "PF connectSession: Password authentication successful.");
    }
    OH_LOG_INFO(LOG_APP, "PF connectSession: Authentication successful.");
    // --- Authentication End --- //

    // --- Configure Keepalive (Adapted from SftpSession::connect) ---
    // Note: SshPortForwardConfig doesn't have keepAliveInterval, maybe add it or use a default/main session value?
    // Using a default of 60 seconds for now if needed, or disable if not critical for PF.
    // int keepAliveIntervalPF = 60; // Example default
    if (m_config.keepAliveInterval > 0 && m_pfSession) { // Use m_config.keepAliveInterval
       OH_LOG_INFO(LOG_APP, "PF connectSession: Configuring libssh2 Keepalive (Interval: %{public}d)", m_config.keepAliveInterval);
       libssh2_keepalive_config(m_pfSession.get(), 1, m_config.keepAliveInterval);
    } else {
       OH_LOG_INFO(LOG_APP, "PF connectSession: libssh2 Keepalive disabled (interval <= 0).");
    }
    // --- Keepalive End --- //

    // --- Success --- //
    m_pfConnected.store(true);
    // Ensure session remains non-blocking for forwarding operations
    libssh2_session_set_blocking(m_pfSession.get(), 0);
    OH_LOG_INFO(LOG_APP, "SshPortForward::connectSession() successful. PF session connected and authenticated.");
    return true;

cleanup_error:
    OH_LOG_INFO(LOG_APP, "connectSession: Entering cleanup due to error.");
    m_pfSession.reset(); // Frees the libssh2 session
    if (*m_pfSock != LIBSSH2_INVALID_SOCKET) {
        close(*m_pfSock);
        *m_pfSock = LIBSSH2_INVALID_SOCKET;
    }
    m_pfConnected.store(false);
    return false;
}

void SshPortForward::disconnectSession() {
    OH_LOG_INFO(LOG_APP, "SshPortForward::disconnectSession() started.");
    std::lock_guard<std::recursive_mutex> lock(m_pfMutex); // Lock PF resources

    if (!m_pfConnected.load()) {
        OH_LOG_INFO(LOG_APP, "disconnectSession: Already disconnected or never connected.");
        return;
    }

    m_pfConnected.store(false);

    if (m_pfSession) {
        try {
            int disconnectAttempts = 0;
            // Use the PF session and socket for waitSocket
            while (disconnectAttempts < 3 &&
                   libssh2_session_disconnect(m_pfSession.get(), "PF session shutdown") == LIBSSH2_ERROR_EAGAIN) {
                if (m_pfSock && *m_pfSock != LIBSSH2_INVALID_SOCKET) {
                    waitSocket(m_pfSession.get(), *m_pfSock.get());
                } else {
                     OH_LOG_WARN(LOG_APP, "disconnectSession: Invalid socket during disconnect wait.");
                     break; // Cannot wait without socket
                }
                disconnectAttempts++;
            }
        } catch (const std::exception& e) {
            OH_LOG_ERROR(LOG_APP, "disconnectSession: Exception during libssh2_session_disconnect: %{public}s", e.what());
        } catch (...) {
            OH_LOG_ERROR(LOG_APP, "disconnectSession: Unknown exception during libssh2_session_disconnect.");
        }
        m_pfSession.reset();
        OH_LOG_INFO(LOG_APP, "disconnectSession: PF session reset.");
    }

    if (m_pfSock && *m_pfSock != LIBSSH2_INVALID_SOCKET) {
        try {
            shutdown(*m_pfSock, SHUT_RDWR);
            close(*m_pfSock);
             OH_LOG_INFO(LOG_APP, "disconnectSession: PF socket closed.");
        } catch (const std::exception& e) {
            OH_LOG_ERROR(LOG_APP, "disconnectSession: Exception closing socket: %{public}s", e.what());
        } catch (...) {
            OH_LOG_ERROR(LOG_APP, "disconnectSession: Unknown exception closing socket.");
        }
        *m_pfSock = LIBSSH2_INVALID_SOCKET;
    }

    OH_LOG_INFO(LOG_APP, "SshPortForward::disconnectSession() finished.");
}

int SshPortForward::waitSocket(LIBSSH2_SESSION* session, libssh2_socket_t sock) {
    struct timeval timeout;
    int rc;
    fd_set fd;
    fd_set *writefd = NULL;
    fd_set *readfd = NULL;
    int dir;

    timeout.tv_sec = 0;
    timeout.tv_usec = 50000; // 50ms timeout

    FD_ZERO(&fd);
    if (sock == LIBSSH2_INVALID_SOCKET) {
        OH_LOG_ERROR(LOG_APP, "SshPortForward::waitSocket: Invalid socket descriptor.");
        return -1;
    }
    FD_SET(sock, &fd);

    if (!session) {
        OH_LOG_ERROR(LOG_APP, "SshPortForward::waitSocket: Invalid session pointer.");
        return -1;
    }

    // Use the provided session to get block directions
    dir = libssh2_session_block_directions(session);

    if (dir & LIBSSH2_SESSION_BLOCK_INBOUND)
        readfd = &fd;

    if (dir & LIBSSH2_SESSION_BLOCK_OUTBOUND)
        writefd = &fd;

    // --- Loop to handle EINTR --- 
    do {
        rc = select((int)(sock + 1), readfd, writefd, NULL, &timeout);
    } while (rc < 0 && errno == EINTR);
    // --- End EINTR loop ---

    // rc = select((int)(sock + 1), readfd, writefd, NULL, &timeout); // Original call
    if (rc < 0) {
         // --- Enhanced error logging (Now after EINTR check) --- 
         int select_errno = errno; // errno is valid only if rc < 0 and not EINTR
         OH_LOG_ERROR(LOG_APP, "SshPortForward::waitSocket: select failed with rc=%{public}d, errno=%{public}d (%{public}s). Socket=%{public}d, Session=%{public}p", 
                      rc, select_errno, strerror(select_errno), sock, session);
         // --- End enhanced logging ---
         // Original log:
         // OH_LOG_ERROR(LOG_APP, "SshPortForward::waitSocket: select error: %s", strerror(errno));
    }
    return rc;
}

int SshPortForward::createListenSocket(int port, bool anyInterface) {
    int listenSocket = socket(AF_INET, SOCK_STREAM, 0);
    if (listenSocket < 0) {
        OH_LOG_ERROR(LOG_APP, "Failed to create listen socket: %s", strerror(errno));
        return -1;
    }

    int flags = fcntl(listenSocket, F_GETFL, 0);
    if (flags == -1 || fcntl(listenSocket, F_SETFL, flags | O_NONBLOCK) == -1) {
        OH_LOG_ERROR(LOG_APP, "Failed to set socket non-blocking: %s", strerror(errno));
        close(listenSocket);
        return -1;
    }

    int optval = 1;
    if (setsockopt(listenSocket, SOL_SOCKET, SO_REUSEADDR, &optval, sizeof(optval)) < 0) {
        OH_LOG_ERROR(LOG_APP, "setsockopt(SO_REUSEADDR) failed: %s", strerror(errno));
        close(listenSocket);
        return -1;
    }

    struct sockaddr_in sin;
    memset(&sin, 0, sizeof(sin));
    sin.sin_family = AF_INET;
    sin.sin_port = htons(port);
    sin.sin_addr.s_addr = anyInterface ? htonl(INADDR_ANY) : htonl(INADDR_LOOPBACK);

    if (::bind(listenSocket, (struct sockaddr*)&sin, sizeof(sin)) < 0) {
        OH_LOG_ERROR(LOG_APP, "bind() failed for port %{public}d: %{public}s", port, strerror(errno));
        close(listenSocket);
        return -1;
    }

    if (listen(listenSocket, 10) < 0) {
        OH_LOG_ERROR(LOG_APP, "listen() failed: %{public}s", strerror(errno));
        close(listenSocket);
        return -1;
    }

    OH_LOG_INFO(LOG_APP, "Listening on port %{public}d (%{public}s)", port, anyInterface ? "any interface" : "localhost");
    return listenSocket;
}

void SshPortForward::closeListenSocket(int socket) {
    if (socket >= 0) {
        OH_LOG_INFO(LOG_APP, "Closing listen socket %{public}d", socket);
        shutdown(socket, SHUT_RDWR);
        close(socket);
    }
}

void SshPortForward::localPortForwardingThread(std::shared_ptr<PortForwardData> data) {
    if (!data || !m_mainSession || !m_mainSession->getThreadPool()) {
        OH_LOG_ERROR(LOG_APP, "Local/Dynamic Forward Thread: Invalid main session, data, or thread pool.");
        if(data) data->running = false;
        return;
    }

    data->listenSocket = createListenSocket(data->localPort, data->anyInterface);
    if (data->listenSocket < 0) {
        OH_LOG_ERROR(LOG_APP, "Failed to create listen socket for port %d", data->localPort);
        data->running = false;
        return;
    }

    OH_LOG_INFO(LOG_APP, "%s port forwarding started - Listening on: %d",
                data->isDynamic ? "Dynamic" : "Local", data->localPort);
    data->running = true;

    while (!data->shouldStop) {
        fd_set readfds;
        FD_ZERO(&readfds);
        FD_SET(data->listenSocket, &readfds);

        struct timeval timeout;
        timeout.tv_sec = 0;
        timeout.tv_usec = 500000;

        int result = select(data->listenSocket + 1, &readfds, NULL, NULL, &timeout);

        if (data->shouldStop) break;

        if (result < 0) {
            if (errno != EINTR) {
                OH_LOG_ERROR(LOG_APP, "select() error on listen socket %d: %s", data->listenSocket, strerror(errno));
                data->shouldStop = true;
            }
            continue;
        }

        if (result > 0 && FD_ISSET(data->listenSocket, &readfds)) {
            struct sockaddr_in client_addr;
            socklen_t addr_len = sizeof(client_addr);
            int clientSocket = accept(data->listenSocket, (struct sockaddr*)&client_addr, &addr_len);

            if (data->shouldStop) {
                 if (clientSocket >= 0) close(clientSocket);
                 break;
            }

            if (clientSocket >= 0) {
                OH_LOG_INFO(LOG_APP, "Accepted new connection on port %{public}d from %{public}s:%{public}d, client_socket=%{public}d",
                            data->localPort, inet_ntoa(client_addr.sin_addr), ntohs(client_addr.sin_port), clientSocket);

                int flags = fcntl(clientSocket, F_GETFL, 0);
                if (flags != -1) {
                   fcntl(clientSocket, F_SETFL, flags | O_NONBLOCK);
                }

                try {
                    if (data->isDynamic) {
                         m_mainSession->getThreadPool()->enqueue([this, clientSocket, data]() {
                            if (!m_mainSession || !m_mainSession->isConnected()) {
                                OH_LOG_ERROR(LOG_APP, "Dynamic Fwd Task: Session invalid or disconnected before handling socket %{public}d.", clientSocket);
                                close(clientSocket);
                                return;
                            }
                            if (data->shouldStop) {
                                OH_LOG_WARN(LOG_APP, "Dynamic Fwd Task: Forwarding stopped before handling socket %{public}d.", clientSocket);
                                close(clientSocket);
                                return;
                            }
                            OH_LOG_INFO(LOG_APP, "Dynamic Fwd Task: Starting to handle client socket %{public}d for port %{public}d.", clientSocket, data->localPort);
                            handleDynamicForwardConnection(clientSocket, data);
                         });
                    } else {
                         m_mainSession->getThreadPool()->enqueue([this, clientSocket, data]() {
                            if (!m_mainSession || !m_mainSession->isConnected()) {
                                OH_LOG_ERROR(LOG_APP, "Local Fwd Task: Session invalid or disconnected before handling socket %{public}d.", clientSocket);
                                close(clientSocket);
                                return;
                            }
                            if (data->shouldStop) {
                                OH_LOG_WARN(LOG_APP, "Local Fwd Task: Forwarding stopped before handling socket %{public}d.", clientSocket);
                                close(clientSocket);
                                return;
                            }
                            OH_LOG_INFO(LOG_APP, "Local Fwd Task: Starting to handle client socket %{public}d for port %{public}d.", clientSocket, data->localPort);
                            handleLocalForwardConnection(clientSocket, data);
                         });
                    }
                    OH_LOG_INFO(LOG_APP, "Enqueued connection handler task for client socket %{public}d (port %{public}d)", clientSocket, data->localPort);
                } catch (const std::runtime_error& e) {
                    OH_LOG_ERROR(LOG_APP, "Failed to enqueue connection task for port %{public}d: %{public}s", data->localPort, e.what());
                    close(clientSocket);
                } catch (const std::system_error& e) {
                     OH_LOG_ERROR(LOG_APP, "System error creating connection task for port %d: %s", data->localPort, e.what());
                     close(clientSocket);
                }
            } else {
                 if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR && errno != ECONNABORTED && errno != EPROTO) {
                    OH_LOG_ERROR(LOG_APP, "accept() error on listen socket %d: %s", data->listenSocket, strerror(errno));
                 }
            }
        }
    }

    OH_LOG_INFO(LOG_APP, "%s port forwarding stopping - Port: %d", data->isDynamic ? "Dynamic" : "Local", data->localPort);

    if (data->listenSocket >= 0) {
        closeListenSocket(data->listenSocket);
        data->listenSocket = -1;
    }

    data->shouldStop.store(true);

    data->running = false;
    OH_LOG_INFO(LOG_APP, "%s port forwarding stopped - Port: %d", data->isDynamic ? "Dynamic" : "Local", data->localPort);
}

void SshPortForward::remotePortForwardingThread(std::shared_ptr<PortForwardData> data) {
     if (!data || !m_mainSession || !m_mainSession->getThreadPool() || !m_pfConnected.load()) {
        OH_LOG_ERROR(LOG_APP, "Remote forward setup failed: Invalid main session, data, thread pool or PF session not connected.");
        if(data) data->running = false;
        return;
    }

    LIBSSH2_SESSION* pfSessionPtr = nullptr;
    LIBSSH2_LISTENER* listener = nullptr;
    int bound_port = 0;
    bool listener_started = false;

    OH_LOG_INFO(LOG_APP, "Requesting remote forward listen on port %d using PF session.", data->localPort);

    {
        std::unique_lock<std::recursive_mutex> lock(m_pfMutex);
        pfSessionPtr = m_pfSession.get();
        if (!pfSessionPtr) {
             OH_LOG_ERROR(LOG_APP, "Remote forward setup failed: Invalid internal PF libssh2 session.");
             data->running = false;
             return;
        }

        int rc = 0;
        const char* listen_host = "0.0.0.0";
        
        int listen_attempts = 0;
        const int max_listen_attempts = 100;
        while (!data->shouldStop) {
             listener = libssh2_channel_forward_listen_ex(pfSessionPtr, listen_host, data->localPort, &bound_port, 10);
             if (listener) {
                 listener_started = true;
                 break;
             }

             rc = libssh2_session_last_error(pfSessionPtr, NULL, NULL, 0);
             if (rc == LIBSSH2_ERROR_EAGAIN) {
                 if (++listen_attempts > max_listen_attempts) {
                      OH_LOG_ERROR(LOG_APP, "Remote forward setup: Timeout waiting for listener after %d attempts.", max_listen_attempts);
                      break;
                 }
                 lock.unlock();
                 OH_LOG_DEBUG(LOG_APP, "Remote forward setup: Waiting for socket (listen EAGAIN, attempt %d).", listen_attempts);
                 waitSocket(m_pfSession.get(), *m_pfSock.get());
                 lock.lock();
                 pfSessionPtr = m_pfSession.get();
                 if (!pfSessionPtr || !m_pfConnected.load()) { 
                      OH_LOG_ERROR(LOG_APP, "Remote forward setup: PF Session became invalid while waiting for listener.");
                      break;
                 }
                 continue;
             } else {
                  OH_LOG_ERROR(LOG_APP, "libssh2_channel_forward_listen_ex failed: %{public}d", rc);
                  break;
             }
        }

        if (!listener_started) {
            OH_LOG_ERROR(LOG_APP, "Failed to start remote listener on port %d (Stopped: %d)", data->localPort, data->shouldStop.load());
            data->running = false;
            return;
        }
        data->listener = listener;
        OH_LOG_INFO(LOG_APP, "Remote forward listening started on remote port %d (bound: %d)", data->localPort, bound_port);
    }

    data->running = true;

    while (!data->shouldStop) {
        LIBSSH2_CHANNEL* channel = nullptr;

        {
            std::unique_lock<std::recursive_mutex> lock(m_pfMutex);
            pfSessionPtr = m_pfSession.get();
            if (!pfSessionPtr || !data->listener) {
                 OH_LOG_WARN(LOG_APP, "Remote forward accept loop: Invalid session or listener. Stopping.");
                 data->shouldStop = true;
                 break;
            }

            channel = libssh2_channel_forward_accept(data->listener);
            int rc = 0;
             if (!channel) {
                 rc = libssh2_session_last_error(pfSessionPtr, NULL, NULL, 0);
                 if (rc == LIBSSH2_ERROR_EAGAIN) {
                      lock.unlock();
                      waitSocket(m_pfSession.get(), *m_pfSock.get());
                 } else if (rc == LIBSSH2_ERROR_CHANNEL_CLOSED) {
                     OH_LOG_INFO(LOG_APP, "Remote forward listener/channel closed (rc=%d). Stopping.", rc);
                     data->shouldStop = true;
                     break;
                 } else {
                     OH_LOG_ERROR(LOG_APP, "libssh2_channel_forward_accept failed: %{public}d. Stopping.", rc);
                      data->shouldStop = true;
                     break;
                 }
             }
        }

        if (data->shouldStop) break;

        if (channel) {
             OH_LOG_INFO(LOG_APP, "Accepted remote forwarded connection for port %d", data->localPort);

             try {
                 m_mainSession->getThreadPool()->enqueue([this, channel, data]() {
                     handleRemoteForwardConnection(channel, data);
                 });
                 OH_LOG_INFO(LOG_APP, "Enqueued remote connection handler task for port %d", data->localPort);
             } catch (const std::runtime_error& e) {
                 OH_LOG_ERROR(LOG_APP, "Failed to enqueue remote connection task for port %d: %s", data->localPort, e.what());
                 std::lock_guard<std::recursive_mutex> sshLock(m_pfMutex);
                 libssh2_channel_free(channel);
             } catch (const std::system_error& e) {
                 OH_LOG_ERROR(LOG_APP, "System error creating remote connection task for port %d: %s", data->localPort, e.what());
                 std::lock_guard<std::recursive_mutex> sshLock(m_pfMutex);
                 libssh2_channel_free(channel);
             }
        }
    }

    OH_LOG_INFO(LOG_APP, "Remote port forwarding stopping - Remote Port: %d", data->localPort);

    if (data->listener && m_pfConnected.load()) {
         OH_LOG_INFO(LOG_APP, "Cancelling remote listener for port %d using PF session", data->localPort);
         std::unique_lock<std::recursive_mutex> lock(m_pfMutex);
         LIBSSH2_SESSION* session = nullptr;
         session = m_pfSession.get();
         if (session && data->listener) {
             int rc = 0;
             int cancel_attempts = 0;
             while ((rc = libssh2_channel_forward_cancel(data->listener)) == LIBSSH2_ERROR_EAGAIN && cancel_attempts < 5) {
                 lock.unlock();
                 waitSocket(session, *m_pfSock.get());
                 lock.lock();
                 session = m_pfSession.get();
                 if(!session) {
                      OH_LOG_WARN(LOG_APP,"Session became invalid while waiting for listener cancel.");
                      break;
                 }
                 cancel_attempts++;
             }
             if (rc != 0 && rc != LIBSSH2_ERROR_EAGAIN) {
                  OH_LOG_ERROR(LOG_APP, "Failed to cancel remote listener: %d", rc);
             } else {
                  OH_LOG_INFO(LOG_APP, "Remote listener cancelled or cancel attempt finished.");
             }
         } else {
              OH_LOG_WARN(LOG_APP, "Cannot cancel remote listener: session invalid or listener already null.");
         }
         data->listener = nullptr;
    }

    data->shouldStop.store(true);

    data->running = false;
    OH_LOG_INFO(LOG_APP, "Remote port forwarding stopped - Remote Port: %d", data->localPort);
}

void SshPortForward::handleLocalForwardConnection(int clientSocket, std::shared_ptr<PortForwardData> data) {
    OH_LOG_INFO(LOG_APP, "Local Forward Handler: Entered for client socket %{public}d.", clientSocket);

    if (!data || !m_mainSession || !m_mainSession->isConnected()) {
        OH_LOG_ERROR(LOG_APP, "Local Forward: Invalid session or data for client socket %{public}d.", clientSocket);
        close(clientSocket);
        return;
    }

    OH_LOG_INFO(LOG_APP, "Local Forward: Handling connection for client socket %{public}d -> %{public}s:%{public}d",
                 clientSocket, data->targetHost.c_str(), data->targetPort);

    LIBSSH2_CHANNEL* channel = nullptr;
    LIBSSH2_SESSION* session = nullptr;
    int rc = 0;

    {
        std::unique_lock<std::recursive_mutex> lock(m_pfMutex);
        session = m_pfSession.get();
        if (!session) {
            OH_LOG_ERROR(LOG_APP, "Local Forward: Cannot open channel, invalid libssh2 session initially.");
            close(clientSocket);
            return;
        }

        int wait_attempts = 0;
        const int max_wait_attempts = 100;

        OH_LOG_INFO(LOG_APP, "Local Forward [Socket %{public}d]: Entering channel creation loop.", clientSocket);
        while (true) { 
            channel = libssh2_channel_direct_tcpip_ex(session, data->targetHost.c_str(), data->targetPort, "127.0.0.1", 22);
            
            if (channel != NULL) {
                OH_LOG_INFO(LOG_APP, "Local Forward [Socket %{public}d]: libssh2_channel_direct_tcpip_ex succeeded. Channel ptr: %{public}p", clientSocket, channel);
                rc = 0; 
                break; 
            }

            rc = libssh2_session_last_error(session, NULL, NULL, 0);
            OH_LOG_INFO(LOG_APP, "Local Forward [Socket %{public}d]: libssh2_channel_direct_tcpip_ex returned NULL, rc=%{public}d", clientSocket, rc);

            if (rc == LIBSSH2_ERROR_EAGAIN) {
                 if (data->shouldStop.load()) {
                     OH_LOG_WARN(LOG_APP, "Local Forward [Socket %{public}d]: Forwarding stopped during channel creation.", clientSocket);
                     break; 
                 }
                 if (++wait_attempts > max_wait_attempts) {
                     OH_LOG_ERROR(LOG_APP, "Local Forward [Socket %{public}d]: Timeout waiting for channel after %{public}d attempts.", clientSocket, max_wait_attempts);
                     rc = LIBSSH2_ERROR_TIMEOUT; 
                     break;
                 }

                 OH_LOG_INFO(LOG_APP, "Local Forward [Socket %{public}d]: Got EAGAIN, unlocking and waiting (Attempt %{public}d/%{public}d)...", clientSocket, wait_attempts, max_wait_attempts);
                 lock.unlock(); 
                 int ws_rc = waitSocket(session, *m_pfSock.get()); 
                 OH_LOG_INFO(LOG_APP, "Local Forward [Socket %{public}d]: waitSocket returned %{public}d. Relocking...", clientSocket, ws_rc);
                 lock.lock(); 
                 OH_LOG_INFO(LOG_APP, "Local Forward [Socket %{public}d]: Relocked.", clientSocket);
 
                 session = m_pfSession.get(); 
                 bool stillConnected = m_pfConnected.load(); 
                 if (!session || !stillConnected) {
                     OH_LOG_ERROR(LOG_APP, "Local Forward [Socket %{public}d]: Session became invalid (ptr=%{public}p) or disconnected (connected=%{public}d) immediately after wait/relock.", clientSocket, session, stillConnected);
                     rc = LIBSSH2_ERROR_SOCKET_DISCONNECT; 
                     break; 
                 }
                 OH_LOG_INFO(LOG_APP, "Local Forward [Socket %{public}d]: Session still valid after wait. Retrying channel creation.", clientSocket);

            } else {
                 OH_LOG_ERROR(LOG_APP, "Local Forward [Socket %{public}d]: libssh2_channel_direct_tcpip_ex failed: %{public}d", clientSocket, rc);
                 channel = nullptr; 
                 break; 
            }
        } 
        OH_LOG_INFO(LOG_APP, "Local Forward [Socket %{public}d]: Exited channel creation loop. Channel ptr: %{public}p, Final rc: %{public}d", clientSocket, channel, rc);
    } 

    if (!channel || rc != 0 || data->shouldStop.load()) {
        OH_LOG_ERROR(LOG_APP, "Local Forward [Socket %{public}d]: Failed to establish SSH channel to %{public}s:%{public}d (rc=%{public}d, stopped=%{public}d).", clientSocket, data->targetHost.c_str(), data->targetPort, rc, data->shouldStop.load());
        close(clientSocket);
        if (channel) {
             std::lock_guard<std::recursive_mutex> freeLock(m_pfMutex);
             if (m_pfSession) {
                libssh2_channel_free(channel);
             }
        }
        return;
    }

    OH_LOG_INFO(LOG_APP, "Local Forward: SSH channel established for socket %{public}d. Starting data loop.", clientSocket);

    forwardDataLoop(clientSocket, channel, data);
    OH_LOG_INFO(LOG_APP, "Local Forward: Data loop finished for client socket %{public}d.", clientSocket);
}

void SshPortForward::handleRemoteForwardConnection(LIBSSH2_CHANNEL* channel, std::shared_ptr<PortForwardData> data) {
    OH_LOG_INFO(LOG_APP, "Remote Forward Handler: Entered for channel %{public}p.", channel);

     if (!data || !m_mainSession || !channel) {
         OH_LOG_ERROR(LOG_APP, "Remote Forward: Invalid session, data, or channel.");
         if (channel && m_pfConnected.load()) {
             std::lock_guard<std::recursive_mutex> lock(m_pfMutex);
             libssh2_channel_free(channel);
         }
         return;
     }

    OH_LOG_INFO(LOG_APP, "Remote Forward: Handling connection for channel (ptr=%{public}p) to local target %{public}s:%{public}d",
                 channel, data->targetHost.c_str(), data->targetPort);

    int targetSocket = socket(AF_INET, SOCK_STREAM, 0);
    if (targetSocket < 0) {
        OH_LOG_ERROR(LOG_APP, "Remote Forward: Failed to create target socket: %s", strerror(errno));
         std::lock_guard<std::recursive_mutex> lock(m_pfMutex);
         libssh2_channel_free(channel);
         return;
    }

    struct sockaddr_in target_addr;
    memset(&target_addr, 0, sizeof(target_addr));
    target_addr.sin_family = AF_INET;
    target_addr.sin_port = htons(data->targetPort);
    if (inet_pton(AF_INET, data->targetHost.c_str(), &target_addr.sin_addr) <= 0) {
         OH_LOG_ERROR(LOG_APP, "Remote Forward: Invalid target IP address %s", data->targetHost.c_str());
         close(targetSocket);
         std::lock_guard<std::recursive_mutex> lock(m_pfMutex);
         libssh2_channel_free(channel);
         return;
    }

    if (connect(targetSocket, (struct sockaddr*)&target_addr, sizeof(target_addr)) < 0) {
         OH_LOG_ERROR(LOG_APP, "Remote Forward: Failed to connect to target %s:%d : %s",
                      data->targetHost.c_str(), data->targetPort, strerror(errno));
         close(targetSocket);
         std::lock_guard<std::recursive_mutex> lock(m_pfMutex);
         libssh2_channel_free(channel);
         return;
    }
    
    int flags = fcntl(targetSocket, F_GETFL, 0);
    if (flags != -1) {
       fcntl(targetSocket, F_SETFL, flags | O_NONBLOCK);
    }


    OH_LOG_INFO(LOG_APP, "Remote Forward: Connected to local target %{public}s:%{public}d on socket %{public}d. Starting data loop.", data->targetHost.c_str(), data->targetPort, targetSocket);
    forwardDataLoop(targetSocket, channel, data);
    OH_LOG_INFO(LOG_APP, "Remote Forward: Data loop finished for target socket %{public}d (%{public}s:%{public}d).", targetSocket, data->targetHost.c_str(), data->targetPort);
}

void SshPortForward::handleDynamicForwardConnection(int clientSocket, std::shared_ptr<PortForwardData> data) {
    OH_LOG_INFO(LOG_APP, "Dynamic Forward Handler: Entered for client socket %{public}d.", clientSocket);

    if (!data || !m_mainSession || !m_mainSession->isConnected() || data->shouldStop) {
        OH_LOG_ERROR(LOG_APP, "Dynamic Forward: Invalid session/data or stopping for client socket %{public}d.", clientSocket);
        close(clientSocket);
        return;
    }
    OH_LOG_INFO(LOG_APP, "Dynamic Forward: Handling SOCKS request from client %{public}d", clientSocket);

    char greeting[260];
    fd_set readfds;
    FD_ZERO(&readfds);
    FD_SET(clientSocket, &readfds);
    struct timeval timeout;
    timeout.tv_sec = 5;
    timeout.tv_usec = 0;
    int sel_ret = select(clientSocket + 1, &readfds, NULL, NULL, &timeout);

    if (data->shouldStop) { close(clientSocket); return; }

    if (sel_ret <= 0) {
         OH_LOG_ERROR(LOG_APP, "Dynamic Forward: Timeout or error waiting for SOCKS greeting (ret=%d, errno=%d)", sel_ret, errno);
         close(clientSocket);
         return;
    }

    ssize_t n = recv(clientSocket, greeting, sizeof(greeting), 0);
    if (n <= 2 || greeting[0] != 0x05) {
        // Log the first few bytes to help diagnose the protocol being used
        std::string hexDump = "";
        for (int i = 0; i < std::min((int)n, 20); i++) {
            char hex[4];
            snprintf(hex, sizeof(hex), "%02X ", (unsigned char)greeting[i]);
            hexDump += hex;
        }
        OH_LOG_ERROR(LOG_APP, "Dynamic Forward: Invalid SOCKS5 greeting (n=%{public}zd, VER=%{public}d, first_char='%c', hex_dump=%s)", 
                     n, n > 0 ? greeting[0] : -1, n > 0 && isprint(greeting[0]) ? greeting[0] : '?', hexDump.c_str());
        OH_LOG_ERROR(LOG_APP, "Dynamic Forward: Client may be using HTTP CONNECT instead of SOCKS5. Please ensure your browser/application is configured for SOCKS5 proxy, not HTTP proxy.");

        close(clientSocket);
        return;
    }
    bool noAuthSupported = false;
    int nmethods = greeting[1];
    for (int i = 0; i < nmethods && (2 + i) < n; ++i) {
        if (greeting[2 + i] == 0x00) {
            noAuthSupported = true;
            break;
        }
    }
    if (!noAuthSupported) {
         OH_LOG_ERROR(LOG_APP, "Dynamic Forward: SOCKS5 No Authentication Required (0x00) not supported by client.");
         char response[] = {0x05, 0xFF};
         send(clientSocket, response, sizeof(response), MSG_NOSIGNAL);
         close(clientSocket);
         return;
    }
    char response[] = {0x05, 0x00};
    if (send(clientSocket, response, sizeof(response), MSG_NOSIGNAL) != sizeof(response)) {
         OH_LOG_ERROR(LOG_APP, "Dynamic Forward: Failed to send SOCKS5 method choice: %s", strerror(errno));
         close(clientSocket);
         return;
    }
    OH_LOG_INFO(LOG_APP, "Dynamic Forward: SOCKS5 Handshake successful (No Auth).");


    char request[300];
    FD_ZERO(&readfds);
    FD_SET(clientSocket, &readfds);
    timeout.tv_sec = 10;
    timeout.tv_usec = 0;
    sel_ret = select(clientSocket + 1, &readfds, NULL, NULL, &timeout);

    if (data->shouldStop) { close(clientSocket); return; }

    if (sel_ret <= 0) {
         OH_LOG_ERROR(LOG_APP, "Dynamic Forward: Timeout or error waiting for SOCKS request (ret=%d, errno=%d)", sel_ret, errno);
         close(clientSocket);
         return;
    }

    n = recv(clientSocket, request, sizeof(request), 0);
    if (n < 10 || request[0] != 0x05) {
         OH_LOG_ERROR(LOG_APP, "Dynamic Forward: Invalid SOCKS5 request (n=%zd, VER=%d)", n, n > 0 ? request[0] : -1);
         close(clientSocket);
         return;
    }
    if (request[1] != 0x01) {
        OH_LOG_ERROR(LOG_APP, "Dynamic Forward: Unsupported SOCKS5 command %d", request[1]);
        char reply[] = {0x05, 0x07, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00};
        send(clientSocket, reply, sizeof(reply), MSG_NOSIGNAL);
        close(clientSocket);
        return;
    }

    std::string targetHost = "";
    int targetPort = 0;
    int atyp = request[3];
    char* current = request + 4;
    int addr_len = 0;

    if (atyp == 0x01) {
        addr_len = 4;
        if (n < 4 + addr_len + 2) {
             OH_LOG_ERROR(LOG_APP,"Dyn Fwd: Short SOCKS IPv4 request (n=%zd)", n);
             close(clientSocket); return;
        }
        char ip_str[INET_ADDRSTRLEN];
        if (inet_ntop(AF_INET, current, ip_str, sizeof(ip_str))) {
             targetHost = ip_str;
        } else {
             OH_LOG_ERROR(LOG_APP, "Dyn Fwd: inet_ntop failed for IPv4.");
             char reply[] = {0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0};
             send(clientSocket, reply, sizeof(reply), MSG_NOSIGNAL);
             close(clientSocket); return;
        }
        current += addr_len;
        targetPort = ntohs(*(reinterpret_cast<uint16_t*>(current)));
    } else if (atyp == 0x03) {
        addr_len = (unsigned char)(*current);
        current += 1;
        if (n < 4 + 1 + addr_len + 2) {
            OH_LOG_ERROR(LOG_APP,"Dyn Fwd: Short SOCKS Domain request (n=%zd, len=%d)", n, addr_len);
            close(clientSocket); return;
        }
        targetHost.assign(current, addr_len);
        current += addr_len;
        targetPort = ntohs(*(reinterpret_cast<uint16_t*>(current)));
    } else if (atyp == 0x04) {
         addr_len = 16;
         if (n < 4 + addr_len + 2) {
             OH_LOG_ERROR(LOG_APP,"Dyn Fwd: Short SOCKS IPv6 request (n=%zd)", n);
             close(clientSocket); return;
         }
         char ip_str[INET6_ADDRSTRLEN];
         if (inet_ntop(AF_INET6, current, ip_str, sizeof(ip_str))) {
              targetHost = ip_str;
         } else {
              OH_LOG_ERROR(LOG_APP, "Dyn Fwd: inet_ntop failed for IPv6.");
              char reply[] = {0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0};
              send(clientSocket, reply, sizeof(reply), MSG_NOSIGNAL);
              close(clientSocket); return;
         }
         current += addr_len;
         targetPort = ntohs(*(reinterpret_cast<uint16_t*>(current)));
         OH_LOG_INFO(LOG_APP, "Dynamic Forward: Parsed IPv6 target.");
    } else {
         OH_LOG_ERROR(LOG_APP, "Dynamic Forward: Invalid SOCKS5 address type %d", atyp);
         char reply[] = {0x05, 0x08, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00};
         send(clientSocket, reply, sizeof(reply), MSG_NOSIGNAL);
         close(clientSocket);
         return;
    }

    OH_LOG_INFO(LOG_APP, "Dynamic Forward: SOCKS Request Parsed. Target: %s:%d (ATYP=%d)", targetHost.c_str(), targetPort, atyp);

    LIBSSH2_CHANNEL* channel = nullptr;
    LIBSSH2_SESSION* session = nullptr;
    int ssh_rc = 0;
    {
        std::unique_lock<std::recursive_mutex> lock(m_pfMutex);
        session = m_pfSession.get();
        if (!session) {
            OH_LOG_ERROR(LOG_APP, "Dynamic Forward: Cannot open channel, invalid libssh2 session.");
             char reply[] = {0x05, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00};
             send(clientSocket, reply, sizeof(reply), MSG_NOSIGNAL);
            close(clientSocket);
            return;
        }

        while (!data->shouldStop) {
            const char* originator_ip = "127.0.0.1";
            int originator_port = 22;

            channel = libssh2_channel_direct_tcpip_ex(session, targetHost.c_str(), targetPort,
                                                      originator_ip, originator_port);
            if (channel) break;

            ssh_rc = libssh2_session_last_error(session, NULL, NULL, 0);
            if (ssh_rc == LIBSSH2_ERROR_EAGAIN) {
                 lock.unlock();
                 waitSocket(session, *m_pfSock.get());
                 lock.lock();
                 session = m_pfSession.get();
                 if (!session) {
                     OH_LOG_ERROR(LOG_APP, "Dynamic Forward: Session became invalid while waiting for channel.");
                     ssh_rc = LIBSSH2_ERROR_SOCKET_DISCONNECT;
                     break;
                 }
                 continue;
            } else {
                 OH_LOG_ERROR(LOG_APP, "Dynamic Forward: libssh2_channel_direct_tcpip_ex failed: %d", ssh_rc);
                 break;
            }
        }
    }

    if (data->shouldStop) {
        OH_LOG_INFO(LOG_APP, "Dynamic Forward: Stopped during SSH channel creation.");
        if (channel) {
            std::lock_guard<std::recursive_mutex> lock(m_pfMutex);
            libssh2_channel_free(channel);
        }
        close(clientSocket);
        return;
    }

    if (!channel) {
        OH_LOG_ERROR(LOG_APP, "Dynamic Forward: Failed to establish SSH channel to %s:%d.", targetHost.c_str(), targetPort);
        char socks_reply_code = 0x01;
        if (ssh_rc == LIBSSH2_ERROR_SOCKET_TIMEOUT || ssh_rc == LIBSSH2_ERROR_TIMEOUT) socks_reply_code = 0x06;
        else if (ssh_rc == LIBSSH2_ERROR_SOCKET_DISCONNECT || ssh_rc == LIBSSH2_ERROR_SOCKET_SEND) socks_reply_code = 0x03;

        char reply[] = {0x05, socks_reply_code, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00};
        send(clientSocket, reply, sizeof(reply), MSG_NOSIGNAL);
        close(clientSocket);
        return;
    }

    char successReply[] = {0x05, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00};
    if (send(clientSocket, successReply, sizeof(successReply), MSG_NOSIGNAL) != sizeof(successReply)) {
        OH_LOG_ERROR(LOG_APP, "Dynamic Forward: Failed to send SOCKS5 success reply: %s", strerror(errno));
        close(clientSocket);
        std::lock_guard<std::recursive_mutex> lock(m_pfMutex);
        if(m_pfSession) libssh2_channel_free(channel);
        return;
    }
    OH_LOG_INFO(LOG_APP, "Dynamic Forward: SOCKS5 Connect successful for client socket %{public}d, SSH channel established (ptr=%{public}p).", clientSocket, channel);

    OH_LOG_INFO(LOG_APP, "Dynamic Forward: Starting data loop for client socket %{public}d -> %{public}s:%{public}d.", clientSocket, targetHost.c_str(), targetPort);
    forwardDataLoop(clientSocket, channel, data);
    OH_LOG_INFO(LOG_APP, "Dynamic Forward: Data loop finished for client socket %{public}d.", clientSocket);
}

void SshPortForward::forwardDataLoop(int socket_fd, LIBSSH2_CHANNEL* channel, std::shared_ptr<PortForwardData> data) {
    if (!m_mainSession || !channel || socket_fd < 0 || data->shouldStop) {
        OH_LOG_ERROR(LOG_APP, "Forward Loop: Invalid parameters or stopped. Socket: %{public}d, Channel: %{public}p, Stopped: %{public}d",
                     socket_fd, channel, data ? data->shouldStop.load() : -1);
        if (socket_fd >= 0) close(socket_fd);
        if (channel && m_pfConnected.load()) {
            std::lock_guard<std::recursive_mutex> lock(m_pfMutex);
            libssh2_channel_free(channel);
        }
        return;
    }

    fd_set read_fds, write_fds;
    struct timeval timeout;
    char buffer[READ_MAX_BUFF_SIZE];
    ssize_t nread, nwritten;
    int rc;
    bool socket_closed = false;
    bool channel_closed = false;
    libssh2_socket_t ssh_socket = LIBSSH2_INVALID_SOCKET;
    bool socket_eof_received = false;
    bool channel_eof_received = false;

    {
         std::lock_guard<std::recursive_mutex> lock(m_pfMutex);
         if (!m_pfSession || !m_pfSock) {
              OH_LOG_ERROR(LOG_APP, "Forward Loop: PF session or socket became invalid.");
              close(socket_fd);
              return;
         }
         ssh_socket = *m_pfSock;
         if (channel) {
             libssh2_channel_set_blocking(channel, 0);
         } else {
              OH_LOG_ERROR(LOG_APP, "Forward Loop: Channel became invalid before setting non-blocking.");
               close(socket_fd);
               return;
         }
    }
     if (ssh_socket == LIBSSH2_INVALID_SOCKET) {
         OH_LOG_ERROR(LOG_APP, "Forward Loop: Invalid PF SSH socket.");
         close(socket_fd);
         return;
     }


    OH_LOG_INFO(LOG_APP, "Forward Loop: Starting between socket %{public}d and SSH channel %{public}p (PF session).", socket_fd, channel);

    while (!socket_closed && !channel_closed && !data->shouldStop.load()) {
        FD_ZERO(&read_fds);
        FD_ZERO(&write_fds);

        if (!socket_eof_received) FD_SET(socket_fd, &read_fds);
        if (!channel_eof_received) FD_SET(ssh_socket, &read_fds);

        int max_fd = std::max((int)ssh_socket, socket_fd);

        timeout.tv_sec = 0;
        timeout.tv_usec = 500000;

        rc = select(max_fd + 1, &read_fds, NULL, NULL, &timeout);

        if (data->shouldStop.load()) {
            OH_LOG_INFO(LOG_APP, "Forward Loop [S:%{public}d C:%{public}p]: Stop requested, breaking loop.", socket_fd, channel);
            break;
        }

        if (rc < 0) {
            if (errno != EINTR) {
                OH_LOG_ERROR(LOG_APP, "Forward Loop [S:%{public}d C:%{public}p]: select() error: %{public}s", socket_fd, channel, strerror(errno));
                break;
            }
            OH_LOG_INFO(LOG_APP, "Forward Loop [S:%{public}d C:%{public}p]: select() interrupted by EINTR, continuing.", socket_fd, channel);
            continue;
        }

        if (rc == 0) {
            std::lock_guard<std::recursive_mutex> lock(m_pfMutex);
            if (!channel_eof_received && channel && libssh2_channel_eof(channel)) {
                 OH_LOG_INFO(LOG_APP, "Forward Loop [S:%{public}d C:%{public}p]: Channel EOF detected via libssh2_channel_eof flag check.", socket_fd, channel);
                 channel_eof_received = true;
                 if (!socket_closed) {
                     OH_LOG_INFO(LOG_APP, "Forward Loop [S:%{public}d C:%{public}p]: Shutting down socket write direction due to channel EOF.", socket_fd, channel);
                     shutdown(socket_fd, SHUT_WR);
                 }
            }
            continue;
        }

        if (!socket_eof_received && FD_ISSET(socket_fd, &read_fds)) {
            nread = recv(socket_fd, buffer, sizeof(buffer), 0);
            OH_LOG_DEBUG(LOG_APP, "Forward Loop [S:%{public}d C:%{public}p]: recv returned %{public}zd", socket_fd, channel, nread);

            if (nread > 0) {
                char* ptr = buffer;
                size_t remaining = nread;
                int write_attempts = 0;
                const int max_write_attempts = 5;
                while (remaining > 0 && !channel_closed && !data->shouldStop.load() && write_attempts < max_write_attempts) {
                     ssize_t channel_written = 0;
                     int write_errno = 0;
                     {
                        std::lock_guard<std::recursive_mutex> lock(m_pfMutex);
                         if (!channel) { channel_closed = true; break; }
                         channel_written = libssh2_channel_write(channel, ptr, remaining);
                         if (channel_written < 0) {
                             if(m_pfSession && m_pfSock) {
                                write_errno = libssh2_session_last_error(m_pfSession.get(), NULL, NULL, 0);
                             } else {
                                write_errno = LIBSSH2_ERROR_SOCKET_DISCONNECT;
                             }
                         }
                     }
                     OH_LOG_DEBUG(LOG_APP, "Forward Loop [S:%{public}d C:%{public}p]: libssh2_channel_write(%zu bytes) returned %{public}zd (errno %{public}d)", socket_fd, channel, remaining, channel_written, write_errno);

                     if (channel_written > 0) {
                         ptr += channel_written;
                         remaining -= channel_written;
                         write_attempts = 0;
                     } else if (channel_written == 0) {
                         OH_LOG_WARN(LOG_APP, "Forward Loop [S:%{public}d C:%{public}p]: libssh2_channel_write returned 0? Retrying.", socket_fd, channel);
                         write_attempts++;
                         std::this_thread::sleep_for(std::chrono::milliseconds(10));
                     } else {
                         if (write_errno == LIBSSH2_ERROR_EAGAIN) {
                              OH_LOG_DEBUG(LOG_APP, "Forward Loop [S:%{public}d C:%{public}p]: libssh2_channel_write EAGAIN, will wait and retry.", socket_fd, channel);
                              write_attempts++;
                              std::this_thread::sleep_for(std::chrono::milliseconds(50));
                         } else {
                             OH_LOG_ERROR(LOG_APP, "Forward Loop [S:%{public}d C:%{public}p]: libssh2_channel_write error %{public}d. Closing channel.", socket_fd, channel, write_errno);
                             channel_closed = true;
                             break;
                         }
                     }
                 }
                 if (channel_closed || data->shouldStop.load()) continue;
                 if (remaining > 0) {
                     OH_LOG_ERROR(LOG_APP, "Forward Loop [S:%{public}d C:%{public}p]: Failed to write all %zu bytes to socket after %d attempts. Closing socket.", socket_fd, channel, nread, max_write_attempts);
                     socket_closed = true;
                 }
            } else if (nread == 0) {
                 OH_LOG_INFO(LOG_APP, "Forward Loop [S:%{public}d C:%{public}p]: Socket closed by peer (EOF). Setting socket_eof_received.", socket_fd, channel);
                 socket_eof_received = true;
                 if (!channel_closed && !socket_eof_received) {
                    std::unique_lock<std::recursive_mutex> lock(m_pfMutex);
                    if (channel && !libssh2_channel_eof(channel)) {
                        OH_LOG_INFO(LOG_APP, "Forward Loop [S:%{public}d C:%{public}p]: Sending EOF to channel due to socket EOF.", socket_fd, channel);
                        int eof_rc = 0;
                        int eof_attempts = 0;
                        while ((eof_rc = libssh2_channel_send_eof(channel)) == LIBSSH2_ERROR_EAGAIN && eof_attempts < 5) {
                             if (data->shouldStop.load()) break;
                             lock.unlock();
                             waitSocket(m_pfSession.get(), *m_pfSock.get());
                             lock.lock();
                             eof_attempts++;
                             if (!m_pfSock || !channel) break;
                        }
                         if (eof_rc != 0 && eof_rc != LIBSSH2_ERROR_EAGAIN) {
                             OH_LOG_WARN(LOG_APP, "Forward Loop [S:%{public}d C:%{public}p]: send_eof failed: %{public}d", socket_fd, channel, eof_rc);
                         } else {
                              OH_LOG_INFO(LOG_APP, "Forward Loop [S:%{public}d C:%{public}p]: send_eof successful or finished with EAGAIN.", socket_fd, channel);
                         }
                    } else {
                        OH_LOG_INFO(LOG_APP, "Forward Loop [S:%{public}d C:%{public}p]: Channel already EOF, not sending EOF again.", socket_fd, channel);
                    }
                 } else {
                      OH_LOG_INFO(LOG_APP, "Forward Loop [S:%{public}d C:%{public}p]: Channel already closed or EOF, not sending EOF.", socket_fd, channel);
                 }
            } else {
                 if (errno != EAGAIN && errno != EWOULDBLOCK) {
                    OH_LOG_ERROR(LOG_APP, "Forward Loop [S:%{public}d C:%{public}p]: recv() error: %{public}s. Closing socket.", socket_fd, channel, strerror(errno));
                    socket_closed = true;
                 }
            }
        }

        bool can_read_channel = false;
        if (!channel_eof_received && FD_ISSET(ssh_socket, &read_fds)) {
             can_read_channel = true;
        }
        if (!channel_eof_received) {
            std::lock_guard<std::recursive_mutex> lock(m_pfMutex);
            if (channel && libssh2_channel_eof(channel)) {
                OH_LOG_INFO(LOG_APP, "Forward Loop [S:%{public}d C:%{public}p]: Channel EOF detected via libssh2_channel_eof flag check.", socket_fd, channel);
                channel_eof_received = true;
                can_read_channel = false;
                if (!socket_closed && !socket_eof_received) {
                    OH_LOG_INFO(LOG_APP, "Forward Loop [S:%{public}d C:%{public}p]: Shutting down socket write direction due to channel EOF.", socket_fd, channel);
                    shutdown(socket_fd, SHUT_WR);
                }
            }
        }

        if (can_read_channel && !channel_closed && !data->shouldStop.load()) {
             nread = 0;
             int read_errno = 0;
             {
                std::lock_guard<std::recursive_mutex> lock(m_pfMutex);
                if (!channel_closed && channel) {
                    nread = libssh2_channel_read(channel, buffer, sizeof(buffer));
                    if (nread < 0) {
                         read_errno = libssh2_session_last_error(m_pfSession.get(), NULL, NULL, 0);
                    } else if (nread == 0) {
                         if (libssh2_channel_eof(channel)) {
                            OH_LOG_INFO(LOG_APP, "Forward Loop [S:%{public}d C:%{public}p]: libssh2_channel_read returned 0 and EOF flag is set.", socket_fd, channel);
                            read_errno = 0;
                         } else {
                            OH_LOG_WARN(LOG_APP, "Forward Loop [S:%{public}d C:%{public}p]: libssh2_channel_read returned 0 but EOF flag *not* set? Treating as EAGAIN.", socket_fd, channel);
                            nread = -1;
                            read_errno = LIBSSH2_ERROR_EAGAIN;
                         }
                    }
                } else {
                    channel_closed = true;
                    nread = -1;
                    read_errno = LIBSSH2_ERROR_CHANNEL_CLOSED;
                }
             }
             OH_LOG_DEBUG(LOG_APP, "Forward Loop [S:%{public}d C:%{public}p]: libssh2_channel_read returned %{public}zd (errno %{public}d)", socket_fd, channel, nread, read_errno);

             if (nread > 0) {
                 char* ptr = buffer;
                 size_t remaining = nread;
                 int write_attempts = 0;
                 const int max_write_attempts = 5;
                 while (remaining > 0 && !socket_closed && !data->shouldStop.load() && write_attempts < max_write_attempts) {
                    nwritten = send(socket_fd, ptr, remaining, MSG_NOSIGNAL);
                    OH_LOG_DEBUG(LOG_APP, "Forward Loop [S:%{public}d C:%{public}p]: send(%zu bytes) returned %{public}zd (errno %{public}d)", socket_fd, channel, remaining, nwritten, (nwritten<0)?errno:0);

                    if (nwritten >= 0) {
                         ptr += nwritten;
                         remaining -= nwritten;
                         write_attempts = 0;
                    } else {
                         if (errno == EAGAIN || errno == EWOULDBLOCK) {
                            OH_LOG_DEBUG(LOG_APP, "Forward Loop [S:%{public}d C:%{public}p]: send returned EAGAIN/EWOULDBLOCK. Breaking inner loop to wait.", socket_fd, channel);
                            write_attempts++;
                            std::this_thread::sleep_for(std::chrono::milliseconds(50));
                         } else {
                            OH_LOG_ERROR(LOG_APP, "Forward Loop [S:%{public}d C:%{public}p]: send() error: %{public}s. Closing socket.", socket_fd, channel, strerror(errno));
                            socket_closed = true;
                            break;
                         }
                    }
                 }
                 if (socket_closed || data->shouldStop.load()) continue;
                 if (remaining > 0) {
                     OH_LOG_ERROR(LOG_APP, "Forward Loop [S:%{public}d C:%{public}p]: Failed to write all %zu bytes to socket after %d attempts. Closing socket.", socket_fd, channel, nread, max_write_attempts);
                     socket_closed = true;
                 }
             } else if (nread == 0 && read_errno == 0) {
                  OH_LOG_INFO(LOG_APP, "Forward Loop [S:%{public}d C:%{public}p]: Channel EOF confirmed by read 0. Setting channel_eof_received.", socket_fd, channel);
                  channel_eof_received = true;
                  if (!socket_closed && !socket_eof_received) {
                      OH_LOG_INFO(LOG_APP, "Forward Loop [S:%{public}d C:%{public}p]: Shutting down socket write direction due to channel EOF.", socket_fd, channel);
                      shutdown(socket_fd, SHUT_WR);
                  }
             } else {
                  if (read_errno != LIBSSH2_ERROR_EAGAIN) {
                     OH_LOG_ERROR(LOG_APP, "Forward Loop [S:%{public}d C:%{public}p]: libssh2_channel_read error %{public}d. Closing channel.", socket_fd, channel, read_errno);
                     channel_closed = true;
                  }
             }
         }

         if (data->shouldStop.load()) {
             OH_LOG_INFO(LOG_APP, "Forward Loop [S:%{public}d C:%{public}p]: Stop requested at end of loop iteration.", socket_fd, channel);
             break;
         }
         if (socket_closed && !channel_closed && !socket_eof_received) {
             OH_LOG_INFO(LOG_APP, "Forward Loop [S:%{public}d C:%{public}p]: Socket closed due to error, ensuring channel EOF is sent.", socket_fd, channel);
             std::unique_lock<std::recursive_mutex> lock(m_pfMutex);
             if (channel && !libssh2_channel_eof(channel)) {
                 libssh2_channel_send_eof(channel);
             }
             channel_closed = true;
         }
         if (channel_closed && !socket_closed && !socket_eof_received) {
              OH_LOG_INFO(LOG_APP, "Forward Loop [S:%{public}d C:%{public}p]: Channel closed due to error, shutting down socket WR.", socket_fd, channel);
              shutdown(socket_fd, SHUT_WR);
              socket_closed = true;
         }

         if (socket_eof_received && channel_eof_received) {
              OH_LOG_INFO(LOG_APP, "Forward Loop [S:%{public}d C:%{public}p]: Both sides received EOF. Exiting loop gracefully.", socket_fd, channel);
              break;
         }

         if (socket_closed || channel_closed) {
             OH_LOG_INFO(LOG_APP, "Forward Loop [S:%{public}d C:%{public}p]: One side closed due to error (socket_closed=%d, channel_closed=%d). Exiting loop.", socket_fd, channel, socket_closed, channel_closed);
             break;
         }

    }

    OH_LOG_INFO(LOG_APP, "Forward Loop [S:%{public}d C:%{public}p]: Exiting loop. Final state: socket_closed=%{public}d, channel_closed=%{public}d, socket_eof=%{public}d, channel_eof=%{public}d, stopped=%{public}d.",
                socket_fd, channel, socket_closed, channel_closed, socket_eof_received, channel_eof_received, data->shouldStop.load());

    if (socket_fd >= 0) {
        close(socket_fd);
    }
    if (channel && m_pfConnected.load()) {
        LIBSSH2_CHANNEL* channel_to_clean = channel;
        OH_LOG_INFO(LOG_APP, "Forward Loop [S:%{public}d C:%{public}p]: Starting cleanup for channel %{public}p using PF session.", socket_fd, channel, channel_to_clean);
        std::unique_lock<std::recursive_mutex> lock(m_pfMutex);
         if (channel_to_clean && m_pfSession) {
            int cleanup_rc = 0;
            int cleanup_attempts = 0;
            const int max_cleanup_attempts = 5;

            if (!libssh2_channel_eof(channel_to_clean)) {
                 cleanup_attempts = 0;
                 while((cleanup_rc = libssh2_channel_send_eof(channel_to_clean)) == LIBSSH2_ERROR_EAGAIN && cleanup_attempts < max_cleanup_attempts) {
                      if (data->shouldStop.load()) break;
                      lock.unlock();
                      waitSocket(m_pfSession.get(), *m_pfSock.get());
                      lock.lock();
                      cleanup_attempts++;
                       if (!m_pfSession || !channel_to_clean) break;
                 }
                 if (cleanup_rc != 0 && cleanup_rc != LIBSSH2_ERROR_EAGAIN) OH_LOG_WARN(LOG_APP, "Forward Loop Cleanup: send_eof failed: %d", cleanup_rc);
            }

            cleanup_attempts = 0;
            while((cleanup_rc = libssh2_channel_close(channel_to_clean)) == LIBSSH2_ERROR_EAGAIN && cleanup_attempts < max_cleanup_attempts) {
                 if (data->shouldStop.load()) break;
                 lock.unlock();
                 waitSocket(m_pfSession.get(), *m_pfSock.get());
                 lock.lock();
                 cleanup_attempts++;
                 if (!m_pfSession || !channel_to_clean) break;
            }
             if (cleanup_rc != 0 && cleanup_rc != LIBSSH2_ERROR_EAGAIN) OH_LOG_WARN(LOG_APP, "Forward Loop Cleanup: close failed: %d", cleanup_rc);


            cleanup_attempts = 0;
            while((cleanup_rc = libssh2_channel_free(channel_to_clean)) == LIBSSH2_ERROR_EAGAIN && cleanup_attempts < max_cleanup_attempts) {
                 if (data->shouldStop.load()) break;
                  lock.unlock();
                  waitSocket(m_pfSession.get(), *m_pfSock.get());
                  lock.lock();
                 cleanup_attempts++;
                  if (!m_pfSession || !channel_to_clean) break;
            }
             if (cleanup_rc != 0 && cleanup_rc != LIBSSH2_ERROR_EAGAIN) {
                  OH_LOG_WARN(LOG_APP, "Forward Loop Cleanup: free failed with %d", cleanup_rc);
             } else if (cleanup_rc == 0) {
                  // If free succeeded, we might conceptually null the channel ptr if needed,
                  // but the function parameter 'channel' won't reflect this outside.
                  // The main point is that libssh2 has freed it.
             }
         } else {
             OH_LOG_INFO(LOG_APP, "Forward Loop [S:%{public}d C:%{public}p]: Channel %{public}p or session became invalid before cleanup.", socket_fd, channel, channel_to_clean);
         }
    }
    OH_LOG_INFO(LOG_APP, "Forward Loop: Cleanup finished for socket %{public}d and channel %{public}p.", socket_fd, channel);
}

bool SshPortForward::startLocalPortForwarding(int localPort, const std::string& targetHost, int targetPort, bool anyInterface) {
    if (!m_mainSession || !m_mainSession->isConnected()) {
        OH_LOG_ERROR(LOG_APP, "Cannot start local forward: SSH session not ready.");
        return false;
    }

    std::lock_guard<std::mutex> lock(m_forwardingMutex);

    for (const auto& data : m_forwardingPorts) {
        if (data->localPort == localPort && !data->isRemote) {
            OH_LOG_ERROR(LOG_APP, "Local port %d already in use.", localPort);
            return false;
        }
    }

    auto forwardData = std::make_shared<PortForwardData>();
    forwardData->localPort = localPort;
    forwardData->targetHost = targetHost;
    forwardData->targetPort = targetPort;
    forwardData->isRemote = false;
    forwardData->isDynamic = false;
    forwardData->anyInterface = anyInterface;
    forwardData->shouldStop = false;
    forwardData->running = false;

    try {
        forwardData->forwardThread = std::thread(&SshPortForward::localPortForwardingThread, this, forwardData);
    } catch (const std::system_error& e) {
         OH_LOG_ERROR(LOG_APP, "Failed to create local forward thread: %s", e.what());
         return false;
    }

    for (int i = 0; i < 20; ++i) {
        if (forwardData->running) {
             m_forwardingPorts.push_back(forwardData);
             OH_LOG_INFO(LOG_APP, "Successfully started local forwarding on port %{public}d.", localPort);
             return true;
        }
        if (!forwardData->running && !forwardData->forwardThread.joinable() && forwardData->listenSocket < 0) {
            OH_LOG_ERROR(LOG_APP, "Local forward thread failed to start listening on port %{public}d.", localPort);
            if (forwardData->forwardThread.joinable()) {
                 forwardData->forwardThread.join();
             }
             return false;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }

    OH_LOG_ERROR(LOG_APP, "Timeout waiting for local forward thread to start on port %{public}d.", localPort);
    forwardData->shouldStop = true;
    if (forwardData->forwardThread.joinable()) {
         forwardData->forwardThread.join();
    }
    return false;
}

bool SshPortForward::startRemotePortForwarding(int remotePort, const std::string& targetHost, int targetPort) {
     if (!m_mainSession || !m_mainSession->isConnected()) {
        OH_LOG_ERROR(LOG_APP, "Cannot start remote forward: SSH session not ready.");
        return false;
    }

    std::lock_guard<std::mutex> lock(m_forwardingMutex);

    for (const auto& data : m_forwardingPorts) {
        if (data->localPort == remotePort && data->isRemote) {
            OH_LOG_ERROR(LOG_APP, "Remote port %d already requested.", remotePort);
            return false;
        }
    }

    auto forwardData = std::make_shared<PortForwardData>();
    forwardData->localPort = remotePort;
    forwardData->targetHost = targetHost;
    forwardData->targetPort = targetPort;
    forwardData->isRemote = true;
    forwardData->isDynamic = false;
    forwardData->anyInterface = false;
    forwardData->shouldStop = false;
    forwardData->running = false;

    try {
        forwardData->forwardThread = std::thread(&SshPortForward::remotePortForwardingThread, this, forwardData);
    } catch (const std::system_error& e) {
         OH_LOG_ERROR(LOG_APP, "Failed to create remote forward thread: %s", e.what());
         return false;
    }

    for (int i = 0; i < 20; ++i) {
        if (forwardData->running) {
             m_forwardingPorts.push_back(forwardData);
             OH_LOG_INFO(LOG_APP, "Successfully started remote forwarding request for port %d.", remotePort);
             return true;
        }
         if (!forwardData->running && !forwardData->forwardThread.joinable() && !forwardData->listener) {
            OH_LOG_ERROR(LOG_APP, "Remote forward thread failed to start listener for remote port %d.", remotePort);
             if (forwardData->forwardThread.joinable()) {
                 forwardData->forwardThread.join();
             }
             return false;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }

    OH_LOG_ERROR(LOG_APP, "Timeout waiting for remote forward thread to start on port %{public}d.", remotePort);
    forwardData->shouldStop = true;
    if (forwardData->forwardThread.joinable()) {
         forwardData->forwardThread.join();
    }
    return false;
}

bool SshPortForward::startDynamicPortForwarding(int localPort, bool anyInterface) {
     if (!m_mainSession || !m_mainSession->isConnected()) {
        OH_LOG_ERROR(LOG_APP, "Cannot start dynamic forward: SSH session not ready.");
        return false;
    }

    std::lock_guard<std::mutex> lock(m_forwardingMutex);

    for (const auto& data : m_forwardingPorts) {
        if (data->localPort == localPort && !data->isRemote) {
            OH_LOG_ERROR(LOG_APP, "Local port %d already in use for dynamic/local forward.", localPort);
            return false;
        }
    }

    auto forwardData = std::make_shared<PortForwardData>();
    forwardData->localPort = localPort;
    forwardData->targetHost = "";
    forwardData->targetPort = 0;
    forwardData->isRemote = false;
    forwardData->isDynamic = true;
    forwardData->anyInterface = anyInterface;
    forwardData->shouldStop = false;
    forwardData->running = false;

    try {
        forwardData->forwardThread = std::thread(&SshPortForward::localPortForwardingThread, this, forwardData);
    } catch (const std::system_error& e) {
         OH_LOG_ERROR(LOG_APP, "Failed to create dynamic forward thread: %s", e.what());
         return false;
    }

     for (int i = 0; i < 20; ++i) {
        if (forwardData->running) {
             m_forwardingPorts.push_back(forwardData);
             OH_LOG_INFO(LOG_APP, "Successfully started dynamic SOCKS forwarding on port %d.", localPort);
             return true;
        }
        if (!forwardData->running && !forwardData->forwardThread.joinable() && forwardData->listenSocket < 0) {
            OH_LOG_ERROR(LOG_APP, "Dynamic forward thread failed to start listening on port %d.", localPort);
             if (forwardData->forwardThread.joinable()) {
                 forwardData->forwardThread.join();
             }
             return false;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }

    OH_LOG_ERROR(LOG_APP, "Timeout waiting for dynamic forward thread to start on port %{public}d.", localPort);
    forwardData->shouldStop = true;
    if (forwardData->forwardThread.joinable()) {
         forwardData->forwardThread.join();
    }
    return false;
}

bool SshPortForward::stopPortForwarding(int port, bool isRemote) {
    std::shared_ptr<PortForwardData> dataToStop = nullptr;
    int indexToRemove = -1;

    {
        std::lock_guard<std::mutex> lock(m_forwardingMutex);
        for (int i = 0; i < m_forwardingPorts.size(); ++i) {
            if (m_forwardingPorts[i] && m_forwardingPorts[i]->localPort == port && m_forwardingPorts[i]->isRemote == isRemote) {
                dataToStop = m_forwardingPorts[i];
                indexToRemove = i;
                 OH_LOG_INFO(LOG_APP, "Found forwarding rule to stop: Port %{public}d, isRemote=%{public}d", port, isRemote);
                break;
            }
        }

        if (!dataToStop) {
            OH_LOG_WARN(LOG_APP, "No active forwarding rule found for port %d, isRemote=%d", port, isRemote);
            return false;
        }

        if (indexToRemove != -1) {
             m_forwardingPorts.erase(m_forwardingPorts.begin() + indexToRemove);
        } else {
            OH_LOG_ERROR(LOG_APP, "Inconsistency: Found dataToStop but not indexToRemove for port %d", port);
            return false;
        }

        OH_LOG_INFO(LOG_APP, "Signaling stop for port %{public}d (isRemote=%{public}d)", port, isRemote);
        dataToStop->shouldStop.store(true);
    }

    OH_LOG_INFO(LOG_APP, "Stopping listener/acceptor for port %{public}d...", port);
    if (!isRemote && dataToStop->listenSocket >= 0) {
        closeListenSocket(dataToStop->listenSocket);
        dataToStop->listenSocket = -1;
    } else if (isRemote && dataToStop->listener && m_mainSession && m_mainSession->isConnected()) {
        std::unique_lock<std::recursive_mutex> lock(m_pfMutex);
        LIBSSH2_SESSION* session = m_pfSession.get();
        if (session && dataToStop->listener) {
            int rc = 0;
            int cancel_attempts = 0;
             while ((rc = libssh2_channel_forward_cancel(dataToStop->listener)) == LIBSSH2_ERROR_EAGAIN && cancel_attempts < 5) {
                 lock.unlock();
                 waitSocket(session, *m_pfSock.get());
                 lock.lock();
                 session = m_pfSession.get();
                 if(!session) break;
                 cancel_attempts++;
             }
             if (rc != 0 && rc != LIBSSH2_ERROR_EAGAIN) {
                  OH_LOG_WARN(LOG_APP, "Failed to cancel remote listener: %d", rc);
             } else {
                  OH_LOG_INFO(LOG_APP, "Remote listener cancelled or cancel attempt finished.");
             }
        } else {
             OH_LOG_WARN(LOG_APP, "Cannot cancel remote listener: session invalid or listener already null.");
        }
        dataToStop->listener = nullptr;
    }

    if (dataToStop->forwardThread.joinable()) {
         OH_LOG_INFO(LOG_APP, "Waiting for forwarder thread for port %{public}d to join...", port);
         try {
             dataToStop->forwardThread.join();
             OH_LOG_INFO(LOG_APP, "Forwarder thread joined for port %{public}d.", port);
         } catch (const std::system_error& e) {
              OH_LOG_ERROR(LOG_APP, "Exception joining forwarder thread for port %{public}d: %{public}s", port, e.what());
         }
    } else {
         OH_LOG_INFO(LOG_APP, "Forwarder thread for port %{public}d was not joinable (already finished?).", port);
    }

    OH_LOG_INFO(LOG_APP, "stopPortForwarding completed for port %{public}d, isRemote=%{public}d.", port, isRemote);
    return true;
}

bool SshPortForward::isPortForwardingActive(int port, bool isRemote) {
    std::lock_guard<std::mutex> lock(m_forwardingMutex);
    for (const auto& data : m_forwardingPorts) {
        if (data->localPort == port && data->isRemote == isRemote) {
            return data->running.load();
        }
    }
    return false;
}

std::vector<std::tuple<int, std::string, int, bool, bool>> SshPortForward::listActivePortForwardings() {
    std::lock_guard<std::mutex> lock(m_forwardingMutex);
    std::vector<std::tuple<int, std::string, int, bool, bool>> result;

    for (const auto& data : m_forwardingPorts) {
        if (data->running) {
            result.emplace_back(
                data->localPort,
                data->targetHost,
                data->targetPort,
                data->isRemote,
                data->isDynamic
            );
        }
    }
    return result;
}