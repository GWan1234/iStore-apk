import { LIGHT_THEME, ThemePalette } from '../../common/theme/ThemeColors'
import { AppState } from '../../common/store/AppState'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { http } from '@kit.NetworkKit'
import { util } from '@kit.ArkTS'
import { getAppVersionText } from '../../common/utils/AppVersion'

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
  @State theme: ThemePalette = LIGHT_THEME
  @State itemSlides: number[] = []
  @State deviceName: string = '未连接设备'
  @State deviceHost: string = ''
  @State deviceConnected: boolean = false
  @State savedCount: number = 0
  @State versionText: string = getAppVersionText()

  private groups: ToolGroup[] = [
    {
      title: '网络',
      items: [
        { emoji: '📶', name: 'WiFi 管理', desc: '无线网络状态与配置管理', route: 'pages/apps/WifiPage', iconResource: $r('app.media.wifi_icon') },
        { emoji: '🌐', name: '网络管理', desc: '接口状态与网络信息', route: 'pages/apps/NetworkPage', iconResource: $r('app.media.network_mgmt') },
        { emoji: '📊', name: '流量排行',  desc: '按速率排名的客户端活跃度', route: 'pages/apps/TrafficRankPage', iconResource: $r('app.media.ranking') },
        { emoji: '🔗', name: '连接排行',  desc: '发现 NAT 连接数最多的设备', route: 'pages/apps/ConntrackRankPage', iconResource: $r('app.media.active_connections') },
        { emoji: '',  name: '网口流量',  desc: '各接口实时速率与累计统计', route: 'pages/apps/PortTrafficPage', iconResource: $r('app.media.flow_monitoring') },
        { emoji: '🖧', name: '物理网口',  desc: '查看物理端口连接状态与速率', route: 'pages/apps/EthPortPage', iconResource: $r('app.media.green_network_port') },
        { emoji: '📈', name: '流量统计',  desc: '近 7/30 天每日流量趋势', route: 'pages/apps/TrafficReportPage', iconResource: $r('app.media.traffic_pipe') },
        { emoji: '🗺', name: '网络拓扑',  desc: '可视化设备连接关系图', route: 'pages/apps/TopologyPage', iconResource: $r('app.media.topology') },
      ]
    },
    {
      title: '管理',
      items: [
        { emoji: '🛡️', name: '家长控制',  desc: 'OAF 应用过滤引擎配置', route: 'pages/apps/OafPage', iconResource: $r('app.media.app_shield') },
        { emoji: '⚙️', name: '系统进程',  desc: '查看和管理运行中的进程', route: 'pages/process/ProcessListPage', iconResource: $r('app.media.app_gear') },
        { emoji: '🚀', name: '启动项',   desc: '管理开机自启服务', route: 'pages/process/StartupPage', iconResource: $r('app.media.app_rocket') },
        { emoji: '🔔', name: '智能通知',  desc: '断网告警与新设备接入提醒', route: 'pages/apps/NotifySettingsPage', iconResource: $r('app.media.app_bell') },
        { emoji: '⏰', name: '定时任务',  desc: '定时重启与定时开关 WiFi', route: 'pages/apps/SchedulePage', iconResource: $r('app.media.schedule') },
        { emoji: '🤖', name: 'AI 网络助手', desc: '自然语言查询网络状态', route: 'pages/apps/AiAssistantPage', iconResource: $r('app.media.ai_assistant') },
        { emoji: '⌨️', name: 'SSH 终端',   desc: '命令行管理路由器', route: 'pages/apps/SshTerminalPage', iconResource: $r('app.media.terminal') },
        { emoji: '📁', name: '文件管理',   desc: '浏览管理 OpenWrt 文件', route: 'pages/apps/FileManagerPage', iconResource: $r('app.media.folder_file') },
      ]
    },
    {
      title: '系统',
      items: [
        { emoji: '🔄', name: '重启',     desc: '重启路由器设备', route: 'pages/system/RebootPage', iconResource: $r('app.media.app_restart') },
        { emoji: '🔙', name: '恢复出厂', desc: '恢复设备到出厂设置', route: 'pages/system/FactoryResetPage', iconResource: $r('app.media.app_reset') },
        { emoji: '🌐', name: 'OpenWRT 首页', desc: '打开路由器管理后台', route: 'pages/apps/WebViewPage', iconResource: $r('app.media.app_globe') },
        { emoji: 'ℹ️', name: '关于',     desc: '版本信息与更新检查', route: '__about__', iconResource: $r('app.media.app_info') },
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

  /** 拉取远程最新版本并跳转关于页（version.json 发布信息） */
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
this.theme = AppState.getInstance().getTheme()
    
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

  /** 分组内双列分组（每行 2 个） */
  groupRows(items: ToolEntry[]): ToolEntry[][] {
    const rows: ToolEntry[][] = []
    for (let i = 0; i < items.length; i += 2) {
      rows.push(items.slice(i, i + 2))
    }
    return rows
  }

  /** 双列功能方块（图标 + 名称，紧凑应用商店风格） */
  @Builder
  toolCard(tool: ToolEntry, slideIdx: number) {
    Column() {
      // 图标（直接显示，不包内层方框）
      Row() {
        if (tool.iconResource) {
          Image(tool.iconResource).width(26).height(26).objectFit(ImageFit.Contain)
        } else {
          Text(tool.emoji).fontSize(24)
        }
      }
      .justifyContent(FlexAlign.Center)

      Text(tool.name)
        .fontSize(11)
        .fontColor(this.theme.textPrimary)
        .fontWeight(FontWeight.Medium)
        .margin({ top: 6 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('48%')
    .padding(10)
    .borderRadius(14)
    .backgroundColor(this.theme.bgCard)
    .backdropBlur(20)
    .border({ width: 0.5, color: this.theme.borderGlass })
    .alignItems(HorizontalAlign.Center)
    .opacity(this.itemSlides.length > slideIdx && this.itemSlides[slideIdx] === 0 ? 1 : 0)
    .translate({ x: this.itemSlides.length > slideIdx ? this.itemSlides[slideIdx] : 300 })
    .onClick(() => this.handleClick(tool))
  }

  build() {
    Stack() {
      Column()
        .width('100%').height('100%')
        .linearGradient({
          angle: 135,
          colors: [['#F1BCA8', 0], ['#F3D6C8', 0.5], ['#F5F1EE', 1]]
        })

      Column() {
        // 顶栏
        Row() {
          Row() {
            Text(' 应用中心').fontSize(16).fontColor(this.theme.textPrimary)
              .fontWeight(FontWeight.Medium)
          }
          .padding({ left: 12, right: 16, top: 6, bottom: 6 })
          .borderRadius(100).backgroundColor('transparent')
          .border({ width: 0.5, color: this.theme.borderGlass })
          .onClick(() => {
            try { this.getUIContext().getRouter().back() }
            catch (e) { hilog.error(0x0001, 'AppsPage', `router.back failed: ${e}`) }
          })

          Blank()
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
                Image($r('app.media.app_drive'))
                  .width(32).height(32)
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
            .width('calc(100% - 56px)')
            .padding(18)
            .borderRadius(20)
            .backgroundColor(this.theme.bgCard)
            .backdropBlur(20)
            .border({ width: 0.5, color: this.theme.borderGlass })
            .margin({ left: 28, right: 28, top: 8 })

            // ===== 分组（横线式标题 + 双列方块，无大卡片框）=====
            ForEach(this.groups, (group: ToolGroup, gIdx: number) => {
              Column() {
                // 横线式分类标题：———— 网络 ————
                Row() {
                  Row()
                    .layoutWeight(1)
                    .height(0.5)
                    .backgroundColor(this.theme.borderGlass)
                  Text(group.title)
                    .fontSize(12)
                    .fontColor(this.theme.textSecondary)
                    .margin({ left: 12, right: 12 })
                  Row()
                    .layoutWeight(1)
                    .height(0.5)
                    .backgroundColor(this.theme.borderGlass)
                }
                .width('100%')
                .padding({ left: 18, right: 18, top: 20, bottom: 6 })

                // 双列方块网格（无卡片容器，直接浮在背景上）
                ForEach(this.groupRows(group.items), (row: ToolEntry[], rowIdx: number) => {
                  Row() {
                    ForEach(row, (tool: ToolEntry, colIdx: number) => {
                      this.toolCard(tool, this.getSlideIndex(gIdx, rowIdx * 2 + colIdx))
                    }, (tool: ToolEntry): string => tool.name + tool.desc)
                  }
                  .width('100%')
                  .justifyContent(FlexAlign.SpaceBetween)
                  .padding({ left: 12, right: 12 })
                  .margin({ top: 8 })
                }, (row: ToolEntry[], rowIdx: number): string => `row_${rowIdx}`)
              }
              .width('100%')
              .margin({ left: 16, right: 16 })
            })

            // 底部版本信息
            Column() {
              Text('iStore 路由管家')
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
