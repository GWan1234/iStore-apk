/**
 * NotifyStore - 智能通知设置存储（单例）
 * 保存：总开关、断网告警开关、新设备提醒开关、AI 健康告警开关
 * 以及检测状态：上次在线状态、已知设备 MAC 集合、AI 告警去重记录
 */
import { preferences } from '@kit.ArkData'
import { hilog } from '@kit.PerformanceAnalysisKit'

const TAG = 'NotifyStore'
const DOMAIN = 0x0001
const STORE_NAME = 'iStore_notify'

export class NotifyStore {
  private static instance: NotifyStore
  private prefs: preferences.Preferences | null = null
  private cache: Map<string, string> = new Map()  // key -> value（字符串缓存）

  static getInstance(): NotifyStore {
    if (!NotifyStore.instance) {
      NotifyStore.instance = new NotifyStore()
    }
    return NotifyStore.instance
  }

  async init(context: Context): Promise<void> {
    if (this.prefs) return
    try {
      this.prefs = await preferences.getPreferences(context, STORE_NAME)
      // 预热缓存
      const keys: string[] = ['enabled', 'offlineAlert', 'newDeviceAlert', 'aiHealthAlert', 'lastOnline', 'lastMacs', 'lastCheckedDate', 'lastAiAlerts']
      for (let i = 0; i < keys.length; i++) {
        this.cache.set(keys[i], this.prefs.getSync(keys[i], '') as string)
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, `Init failed: ${JSON.stringify(e)}`)
    }
  }

  private getStr(key: string, def: string): string {
    const v: string | undefined = this.cache.get(key)
    if (v !== undefined) return v
    return def
  }

  private setStr(key: string, value: string): void {
    this.cache.set(key, value)
    if (this.prefs) {
      try {
        this.prefs.putSync(key, value)
        this.prefs.flush()
      } catch (e) {
        hilog.error(DOMAIN, TAG, `put ${key} err: ${JSON.stringify(e)}`)
      }
    }
  }

  // ========== 开关状态 ==========

  /** 总开关：是否启用智能通知 */
  isEnabled(): boolean {
    return this.getStr('enabled', '') === '1'
  }

  setEnabled(v: boolean): void {
    this.setStr('enabled', v ? '1' : '0')
  }

  /** 断网告警开关 */
  isOfflineAlertOn(): boolean {
    return this.getStr('offlineAlert', '') === '1'
  }

  setOfflineAlert(v: boolean): void {
    this.setStr('offlineAlert', v ? '1' : '0')
  }

  /** 新设备接入提醒开关 */
  isNewDeviceAlertOn(): boolean {
    return this.getStr('newDeviceAlert', '') === '1'
  }

  setNewDeviceAlert(v: boolean): void {
    this.setStr('newDeviceAlert', v ? '1' : '0')
  }

  /** AI 健康告警开关（温度/内存/流量异常主动推送） */
  isAiHealthAlertOn(): boolean {
    return this.getStr('aiHealthAlert', '') === '1'
  }

  setAiHealthAlert(v: boolean): void {
    this.setStr('aiHealthAlert', v ? '1' : '0')
  }

  // ========== 检测状态 ==========

  /** 上次在线状态（true=在线 false=离线；未检测过返回 null） */
  getLastOnline(): boolean | null {
    const v: string = this.getStr('lastOnline', '')
    if (v === '') return null
    return v === '1'
  }

  setLastOnline(v: boolean | null): void {
    this.setStr('lastOnline', v === null ? '' : (v ? '1' : '0'))
  }

  /** 已知设备 MAC 集合（JSON 数组） */
  getLastMacs(): string[] {
    try {
      const v: string = this.getStr('lastMacs', '')
      if (!v) return []
      return JSON.parse(v) as string[]
    } catch (e) {
      return []
    }
  }

  setLastMacs(macs: string[]): void {
    this.setStr('lastMacs', JSON.stringify(macs))
  }

  /** 上次执行日期（YYYY-MM-DD，防止同一任务重复触发） */
  getLastCheckedDate(): string {
    return this.getStr('lastCheckedDate', '')
  }

  setLastCheckedDate(d: string): void {
    this.setStr('lastCheckedDate', d)
  }

  /** AI 告警去重记录：{ 类型: 上次推送日期YYYY-MM-DD }，同类型 24h 内不重复推送 */
  getLastAiAlerts(): Record<string, string> {
    try {
      const v: string = this.getStr('lastAiAlerts', '')
      if (!v) return {}
      return JSON.parse(v) as Record<string, string>
    } catch (e) {
      return {}
    }
  }

  setLastAiAlerts(map: Record<string, string>): void {
    this.setStr('lastAiAlerts', JSON.stringify(map))
  }
}
