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
  aboutToAppear(): void {
    // 首次加载数据，然后启动 5 秒轮询刷新
    this.loadData()
    this.timerId = setInterval(() => {
      this.refreshData()
    }, 5000)
  }

  aboutToDisappear(): void {
    if (this.timerId !== -1) {
      clearInterval(this.timerId)
      this.timerId = -1
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

  getTempColor(temp: number): string {
    if (temp <= 0) {
      // 未获取到温度数据，使用灰色
      return this.theme.textTertiary
    }
    if (temp < 50) {
      // < 50°C：健康（绿色）
      return '#00E676'
    }
    if (temp < 65) {
      // 50-65°C：警告（黄色）
      return '#FFD740'
    }
    // ≥ 65°C：过热（红色）
    return '#FF5252'
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

  getMemoryPct(): number {
    // 计算内存使用率，避免除零
    return this.systemInfo.memoryTotal > 0
      ? (this.systemInfo.memoryUsed / this.systemInfo.memoryTotal) * 100
      : 0
  }

  getMemoryColor(usage: number): string {
    if (usage < 40) {
      // < 40%：充足（绿色）
      return '#00E676'
    }
    if (usage < 75) {
      // 40-75%：适中（黄色）
      return '#FFD740'
    }
    // ≥ 75%：紧张（红色）
    return '#FF5252'
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
              .fill(this.isOnline ? this.theme.success : this.theme.danger)
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

            // ============ 第二行：CPU / 内存 / 温度 三个卡片 ============
            Row() {
              // CPU
              Column() {
                Text('CPU')
                  .fontSize(11)
                  .fontColor(this.theme.textTertiary)
                  .margin({ bottom: 4 })
                Text(FormatUtils.formatPercent(this.systemInfo.cpuUsage))
                  .fontSize(18)
                  .fontColor(this.getCpuColor(this.systemInfo.cpuUsage))
                  .fontWeight(FontWeight.Bold)
                  .margin({ bottom: 6 })

                Stack() {
                  Row()
                    .width('100%')
                    .height(4)
                    .borderRadius(2)
                    .backgroundColor('rgba(255,255,255,0.1)')
                  Row()
                    .width(`${Math.max(0, Math.min(100, this.systemInfo.cpuUsage))}%`)
                    .height(4)
                    .borderRadius(2)
                    .linearGradient({
                      angle: 90,
                      colors: [
                        [this.getCpuColor(this.systemInfo.cpuUsage), 0],
                        [this.getCpuColor(this.systemInfo.cpuUsage) + '44', 1]
                      ]
                    })
                }
                .width('100%')
                .alignContent(Alignment.End)
              }
              .width('30%')
              .padding(12)
              .borderRadius(14)
              .backgroundColor(this.theme.bgCard)
              .backdropBlur(20)
              .border({ width: 0.5, color: this.theme.borderGlass })
              .alignItems(HorizontalAlign.Start)

              // 内存
              Column() {
                Text('内存')
                  .fontSize(11)
                  .fontColor(this.theme.textTertiary)
                  .margin({ bottom: 4 })
                Text(`${this.getMemoryPct().toFixed(1)}%`)
                  .fontSize(18)
                  .fontColor(this.getMemoryColor(this.getMemoryPct()))
                  .fontWeight(FontWeight.Bold)
                  .margin({ bottom: 2 })
                Text(`${FormatUtils.formatBytes(this.systemInfo.memoryUsed)} / ${FormatUtils.formatBytes(this.systemInfo.memoryTotal)}`)
                  .fontSize(11)
                  .fontColor(this.theme.textTertiary)
                  .margin({ bottom: 4 })

                Stack() {
                  Row()
                    .width('100%')
                    .height(4)
                    .borderRadius(2)
                    .backgroundColor('rgba(255,255,255,0.1)')
                  Row()
                    .width(`${Math.max(0, Math.min(100, this.getMemoryPct()))}%`)
                    .height(4)
                    .borderRadius(2)
                    .linearGradient({
                      angle: 90,
                      colors: [
                        [this.getMemoryColor(this.getMemoryPct()), 0],
                        [this.getMemoryColor(this.getMemoryPct()) + '44', 1]
                      ]
                    })
                }
                .width('100%')
                .alignContent(Alignment.End)
              }
              .width('30%')
              .padding(12)
              .borderRadius(14)
              .backgroundColor(this.theme.bgCard)
              .backdropBlur(20)
              .border({ width: 0.5, color: this.theme.borderGlass })
              .alignItems(HorizontalAlign.Start)

              // 温度
              Column() {
                Text('CPU温度')
                  .fontSize(11)
                  .fontColor(this.theme.textTertiary)
                  .margin({ bottom: 4 })
                Row() {
                  Text(this.systemInfo.cpuTemp > 0 ? this.systemInfo.cpuTemp.toFixed(1) : '--')
                    .fontSize(18)
                    .fontColor(this.getTempColor(this.systemInfo.cpuTemp))
                    .fontWeight(FontWeight.Bold)
                  Text('°C')
                    .fontSize(11)
                    .fontColor(this.theme.textTertiary)
                    .margin({ left: 2 })
                }
                .margin({ bottom: 6 })

                Stack() {
                  Row()
                    .width('100%')
                    .height(4)
                    .borderRadius(2)
                    .backgroundColor('rgba(255,255,255,0.1)')
                  Row()
                    .width(`${this.systemInfo.cpuTemp > 0 ? Math.min(100, (this.systemInfo.cpuTemp / 100) * 100) : 0}%`)
                    .height(4)
                    .borderRadius(2)
                    .linearGradient({
                      angle: 90,
                      colors: [
                        [this.getTempColor(this.systemInfo.cpuTemp), 0],
                        [this.getTempColor(this.systemInfo.cpuTemp) + '44', 1]
                      ]
                    })
                }
                .width('100%')
                .alignContent(Alignment.End)
              }
              .width('30%')
              .padding(12)
              .borderRadius(14)
              .backgroundColor(this.theme.bgCard)
              .backdropBlur(20)
              .border({ width: 0.5, color: this.theme.borderGlass })
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)
            .margin({ top: 10 })

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
        .fill(iface.status === 'up' ? this.theme.success : this.theme.textTertiary)
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
