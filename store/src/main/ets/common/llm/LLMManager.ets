/**
 * MNN LLM 模型管理工具类
 *
 * 职责：
 *  1. 从 ModelScope 模型市场下载模型到沙箱 models/ 目录
 *  2. 加载 / 卸载模型、重置多轮对话上下文、动态切换思考模式
 *  3. 封装异步对话推理，通过回调向 UI 层回传累计回复文本
 *  4. 扫描沙箱 models/ 目录列出已下载模型，支持文件导入
 *  5. 提供 native 推理统计（token 数 / 速度）读取
 *
 * 注意：mnnllm 库导出的是一组命名原生函数（nativeLoadAsync / nativeChatAsync 等），
 *       并非类对象，需直接按名导入使用。
 */
import { common } from '@kit.AbilityKit';
import { BusinessError, zlib } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { http } from '@kit.NetworkKit';
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import fs from '@ohos.file.fs';
// 注：本地自编译 libmnnllm.so（MNN 3.6.1 bridge）注册全部 15 个函数：
//     基础 10 个（nativeLoad/LoadAsync/Chat/ChatAsync/ChatStream/VLM*/Unload/Reset）
//     扩展 5 个（nativeSetSystemPrompt/SetConfig/SetHistory/Stats/Stop）
//     与参考项目 mnn-local-ai-chat 的 bridge.cpp 完全一致，替换 ohpm 官方版（仅 10 个基础函数）。
import {
  nativeLoadAsync,
  nativeChatAsync,
  nativeReset,
  nativeUnload,
  nativeSetSystemPrompt,
  nativeSetConfig,
  nativeStats,
  nativeStop,
  nativeSetHistory
} from 'libmnnllm.so';
// llama.cpp 引擎 bridge（libllamallm.so）：GGUF 模型加载 / 推理 / 采样 / KV cache / chat 模板
import {
  llNativeLoadAsync,
  llNativeChatAsync,
  llNativeReset,
  llNativeUnload,
  llNativeStop,
  llNativeSetSystemPrompt,
  llNativeSetConfig,
  llNativeSetHistory,
  llNativeStats
} from 'libllamallm.so';

const TAG: string = 'MNNLLM';
const DOMAIN: number = 0x0000;
/** 基础系统提示词（准确性优先）：恒定前置注入，压制幻觉（尤其史实类问题——不确定就明说，绝不编造） */
const HONESTY_PROMPT: string =
  `你是一个以准确性为最高准则的 AI 助手。请严格遵循以下原则：

【核心原则：准确第一】
- 绝对禁止编造任何信息，包括但不限于事实、数据、引用、人名、日期、事件经过。
- 绝对禁止编造史实。涉及历史事件、人物、时间线时，必须基于可靠来源，不得推测或虚构。
- 不确定的内容，必须明确告知用户"我不确定"或"我没有可靠信息"，绝不含糊带过。
- 不知道就是不知道，严禁不懂装懂、强行作答。

【回答纪律】
- 不要反复思考、反复自我纠正。如果不确定，直接说明不确定，不要通过反复修改来掩盖不确定性。
- 回答应当一次到位，避免"先猜一个答案再修正"的模式。
- 宁可少说，不可多说。没有把握的信息不要输出。

【回答长度】
- 默认给出简短、精炼的回答，直达结论，不设字数上限。
- 仅在用户明确要求展开或补充细节时，再详细说明。

【能力边界】
- 明确区分"已知事实"和"推测/观点"，如需推测必须标注。
- 涉及专业领域（医疗、法律、金融、学术等）时，提醒用户以权威来源为准。
- 不假装拥有未授权的能力，不伪造数据来源或引用链接。

【交互风格】
- 简洁、直接、诚实。
- 遇到超出能力范围的问题，坦诚说明并给出合理建议。
- 保持专业、友好的语气，但诚实优先于礼貌。`;
/** 模型市场仓库（ModelScope）根下载地址模板 */
const MODELSCOPE_DL: string = 'https://modelscope.cn/models/';
/** 单文件下载最大尝试次数（首次 + 最多 2 次自动重试） */
const MAX_DL_RETRY: number = 3;
/** 思考深度分档指令：思考开启时按深度档位注入，越深越鼓励展开推理 */
const THINK_DEPTH_PROMPTS: string[] = [
  // 深度 1~30：轻思考
  '请只做简要思考：1-2 句话完成推理后立即给出最终答案，不要展开长篇推理过程。思考结束后必须直接输出最终答案正文，正文不能为空。',
  // 深度 31~69：适度思考
  '请进行适度思考：给出必要的推理步骤后再给出最终答案，保持简洁清晰。思考结束后必须直接输出最终答案正文，正文不能为空。',
  // 深度 70~100：深入思考
  '请进行深入思考：从多个角度逐步分析问题，充分展开推理链后再给出详尽、准确的最终答案。思考结束后必须直接输出最终答案正文，正文不能为空。'
];
/** 下载 MNN 模型时的标准文件清单（按大小从小到大排列，先小后大） */
const MODEL_FILES: string[] = [
  'config.json',
  'llm_config.json',
  'configuration.json',
  'export_args.json',
  'tokenizer.txt',
  'embeddings_bf16.bin',
  'llm.mnn.json',
  'visual.mnn',
  'visual.mnn.weight',
  'llm.mnn',
  'llm.mnn.weight'
];

/**
 * 剥离模型输出中的 <answer>...</answer> 包裹标签（部分 MNN 模型固定输出该格式）。
 * 兼容流式片段：开标签/闭标签可能在任意一次 delta 中出现。
 * 增强：也清理跨片段残留的不完整标签（如开头 "<answer" 缺 ">"、结尾残留 "</answer" 等）。
 */
export function stripAnswerTags(s: string): string {
  let out: string = s;
  // 完整标签（含大小写与空白变体）
  out = out.replace(/<answer\s*>/gi, '');
  out = out.replace(/<\/answer\s*>/gi, '');
  // 残缺开标签：<answer（无闭合 >，出现在片段边界）
  out = out.replace(/<answer\s*/gi, '');
  // 残缺闭标签：</answer（无闭合 >）
  out = out.replace(/<\/answer\s*/gi, '');
  return out;
}

/** 推理统计 */
export interface LLMStats {
  promptTokens: number;
  outputTokens: number;
  ttfaMs: number;
  decodeMs: number;
  tokPerSec: number;
}

/** 外部文件读取结果（发送文件功能） */
export interface FileReadResult {
  /** 是否成功读到文本内容 */
  ok: boolean;
  /** 文本内容（可能被截断） */
  text: string;
  /** 原始文件字节数 */
  size: number;
  /** 内容超过读取上限被截断 */
  truncated: boolean;
  /** 判定为二进制文件（内容无法作为文本） */
  binary: boolean;
  /** 失败原因（ok/binary 时不适用） */
  error: string;
}

/** 文本读取上限（字节）：512KB，超出截断前段 */
const MAX_TEXT_BYTES: number = 512 * 1024;

/** ZIP 归档内单个条目（自研解析用） */
export interface ZipEntry {
  /** 归档内路径，如 word/document.xml */
  name: string;
  /** 解压后字节内容 */
  data: Uint8Array;
}

/** 沙箱中已导入的模型信息 */
export interface ModelInfo {
  /** 模型目录名（models/ 下的子目录名） */
  name: string;
  /** 模型目录完整路径（沙箱） */
  dir: string;
  /** 模型总大小（MB，一位小数） */
  sizeMB: number;
  /** 是否下载未完成（目录内存在 .tmp 残留）：true 时不可加载，应显示"下载中" */
  downloading: boolean;
}

/** ModelScope 市场模型条目 */
export interface MarketModel {
  /** 展示名 */
  name: string;
  /** ModelScope 仓库路径，如 MNN/Qwen3.5-0.8B-MNN */
  repo: string;
  /** 一句话描述 */
  desc: string;
  /** 预估下载大小（MB） */
  sizeMB: number;
  /** 模型格式：mnn（默认） / gguf（走 llama.cpp 引擎） */
  format?: 'mnn' | 'gguf';
  /** 纯文本聊天：跳过 visual.* 视觉文件（多模态模型专用，可省 60~190MB） */
  skipVisual?: boolean;
}

/** ModelScope 仓库文件条目（文件名 + 真实字节大小，来自 repo/files API 的 Size 字段） */
export interface RepoFile {
  /** 文件名，如 llm.mnn.weight */
  name: string;
  /** 文件字节大小（API 无该字段时为 -1） */
  size: number;
}

/** 单条对话消息（用于会话持久化 / 上下文记忆恢复） */
export interface ChatMessage {
  role: string;    // 'user' | 'assistant'
  content: string;
  /** 消息时间戳（毫秒）：持久化后作为 ForEach 唯一 key，保证不同会话切换时列表组件强制刷新（旧数据可能缺失） */
  time?: number;
  /** 联网搜索来源列表（可选，AI 消息引用来源时使用） */
  refs?: SearchRef[];
  /** 该条 AI 回复生成完成时的推理统计（如"输入12 · 输出345 · 12.3 tok/s"，按消息归属持久化） */
  stats?: string;
}

/** 联网搜索来源条目 */
export interface SearchRef {
  title: string;
  url: string;
  snippet: string;
}

/** 历史会话条目 */
export interface ChatSession {
  /** 会话唯一 id（时间戳） */
  id: string;
  /** 会话标题（首条用户消息截断） */
  title: string;
  /** 会话创建时间戳（毫秒）：一次对话即一组，新对话创建时记录 */
  createdAt: number;
  /** 最近更新时间戳（毫秒） */
  updatedAt: number;
  /** 消息列表 */
  messages: ChatMessage[];
  /** 是否置顶 */
  pinned: boolean;
  /** 生成该会话所用的模型名（旧数据可能缺失） */
  modelName?: string;
}

/** 模型推理参数（对应 UI 参数面板） */
export interface LLMParams {
  /** 温度 0.1~2.0 */
  temperature: number;
  /** top-k 采样 1~100 */
  topK: number;
  /** top-p 核采样 0.1~1.0 */
  topP: number;
  /** 最大输出 token 数 64~32768 */
  maxNewTokens: number;
  /** 上下文长度（注入模型的历史字符上限）1024~64000 */
  historyChars: number;
}

/** 单个模型的独立配置（每模型参数 + 预制提示词，按模型名存储） */
export interface ModelConfig {
  params: LLMParams;
  systemPrompt: string;
  /** 思考深度 0~100（旧数据可能缺失，默认 50） */
  thinkDepth?: number;
}

/** 联网搜索结果条目 */
export interface SearchItem {
  title: string;
  link: string;
  snippet: string;
}

/** native set_config 的思考模式配置结构（temperature/repetition_penalty 仅在思考模式下覆盖） */
interface ThinkingJinjaConfig {
  jinja: ThinkingContext;
  repetition_penalty?: number;
  temperature?: number;
}

interface ThinkingContext {
  context: ThinkingEnable;
}

interface ThinkingEnable {
  enable_thinking: boolean;
}

// ==================== 纯 ArkTS raw deflate 解压（移植自 zlib 参考实现 puff.c，公有领域） ====================
// 不依赖 SDK zlib：规避部分设备 raw inflate（负 windowBits）不可用导致的 ZIP 条目解压失败。
// 支持存储块 / 固定 Huffman / 动态 Huffman 三种 DEFLATE 块类型；结构错误或输入不足返回 null。

/** Huffman 解码表：count[len] = 长度 len 的码个数；symbol 按码长升序、同长按符号升序排列 */
interface HuffTable {
  count: number[];
  symbol: number[];
  left: number;
}

