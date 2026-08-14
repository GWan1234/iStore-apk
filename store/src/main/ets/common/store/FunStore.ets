/**
 * FunStore - 趣味功能数据存储（成就 / 里程碑 / 设备作息采样）
 * 独立 preferences 存储，与 TrafficStatStore 同模式
 */
import { preferences } from '@kit.ArkData'
import { hilog } from '@kit.PerformanceAnalysisKit'

const STORE_NAME = 'iStore_fun_store'   // Preferences 存储文件名
const DOMAIN = 0x0001
const TAG = 'FunStore'

export class FunStore {
  private static instance: FunStore
  private prefs: preferences.Preferences | null = null

  static getInstance(): FunStore {
    if (!FunStore.instance) {
      FunStore.instance = new FunStore()
    }
    return FunStore.instance
  }

  async init(context: Context): Promise<void> {
    if (this.prefs) return
    try {
      this.prefs = await preferences.getPreferences(context, STORE_NAME)
    } catch (e) {
      hilog.error(DOMAIN, TAG, `Init failed: ${JSON.stringify(e)}`)
    }
  }

  private todayKey(): string {
    const d: Date = new Date()
    const m: string = (d.getMonth() + 1).toString().padStart(2, '0')
    const day: string = d.getDate().toString().padStart(2, '0')
    return `${d.getFullYear()}-${m}-${day}`
  }

  // ========== 里程碑：首次连接日期 ==========
  getFirstDate(): string {
    if (!this.prefs) return ''
    try {
      return this.prefs.getSync('first_date', '') as string
    } catch (e) {
      return ''
    }
  }

  setFirstDate(date: string): void {
    if (!this.prefs) return
    try {
      this.prefs.putSync('first_date', date)
      this.prefs.flush()
    } catch (e) {}
  }

  // ========== 成就：达成状态 ==========
  isAchieved(id: string): boolean {
    if (!this.prefs) return false
    try {
      return (this.prefs.getSync(`ach_${id}`, false) as boolean) || false
    } catch (e) {
      return false
    }
  }

  setAchieved(id: string): void {
    if (!this.prefs) return
    try {
      this.prefs.putSync(`ach_${id}`, true)
      this.prefs.flush()
    } catch (e) {}
  }

  /** 记录今日使用（用于连续使用成就） */
  markUsedToday(): void {
    if (!this.prefs) return
    try {
      const key: string = `used_${this.todayKey()}`
      this.prefs.putSync(key, true)
      this.prefs.flush()
    } catch (e) {}
  }

  /** 最近 N 天使用天数 */
  usedDays(count: number): number {
    if (!this.prefs) return 0
    let total: number = 0
    const today: Date = new Date()
    for (let i = 0; i < count; i++) {
      const d: Date = new Date(today.getTime() - i * 86400000)
      const m: string = (d.getMonth() + 1).toString().padStart(2, '0')
      const day: string = d.getDate().toString().padStart(2, '0')
      const key: string = `used_${d.getFullYear()}-${m}-${day}`
      try {
        if (this.prefs.getSync(key, false) as boolean) {
          total++
        }
      } catch (e) {}
    }
    return total
  }

  // ========== 今日运势日期（每日一次）==========
  getFortuneDate(): string {
    if (!this.prefs) return ''
    try {
      return this.prefs.getSync('fortune_date', '') as string
    } catch (e) {
      return ''
    }
  }

  setFortuneDate(date: string): void {
    if (!this.prefs) return
    try {
      this.prefs.putSync('fortune_date', date)
      this.prefs.flush()
    } catch (e) {}
  }

