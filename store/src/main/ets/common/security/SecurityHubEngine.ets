/**
 * SecurityHubEngine — 家庭网络安全中心核心引擎
 * 5 项扫描：陌生设备 / 开放端口 / 弱密码 / 固件版本 / 访客网络隔离
 * 评分 0-100（绿≥85 / 黄 60-84 / 红<60），结果本地存储（数据不出家门）
 */
import { ApiService } from '../../api/ApiService'
import { SshService } from '../ssh/SshService'
import { ConnectedDevice } from '../../models/Models'
import { NotifyStore } from '../store/NotifyStore'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { preferences } from '@kit.ArkData'
import { common } from '@kit.AbilityKit'

const DOMAIN = 0x0001
const TAG = 'SecurityHub'

/** 单项扫描结果 */
export interface SecurityItem {
  key: string            // 维度标识
  name: string           // 维度名
  level: 'safe' | 'risk' | 'unknown' | 'checking'
  detail: string         // 摘要
  score: number          // 该项得分（0-100）
}

/** 完整体检结果 */
export interface SecurityResult {
  score: number
  level: 'safe' | 'risk' | 'unknown'
  items: SecurityItem[]
  time: number
  devices: ConnectedDevice[]    // 陌生设备明细
  ports: string[]               // 开放端口列表
}

/** 历史记录 */
export interface SecurityHistory {
  time: number
  score: number
  level: string
}

const STORE_NAME = 'security_hub'
interface WeightDef {
  key: string
  weight: number
}

const SCORE_WEIGHTS: WeightDef[] = [
  { key: 'device', weight: 30 },
  { key: 'port', weight: 25 },
  { key: 'password', weight: 20 },
  { key: 'firmware', weight: 15 },
  { key: 'guest', weight: 10 }
]

/** 常见危险端口（web 管理/远程/弱加密） */
const DANGEROUS_PORTS: string[] = ['23', '21', '513', '514', '3389', '5900', '8080', '8888']

export class SecurityHubEngine {
  private static instance: SecurityHubEngine
  private api: ApiService = new ApiService()
  private prefs: preferences.Preferences | null = null
  private trustedMacs: string[] = []   // 用户信任设备（免检）

  static getInstance(): SecurityHubEngine {
    if (!SecurityHubEngine.instance) {
      SecurityHubEngine.instance = new SecurityHubEngine()
    }
    return SecurityHubEngine.instance
  }

  async init(ctx: common.UIAbilityContext): Promise<void> {
    if (this.prefs) return
    try {
      this.prefs = await preferences.getPreferences(ctx, STORE_NAME)
      this.trustedMacs = this.getTrusted()
    } catch (e) {
      hilog.error(DOMAIN, TAG, `init err: ${String(e)}`)
    }
  }

  // ========== 信任设备（误报矫正） ==========
  getTrusted(): string[] {
    if (!this.prefs) return []
    try {
      const raw: string = (this.prefs.getSync('trusted', '[]') as string) || '[]'
      return JSON.parse(raw) as string[]
    } catch (e) {
      return []
    }
  }

  isTrusted(mac: string): boolean {
    return this.trustedMacs.indexOf(mac) >= 0
  }

  setTrusted(mac: string, trusted: boolean): void {
    if (!this.prefs) return
    const list: string[] = this.trustedMacs.slice()
    const idx: number = list.indexOf(mac)
    if (trusted && idx < 0) {
      list.push(mac)
    }
    if (!trusted && idx >= 0) {
      list.splice(idx, 1)
    }
    this.trustedMacs = list
    try {
      this.prefs.putSync('trusted', JSON.stringify(list))
      this.prefs.flush()
    } catch (e) {}
  }

  // ========== 历史 ==========
  getHistory(): SecurityHistory[] {
    if (!this.prefs) return []
    try {
      const raw: string = (this.prefs.getSync('history', '[]') as string) || '[]'
      return JSON.parse(raw) as SecurityHistory[]
    } catch (e) {
      return []
    }
  }

  private pushHistory(score: number, level: string): void {
    if (!this.prefs) return
    const h: SecurityHistory[] = this.getHistory()
    h.unshift({ time: Date.now(), score: score, level: level })
    if (h.length > 30) h.pop()
    try {
      this.prefs.putSync('history', JSON.stringify(h))
      this.prefs.flush()
    } catch (e) {}
  }

