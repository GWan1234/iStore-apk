/**
 * Jellyfin 媒体配置存储
 * 使用 Preferences 将 Jellyfin 服务器配置（URL + Token + 用户信息）以 JSON 字符串形式持久化
 * 配置按路由器设备隔离：每个设备独立保存，切换设备互不影响
 */
import { preferences } from '@kit.ArkData'
import { hilog } from '@kit.PerformanceAnalysisKit'

const STORE_NAME = 'iStore_jellyfin'  // Preferences 存储文件名
const KEY_PREFIX = 'jellyfinConfig_'  // 配置存储键前缀（后接设备 ID）
const DOMAIN = 0x0001
const TAG = 'JellyfinStore'

/** Jellyfin 服务器配置 */
export interface JellyfinConfig {
  baseUrl: string   // 服务器地址（如 http://192.168.1.1:8096）
  token: string     // AccessToken
  userId: string    // 用户 ID
  userName: string  // 用户名
  password: string  // 密码（用于 token 失效自动重登）
}

export class JellyfinStore {
  private static instance: JellyfinStore
  private prefs: preferences.Preferences | null = null
  private config: JellyfinConfig | null = null
  private configDeviceId: string = ''   // 当前 config 对应的设备 ID

  static getInstance(): JellyfinStore {
    if (!JellyfinStore.instance) {
      JellyfinStore.instance = new JellyfinStore()
    }
    return JellyfinStore.instance
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
  async getConfig(deviceId: string): Promise<JellyfinConfig | null> {
    if (!this.prefs || !deviceId) return null
    if (this.config && this.configDeviceId === deviceId) {
      return this.config
    }
    try {
      const raw: preferences.ValueType = this.prefs.getSync(this.keyOf(deviceId), '')
      if (typeof raw === 'string' && raw) {
        const parsed: JellyfinConfig = JSON.parse(raw) as JellyfinConfig
        if (parsed && parsed.baseUrl) {
          this.config = parsed
          this.configDeviceId = deviceId
          return parsed
        }
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, `getConfig failed: ${JSON.stringify(e)}`)
    }
    return null
  }

  /** 保存指定设备的配置 */
  async saveConfig(deviceId: string, config: JellyfinConfig): Promise<void> {
    if (!this.prefs || !deviceId) return
    try {
      await this.prefs.put(this.keyOf(deviceId), JSON.stringify(config))
      await this.prefs.flush()
      this.config = config
      this.configDeviceId = deviceId
    } catch (e) {
      hilog.error(DOMAIN, TAG, `saveConfig failed: ${JSON.stringify(e)}`)
    }
  }

  /** 清除指定设备的配置 */
  async clearConfig(deviceId: string): Promise<void> {
    if (!this.prefs || !deviceId) return
    try {
      await this.prefs.delete(this.keyOf(deviceId))
      await this.prefs.flush()
      if (this.configDeviceId === deviceId) {
        this.config = null
        this.configDeviceId = ''
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, `clearConfig failed: ${JSON.stringify(e)}`)
    }
  }
}
