/**
 * ApiUtils - 路由器 API 解析工具（静态方法集）
 * 从 ApiClient 拆出，供 ApiClient 及上层解析使用
 */

/** 安全读取字符串字段 */
export class ApiUtils {
  /** 安全读取字符串字段 */
  static strOf(obj: Object, key: string): string {
    if (!obj || typeof obj !== 'object') {
      return ''
    }
    const v = (obj as Record<string, Object>)[key]
    if (v === undefined || v === null) {
      return ''
    }
    return String(v)
  }

  /** 安全读取数值字段 */
  static numOf(obj: Object, key: string, def: number): number {
    if (!obj || typeof obj !== 'object') {
      return def
    }
    const v = (obj as Record<string, Object>)[key]
    if (v === undefined || v === null) {
      return def
    }
    const n: number = Number(v)
    return isNaN(n) ? def : n
  }

  /** 解析百分比字符串（如 "55%" → 55） */
  static percentOf(obj: Object, key: string): number {
    const raw: string = ApiUtils.strOf(obj, key).replace('%', '').trim()
    const n: number = parseFloat(raw)
    return isNaN(n) ? 0 : n
  }

  /** 解析带单位的容量字符串为 KB（如 "2169m" → 2221056，"512k" → 512） */
  static parseSizeToKb(raw: string): number {
    if (!raw) {
      return 0
    }
    const s: string = raw.trim().toLowerCase()
    const n: number = parseFloat(s)
    if (isNaN(n)) {
      return 0
    }
    if (s.endsWith('g')) {
      return Math.floor(n * 1024 * 1024)
    }
    if (s.endsWith('m')) {
      return Math.floor(n * 1024)
    }
    return Math.floor(n)
  }

  /** 返回指定 key 之后的 token 值（用于解析 ip route 输出） */
  static tokenAfter(toks: string[], key: string): string {
    for (let i = 0; i < toks.length - 1; i++) {
      if (toks[i] === key) {
        return toks[i + 1]
      }
    }
    return ''
  }

  /** 解析 /proc/stat 首行，返回 [总时间, 空闲+iowait] */
  static parseProcStatCpu(text: string): number[] {
    const firstNl: number = text.indexOf('\n')
    const line: string = (firstNl > 0 ? text.substring(0, firstNl) : text).trim()
    if (!line.startsWith('cpu')) {
      return []
    }
    const toks: string[] = line.split(/\s+/).slice(1)
    if (toks.length < 5) {
      return []
    }
    let total: number = 0
    for (let i = 0; i < toks.length; i++) {
      total += parseInt(toks[i]) || 0
    }
    const idle: number = (parseInt(toks[3]) || 0) + (parseInt(toks[4]) || 0)
    return [total, idle]
  }

  /** 提取 dockerman 表格行内指定字段的隐藏 input 值（含 HTML 反转义） */
  static dockerField(rowHtml: string, field: string): string {
    const re: RegExp = new RegExp(`data-name="${field}"[\\s\\S]{0,600}?value="([^"]*)"`)
    const m = rowHtml.match(re)
    if (!m || m.length < 2) {
      return ''
    }
    return ApiUtils.unescapeHtml(m[1])
  }

  /** HTML 反转义（数字实体 + 常见命名实体） */
  static unescapeHtml(s: string): string {
    if (!s) {
      return ''
    }
    return s
      .replace(/&#(\d+);/g, (_m: string, code: string): string => String.fromCharCode(parseInt(code)))
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"')
      .replace(/&#x27;/g, "'")
      .replace(/&amp;/g, '&')
  }

  /** 去除 HTML 标签 */
  static stripTags(s: string): string {
    if (!s) {
      return ''
    }
    return s.replace(/<[^>]+>/g, ' ')
  }

  /** 延迟等待 */
  static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(() => {
        resolve()
      }, ms)
    })
  }
}
