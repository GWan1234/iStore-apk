import { AppState } from '../../common/store/AppState'
import { ThemePalette, DARK_THEME } from '../../common/theme/ThemeColors'
import { SystemInfo, WanStatus, ConnectedDevice, NetworkInterface, MountPoint, ConntrackInfo, WirelessClient } from '../../models/Models'
import { FormatUtils } from '../../common/utils/FormatUtils'
import { ApiService } from '../../api/ApiService'
import { hilog } from '@kit.PerformanceAnalysisKit'

// ============================================================
// DashboardTab - 首页
// ============================================================
@Component
export struct DashboardTab {
  @Prop theme: ThemePalette
  @State systemInfo: SystemInfo = this.emptySys()
  @State wanStatus: WanStatus = this.emptyWan()
  @State lanStatus: WanStatus = this.emptyWan()
  @State isLoading: boolean = true
  @State lastUpdate: string = '--:--:--'
  @State errorText: string = ''
  @State isOnline: boolean = false
  @State mountPoints: MountPoint[] = []
  @State conntrack: ConntrackInfo = { current: 0, max: 0, percent: 0 }
  @State networkInterfaces: NetworkInterface[] = []
  @State onlineClientCount: number = 0
  private lastScrollY: number = 0
  private timerId: number = -1
  private isVisible: boolean = false
  private tabChangeListener: ((tab: number) => void) | null = null
  // 仪表盘 Canvas 上下文（每个仪表独立）
  private gaugeCtx0: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true))
  private gaugeCtx1: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true))
  private gaugeCtx2: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true))
  private gaugeCtx3: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true))
  // 仪表动画状态（当前显示值 → 目标值，丝滑过渡）
  private gaugeCurrent: number[] = [0, 0, 0, 0]
  private gaugeTarget: number[] = [0, 0, 0, 0]
  private gaugeAnimTimer: number = -1

  aboutToAppear(): void {
    // 前台感知：仅当本 Tab（首页 index 0）可见时轮询
    this.isVisible = AppState.getInstance().getCurrentTab() === 0
    this.tabChangeListener = (tab: number) => {
      const visible: boolean = tab === 0
      if (visible && !this.isVisible) {
        this.isVisible = true
        // 回到本 Tab 时立即刷新一次，然后恢复轮询
        this.refreshData()
        if (this.timerId === -1) {
          this.timerId = setInterval(() => { this.refreshData() }, 5000)
        }
      } else if (!visible && this.isVisible) {
        this.isVisible = false
        if (this.timerId !== -1) {
          clearInterval(this.timerId)
          this.timerId = -1
        }
      }
    }
    AppState.getInstance().onTabChange(this.tabChangeListener)
    // 首次加载数据，然后启动 5 秒轮询刷新
    this.loadData()
    if (this.isVisible) {
      this.timerId = setInterval(() => {
        this.refreshData()
      }, 5000)
    }
  }

  aboutToDisappear(): void {
    if (this.timerId !== -1) {
      clearInterval(this.timerId)
      this.timerId = -1
    }
    if (this.gaugeAnimTimer !== -1) {
      clearInterval(this.gaugeAnimTimer)
      this.gaugeAnimTimer = -1
    }
    if (this.tabChangeListener) {
      AppState.getInstance().offTabChange(this.tabChangeListener)
      this.tabChangeListener = null
    }
  }

  async loadData(): Promise<void> {
    this.isLoading = true
    this.errorText = ''
    try {
      // 检查连接状态，未连接则直接返回
      if (!AppState.getInstance().isConnected()) {
        this.errorText = '设备未连接'
        this.isLoading = false
        return
      }
      const api = new ApiService()
      // 并行请求，减少总加载时间
      const results = await Promise.all([
        api.fetchSystemInfo(),
        api.fetchLanStatus(),
        api.fetchMountPoints(),
        api.fetchConntrack(),
        api.fetchNetworkInterfaces(),
        api.fetchConnectedDevices()
      ])
      // 按 Promise.all 顺序解包结果
      this.systemInfo = results[0]
      this.lanStatus = results[1]
      this.wanStatus = results[1]
      this.mountPoints = results[2]
      this.conntrack = results[3]
      this.networkInterfaces = results[4]
      this.onlineClientCount = this.countOnlineClients(results[5])
      this.isOnline = true
    } catch (dashErr) {
      this.errorText = '加载数据失败'
    }
    this.isLoading = false
    this.updateTimestamp()
    this.redrawGauges()
  }

  countOnlineClients(devices: ConnectedDevice[]): number {
    let count = 0
    for (let i = 0; i < devices.length; i++) {
      if (devices[i].isOnline) {
        count++
      }
    }
    return count
  }

  async refreshData(): Promise<void> {
    try {
      // 断开连接后停止刷新
      if (!AppState.getInstance().isConnected()) {
        return
      }
      const api = new ApiService()
      const results = await Promise.all([
        api.fetchSystemInfo(),
        api.fetchLanStatus(),
        api.fetchMountPoints(),
        api.fetchConntrack(),
        api.fetchConnectedDevices()
      ])
      this.systemInfo = results[0]
      this.lanStatus = results[1]
      this.wanStatus = results[1]
      this.mountPoints = results[2]
      this.conntrack = results[3]
      this.onlineClientCount = this.countOnlineClients(results[4])
      this.isOnline = true
    } catch (refErr) {
      // 刷新失败静默处理，不打断用户操作
    }
    this.updateTimestamp()
    this.redrawGauges()
  }

  updateTimestamp(): void {
    const now: Date = new Date()
    this.lastUpdate =
      `${now.getHours().toString().padStart(2, '0')}:${now.getMinutes().toString().padStart(2, '0')}:${now.getSeconds().toString().padStart(2, '0')}`
  }

  emptySys(): SystemInfo {
    return {
      hostname: '', model: '', kernel: '', firmwareVersion: '',
      localTime: '', uptime: 0, cpuUsage: 0, memoryTotal: 0, memoryUsed: 0,
      memoryCached: 0, memoryAvailable: 0, storageTotal: 0, storageUsed: 0, cpuTemp: 0,
      boardName: '', cpuModel: '', distribution: '', releaseVersion: '', releaseRevision: '', releaseTarget: ''
    }
  }

  emptyWan(): WanStatus {
    return {
      interface: '', uptime: 0, ipAddress: '0.0.0.0',
      netmask: '', gateway: '', dns: [], rxRate: 0, txRate: 0, onlineTime: '',
      proto: '', macAddr: ''
    }
  }

  getCpuColor(usage: number): string {
    if (usage < 30) {
      // < 30%：低负载（绿色）
      return '#00E676'
    }
    if (usage < 60) {
      // 30-60%：中等负载（黄色）
      return '#FFD740'
    }
    // ≥ 60%：高负载（红色）
    return '#FF5252'
  }

  /** 内存使用率（%） */
  memoryPercent(): number {
    return this.systemInfo.memoryTotal > 0
      ? Math.min(100, Math.round(this.systemInfo.memoryUsed * 100 / this.systemInfo.memoryTotal))
      : 0
  }

  /** 内存已用/总量文本（如 256MB / 1.9GB） */
  memoryUsedText(): string {
    if (this.systemInfo.memoryTotal <= 0) {
      return '--'
    }
    return FormatUtils.formatBytes(this.systemInfo.memoryUsed)
  }

  /** 内存颜色（按使用率） */
  getMemColor(usage: number): string {
    if (usage < 60) return '#448AFF'
    if (usage < 85) return '#FFD740'
    return '#FF5252'
  }

  /** 温度 → 仪表进度（0-100%），>90°C 视为满 */
  tempPercent(temp: number): number {
    if (temp <= 0) return 0
    return Math.min(100, Math.max(0, Math.round(temp * 100 / 90)))
  }

  /** 统一仪表颜色：绿(<30%)/蓝(<60%)/黄(<70%)/红(≥70%)，返回 [浅色, 深色] 渐变对 */
  getGaugeGradient(percent: number): string[] {
    if (percent < 30) {
      return ['#69F0AE', '#00C853']  // 绿色渐变（浅→深，对比明显）
    }
    if (percent < 60) {
      return ['#90CAF9', '#1E88E5']  // 蓝色渐变（浅→深）
    }
    if (percent < 70) {
      return ['#FFE082', '#FFB300']  // 黄色渐变（浅→深）
    }
    return ['#FF8A80', '#D50000']    // 红色渐变（浅→深）
  }

  /** 温度仪表配色：绿(<30°C) / 蓝(<60°C) / 黄(<70°C) / 红(≥70°C)，返回 [浅色, 深色] */
  getTempGaugeGradient(temp: number): string[] {
    if (temp <= 0) {
      return ['#9E9E9E', '#616161']  // 无温度数据：灰色渐变
    }
    if (temp < 30) {
      return ['#69F0AE', '#00C853']  // 绿色渐变（浅→深）
    }
    if (temp < 60) {
      return ['#90CAF9', '#1E88E5']  // 蓝色渐变（浅→深）
    }
    if (temp < 70) {
      return ['#FFE082', '#FFB300']  // 黄色渐变（浅→深）
    }
    return ['#FF8A80', '#D50000']    // 红色渐变（浅→深）
  }

  /** 环形仪表卡片（Canvas 渐变圆弧） */
  @Builder
  gaugeCard(label: string, valueText: string, percent: number, color: string, ctx: CanvasRenderingContext2D, gradientOverride: string[]) {
    Column() {
      // 环形仪表（Canvas 渐变）
      Canvas(ctx)
        .width(76).height(76)
        .onReady(() => {
          // 首次绘制当前目标值（传入渐变对覆盖时用覆盖配色）
          this.drawGauge(ctx, Math.max(0, Math.min(100, percent)), color, gradientOverride)
        })
      // 中心数值（叠加在 Canvas 上方，数值与说明字号一致 10）
      Column() {
        Text(valueText)
          .fontSize(10)
          .fontColor(this.theme.textPrimary)
          .fontWeight(FontWeight.Bold)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(label)
          .fontSize(10)
          .fontColor(this.theme.textTertiary)
          .margin({ top: 2 })
      }
      .width(76).height(76)
      .position({ x: 0, y: 0 })
      .alignItems(HorizontalAlign.Center)
      .justifyContent(FlexAlign.Center)
    }
    .layoutWeight(1)
    .padding({ top: 14, bottom: 14 })
    .borderRadius(16)
    .backgroundColor(this.theme.bgCard)
    .backdropBlur(20)
    .border({ width: 0.5, color: this.theme.borderGlass })
    .alignItems(HorizontalAlign.Center)
    .margin({ left: 3, right: 3 })
  }

  /** 数据更新后平滑动画过渡到新值（丝滑渐变） */
  private redrawGauges(): void {
    const cpu: number = Math.max(0, Math.min(100, this.systemInfo.cpuUsage))
    const mem: number = this.memoryPercent()
    const temp: number = this.tempPercent(this.systemInfo.cpuTemp)
    // 更新目标值：CPU / 内存 / 内存占用 / 温度
    this.gaugeTarget[0] = cpu
    this.gaugeTarget[1] = mem
    this.gaugeTarget[2] = mem
    this.gaugeTarget[3] = temp
    // 启动动画循环（若未运行）
    if (this.gaugeAnimTimer === -1) {
      this.gaugeAnimTimer = setInterval(() => {
        this.gaugeAnimTick()
      }, 16)
    }
  }

  /** 动画帧：当前值向目标值插值逼近，重绘 4 个仪表 */
  private gaugeAnimTick(): void {
    try {
      let done: boolean = true
      for (let i = 0; i < 4; i++) {
        const cur: number = this.gaugeCurrent[i]
        const tgt: number = this.gaugeTarget[i]
        if (Math.abs(tgt - cur) < 0.3) {
          this.gaugeCurrent[i] = tgt
        } else {
          // 每帧向目标靠近 18%（指数趋近，先快后慢，丝滑）
          this.gaugeCurrent[i] = cur + (tgt - cur) * 0.18
          done = false
        }
      }
      // 重绘（用插值后的当前值；注意 ctx 与 UI 布局顺序对应：CPU ctx0 / 内存 ctx1 / 内存占用 ctx3 / 温度 ctx2）
      this.drawGauge(this.gaugeCtx0, this.gaugeCurrent[0], this.getGaugeGradient(this.gaugeTarget[0])[0])
      this.drawGauge(this.gaugeCtx1, this.gaugeCurrent[1], this.getGaugeGradient(this.gaugeTarget[1])[0])
      this.drawGauge(this.gaugeCtx3, this.gaugeCurrent[2], this.getGaugeGradient(this.gaugeTarget[2])[0])
      // 温度仪表：按温度值分档配色（绿<30°C / 蓝<60°C / 黄<70°C / 红≥70°C）
      const tempColors: string[] = this.getTempGaugeGradient(this.systemInfo.cpuTemp)
      this.drawGauge(this.gaugeCtx2, this.gaugeCurrent[3], tempColors[0], tempColors)
      // 全部到位后停止动画
      if (done) {
        if (this.gaugeAnimTimer !== -1) {
          clearInterval(this.gaugeAnimTimer)
          this.gaugeAnimTimer = -1
        }
      }
    } catch (e) {
      hilog.error(0x0001, 'DashboardTab', `gaugeAnimTick err: ${JSON.stringify(e)}`)
      if (this.gaugeAnimTimer !== -1) {
        clearInterval(this.gaugeAnimTimer)
        this.gaugeAnimTimer = -1
      }
    }
  }

  /** 绘制渐变圆弧仪表 */
  private drawGauge(ctx: CanvasRenderingContext2D, percent: number, color: string, colorsOverride: string[] = []): void {
    try {
      const w: number = 76
      const h: number = 76
      const cx: number = w / 2
      const cy: number = h / 2
      const r: number = 30
      const startAngle: number = -Math.PI / 2  // 12 点方向
      const endAngle: number = startAngle + Math.PI * 2  // 整圆

      ctx.clearRect(0, 0, w, h)

      // 底环（灰色）
      ctx.strokeStyle = 'rgba(255,255,255,0.08)'
      ctx.lineWidth = 8
      ctx.beginPath()
      ctx.arc(cx, cy, r, 0, Math.PI * 2)
      ctx.stroke()

      // 进度渐变圆弧：从起始点（12点）浅色 → 沿弧线均匀过渡到深色
      // 用分段绘制实现精确可控的弧线渐变（圆锥渐变角度语义不可靠）
      const colors: string[] = colorsOverride.length > 0 ? colorsOverride : this.getGaugeGradient(percent)
      const angle: number = Math.PI * 2 * Math.max(0, Math.min(100, percent)) / 100
      const segments: number = 24
      ctx.lineWidth = 8
      ctx.lineCap = 'round'
      for (let i = 0; i < segments; i++) {
        const t: number = i / segments  // 0（起始点浅色）→ 1（终点深色）
        const a0: number = startAngle + angle * i / segments
        const a1: number = startAngle + angle * (i + 1) / segments
        ctx.strokeStyle = this.lerpColor(colors[0], colors[1], t)
        ctx.beginPath()
        ctx.arc(cx, cy, r, a0, a1)
        ctx.stroke()
      }
    } catch (e) {
      hilog.error(0x0001, 'DashboardTab', `drawGauge err: ${JSON.stringify(e)}`)
    }
  }

  /** 两个 #RRGGBB 颜色按 t(0-1) 线性插值 */
  private lerpColor(c1: string, c2: string, t: number): string {
    try {
      const r1: number = parseInt(c1.substring(1, 3), 16)
      const g1: number = parseInt(c1.substring(3, 5), 16)
      const b1: number = parseInt(c1.substring(5, 7), 16)
      const r2: number = parseInt(c2.substring(1, 3), 16)
      const g2: number = parseInt(c2.substring(3, 5), 16)
      const b2: number = parseInt(c2.substring(5, 7), 16)
      const r: number = Math.round(r1 + (r2 - r1) * t)
      const g: number = Math.round(g1 + (g2 - g1) * t)
      const b: number = Math.round(b1 + (b2 - b1) * t)
      return `#${r.toString(16).padStart(2, '0')}${g.toString(16).padStart(2, '0')}${b.toString(16).padStart(2, '0')}`
    } catch (e) {
      return c1
    }
  }

  formatLocalTime(isoStr: string): string {
    try {
      // 将 ISO 格式时间字符串转为本地友好格式
      const d: Date = new Date(isoStr)
      return `${d.getFullYear()}-${(d.getMonth() + 1).toString().padStart(2, '0')}-${d.getDate().toString().padStart(2, '0')} ${d.getHours().toString().padStart(2, '0')}:${d.getMinutes().toString().padStart(2, '0')}:${d.getSeconds().toString().padStart(2, '0')}`
    } catch (e) {
      // 解析失败时返回原始字符串兜底
      return isoStr
    }
  }

  getTypeColor(type: string): string {
    if (type === 'wan') {
      return '#FF6E40'  // WAN 用橙色
    }
    if (type === 'lan') {
      return '#448AFF'  // LAN 用蓝色
    }
    if (type === 'wifi') {
      return '#00E676'  // WiFi 用绿色
    }
    return this.theme.textTertiary
  }

  getLanInterface(): NetworkInterface | null {
    // 遍历网络接口列表查找第一个 LAN 类型接口
    for (let i = 0; i < this.networkInterfaces.length; i++) {
      if (this.networkInterfaces[i].type === 'lan') {
        return this.networkInterfaces[i]
      }
    }
    return null
  }

  getLanIP(): string {
    const lanIf = this.getLanInterface()
    if (lanIf && lanIf.ipAddress) {
      return lanIf.ipAddress
    }
    return this.lanStatus.ipAddress !== '0.0.0.0' ? this.lanStatus.ipAddress : '--'
  }

  build() {
    Column() {
      // 顶部：设备名 + 在线状态 + 更新时间
      Row() {
        Column() {
          Text(this.systemInfo.hostname || 'OpenWrt')
            .fontSize(24)
            .fontColor(this.theme.textPrimary)
            .fontWeight(FontWeight.Bold)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Row() {
            Circle()
              .width(6)
              .height(6)
              .foregroundColor(this.isOnline ? this.theme.success : this.theme.danger)
            Text(this.isOnline ? '在线' : '离线')
              .fontSize(11)
              .fontColor(this.isOnline ? this.theme.success : this.theme.textTertiary)
              .margin({ left: 4 })
            Text(' · ')
              .fontSize(11)
              .fontColor(this.theme.textTertiary)
            Text(`更新 ${this.lastUpdate}`)
              .fontSize(11)
              .fontColor(this.theme.textTertiary)
          }
          .margin({ top: 4 })
        }

        Blank()
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: 8 })

      if (this.isLoading) {
        Column() {
          LoadingProgress().width(40).height(40).color(this.theme.primary)
          Text('加载中...')
            .fontSize(14)
            .fontColor(this.theme.textSecondary)
            .margin({ top: 12 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column() {
            if (this.errorText) {
              Flex({ direction: FlexDirection.Row, alignItems: ItemAlign.Stretch }) {
                Text('⚠')
                  .fontSize(16)
                  .margin({ right: 8 })
                Text(this.errorText)
                  .fontSize(12)
                  .fontColor(this.theme.warning)
              }
              .width('100%')
              .padding(14)
              .borderRadius(14)
              .margin({ top: 4, bottom: 4 })
              .backgroundColor(this.theme.bgCard)
              .backdropBlur(20)
              .border({ width: 0.5, color: this.theme.borderGlass })
            }

            // ============ 第一行：下载/上传 两个大卡片 ============
            Row() {
              // 下载速度
              Column() {
                Text('⇩ 下载')
                  .fontSize(11)
                  .fontColor(this.theme.textTertiary)
                  .margin({ bottom: 6 })
                Text(FormatUtils.formatSpeed(this.wanStatus.rxRate))
                  .fontSize(22)
                  .fontColor('#00E676')
                  .fontWeight(FontWeight.Bold)
                  .fontFamily('monospace')
              }
              .width('47%')
              .padding(14)
              .borderRadius(14)
              .backgroundColor(this.theme.bgCard)
              .backdropBlur(20)
              .border({ width: 0.5, color: this.theme.borderGlass })
              .alignItems(HorizontalAlign.Start)

              // 上传速度
              Column() {
                Text('⇧ 上传')
                  .fontSize(11)
                  .fontColor(this.theme.textTertiary)
                  .margin({ bottom: 6 })
                Text(FormatUtils.formatSpeed(this.wanStatus.txRate))
                  .fontSize(22)
                  .fontColor('#448AFF')
                  .fontWeight(FontWeight.Bold)
                  .fontFamily('monospace')
              }
              .width('47%')
              .padding(14)
              .borderRadius(14)
              .backgroundColor(this.theme.bgCard)
              .backdropBlur(20)
              .border({ width: 0.5, color: this.theme.borderGlass })
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)
            .margin({ top: 8 })

            // ============ 实时监控仪表盘：CPU / 内存 / 内存占用 / 温度 环形仪表（统一绿/蓝/黄/红渐变）============
            Row() {
              // CPU 仪表
              this.gaugeCard('CPU', FormatUtils.formatPercent(this.systemInfo.cpuUsage),
                this.systemInfo.cpuUsage, this.getGaugeGradient(this.systemInfo.cpuUsage)[0], this.gaugeCtx0, [])
              // 内存仪表
              this.gaugeCard('内存', FormatUtils.formatPercent(this.memoryPercent()),
                this.memoryPercent(), this.getGaugeGradient(this.memoryPercent())[0], this.gaugeCtx1, [])
              // 内存容量占用仪表（已用/总量）
              this.gaugeCard('内存占用', this.memoryUsedText(),
                this.memoryPercent(), this.getGaugeGradient(this.memoryPercent())[0], this.gaugeCtx3, [])
              // 温度仪表（按温度值分档配色：绿<30°C / 蓝<60°C / 黄<70°C / 红≥70°C）
              this.gaugeCard('温度', this.systemInfo.cpuTemp > 0 ? `${this.systemInfo.cpuTemp.toFixed(1)}°C` : '--',
                this.tempPercent(this.systemInfo.cpuTemp), this.getTempGaugeGradient(this.systemInfo.cpuTemp)[0],
                this.gaugeCtx2, this.getTempGaugeGradient(this.systemInfo.cpuTemp))
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)
            .margin({ top: 8 })

            // ============ 系统信息卡片 ============
            Column() {
              Text('💻 系统信息')
                .fontSize(14)
                .fontColor(this.theme.textPrimary)
                .fontWeight(FontWeight.Medium)
                .margin({ bottom: 12 })
              this.infoRow('主机名', this.systemInfo.hostname || '--')
              this.infoRow('系统描述', this.systemInfo.model || '--')
              if (this.systemInfo.cpuModel) {
                this.infoRow('CPU 型号', this.systemInfo.cpuModel)
              }
              if (this.systemInfo.boardName) {
                this.infoRow('架构/主板', this.systemInfo.boardName)
              }
              if (this.systemInfo.distribution) {
                this.infoRow('发行版', this.systemInfo.distribution)
              }
              if (this.systemInfo.releaseVersion) {
                this.infoRow('固件版本', this.systemInfo.releaseRevision
                  ? `${this.systemInfo.releaseVersion} (${this.systemInfo.releaseRevision})`
                  : this.systemInfo.releaseVersion)
              } else {
                this.infoRow('固件版本', this.systemInfo.firmwareVersion || '--')
              }
              if (this.systemInfo.releaseTarget) {
                this.infoRow('目标平台', this.systemInfo.releaseTarget)
              }
              this.infoRow('内核', this.systemInfo.kernel || '--')
              this.infoRow('本地时间', this.systemInfo.localTime
                ? this.formatLocalTime(this.systemInfo.localTime)
                : '--')
              this.infoRow('运行时间', this.systemInfo.uptime > 0 ? FormatUtils.formatUptime(this.systemInfo.uptime) : '--')
            }
            .width('100%')
            .padding(20)
            .borderRadius(24)
            .margin({ top: 10 })
            .backgroundColor(this.theme.bgCard)
            .backdropBlur(20)
            .border({ width: 0.5, color: this.theme.borderGlass })

            // ============ 局域网 ============
            Column() {
              Row() {
                Text('🌐 局域网')
                  .fontSize(13)
                  .fontColor(this.theme.textPrimary)
                  .fontWeight(FontWeight.Medium)

                Blank()

                Text(this.getLanIP())
                  .fontSize(16)
                  .fontColor(this.theme.primary)
                  .fontWeight(FontWeight.Bold)
                  .fontFamily('monospace')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width('100%')

              if (this.lanStatus.gateway) {
                Row() {
                  Text('网关')
                    .fontSize(11)
                    .fontColor(this.theme.textTertiary)
                  Blank()
                  Text(this.lanStatus.gateway)
                    .fontSize(11)
                    .fontColor(this.theme.textSecondary)
                    .fontFamily('monospace')
                }
                .width('100%')
                .margin({ top: 4 })
              }
            }
            .width('100%')
            .padding(10)
            .borderRadius(12)
            .margin({ top: 10 })
            .backgroundColor(this.theme.bgCard)
            .backdropBlur(20)
            .border({ width: 0.5, color: this.theme.borderGlass })

            // ============ 在线用户数 ============
            Column() {
              Row() {
                Text('👥 在线用户')
                  .fontSize(13)
                  .fontColor(this.theme.textPrimary)
                  .fontWeight(FontWeight.Medium)

                Blank()

                Text(`${this.onlineClientCount}`)
                  .fontSize(22)
                  .fontColor(this.theme.primary)
                  .fontWeight(FontWeight.Bold)
                  .fontFamily('monospace')

                Text(' 台设备')
                  .fontSize(12)
                  .fontColor(this.theme.textSecondary)
                  .margin({ left: 4 })
              }
              .width('100%')

              if (this.onlineClientCount === 0) {
                Text('暂无在线设备')
                  .fontSize(11)
                  .fontColor(this.theme.textTertiary)
                  .margin({ top: 4 })
              }
            }
            .width('100%')
            .padding(10)
            .borderRadius(12)
            .margin({ top: 10 })
            .backgroundColor(this.theme.bgCard)
            .backdropBlur(20)
            .border({ width: 0.5, color: this.theme.borderGlass })
            Column() {
              Text('💾 磁盘使用')
                .fontSize(14)
                .fontColor(this.theme.textPrimary)
                .fontWeight(FontWeight.Medium)
                .margin({ bottom: 12 })

              if (this.mountPoints.length === 0) {
                Text('暂无挂载点数据')
                  .fontSize(11)
                  .fontColor(this.theme.textTertiary)
              } else {
                ForEach(this.mountPoints, (mp: MountPoint, idx: number) => {
                  Column() {
                    Row() {
                      Text(mp.mountPoint)
                        .fontSize(13)
                        .fontColor(this.theme.textPrimary)
                        .fontWeight(FontWeight.Medium)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .layoutWeight(1)
                      Text(`${mp.usedPercent.toFixed(1)}%`)
                        .fontSize(13)
                        .fontColor(this.getCpuColor(mp.usedPercent))
                        .fontWeight(FontWeight.Bold)
                    }
                    .width('100%')

                    Row() {
                      Text(`${FormatUtils.formatBytes(mp.used)} / ${FormatUtils.formatBytes(mp.size)}`)
                        .fontSize(11)
                        .fontColor(this.theme.textTertiary)
                      Blank()
                      Text(`可用 ${FormatUtils.formatBytes(mp.available)}`)
                        .fontSize(11)
                        .fontColor(this.theme.textSecondary)
                    }
                    .width('100%')
                    .margin({ top: 2 })

                    Stack() {
                      Row()
                        .width('100%')
                        .height(4)
                        .borderRadius(2)
                        .backgroundColor('rgba(255,255,255,0.1)')
                      Row()
                        .width(`${Math.max(0, Math.min(100, mp.usedPercent))}%`)
                        .height(4)
                        .borderRadius(2)
                        .linearGradient({
                          angle: 90,
                          colors: [
                            [this.getCpuColor(mp.usedPercent), 0],
                            [this.getCpuColor(mp.usedPercent) + '44', 1]
                          ]
                        })
                    }
                    .width('100%')
                    .alignContent(Alignment.End)
                    .margin({ top: 8 })
                  }
                  .width('100%')
                  .padding({ top: idx > 0 ? 10 : 0, bottom: idx < this.mountPoints.length - 1 ? 10 : 0 })
                  .border(idx < this.mountPoints.length - 1 ? { width: { bottom: 0.3 }, color: this.theme.borderGlass } : {})
                }, (item: MountPoint): string => item.mountPoint)
              }
            }
            .width('100%')
            .padding(14)
            .borderRadius(18)
            .margin({ top: 12 })
            .backgroundColor(this.theme.bgCard)
            .backdropBlur(20)
            .border({ width: 0.5, color: this.theme.borderGlass })
          }
          .width('100%')
          .padding({ left: 12, right: 12, bottom: 130 })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .onScroll((_x: number, y: number) => {
          const diff = y - this.lastScrollY
          this.lastScrollY = y
          if (diff > 10 && y > 120) {
            AppState.getInstance().hideNav()
          } else if (diff < -10 && y < 80) {
            AppState.getInstance().showNav()
          }
        })
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder NetInterfaceRow(iface: NetworkInterface) {
    Row() {
      Circle()
        .width(8)
        .height(8)
        .foregroundColor(iface.status === 'up' ? this.theme.success : this.theme.textTertiary)
        .margin({ right: 6 })
      Text(iface.ipAddress || '0.0.0.0')
        .fontSize(14)
        .fontColor(this.theme.primary)
        .fontWeight(FontWeight.Bold)
        .fontFamily('monospace')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .margin({ bottom: 8 })

    if (iface.macAddress) {
      Row() {
        Text('MAC  ')
          .fontSize(11)
          .fontColor(this.theme.textTertiary)
        Text(iface.macAddress)
          .fontSize(11)
          .fontColor(this.theme.textSecondary)
          .fontFamily('monospace')
      }
      .width('100%')
      .margin({ top: 2 })
    }

    if (iface.gateway || iface.mtu > 0) {
      Row() {
        if (iface.gateway) {
          Text(`网关 ${iface.gateway}`)
            .fontSize(11)
            .fontColor(this.theme.textTertiary)
        }
        if (iface.gateway && iface.mtu > 0) {
          Text('  ·  ')
            .fontSize(11)
            .fontColor(this.theme.textTertiary)
        }
        Text(`MTU ${iface.mtu}`)
          .fontSize(11)
          .fontColor(this.theme.textTertiary)
      }
      .width('100%')
      .margin({ top: 2 })
    }

    if (iface.rxBytes > 0 || iface.txBytes > 0) {
      Row() {
        Text(`↓ ${FormatUtils.formatBytes(iface.rxBytes)}`)
          .fontSize(11)
          .fontColor('#00E676')
        Text(`  ↑ ${FormatUtils.formatBytes(iface.txBytes)}`)
          .fontSize(11)
          .fontColor('#448AFF')
      }
      .width('100%')
      .margin({ top: 4 })
    }
  }

  @Builder infoRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(11)
        .fontColor(this.theme.textSecondary)
        .width(60)
      Text(value)
        .fontSize(11)
        .fontColor(this.theme.textPrimary)
        .fontWeight(FontWeight.Medium)
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
    .border({ width: { bottom: 0.3 }, color: this.theme.borderGlass })
  }
}
