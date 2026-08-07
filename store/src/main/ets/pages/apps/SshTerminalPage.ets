/**
 * SshTerminalPage - SSH 终端
 * 连接路由器 SSH（复用设备用户名/密码），执行命令查看输出
 * 终端风格：深色底 + 等宽字体 + 快捷命令
 */
import { AppState } from '../../common/store/AppState'
import { ThemePalette, DARK_THEME } from '../../common/theme/ThemeColors'
import { SshService } from '../../common/ssh/SshService'
import { SavedDevice } from '../../common/store/DeviceStore'
import { window } from '@kit.ArkUI'

/** 快捷命令 */
const QUICK_CMDS: string[] = [
  'top -n 1',
  'free -m',
  'df -h',
  'uptime',
  'cat /etc/openwrt_release',
  'iwinfo',
  'logread -l 20',
  'ps w',
  'ifconfig',
  'ls -la /tmp'
]

/** 命令执行记录 */
interface CmdRecord {
  cmd: string
  output: string
}

@Entry
@Component
struct SshTerminalPage {
  @State isDark: boolean = true
  @State theme: ThemePalette = DARK_THEME
  @State topSafeArea: number = 44
  @State connecting: boolean = true
  @State connected: boolean = false
  @State connError: string = ''
  @State records: CmdRecord[] = []
  @State inputText: string = ''
  @State running: boolean = false
  private ssh: SshService = SshService.getInstance()
  private listScroller: Scroller = new Scroller()

  aboutToAppear(): void {
    this.isDark = AppState.getInstance().isDarkMode
    this.theme = AppState.getInstance().getTheme()
    AppState.getInstance().onThemeChange(() => {
      this.isDark = AppState.getInstance().isDarkMode
      this.theme = AppState.getInstance().getTheme()
    })
    this.loadTopSafeArea()
    this.doConnect()
  }