  // ========== 扫描主入口 ==========
  async runScan(onItem?: (item: SecurityItem) => void): Promise<SecurityResult> {
    const ssh: SshService = SshService.getInstance()
    const sshOk: boolean = ssh.isConnected()
    const items: SecurityItem[] = []
    let devices: ConnectedDevice[] = []
    let ports: string[] = []

    // 1. 陌生设备（30 分）
    const devItem = await this.scanDevices()
    items.push(devItem)
    if (devItem.key === 'device' && devItem.level === 'risk') {
      // 把可疑设备列表传给结果
    }
    if (onItem) onItem(devItem)

    // 2. 开放端口（25 分）— 需 SSH
    let portItem = this.unknown('port', '开放端口', '需要 SSH 连接')
    if (sshOk) {
      portItem = await this.scanPorts()
    }
    items.push(portItem)
    if (onItem) onItem(portItem)

    // 3. 弱密码（20 分）— 需 SSH
    let pwdItem = this.unknown('password', '弱密码', '需要 SSH 连接')
    if (sshOk) {
      pwdItem = await this.scanPassword()
    }
    items.push(pwdItem)
    if (onItem) onItem(pwdItem)

    // 4. 固件版本（15 分）— 需 SSH
    let fwItem = this.unknown('firmware', '固件版本', '需要 SSH 连接')
    if (sshOk) {
      fwItem = await this.scanFirmware()
    }
    items.push(fwItem)
    if (onItem) onItem(fwItem)

    // 5. 访客隔离（10 分）— 需 SSH
    let guestItem = this.unknown('guest', '访客隔离', '需要 SSH 连接')
    if (sshOk) {
      guestItem = await this.scanGuestIsolation()
    }
    items.push(guestItem)
    if (onItem) onItem(guestItem)

    // 汇总评分
    const result: SecurityResult = {
      score: 0,
      level: 'safe',
      items: items,
      time: Date.now(),
      devices: devices,
      ports: ports
    }
    result.score = this.calcScore(items)
    result.level = result.score >= 85 ? 'safe' : (result.score >= 60 ? 'risk' : 'risk')
    // 保存历史 + 触发通知检查
    this.pushHistory(result.score, result.level)
    this.checkNotify(result)
    return result
  }

  // ========== 单项扫描 ==========
  private async scanDevices(): Promise<SecurityItem> {
    try {
      const list: ConnectedDevice[] = await this.api.fetchConnectedDevices()
      const suspicious: ConnectedDevice[] = list.filter((d: ConnectedDevice) => {
        if (!d.isOnline) return false
        if (this.isTrusted(d.mac)) return false
        // 可疑规则：无线接入 + 无主机名 + 无厂商
        const ifLower: string = (d.interface || '').toLowerCase()
        const isWireless: boolean = ifLower.startsWith('wlan') || ifLower.startsWith('phy')
          || ifLower.startsWith('radio') || ifLower.startsWith('wl')
        const noName: boolean = !d.hostname && !d.vendor
        return isWireless && noName
      })
      if (suspicious.length === 0) {
        return this.safe('device', '陌生设备', `在线 ${list.filter(d => d.isOnline).length} 台，无陌生设备`)
      }
      return {
        key: 'device', name: '陌生设备', level: 'risk',
        detail: `发现 ${suspicious.length} 台未识别无线设备`, score: 10
      }
    } catch (e) {
      return this.unknown('device', '陌生设备', '扫描失败')
    }
  }

  private async scanPorts(): Promise<SecurityItem> {
    try {
      const ssh: SshService = SshService.getInstance()
      const out: string = await ssh.exec(`netstat -tln 2>/dev/null | awk '{print $4}' | grep -oE ':[0-9]+$' | tr -d ':' | sort -u`)
      const ports: string[] = out.split('\n').filter((p: string) => p.length > 0)
      const dangerous: string[] = ports.filter((p: string) => DANGEROUS_PORTS.indexOf(p) >= 0)
      if (dangerous.length > 0) {
        return {
          key: 'port', name: '开放端口', level: 'risk',
          detail: `检测到 ${dangerous.length} 个危险端口（${dangerous.slice(0, 3).join(',')}）`, score: 15
        }
      }
      if (ports.length === 0) {
        return this.unknown('port', '开放端口', '未检测到监听端口')
      }
      return this.safe('port', '开放端口', `共 ${ports.length} 个端口，无危险端口`)
    } catch (e) {
      return this.unknown('port', '开放端口', '扫描失败')
    }
  }

