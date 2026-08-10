// 基础连接接口
export function openProtocol(config: string): Promise<number>;
export function sendTerminalCommand(sessionId: number, command: string): Promise<string>;
export function closeProtocol(sessionId: number): Promise<boolean>;
export function registerDataCallback(callback: (sessionId: number, data: string, status: boolean) => void): void;

/**
 * 调整远程伪终端 (PTY) 的大小。
 * @param sessionId 会话 ID。
 * @param width 新的终端宽度（字符数）。
 * @param height 新的终端高度（行数）。
 * @returns 返回一个 Promise，解析为 boolean 值，表示操作是否成功。
 */
export function resizeTerminal(sessionId: number, width: number, height: number): Promise<boolean>;

/**
 * 进度回调函数类型定义
 */
type ProgressCallback = (progress: number) => void;

/**
 * 文件操作完成回调函数类型定义
 */
type CompletionCallback = (success: boolean, error: string | null) => void;

// SFTP 文件信息接口
export interface SftpFileInfo {
  name: string;           // 文件名
  isDirectory: boolean;   // 是否是目录
  size: number;          // 文件大小
  permissions: string;    // 权限字符串
  mtime: string;         // 修改时间
  atime: string;         // 访问时间
  owner: string;         // 所有者
  group: string;         // 用户组
  fullPath: string;      // 完整路径
}

// 目录导航状态
export interface DirectoryState {
  currentPath: string;    // 当前目录路径
  parentPath: string;     // 父目录路径
  isRoot: boolean;       // 是否是根目录
}

// SFTP 基础函数
export function initSftp(sessionId: number): boolean; // 初始化SFTP会话

// SFTP 文件操作接口
// 列出目录内容（异步版本）
export function listDirectory(sessionId: number, path: string, callback: (error: Error | null, result: SftpFileInfo[]) => void): void;

/**
 * 文件上传进度项接口
 */
export interface UploadProgressItem {
  progress: number;      // 上传进度 (0-100)
  completed: boolean;    // 是否已完成
  remotePath: string;    // 远程文件路径
  speed: number;         // 上传速率 (MB/s)
  totalFiles: number;    // 总文件数
  completedFiles: number; // 已完成的文件数
  currentFileSize: number; // 当前正在上传的文件大小 (bytes)
}

/**
 * 上传进度回调函数类型
 * @param error 如果在处理进度时发生错误，则为 Error 对象；否则为 null。
 * @param progressDetails 包含当前上传进度的对象。
 */
type UploadProgressCallback = (error: Error | null, progressDetails: UploadProgressItem) => void;

/**
 * 上传完成回调函数类型
 * @param error 如果上传操作最终失败，则为 Error 对象；否则为 null。
 * @param resultDetails 包含上传最终结果（例如成功的文件数）的对象。注意：即使 error 不为 null，此对象也可能包含部分成功的信息。
 */
type UploadCompletionCallback = (error: Error | null, resultDetails: UploadProgressItem) => void; // 复用 UploadProgressItem 结构表示最终状态

/**
 * 上传文件到远程服务器
 * @param sessionId 会话 ID。
 * @param files 文件数组，每个元素包含文件描述符和可选的文件名
 * @param targetDir 目标目录路径
 * @param progressCallback 进度回调函数，在上传过程中多次调用
 * @param completionCallback 完成回调函数，在所有文件上传尝试结束后调用一次
 */
export function uploadFile(
  sessionId: number,
  files: { fd: number, name?: string }[],
  targetDir: string,
  progressCallback: UploadProgressCallback, // 第三个参数：进度回调
  completionCallback: UploadCompletionCallback // 第四个参数：完成回调
): void;

/**
 * 文件下载进度项接口
 */
export interface DownloadProgressItem {
  progress: number;      // 下载进度 (0-100)
  completed: boolean;    // 是否已完成
  remotePath: string;    // 远程文件路径
  speed: number;         // 下载速率 (MB/s)
  fileSize: number;      // 文件总大小 (bytes)
  downloadedBytes: number; // 已下载字节数 (bytes)
}

/**
 * 下载进度回调函数类型
 * @param error 如果在处理进度时发生错误，则为 Error 对象；否则为 null。
 * @param progressDetails 包含当前下载进度的对象。
 */
type DownloadProgressCallback = (error: Error | null, progressDetails: DownloadProgressItem) => void;