  aboutToDisappear(): void {
    // 离开页面断开连接
    this.ssh.disconnect()
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

  /** 连接路由器 */
  async doConnect(): Promise<void> {
    this.connecting = true
    this.connError = ''
    const device: SavedDevice | undefined = AppState.getInstance().getActiveDevice()
    if (!device) {
      this.connecting = false
      this.connError = '未选择路由器设备'
      return
    }
    if (!device.username || !device.password) {
      this.connecting = false
      this.connError = '设备未配置 SSH 用户名/密码，请到登录页编辑设备补充'
      return
    }
    const ok: boolean = await this.ssh.connect(device)
    this.connecting = false
    if (ok) {
      this.connected = true
      this.records = [{
        cmd: '',
        output: `已连接 ${device.host}（SSH）\n输入命令开始，或点击下方快捷命令\n输入 help 查看用法`
      }]
    } else {
      this.connError = '连接失败：请确认路由器已开启 SSH（系统→管理→SSH 访问），且用户名密码正确'
    }
  }

  /** 执行命令 */
  runCommand(cmdText: string): void {
    const cmd: string = cmdText.trim()
    if (!cmd || this.running) return
    // 本地命令
    if (cmd === 'help') {
      this.records.push({
        cmd: 'help',
        output: '快捷命令：top / free -m / df -h / uptime / iwinfo / logread -l 20 / cat /etc/openwrt_release\n'
      })
      this.inputText = ''
      this.scrollToBottom()
      return
    }
    if (cmd === 'clear' || cmd === 'cls') {
      this.records = []
      this.inputText = ''
      return
    }
    this.inputText = ''
    this.running = true
    this.ssh.exec(cmd).then((out: string) => {
      this.records.push({ cmd: cmd, output: out })
      this.running = false
      this.scrollToBottom()
    }).catch(() => {
      this.records.push({ cmd: cmd, output: '执行异常' })
      this.running = false
    })
  }

  /** 滚动到底部 */
  private scrollToBottom(): void {
    try {
      setTimeout(() => {
        this.listScroller.scrollEdge(Edge.Bottom)
      }, 50)
    } catch (e) {}
  }

  /** 单条记录渲染 */
  @Builder
  recordItem(rec: CmdRecord) {
    Column() {
      if (rec.cmd) {
        Text(`$ ${rec.cmd}`)
          .fontSize(13)
          .fontColor('#00E676')
          .fontFamily('monospace')
          .width('100%')
      }
      Text(rec.output || '（无输出）')
        .fontSize(12)
        .fontColor('#D0D7DE')
        .fontFamily('monospace')
        .lineHeight(18)
        .width('100%')
        .margin({ top: rec.cmd ? 4 : 0 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 8 })
  }

  build() {
    Column() {
      // 标题栏
      Row() {
        Row() {
          Text('←')
            .fontSize(18)
            .fontColor(this.theme.primary)
          Text(' SSH 终端')
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
        if (this.connected) {
          Row() {
            Circle({ width: 6, height: 6 }).fill('#00C853')
            Text(` ${this.ssh.host()}`)
              .fontSize(11).fontColor(this.theme.success)
          }
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .borderRadius(10)
          .backgroundColor('rgba(0,200,83,0.1)')
        } else {
          Text('未连接')
            .fontSize(11).fontColor(this.theme.danger)
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: this.topSafeArea + 4, bottom: 8 })

      // 终端主体（深色）
      Column() {
        if (this.connecting) {
          Row() {
            LoadingProgress().width(16).height(16).color('#00E676')
            Text(' 正在连接 SSH…')
              .fontSize(12).fontColor('#8B949E')
              .margin({ left: 8 })
          }
          .width('100%').justifyContent(FlexAlign.Center).padding(30)
        } else if (!this.connected) {
          Column() {
            Text('⚠ SSH 未连接')
              .fontSize(13).fontColor('#FF5252')
            Text(this.connError)
              .fontSize(12).fontColor('#8B949E')
              .margin({ top: 8 })
              .lineHeight(18)
            Row() {
              Text('重新连接')
                .fontSize(12).fontColor('#FFFFFF')
                .padding({ left: 16, right: 16, top: 8, bottom: 8 })
                .borderRadius(12)
                .backgroundColor('#00E676')
                .margin({ top: 16 })
                .onClick(() => { this.doConnect() })
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          .padding(30)
        } else {
          // 输出区
          List({ scroller: this.listScroller, space: 2 }) {
            ForEach(this.records, (rec: CmdRecord, idx: number) => {
              ListItem() {
                this.recordItem(rec)
              }
            }, (rec: CmdRecord, idx: number): string => `${idx}_${rec.cmd}`)
          }
          .layoutWeight(1)
          .width('100%')
          .padding({ left: 12, right: 12, top: 4 })
          .scrollBar(BarState.Off)
          .align(Alignment.Top)
        }
      }
      .layoutWeight(1)
      .width('100%')
      .backgroundColor('#0D1117')
      .borderRadius(14)
      .margin({ left: 12, right: 12 })
      .clip(true)

      // 快捷命令
      Scroll() {
        Row({ space: 8 }) {
          ForEach(QUICK_CMDS, (c: string) => {
            Text(c)
              .fontSize(10)
              .fontColor('#00E676')
              .fontFamily('monospace')
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .borderRadius(10)
              .backgroundColor('rgba(0,230,118,0.1)')
              .border({ width: 0.5, color: 'rgba(0,230,118,0.3)' })
              .onClick(() => { this.runCommand(c) })
          }, (c: string): string => c)
        }
        .padding({ left: 12, right: 12, top: 8, bottom: 4 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')

      // 输入栏
      Row() {
        Text('$')
          .fontSize(14)
          .fontColor('#00E676')
          .fontFamily('monospace')
          .margin({ left: 12, right: 6 })
        TextInput({ placeholder: '输入命令，如 top', text: this.inputText })
          .placeholderColor('#6E7681')
          .fontColor('#D0D7DE')
          .fontFamily('monospace')
          .backgroundColor('#0D1117')
          .height(40)
          .layoutWeight(1)
          .onChange((v: string) => { this.inputText = v })
          .onSubmit(() => { this.runCommand(this.inputText) })
        Row() {
          Text(this.running ? '…' : '执行')
            .fontSize(12)
            .fontColor('#FFFFFF')
            .fontWeight(FontWeight.Medium)
        }
        .width(60)
        .height(40)
        .borderRadius(10)
        .backgroundColor('#00E676')
        .justifyContent(FlexAlign.Center)
        .margin({ left: 8, right: 12 })
        .opacity((this.running || !this.connected) ? 0.4 : 1)
        .onClick(() => { this.runCommand(this.inputText) })
      }
      .width('100%')
      .padding({ top: 6, bottom: 18 })
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