/** 纯 ArkTS raw deflate（RFC1951）解压器 */
function inflateRawDeflatePure(data: Uint8Array): Uint8Array | null {
  const LENS: number[] = [3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258];
  const LEXT: number[] = [0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0];
  const DISTS: number[] = [1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577];
  const DEXT: number[] = [0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13];
  const ORDER: number[] = [16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15];
  const MAXBITS: number = 15;
  const MAXCODES: number = 286 + 30;

  let inPos: number = 0;
  let bitbuf: number = 0;
  let bitcnt: number = 0;
  let out: Uint8Array = new Uint8Array(1 << 15);
  let outCnt: number = 0;

  /** 读取 need 位（LSB 优先），输入不足返回 -1 */
  const readBits = (need: number): number => {
    let val: number = bitbuf;
    while (bitcnt < need) {
      if (inPos >= data.length) {
        return -1;
      }
      val |= data[inPos] << bitcnt;
      inPos++;
      bitcnt += 8;
    }
    bitbuf = val >> need;
    bitcnt -= need;
    return val & ((1 << need) - 1);
  };

  /** 输出缓冲扩容，保证还能写 need 字节 */
  const ensure = (need: number): void => {
    if (outCnt + need <= out.length) {
      return;
    }
    let nl: number = out.length * 2;
    if (nl < outCnt + need) {
      nl = outCnt + need;
    }
    const nb: Uint8Array = new Uint8Array(nl);
    nb.set(out.subarray(0, outCnt));
    out = nb;
  };

  const outByte = (v: number): void => {
    ensure(1);
    out[outCnt++] = v;
  };

  /** 复制 back-reference：dist 距当前位置的回溯距离，len 复制长度（允许重叠） */
  const outBack = (dist: number, len: number): boolean => {
    if (dist <= 0 || dist > outCnt) {
      return false;
    }
    ensure(len);
    for (let i: number = 0; i < len; i++) {
      out[outCnt] = out[outCnt - dist];
      outCnt++;
    }
    return true;
  };

  /** 存储块直接拷贝 len 字节 */
  const outStored = (len: number): boolean => {
    if (inPos + len > data.length) {
      return false;
    }
    ensure(len);
    for (let i: number = 0; i < len; i++) {
      out[outCnt++] = data[inPos++];
    }
    return true;
  };

  /** 依码长数组构造规范 Huffman 表；left=0 完整 / >0 不完整 / <0 超额 */
  const construct = (lengths: number[], n: number): HuffTable => {
    const count: number[] = new Array<number>(MAXBITS + 1).fill(0);
    for (let i: number = 0; i < n; i++) {
      if (lengths[i] > 0) {
        count[lengths[i]]++;
      }
    }
    if (count[0] === n) {
      return { count: count, symbol: new Array<number>(0), left: 0 };
    }
    let left: number = 1;
    for (let len: number = 1; len <= MAXBITS; len++) {
      left = (left << 1) - count[len];
      if (left < 0) {
        return { count: count, symbol: new Array<number>(0), left: left };
      }
    }
    const offs: number[] = new Array<number>(MAXBITS + 1).fill(0);
    for (let len: number = 1; len < MAXBITS; len++) {
      offs[len + 1] = offs[len] + count[len];
    }
    const symbol: number[] = new Array<number>(n).fill(0);
    for (let i: number = 0; i < n; i++) {
      const l: number = lengths[i];
      if (l !== 0) {
        symbol[offs[l]] = i;
        offs[l]++;
      }
    }
    return { count: count, symbol: symbol, left: left };
  };

  /** 规范 Huffman 解码一个符号；-1 输入不足 / -10 非法码 */
  const decode = (h: HuffTable): number => {
    let code: number = 0;
    let first: number = 0;
    let index: number = 0;
    for (let len: number = 1; len <= MAXBITS; len++) {
      const b: number = readBits(1);
      if (b < 0) {
        return -1;
      }
      code |= b;
      const cnt: number = h.count[len];
      if (code - cnt < first) {
        return h.symbol[index + (code - first)];
      }
      index += cnt;
      first += cnt;
      first <<= 1;
      code <<= 1;
    }
    return -10;
  };

  /** 处理固定 Huffman 块（type=1） */
  const inflateFixed = (): number => {
    const lens: number[] = new Array<number>(288).fill(8);
    for (let i: number = 144; i < 256; i++) {
      lens[i] = 9;
    }
    for (let i: number = 256; i < 280; i++) {
      lens[i] = 7;
    }
    const lh: HuffTable = construct(lens, 288);
    if (lh.left !== 0) {
      return -1;
    }
    const dlens: number[] = new Array<number>(MAXCODES).fill(5);
    const dh: HuffTable = construct(dlens, 30);
    if (dh.left !== 0) {
      return -1;
    }
    return inflateCodes(lh, dh);
  };

  /** 处理存储块（type=0），按字节对齐 */
  const inflateStored = (): number => {
    bitbuf = 0;
    bitcnt = 0;
    const len: number = readBits(16);
    if (len < 0) {
      return -1;
    }
    const nlen: number = readBits(16);
    if (nlen < 0) {
      return -1;
    }
    if ((len & 0xffff) !== ((~nlen) & 0xffff)) {
      return -2;
    }
    if (!outStored(len)) {
      return -3;
    }
    return 0;
  };

  /** 处理动态 Huffman 块（type=2） */
  const inflateDynamic = (): number => {
    const b1: number = readBits(5);
    const b2: number = readBits(5);
    const b3: number = readBits(4);
    if (b1 < 0 || b2 < 0 || b3 < 0) {
      return -1;
    }
    const nlen: number = b1 + 257;
    const ndist: number = b2 + 1;
    const ncode: number = b3 + 4;
    if (nlen > 286 || ndist > 30) {
      return -1;
    }
    const lens: number[] = new Array<number>(MAXCODES).fill(0);
    for (let i: number = 0; i < ncode; i++) {
      const l: number = readBits(3);
      if (l < 0) {
        return -1;
      }
      lens[ORDER[i]] = l;
    }
    const ch: HuffTable = construct(lens, 19);
    if (ch.left !== 0) {
      return -4;
    }
    let index: number = 0;
    while (index < nlen + ndist) {
      let sym: number = decode(ch);
      if (sym < 0) {
        return sym;
      }
      if (sym < 16) {
        lens[index++] = sym;
      } else {
        let lenv: number = 0;
        if (sym === 16) {
          if (index === 0) {
            return -5;
          }
          lenv = lens[index - 1];
          const eb: number = readBits(2);
          if (eb < 0) {
            return -1;
          }
          sym = 3 + eb;
        } else if (sym === 17) {
          const eb: number = readBits(3);
          if (eb < 0) {
            return -1;
          }
          sym = 3 + eb;
        } else {
          const eb: number = readBits(7);
          if (eb < 0) {
            return -1;
          }
          sym = 11 + eb;
        }
        if (index + sym > nlen + ndist) {
          return -6;
        }
        while (sym > 0) {
          lens[index++] = lenv;
          sym--;
        }
      }
    }
    const lh: HuffTable = construct(lens, nlen);
    if (lh.left !== 0 && (lh.left < 0 || nlen !== lh.count[0] + lh.count[1])) {
      return -7;
    }
    const dlens: number[] = new Array<number>(MAXCODES).fill(0);
    for (let i: number = 0; i < ndist; i++) {
      dlens[i] = lens[nlen + i];
    }
    const dh: HuffTable = construct(dlens, ndist);
    if (dh.left !== 0 && (dh.left < 0 || ndist !== dh.count[0] + dh.count[1])) {
      return -8;
    }
    return inflateCodes(lh, dh);
  };

  /** 解码字面量/长度码与距离码并输出 */
  const inflateCodes = (lh: HuffTable, dh: HuffTable): number => {
    for (;;) {
      let sym: number = decode(lh);
      if (sym < 0) {
        return sym;
      }
      if (sym < 256) {
        outByte(sym);
      } else if (sym === 256) {
        return 0;
      } else {
        const li: number = sym - 257;
        if (li >= 29) {
          return -11;
        }
        const eb: number = readBits(LEXT[li]);
        if (eb < 0) {
          return -1;
        }
        const len: number = LENS[li] + eb;
        const ds: number = decode(dh);
        if (ds < 0) {
          return ds;
        }
        if (ds >= 30) {
          return -12;
        }
        const db: number = readBits(DEXT[ds]);
        if (db < 0) {
          return -1;
        }
        const dist: number = DISTS[ds] + db;
        if (!outBack(dist, len)) {
          return -13;
        }
      }
    }
  };

  // 主循环：逐块解压直到 last 块
  for (;;) {
    const lb: number = readBits(1);
    if (lb < 0) {
      return null;
    }
    const last: number = lb;
    const tb: number = readBits(2);
    if (tb < 0) {
      return null;
    }
    let ret: number = 0;
    if (tb === 0) {
      ret = inflateStored();
    } else if (tb === 1) {
      ret = inflateFixed();
    } else if (tb === 2) {
      ret = inflateDynamic();
    } else {
      return null;
    }
    if (ret !== 0) {
      return null;
    }
    if (last === 1) {
      break;
    }
  }
  const result: Uint8Array = new Uint8Array(outCnt);
  for (let i: number = 0; i < outCnt; i++) {
    result[i] = out[i];
  }
  return result;
}

