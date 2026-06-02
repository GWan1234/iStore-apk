import { AppState } from '../../common/store/AppState'
import { ThemePalette, DARK_THEME } from '../../common/theme/ThemeColors'
import { ConnectedDevice, WirelessClient } from '../../models/Models'
import { FormatUtils } from '../../common/utils/FormatUtils'
import { ApiService } from '../../api/ApiService'
import { hilog } from '@kit.PerformanceAnalysisKit'

// ============================================================
// DeviceTab - 设备列表（DHCP客户端）
// ============================================================
@Component
export struct DeviceTab {
  @Prop theme: ThemePalette
  @State devices: ConnectedDevice[] = []
  @State isLoading: boolean = true
  @State errorText: string = ''
  @State searchText: string = ''
  @State subTab: number = 0
  @State wirelessClients: WirelessClient[] = []
  @State wirelessLoading: boolean = false
  private lastScrollY: number = 0
  aboutToAppear(): void {
    this.loadDevices()
    this.loadWirelessData()
  }

  async loadDevices(): Promise<void> {
    this.isLoading = true
    this.errorText = ''
    try {
      if (!AppState.getInstance().isConnected()) {
        this.errorText = '设备未连接'
        this.isLoading = false
        return
      }
      const api = new ApiService()
      this.devices = await api.fetchConnectedDevices()
    } catch (devErr) {
      this.errorText = '加载设备列表失败'
    }
    this.isLoading = false
  }

  async loadWirelessData(): Promise<void> {
    this.wirelessLoading = true
    try {
      if (!AppState.getInstance().isConnected()) {
        this.wirelessLoading = false
        return
      }
      const api = new ApiService()
      const wdevices = await api.fetchWirelessDevices()
      if (wdevices.length > 0) {
        this.wirelessClients = await api.fetchWirelessClients(wdevices[0].name)
      } else {
        this.wirelessClients = []
      }
    } catch (wlErr) {
      this.wirelessClients = []
    }
    this.wirelessLoading = false
  }

  getFilteredDevices(): ConnectedDevice[] {
    if (!this.searchText.trim()) {
      return this.devices
    }
    const kw: string = this.searchText.trim().toLowerCase()
    return this.devices.filter(d =>
      d.hostname.toLowerCase().includes(kw) ||
      d.ip.includes(kw) ||
      d.mac.toLowerCase().includes(kw)
    )
  }

  getDeviceEmoji(mac: string, hostname: string): string {
    const icon: string = FormatUtils.getDeviceIcon(mac, hostname)
    switch (icon) {
      case 'phone':
        return '📱'
      case 'laptop':
        return '💻'
      case 'tv':
        return '📺'
      case 'server':
        return '🖥'
      case 'camera':
        return '📷'
      case 'printer':
        return '🖨'
      case 'speaker':
        return '🔊'
      case 'watch':
        return '⌚'
      default:
        return '📡'
    }
  }

