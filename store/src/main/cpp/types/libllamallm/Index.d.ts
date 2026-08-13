/**
 * libllamallm.so 原生桥接层类型声明（自编译 llama.cpp bridge，9 个函数）
 * 与参考项目 E:\Code\mnn-local-ai-chat\native\llama_bridge\llama_bridge.cpp 注册的函数一一对应
 */
export const llNativeLoadAsync: (ggufPath: string, callback: (result: number, msg: string) => void) => number;
export const llNativeUnload: () => number;
export const llNativeChatAsync: (prompt: string, callback: (delta: string, isEop: number) => void) => number;
export const llNativeStop: () => void;
export const llNativeReset: () => number;
export const llNativeSetSystemPrompt: (prompt: string) => void;
export const llNativeSetConfig: (configJson: string) => void;
export const llNativeSetHistory: (historyJson: string) => number;
export const llNativeStats: () => string;
