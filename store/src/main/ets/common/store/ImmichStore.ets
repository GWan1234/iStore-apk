/**
 * Immich 相册配置存储
 * 使用 Preferences 将 Immich 服务器配置（URL + API Key）以 JSON 字符串形式持久化
 * 配置按路由器设备隔离：每个设备独立保存，切换设备互不影响
 */
import { preferences } from '@kit.ArkData'
import { hilog } from '@kit.PerformanceAnalysisKit'

const STORE_NAME = 'iStore_immich'  // Preferences 存储文件名
const KEY_PREFIX = 'immichConfig_'  // 配置存储键前缀（后接设备 ID）
const DOMAIN = 0x0001
const TAG = 'ImmichStore'

/** Immich 服务器配置 */
export interface ImmichConfig {
  baseUrl: string   // 服务器地址（如 http://192.168.1.1:2283）
  apiKey: string    // API Key
}

export class ImmichStore {
  private static instance: ImmichStore
  private prefs: preferences.Preferences | null = null
  private config: ImmichConfig | null = null
  private configDeviceId: string = ''   // 当前 config 对应的设备 ID

  static getInstance(): ImmichStore {
    if (!ImmichStore.instance) {
      ImmichStore.instance = new ImmichStore()
    }
    return ImmichStore.instance
  }

  /** 初始化 Preferences 存储 */
  async init(context: Context): Promise<void> {
    if (this.prefs) return
    try {
      this.prefs = await preferences.getPreferences(context, STORE_NAME)
    } catch (e) {
      hilog.error(DOMAIN, TAG, `init failed: ${JSON.stringify(e)}`)
    }
  }

  /** 生成某设备的配置键 */
  private keyOf(deviceId: string): string {
    return `${KEY_PREFIX}${deviceId}`
  }

  /**
   * 获取指定设备的配置（未初始化或该设备无配置时为 null）
   * 从 Preferences 按设备加载并缓存
   */
  async getConfig(deviceId: string): Promise<ImmichConfig | null> {
    if (!this.prefs || !deviceId) return null
    // 命中缓存直接返回
    if (this.config && this.configDeviceId === deviceId) {
      return this.config
    }
    try {
      const raw: preferences.ValueType = this.prefs.getSync(this.keyOf(deviceId), '')
      if (typeof raw === 'string' && raw) {
        this.config = JSON.parse(raw) as ImmichConfig
        this.configDeviceId = deviceId
        return this.config
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, `getConfig failed: ${JSON.stringify(e)}`)
    }
    return null
  }

  /** 获取当前设备配置的同步版本（仅当已缓存时有效） */
  getConfigSync(): ImmichConfig | null {
    return this.config
  }

  /** 保存指定设备的配置 */
  async saveConfig(deviceId: string, baseUrl: string, apiKey: string): Promise<boolean> {
    if (!this.prefs || !deviceId) return false
    try {
      const cfg: ImmichConfig = {
        baseUrl: baseUrl.trim().replace(/\/+$/, ''),
        apiKey: apiKey.trim()
      }
      this.config = cfg
      this.configDeviceId = deviceId
      await this.prefs.put(this.keyOf(deviceId), JSON.stringify(cfg))
      await this.prefs.flush()
      return true
    } catch (e) {
      hilog.error(DOMAIN, TAG, `saveConfig failed: ${JSON.stringify(e)}`)
    }
    return false
  }

  /** 清除指定设备的配置 */
  async clearConfig(deviceId: string): Promise<boolean> {
    if (!this.prefs || !deviceId) return false
    try {
      if (this.configDeviceId === deviceId) {
        this.config = null
        this.configDeviceId = ''
      }
      await this.prefs.delete(this.keyOf(deviceId))
      await this.prefs.flush()
      return true
    } catch (e) {
      hilog.error(DOMAIN, TAG, `clearConfig failed: ${JSON.stringify(e)}`)
    }
    return false
  }
}
