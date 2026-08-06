/**
 * DeviceNoteStore - 设备备注名存储（单例）
 * 按路由器设备隔离，保存 mac 地址 → 自定义备注名的映射
 * 用于设备管理增强：给设备改名/备注（本地存储，不修改路由器配置）
 */
import { preferences } from '@kit.ArkData'
import { hilog } from '@kit.PerformanceAnalysisKit'

const TAG = 'DeviceNoteStore'
const DOMAIN = 0x0001
const STORE_NAME = 'iStore_device_notes'

export class DeviceNoteStore {
  private static instance: DeviceNoteStore
  private prefs: preferences.Preferences | null = null
  private cache: Map<string, Map<string, string>> = new Map()  // deviceId -> (mac -> note)

  static getInstance(): DeviceNoteStore {
    if (!DeviceNoteStore.instance) {
      DeviceNoteStore.instance = new DeviceNoteStore()
    }
    return DeviceNoteStore.instance
  }

  async init(context: Context): Promise<void> {
    if (this.prefs) return
    try {
      this.prefs = await preferences.getPreferences(context, STORE_NAME)
    } catch (e) {
      hilog.error(DOMAIN, TAG, `Init failed: ${JSON.stringify(e)}`)
    }
  }

  /** 获取某设备的备注映射表（内部） */
  private async notesOf(deviceId: string): Promise<Map<string, string>> {
    const cached: Map<string, string> | undefined = this.cache.get(deviceId)
    if (cached) {
      return cached
    }
    const map: Map<string, string> = new Map()
    if (this.prefs) {
      try {
        const json: string = this.prefs.getSync(`notes_${deviceId}`, '{}') as string
        const rec = JSON.parse(json) as Record<string, string>
        const keys: string[] = Object.keys(rec)
        for (let i = 0; i < keys.length; i++) {
          map.set(keys[i].toUpperCase(), rec[keys[i]])
        }
      } catch (e) {
        hilog.error(DOMAIN, TAG, `notesOf err: ${JSON.stringify(e)}`)
      }
    }
    this.cache.set(deviceId, map)
    return map
  }

  /** 保存设备备注名（mac 大写规范化存储） */
  async saveNote(deviceId: string, mac: string, note: string): Promise<void> {
    if (!this.prefs) return
    const macKey: string = mac.toUpperCase()
    const map: Map<string, string> = await this.notesOf(deviceId)
    if (note.trim()) {
      map.set(macKey, note.trim())
    } else {
      map.delete(macKey)
    }
    // 写回 Preferences
    const rec: Record<string, string> = {}
    map.forEach((v: string, k: string) => {
      rec[k] = v
    })
    try {
      await this.prefs.put(`notes_${deviceId}`, JSON.stringify(rec))
      await this.prefs.flush()
    } catch (e) {
      hilog.error(DOMAIN, TAG, `saveNote err: ${JSON.stringify(e)}`)
    }
  }

  /** 读取设备备注名（无则返回空串） */
  async getNote(deviceId: string, mac: string): Promise<string> {
    const map: Map<string, string> = await this.notesOf(deviceId)
    return map.get(mac.toUpperCase()) || ''
  }
}
