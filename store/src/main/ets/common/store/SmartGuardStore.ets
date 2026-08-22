/**
 * SmartGuardStore — 智能管家数据持久化
 * 保存：每小时流量采样（预言家）、夜间事件日志（值班员）、周健康汇总（周报）
 * 按设备隔离，Preferences 存储
 */
import { preferences } from '@kit.ArkData'
import { hilog } from '@kit.PerformanceAnalysisKit'

const STORE_NAME = 'iStore_smartguard'
const KEY_PREFIX = 'sg_'
const DOMAIN = 0x0001
const TAG = 'SmartGuardStore'

/** 每小时采样点 */
export interface HourSample {
  hour: number        // 0-23
  rx: number          // 该小时接收字节
  tx: number          // 该小时发送字节
  devices: number     // 在线设备数
}

/** 夜间事件 */
export interface NightEvent {
  time: string        // HH:mm
  type: string        // new_device / big_traffic / offline / attack
  text: string        // 描述
}

/** 日汇总（周报用） */
export interface DaySummary {
  date: string        // MM-dd
  rx: number
  tx: number
  maxDevices: number
  peakHour: number
  anomalyCount: number
}

export class SmartGuardStore {
  private static instance: SmartGuardStore
  private prefs: preferences.Preferences | null = null
  private deviceId: string = ''

  static getInstance(): SmartGuardStore {
    if (!SmartGuardStore.instance) {
      SmartGuardStore.instance = new SmartGuardStore()
    }
    return SmartGuardStore.instance
  }

  async init(context: Context): Promise<void> {
    if (this.prefs) return
    try {
      this.prefs = await preferences.getPreferences(context, STORE_NAME)
    } catch (e) {
      hilog.error(DOMAIN, TAG, `init err: ${JSON.stringify(e)}`)
    }
  }

  setDevice(id: string): void {
    this.deviceId = id
  }

  private key(name: string): string {
    return `${KEY_PREFIX}${name}_${this.deviceId}`
  }

  private async putJson(name: string, value: Object): Promise<void> {
    if (!this.prefs || !this.deviceId) return
    try {
      await this.prefs.put(this.key(name), JSON.stringify(value))
      await this.prefs.flush()
    } catch (e) {
      hilog.error(DOMAIN, TAG, `putJson ${name} err: ${JSON.stringify(e)}`)
    }
  }

  private async getJson<T>(name: string, def: T): Promise<T> {
    if (!this.prefs || !this.deviceId) return def
    try {
      const raw: preferences.ValueType = this.prefs.getSync(this.key(name), '')
      if (typeof raw === 'string' && raw) {
        return JSON.parse(raw) as T
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, `getJson ${name} err: ${JSON.stringify(e)}`)
    }
    return def
  }

  // ========== 采样（预言家） ==========
  /** 追加一条小时采样（保留最近 7×24=168 条） */
  async addSample(s: HourSample): Promise<void> {
    const list: HourSample[] = await this.getJson<HourSample[]>('samples', [])
    list.push(s)
    while (list.length > 168) {
      list.shift()
    }
    await this.putJson('samples', list)
  }

  async getSamples(): Promise<HourSample[]> {
    return this.getJson<HourSample[]>('samples', [])
  }

  // ========== 夜间事件（值班员） ==========
  async saveNightEvents(events: NightEvent[]): Promise<void> {
    await this.putJson('nightEvents', events)
  }

  async getNightEvents(): Promise<NightEvent[]> {
    return this.getJson<NightEvent[]>('nightEvents', [])
  }

  async saveLastNightDate(date: string): Promise<void> {
    await this.putJson('lastNightDate', date)
  }

  async getLastNightDate(): Promise<string> {
    return this.getJson<string>('lastNightDate', '')
  }

  // ========== 日汇总（周报） ==========
  async addDaySummary(s: DaySummary): Promise<void> {
    const list: DaySummary[] = await this.getJson<DaySummary[]>('days', [])
    // 同一天覆盖
    const idx: number = list.findIndex((d: DaySummary) => d.date === s.date)
    if (idx >= 0) {
      list[idx] = s
    } else {
      list.push(s)
    }
    while (list.length > 30) {
      list.shift()
    }
    await this.putJson('days', list)
  }

  async getDaySummaries(): Promise<DaySummary[]> {
    return this.getJson<DaySummary[]>('days', [])
  }
}