/**
 * 下载完成回调函数类型
 * @param error 如果下载操作最终失败，则为 Error 对象；否则为 null。
 * @param resultDetails 包含下载最终结果的对象。
 */
type DownloadCompletionCallback = (error: Error | null, resultDetails: DownloadProgressItem | null) => void;

/**
 * 从远程服务器下载文件
 * @param sessionId 会话 ID。
 * @param remotePath 远程文件路径
 * @param fd 本地文件描述符
 * @param progressCallback 进度回调函数，在下载过程中多次调用
 * @param completionCallback 完成回调函数，在下载尝试结束后调用一次
 */
export function downloadFile(
  sessionId: number,
  remotePath: string,
  fd: number,
  progressCallback: DownloadProgressCallback, // 第三个参数：进度回调
  completionCallback: DownloadCompletionCallback // 第四个参数：完成回调
): void;

export function deleteFile(sessionId: number, path: string, callback: (error: Error | null, success: boolean) => void): void; // 删除文件
export function createDirectory(sessionId: number, path: string, callback: (error: Error | null, success: boolean) => void): void; // 创建目录
export function deleteDirectory(sessionId: number, path: string, callback: (error: Error | null, success: boolean) => void): void; // 删除目录
export function rename(sessionId: number, oldPath: string, newPath: string, callback: (error: Error | null, success: boolean) => void): void; // 重命名文件或目录

// 日志类型枚举
export enum LogType {
    None = 0,              // 不记录日志
    PrintableOutput = 1,   // 只记录可打印输出
    AllSessionOutput = 2,  // 记录所有会话输出
    SSHPacketData = 3,     // 记录SSH数据包信息
    SSHPacketAndRaw = 4    // 记录SSH数据包信息和原始数据
}

// 文件存在时的操作枚举
export enum LogExistOperation {
    Overwrite = 0,         // 覆盖已存在的文件
    Append = 1             // 追加到文件末尾
}

// 日志设置结果接口
export interface LoggingResult {
    success: boolean;
    error: string;
}

export interface LoggingConfig {
    fd: number;
    logType: LogType;
    existOperation: LogExistOperation;
    includeHeader?: boolean;
    omitKnownPassword?: boolean;
    omitSessionData?: boolean;
}

export function setLogging(
    sessionId: number,
    config: LoggingConfig,
    callback: (success: boolean, error: string) => void
): void;

/**
 * 启用或禁用终端目录跟踪功能 (Follow Terminal Folder)。
 * 启用后，当远程 Shell 的当前目录发生变化时，会通过注册的回调通知。
 * @param sessionId 会话 ID。
 * @param enable 布尔值，true 表示启用，false 表示禁用。
 * @returns 返回一个 Promise，解析为 boolean 值，表示操作是否成功。
 */
export function enableDirectoryTracking(sessionId: number, enable: boolean): Promise<boolean>;

/**
 * 注册一个回调函数，用于接收终端当前工作目录的变更通知。
 * 仅当 enableDirectoryTracking(true) 被调用后才会收到通知。
 * @param callback 当目录发生变化时调用的函数，接收会话 ID (sessionId) 和新的目录路径 (directory) 作为参数。
 */
export function registerDirectoryChangeCallback(callback: (sessionId: number, directory: string) => void): void;

/**
 * 请求取消当前正在进行的 SFTP 文件传输（上传或下载）。
 * 注意：这是一个尽力而为的操作，取消可能不会立即生效。
 * 底层操作需要达到一个检查点才能响应取消请求。
 * 传输成功与否仍需通过原有的完成回调来判断。
 * @param sessionId 要取消传输的会话 ID。
 */
export function cancelTransfer(sessionId: number): void;

// --- 新增: 密钥管理接口 ---

/**
 * 异步生成密钥对并写入文件描述符。
 * @param algorithm 加密算法。支持的值: "RSA", "ECDSA", "ED25519".
 *                  对于 "ECDSA"，目前默认使用 P-256 (secp256r1) 曲线。
 * @param password 用于加密私钥的密码。如果为 null, undefined 或空字符串，则不加密私钥。
 * @param privateKeyFd 用于写入私钥的文件描述符。
 * @param publicKeyFd 用于写入公钥的文件描述符。
 * @returns 返回一个 Promise，成功时解析为 true，失败时拒绝并返回错误信息。
 * @throws 如果参数无效或操作失败。
 */
export function generateKeyPair(algorithm: string, password: string | null | undefined, privateKeyFd: number, publicKeyFd: number): Promise<boolean>;

