import { AppState } from '../../common/store/AppState'
import { ThemePalette, DARK_THEME } from '../../common/theme/ThemeColors'
import { OafStatus, AppFilterBase, AppClass, AppItem, AppFilterTime, AppFilterUser, TimeSlot } from '../../models/Models'
import { ApiService } from '../../api/ApiService'
import { hilog } from '@kit.PerformanceAnalysisKit'

/** 星期常量映射 */
const WEEKDAYS: string[] = ['日', '一', '二', '三', '四', '五', '六']

@Entry
@Component
struct OafPage {
  @State isDark: boolean = true
  @State theme: ThemePalette = DARK_THEME
  @State isLoading: boolean = true
  @State errorText: string = ''
  @State oafStatus: OafStatus | null = null
  @State appBase: AppFilterBase | null = null
  @State appClasses: AppClass[] = []
  @State appTime: AppFilterTime | null = null
  @State appUser: AppFilterUser | null = null
  @State expandedClasses: Set<number> = new Set()

  aboutToAppear(): void {
    this.isDark = AppState.getInstance().isDarkMode
    this.theme = AppState.getInstance().getTheme()
    AppState.getInstance().onThemeChange(() => {
      this.isDark = AppState.getInstance().isDarkMode
      this.theme = AppState.getInstance().getTheme()
    })
    this.loadData()
  }

  async loadData(): Promise<void> {
    this.isLoading = true
    this.errorText = ''
    try {
      const api = new ApiService()
      const results = await Promise.all([
        api.fetchOafStatus(),
        api.fetchAppFilterBase(),
        api.fetchAppFilterClasses(),
        api.fetchAppFilterTime(),
        api.fetchAppFilterUser()
      ])
      this.oafStatus = results[0]
      this.appBase = results[1]
      this.appClasses = results[2]
      this.appTime = results[3]
      this.appUser = results[4]
    } catch (e) {
      this.errorText = '加载数据失败'
    }
    this.isLoading = false
  }

  toggleClassExpand(clsId: number): void {
    const next = new Set(this.expandedClasses)
    if (next.has(clsId)) {
      next.delete(clsId)
    } else {
      next.add(clsId)
    }
    this.expandedClasses = next
  }

