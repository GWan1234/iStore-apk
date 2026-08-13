/**
 * libmnnllm.so 原生桥接层类型声明（自编译 MNN 3.6.1 bridge，15 个函数）
 * 与参考项目 E:\Code\mnn-local-ai-chat\native\mnn_bridge\bridge.cpp 注册的函数一一对应
 */
export const nativeLoad: (filePath: string) => number;
export const nativeLoadAsync: (filePath: string, callback: (result: number) => void) => number;
export const nativeChat: (prompt: string) => string;
export const nativeChatAsync: (prompt: string, callback: (result: string, is_eop: number) => void) => number;
export const nativeChatStream: (prompt: string, callback: (result: string, is_eop: number) => boolean) => number;
export const nativeChatVLM: (prompt: string, imgPath: string) => string;
export const nativeChatVLMAsync: (prompt: string, imgPath: string, callback: (result: string, is_eop: number) => void) => number;
export const nativeChatVLMStream: (prompt: string, imgPath: string, callback: (result: string, is_eop: number) => boolean) => number;
export const nativeUnload: () => number;
export const nativeReset: () => number;
export const nativeSetSystemPrompt: (prompt: string) => void;
export const nativeSetConfig: (configJson: string) => void;
export const nativeSetHistory: (historyJson: string) => number;
export const nativeStats: () => string;
export const nativeStop: () => void;
