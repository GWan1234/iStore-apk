/**
 * WidgetDataStore - 桌面小组件数据桥接
 * App 前台轮询时把路由器实时状态写入 Preferences；
 * 卡片（FormExtensionAbility）onUpdateForm 时读取并渲染
 */
import { preferences } from '@kit.ArkData'
import { hilog } from '@kit.PerformanceAnalysisKit'

const TAG = 'WidgetDataStore'
const DOMAIN = 0x0001
const STORE_NAME = 'iStore_widget'

/** 小组件快照数据 */
export interface WidgetSnapshot {
  rxRate: number       // 下载速率（B/s）
  txRate: number       // 上传速率（B/s）
  deviceCount: number  // 在线设备数
  online: boolean      // 路由器是否在线
  deviceName: string   // 设备名称
  cpuUsage: number     // CPU 使用率（%）
  memPercent: number   // 内存使用率（%）
  ip: string           // 路由器 LAN IP
}

const KEY_DATA = 'snapshot'
const KEY_DIMENSION = 'dimension'

export class WidgetDataStore {
  private static prefs: preferences.Preferences | null = null

  /** 记录卡片尺寸（onAddForm 时保存，onUpdateForm 读取避免被覆盖） */
  static saveDimension(dimension: string): void {
    if (!WidgetDataStore.prefs) return
    try {
      WidgetDataStore.prefs.putSync(KEY_DIMENSION, dimension)
      WidgetDataStore.prefs.flush()
    } catch (e) {
      hilog.error(DOMAIN, TAG, `saveDimension err: ${JSON.stringify(e)}`)
    }
  }

  /** 读取卡片尺寸（默认 2*2） */
  static loadDimension(): string {
    if (!WidgetDataStore.prefs) return '2*2'
    try {
      const v: string = WidgetDataStore.prefs.getSync(KEY_DIMENSION, '') as string
      return v || '2*2'
    } catch (e) {
      return '2*2'
    }
  }

  /** 初始化（App 侧调用） */
  static async init(context: Context): Promise<void> {
    if (WidgetDataStore.prefs) return
    try {
      WidgetDataStore.prefs = await preferences.getPreferences(context, STORE_NAME)
    } catch (e) {
      hilog.error(DOMAIN, TAG, `init err: ${JSON.stringify(e)}`)
    }
  }

  /** App 侧：保存最新快照 */
  static save(snap: WidgetSnapshot): void {
    if (!WidgetDataStore.prefs) return
    try {
      WidgetDataStore.prefs.putSync(KEY_DATA, JSON.stringify(snap))
      WidgetDataStore.prefs.flush()
    } catch (e) {
      hilog.error(DOMAIN, TAG, `save err: ${JSON.stringify(e)}`)
    }
  }

  /** 卡片侧：读取快照 */
  static load(): WidgetSnapshot {
    const empty: WidgetSnapshot = {
      rxRate: 0, txRate: 0, deviceCount: 0, online: false, deviceName: 'iStore 路由管家',
      cpuUsage: 0, memPercent: 0, ip: ''
    }
    if (!WidgetDataStore.prefs) return empty
    try {
      const v: string = WidgetDataStore.prefs.getSync(KEY_DATA, '') as string
      if (!v) return empty
      const rec = JSON.parse(v) as Record<string, Object>
      return {
        rxRate: (rec['rxRate'] as number) || 0,
        txRate: (rec['txRate'] as number) || 0,
        deviceCount: (rec['deviceCount'] as number) || 0,
        online: (rec['online'] as boolean) === true,
        deviceName: (rec['deviceName'] as string) || 'iStore 路由管家',
        cpuUsage: (rec['cpuUsage'] as number) || 0,
        memPercent: (rec['memPercent'] as number) || 0,
        ip: (rec['ip'] as string) || ''
      }
    } catch (e) {
      return empty
    }
  }

  /** 卡片侧：用独立 context 初始化后读取 */
  static async loadWithContext(context: Context): Promise<WidgetSnapshot> {
    try {
      const p: preferences.Preferences = await preferences.getPreferences(context, STORE_NAME)
      WidgetDataStore.prefs = p
    } catch (e) {
      hilog.error(DOMAIN, TAG, `loadWithContext err: ${JSON.stringify(e)}`)
    }
    return WidgetDataStore.load()
  }

  /** 卡片侧：同步读取（onAddForm 等同步回调用） */
  static loadWithContextSync(context: Context): WidgetSnapshot {
    try {
      WidgetDataStore.prefs = preferences.getPreferencesSync(context, { name: STORE_NAME })
    } catch (e) {
      hilog.error(DOMAIN, TAG, `loadWithContextSync err: ${JSON.stringify(e)}`)
    }
    return WidgetDataStore.load()
  }
}