  /** 格式化 HH:MM */
  fmtTime(h: number, m: number): string {
    return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}`
  }

  /** 工作日数组转中文 */
  fmtWeekdays(arr: number[]): string {
    if (arr.length === 0) return '未设置'
    if (arr.length === 7) return '每天'
    return arr.map(i => '周' + WEEKDAYS[i]).join('、')
  }

  build() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
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
            Text('←')
              .fontSize(18)
              .fontColor(this.theme.primary)
            Text(' 家长控制')
              .fontSize(16)
              .fontColor(this.theme.textPrimary)
              .fontWeight(FontWeight.Medium)
          }
          .padding({ left: 12, right: 16, top: 6, bottom: 6 })
          .borderRadius(100)
          .backgroundColor(this.theme.bgCard)
          .backdropBlur(20)
          .border({ width: 0.5, color: this.theme.borderGlass })
          .onClick(() => this.getUIContext().getRouter().back())
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 48, bottom: 8 })

        if (this.isLoading) {
          Column() {
            LoadingProgress().color(this.theme.primary).width(32).height(32)
            Text('加载中…').fontSize(13).fontColor(this.theme.textTertiary).margin({ top: 12 })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.errorText) {
          Column() {
            Text('⚠ ' + this.errorText).fontSize(14).fontColor(this.theme.warning).margin({ bottom: 12 })
            Text('点击重试')
              .fontSize(14).fontColor(this.theme.primary)
              .onClick(() => this.loadData())
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          Scroll() {
            Column() {
              // ======== 引擎状态卡片 ========
              Column() {
                Text('🔧 OAF 引擎状态')
                  .fontSize(14).fontColor(this.theme.textPrimary)
                  .fontWeight(FontWeight.Medium).margin({ bottom: 12 })
                this.statRow('插件版本', this.oafStatus?.pluginVersion || '--')
                this.statRow('引擎版本', this.oafStatus?.engineVersion || '--')
                this.statRow('内核版本', this.oafStatus?.kernelVersion || '--')
                Row() {
                  Text('引擎状态')
                    .fontSize(12).fontColor(this.theme.textTertiary).layoutWeight(1)
                  Text(this.oafStatus?.engineStatus === 'running' ? '运行中' : '未运行')
                    .fontSize(12).fontColor(this.oafStatus?.engineStatus === 'running' ? '#00E676' : '#FF5252')
                }.width('100%').margin({ top: 8 })
              }
              .width('100%').padding(16).borderRadius(14).margin({ top: 8, left: 16, right: 16 })
              .backgroundColor(this.theme.bgCard).backdropBlur(20)
              .border({ width: 0.5, color: this.theme.borderGlass })

              // ======== 基础配置卡片 ========
              Column() {
                Text('⚙️ 基础配置')
                  .fontSize(14).fontColor(this.theme.textPrimary)
                  .fontWeight(FontWeight.Medium).margin({ bottom: 10 })
                Row() {
                  this.configBadge('总开关', this.appBase?.appFilterEnabled === true, '#00E676', '#FF5252')
                  this.configBadge('工作模式',
                    this.appBase?.workMode === 'gateway', '#448AFF', '#FF9800',
                    this.appBase?.workMode === 'gateway' ? '网关' : '旁路')
                  this.configBadge('日志', this.appBase?.appLogEnabled === true, '#00E676', '#9E9E9E')
                }
                .width('100%')
                .justifyContent(FlexAlign.SpaceEvenly)
              }
              .width('100%').padding(16).borderRadius(14).margin({ top: 10, left: 16, right: 16 })
              .backgroundColor(this.theme.bgCard).backdropBlur(20)
              .border({ width: 0.5, color: this.theme.borderGlass })

              // ======== 应用分类管控 ========
              Column() {
                Row() {
                  Text('📱 应用管控')
                    .fontSize(14).fontColor(this.theme.textPrimary)
                    .fontWeight(FontWeight.Medium)
                  Text(`  ${this.appClasses.length} 类`)
                    .fontSize(11).fontColor(this.theme.textTertiary)
                }
                .margin({ bottom: 10 })

                if (this.appClasses.length === 0) {
                  Text('暂无应用分类数据').fontSize(12).fontColor(this.theme.textTertiary)
                    .width('100%').textAlign(TextAlign.Center).padding({ top: 12, bottom: 12 })
                } else {
                  ForEach(this.appClasses, (cls: AppClass, idx: number) => {
                    Column() {
                      Row() {
                        Text(cls.name)
                          .fontSize(13).fontColor(this.theme.textPrimary).fontWeight(FontWeight.Medium)
                        Text(`  ${cls.apps.length} 个`)
                          .fontSize(11).fontColor(this.theme.textTertiary)
                        Blank()
                        Text(this.expandedClasses.has(cls.id) ? '▾' : '▸')
                          .fontSize(14).fontColor(this.theme.textTertiary)
                      }
                      .width('100%')
                      .padding({ top: 8, bottom: 8 })
                      .onClick(() => this.toggleClassExpand(cls.id))

                      if (this.expandedClasses.has(cls.id)) {
                        Column() {
                          ForEach(cls.apps, (app: AppItem) => {
                            Row() {
                              Text(app.name)
                                .fontSize(11).fontColor(this.theme.textSecondary)
                                .layoutWeight(1)
                              Text(app.enabled ? '已管控' : '未管控')
                                .fontSize(10)
                                .fontColor(app.enabled ? '#00E676' : '#9E9E9E')
                                .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                                .borderRadius(8)
                                .backgroundColor(app.enabled ? 'rgba(0,230,118,0.12)' : 'rgba(158,158,158,0.12)')
                            }
                            .width('100%')
                            .padding({ top: 4, bottom: 4 })
                          })
                        }
                        .width('100%')
                        .padding({ left: 8, top: 4, bottom: 4 })
                      }
                    }
                    .width('100%')
                    .padding({ left: 12, right: 12 })
                    .borderRadius(10)
                    .border({ width: 0.5, color: this.theme.borderGlass })
                    .margin({ bottom: idx < this.appClasses.length - 1 ? 8 : 0 })
                  })
                }
              }
              .width('100%').padding(16).borderRadius(14).margin({ top: 10, left: 16, right: 16 })
              .backgroundColor(this.theme.bgCard).backdropBlur(20)
              .border({ width: 0.5, color: this.theme.borderGlass })

              // ======== 时间段配置 ========
              if (this.appTime) {
                Column() {
                  Text('🕐 时间段配置')
                    .fontSize(14).fontColor(this.theme.textPrimary)
                    .fontWeight(FontWeight.Medium).margin({ bottom: 10 })

                  // 生效星期
                  this.statRow('生效日期', this.fmtWeekdays(this.appTime.weekdays))

                  // 固定时段
                  if (this.appTime.fixedTimes.length > 0) {
                    Text('固定时段')
                      .fontSize(12).fontColor(this.theme.textTertiary).margin({ top: 8, bottom: 6 })
                    ForEach(this.appTime.fixedTimes, (slot: TimeSlot, i: number) => {
                      Text(`${this.fmtTime(slot.startHour, slot.startMin)} ~ ${this.fmtTime(slot.endHour, slot.endMin)}`)
                        .fontSize(12).fontColor(this.theme.textPrimary)
                        .padding({ top: 4, bottom: 4 })
                    })
                  } else {
                    this.statRow('固定时段', '未设置')
                  }

                  // 动态时长
                  if (this.appTime.dynamicMinutes > 0) {
                    this.statRow('动态时长',
                      `${this.appTime.dynamicMinutes} 分钟（${this.fmtTime(this.appTime.dynamicStartHour, this.appTime.dynamicStartMin)}~${this.fmtTime(this.appTime.dynamicEndHour, this.appTime.dynamicEndMin)}）`)
                  } else {
                    this.statRow('动态时长', '未启用')
                  }
                }
                .width('100%').padding(16).borderRadius(14).margin({ top: 10, left: 16, right: 16 })
                .backgroundColor(this.theme.bgCard).backdropBlur(20)
                .border({ width: 0.5, color: this.theme.borderGlass })
              }

              // ======== 管控用户 ========
              if (this.appUser) {
                Column() {
                  Text('👥 管控用户')
                    .fontSize(14).fontColor(this.theme.textPrimary)
                    .fontWeight(FontWeight.Medium).margin({ bottom: 10 })
                  this.statRow('模式', this.appUser.mode === 'auto' ? '自动' : '手动')
                }
                .width('100%').padding(16).borderRadius(14).margin({ top: 10, left: 16, right: 16 })
                .backgroundColor(this.theme.bgCard).backdropBlur(20)
                .border({ width: 0.5, color: this.theme.borderGlass })
              }

              // 底部留白
              Row().width('100%').height(100)
            }
            .width('100%')
          }
          .width('100%').padding({ left: 0, right: 0, top: 0, bottom: 90 })
          .layoutWeight(1)
          .scrollBar(BarState.Off)
        }
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
  }

  // ========== 辅助 Builder ==========

  @Builder
  statRow(label: string, value: string): void {
    Row() {
      Text(label)
        .fontSize(12).fontColor(this.theme.textTertiary).layoutWeight(1)
      Text(value)
        .fontSize(12).fontColor(this.theme.textPrimary)
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
    .border({
      width: { bottom: 0.5 },
      color: this.theme.borderGlass
    })
  }

  @Builder
  configBadge(label: string, active: boolean, onColor: string, offColor: string, altText?: string): void {
    Column() {
      Text(label)
        .fontSize(10).fontColor(this.theme.textTertiary).margin({ bottom: 4 })
      Text(altText ? altText : (active ? '开启' : '关闭'))
        .fontSize(11).fontColor(active ? onColor : offColor)
        .padding({ left: 10, right: 10, top: 3, bottom: 3 })
        .borderRadius(8)
        .backgroundColor(active ? onColor + '18' : offColor + '18')
    }
  }
}