  // ========== 设备作息采样（24h 活跃热力图）==========
  /**
   * 记录一批在线设备在指定小时的活跃标记（同日同设备同小时去重）
   * @param macs 在线设备 MAC 列表
   */
  addActivity(macs: string[]): void {
    if (!this.prefs || macs.length === 0) return
    try {
      const date: string = this.todayKey()
      const hour: number = new Date().getHours()
      const key: string = `act_${date}`
      const raw: string = this.prefs.getSync(key, '') as string
      const data: Record<string, string[]> = raw ? (JSON.parse(raw) as Record<string, string[]>) : {}
      for (let i = 0; i < macs.length; i++) {
        const mac: string = macs[i]
        if (!mac) continue
        let hours: string[] = data[mac]
        if (!hours) {
          hours = []
          for (let h = 0; h < 24; h++) {
            hours.push('0')
          }
          data[mac] = hours
        }
        if (hours[hour] === '0') {
          hours[hour] = '1'
        }
      }
      this.prefs.putSync(key, JSON.stringify(data))
      // 只保留最近 7 天
      const allKeys: string[] = Object.keys(this.prefs.getAllSync() as Object)
      const cutoff: Date = new Date(Date.now() - 7 * 86400000)
      const cM: string = (cutoff.getMonth() + 1).toString().padStart(2, '0')
      const cD: string = cutoff.getDate().toString().padStart(2, '0')
      const cutoffKey: string = `act_${cutoff.getFullYear()}-${cM}-${cD}`
      for (let k = 0; k < allKeys.length; k++) {
        if (allKeys[k].startsWith('act_') && allKeys[k] < cutoffKey) {
          this.prefs.deleteSync(allKeys[k])
        }
      }
      this.prefs.flush()
    } catch (e) {
      hilog.error(DOMAIN, TAG, `addActivity err: ${JSON.stringify(e)}`)
    }
  }

  /** 今日每设备 24h 活跃标记 */
  getTodayActivity(): Record<string, string[]> {
    const empty: Record<string, string[]> = {}
    if (!this.prefs) return empty
    try {
      const raw: string = this.prefs.getSync(`act_${this.todayKey()}`, '') as string
      if (!raw) return empty
      return JSON.parse(raw) as Record<string, string[]>
    } catch (e) {
      return empty
    }
  }

  // ========== WOL 远程开机设备列表 ==========
  /** 获取已保存的 WOL 设备列表 */
  getWolDevices(): WolDevice[] {
    const empty: WolDevice[] = []
    if (!this.prefs) return empty
    try {
      const raw: string = this.prefs.getSync('wol_devices', '') as string
      if (!raw) return empty
      const parsed = JSON.parse(raw) as WolDevice[]
      return parsed ? parsed : empty
    } catch (e) {
      return empty
    }
  }

  /** 保存 WOL 设备列表 */
  saveWolDevices(list: WolDevice[]): void {
    if (!this.prefs) return
    try {
      this.prefs.putSync('wol_devices', JSON.stringify(list))
      this.prefs.flush()
    } catch (e) {}
  }

  // ========== 路由器等级 ==========
  /** 累计使用天数（从首次连接日到今天） */
  getLevelUpDays(): number {
    const first: string = this.getFirstDate()
    if (!first) return 0
    try {
      const f: Date = new Date(first.replace(/-/g, '/'))
      const now: Date = new Date()
      const diff: number = Math.floor((now.getTime() - f.getTime()) / 86400000)
      return diff >= 0 ? diff + 1 : 1
    } catch (e) {
      return 1
    }
  }

  // ========== AI 首次对话标记 ==========
  hasAiChatted(): boolean {
    if (!this.prefs) return false
    try {
      return (this.prefs.getSync('ai_first_chat', false) as boolean) || false
    } catch (e) {
      return false
    }
  }

  setAiChatted(): void {
    if (!this.prefs) return
    try {
      this.prefs.putSync('ai_first_chat', true)
      this.prefs.flush()
    } catch (e) {}
  }

  /** 操作次数（趣味功能使用累计） */
  getLevelActions(): number {
    if (!this.prefs) return 0
    try {
      return (this.prefs.getSync('lv_actions', 0) as number) || 0
    } catch (e) {
      return 0
    }
  }

  /** 刷新累计次数（成就联动） */
  getRefreshCount(): number {
    if (!this.prefs) return 0
    try {
      return (this.prefs.getSync('refresh_count', 0) as number) || 0
    } catch (e) {
      return 0
    }
  }

  setRefreshCount(n: number): void {
    if (!this.prefs) return
    try {
      this.prefs.putSync('refresh_count', n)
      this.prefs.flush()
    } catch (e) {}
  }

  /** 记录一次操作（每天首次计数 +1，封顶防刷） */
  addLevelAction(): void {
    if (!this.prefs) return
    try {
      const today: string = this.todayKey()
      const last: string = (this.prefs.getSync('lv_last_day', '') as string) || ''
      let n: number = (this.prefs.getSync('lv_actions', 0) as number) || 0
      if (last !== today) {
        n = n + 1
        this.prefs.putSync('lv_last_day', today)
      }
      this.prefs.putSync('lv_actions', n)
      this.prefs.flush()
    } catch (e) {}
  }
}

/** WOL 远程开机设备 */
export interface WolDevice {
  name: string
  mac: string
}
