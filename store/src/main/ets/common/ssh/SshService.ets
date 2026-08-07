/**
 * SshService - SSH 终端服务（基于 @ohos-rs/ssh）
 * 复用设备保存的用户名/密码，保持长连接执行命令
 */
import { connect, Client, DisconnectReason } from '@ohos-rs/ssh'
import { SavedDevice } from '../store/DeviceStore'
import { hilog } from '@kit.PerformanceAnalysisKit'

const DOMAIN = 0x0001
const TAG = 'SshService'

export class SshService {
  private static instance: SshService
  private client: Client | null = null
  private hostName: string = ''

  static getInstance(): SshService {
    if (!SshService.instance) {
      SshService.instance = new SshService()
    }
    return SshService.instance
  }

  /** 连接路由器（SSH 端口 22） */
  async connect(device: SavedDevice): Promise<boolean> {
    this.disconnect()
    try {
      const hostPort: string = `${device.host}:22`
      const client: Client = await connect(hostPort)
      const authOk: boolean = await client.authenticatePassword(device.username, device.password)
      if (!authOk) {
        try { client.disconnect(DisconnectReason.ByApplication, '', '') } catch (_e) {}
        hilog.error(DOMAIN, TAG, 'SSH 密码认证失败')
        return false
      }
      this.client = client
      this.hostName = device.host
      hilog.info(DOMAIN, TAG, `SSH connected: ${hostPort}`)
      return true
    } catch (e) {
      hilog.error(DOMAIN, TAG, `connect err: ${JSON.stringify(e)}`)
      return false
    }
  }

  /** 执行命令，返回输出文本 */
  async exec(cmd: string): Promise<string> {
    if (!this.client) {
      return '未连接 SSH，请先连接'
    }
    try {
      const output = await this.client.exec(cmd)
      // Decode ArrayBuffer to string
      const bytes = new Uint8Array(output.output as ArrayBuffer)
      let result: string = ''
      for (let i = 0; i < bytes.length; i++) {
        result += String.fromCharCode(bytes[i])
      }
      return result
    } catch (e) {
      hilog.error(DOMAIN, TAG, `exec err: ${JSON.stringify(e)}`)
      return `命令执行失败：${JSON.stringify(e)}`
    }
  }

  /** 断开连接 */
  disconnect(): void {
    if (this.client) {
      try {
        this.client.disconnect(DisconnectReason.ByApplication, '', '')
      } catch (e) {
        hilog.error(DOMAIN, TAG, `disconnect err: ${JSON.stringify(e)}`)
      }
      this.client = null
    }
    this.hostName = ''
  }

  /** 是否已连接 */
  isConnected(): boolean {
    return this.client !== null
  }

  /** 当前连接主机 */
  host(): string {
    return this.hostName
  }
}
