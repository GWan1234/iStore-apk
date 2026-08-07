/**
 * TopologyPage - 网络拓扑图
 * 可视化设备连接关系：路由器在中心，无线设备（下半区）/ 有线设备（上半区）围绕分布
 */
import { AppState } from '../../common/store/AppState'
import { ThemePalette, DARK_THEME } from '../../common/theme/ThemeColors'
import { ConnectedDevice } from '../../models/Models'
import { ApiService } from '../../api/ApiService'
import { window } from '@kit.ArkUI'

@Entry
@Component
struct TopologyPage {
  @State isDark: boolean = true
  @State theme: ThemePalette = DARK_THEME
  @State topSafeArea: number = 44
  @State isLoading: boolean = true
  @State errorText: string = ''
  @State devices: ConnectedDevice[] = []
  @State wifiMacs: string[] = []
  private canvasCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true))
  private canvasW: number = 360
  private canvasH: number = 420
  private deviceName: string = '路由器'

  aboutToAppear(): void {
    this.isDark = AppState.getInstance().isDarkMode
    this.theme = AppState.getInstance().getTheme()
    AppState.getInstance().onThemeChange(() => {
      this.isDark = AppState.getInstance().isDarkMode
      this.theme = AppState.getInstance().getTheme()
      this.draw()
    })
    const device = AppState.getInstance().getActiveDevice()
    this.deviceName = device ? (device.label || device.host) : '路由器'
    this.loadTopSafeArea()
    this.loadData()
  }

  loadTopSafeArea(): void {
    try {
      const hostCtx = this.getUIContext().getHostContext()
      if (hostCtx) {
        window.getLastWindow(hostCtx as Context).then((win: window.Window) => {
          const avoidArea: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM)
          const h: number = px2vp(avoidArea.topRect.height)
          if (h > 0) {
            this.topSafeArea = h
          }
        }).catch(() => {})
      }
    } catch (e) {}
  }

  /** 加载设备与无线客户端（区分有线/无线） */
  async loadData(): Promise<void> {
    this.isLoading = true
    this.errorText = ''
    try {
      const api = new ApiService()
      const devs: ConnectedDevice[] = await api.fetchConnectedDevices()
      const wifiClients = await api.fetchWifiClients()
      const macs: string[] = []
      for (let i = 0; i < wifiClients.length; i++) {
        macs.push(wifiClients[i].mac.toUpperCase())
      }
      this.wifiMacs = macs
      this.devices = devs
    } catch (e) {
      this.errorText = '加载设备信息失败'
    }
    this.isLoading = false
    this.draw()
  }

  isWifiDevice(dev: ConnectedDevice): boolean {
    const m: string = dev.mac.toUpperCase()
    return this.wifiMacs.indexOf(m) >= 0
  }

  /** 绘制拓扑图（中心路由器 + 无线/有线半圆分布） */
  draw(): void {
    const ctx: CanvasRenderingContext2D = this.canvasCtx
    const w: number = this.canvasW
    const h: number = this.canvasH
    const cx: number = w / 2
    const cy: number = h / 2

    ctx.clearRect(0, 0, w, h)

    // 无线设备（下半区）与有线设备（上半区）分组
    const wifiDevs: ConnectedDevice[] = []
    const wiredDevs: ConnectedDevice[] = []
    for (let i = 0; i < this.devices.length; i++) {
      const d: ConnectedDevice = this.devices[i]
      if (!d.isOnline) continue
      if (this.isWifiDevice(d)) {
        wifiDevs.push(d)
      } else {
        wiredDevs.push(d)
      }
    }
    const showWifi: ConnectedDevice[] = wifiDevs.slice(0, 12)
    const showWired: ConnectedDevice[] = wiredDevs.slice(0, 12)

    // ---- 连线（先画线，节点覆盖在上面）----
    ctx.lineWidth = 1.2
    ctx.strokeStyle = this.theme.borderGlassFocus

    const wifiCount: number = showWifi.length
    for (let i = 0; i < wifiCount; i++) {
      const a: number = Math.PI + (i + 1) * Math.PI / (wifiCount + 1)  // 180°~360°
      const r: number = 150
      const x: number = cx + Math.cos(a) * r
      const y: number = cy + Math.sin(a) * r
      ctx.beginPath()
      ctx.moveTo(cx, cy - 10)
      ctx.lineTo(x, y)
      ctx.stroke()
    }
    const wiredCount: number = showWired.length
    for (let i = 0; i < wiredCount; i++) {
      const a: number = (i + 1) * Math.PI / (wiredCount + 1)  // 0°~180°
      const r: number = 150
      const x: number = cx + Math.cos(a) * r
      const y: number = cy - Math.sin(a) * r
      ctx.beginPath()
      ctx.moveTo(cx, cy - 10)
      ctx.lineTo(x, y)
      ctx.stroke()
    }

    // ---- 中心路由器节点 ----
    ctx.beginPath()
    ctx.arc(cx, cy, 34, 0, Math.PI * 2)
    ctx.fillStyle = this.theme.primary
    ctx.fill()
    ctx.beginPath()
    ctx.arc(cx, cy, 27, 0, Math.PI * 2)
    ctx.fillStyle = this.isDark ? '#0A0E27' : '#FFFFFF'
    ctx.fill()
    ctx.fillStyle = this.theme.primary
    ctx.font = '22vp sans-serif'
    ctx.textAlign = 'center'
    ctx.textBaseline = 'middle'
    ctx.fillText('📡', cx, cy)
    // 设备名
    ctx.fillStyle = this.theme.textPrimary
    ctx.font = '12vp sans-serif'
    ctx.fillText(this.deviceName, cx, cy + 52)

    // ---- 设备节点 ----
    ctx.font = '10vp sans-serif'
    const drawNode = (dev: ConnectedDevice, x: number, y: number, isWifi: boolean): void => {
      ctx.beginPath()
      ctx.arc(x, y, 17, 0, Math.PI * 2)
      ctx.fillStyle = isWifi ? '#1D9E75' : '#185FA5'
      ctx.fill()
      ctx.fillStyle = '#FFFFFF'
      ctx.font = '9vp sans-serif'
      ctx.fillText(dev.hostname || '设备', x, y)
      // 名称标签（节点下方）
      ctx.fillStyle = this.theme.textSecondary
      ctx.font = '9vp sans-serif'
      const label: string = (dev.hostname || dev.mac).length > 6
        ? (dev.hostname || dev.mac).substring(0, 6) : (dev.hostname || dev.mac)
      ctx.fillText(label, x, y + 28)
    }

    for (let i = 0; i < wifiCount; i++) {
      const a: number = Math.PI + (i + 1) * Math.PI / (wifiCount + 1)
      const r: number = 150
      drawNode(showWifi[i], cx + Math.cos(a) * r, cy + Math.sin(a) * r, true)
    }
    for (let i = 0; i < wiredCount; i++) {
      const a: number = (i + 1) * Math.PI / (wiredCount + 1)
      const r: number = 150
      drawNode(showWired[i], cx - Math.cos(a) * r, cy - Math.sin(a) * r, false)
    }

    // ---- 图例 ----
    ctx.fillStyle = '#1D9E75'
    ctx.font = '10vp sans-serif'
    ctx.textAlign = 'left'
    ctx.fillText('● 无线设备', 20, h - 18)
    ctx.fillStyle = '#185FA5'
    ctx.fillText('● 有线设备', 120, h - 18)
    ctx.fillStyle = this.theme.textTertiary
    ctx.fillText(`共 ${this.devices.length} 台在线`, w - 110, h - 18)
  }

  build() {
    Column() {
      // 标题栏
      Row() {
        Row() {
          Text('←')
            .fontSize(18)
            .fontColor(this.theme.primary)
          Text(' 网络拓扑')
            .fontSize(16)
            .fontColor(this.theme.textPrimary)
            .fontWeight(FontWeight.Medium)
        }
        .padding({ left: 12, right: 16, top: 6, bottom: 6 })
        .borderRadius(100)
        .backgroundColor(this.theme.bgCard)
        .border({ width: 0.5, color: this.theme.borderGlass })
        .onClick(() => {
          this.getUIContext().getRouter().back()
        })
        Blank()
        Text('↻ 刷新')
          .fontSize(12).fontColor(this.theme.primary)
          .padding({ left: 14, right: 14, top: 7, bottom: 7 })
          .borderRadius(16)
          .backgroundColor('rgba(68,138,255,0.1)')
          .onClick(() => { this.loadData() })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: this.topSafeArea + 4, bottom: 8 })

      if (this.isLoading) {
        Column() {
          LoadingProgress().width(32).height(32).color(this.theme.primary)
          Text('加载中...').fontSize(13).fontColor(this.theme.textTertiary).margin({ top: 12 })
        }
        .width('100%').padding(40).alignItems(HorizontalAlign.Center).margin({ top: 60 })
      } else if (this.devices.length === 0) {
        Column() {
          Text('暂无在线设备')
            .fontSize(13).fontColor(this.theme.textTertiary)
          if (this.errorText) {
            Text(this.errorText)
              .fontSize(12).fontColor(this.theme.warning).margin({ top: 8 })
          }
        }
        .width('100%').alignItems(HorizontalAlign.Center).margin({ top: 120 })
      } else {
        // 拓扑画布
        Canvas(this.canvasCtx)
          .width('100%')
          .height(440)
          .onReady(() => {
            this.canvasW = 360
            this.canvasH = 440
            this.draw()
          })
          .backgroundColor('transparent')

        // 拓扑说明
        Column() {
          Text('📶 绿色节点 = 无线连接（WiFi）')
            .fontSize(11).fontColor(this.theme.textSecondary)
          Text('🔌 蓝色节点 = 有线连接（网线）')
            .fontSize(11).fontColor(this.theme.textSecondary).margin({ top: 4 })
          Text('最多展示前 12 台无线 + 12 台有线设备')
            .fontSize(10).fontColor(this.theme.textTertiary).margin({ top: 4 })
        }
        .width('100%')
        .padding(16)
        .borderRadius(14)
        .margin({ left: 16, right: 16, top: 8 })
        .backgroundColor(this.theme.bgCard)
        .backdropBlur(20)
        .border({ width: 0.5, color: this.theme.borderGlass })
      }
      Blank()
    }
    .width('100%')
    .height('100%')
    .linearGradient({
      angle: 180,
      colors: this.isDark
        ? [['#0A0E27', 0], ['#121637', 0.5], ['#0A0E27', 1]]
        : [['#E8ECF1', 0], ['#F5F7FA', 0.5], ['#E8ECF1', 1]]
    })
  }
}
