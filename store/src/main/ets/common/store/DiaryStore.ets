/**
 * DiaryStore — 网络日记存储（每日事件收集，JSON 持久化，保留 30 天）
 * 事件类型：new_device(新增) / traffic(大流量) / offline(掉线) / security(安全) / peak(高峰)
 */
import { preferences } from '@kit.ArkData'
import { common } from '@kit.AbilityKit'
import { hilog } from '@kit.PerformanceAnalysisKit'

const DOMAIN = 0x0001
const TAG = 'DiaryStore'
const STORE_NAME = 'diary_store'
const MAX_DAYS = 30

/** 日记事件 */
export interface DiaryEvent {
  type: string       // new_device / traffic / offline / security / peak
  title: string
  desc: string
  time: string       // HH:mm
  chips: string[]    // 状态芯片文字
  chipTone: string   // up / growth / warn / bad / info
}

/** 某天日记 */
export interface DayDiary {
  date: string            // YYYY-MM-DD
  onlineCount: number     // 在线设备
  newCount: number        // 新增设备
  trafficGb: number       // 总流量 GB
  abnormalCount: number   // 异常事件数
  events: DiaryEvent[]
}

export class DiaryStore {
  private static instance: DiaryStore
  private prefs: preferences.Preferences | null = null

  static getInstance(): DiaryStore {
    if (!DiaryStore.instance) {
      DiaryStore.instance = new DiaryStore()
    }
    return DiaryStore.instance
  }

  async init(ctx: common.UIAbilityContext): Promise<void> {
    if (this.prefs) return
    try {
      this.prefs = await preferences.getPreferences(ctx, STORE_NAME)
    } catch (e) {
      hilog.error(DOMAIN, TAG, `init err: ${String(e)}`)
    }
  }

  private today(): string {
    const d: Date = new Date()
    return `${d.getFullYear()}-${this.pad(d.getMonth() + 1)}-${this.pad(d.getDate())}`
  }

  private pad(n: number): string {
    return n < 10 ? '0' + n : '' + n
  }

  /** 取某天日记（无则空模板） */
  getDay(date: string): DayDiary {
    const all: DayDiary[] = this.getAll()
    for (let i = 0; i < all.length; i++) {
      if (all[i].date === date) return all[i]
    }
    return {
      date: date, onlineCount: 0, newCount: 0, trafficGb: 0, abnormalCount: 0, events: []
    }
  }

  /** 全部日记（倒序，今天在前） */
  getAll(): DayDiary[] {
    if (!this.prefs) return []
    try {
      const raw: string = (this.prefs.getSync('diaries', '[]') as string) || '[]'
      return JSON.parse(raw) as DayDiary[]
    } catch (e) {
      return []
    }
  }

  /** 最近 N 天日期列表（含今天） */
  recentDates(count: number): string[] {
    const dates: string[] = []
    const now: Date = new Date()
    for (let i = 0; i < count; i++) {
      const d: Date = new Date(now.getTime() - i * 86400000)
      dates.push(`${d.getFullYear()}-${this.pad(d.getMonth() + 1)}-${this.pad(d.getDate())}`)
    }
    return dates
  }

  /** 追加事件到某天 */
  addEvent(date: string, ev: DiaryEvent): void {
    if (!this.prefs) return
    try {
      const all: DayDiary[] = this.getAll()
      let day: DayDiary | null = null
      for (let i = 0; i < all.length; i++) {
        if (all[i].date === date) {
          day = all[i]
          break
        }
      }
      if (!day) {
        day = { date: date, onlineCount: 0, newCount: 0, trafficGb: 0, abnormalCount: 0, events: [] }
        all.unshift(day)
      }
      // 去重（同类型+标题 24h 内只记一次）
      for (let i = 0; i < day.events.length; i++) {
        if (day.events[i].type === ev.type && day.events[i].title === ev.title) {
          return
        }
      }
      if (ev.type === 'new_device') day.newCount++
      if (ev.type === 'offline' || ev.type === 'peak') day.abnormalCount++
      day.events.unshift(ev)
      if (day.events.length > 30) day.events.pop()
      // 保留 30 天
      const sorted: DayDiary[] = all.sort((a: DayDiary, b: DayDiary) => b.date.localeCompare(a.date))
      while (sorted.length > MAX_DAYS) sorted.pop()
      this.prefs.putSync('diaries', JSON.stringify(sorted))
      this.prefs.flush()
    } catch (e) {
      hilog.error(DOMAIN, TAG, `addEvent err: ${String(e)}`)
    }
  }

  /** 设置某天概览数字 */
  setSummary(date: string, online: number, trafficGb: number): void {
    if (!this.prefs) return
    try {
      const all: DayDiary[] = this.getAll()
      let day: DayDiary | null = null
      for (let i = 0; i < all.length; i++) {
        if (all[i].date === date) {
          day = all[i]
          break
        }
      }
      if (!day) {
        day = { date: date, onlineCount: 0, newCount: 0, trafficGb: 0, abnormalCount: 0, events: [] }
        all.unshift(day)
      }
      day.onlineCount = online
      day.trafficGb = trafficGb
      const sorted: DayDiary[] = all.sort((a: DayDiary, b: DayDiary) => b.date.localeCompare(a.date))
      while (sorted.length > MAX_DAYS) sorted.pop()
      this.prefs.putSync('diaries', JSON.stringify(sorted))
      this.prefs.flush()
    } catch (e) {}
  }
}