  build() {
    Column() {
      // 标题栏
      Row() {
        Text('设备列表')
          .fontSize(20)
          .fontColor(this.theme.textPrimary)
          .fontWeight(FontWeight.Bold)
        Blank()
        Text(`${this.getFilteredDevices().length} 台设备`)
          .fontSize(12)
          .fontColor(this.theme.textSecondary)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: 4 })

      // 搜索栏
      Row() {
        TextInput({ placeholder: '搜索设备名称、IP 或 MAC...', text: this.searchText })
          .placeholderColor(this.theme.textTertiary)
          .fontColor(this.theme.textPrimary)
          .backgroundColor('transparent')
          .onChange((v: string) => {
            this.searchText = v
          })
          .layoutWeight(1)
          .height(40)
        Text('🔍')
          .fontSize(16)
          .fontColor(this.theme.textSecondary)
          .padding({ left: 10, right: 4 })
      }
      .width('100%')
      .height(40)
      .borderRadius(12)
      .backgroundColor(this.theme.bgCard)
      .backdropBlur(10)
      .border({ width: 0.5, color: this.theme.borderGlass })
      .padding({ left: 14, right: 14 })
      .margin({ left: 16, right: 16, top: 8, bottom: 8 })

      // 子标签切换：DHCP / 无线
      Row() {
        Row() {
          Text('DHCP 客户端')
            .fontSize(12)
            .fontColor(this.subTab === 0 ? this.theme.textPrimary : this.theme.textTertiary)
            .fontWeight(this.subTab === 0 ? FontWeight.Medium : FontWeight.Normal)
        }
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .borderRadius(100)
        .backgroundColor(this.subTab === 0 ? this.theme.bgCardHover : 'transparent')
        .border(this.subTab === 0 ? { width: 0.5, color: this.theme.primary } : {})
        .onClick(() => {
          this.subTab = 0
        })

        Row() {
          Text('📶 无线')
            .fontSize(12)
            .fontColor(this.subTab === 1 ? this.theme.textPrimary : this.theme.textTertiary)
            .fontWeight(this.subTab === 1 ? FontWeight.Medium : FontWeight.Normal)
        }
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .borderRadius(100)
        .backgroundColor(this.subTab === 1 ? this.theme.bgCardHover : 'transparent')
        .border(this.subTab === 1 ? { width: 0.5, color: this.theme.primary } : {})
        .margin({ left: 10 })
        .onClick(() => {
          this.subTab = 1
        })

        Blank()
      }
      .width('100%')
      .padding({ left: 16, right: 16 })
      .margin({ bottom: 4 })

      if (this.subTab === 0) {
      Scroll() {
        Column() {
          if (this.isLoading) {
            Column() {
              LoadingProgress().width(40).height(40).color(this.theme.primary)
              Text('加载设备列表...')
                .fontSize(14)
                .fontColor(this.theme.textSecondary)
                .margin({ top: 12 })
            }
            .width('100%')
            .height(200)
            .justifyContent(FlexAlign.Center)
          } else if (this.errorText) {
            Row() {
              Text('⚠')
                .fontSize(16)
                .margin({ right: 8 })
              Text(this.errorText)
                .fontSize(12)
                .fontColor(this.theme.warning)
            }
            .width('100%')
            .padding(16)
            .borderRadius(14)
            .margin({ top: 8 })
            .backgroundColor(this.theme.bgCard)
            .border({ width: 0.5, color: this.theme.borderGlass })
          } else if (this.devices.length === 0) {
            Column() {
              Text('📡')
                .fontSize(48)
                .margin({ bottom: 12 })
              Text('暂无连接设备')
                .fontSize(16)
                .fontColor(this.theme.textPrimary)
                .fontWeight(FontWeight.Medium)
            }
            .width('100%')
            .padding(40)
            .borderRadius(14)
            .margin({ top: 8 })
            .backgroundColor(this.theme.bgCard)
            .border({ width: 0.5, color: this.theme.borderGlass })
            .alignItems(HorizontalAlign.Center)
          } else {
            ForEach(this.getFilteredDevices(), (device: ConnectedDevice, index: number) => {
              Row() {
                // 设备图标
                Text(this.getDeviceEmoji(device.mac, device.hostname))
                  .fontSize(28)
                  .width(44)
                  .height(44)
                  .borderRadius(12)
                  .backgroundColor(this.theme.bgGlassLight)
                  .textAlign(TextAlign.Center)

                // 设备信息
                Column() {
                  Text(device.hostname || 'Unknown')
                    .fontSize(14)
                    .fontColor(this.theme.textPrimary)
                    .fontWeight(FontWeight.Medium)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Row() {
                    Text(FormatUtils.formatMac(device.mac))
                      .fontSize(10)
                      .fontColor(this.theme.textTertiary)
                    if (FormatUtils.getVendorName(device.mac) !== 'Unknown') {
                      Text(` · ${FormatUtils.getVendorName(device.mac)}`)
                        .fontSize(10)
                        .fontColor(this.theme.textTertiary)
                    }
                  }
                }
                .margin({ left: 12 })
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                // IP 地址
                Column() {
                  Text(device.ip)
                    .fontSize(12)
                    .fontColor(this.theme.textPrimary)
                    .fontWeight(FontWeight.Medium)
                    .fontFamily('monospace')
                }
                .alignItems(HorizontalAlign.End)

                // 在线状态
                Circle()
                  .width(8)
                  .height(8)
                  .fill(device.isOnline ? this.theme.success : this.theme.textTertiary)
                  .margin({ left: 8 })
              }
              .width('100%')
              .padding(14)
              .borderRadius(14)
              .margin({ top: 6 })
              .backgroundColor(this.theme.bgCard)
              .backdropBlur(20)
              .border({ width: 0.5, color: this.theme.borderGlass })
              .onClick(() => {
                try {
                  this.getUIContext().getRouter().pushUrl({
                    url: 'pages/devices/ClientDetailPage',
                    params: { mac: device.mac, hostname: device.hostname }
                  })
                } catch (e) {
                  hilog.error(0x0001, 'MainPage', `pushUrl failed: ${e}`)
                }
              })
            }, (item: ConnectedDevice): string => item.mac + item.ip)
          }
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 4, bottom: 100 })
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
      } else {
      // 无线客户端列表
      Scroll() {
        Column() {
          if (this.wirelessLoading) {
            Column() {
              LoadingProgress().width(40).height(40).color(this.theme.primary)
              Text('加载无线设备...')
                .fontSize(14)
                .fontColor(this.theme.textSecondary)
                .margin({ top: 12 })
            }
            .width('100%')
            .height(200)
            .justifyContent(FlexAlign.Center)
          } else if (this.wirelessClients.length === 0) {
            Column() {
              Text('📶')
                .fontSize(48)
                .margin({ bottom: 12 })
              Text('暂无无线客户端')
                .fontSize(16)
                .fontColor(this.theme.textPrimary)
                .fontWeight(FontWeight.Medium)
            }
            .width('100%')
            .padding(40)
            .borderRadius(14)
            .margin({ top: 8 })
            .backgroundColor(this.theme.bgCard)
            .border({ width: 0.5, color: this.theme.borderGlass })
            .alignItems(HorizontalAlign.Center)
          } else {
            ForEach(this.wirelessClients, (client: WirelessClient, idx: number) => {
              Row() {
                Text('📶')
                  .fontSize(28)
                  .width(44)
                  .height(44)
                  .borderRadius(12)
                  .backgroundColor(this.theme.bgGlassLight)
                  .textAlign(TextAlign.Center)

                Column() {
                  Text(client.hostname || client.mac)
                    .fontSize(14)
                    .fontColor(this.theme.textPrimary)
                    .fontWeight(FontWeight.Medium)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Row() {
                    Text(FormatUtils.formatMac(client.mac))
                      .fontSize(10)
                      .fontColor(this.theme.textTertiary)
                    if (client.signal > 0) {
                      Text(` · 信号 ${client.signal} dBm`)
                        .fontSize(10)
                        .fontColor(this.theme.textTertiary)
                    }
                  }
                }
                .margin({ left: 12 })
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                Column() {
                  Text(client.rxRate > 0 || client.txRate > 0 ? `⇩ ${FormatUtils.formatSpeed(client.rxRate)}` : '--')
                    .fontSize(10)
                    .fontColor(this.theme.success)
                  Text(client.rxRate > 0 || client.txRate > 0 ? `⇧ ${FormatUtils.formatSpeed(client.txRate)}` : '--')
                    .fontSize(10)
                    .fontColor(this.theme.secondary)
                    .margin({ top: 2 })
                }
                .alignItems(HorizontalAlign.End)
              }
              .width('100%')
              .padding(14)
              .borderRadius(14)
              .margin({ top: 6 })
            .backgroundColor(this.theme.bgCard)
            .backdropBlur(20)
            .border({ width: 0.5, color: this.theme.borderGlass })
            .onClick(() => {
              try {
                this.getUIContext().getRouter().pushUrl({
                  url: 'pages/devices/ClientDetailPage',
                  params: { mac: client.mac, hostname: client.hostname || client.mac }
                })
              } catch (e) {
                hilog.error(0x0001, 'MainPage', `pushUrl failed: ${e}`)
              }
            })
          }, (item: WirelessClient): string => item.mac)
          }
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 4, bottom: 100 })
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
}
