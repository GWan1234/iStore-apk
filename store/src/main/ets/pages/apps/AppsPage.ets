import { ThemePalette, DARK_THEME } from '../../common/theme/ThemeColors'
import { AppState } from '../../common/store/AppState'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { http } from '@kit.NetworkKit'
import { util } from '@kit.ArkTS'

const VERSION_URL = 'https://raw.githubusercontent.com/HWYWL/iStore/main/api/version.json'

interface ToolEntry {
  emoji: string
  name: string
  desc: string
  route: string
  iconResource?: Resource
}

/** 分类分组 */
interface ToolGroup {
  title: string
  items: ToolEntry[]
}

@Entry
@Component
struct AppsPage {
  @State isDark: boolean = true
  @State theme: ThemePalette = DARK_THEME
  @State itemSlides: number[] = []
  @State deviceName: string = '未连接设备'
  @State deviceHost: string = ''
  @State deviceConnected: boolean = false
  @State savedCount: number = 0
  @State versionText: string = 'v2.8.5'

  private groups: ToolGroup[] = [
    {
      title: '网络',
      items: [
        { emoji: '📶', name: 'WiFi 管理', desc: '无线网络状态与配置管理', route: 'pages/apps/WifiPage' },
        { emoji: '🌐', name: '网络管理', desc: '接口状态与网络信息', route: 'pages/apps/NetworkPage' },
        { emoji: '📊', name: '流量排行',  desc: '按速率排名的客户端活跃度', route: 'pages/apps/TrafficRankPage' },
        { emoji: '🔗', name: '连接排行',  desc: '发现 NAT 连接数最多的设备', route: 'pages/apps/ConntrackRankPage' },
        { emoji: '',  name: '网口流量',  desc: '各接口实时速率与累计统计', route: 'pages/apps/PortTrafficPage', iconResource: $r('app.media.flow_monitoring') },
        { emoji: '🖧', name: '物理网口',  desc: '查看物理端口连接状态与速率', route: 'pages/apps/EthPortPage' },
      ]
    },
    {
      title: '管理',
      items: [
        { emoji: '🛡️', name: '家长控制',  desc: 'OAF 应用过滤引擎配置', route: 'pages/apps/OafPage' },
        { emoji: '⚙️', name: '系统进程',  desc: '查看和管理运行中的进程', route: 'pages/process/ProcessListPage' },
        { emoji: '🚀', name: '启动项',   desc: '管理开机自启服务', route: 'pages/process/StartupPage' },
        { emoji: '🔔', name: '智能通知',  desc: '断网告警与新设备接入提醒', route: 'pages/apps/NotifySettingsPage' },
        { emoji: '⏰', name: '定时任务',  desc: '定时重启与定时开关 WiFi', route: 'pages/apps/SchedulePage' },
      ]
    },
    {
      title: '系统',
      items: [
        { emoji: '🔄', name: '重启',     desc: '重启路由器设备', route: 'pages/system/RebootPage' },
        { emoji: '🔙', name: '恢复出厂', desc: '恢复设备到出厂设置', route: 'pages/system/FactoryResetPage' },
        { emoji: '🌐', name: 'OpenWRT 首页', desc: '打开路由器管理后台', route: 'pages/apps/WebViewPage' },
        { emoji: 'ℹ️', name: '关于',     desc: '版本信息与更新检查', route: '__about__' },
      ]
    },
  ]

  /** 扁平化获取总数量用于动画 */
  private flatTools(): ToolEntry[] {
    const arr: ToolEntry[] = []
    for (const g of this.groups) {
      for (const t of g.items) arr.push(t)
    }
    return arr
  }

  async fetchVersionAndAbout(): Promise<void> {
    let ver = '未知'
    let req: http.HttpRequest | null = null
    try {
      req = http.createHttp()
      const result = await Promise.race([
        req.request(VERSION_URL, {
          method: http.RequestMethod.GET,
          expectDataType: http.HttpDataType.STRING,
          connectTimeout: 4000,
          readTimeout: 4000
        }),
        new Promise<null>(r => setTimeout(() => r(null), 5000))
      ])
      if (result && (result as http.HttpResponse).responseCode === 200) {
        const resp = result as http.HttpResponse
        let bodyStr = ''
        if (typeof resp.result === 'string') {
          bodyStr = resp.result as string
        } else {
          const decoder = new util.TextDecoder('utf-8')
          bodyStr = decoder.decodeToString(new Uint8Array(resp.result as ArrayBuffer))
        }
        const body = JSON.parse(bodyStr) as Record<string, Object>
        ver = (body['version'] as string) || '未知'
      }
    } catch (_e) {
    } finally {
      try { req?.destroy() } catch (_e) {}
    }
    try {
      this.getUIContext().getRouter().pushUrl({
        url: 'pages/other/AboutPage',
        params: { latestVersion: ver }
      })
    } catch (_e) {}
  }