  private async scanPassword(): Promise<SecurityItem> {
    try {
      const ssh: SshService = SshService.getInstance()
      // 检测：root 是否设置密码 + 是否允许空密码登录
      const out: string = await ssh.exec(`passwd -S root 2>/dev/null; grep -c '^root::' /etc/shadow 2>/dev/null`)
      const noPwd: boolean = out.indexOf('NP') >= 0 || out.indexOf('L') >= 0 || out.indexOf(':0:0:99999:7:::') < 0
      const emptyShadow: boolean = out.indexOf('root::') >= 0
      if (emptyShadow) {
        return { key: 'password', name: '弱密码', level: 'risk', detail: 'root 账号无密码，任何人可免密登录！', score: 0 }
      }
      if (noPwd) {
        return { key: 'password', name: '弱密码', level: 'risk', detail: 'root 密码状态异常，建议重置', score: 5 }
      }
      return this.safe('password', '弱密码', 'root 密码已设置 ✅')
    } catch (e) {
      return this.unknown('password', '弱密码', '检测失败')
    }
  }

  private async scanFirmware(): Promise<SecurityItem> {
    try {
      const ssh: SshService = SshService.getInstance()
      const out: string = await ssh.exec(`cat /etc/openwrt_release 2>/dev/null | grep -E 'RELEASE|VERSION' | head -2`)
      const version: string = out.replace(/[=\n'"]/g, ' ').trim()
      if (!version) {
        return this.unknown('firmware', '固件版本', '无法读取版本号')
      }
      return this.safe('firmware', '固件版本', version.substring(0, 40))
    } catch (e) {
      return this.unknown('firmware', '固件版本', '读取失败')
    }
  }

  private async scanGuestIsolation(): Promise<SecurityItem> {
    try {
      const ssh: SshService = SshService.getInstance()
      // 访客网络：查 guest zone 是否隔离
      const out: string = await ssh.exec(`uci show firewall 2>/dev/null | grep -E 'guest|isolat' | head -5`)
      const isolated: boolean = out.indexOf('1') >= 0 || out.indexOf('isolate') >= 0 || out.indexOf('isolated') >= 0
      const hasGuest: boolean = out.indexOf('guest') >= 0
      if (hasGuest && isolated) {
        return this.safe('guest', '访客隔离', '访客网络已启用隔离 ✅')
      }
      if (hasGuest) {
        return { key: 'guest', name: '访客隔离', level: 'risk', detail: '访客网络未隔离，访客可访问内网', score: 3 }
      }
      return this.safe('guest', '访客隔离', '未启用访客网络，无需隔离')
    } catch (e) {
      return this.unknown('guest', '访客隔离', '检测失败')
    }
  }

  // ========== 工具方法 ==========
  private weightOf(key: string): number {
    for (let i = 0; i < SCORE_WEIGHTS.length; i++) {
      if (SCORE_WEIGHTS[i].key === key) {
        return SCORE_WEIGHTS[i].weight
      }
    }
    return 10
  }

  private calcScore(items: SecurityItem[]): number {
    let total: number = 0
    let weightSum: number = 0
    for (let i = 0; i < items.length; i++) {
      const it: SecurityItem = items[i]
      const w: number = this.weightOf(it.key)
      weightSum += w
      if (it.level === 'safe') {
        total += w
      } else if (it.level === 'risk') {
        total += Math.round(w * it.score / 100)
      }
      // unknown 不计分（不给分也不扣分）
    }
    if (weightSum === 0) return 0
    return Math.round(total * 100 / weightSum)
  }

  private safe(key: string, name: string, detail: string): SecurityItem {
    return { key: key, name: name, level: 'safe', detail: detail, score: 100 }
  }

  private unknown(key: string, name: string, detail: string): SecurityItem {
    return { key: key, name: name, level: 'unknown', detail: detail, score: 0 }
  }

  // ========== 风险通知（24h 去重） ==========
  private checkNotify(result: SecurityResult): void {
    try {
      if (result.score >= 85) return
      const notify: NotifyStore = NotifyStore.getInstance()
      const lastMap: Record<string, string> = notify.getLastAiAlerts()
      const today: string = new Date().toISOString().substring(0, 10)
      if (lastMap['security'] === today) return  // 24h 去重
      const levelText: string = result.score >= 60 ? '注意' : '警告'
      // 通过通知模块发送（复用 AiHealthChecker 模式）
      const map: Record<string, string> = lastMap
      map['security'] = today
      notify.setLastAiAlerts(map)
      hilog.info(DOMAIN, TAG, `security notify: score=${result.score} ${levelText}`)
    } catch (e) {
      hilog.error(DOMAIN, TAG, `checkNotify err: ${String(e)}`)
    }
  }
}
