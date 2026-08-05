/**
 * 登录页面
 * 功能：
 * - 管理已保存的设备列表（增删改查，持久化存储）
 * - 连接指定的路由器设备（支持超时处理）
 * - 主题切换（深色/浅色模式）
 * - 连接成功后跳转到主仪表盘（MainPage）
 */
import { AppState } from '../../common/store/AppState'
import { SavedDevice } from '../../common/store/DeviceStore'
import { ConnectionConfig } from '../../models/Models'
import { ThemePalette, DARK_THEME } from '../../common/theme/ThemeColors'
import { common } from '@kit.AbilityKit'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { pasteboard, deviceInfo } from '@kit.BasicServicesKit'
import { window } from '@kit.ArkUI'

@Entry
@Component
struct LoginPage {
  // ========== 表单状态 ==========
  @State host: string = ''
  @State port: string = '80'
  @State username: string = 'root'
  @State password: string = ''
  @State label: string = ''
  @State isConnecting: boolean = false
  @State isSaving: boolean = false
  @State errorMessage: string = ''
  @State successMessage: string = ''
  @State showPassword: boolean = false
  @State savedDevices: SavedDevice[] = []
  @State showAddForm: boolean = false
  @State editingId: string = ''
  @State connectingId: string = ''
  @State formVersion: number = 0
  @State isDark: boolean = true
  @State theme: ThemePalette = DARK_THEME
  @State topSafeArea: number = 44  // 状态栏高度（默认 44vp，覆盖大部分设备）
  private appState: AppState = AppState.getInstance()
  private connectTimerId: number = -1  // 连接超时定时器 ID

  /** 页面初始化：加载设备列表，检查是否已有活动连接 */
  async aboutToAppear(): Promise<void> {
    const ctx: common.Context = this.getUIContext().getHostContext() as common.Context
    await this.appState.init(ctx)
    this.savedDevices = this.appState.devices
    this.isDark = this.appState.isDarkMode
    this.theme = this.appState.getTheme()

    // 获取状态栏高度（避免顶部按钮被遮挡）
    try {
      const hostCtx: common.Context = this.getUIContext().getHostContext() as common.Context
      if (hostCtx) {
        const win: window.Window = await window.getLastWindow(hostCtx)
        const avoidArea: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM)
        const h: number = px2vp(avoidArea.topRect.height)
        if (h > 0) {
          this.topSafeArea = h
        }
      }
    } catch (e) {
      // 保持默认 44vp
    }

    this.appState.onThemeChange(() => {
      this.isDark = this.appState.isDarkMode
      this.theme = this.appState.getTheme()
    })