  handleClick(tool: ToolEntry): void {
    if (tool.route === '__about__') {
      this.fetchVersionAndAbout()
    } else {
      try {
        this.getUIContext().getRouter().pushUrl({ url: tool.route })
      } catch (e) {
        hilog.error(0x0001, 'AppsPage', `pushUrl failed: ${e}`)
      }
    }
  }

  aboutToAppear(): void {
    this.isDark = AppState.getInstance().isDarkMode
    this.theme = AppState.getInstance().getTheme()
    AppState.getInstance().onThemeChange(() => {
      this.isDark = AppState.getInstance().isDarkMode
      this.theme = AppState.getInstance().getTheme()
    })

    // 填充设备信息（仿应用商店「我的」个人卡片）
    const active = AppState.getInstance().getActiveDevice()
    this.deviceConnected = AppState.getInstance().isConnected()
    if (active) {
      this.deviceName = active.label || active.host || '路由器'
      this.deviceHost = active.host ? `${active.host}${active.port && active.port !== '80' ? ':' + active.port : ''}` : ''
    }
    this.savedCount = AppState.getInstance().devices.length

    const tools: ToolEntry[] = this.flatTools()
    const slides: number[] = []
    for (let i = 0; i < tools.length; i++) slides.push(300)
    this.itemSlides = slides

    for (let i = 0; i < tools.length; i++) {
      setTimeout(() => {
        this.getUIContext().animateTo({ duration: 380, curve: Curve.EaseOut }, () => {
          const arr: number[] = [...this.itemSlides]
          arr[i] = 0
          this.itemSlides = arr
        })
      }, 50 * i)
    }
  }

  /** 获取全局动画索引 */
  getSlideIndex(groupIdx: number, itemIdx: number): number {
    let idx = 0
    for (let g = 0; g < groupIdx; g++) idx += this.groups[g].items.length
    return idx + itemIdx
  }

