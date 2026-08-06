/**
 * ScheduleStore - 定时任务配置存储（单例）
 * 保存：定时重启、定时开关 WiFi 的配置
 * 配置项：enabled / time(HH:MM) / weekdays(JSON 数组 0-6，0=周一)
 * 以及执行状态：lastExecDate 防止重复触发
 */
import { preferences } from '@kit.ArkData'
import { hilog } from '@kit.PerformanceAnalysisKit'

const TAG = 'ScheduleStore'
const DOMAIN = 0x0001
const STORE_NAME = 'iStore_schedule'

/** 定时任务配置 */
export interface ScheduleTask {
  enabled: boolean
  time: string        // "HH:MM"
  weekdays: number[]  // 0=周一 ... 6=周日；空=每天
}

export class ScheduleStore {
  private static instance: ScheduleStore
  private prefs: preferences.Preferences | null = null
  private cache: Map<string, string> = new Map()

  static getInstance(): ScheduleStore {
    if (!ScheduleStore.instance) {
      ScheduleStore.instance = new ScheduleStore()
    }
    return ScheduleStore.instance
  }

  async init(context: Context): Promise<void> {
    if (this.prefs) return
    try {
      this.prefs = await preferences.getPreferences(context, STORE_NAME)
      const keys: string[] = ['reboot', 'wifiOff', 'wifiOn', 'lastExecDate']
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

  private parseTask(key: string): ScheduleTask {
    const def: ScheduleTask = { enabled: false, time: '04:00', weekdays: [] }
    try {
      const v: string = this.getStr(key, '')
      if (!v) return def
      const rec = JSON.parse(v) as Record<string, Object>
      const task: ScheduleTask = {
        enabled: rec['enabled'] === true,
        time: (rec['time'] as string) || '04:00',
        weekdays: (rec['weekdays'] as number[]) || []
      }
      return task
    } catch (e) {
      return def
    }
  }

  private saveTask(key: string, task: ScheduleTask): void {
    this.setStr(key, JSON.stringify(task))
  }

  // ========== 定时重启 ==========

  getRebootTask(): ScheduleTask {
    return this.parseTask('reboot')
  }

  saveRebootTask(task: ScheduleTask): void {
    this.saveTask('reboot', task)
  }

  // ========== 定时 WiFi ==========

  /** 定时关 WiFi（time=关闭时刻） */
  getWifiOffTask(): ScheduleTask {
    return this.parseTask('wifiOff')
  }

  saveWifiOffTask(task: ScheduleTask): void {
    this.saveTask('wifiOff', task)
  }

  /** 定时开 WiFi（time=开启时刻） */
  getWifiOnTask(): ScheduleTask {
    return this.parseTask('wifiOn')
  }

  saveWifiOnTask(task: ScheduleTask): void {
    this.saveTask('wifiOn', task)
  }

  // ========== 执行状态 ==========

  /** 上次已执行任务的日期（YYYY-MM-DD）+ 任务标识，防止重复触发 */
  getLastExec(key: string): string {
    return this.getStr(`lastExec_${key}`, '')
  }

  setLastExec(key: string, date: string): void {
    this.setStr(`lastExec_${key}`, date)
  }
}