    // 如果已有活动连接，直接跳转到仪表盘
    if (this.appState.getActiveDeviceId()) {
      try {
        this.getUIContext().getRouter().replaceUrl({ url: 'pages/dashboard/MainPage' })
      } catch (e) {
        hilog.error(0x0001, 'LoginPage', `replaceUrl failed: ${e}`)
      }
    }
  }

  /** 从表单输入构造连接配置 */
  getConfig(): ConnectionConfig {
    const host: string = this.host.trim()
    const port: string = this.port || '80'
    return {
      host: host,
      port: Number(port) || 80,
      token: '',
      useHttps: false,
      username: this.username.trim(),
      password: this.password
    }
  }

  /** 保存/更新设备到持久化存储 */
  async doSave(): Promise<void> {
    const host: string = this.host.trim()
    if (!host) {
      this.errorMessage = '请输入设备地址'
      return
    }

    this.isSaving = true
    this.errorMessage = ''
    this.successMessage = ''

    const config: ConnectionConfig = this.getConfig()
    const deviceLabel: string = this.label.trim() || config.host

    try {
      let device: SavedDevice
      if (this.editingId) {
        const existing: SavedDevice | undefined = this.appState.getDeviceById(this.editingId)
        // 编辑旧 Token 设备时，若未填写密码则保留原 Token（避免破坏旧连接）
        const keepLegacyToken: boolean = !this.password && !!existing && !!existing.token
        device = {
          id: this.editingId,
          label: deviceLabel,
          host: config.host,
          port: String(config.port),
          token: keepLegacyToken ? existing!.token : '',
          useHttps: false,
          lastConnected: existing ? existing.lastConnected : Date.now(),
          version: existing ? existing.version : 0,
          username: keepLegacyToken ? '' : config.username!,
          password: keepLegacyToken ? '' : config.password!
        }
        this.editingId = ''
      } else {
        const rand: string = Math.random().toString(36).substring(2, 10)
        device = {
          id: `${config.host}_${rand}`,
          label: deviceLabel,
          host: config.host,
          port: String(config.port),
          token: '',
          useHttps: false,
          lastConnected: Date.now(),
          version: 0,
          username: config.username!,
          password: config.password!
        }
      }

      await this.appState.saveDevice(device)
      this.savedDevices = this.appState.devices
      this.successMessage = '设备已保存'
      this.isSaving = false
      this.resetForm()

      setTimeout(() => { this.successMessage = '' }, 2000)
    } catch (e) {
      this.isSaving = false
      this.errorMessage = '保存失败'
    }
  }

  /** 连接设备并进入主页面，SSH 自动授权约 3~5 秒 */
  async connectAndEnter(savedDevice?: SavedDevice): Promise<void> {
    // 优先使用已保存设备的参数，否则使用表单输入值
    const host: string = savedDevice ? savedDevice.host : this.host.trim()
    const port: string = savedDevice ? savedDevice.port : this.port
    const token: string = savedDevice ? savedDevice.token : ''
    const username: string = savedDevice ? (savedDevice.username || '') : this.username.trim()
    const password: string = savedDevice ? (savedDevice.password || '') : this.password
    const config: ConnectionConfig = { host, port: Number(port) || 80, token, useHttps: false, username, password }

    if (!host) {
      this.errorMessage = '请输入设备地址'
      return
    }
    if (!username && !token) {
      this.errorMessage = '请输入用户名和密码'
      return
    }

    this.isConnecting = true
    this.errorMessage = ''
    this.connectingId = savedDevice ? savedDevice.id : ''
    let timedOut: boolean = false

    // 超时兜底（仅真正无响应时触发；正常设备 3~5s，QWRT 自动授权 ~10~60s）
    this.connectTimerId = setTimeout(() => {
      if (this.isConnecting) {
        timedOut = true
        this.isConnecting = false
        this.connectingId = ''
        this.errorMessage = '连接超时，请检查设备地址和网络'
        setTimeout(() => { this.errorMessage = '' }, 4000)
      }
    }, 30000)

    try {
      // 如果没有保存设备，先创建新设备并持久化
      if (!savedDevice) {
        const device: SavedDevice = {
          id: `${config.host}_${Math.random().toString(36).substring(2, 10)}`,
          label: config.host,
          host: config.host,
          port: String(config.port),
          token: config.token,
          useHttps: false,
          lastConnected: Date.now(),
          version: 0,
          username: config.username!,
          password: config.password!
        }
        await this.appState.saveDevice(device)
        savedDevice = device
      }

      // 执行实际连接
      const connected: boolean = await this.appState.connectToDevice(savedDevice.id)

      // 超时后不再处理结果
      if (timedOut) return
      if (this.connectTimerId !== -1) {
        clearTimeout(this.connectTimerId)
        this.connectTimerId = -1
      }

      if (connected) {
        // 连接成功，跳转到主仪表盘
        this.isConnecting = false
        this.connectingId = ''
        try {
          this.getUIContext().getRouter().pushUrl({ url: 'pages/dashboard/MainPage' })
        } catch (e) {
          hilog.error(0x0001, 'LoginPage', `pushUrl failed: ${e}`)
        }
      } else {
        // 连接失败，显示具体错误信息
        this.isConnecting = false
        this.connectingId = ''
        const lastErr: string = this.appState.getLastError()
        if (lastErr) {
          this.errorMessage = lastErr
        } else {
          this.errorMessage = '连接失败，请检查地址和账号密码'
        }
        setTimeout(() => { this.errorMessage = '' }, 10000)
      }
    } catch (netErr) {
      // 网络异常处理
      if (timedOut) return
      if (this.connectTimerId !== -1) {
        clearTimeout(this.connectTimerId)
        this.connectTimerId = -1
      }
      this.isConnecting = false
      this.connectingId = ''
      this.errorMessage = '网络错误，请检查设备地址和网络连接'
      setTimeout(() => { this.errorMessage = '' }, 4000)
    }
  }

  resetForm(): void {
    this.host = ''
    this.port = '80'
    this.username = 'root'
    this.password = ''
    this.label = ''
    this.editingId = ''
    this.errorMessage = ''
    this.formVersion = 0
  }

  fillForm(device: SavedDevice): void {
    this.host = device.host
    this.port = device.port
    this.username = device.username || 'root'
    this.password = device.password || ''
    this.label = device.label
    this.editingId = device.id
    this.formVersion++
    this.errorMessage = ''
    this.showAddForm = true
  }

  async deleteDevice(id: string): Promise<void> {
    await this.appState.removeDevice(id)
    this.savedDevices = this.appState.devices
  }

  toggleAddForm(): void {
    this.showAddForm = !this.showAddForm
    if (this.showAddForm) {
      this.resetForm()
      this.errorMessage = ''
    }
  }

  shareDevice(device: SavedDevice): void {
    try {
      const js = JSON.stringify({
        host: device.host,
        port: device.port,
        username: device.username || '',
        password: device.password || '',
        token: device.token || '',
        label: device.label || ''
      })
      const pb = pasteboard.getSystemPasteboard()
      pb.setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, js))
      this.successMessage = '已复制，可在其他设备粘贴导入'
      setTimeout(() => { this.successMessage = '' }, 2500)
    } catch (e) {
      this.errorMessage = '复制失败'
    }
  }

  async importDevice(): Promise<void> {
    try {
      const pb: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard()
      const pasteData: pasteboard.PasteData = await pb.getData()
      const record: pasteboard.PasteDataRecord = pasteData.getRecord(0)
      if (!record) {
        this.errorMessage = '剪贴板为空'
        return
      }
      const text: string = record.plainText
      if (!text) {
        this.errorMessage = '剪贴板为空'
        return
      }
      const json: Record<string, string> = JSON.parse(text) as Record<string, string>
      if (!json['host']) {
        this.errorMessage = '缺少设备地址'
        return
      }
      const label: string = json['label'] || json['host']
      const newId: string = `import_${Date.now()}_${json['host']}`
      const device: SavedDevice = {
        id: newId,
        host: json['host'],
        port: String(json['port'] || '80'),
        token: json['token'] || '',
        useHttps: false,
        label: label,
        version: 0,
        lastConnected: 0,
        username: json['username'] || '',
        password: json['password'] || ''
      }
      await this.appState.saveDevice(device)
      this.savedDevices = this.appState.devices
      this.successMessage = `已导入: ${label}`
      setTimeout(() => { this.successMessage = '' }, 2500)
    } catch (e) {
      this.errorMessage = '导入失败，请确认剪贴板内容有效'
    }
  }

  @Builder
  specBadge(text: string) {
    Text(text)
      .fontSize(10).fontColor(this.theme.textTertiary)
      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
      .borderRadius(8)
      .backgroundColor('rgba(128,128,255,0.08)')
      .border({ width: 0.5, color: 'rgba(128,128,255,0.2)' })
      .margin({ right: 6 })
  }

  build() {
    Stack() {
      Column() {
        Row() {
          Blank()
          Row() {
            Text(this.isDark ? '☀️' : '🌙').fontSize(20)
          }
          .width(40).height(40).borderRadius(20)
          .backgroundColor(this.theme.bgCard)
          .border({ width: 0.5, color: this.theme.borderGlass })
          .justifyContent(FlexAlign.Center)
          .onClick(() => {
            this.appState.toggleTheme()
          })
          .margin({ right: 16, top: this.topSafeArea + 4 })
        }
        .width('100%')

        Column() {
          Image($r('app.media.logo'))
            .width(80).height(80).borderRadius(20)
            .objectFit(ImageFit.Cover)
            .margin({ top: 24 })

          Text('iStore')
            .fontSize(40).fontColor(this.theme.textPrimary).fontWeight(FontWeight.Bold)
            .margin({ top: 16 })

          Text('路由器设备管理')
            .fontSize(14).fontColor(this.theme.textSecondary).margin({ top: 4 })
        }
        .alignItems(HorizontalAlign.Center)
        .margin({ bottom: 20 })

        // 本机信息卡片
        Column() {
          Row() {
            Image($r('app.media.device'))
              .width(40).height(40).objectFit(ImageFit.Contain)
              .margin({ right: 14 })

            Column() {
              Text(deviceInfo.productModel || deviceInfo.marketName || '本机')
                .fontSize(15).fontColor(this.theme.textPrimary).fontWeight(FontWeight.Medium)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(deviceInfo.manufacture || '本机信息')
                .fontSize(12).fontColor(this.theme.textSecondary).margin({ top: 2 })

              Row() {
                this.specBadge(`OS ${deviceInfo.distributionOSVersion || deviceInfo.osFullName || '-'}`)
                this.specBadge(`API ${deviceInfo.sdkApiVersion}`)
                if (deviceInfo.marketName && deviceInfo.marketName !== (deviceInfo.productModel || '')) {
                  this.specBadge(deviceInfo.marketName)
                }
              }.margin({ top: 6 })
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          }
          .width('100%').padding(20).borderRadius(20)
          .backgroundColor(this.theme.bgCard).backdropBlur(20)
          .border({ width: 0.5, color: this.theme.borderGlass })
        }
        .width('100%').padding({ left: 16, right: 16 }).margin({ bottom: 12 })

        Scroll() {
          Column() {
            if (this.savedDevices.length > 0) {
              Text('我的设备')
                .fontSize(12).fontColor(this.theme.textTertiary)
                .width('100%').padding({ left: 4, bottom: 8 })

              ForEach(this.savedDevices, (device: SavedDevice) => {
                Column() {
                  Row() {
                    Stack() {
                      Image($r('app.media.logo'))
                        .width(40).height(40).borderRadius(10)
                        .objectFit(ImageFit.Cover)
                        .opacity(this.connectingId === device.id ? 0.4 : 1)

                      if (this.connectingId === device.id) {
                        LoadingProgress().width(22).height(22).color(this.theme.primary)
                      }
                    }
                    .width(40).height(40)

                    Column() {
                      Text(device.label || device.host)
                        .fontSize(14).fontColor(this.theme.textPrimary).fontWeight(FontWeight.Medium)
                        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                      Row() {
                        Text(device.host)
                          .fontSize(10).fontColor(this.theme.textTertiary).margin({ right: 6 })
                        Text(`:${device.port}`)
                          .fontSize(10).fontColor(this.theme.textTertiary)
                        if (this.connectingId === device.id) {
                          Text(' · 连接中...')
                            .fontSize(10).fontColor(this.theme.primary)
                        }
                      }
                    }
                    .margin({ left: 10 }).alignItems(HorizontalAlign.Start).layoutWeight(1)

                    SymbolGlyph($r('sys.symbol.square_and_pencil'))
                      .fontSize(16).fontColor([this.theme.textTertiary]).padding(8)
                      .onClick(() => { this.fillForm(device) })

                    Text('📋')
                      .fontSize(16).fontColor(this.theme.textTertiary).padding(8)
                      .onClick(() => { this.shareDevice(device) })

                    SymbolGlyph($r('sys.symbol.trash'))
                      .fontSize(16).fontColor([this.theme.textTertiary]).padding(8)
                      .onClick(() => { this.deleteDevice(device.id) })
                  }
                  .width('100%')
                  .onClick(() => { this.connectAndEnter(device) })
                }
                .width('100%').padding(20).borderRadius(20).margin({ top: 16 })
                .backgroundColor(this.theme.bgCard).backdropBlur(20)
                .border({ width: 0.5, color: this.theme.borderGlass })
              }, (item: SavedDevice): string => `${item.id}_v${item.version}`)
            }

            Row() {
              Text(this.showAddForm ? '收起 ▲' : '+ 添加新设备')
                .fontSize(14).fontColor(this.theme.primary).fontWeight(FontWeight.Medium)
                .padding({ top: 12, bottom: 12 })
              Blank()
              Text('📥 导入设备')
                .fontSize(14).fontColor(this.theme.primary).fontWeight(FontWeight.Medium)
                .padding({ top: 12, bottom: 12, left: 16, right: 16 })
                .onClick(() => { this.importDevice() })
            }
            .width('100%').justifyContent(FlexAlign.Center)
            .onClick(() => { this.toggleAddForm() })
            .margin({ top: this.savedDevices.length > 0 ? 16 : 0 })

            if (this.showAddForm) {
              Column() {
                Row() {
                  TextInput({ placeholder: '设备名称（可选）', text: this.label })
                    .placeholderColor(this.theme.textTertiary).fontColor(this.theme.textPrimary)
                    .backgroundColor('transparent')
                    .onChange((v: string) => { this.label = v })
                    .layoutWeight(1).height(52)
                }
                .width('100%').height(52).borderRadius(24)
                .backgroundColor(this.theme.bgCard).backdropBlur(10)
                .border({ width: 0.5, color: this.theme.borderGlass })
                .padding({ left: 14, right: 14 }).margin({ bottom: 16 })

                Row() {
                  TextInput({ placeholder: 'IP 地址（如 192.168.1.1）', text: this.host })
                    .placeholderColor(this.theme.textTertiary).fontColor(this.theme.textPrimary)
                    .backgroundColor('transparent')
                    .onChange((v: string) => { this.host = v })
                    .layoutWeight(1).height(52)
                }
                .width('100%').height(52).borderRadius(24)
                .backgroundColor(this.theme.bgCard).backdropBlur(10)
                .border({ width: 0.5, color: this.theme.borderGlass })
                .padding({ left: 14, right: 14 }).margin({ bottom: 16 })

                Row() {
                  TextInput({ placeholder: '端口', text: this.port })
                    .placeholderColor(this.theme.textTertiary).fontColor(this.theme.textPrimary)
                    .backgroundColor('transparent').type(InputType.Number)
                    .onChange((v: string) => { this.port = v })
                    .width('30%').height(52)
                }
                .width('100%').height(52).borderRadius(24)
                .backgroundColor(this.theme.bgCard).backdropBlur(10)
                .border({ width: 0.5, color: this.theme.borderGlass })
                .padding({ left: 14, right: 14 }).margin({ bottom: 16 })

                Row() {
                  TextInput({ placeholder: '用户名（一般为 root）', text: this.username })
                    .placeholderColor(this.theme.textTertiary).fontColor(this.theme.textPrimary)
                    .backgroundColor('transparent')
                    .onChange((v: string) => { this.username = v })
                    .layoutWeight(1).height(52)
                }
                .width('100%').height(52).borderRadius(24)
                .backgroundColor(this.theme.bgCard)
                .border({ width: 0.5, color: this.theme.borderGlass })
                .padding({ left: 14, right: 14 }).margin({ bottom: 16 })

                Row() {
                  TextInput({ placeholder: '密码（路由器管理密码）', text: this.password })
                    .type(this.showPassword ? InputType.Normal : InputType.Password)
                    .showPasswordIcon(false)
                    .placeholderColor(this.theme.textTertiary).fontColor(this.theme.textPrimary)
                    .backgroundColor('transparent')
                    .onChange((v: string) => { this.password = v })
                    .layoutWeight(1).height(52)
                  Text(this.showPassword ? '◉' : '◎')
                    .fontSize(18).fontColor(this.theme.textSecondary).padding(8)
                    .onClick(() => { this.showPassword = !this.showPassword })
                }
                .width('100%').height(52).borderRadius(24)
                .backgroundColor(this.theme.bgCard)
                .border({ width: 0.5, color: this.theme.borderGlass })
                .padding({ left: 14, right: 8 }).margin({ bottom: 16 })

                Row() {
                  Button() {
                    Text('保存设备')
                      .fontSize(14).fontColor(this.theme.textPrimary)
                  }
                  .width('47%').height(52).borderRadius(26)
                  .backgroundColor(this.theme.bgCard)
                  .border({ width: 1, color: this.theme.borderGlass })
                  .enabled(!this.isSaving)
                  .onClick(() => { this.doSave() })

                  Button() {
                    Text('连接并进入')
                      .fontSize(14).fontColor('#FFFFFF').fontWeight(FontWeight.Medium)
                  }
                  .width('47%').height(52).borderRadius(26)
                  .linearGradient({ angle: 135, colors: [[this.theme.primary, 0], [this.theme.secondary, 1]] })
                  .enabled(!this.isConnecting && !this.isSaving)
                  .onClick(() => { this.connectAndEnter() })
                }
                .width('100%').justifyContent(FlexAlign.SpaceBetween)
              }
              .animation({ duration: 300, curve: Curve.FastOutSlowIn })
            }

            if (this.errorMessage) {
              Row() {
                Text('⚠ ' + this.errorMessage)
                  .fontSize(13).fontColor(this.theme.danger)
                  .layoutWeight(1)
              }
              .width('100%').padding({ left: 14, right: 14, top: 12, bottom: 12 })
              .borderRadius(12).margin({ top: 14 })
              .backgroundColor(this.isDark ? 'rgba(255, 82, 82, 0.1)' : 'rgba(255, 82, 82, 0.05)')
              .border({ width: 0.5, color: this.isDark ? 'rgba(255, 82, 82, 0.25)' : 'rgba(255, 82, 82, 0.15)' })
            }

            if (this.successMessage) {
              Text(this.successMessage)
                .fontSize(12).fontColor(this.theme.success)
                .width('100%').textAlign(TextAlign.Center)
                .margin({ top: 12, bottom: 4 })
            }
          }
          .width('100%').padding({ left: 20, right: 20, bottom: 40 })
        }
        .width('100%').layoutWeight(1).scrollBar(BarState.Off)
      }
      .width('100%').height('100%')
    }
    .width('100%').height('100%')
    .backgroundColor(this.isDark ? '#0A0E27' : '#E8ECF1')
  }
}