/**
 * 从文件描述符读取并解密私钥。
 * @param privateKeyFd 包含加密私钥的文件描述符。
 * @param password 用于解密私钥的密码。
 * @returns 返回一个 Promise，成功时解析为解密后的 PEM 格式私钥字符串，失败时拒绝并返回错误信息。
 * @throws 如果参数无效、密码错误或解密失败。
 */
export function decryptPrivateKey(privateKeyFd: number, password: string): Promise<string>;

/**
 * 描述一个活动的端口转发规则的信息。
 */
export interface PortForwardingInfo {
  port: number;        // 源端口 (本地转发/动态转发时为本地端口，远程转发时为远程端口)
  targetHost: string;  // 目标主机
  targetPort: number;  // 目标端口
  isRemote: boolean;   // 如果是远程转发规则则为 true
  isDynamic: boolean;  // 如果是动态 SOCKS 转发规则则为 true
}

/**
 * 启动本地端口转发。
 * 将本地端口映射到 SSH 服务器可以访问的目标主机/端口。
 * @param sessionId 会话 ID。
 * @param localPort 要监听的本地端口号。
 * @param targetHost 目标主机名或 IP 地址（相对于 SSH 服务器）。
 * @param targetPort 目标端口号。
 * @param anyInterface 可选参数，如果为 true，则监听所有本地接口 (0.0.0.0)；否则仅监听 localhost (127.0.0.1)。默认为 false。
 * @returns 返回一个 Promise，如果转发成功启动则解析为 true，否则为 false。
 */
export function startLocalPortForwarding(sessionId: number, localPort: number, targetHost: string, targetPort: number, anyInterface?: boolean): Promise<boolean>;

/**
 * 启动远程端口转发。
 * 将 SSH 服务器上的端口映射到客户端机器可以访问的目标主机/端口。
 * @param sessionId 会话 ID。
 * @param remotePort SSH 服务器要监听的端口号。
 * @param targetHost 目标主机名或 IP 地址（相对于客户端机器）。
 * @param targetPort 目标端口号。
 * @returns 返回一个 Promise，如果转发请求成功发送且监听器已启动则解析为 true，否则为 false。
 */
export function startRemotePortForwarding(sessionId: number, remotePort: number, targetHost: string, targetPort: number): Promise<boolean>;

/**
 * 启动动态端口转发（SOCKS 代理）。
 * 在本地端口上创建一个 SOCKS 代理，通过 SSH 服务器转发流量。
 * @param sessionId 会话 ID。
 * @param localPort 要监听 SOCKS 代理的本地端口号。
 * @param anyInterface 可选参数，如果为 true，则监听所有本地接口 (0.0.0.0)；否则仅监听 localhost (127.0.0.1)。默认为 false。
 * @returns 返回一个 Promise，如果 SOCKS 代理成功启动则解析为 true，否则为 false。
 */
export function startDynamicPortForwarding(sessionId: number, localPort: number, anyInterface?: boolean): Promise<boolean>;

/**
 * 停止一个活动的端口转发规则。
 * @param sessionId 会话 ID。
 * @param port 要停止的规则的源端口号（本地/动态转发为本地端口，远程转发为远程端口）。
 * @param isRemote 可选参数，如果要停止的是远程转发规则则设为 true，否则为 false。默认为 false。
 * @returns 返回一个 Promise，如果转发规则成功停止则解析为 true，否则为 false。
 */
export function stopPortForwarding(sessionId: number, port: number, isRemote?: boolean): Promise<boolean>;

/**
 * 检查指定的端口转发规则当前是否处于活动状态。
 * @param sessionId 会话 ID。
 * @param port 要检查的源端口号（本地/动态转发为本地端口，远程转发为远程端口）。
 * @param isRemote 可选参数，如果要检查的是远程转发规则则设为 true，否则为 false。默认为 false。
 * @returns 返回一个 Promise，如果规则处于活动状态则解析为 true，否则为 false。
 */
export function isPortForwardingActive(sessionId: number, port: number, isRemote?: boolean): Promise<boolean>;

/**
 * 列出当前会话中所有活动的端口转发规则。
 * @param sessionId 会话 ID。
 * @returns 返回一个 Promise，解析为一个包含 PortForwardingInfo 对象的数组，描述了所有活动的规则。
 */
export function listActivePortForwardings(sessionId: number): Promise<PortForwardingInfo[]>;