export class LLMManager {
  private context: common.UIAbilityContext;
  private readonly filesDir: string;
  /** 当前使用的模型目录（'models/xxx' 表示沙箱中已下载的模型目录） */
  modelDir: string = '';
  /** 模型是否已加载成功 */
  isLoaded: boolean = false;
  /** 是否正在加载模型 */
  isLoading: boolean = false;
  /** 是否正在推理生成 */
  isGenerating: boolean = false;
  /** 思考模式开关（默认关闭：小模型思考模式下易陷入输出循环，直接回答更稳） */
  thinkingEnabled: boolean = false;
  /** 思考深度 0~100（默认 50）：越低越削弱思考、回答越快；越高保留更多推理步骤 */
  thinkingDepth: number = 50;
  /** 用户预制 system 提示词（与思考分档指令合并后注入原生层） */
  private customSystemPrompt: string = '';
  /** 当前推理引擎：mnn（.mnn 模型，config.json） / llama（.gguf 模型） */
  private currentEngine: 'mnn' | 'llama' = 'mnn';
  /** 最近一次应用侧合成的完整 system prompt（重建原生历史时前置） */
  private currentSystemPrompt: string = '';
  /** 下载取消标志：cancelDownload() 置位，下载循环检测后中断并清理 */
  private downloadCancelRequested: boolean = false;
  /** 最近一次加载失败的原因（供 UI 展示） */
  lastLoadError: string = '';

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.filesDir = context.filesDir;
  }

  /**
   * 加载模型：加载沙箱 models/ 目录下已下载的模型
   * @param dir 模型目录，格式 'models/xxx'
   * @returns Promise<number> 0 成功 / -1 失败
   */
  loadModel(dir: string): Promise<number> {
    this.modelDir = dir;
    this.isLoading = true;
    return new Promise<number>((resolve) => {
      if (!dir.startsWith('models/')) {
        this.isLoaded = false;
        this.isLoading = false;
        hilog.error(DOMAIN, TAG, 'invalid model dir: %{public}s', dir);
        resolve(-1);
        return;
      }
      const modelPath: string = `${this.filesDir}/${dir}`;
      const configPath: string = `${modelPath}/config.json`;
      // 双引擎识别：目录内存在 .gguf → llama.cpp 引擎；否则走 MNN 引擎
      const engine: 'mnn' | 'llama' = this.detectEngine(modelPath);
      this.currentEngine = engine;
      hilog.info(DOMAIN, TAG, 'start load model, engine=%{public}s dir=%{public}s', engine, dir);
      if (engine === 'llama') {
        const gguf: string = this.findGgufFile(modelPath);
        if (gguf === '') {
          this.isLoaded = false;
          this.isLoading = false;
          hilog.error(DOMAIN, TAG, 'no gguf file found in %{public}s', modelPath);
          resolve(-1);
          return;
        }
        llNativeLoadAsync(gguf, (result: number, msg: string) => {
          this.isLoaded = result === 0;
          this.isLoading = false;
          hilog.info(DOMAIN, TAG, 'llama load result: %{public}d msg=%{public}s', result, msg);
          if (result === 0) {
            this.applyThinkingConfig();
            this.rememberModel(dir);
          }
          resolve(result);
        });
      } else {
        // MNN 引擎完整性校验：存在 .tmp 残留（下载未完成）或权重文件缺失 → 拒绝加载，避免 native 崩溃
        if (this.hasTmpFile(modelPath)) {
          this.isLoaded = false;
          this.isLoading = false;
          this.lastLoadError = '存在未完成的 .tmp 临时文件（下载未完成，请稍候或到商店续传）';
          hilog.error(DOMAIN, TAG, 'model has incomplete tmp files, load aborted: %{public}s', modelPath);
          resolve(-1);
          return;
        }
        const weightPath: string = `${modelPath}/llm.mnn.weight`;
        if (!fs.accessSync(weightPath)) {
          this.isLoaded = false;
          this.isLoading = false;
          this.lastLoadError = '权重文件 llm.mnn.weight 缺失';
          hilog.error(DOMAIN, TAG, 'model weight missing, load aborted: %{public}s', weightPath);
          resolve(-1);
          return;
        }
        this.lastLoadError = '';
        nativeLoadAsync(configPath, (result: number) => {
          this.isLoaded = result === 0;
          this.isLoading = false;
          hilog.info(DOMAIN, TAG, 'load model result: %{public}d', result);
          // 加载成功后应用思考模式设置
          if (result === 0) {
            this.applyThinkingConfig();
            this.lastLoadError = '';
            this.rememberModel(dir);
          } else {
            this.lastLoadError = 'MNN 引擎加载失败（模型文件可能不兼容或内存不足）';
          }
          resolve(result);
        });
      }
    });
  }

  /** 按模型目录内容识别推理引擎：存在 .gguf → llama，否则 mnn */
  private detectEngine(modelPath: string): 'mnn' | 'llama' {
    return this.findGgufFile(modelPath) !== '' ? 'llama' : 'mnn';
  }

  /** 在模型目录中查找第一个 .gguf 模型文件（不存在返回空串） */
  private findGgufFile(modelPath: string): string {
    try {
      if (!fs.accessSync(modelPath)) {
        return '';
      }
      const names: string[] = fs.listFileSync(modelPath);
      for (const n of names) {
        if (n.toLowerCase().endsWith('.gguf')) {
          return `${modelPath}/${n}`;
        }
      }
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'find gguf failed: %{public}s', JSON.stringify(err));
    }
    return '';
  }

  /** 将当前思考开关/深度同步到 native（无需重新加载模型） */
  private applyThinkingConfig(): void {
    try {
      const depth: number = Math.min(100, Math.max(0, this.thinkingDepth));
      // 深度为 0 时视为完全关闭思考（模板不注入 <think>，直接回答）
      const thinking: boolean = this.thinkingEnabled && depth > 0;
      // 最终 system prompt = 诚实准则 + 深度分档指令（可选） + 用户预制提示词
      let prompt: string = this.customSystemPrompt;
      if (thinking) {
        const tierIdx: number = depth >= 70 ? 2 : (depth >= 31 ? 1 : 0);
        const tier: string = THINK_DEPTH_PROMPTS[tierIdx];
        prompt = tier + (prompt !== '' ? '\n\n' + prompt : '');
      }
      // 诚实准则恒定前置，确保任何对话模式下都抑制幻觉
      prompt = HONESTY_PROMPT + '\n\n' + prompt;
      if (this.currentEngine === 'llama') {
        // llama 引擎：仅注入 system prompt（chat 模板由 GGUF tokenizer.chat_template 渲染）
        llNativeSetSystemPrompt(prompt);
      } else {
        nativeSetSystemPrompt(prompt);
        const config: ThinkingJinjaConfig = {
          jinja: {
            context: {
              enable_thinking: thinking
            }
          }
        };
        // 仅思考模式下由深度接管采样参数（避免覆盖用户在 applyParams 里设置的温度/重复惩罚）：
        //   深度越高：重复抑制越弱（推理链更容易写长）、温度越高（探索更多路径）
        if (thinking) {
          config.repetition_penalty = 1.5 - (depth / 100) * 0.4; // 1.5 -> 1.1
          config.temperature = 0.5 + (depth / 100) * 0.6;        // 0.5 -> 1.1
        }
        nativeSetConfig(JSON.stringify(config));
      }
      hilog.info(DOMAIN, TAG, 'apply thinking config, engine=%{public}s enabled=%{public}s depth=%{public}d promptLen=%{public}d',
        this.currentEngine, String(this.thinkingEnabled), depth, prompt.length);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'apply thinking config failed: %{public}s', JSON.stringify(err));
    }
  }

  /** 调节思考深度（动态生效，0~100） */
  setThinkingDepth(depth: number): void {
    this.thinkingDepth = Math.min(100, Math.max(0, depth));
    if (this.isLoaded) {
      this.applyThinkingConfig();
    }
  }

  /** 切换思考模式（动态生效，不清空历史上下文） */
  setThinking(enabled: boolean): void {
    this.thinkingEnabled = enabled;
    if (this.isLoaded) {
      this.applyThinkingConfig();
    }
  }

  /**
   * 异步对话推理（nativeChatAsync）
   * 双语义兼容：厂商原始 so 的回调携带"已累计的完整回复"，自定义 bridge 的回调携带"增量片段"。
   * 本方法自动识别并统一为增量片段转发给 onDelta，由 UI 层按打字机节奏刷出。
   * @param prompt 用户输入
   * @param onDelta 每次回调携带增量文本（用于流式刷新 UI）
   * @param onDone 推理结束回调
   * @returns Promise<number> 0 成功 / -1 失败
   */
  chat(prompt: string, onDelta: (text: string) => void, onDone: () => void): Promise<number> {
    this.isGenerating = true;
    return new Promise<number>((resolve) => {
      try {
        let accumulated: string = '';
        let cbCount: number = 0;
        let cb: (result: string, isEop: number) => void = (result: string, isEop: number) => {
          if (isEop === 0) {
            // 语义识别：若 result 以已累计内容开头，说明是"累计全文"回调，取差值作为增量；
            // 否则视为独立增量片段，原样转发。
            let delta: string = result;
            if (result.length > accumulated.length && result.startsWith(accumulated)) {
              delta = result.substring(accumulated.length);
            }
            // 剥离模型输出的 <answer>...</answer> 包裹标签（部分 MNN 模型固定输出）
            delta = stripAnswerTags(delta);
            accumulated += delta;
            cbCount++;
            if (cbCount % 50 === 1) {
              hilog.info(DOMAIN, TAG, 'chat cb#%{public}d delta=%{public}d accum=%{public}d',
                cbCount, delta.length, accumulated.length);
            }
            onDelta(delta);
          } else {
            // is_eop 为 1 表示推理结束：先对完整回复做整体清理（处理跨片段的 <answer> 标签残留），
            // 再去除回复末尾换行（response 默认以 "\n" 结尾）
            accumulated = stripAnswerTags(accumulated);
            if (accumulated.endsWith('\n')) {
              accumulated = accumulated.substring(0, accumulated.length - 1);
            }
            onDone();
            this.isGenerating = false;
            resolve(0);
          }
        };
        const ret: number = this.currentEngine === 'llama'
          ? llNativeChatAsync(prompt, cb)
          : nativeChatAsync(prompt, cb);
        // 同步返回 -1 表示推理启动失败（回调可能不再触发），交由调用方收尾
        if (ret !== 0) {
          this.isGenerating = false;
          resolve(ret);
        }
      } catch (e) {
        const err = e as BusinessError;
        hilog.error(DOMAIN, TAG, 'chat failed: %{public}s', JSON.stringify(err));
        this.isGenerating = false;
        resolve(-1);
      }
    });
  }

  /** 请求中断当前生成（非阻塞）：原生层会中断推理并回调结束 */
  stop(): void {
    try {
      if (this.currentEngine === 'llama') {
        llNativeStop();
      } else {
        nativeStop();
      }
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'stop failed: %{public}s', JSON.stringify(err));
    }
  }

  /** 读取 native 推理统计 */
  getStats(): LLMStats {
    const empty: LLMStats = { promptTokens: 0, outputTokens: 0, ttfaMs: 0, decodeMs: 0, tokPerSec: 0 };
    try {
      const json: string = this.currentEngine === 'llama' ? llNativeStats() : nativeStats();
      if (json === '' || json === '{}') {
        return empty;
      }
      const obj: Record<string, number> = JSON.parse(json) as Record<string, number>;
      return {
        promptTokens: obj['promptTokens'] ?? 0,
        outputTokens: obj['outputTokens'] ?? 0,
        ttfaMs: obj['ttfaMs'] ?? 0,
        decodeMs: obj['decodeMs'] ?? 0,
        tokPerSec: obj['tokPerSec'] ?? 0
      };
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'getStats failed: %{public}s', JSON.stringify(err));
      return empty;
    }
  }

  /** 重置多轮对话上下文 */
  resetConversation(): void {
    const ret: number = this.currentEngine === 'llama' ? llNativeReset() : nativeReset();
    hilog.info(DOMAIN, TAG, 'reset conversation result: %{public}d', ret);
  }

  /**
   * 应用推理参数到原生层（温度/top-k/top-p/最大输出 token/上下文长度），
   * 无需重新加载模型。模型未加载时静默跳过（加载成功后会由 UI 再次应用）。
   * @param params 推理参数
   */
  applyParams(params: LLMParams): void {
    try {
      const isLlama: boolean = this.currentEngine === 'llama';
      // llama bridge 采用下划线风格配置键（repeat_penalty）；MNN bridge 采用驼峰（repetition_penalty）
      const config: Record<string, number> = {
        'temperature': params.temperature,
        'max_new_tokens': params.maxNewTokens,
        'history_max_chars': params.historyChars
      };
      if (isLlama) {
        config['top_k'] = params.topK;
        config['top_p'] = params.topP;
        config['repeat_penalty'] = 1.15;
      } else {
        config['topK'] = params.topK;
        config['topP'] = params.topP;
        config['repetition_penalty'] = 1.15;
      }
      if (isLlama) {
        llNativeSetConfig(JSON.stringify(config));
      } else {
        nativeSetConfig(JSON.stringify(config));
      }
      hilog.info(DOMAIN, TAG, 'apply params: temp=%{public}s topK=%{public}s topP=%{public}s maxT=%{public}s ctx=%{public}s',
        String(params.temperature), String(params.topK), String(params.topP),
        String(params.maxNewTokens), String(params.historyChars));
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'apply params failed: %{public}s', JSON.stringify(err));
    }
  }

  /** 设置预制提示词（system prompt），空串清除。思考模式下会与深度分档指令合并后注入 */
  setSystemPrompt(prompt: string): void {
    this.customSystemPrompt = prompt;
    if (this.isLoaded) {
      this.applyThinkingConfig();
    }
  }

  /**
   * 恢复历史会话上下文（上下文记忆）：
   * 将持久化的消息数组写回原生层 g_messages，使恢复会话后的首轮对话携带完整上下文。
   * 生成期间会被原生层拒绝（返回 -1），由调用方忽略。
   * @param messages 消息数组 [{role, content}, ...]
   */
  setHistory(messages: ChatMessage[]): void {
    try {
      const ret: number = this.currentEngine === 'llama'
        ? llNativeSetHistory(JSON.stringify(messages))
        : nativeSetHistory(JSON.stringify(messages));
      hilog.info(DOMAIN, TAG, 'set history, count=%{public}d, ret=%{public}d', messages.length, ret);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'set history failed: %{public}s', JSON.stringify(err));
    }
  }

  /**
   * 将 UI 侧完整消息历史（含思考标签）连同 system 提示词同步到原生层。
   * 用途：MNN 引擎的历史默认用 StripThink 剥离 <think>，第二轮起模板会对"不以 <think> 开头"的
   * 历史 assistant 注入未闭合的 <think>，导致模型上下文混乱（只输出思考、没有正文）。
   * 这里改用 UI 侧完整文本重建原生历史，让模板按完整闭合的思考块渲染。
   */
  syncHistory(messages: ChatMessage[]): void {
    try {
      const msgs: ChatMessage[] = [];
      if (this.currentSystemPrompt !== '') {
        msgs.push({ role: 'system', content: this.currentSystemPrompt });
      }
      for (const m of messages) {
        msgs.push({ role: m.role, content: m.content });
      }
      const ret: number = this.currentEngine === 'llama'
        ? llNativeSetHistory(JSON.stringify(msgs))
        : nativeSetHistory(JSON.stringify(msgs));
      hilog.info(DOMAIN, TAG, 'sync history, count=%{public}d, ret=%{public}d', msgs.length, ret);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'sync history failed: %{public}s', JSON.stringify(err));
    }
  }

  // ==================== 历史会话持久化（preferences） ====================

  /** 保存全部会话列表到本地 */
  saveSessions(sessions: ChatSession[]): void {
    try {
      const store = preferences.getPreferencesSync(this.context, { name: 'chat_sessions' });
      store.putSync('sessions', JSON.stringify(sessions));
      store.flush();
      hilog.info(DOMAIN, TAG, 'saved %{public}d sessions', sessions.length);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'saveSessions failed: %{public}s', JSON.stringify(err));
    }
  }

  /** 加载全部会话列表 */
  loadSessions(): ChatSession[] {
    try {
      const store = preferences.getPreferencesSync(this.context, { name: 'chat_sessions' });
      const json: string = store.getSync('sessions', '[]') as string;
      const list = JSON.parse(json) as ChatSession[];
      hilog.info(DOMAIN, TAG, 'loaded %{public}d sessions', list.length);
      return list;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'loadSessions failed: %{public}s', JSON.stringify(err));
      return [];
    }
  }

  // ==================== 每模型配置持久化（模型管理） ====================

  /** 记住最近一次成功加载的模型名（供下次自动加载；模型被删除后调用方会跳过） */
  rememberModel(dir: string): void {
    try {
      const name: string = dir.startsWith('models/') ? dir.substring(7) : dir;
      const store = preferences.getPreferencesSync(this.context, { name: 'model_configs' });
      store.putSync('last_model', name);
      store.flush();
      hilog.info(DOMAIN, TAG, 'remember model: %{public}s', name);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'rememberModel failed: %{public}s', JSON.stringify(err));
    }
  }

  /** 读取上次成功加载的模型名（不存在返回空串） */
  getRememberedModel(): string {
    try {
      const store = preferences.getPreferencesSync(this.context, { name: 'model_configs' });
      return store.getSync('last_model', '') as string;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'getRememberedModel failed: %{public}s', JSON.stringify(err));
      return '';
    }
  }

  /** 保存各模型独立配置（key=模型名） */
  saveModelConfigs(configs: Record<string, ModelConfig>): void {
    try {
      const store = preferences.getPreferencesSync(this.context, { name: 'model_configs' });
      store.putSync('configs', JSON.stringify(configs));
      store.flush();
      hilog.info(DOMAIN, TAG, 'saved %{public}d model configs', Object.keys(configs).length);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'saveModelConfigs failed: %{public}s', JSON.stringify(err));
    }
  }

  /** 加载各模型独立配置 */
  loadModelConfigs(): Record<string, ModelConfig> {
    try {
      const store = preferences.getPreferencesSync(this.context, { name: 'model_configs' });
      const json: string = store.getSync('configs', '{}') as string;
      const obj = JSON.parse(json) as Record<string, ModelConfig>;
      hilog.info(DOMAIN, TAG, 'loaded %{public}d model configs', Object.keys(obj).length);
      return obj;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'loadModelConfigs failed: %{public}s', JSON.stringify(err));
      return {};
    }
  }

  /** 递归删除目录（沙箱内） */
  private deleteDirRecursive(dir: string): void {
    try {
      const entries: string[] = fs.listFileSync(dir);
      for (let i = 0; i < entries.length; i++) {
        const full: string = `${dir}/${entries[i]}`;
        try {
          const stat: fs.Stat = fs.statSync(full);
          if (stat.isDirectory()) {
            this.deleteDirRecursive(full);
          } else {
            fs.unlinkSync(full);
          }
        } catch (e) {
          const err = e as BusinessError;
          hilog.error(DOMAIN, TAG, 'delete entry %{public}s failed: %{public}s', full, JSON.stringify(err));
        }
      }
      fs.rmdirSync(dir);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'deleteDirRecursive %{public}s failed: %{public}s', dir, JSON.stringify(err));
    }
  }

  /** 删除沙箱中的模型目录（仅本地导入模型；内置模型不可删除） */
  deleteModel(name: string): boolean {
    try {
      const dir: string = `${this.filesDir}/models/${name}`;
      this.deleteDirRecursive(dir);
      hilog.info(DOMAIN, TAG, 'deleted model dir: %{public}s', dir);
      return true;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'deleteModel %{public}s failed: %{public}s', name, JSON.stringify(err));
      return false;
    }
  }

  // ==================== 联网搜索 ====================

  /**
   * 执行联网搜索，返回结构化结果文本（供注入 prompt 供模型引用）。
   * @param query 搜索关键词
   * @param engine 搜索引擎：'wikipedia' | 'bing'
   * @returns Promise<SearchItem[]> 搜索结果；失败返回空数组
   */
  searchWeb(query: string, engine: string): Promise<SearchItem[]> {
    if (engine === 'wikipedia') {
      return this.searchWikipedia(query);
    }
    return this.searchBing(query);
  }

  /** 维基百科搜索（免费 API，返回 JSON） */
  private searchWikipedia(query: string): Promise<SearchItem[]> {
    return new Promise<SearchItem[]>((resolve) => {
      const req = http.createHttp();
      const url: string =
        `https://zh.wikipedia.org/w/api.php?action=query&list=search&srsearch=${encodeURIComponent(query)}&format=json&utf8=1&srlimit=5`;
      req.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 10000,
        readTimeout: 15000
      }).then((resp: http.HttpResponse) => {
        req.destroy();
        if (resp.responseCode !== 200) {
          resolve([]);
          return;
        }
        const obj = JSON.parse(resp.result as string) as Record<string, Object>;
        const queryObj = obj['query'] as Record<string, Object>;
        const arr = queryObj['search'] as Array<Record<string, Object>>;
        if (arr === undefined) {
          resolve([]);
          return;
        }
        const items: SearchItem[] = [];
        for (let i = 0; i < arr.length; i++) {
          const title: string = arr[i]['title'] as string;
          let snippet: string = this.stripHtml(arr[i]['snippet'] as string);
          const link: string = `https://zh.wikipedia.org/wiki/${encodeURIComponent(title.replace(/ /g, '_'))}`;
          items.push({ title: title, link: link, snippet: snippet });
        }
        hilog.info(DOMAIN, TAG, 'wikipedia search "%{public}s" -> %{public}d', query, items.length);
        resolve(items);
      }).catch((e: BusinessError) => {
        req.destroy();
        hilog.warn(DOMAIN, TAG, 'wikipedia search failed: %{public}s', JSON.stringify(e));
        resolve([]);
      });
    });
  }

  /** Bing 搜索（抓取 HTML 解析标题/摘要，请求失败时降级返回空） */
  private searchBing(query: string): Promise<SearchItem[]> {
    return new Promise<SearchItem[]>((resolve) => {
      const req = http.createHttp();
      const url: string = `https://cn.bing.com/search?q=${encodeURIComponent(query)}&setlang=zh-CN`;
      req.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 10000,
        readTimeout: 15000,
        header: { 'User-Agent': 'Mozilla/5.0' }
      }).then((resp: http.HttpResponse) => {
        req.destroy();
        if (resp.responseCode !== 200) {
          resolve([]);
          return;
        }
        const html: string = resp.result as string;
        const items: SearchItem[] = this.parseBingHtml(html);
        hilog.info(DOMAIN, TAG, 'bing search "%{public}s" -> %{public}d', query, items.length);
        resolve(items);
      }).catch((e: BusinessError) => {
        req.destroy();
        hilog.warn(DOMAIN, TAG, 'bing search failed: %{public}s', JSON.stringify(e));
        resolve([]);
      });
    });
  }

  /** 解析 Bing 搜索结果 HTML（提取标题/链接/摘要） */
  private parseBingHtml(html: string): SearchItem[] {
    const items: SearchItem[] = [];
    // 按 <li class="b_algo"> 切块
    const parts: string[] = html.split('<li class="b_algo');
    for (let i = 1; i < parts.length && items.length < 5; i++) {
      const block: string = parts[i];
      const titleMatch: RegExpMatchArray | null = block.match(/<h2[^>]*>\s*<a[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>/);
      if (titleMatch === null) {
        continue;
      }
      const link: string = titleMatch[1];
      const title: string = this.stripHtml(titleMatch[2]).trim();
      // 摘要：b_caption 或 b_paractl 段落
      const capMatch: RegExpMatchArray | null = block.match(/<p[^>]*>([\s\S]*?)<\/p>/);
      const snippet: string = capMatch !== null ? this.stripHtml(capMatch[1]).trim() : '';
      items.push({ title: title, link: link, snippet: snippet });
    }
    return items;
  }

  /** 去除 HTML 标签与常见实体 */
  private stripHtml(html: string): string {
    let s: string = html;
    s = s.replace(/<[^>]+>/g, '');
    s = s.replace(/&quot;/g, '"').replace(/&amp;/g, '&').replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>').replace(/&nbsp;/g, ' ').replace(/&#\d+;/g, ' ');
    return s;
  }

  // ==================== 文件/图片辅助 ====================

  /**
   * 读取文本文件内容（用于"上传文件"注入对话上下文）
   * 仅支持文本类文件且限 64KB，超出或读取失败返回空串
   * @param uri 文件 uri
   */
  /**
   * 读取用户选择的外部文件：
   * 1) 优先直接按授权 uri 读取（DocumentViewPicker 返回的 file://docs 或 datashare:// 授权 uri，openSync 可直接打开）
   * 2) 直接读取失败时，把 uri 拷贝到应用沙箱 attachments/ 目录再读（兼容部分不支持直接打开的 uri）
   * 3) 文本内容 UTF-8 最多 512KB，超长截断前段；二进制检测：前 512 字节含空字节判为二进制
   * @param uri  文件选择器返回的 uri
   * @param name 文件名（用于沙箱落盘）
   */
  readAttachedFile(uri: string, name: string): FileReadResult {
    const ext: string = LLMManager.extOf(name);
    // HTML：按文本读取后剥离标签，保留段落结构
    if (ext === 'html' || ext === 'htm') {
      const hr: FileReadResult = this.readFileText(uri);
      if (hr.ok && !hr.binary) {
        const t: string = this.stripHtmlDoc(hr.text);
        return { ok: t.trim() !== '', text: t, size: hr.size, truncated: hr.truncated, binary: false, error: '' };
      }
      return hr;
    }
    // 旧版 DOC（OLE 复合文档）：整文件按 UTF-16LE 解码后过滤可读文本段，尽力提取
    if (ext === 'doc') {
      let bytes: Uint8Array | null = this.readAllBytes(uri);
      if (bytes === null) {
        try {
          const attDir: string = `${this.filesDir}/attachments`;
          fs.mkdirSync(attDir, true);
          const safeName: string = name.replace(/[\\/:*?"<>|]/g, '_');
          const dest: string = `${attDir}/${safeName}`;
          fs.copyFileSync(uri, dest);
          bytes = this.readAllBytes(dest);
        } catch (e2) {
          bytes = null;
        }
      }
      if (bytes !== null) {
        const t: string = this.extractDocText(bytes);
        return { ok: t.trim() !== '', text: t, size: bytes.length, truncated: bytes.length > MAX_TEXT_BYTES, binary: false, error: '' };
      }
      return { ok: false, text: '', size: 0, truncated: false, binary: false, error: '无法读取 DOC 文件（可能无读取权限）' };
    }
    // 优先直接读取授权 uri（无需拷贝）
    const direct: FileReadResult = this.readFileText(uri);
    if (direct.ok || direct.binary) {
      return direct;
    }
    // 直接读取失败：尝试拷贝到沙箱后读取（copyFileSync 官方推荐直接传授权 uri）
    try {
      const attDir: string = `${this.filesDir}/attachments`;
      fs.mkdirSync(attDir, true);
      // 清洗文件名，防止非法字符破坏沙箱路径
      const safeName: string = name.replace(/[\\/:*?"<>|]/g, '_');
      const dest: string = `${attDir}/${safeName}`;
      fs.copyFileSync(uri, dest);
      return this.readFileText(dest);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'readAttachedFile %{public}s failed: %{public}s', name, JSON.stringify(err));
      // 合并直读失败原因与错误码，便于定位
      const msg: string = direct.error !== '' ? `${direct.error}（${err.message} code=${err.code}）` :
        `无法读取该文件（可能无读取权限，code=${err.code}）`;
      return { ok: false, text: '', size: 0, truncated: false, binary: false, error: msg };
    }
  }

  // ==================== 办公文档/网页 文本提取 ====================

  /** 从文件名取扩展名（小写，不含点） */
  static extOf(name: string): string {
    const i: number = name.lastIndexOf('.');
    if (i === -1) {
      return '';
    }
    return name.substring(i + 1).toLowerCase();
  }

  /** 剥离 HTML 标签（文档用，比搜索解析版更完整）：去掉 script/style/注释，块级标签转行，解码常见实体 */
  private stripHtmlDoc(html: string): string {
    let s: string = html;
    s = s.replace(/<script[\s\S]*?<\/script>/gi, ' ');
    s = s.replace(/<style[\s\S]*?<\/style>/gi, ' ');
    s = s.replace(/<!--[\s\S]*?-->/g, ' ');
    s = s.replace(/<(br|p|div|h[1-6]|li|tr|table)\b[^>]*>/gi, '\n');
    s = s.replace(/<[^>]+>/g, '');
    s = s.replace(/&nbsp;/g, ' ').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&#(\d+);/g,
        (full: string, d: string): string => String.fromCharCode(parseInt(d, 10)));
    s = s.replace(/[ \t]{2,}/g, ' ');
    s = s.replace(/\n{3,}/g, '\n\n');
    return s.trim();
  }

  /** 读取文件全部字节（默认上限 20MB，office 归档可传更大上限），失败返回 null */
  private readAllBytes(uri: string, maxBytes?: number): Uint8Array | null {
    try {
      const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      try {
        const stat = fs.statSync(uri);
        if (stat.size <= 0) {
          return null;
        }
        const cap: number = maxBytes !== undefined && maxBytes > 0 ? maxBytes : 20 * 1024 * 1024;
        const len: number = Math.min(stat.size, cap);
        const buf = new ArrayBuffer(len);
        let pos: number = 0;
        while (pos < len) {
          const n: number = fs.readSync(file.fd, buf, { offset: pos, length: len - pos });
          if (n <= 0) {
            break;
          }
          pos += n;
        }
        return new Uint8Array(buf, 0, pos);
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      return null;
    }
  }

  /** 旧版 .doc：整文件按 UTF-16LE 解码后，过滤出连续可读文本段（中文/英文/数字），尽力提取 */
  private extractDocText(bytes: Uint8Array): string {
    const chars: string[] = [];
    const end: number = bytes.length - 1 - (bytes.length % 2);
    for (let i = 0; i < end; i += 2) {
      chars.push(String.fromCharCode(bytes[i] | (bytes[i + 1] << 8)));
    }
    const s: string = chars.join('');
    const segs: RegExpMatchArray | null = s.match(
      /[\u4e00-\u9fff\u3040-\u30ff\u3400-\u4dbf\uff00-\uffef\u2018-\u201f\u3000-\u303fA-Za-z0-9]{2,}(?:[\s.,;:!?()\-'"%\/\\：，。；、！？（）【】"“”'][\u4e00-\u9fff\u3040-\u30ff\u3400-\u4dbf\uff00-\uffef\u2018-\u201f\u3000-\u303fA-Za-z0-9]{1,}){0,12}/g);
    if (segs === null) {
      return '';
    }
    let out: string = segs.join('\n');
    if (out.length > MAX_TEXT_BYTES) {
      out = out.substring(0, MAX_TEXT_BYTES);
    }
    return out;
  }


  /** 解码 XML 常见实体 */
  private decodeXmlEntities(s: string): string {
    return s.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"')
      .replace(/&apos;/g, "'").replace(/&amp;/g, '&');
  }

  /** DOCX：从 word/document.xml 提取段落文本（<w:p> 段落、<w:t> 文本） */
  private extractDocxText(xml: string): string {
    const s: string = xml.replace(/<\/w:p>/gi, '\n').replace(/<\/w:tr>/gi, '\n');
    const paras: string[] = s.split('\n');
    const parts: string[] = [];
    for (let i = 0; i < paras.length; i++) {
      const re: RegExp = /<w:t(?:\s[^>]*)?>([\s\S]*?)<\/w:t>/g;
      const segs: string[] = [];
      let m: RegExpExecArray | null;
      while ((m = re.exec(paras[i])) !== null) {
        const v: string = this.decodeXmlEntities(m[1]);
        if (v !== '') {
          segs.push(v);
        }
      }
      if (segs.length > 0) {
        parts.push(segs.join(''));
      }
    }
    return parts.join('\n');
  }

  /** PPTX：从单个 slide XML 提取文本（<a:p> 段落、<a:t> 文本） */
  private extractPptxText(xml: string): string {
    const s: string = xml.replace(/<\/a:p>/gi, '\n');
    const paras: string[] = s.split('\n');
    const parts: string[] = [];
    for (let i = 0; i < paras.length; i++) {
      const re: RegExp = /<a:t(?:\s[^>]*)?>([\s\S]*?)<\/a:t>/g;
      const segs: string[] = [];
      let m: RegExpExecArray | null;
      while ((m = re.exec(paras[i])) !== null) {
        const v: string = this.decodeXmlEntities(m[1]).trim();
        if (v !== '') {
          segs.push(v);
        }
      }
      if (segs.length > 0) {
        parts.push(segs.join(''));
      }
    }
    return parts.join('\n');
  }


  /** 小端读取 u16 */
  private leU16(b: Uint8Array, off: number): number {
    return b[off] | (b[off + 1] << 8);
  }

  /** 小端读取 u32 */
  private leU32(b: Uint8Array, off: number): number {
    return ((b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24)) >>> 0);
  }

  /** Uint8Array -> UTF-8 字符串 */
  private bytesToUtf8(b: Uint8Array): string {
    try {
      const decoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(b);
    } catch (e) {
      return '';
    }
  }

  /**
   * 自研 ZIP 解析器：无需落盘解压，直接在内存中读取归档条目。
   * 步骤：EOCD（尾部 PK\x05\x06）→ Central Directory（PK\x01\x02）→ 各条目
   * Local File Header（PK\x03\x04）定位压缩数据；method 0 原样取，method 8 用
   * raw inflate（inflateInit2 windowBits=-15）解压。docx/pptx 均可提取。
   */
  private async parseZipEntries(bytes: Uint8Array): Promise<Array<ZipEntry>> {
    const out: Array<ZipEntry> = [];
    try {
      // 1. 从文件尾部向前搜索 EOCD 签名（0x50 0x4b 0x05 0x06），ZIP 注释最长 65535 字节
      let eocd: number = -1;
      const scanFrom: number = Math.max(0, bytes.length - 65557);
      for (let i = bytes.length - 22; i >= scanFrom; i--) {
        if (bytes[i] === 0x50 && bytes[i + 1] === 0x4b && bytes[i + 2] === 0x05 && bytes[i + 3] === 0x06) {
          eocd = i;
          break;
        }
      }
      if (eocd < 0) {
        return out;
      }
      const totalEntries: number = this.leU16(bytes, eocd + 10);
      const cdOffset: number = this.leU32(bytes, eocd + 16);
      // 2. 遍历 Central Directory
      let pos: number = cdOffset;
      for (let n = 0; n < totalEntries; n++) {
        if (pos + 46 > bytes.length) {
          break;
        }
        if (!(bytes[pos] === 0x50 && bytes[pos + 1] === 0x4b && bytes[pos + 2] === 0x01 && bytes[pos + 3] === 0x02)) {
          break;
        }
        const method: number = this.leU16(bytes, pos + 10);
        const compSize: number = this.leU32(bytes, pos + 20);
        const nameLen: number = this.leU16(bytes, pos + 28);
        const extraLen: number = this.leU16(bytes, pos + 30);
        const commentLen: number = this.leU16(bytes, pos + 32);
        const lho: number = this.leU32(bytes, pos + 42);
        const name: string = this.bytesToUtf8(bytes.slice(pos + 46, pos + 46 + nameLen));
        // 3. 定位 Local File Header，读取压缩数据
        if (lho + 30 <= bytes.length && bytes[lho] === 0x50 && bytes[lho + 1] === 0x4b
          && bytes[lho + 2] === 0x03 && bytes[lho + 3] === 0x04) {
          const lNameLen: number = this.leU16(bytes, lho + 26);
          const lExtraLen: number = this.leU16(bytes, lho + 28);
          const dStart: number = lho + 30 + lNameLen + lExtraLen;
          const dEnd: number = Math.min(dStart + compSize, bytes.length);
          if (dEnd > dStart) {
            const comp: Uint8Array = bytes.slice(dStart, dEnd);
            if (method === 0) {
              out.push({ name: name, data: comp });
            } else if (method === 8) {
              const raw: Uint8Array | null = await this.inflateZipRaw(comp);
              if (raw !== null) {
                out.push({ name: name, data: raw });
              }
            }
          }
        }
        pos += 46 + nameLen + extraLen + commentLen;
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'parseZipEntries failed: %{public}s', JSON.stringify(e));
    }
    return out;
  }

  /** ZIP 条目 raw deflate（RFC1951）解压，失败返回 null。
   *  三档模式兜底：① windowBits=-15 raw（ZIP 标准）→ ② 47 自动检测 → ③ 15 + 伪造 zlib 头
   *  （部分 SDK 实现不支持负 windowBits 时的兜底；伪造头后缺 4 字节 adler 校验尾会返回 BUF_ERROR，
   *  但解压输出已完整产生，BUF_ERROR 视为成功）。
   *  长度判定三重兜底：availableOut 差值 → totalOut → 输出缓冲首个 NUL 前长度。 */
  private async inflateZipRaw(data: Uint8Array): Promise<Uint8Array | null> {
    // 优先纯 ArkTS 解压（puff 移植，真机行为确定）；失败再回退 SDK zlib 三档 windowBits 模式
    const pure: Uint8Array | null = inflateRawDeflatePure(data);
    if (pure !== null && pure.length > 0) {
      hilog.info(DOMAIN, TAG, 'pure inflate ok in=%{public}d out=%{public}d', data.length, pure.length);
      return pure;
    }
    const MAX_OUT: number = 64 * 1024 * 1024;
    let outSize: number = Math.max(Math.min(data.length * 20, 4 * 1024 * 1024), 256 * 1024);
    let attempts: number = 0;
    while (attempts++ < 6 && outSize <= MAX_OUT) {
      const modes: number[] = [-15, 15 + 32, 15];
      for (let w = 0; w < modes.length; w++) {
        try {
          const zip = zlib.createZipSync();
          const strm: zlib.ZStream = await zip.getZStream();
          const init: zlib.ReturnStatus = await zip.inflateInit2(strm, modes[w]);
          if (init !== zlib.ReturnStatus.OK) {
            hilog.warn(DOMAIN, TAG, 'inflateInit2(%{public}d) rc=%{public}d', modes[w], init);
            continue;
          }
          let src: ArrayBuffer;
          let availIn: number;
          if (modes[w] === 15) {
            // 伪造 zlib 头（CMF=0x78, FLG=0x9C = deflate + 32K 窗口），raw deflate 数据接在其后
            const wrapped: Uint8Array = new Uint8Array(data.length + 2);
            wrapped[0] = 0x78;
            wrapped[1] = 0x9c;
            wrapped.set(data, 2);
            src = wrapped.buffer as ArrayBuffer;
            availIn = wrapped.length;
          } else {
            src = data.buffer.slice(data.byteOffset, data.byteOffset + data.length) as ArrayBuffer;
            availIn = data.length;
          }
          strm.nextIn = src;
          strm.availableIn = availIn;
          const dest: ArrayBuffer = new ArrayBuffer(outSize);
          strm.nextOut = dest;
          strm.availableOut = outSize;
          const st: zlib.ReturnStatus = await zip.inflate(strm, zlib.CompressFlushMode.FINISH);
          const availOut: number = strm.availableOut ?? -1;
          const totalOut: number = strm.totalOut ?? -1;
          await zip.inflateEnd(strm);
          const okSt: boolean = st === zlib.ReturnStatus.STREAM_END || st === zlib.ReturnStatus.OK
            || (modes[w] === 15 && st === zlib.ReturnStatus.BUF_ERROR);
          if (okSt) {
            let total: number = outSize - (availOut > 0 ? availOut : 0);
            if (totalOut > total) {
              total = totalOut;
            }
            if (total <= 0) {
              // 兜底：SDK 实现可能不更新 availableOut/totalOut，取输出缓冲中首个 NUL 前的有效长度
              const view: Uint8Array = new Uint8Array(dest);
              let end: number = 0;
              while (end < view.length && view[end] !== 0) {
                end++;
              }
              total = end;
            }
            if (total > 0) {
              const real: number = Math.min(total, dest.byteLength);
              hilog.info(DOMAIN, TAG, 'inflate ok mode=%{public}d st=%{public}d in=%{public}d out=%{public}d', modes[w], st, data.length, real);
              return new Uint8Array(dest.slice(0, real));
            }
          } else {
            hilog.warn(DOMAIN, TAG, 'inflate mode=%{public}d st=%{public}d availOut=%{public}d totalOut=%{public}d size=%{public}d', modes[w], st, availOut, totalOut, outSize);
          }
        } catch (e) {
          const em = (e as BusinessError).message;
          hilog.warn(DOMAIN, TAG, 'inflateZipRaw ex mode=%{public}d size=%{public}d: %{public}s', modes[w], outSize, em !== undefined ? em : '');
        }
      }
      outSize = Math.min(outSize * 4, MAX_OUT);
    }
    hilog.warn(DOMAIN, TAG, 'inflateZipRaw all failed, in=%{public}d', data.length);
    return null;
  }

  /** 从 zip 归档条目中提取可读文本：优先拼接小体积的 txt/md/xml/html 等条目（含内嵌 docx 的 document.xml） */
  private extractZipText(entries: Array<ZipEntry>, maxTextBytes: number): string {
    const parts: string[] = [];
    let total: number = 0;
    for (let i = 0; i < entries.length; i++) {
      const n: string = entries[i].name.toLowerCase();
      if (n.indexOf('word/document.xml') !== -1) {
        const t: string = this.extractDocxText(this.bytesToUtf8(entries[i].data));
        if (t.trim() !== '') {
          parts.push(`【${entries[i].name}】\n${t.trim()}`);
          total += t.length;
        }
        continue;
      }
      if (n.endsWith('.txt') || n.endsWith('.md') || n.endsWith('.markdown')
        || n.endsWith('.xml') || n.endsWith('.html') || n.endsWith('.htm')
        || n.endsWith('.json') || n.endsWith('.csv') || n.endsWith('.log')
        || n.endsWith('.css') || n.endsWith('.js')) {
        if (entries[i].data.length <= maxTextBytes) {
          const t: string = (n.endsWith('.html') || n.endsWith('.htm')) ?
            this.stripHtmlDoc(this.bytesToUtf8(entries[i].data)) :
            this.bytesToUtf8(entries[i].data);
          const ct: string = t.trim();
          if (ct !== '') {
            parts.push(`【${entries[i].name}】\n${ct}`);
            total += ct.length;
            if (total >= maxTextBytes) {
              break;
            }
          }
        }
      }
    }
    return parts.join('\n\n');
  }

  /**
   * 异步读取 ZIP 系/PDF 办公文档（docx/pptx/pdf/zip）：
   * 1) docx/pptx/zip 拷贝到沙箱后用自研 ZIP 解析器在内存中提取 XML/文本；
   * 2) pdf 扫描内容流中的 FlateDecode 块解压，提取 Tj/TJ 文本操作符。
   */
  async readOfficeFile(uri: string, name: string): Promise<FileReadResult> {
    const ext: string = LLMManager.extOf(name);
    try {
      const attDir: string = `${this.filesDir}/attachments`;
      fs.mkdirSync(attDir, true);
      const safeName: string = name.replace(/[\\/:*?"<>|]/g, '_');
      const srcPath: string = `${attDir}/${safeName}`;
      fs.copyFileSync(uri, srcPath);
      const size: number = fs.statSync(srcPath).size;
      let text: string = '';
      let entryCount: number = -1;
      if (ext === 'pdf') {
        text = await this.extractPdfText(srcPath, size);
        hilog.info(DOMAIN, TAG, 'readOfficeFile %{public}s pdf textLen=%{public}d', name, text.length);
      } else {
        // docx/pptx/zip：自研 ZIP 解析（decompressFile 只能输出单文件，无法解目录归档）
        // 含图片的 docx/pptx 体积大，放宽读取上限到 100MB（默认 20MB 会截断导致解析失败）
        const zbytes: Uint8Array | null = this.readAllBytes(srcPath, 100 * 1024 * 1024);
        if (zbytes === null) {
          text = '';
        } else {
          const entries: Array<ZipEntry> = await this.parseZipEntries(zbytes);
          entryCount = entries.length;
          hilog.info(DOMAIN, TAG, 'readOfficeFile %{public}s bytes=%{public}d entries=%{public}d', name, zbytes.length, entries.length);
          if (ext === 'docx') {
            for (let i = 0; i < entries.length; i++) {
              if (entries[i].name === 'word/document.xml') {
                text = this.extractDocxText(this.bytesToUtf8(entries[i].data));
                break;
              }
            }
          } else if (ext === 'pptx') {
            // pptx：收集 ppt/slides/slideN.xml 按序号排序后逐页拼接
            const slideNames: string[] = [];
            for (let i = 0; i < entries.length; i++) {
              if (entries[i].name.startsWith('ppt/slides/slide') && entries[i].name.endsWith('.xml')) {
                slideNames.push(entries[i].name);
              }
            }
            slideNames.sort((a: string, b: string): number => {
              const na: number = parseInt(a.replace(/[^0-9]/g, ''), 10);
              const nb: number = parseInt(b.replace(/[^0-9]/g, ''), 10);
              return na - nb;
            });
            const pages: string[] = [];
            for (let i = 0; i < slideNames.length; i++) {
              const slideName: string = slideNames[i];
              let slideXml: string = '';
              for (let j = 0; j < entries.length; j++) {
                if (entries[j].name === slideName) {
                  slideXml = this.extractPptxText(this.bytesToUtf8(entries[j].data));
                  break;
                }
              }
              if (slideXml.trim() !== '') {
                pages.push(`【第 ${i + 1} 页】\n${slideXml}`);
              }
            }
            text = pages.join('\n\n');
          } else if (ext === 'zip') {
            // 普通 zip 压缩包：提取内部可读文本（txt/md/xml/html 等）
            text = this.extractZipText(entries, MAX_TEXT_BYTES);
          }
        }
      }
      const clean: string = text.replace(/\s+/g, ' ').trim();
      const truncated: boolean = clean.length > MAX_TEXT_BYTES;
      const final: string = truncated ? clean.substring(0, MAX_TEXT_BYTES) : clean;
      if (final === '') {
        const detail: string = entryCount >= 0 ? `（归档条目 ${entryCount} 个，未能解出文本）` : '';
        return { ok: false, text: '', size: size, truncated: false, binary: false, error: `未能从文件中提取到文本内容${detail}` };
      }
      return { ok: true, text: final, size: size, truncated: truncated, binary: false, error: '' };
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'readOfficeFile %{public}s failed: %{public}s', name, JSON.stringify(err));
      return { ok: false, text: '', size: 0, truncated: false, binary: false, error: `解析失败（${err.message}）` };
    }
  }

  /** PDF：扫描全部 stream 块，尝试 FlateDecode 解压，再提取 Tj/TJ 文本 */
  private async extractPdfText(path: string, size: number): Promise<string> {
    const readLen: number = Math.min(size, 32 * 1024 * 1024);
    const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    const buf = new ArrayBuffer(readLen);
    let pos: number = 0;
    while (pos < readLen) {
      const n: number = fs.readSync(file.fd, buf, { offset: pos, length: readLen - pos });
      if (n <= 0) {
        break;
      }
      pos += n;
    }
    fs.closeSync(file);
    const bytes: Uint8Array = new Uint8Array(buf, 0, pos);
    // 字节 → latin1 字符串（无损承载 0-255 字节），便于定位 stream/endstream
    const chars: string[] = new Array<string>(bytes.length);
    for (let i = 0; i < bytes.length; i++) {
      chars[i] = String.fromCharCode(bytes[i]);
    }
    const latin: string = chars.join('');
    const texts: string[] = [];
    let cur: number = 0;
    while (true) {
      const sIdx: number = latin.indexOf('stream', cur);
      if (sIdx === -1) {
        break;
      }
      let dStart: number = sIdx + 6;
      if (latin.charAt(dStart) === '\r') {
        dStart++;
      }
      if (latin.charAt(dStart) === '\n') {
        dStart++;
      }
      const eIdx: number = latin.indexOf('endstream', dStart);
      if (eIdx === -1) {
        break;
      }
      cur = eIdx + 9;
      if (eIdx <= dStart) {
        continue;
      }
      const chunk: string = latin.substring(dStart, eIdx);
      const inflated: string | null = await this.tryInflateLatin(chunk);
      if (inflated !== null) {
        const t: string = this.extractPdfOps(inflated);
        if (t.trim() !== '') {
          texts.push(t);
        }
      }
    }
    return texts.join('\n');
  }

  /** 尝试把 PDF 流块解压：先按 zlib 格式（FlateDecode 规范 RFC1950），失败回退 raw deflate（RFC1951），均失败返回 null */
  private async tryInflateLatin(chunk: string): Promise<string | null> {
    try {
      const data: Uint8Array = new Uint8Array(chunk.length);
      for (let i = 0; i < chunk.length; i++) {
        data[i] = chunk.charCodeAt(i);
      }
      const src: ArrayBuffer = data.buffer.slice(data.byteOffset, data.byteOffset + data.length);
      const destSize: number = Math.min(Math.max(data.length * 30, 4096), 16 * 1024 * 1024);
      // 1) 标准 zlib 格式
      const dest: ArrayBuffer = new ArrayBuffer(destSize);
      const zip = zlib.createZipSync();
      const info: zlib.ZipOutputInfo = await zip.uncompress(dest, src, data.length);
      if (info.status === zlib.ReturnStatus.OK || info.status === zlib.ReturnStatus.STREAM_END) {
        const out: Uint8Array = new Uint8Array(dest, 0, Math.min(info.destLen, dest.byteLength));
        const decoder = util.TextDecoder.create('utf-8');
        return decoder.decodeToString(out);
      }
      // 2) 部分厂商输出 raw deflate（无 zlib 头），用 inflateInit2(-15) 兜底
      const zip2 = zlib.createZipSync();
      const strm: zlib.ZStream = await zip2.getZStream();
      const init: zlib.ReturnStatus = await zip2.inflateInit2(strm, -15);
      if (init !== zlib.ReturnStatus.OK) {
        return null;
      }
      strm.nextIn = src;
      strm.availableIn = data.length;
      strm.nextOut = dest;
      strm.availableOut = destSize;
      const st: zlib.ReturnStatus = await zip2.inflate(strm, zlib.CompressFlushMode.FINISH);
      await zip2.inflateEnd(strm);
      if (st === zlib.ReturnStatus.OK || st === zlib.ReturnStatus.STREAM_END) {
        let total: number = destSize - (strm.availableOut ?? 0);
        if ((strm.totalOut ?? 0) > total) {
          total = strm.totalOut as number;
        }
        if (total > 0) {
          const out: Uint8Array = new Uint8Array(dest, 0, Math.min(total, dest.byteLength));
          const decoder = util.TextDecoder.create('utf-8');
          return decoder.decodeToString(out);
        }
      }
    } catch (e) {
      return null;
    }
    return null;
  }

  /** 从解压后的 PDF 内容流提取文本操作符：(...) Tj、<hex> Tj 与混合 [...] TJ */
  private extractPdfOps(stream: string): string {
    const parts: string[] = [];
    // 1) 字符串操作符 (...) Tj
    let re: RegExp = /\(((?:[^()\\\r\n]|\\.)*)\)\s*Tj/g;
    let m: RegExpExecArray | null;
    while ((m = re.exec(stream)) !== null) {
      const v: string = this.decodePdfString(m[1]).trim();
      if (v !== '') {
        parts.push(v);
      }
    }
    // 2) 十六进制字符串操作符 <hex> Tj（CID 字体常见，普通文本经 hex 编码）
    re = /<([0-9A-Fa-f\s]+)>\s*Tj/g;
    while ((m = re.exec(stream)) !== null) {
      const v: string = this.decodeHexPdf(m[1]).trim();
      if (v !== '') {
        parts.push(v);
      }
    }
    // 3) 文本数组操作符 [...] TJ（可混含 (...) 与 <hex> 元素）
    re = /\[([\s\S]*?)\]\s*TJ/g;
    while ((m = re.exec(stream)) !== null) {
      const arr: string = m[1];
      const segs: string[] = [];
      const re2: RegExp = /(?:\(((?:[^()\\]|\\.)*)\)|<([0-9A-Fa-f\s]+)>)/g;
      let m2: RegExpExecArray | null;
      while ((m2 = re2.exec(arr)) !== null) {
        if (m2[1] !== undefined) {
          segs.push(this.decodePdfString(m2[1]));
        } else if (m2[2] !== undefined) {
          segs.push(this.decodeHexPdf(m2[2]));
        }
      }
      if (segs.length > 0) {
        parts.push(segs.join(''));
      }
    }
    return parts.join('\n');
  }

  /** 解码 PDF 十六进制字符串：普通字节直解；若高字节普遍为 0x00（UTF-16BE 特征）按 UTF-16BE 解码 */
  private decodeHexPdf(hex: string): string {
    const clean: string = hex.replace(/\s/g, '');
    if (clean.length < 2) {
      return '';
    }
    // UTF-16BE 检测：偶数边界取 2 字节单元，高字节为 0x00 占比 ≥60% 视为 UTF-16BE
    let utf16: boolean = true;
    const sample: number = Math.min(clean.length, 64);
    let zeroHigh: number = 0;
    let total: number = 0;
    for (let i = 0; i + 3 < sample; i += 4) {
      if (parseInt(clean.substring(i, i + 2), 16) === 0) {
        zeroHigh++;
      }
      total++;
    }
    if (total < 2 || zeroHigh < total * 0.6) {
      utf16 = false;
    }
    let out: string = '';
    if (utf16) {
      for (let i = 0; i + 3 < clean.length; i += 4) {
        const code: number = (parseInt(clean.substring(i, i + 2), 16) << 8) |
          parseInt(clean.substring(i + 2, i + 4), 16);
        if (code > 0) {
          out += String.fromCharCode(code);
        }
      }
    } else {
      for (let i = 0; i + 1 < clean.length; i += 2) {
        out += String.fromCharCode(parseInt(clean.substring(i, i + 2), 16));
      }
    }
    return out;
  }

  /** 解码 PDF 字符串转义：\n \r \t \( \) \\ \ddd（八进制） */
  private decodePdfString(s: string): string {
    let out: string = '';
    let i: number = 0;
    while (i < s.length) {
      const c: string = s.charAt(i);
      if (c !== '\\') {
        out += c;
        i++;
        continue;
      }
      const n: string = s.charAt(i + 1);
      if (n === 'n') {
        out += '\n';
        i += 2;
      } else if (n === 'r') {
        out += '\r';
        i += 2;
      } else if (n === 't') {
        out += '\t';
        i += 2;
      } else if (n === '(' || n === ')' || n === '\\') {
        out += n;
        i += 2;
      } else if (n >= '0' && n <= '7') {
        let num: string = n;
        let j: number = i + 2;
        while (j < s.length && j < i + 4 && s.charAt(j) >= '0' && s.charAt(j) <= '7') {
          num += s.charAt(j);
          j++;
        }
        out += String.fromCharCode(parseInt(num, 8));
        i = j;
      } else {
        out += n;
        i += 2;
      }
    }
    return out;
  }

  /** 读取文本文件内容（UTF-8，512KB 截断 + 二进制检测） */
  readFileText(uri: string): FileReadResult {
    try {
      const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      try {
        const stat = fs.statSync(uri);
        const size: number = stat.size;
        if (size <= 0) {
          return { ok: false, text: '', size: 0, truncated: false, binary: false, error: '文件为空' };
        }
        const readLen: number = Math.min(size, MAX_TEXT_BYTES);
        const buf = new ArrayBuffer(readLen);
        const bytes = new Uint8Array(buf);
        // 循环读取直至读满（大文件/网络盘可能单次读不满）
        let pos: number = 0;
        while (pos < readLen) {
          const n: number = fs.readSync(file.fd, buf, { offset: pos, length: readLen - pos });
          if (n <= 0) {
            break;
          }
          pos += n;
        }
        // 二进制检测前先判 UTF-16 BOM：带 BOM 的文本是正常文本文件，不能判为二进制
        let utf16le: boolean = false;
        let utf16be: boolean = false;
        if (bytes.length >= 2) {
          if (bytes[0] === 0xFF && bytes[1] === 0xFE) {
            utf16le = true;
          } else if (bytes[0] === 0xFE && bytes[1] === 0xFF) {
            utf16be = true;
          }
        }
        if (!utf16le && !utf16be) {
          const probeLen: number = Math.min(512, bytes.length);
          let binary: boolean = false;
          for (let i = 0; i < probeLen; i++) {
            if (bytes[i] === 0) {
              binary = true;
              break;
            }
          }
          if (binary) {
            return { ok: false, text: '', size: size, truncated: false, binary: true, error: '二进制文件（仅支持文本文件）' };
          }
        }
        let text: string;
        if (utf16le || utf16be) {
          text = this.decodeUtf16(bytes, utf16le);
        } else {
          const decoder = util.TextDecoder.create('utf-8');
          text = decoder.decodeToString(bytes);
        }
        return {
          ok: text.trim() !== '',
          text: text,
          size: size,
          truncated: size > readLen,
          binary: false,
          error: ''
        };
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'readFileText %{public}s failed: %{public}s', uri, JSON.stringify(err));
      return { ok: false, text: '', size: 0, truncated: false, binary: false, error: '读取失败（' + err.message + '）' };
    }
  }

  /** 手动解码 UTF-16（依据 BOM 大小端）：避免依赖 TextDecoder 的编码支持范围 */
  private decodeUtf16(bytes: Uint8Array, littleEndian: boolean): string {
    let out: string = '';
    if (bytes.length < 2) {
      return out;
    }
    // 跳过 2 字节 BOM；末尾奇数个字节丢弃
    const end: number = bytes.length - 1 - ((bytes.length - 2) % 2);
    const units: string[] = [];
    for (let i = 2; i < end; i += 2) {
      const lo: number = bytes[i];
      const hi: number = bytes[i + 1];
      const u: number = littleEndian ? (lo | (hi << 8)) : ((lo << 8) | hi);
      units.push(String.fromCharCode(u));
    }
    out = units.join('');
    return out;
  }

  /** 从 uri 提取文件名 */
  static fileNameFromUri(uri: string): string {
    let u: string = uri;
    if (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    const slash: number = u.lastIndexOf('/');
    let name: string = slash === -1 ? u : u.substring(slash + 1);
    name = name.split('?')[0];
    return name;
  }

  /** 卸载模型 */
  unloadModel(): void {
    const ret: number = this.currentEngine === 'llama' ? llNativeUnload() : nativeUnload();
    this.isLoaded = false;
    this.isGenerating = false;
    hilog.info(DOMAIN, TAG, 'unload model result: %{public}d', ret);
  }

  /**
   * 列出沙箱 models/ 目录下已导入的模型（目录需包含 config.json）
   */
  /** 沙箱模型根目录（models/） */
  getModelsDir(): string {
    return `${this.filesDir}/models`;
  }

  listModels(): ModelInfo[] {
    const result: ModelInfo[] = [];
    try {
      const modelsRoot: string = `${this.filesDir}/models`;
      if (!fs.accessSync(modelsRoot)) {
        return result;
      }
      const names: string[] = fs.listFileSync(modelsRoot);
      for (let i = 0; i < names.length; i++) {
        const dir: string = `${modelsRoot}/${names[i]}`;
        try {
          const stat = fs.statSync(dir);
          if (!stat.isDirectory()) {
            // 根目录下的孤立文件：历史版本直接复制模型文件到根目录的脏数据，
            // 非合法模型，清理避免与后续同名目录冲突（mkdir EEXIST）
            fs.unlinkSync(dir);
            hilog.warn(DOMAIN, TAG, 'clean orphan file in models root: %{public}s', dir);
            continue;
          }
          // 目录内存在 config.json（MNN）或 .gguf 模型文件（llama）即视为可加载模型
          if (!fs.accessSync(`${dir}/config.json`) && this.findGgufFile(dir) === '') {
            continue;
          }
          // 目录内存在 .tmp 残留 → 下载未完成，标记 downloading（UI 据此显示"下载中"，禁止加载）
          result.push({
            name: names[i],
            dir: dir,
            sizeMB: this.calcDirSizeMB(dir),
            downloading: this.hasTmpFile(dir)
          });
        } catch (e) {
          // 跳过无法访问的目录
        }
      }
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'listModels failed: %{public}s', JSON.stringify(err));
    }
    return result;
  }

  /** 计算目录总大小（MB，一位小数） */
  private calcDirSizeMB(dir: string): number {
    let total: number = 0;
    try {
      const files: string[] = fs.listFileSync(dir);
      for (let i = 0; i < files.length; i++) {
        try {
          const stat = fs.statSync(`${dir}/${files[i]}`);
          if (stat.isFile()) {
            total += stat.size;
          }
        } catch (e) {
          // 忽略单个文件统计失败
        }
      }
    } catch (e) {
      // 目录读取失败
    }
    return Math.round(total / 1024 / 1024 * 10) / 10;
  }

  /**
   * 导入模型文件到沙箱 models/ 目录
   * @param uris 用户通过文件选择器选中的文件 uri 列表
   * @param targetName 目标目录名（不含 models/ 前缀）
   * @returns Promise<boolean> 是否成功
   */
  importFiles(uris: string[], targetName: string): Promise<boolean> {
    const targetDir: string = `${this.filesDir}/models/${targetName}`;
    return new Promise<boolean>((resolve) => {
      if (!this.ensureModelDir(targetDir)) {
        resolve(false);
        return;
      }
      let index: number = 0;
      let anyFailed: boolean = false;
      const next = (): void => {
        if (index >= uris.length) {
          hilog.info(DOMAIN, TAG, 'import finished, target=%{public}s, anyFailed=%{public}s',
            targetDir, String(anyFailed));
          resolve(!anyFailed);
          return;
        }
        const uri: string = uris[index];
        index++;
        // 从 uri 提取文件名（去掉路径与查询串）
        const rawName: string = uri.substring(uri.lastIndexOf('/') + 1);
        const fileName: string = rawName.split('?')[0];
        // 解码 URI 百分号编码（文件名含空格/中文时 URI 会编码成 %20 / %XX），
        // 否则落盘文件名会保留 %20，导致后续模型名/加载路径不一致
        let realName: string = fileName;
        try {
          realName = decodeURIComponent(fileName);
        } catch (e) {
          // 解码失败保留原名
        }
        const dest: string = `${targetDir}/${realName}`;
        this.copyFromUri(uri, dest).then((ok: boolean) => {
          if (ok) {
            hilog.info(DOMAIN, TAG, 'imported %{public}s -> %{public}s', fileName, dest);
          } else {
            anyFailed = true;
            hilog.error(DOMAIN, TAG, 'import %{public}s failed', fileName);
          }
          next();
        });
      };
      next();
    });
  }

  /**
   * 从文件选择器 uri 复制到沙箱目标路径。
   * 直接 open 源 uri 拿 fd 分块流式复制，对跨应用/大文件比 fs.copyFile 更可靠
   * （fs.copyFile 对 picker uri 可能报 13900002 No such file or directory）。
   */
  private copyFromUri(srcUri: string, dest: string): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      try {
        const srcFile: fs.File = fs.openSync(srcUri, fs.OpenMode.READ_ONLY);
        const destFile: fs.File = fs.openSync(dest, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
        const buf: ArrayBuffer = new ArrayBuffer(1024 * 1024);
        let bytesRead: number = -1;
        while (bytesRead !== 0) {
          bytesRead = fs.readSync(srcFile.fd, buf);
          if (bytesRead > 0) {
            fs.writeSync(destFile.fd, buf, { length: bytesRead });
          }
        }
        fs.closeSync(srcFile.fd);
        fs.closeSync(destFile.fd);
        resolve(true);
      } catch (e) {
        const err = e as BusinessError;
        hilog.error(DOMAIN, TAG, 'copyFromUri failed: %{public}s', JSON.stringify(err));
        resolve(false);
      }
    });
  }

  /**
   * 从文件 uri 推导其所在目录名（作为导入模型的目录名）
   * 如 file://docs/storage/.../Qwen3-0.6B/llm.mnn -> Qwen3-0.6B
   */
  static parentDirName(uri: string): string {
    let u: string = uri;
    if (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    const slash: number = u.lastIndexOf('/');
    if (slash === -1) {
      return '';
    }
    let dir: string = u.substring(0, slash);
    const s2: number = dir.lastIndexOf('/');
    if (s2 !== -1) {
      dir = dir.substring(s2 + 1);
    }
    return dir.split('?')[0];
  }

  /**
   * 从 ModelScope 下载模型到沙箱 models/{name}/
   * 文件清单通过 repo/files API 动态枚举（适配不同模型的差异文件结构），
   * 枚举失败时回退到固定清单 MODEL_FILES。
   * @param model 市场模型条目
   * @param onProgress 进度回调（已完成文件数, 总文件数）
   * @returns Promise<number> 0 成功 / -1 失败
   */
  downloadModel(model: MarketModel, onProgress: (received: number, total: number) => void): Promise<number> {
    const targetDir: string = `${this.filesDir}/models/${model.name}`;
    return new Promise<number>((resolve) => {
      if (!this.ensureModelDir(targetDir)) {
        resolve(-1);
        return;
      }
      // 新一次下载前复位取消标志
      this.downloadCancelRequested = false;
      // 先动态枚举文件列表（带 API 真实 Size），失败回退固定清单（大小走 fetchSizes）
      this.listRepoFiles(model.repo).then((files: RepoFile[]) => {
        let list: RepoFile[] = files.length > 0 ? files.slice() : MODEL_FILES.map((f: string): RepoFile => ({ name: f, size: -1 }));
        // 纯文本模式：跳过 visual.* 视觉文件（Qwen3.5 等多模态模型）
        if (model.skipVisual) {
          list = list.filter((f: RepoFile) => !f.name.toLowerCase().startsWith('visual'));
        }
        // GGUF 模型：只下载一个量化档（优先 Q4_K_M，其次任意 Q4，最后第一个 .gguf），
        // 分片模型（xxx-q4_k_m-00001-of-00002）会把同量化档的全部分片一并下载，缺一不可
        if (model.format === 'gguf') {
          const ggufs: RepoFile[] = [];
          for (let i = 0; i < list.length; i++) {
            if (list[i].name.toLowerCase().endsWith('.gguf')) {
              ggufs.push(list[i]);
            }
          }
          if (ggufs.length > 0) {
            let km: number = -1;
            let q4: number = -1;
            for (let i = 0; i < ggufs.length; i++) {
              const low: string = ggufs[i].name.toLowerCase();
              if (km === -1 && low.indexOf('q4_k_m') !== -1) {
                km = i;
              }
              if (q4 === -1 && low.indexOf('q4') !== -1) {
                q4 = i;
              }
            }
            const chosen: RepoFile = km !== -1 ? ggufs[km] : (q4 !== -1 ? ggufs[q4] : ggufs[0]);
            list = [chosen];
            // 分片检测：文件形如 "xxx-q4_k_m-00001-of-00002.gguf"，补齐其余分片
            const sep: number = chosen.name.indexOf('-0000');
            if (sep !== -1) {
              const base: string = chosen.name.substring(0, sep);
              for (let i = 0; i < ggufs.length; i++) {
                if (ggufs[i] !== chosen && ggufs[i].name.startsWith(base + '-0000')) {
                  list.push(ggufs[i]);
                }
              }
            }
          }
        }
        // 预取各文件大小：优先用 API 的 Size 字段（repo/files 已返回真实字节数），
        // API 缺失（-1）的文件回退 HEAD 探测；汇总总字节数用于进度百分比
        this.fetchSizes(list, model).then((sizes: number[]) => {
          let total: number = 0;
          for (let i = 0; i < sizes.length; i++) {
            if (sizes[i] > 0) {
              total += sizes[i];
            }
          }
          this.downloadFiles(model, list, sizes, targetDir, 0, 0, total, onProgress, resolve);
        });
      });
    });
  }

  /** 取消进行中的模型下载（中断当前文件并清理临时文件） */
  cancelDownload(): void {
    this.downloadCancelRequested = true;
    hilog.info(DOMAIN, TAG, 'cancelDownload requested');
  }

  /** 批量获取文件大小：优先用 repo/files API 的 Size 字段（已含真实字节数），缺失的走 HEAD 探测（失败 -1） */
  private fetchSizes(files: RepoFile[], model: MarketModel): Promise<number[]> {
    const sizes: number[] = new Array<number>(files.length).fill(-1);
    // 第一遍：直接用 API Size
    let unknown: number[] = [];
    for (let i = 0; i < files.length; i++) {
      if (files[i].size > 0) {
        sizes[i] = files[i].size;
      } else {
        unknown.push(i);
      }
    }
    if (unknown.length === 0) {
      return Promise.resolve(sizes);
    }
    // 第二遍：仅对未知大小的文件发 HEAD 请求补探测
    return new Promise<number[]>((resolve) => {
      let pending: number = unknown.length;
      for (let k = 0; k < unknown.length; k++) {
        const i: number = unknown[k];
        const url: string = `${MODELSCOPE_DL}${model.repo}/resolve/master/${files[i].name}`;
        const req = http.createHttp();
        req.request(url, { method: http.RequestMethod.HEAD }).then((resp: http.HttpResponse) => {
          const h = resp.header as Record<string, string>;
          const cl: number = Number(h['content-length'] ?? h['Content-Length'] ?? 0);
          if (cl > 0) {
            sizes[i] = cl;
          }
          req.destroy();
          pending--;
          if (pending === 0) {
            resolve(sizes);
          }
        }).catch(() => {
          req.destroy();
          pending--;
          if (pending === 0) {
            resolve(sizes);
          }
        });
      }
    });
  }

  /** 顺序下载文件列表，核心文件缺失立即失败，可选文件缺失跳过；已存在文件跳过（断点续传） */
  private downloadFiles(model: MarketModel, files: RepoFile[], sizes: number[], targetDir: string, index: number,
    accReceived: number, totalBytes: number,
    onProgress: (received: number, total: number) => void, resolve: (v: number) => void): void {
    if (index >= files.length) {
      // 完整性校验：核心文件必须存在且 >0；已知大小（API Size / content-length）时还要逐字节一致
      for (let i = 0; i < files.length; i++) {
        if (this.isCoreFile(files[i].name)) {
          const actual: number = this.fileSize(`${targetDir}/${files[i].name}`);
          if (actual <= 0 || (sizes[i] > 0 && actual !== sizes[i])) {
            hilog.error(DOMAIN, TAG, 'core file invalid %{public}s expected=%{public}d actual=%{public}d',
              files[i].name, sizes[i], actual);
            // 清理不完整的核心文件与其 .tmp，避免加载时崩溃
            try {
              if (fs.accessSync(`${targetDir}/${files[i].name}.tmp`)) {
                fs.unlinkSync(`${targetDir}/${files[i].name}.tmp`);
              }
              if (fs.accessSync(`${targetDir}/${files[i].name}`)) {
                fs.unlinkSync(`${targetDir}/${files[i].name}`);
              }
            } catch (e) {}
            resolve(-1);
            return;
          }
        }
      }
      // 清理遗留 .tmp 残留
      try {
        const names: string[] = fs.listFileSync(targetDir);
        for (let i = 0; i < names.length; i++) {
          if (names[i].endsWith('.tmp')) {
            fs.unlinkSync(`${targetDir}/${names[i]}`);
          }
        }
      } catch (e) {}
      hilog.info(DOMAIN, TAG, 'download finished, target=%{public}s', targetDir);
      onProgress(accReceived, totalBytes);
      resolve(0);
      return;
    }
    if (this.downloadCancelRequested) {
      hilog.warn(DOMAIN, TAG, 'download canceled by user');
      resolve(-1);
      return;
    }
    const fileName: string = files[index].name;
    const dest: string = `${targetDir}/${fileName}`;
    // 断点续传：目标文件已完整存在（>0 字节）则跳过
    const existing: number = this.fileSize(dest);
    if (existing > 0) {
      onProgress(accReceived + existing, totalBytes);
      this.downloadFiles(model, files, sizes, targetDir, index + 1, accReceived + existing,
        totalBytes, onProgress, resolve);
      return;
    }
    const url: string = `${MODELSCOPE_DL}${model.repo}/resolve/master/${fileName}`;
    this.downloadFile(url, dest, (received: number, curTotal: number) => {
      // 总字节优先用预取值；预取失败时退回当前文件 content-length
      const t: number = totalBytes > 0 ? totalBytes : curTotal;
      onProgress(accReceived + received, t);
    }).then((ok: boolean) => {
      if (ok) {
        const size: number = this.fileSize(dest);
        onProgress(accReceived + size, totalBytes);
        this.downloadFiles(model, files, sizes, targetDir, index + 1, accReceived + size,
          totalBytes, onProgress, resolve);
      } else if (this.isCoreFile(fileName)) {
        // 核心文件缺失则整体失败
        resolve(-1);
      } else {
        // 其余可选文件缺失时跳过
        this.downloadFiles(model, files, sizes, targetDir, index + 1, accReceived,
          totalBytes, onProgress, resolve);
      }
    });
  }

  /** 文件大小（不存在返回 -1） */
  /** 目录内是否存在 .tmp 残留（下载未完成的标志） */
  private hasTmpFile(dir: string): boolean {
    try {
      const names: string[] = fs.listFileSync(dir);
      for (let i = 0; i < names.length; i++) {
        if (names[i].endsWith('.tmp')) {
          return true;
        }
      }
    } catch (e) {}
    return false;
  }

  private fileSize(path: string): number {
    try {
      const st: fs.Stat = fs.statSync(path);
      return st.size;
    } catch (e) {
      return -1;
    }
  }

  /** 确保模型目录存在：同名文件（历史脏数据）先删除再建目录，避免 mkdir 报 EEXIST */
  private ensureModelDir(dir: string): boolean {
    try {
      if (fs.accessSync(dir)) {
        const st = fs.statSync(dir);
        if (st.isDirectory()) {
          return true;
        }
        hilog.warn(DOMAIN, TAG, 'model dir conflict (file), remove: %{public}s', dir);
        fs.unlinkSync(dir);
      }
    } catch (e) {
      // 路径不存在，走下方 mkdir
    }
    try {
      fs.mkdirSync(dir, true);
      return true;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'mkdir %{public}s failed: %{public}s', dir, JSON.stringify(err));
      return false;
    }
  }

  /** 核心文件判断：缺失即视为模型不完整 */
  private isCoreFile(name: string): boolean {
    if (name.toLowerCase().endsWith('.gguf')) {
      return true;
    }
    return name === 'config.json' || name === 'llm_config.json' || name === 'configuration.json' ||
      name.startsWith('tokenizer') || name === 'llm.mnn' || name === 'llm.mnn.weight' ||
      name.startsWith('embeddings');
  }

  /**
   * 动态枚举 ModelScope 仓库文件列表（repo/files API）
   * @param repo 仓库路径，如 MNN/Qwen3.5-0.8B-MNN
   * @returns Promise<RepoFile[]> 文件列表（已过滤非模型文件，带 API 返回的真实字节大小）；失败返回空数组
   */
  private listRepoFiles(repo: string): Promise<RepoFile[]> {
    return new Promise<RepoFile[]>((resolve) => {
      const req = http.createHttp();
      req.request(`https://modelscope.cn/api/v1/models/${repo}/repo/files?Revision=master&Recursive=true`, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING
      }).then((resp: http.HttpResponse) => {
        req.destroy();
        if (resp.responseCode !== 200) {
          resolve([]);
          return;
        }
        const body: string = resp.result as string;
        const obj: Record<string, Object> = JSON.parse(body) as Record<string, Object>;
        const data: Record<string, Object> = obj['Data'] as Record<string, Object>;
        const arr: Array<Record<string, Object>> = data['Files'] as Array<Record<string, Object>>;
        if (arr === undefined) {
          resolve([]);
          return;
        }
        const names: RepoFile[] = [];
        for (let i = 0; i < arr.length; i++) {
          const name: string = arr[i]['Name'] as string;
          if (this.isModelFile(name)) {
            const sz: number = Number(arr[i]['Size'] ?? 0);
            names.push({ name: name, size: sz > 0 ? sz : -1 });
          }
        }
        hilog.info(DOMAIN, TAG, 'listRepoFiles(%{public}s) found %{public}d files', repo, names.length);
        resolve(names);
      }).catch((e: BusinessError) => {
        req.destroy();
        hilog.warn(DOMAIN, TAG, 'listRepoFiles(%{public}s) failed: %{public}s', repo, JSON.stringify(e));
        resolve([]);
      });
    });
  }

  /** 过滤非模型文件（文档/图片/配置文件说明等） */
  private isModelFile(name: string): boolean {
    const lower: string = name.toLowerCase();
    if (lower.startsWith('readme') || lower.startsWith('license') ||
      lower === '.gitattributes' || lower === '.gitignore' ||
      lower.endsWith('.md') || lower.endsWith('.png') || lower.endsWith('.jpg') ||
      lower.endsWith('.jpeg') || lower.endsWith('.gif') || lower.endsWith('.svg') ||
      lower.endsWith('.py') || lower.endsWith('.pyc') || lower.endsWith('.gitkeep')) {
      return false;
    }
    return true;
  }

  /**
   * 流式下载单个文件（带 30s 无数据超时守卫：网络中断/挂起时及时失败，
   * 避免按钮永久卡在下载中）。
   * 先下载到 dest + '.tmp'（已存在则 Range 续传），成功后原子重命名为 dest。
   * @param url 下载地址
   * @param dest 目标路径
   */
  private downloadFile(url: string, dest: string, onBytes?: (received: number, total: number) => void): Promise<boolean> {
    return this.downloadFileOnce(url, dest, MAX_DL_RETRY, onBytes);
  }

  /** 剩余尝试次数 > 1 时自动重试（临时文件已保留，配合 Range 断点续传），否则判定失败 */
  private retryOrFail(url: string, dest: string, attempts: number, onBytes?: (received: number, total: number) => void): Promise<boolean> {
    if (attempts > 1) {
      hilog.warn(DOMAIN, TAG, 'download retry (left=%{public}d): %{public}s', attempts - 1, dest);
      return this.downloadFileOnce(url, dest, attempts - 1, onBytes);
    }
    return Promise.resolve(false);
  }

  /** 单次下载尝试：失败（90s 无数据超时 / 网络错误）时自动重试并断点续传 */
  private downloadFileOnce(url: string, dest: string, attempts: number, onBytes?: (received: number, total: number) => void): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      const tmp: string = `${dest}.tmp`;
      const start: number = this.fileSize(tmp) > 0 ? this.fileSize(tmp) : 0;
      const req = http.createHttp();
      let file: fs.File | undefined = undefined;
      let finished: boolean = false;
      // 远端文件总大小（-1 表示未知，收到响应头后更新）
      let curTotal: number = -1;
      // 已接收字节数（含断点续传起点）
      let received: number = start;
      // 90 秒无数据视为网络挂起：保留临时文件并自动重试（断点续传）
      let idleTimer: number = -1;
      const resetIdleTimer = (): void => {
        if (idleTimer !== -1) {
          clearTimeout(idleTimer);
        }
        idleTimer = setTimeout(() => {
          if (!finished) {
            hilog.warn(DOMAIN, TAG, 'download timeout(90s no data): %{public}s', dest);
            finished = true;
            try {
              if (file !== undefined) {
                fs.closeSync(file);
              }
            } catch (e2) {
              // 忽略关闭异常
            }
            req.destroy();
            resolve(this.retryOrFail(url, dest, attempts, onBytes));
          }
        }, 90000);
      };
      const cleanup = (): void => {
        if (idleTimer !== -1) {
          clearTimeout(idleTimer);
          idleTimer = -1;
        }
      };
      try {
        const headers: Record<string, string> = {};
        if (start > 0) {
          headers['Range'] = `bytes=${start}-`;
        }
        req.requestInStream(url, {
          method: http.RequestMethod.GET,
          expectDataType: http.HttpDataType.ARRAY_BUFFER,
          header: headers
        }, (err: BusinessError) => {
          if (err && !finished) {
            hilog.warn(DOMAIN, TAG, 'download %{public}s failed: %{public}s', url, JSON.stringify(err));
            finished = true;
            cleanup();
            if (file !== undefined) {
              try {
                fs.closeSync(file);
              } catch (e2) {
                // 忽略关闭异常
              }
            }
            req.destroy();
            resolve(this.retryOrFail(url, dest, attempts, onBytes));
          }
        });
        if (start > 0) {
          file = fs.openSync(tmp, fs.OpenMode.READ_WRITE | fs.OpenMode.APPEND);
        } else {
          file = fs.openSync(tmp, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        }
        resetIdleTimer();
        // 解析响应头 content-length，用于字节级进度
        req.on('headersReceive', (header: Object) => {
          const h = header as Record<string, string>;
          const cl: number = Number(h['content-length'] ?? h['Content-Length'] ?? 0);
          if (cl > 0) {
            curTotal = cl;
          }
          if (onBytes !== undefined) {
            onBytes(received, curTotal);
          }
        });
        req.on('dataReceive', (data: ArrayBuffer) => {
          if (finished || file === undefined) {
            return;
          }
          // 用户取消：中断下载并清理临时文件
          if (this.downloadCancelRequested) {
            finished = true;
            cleanup();
            try {
              fs.closeSync(file);
            } catch (e2) {
              // 忽略关闭异常
            }
            try {
              if (fs.accessSync(tmp)) {
                fs.unlinkSync(tmp);
              }
            } catch (e3) {
              // 忽略清理异常
            }
            req.destroy();
            hilog.warn(DOMAIN, TAG, 'download canceled: %{public}s', dest);
            resolve(false);
            return;
          }
          resetIdleTimer();
          received += data.byteLength;
          if (onBytes !== undefined) {
            onBytes(received, curTotal);
          }
          const arr = new Uint8Array(data);
          fs.writeSync(file.fd, arr.buffer as ArrayBuffer);
        });
        req.on('dataEnd', () => {
          if (finished) {
            return;
          }
          finished = true;
          cleanup();
          if (file !== undefined) {
            try {
              fs.closeSync(file);
            } catch (e2) {
              // 忽略关闭异常
            }
          }
          req.destroy();
          // 原子重命名 tmp -> dest
          try {
            if (fs.accessSync(dest)) {
              fs.unlinkSync(dest);
            }
            fs.renameSync(tmp, dest);
            resolve(true);
          } catch (e3) {
            const err = e3 as BusinessError;
            hilog.error(DOMAIN, TAG, 'rename %{public}s failed: %{public}s', tmp, JSON.stringify(err));
            resolve(false);
          }
        });
      } catch (e) {
        const err = e as BusinessError;
        hilog.error(DOMAIN, TAG, 'download %{public}s failed: %{public}s', dest, JSON.stringify(err));
        finished = true;
        cleanup();
        if (file !== undefined) {
          try {
            fs.closeSync(file);
          } catch (e2) {
            // 忽略关闭异常
          }
        }
        req.destroy();
        resolve(this.retryOrFail(url, dest, attempts, onBytes));
      }
    });
  }
}