  build() {
    Stack() {
      Column()
        .width('100%').height('100%')
        .linearGradient({
          angle: 180,
          colors: this.isDark
            ? [['#0A0E27', 0], ['#121637', 0.5], ['#0A0E27', 1]]
            : [['#E8ECF1', 0], ['#F5F7FA', 0.5], ['#E8ECF1', 1]]
        })

      Column() {
        // 顶栏
        Row() {
          Row() {
            Text('←').fontSize(18).fontColor(this.theme.primary)
            Text(' 应用中心').fontSize(16).fontColor(this.theme.textPrimary)
              .fontWeight(FontWeight.Medium)
          }
          .padding({ left: 12, right: 16, top: 6, bottom: 6 })
          .borderRadius(100).backgroundColor(this.theme.bgCard).backdropBlur(20)
          .border({ width: 0.5, color: this.theme.borderGlass })
          .onClick(() => {
            try { this.getUIContext().getRouter().back() }
            catch (e) { hilog.error(0x0001, 'AppsPage', `router.back failed: ${e}`) }
          })

          Blank()

          Row() {
            Text(this.isDark ? '☀' : '🌙').fontSize(16)
          }
          .width(34).height(34).borderRadius(17)
          .backgroundColor(this.theme.bgCard)
          .border({ width: 0.5, color: this.theme.borderGlass })
          .justifyContent(FlexAlign.Center)
          .onClick(() => AppState.getInstance().toggleTheme())
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 48, bottom: 12 })

        // 内容列表（仿鸿蒙应用商店「我的」排版）
        Scroll() {
          Column() {
            // ===== 顶部个人信息卡片 =====
            Row() {
              // 圆形设备头像
              Row() {
                SymbolGlyph($r('sys.symbol.externaldrive_fill_3'))
                  .fontSize(30)
                  .fontColor([this.theme.primary])
              }
              .width(64).height(64).borderRadius(32)
              .backgroundColor(this.deviceConnected ? 'rgba(68,138,255,0.15)' : 'rgba(255,82,82,0.12)')
              .justifyContent(FlexAlign.Center)

              // 名称 + 地址
              Column() {
                Row() {
                  Text(this.deviceName)
                    .fontSize(18).fontColor(this.theme.textPrimary)
                    .fontWeight(FontWeight.Bold)
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(this.deviceConnected ? '●' : '○')
                    .fontSize(14).fontColor(this.deviceConnected ? '#00E676' : '#FF5252')
                    .margin({ left: 6 })
                }
                .width('100%')
                .alignItems(VerticalAlign.Center)

                if (this.deviceHost) {
                  Text(this.deviceHost)
                    .fontSize(12).fontColor(this.theme.textTertiary)
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    .margin({ top: 3 })
                } else {
                  Text('未连接设备，请先登录路由器')
                    .fontSize(12).fontColor(this.theme.textTertiary)
                    .margin({ top: 3 })
                }
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              .margin({ left: 14 })

              // 已保存设备数
              Column() {
                Text(String(this.savedCount))
                  .fontSize(20).fontColor(this.theme.primary).fontWeight(FontWeight.Bold)
                Text('已保存设备')
                  .fontSize(10).fontColor(this.theme.textTertiary).margin({ top: 2 })
              }
              .alignItems(HorizontalAlign.Center)
              .padding({ left: 12, right: 4 })
            }
            .width('100%')
            .padding(18)
            .borderRadius(20)
            .backgroundColor(this.theme.bgCard)
            .backdropBlur(20)
            .border({ width: 0.5, color: this.theme.borderGlass })
            .margin({ left: 16, right: 16, top: 8 })

            // ===== 分组大卡片（行间分割线）=====
            ForEach(this.groups, (group: ToolGroup, gIdx: number) => {
              Column() {
                // 分类标题
                Text(group.title)
                  .fontSize(13).fontColor(this.theme.textSecondary)
                  .width('100%')
                  .padding({ left: 18, right: 18, top: 20, bottom: 8 })

                // 整组一张大卡片
                Column() {
                  ForEach(group.items, (tool: ToolEntry, tIdx: number) => {
                    Column() {
                      Row() {
                        // 左侧图标
                        Row() {
                          if (tool.iconResource) {
                            Image(tool.iconResource).width(22).height(22).objectFit(ImageFit.Contain)
                          } else {
                            Text(tool.emoji).fontSize(20)
                          }
                        }
                        .width(40).height(40).borderRadius(12)
                        .backgroundColor(this.theme.bgGlassLight)
                        .justifyContent(FlexAlign.Center)

                        // 中间文字
                        Column() {
                          Text(tool.name)
                            .fontSize(15).fontColor(this.theme.textPrimary)
                            .fontWeight(FontWeight.Medium)
                          Text(tool.desc)
                            .fontSize(11).fontColor(this.theme.textTertiary)
                            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                            .margin({ top: 2 })
                        }
                        .alignItems(HorizontalAlign.Start)
                        .layoutWeight(1)
                        .margin({ left: 12 })

                        // 右侧箭头
                        Text('›').fontSize(20).fontColor(this.theme.textTertiary)
                      }
                      .width('100%')
                      .padding({ left: 14, right: 14, top: 12, bottom: 12 })
                      .onClick(() => this.handleClick(tool))

                      // 行间分割线（除最后一项）
                      if (tIdx < group.items.length - 1) {
                        Row()
                          .width('calc(100% - 28px)')
                          .height(0.5)
                          .backgroundColor(this.theme.borderGlass)
                          .margin({ left: 14 })
                      }
                    }
                    .width('100%')
                    .opacity(this.getSlideIndex(gIdx, tIdx) < this.itemSlides.length && this.itemSlides[this.getSlideIndex(gIdx, tIdx)] === 0 ? 1 : 0)
                    .translate({ x: this.itemSlides.length > this.getSlideIndex(gIdx, tIdx) ? this.itemSlides[this.getSlideIndex(gIdx, tIdx)] : 300 })
                  })
                }
                .width('100%')
                .borderRadius(18)
                .backgroundColor(this.theme.bgCard)
                .backdropBlur(20)
                .border({ width: 0.5, color: this.theme.borderGlass })
                .padding({ top: 4, bottom: 4 })
              }
              .width('100%')
              .margin({ left: 16, right: 16 })
            })

            // 底部版本信息
            Column() {
              Text('iStore 路由器管理')
                .fontSize(12).fontColor(this.theme.textTertiary)
              Text(`${this.versionText} · 开源 · HarmonyOS`)
                .fontSize(10).fontColor(this.theme.textTertiary).opacity(0.7)
                .margin({ top: 3 })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)
            .padding({ top: 28, bottom: 40 })
          }
          .width('100%')
        }
        .width('100%').layoutWeight(1).scrollBar(BarState.Off)
        .padding({ top: 4 })
      }
      .width('100%').height('100%')
    }
    .width('100%').height('100%')
  }
}
