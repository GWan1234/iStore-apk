/**
 * NotifySettingsPage - 智能通知设置页
 * 开关：总开关 / 断网告警 / 新设备接入提醒
 * 请求系统通知权限，说明检测机制
 */
import { notificationManager } from '@kit.NotificationKit'
import { window } from '@kit.ArkUI'
import { AppState } from '../../common/store/AppState'
import { LIGHT_THEME, ThemePalette } from '../../common/theme/ThemeColors'
import { NotifyStore } from '../../common/store/NotifyStore'
import { hilog } from '@kit.PerformanceAnalysisKit'

@Entry
@Component
struct NotifySettingsPage {
  @State theme: ThemePalette = LIGHT_THEME
  @State topSafeArea: number = 44  // 状态栏高度（默认 44vp）
  @State masterEnabled: boolean = false
  @State offlineAlert: boolean = false
  @State newDeviceAlert: boolean = false
  @State notifyEnabled: boolean = true  // 系统通知权限
  private store: NotifyStore = NotifyStore.getInstance()

  aboutToAppear(): void {
this.theme = AppState.getInstance().getTheme()
        const hostCtx = this.getUIContext().getHostContext()
    if (hostCtx) {
      this.store.init(hostCtx as Context)
    }
    this.masterEnabled = this.store.isEnabled()
    this.offlineAlert = this.store.isOfflineAlertOn()
    this.newDeviceAlert = this.store.isNewDeviceAlertOn()
    this.checkNotifyPermission()
    // 获取状态栏高度（避免标题栏被遮挡）
    this.loadTopSafeArea()
  }

  /** 获取状态栏高度 */
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
        }).catch(() => { /* 保持默认值 */ })
      }
    } catch (e) {
      hilog.error(0x0001, 'NotifySettingsPage', `loadTopSafeArea err: ${JSON.stringify(e)}`)
    }
  }

  /** 检查系统通知权限 */
  checkNotifyPermission(): void {
    try {
      this.notifyEnabled = notificationManager.isNotificationEnabledSync()
    } catch (e) {
      hilog.error(0x0001, 'NotifySettingsPage', `isNotificationEnabledSync err: ${JSON.stringify(e)}`)
    }
  }

  /** 请求通知权限 */
  async requestNotifyPermission(): Promise<void> {
    try {
      await notificationManager.requestEnableNotification()
      this.checkNotifyPermission()
    } catch (e) {
      hilog.error(0x0001, 'NotifySettingsPage', `requestEnableNotification err: ${JSON.stringify(e)}`)
    }
  }

  @Builder
  switchRow(title: string, desc: string, checked: boolean, tag: number) {
    Row() {
      Column() {
        Text(title)
          .fontSize(15)
          .fontColor(this.theme.textPrimary)
          .fontWeight(FontWeight.Medium)
        Text(desc)
          .fontSize(11)
          .fontColor(this.theme.textTertiary)
          .margin({ top: 3 })
          .lineHeight(15)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: checked })
        .selectedColor('#448AFF')
        .onChange((v: boolean) => {
          // tag 分发：0=总开关 1=断网告警 2=新设备提醒
          if (tag === 0) {
            this.masterEnabled = v
            this.store.setEnabled(v)
          } else if (tag === 1) {
            this.offlineAlert = v
            this.store.setOfflineAlert(v)
          } else {
            this.newDeviceAlert = v
            this.store.setNewDeviceAlert(v)
          }
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .backgroundColor(this.theme.bgCard)
    .backdropBlur(20)
    .border({ width: 0.5, color: this.theme.borderGlass })
    .borderRadius(14)
  }

  @Builder
  sectionTitle(title: string) {
    Text(title)
      .fontSize(13)
      .fontColor(this.theme.textSecondary)
      .fontWeight(FontWeight.Medium)
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 6 })
  }

  build() {
    Column() {
      // 标题栏
      Row() {
        Row() {
          Text(' 智能通知')
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
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: this.topSafeArea + 4, bottom: 8 })

      Scroll() {
        Column() {
          // 系统通知权限提示
          if (!this.notifyEnabled) {
            Row() {
              Column() {
                Text('🔕 通知权限未开启')
                  .fontSize(14)
                  .fontColor(this.theme.warning)
                  .fontWeight(FontWeight.Medium)
                Text('开启后才能收到断网告警和新设备提醒')
                  .fontSize(11)
                  .fontColor(this.theme.textTertiary)
                  .margin({ top: 3 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Text('去开启')
                .fontSize(12)
                .fontColor(Color.White)
                .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                .borderRadius(14)
                .backgroundColor(this.theme.primary)
                .onClick(() => {
                  this.requestNotifyPermission()
                })
            }
            .width('100%')
            .padding(14)
            .borderRadius(14)
            .backgroundColor('rgba(255,152,0,0.1)')
            .border({ width: 0.5, color: 'rgba(255,152,0,0.3)' })
            .margin({ top: 8, bottom: 4 })
          }

          this.sectionTitle('推送开关')
          // 总开关
          this.switchRow('智能通知推送', '开启后检测路由器状态变化并推送通知', this.masterEnabled, 0)

          Column() {
            // 断网告警
            this.switchRow('断网告警', '路由器离线/恢复时通知你', this.offlineAlert, 1)
            // 新设备接入提醒
            this.switchRow('新设备接入提醒', '有新设备连接 WiFi 时通知你（首次建立基线不打扰）',
              this.newDeviceAlert, 2)
          }
          .margin({ top: 8 })
          .backgroundColor(this.theme.bgCard)
          .backdropBlur(20)
          .border({ width: 0.5, color: this.theme.borderGlass })
          .borderRadius(14)
          .clip(true)

          this.sectionTitle('检测说明')
          Column() {
            Row() {
              Text('🔄')
                .fontSize(16)
              Column() {
                Text('每 60 秒检测一次')
                  .fontSize(13)
                  .fontColor(this.theme.textPrimary)
                  .fontWeight(FontWeight.Medium)
                Text('App 运行时自动检测路由器在线状态和设备列表变化')
                  .fontSize(11)
                  .fontColor(this.theme.textTertiary)
                  .margin({ top: 2 })
                  .lineHeight(15)
              }
              .alignItems(HorizontalAlign.Start)
              .margin({ left: 10 })
              .layoutWeight(1)
            }
            .width('100%')
            .padding(14)

            Divider().color(this.theme.borderGlass)

            Row() {
              Text('🔒')
                .fontSize(16)
              Column() {
                Text('数据不出本机')
                  .fontSize(13)
                  .fontColor(this.theme.textPrimary)
                  .fontWeight(FontWeight.Medium)
                Text('检测仅在手机与你的路由器之间进行，不上传任何服务器')
                  .fontSize(11)
                  .fontColor(this.theme.textTertiary)
                  .margin({ top: 2 })
                  .lineHeight(15)
              }
              .alignItems(HorizontalAlign.Start)
              .margin({ left: 10 })
              .layoutWeight(1)
            }
            .width('100%')
            .padding(14)
          }
          .width('100%')
          .backgroundColor(this.theme.bgCard)
          .backdropBlur(20)
          .border({ width: 0.5, color: this.theme.borderGlass })
          .borderRadius(14)
          .clip(true)

          // 底部留白
          Row().width('100%').height(40)
        }
        .width('100%')
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .linearGradient({
      angle: 135,
      colors: [['#F1BCA8', 0], ['#F3D6C8', 0.5], ['#F5F1EE', 1]]
    })
  }
}
