import { AppState } from '../../common/store/AppState'
import { ThemePalette, DARK_THEME } from '../../common/theme/ThemeColors'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit'
import { SymbolGlyphModifier, window } from '@kit.ArkUI'
import { DashboardTab } from './DashboardTab'
import { DeviceTab } from './DeviceTab'
import { IStoreTabView } from './IStoreTabView'
import { NotificationWatcher } from '../../common/store/NotificationWatcher'
import { NotifyStore } from '../../common/store/NotifyStore'
import { ScheduleStore } from '../../common/store/ScheduleStore'
import { DockerTab } from './DockerTab'
import { AlbumTab } from './AlbumTab'

@Entry
@Component
struct MainPage {
  @State theme: ThemePalette = DARK_THEME
  @State isDark: boolean = true
  @State deviceName: string = ''
  @State navHidden: boolean = false
  @State bottomSafeArea: number = 20  // 默认 20vp，覆盖大部分设备的导航指示条高度
  @State lastTabIndex: number = 0  // 进入应用中心前的 Tab（返回时恢复）
  private lastScrollOffset: number = 0
  private tabsController: HdsTabsController = new HdsTabsController()

  aboutToAppear(): void {
    this.isDark = AppState.getInstance().isDarkMode
    this.theme = AppState.getInstance().getTheme()
    const device = AppState.getInstance().getActiveDevice()
    this.deviceName = device ? (device.label || device.host) : '未连接'
    // 初始 Tab 为首页，广播给子页做前台感知
    AppState.getInstance().setCurrentTab(0)

    // 初始化通知/定时任务存储并启动检测器（App 前台期间 60s 检测）
    const hostCtx = this.getUIContext().getHostContext()
    if (hostCtx) {
      NotifyStore.getInstance().init(hostCtx as Context)
      ScheduleStore.getInstance().init(hostCtx as Context)
      NotificationWatcher.getInstance().start()
    }

    AppState.getInstance().onThemeChange(() => {
      this.isDark = AppState.getInstance().isDarkMode
      this.theme = AppState.getInstance().getTheme()
    })

    AppState.getInstance().onNavChange(() => {
      // 用 duration 0 的显式动画覆盖 .animation(300) 隐式动画，
      // 避免导航条 barBottomMargin 从底部位置突变到 -100 时播放"从顶部滑下"的大位移动画
      this.getUIContext().animateTo({ duration: 0 }, () => {
        this.navHidden = AppState.getInstance().isNavHidden()
      })
    })

    // 获取系统底部导航指示条 / 手势条高度（适配各机型）
    try {
      const ctx = this.getUIContext().getHostContext()
      if (ctx) {
        window.getLastWindow(ctx).then((win: window.Window) => {
          const avoidArea: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR)
          const h: number = px2vp(avoidArea.bottomRect.height)
          if (h > 0) {
            this.bottomSafeArea = h
          }
          // 广播悬浮主导航条占用的底部空间（手势条 + 130：悬浮边距28 + 导航条高度 + 材质/避让余量）
          AppState.getInstance().setBottomNavInset(this.bottomSafeArea + 130)
          hilog.info(0x0001, 'MainPage', `bottomSafeArea=${this.bottomSafeArea}, navInset=${this.bottomSafeArea + 130}`)
        }).catch(() => {
          AppState.getInstance().setBottomNavInset(this.bottomSafeArea + 130)
          hilog.info(0x0001, 'MainPage', `getLastWindow failed, navInset=${this.bottomSafeArea + 130}`)
        })
      } else {
        AppState.getInstance().setBottomNavInset(this.bottomSafeArea + 130)
      }
    } catch (_e) {
      AppState.getInstance().setBottomNavInset(this.bottomSafeArea + 130)
    }
  }

  aboutToDisappear(): void {
    AppState.getInstance().offNavChange(() => {})
    NotificationWatcher.getInstance().stop()
  }

  /** 页面重新可见（从应用中心返回等）：恢复进入前的 Tab */
  onPageShow(): void {
    // 从应用中心返回时，从系统占位 Tab 恢复到进入前的 Tab（设备→系统→返回→设备）
    if (this.lastTabIndex !== 5 && this.lastTabIndex >= 0 && this.lastTabIndex <= 4) {
      this.tabsController.changeIndex(this.lastTabIndex)
      AppState.getInstance().setCurrentTab(this.lastTabIndex)
    }
  }

  /**
   * 拦截系统返回（含侧滑返回手势）
   * 当相册处于子视图（相册详情/全部照片/全屏查看）时，先返回相册列表，不退出应用
   */
  onBackPress(): boolean {
    if (AppState.getInstance().isAlbumSubView()) {
      AppState.getInstance().notifyAlbumBack()
      return true
    }
    return false
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
        Row()
          .width('100%')
          .height(48)

        HdsTabs({ controller: this.tabsController }) {
          TabContent() {
            DashboardTab({ theme: this.theme })
          }
          .tabBar(new BottomTabBarStyle({
            normal: new SymbolGlyphModifier($r('sys.symbol.house_fill')),
            selected: new SymbolGlyphModifier($r('sys.symbol.house_fill'))
          }, '首页'))

          TabContent() {
            DeviceTab({ theme: this.theme })
          }
          .tabBar(new BottomTabBarStyle({
            normal: new SymbolGlyphModifier($r('sys.symbol.nearby_devices')),
            selected: new SymbolGlyphModifier($r('sys.symbol.nearby_devices'))
          }, '设备'))

          TabContent() {
            AlbumTab({ theme: this.theme })
          }
          .tabBar(new BottomTabBarStyle({
            normal: new SymbolGlyphModifier($r('sys.symbol.archivebox_fill')),
            selected: new SymbolGlyphModifier($r('sys.symbol.archivebox_fill'))
          }, '相册'))

          TabContent() {
            IStoreTabView({ theme: this.theme })
          }
          .tabBar(new BottomTabBarStyle({
            normal: new SymbolGlyphModifier($r('sys.symbol.bag_fill')),
            selected: new SymbolGlyphModifier($r('sys.symbol.bag_fill'))
          }, 'iStore'))

          TabContent() {
            DockerTab({ theme: this.theme })
          }
          .tabBar(new BottomTabBarStyle({
            normal: new SymbolGlyphModifier($r('sys.symbol.archivebox_fill')),
            selected: new SymbolGlyphModifier($r('sys.symbol.archivebox_fill'))
          }, 'Docker'))

          TabContent() {
            Column() {
              Text('🛠').fontSize(32).margin({ bottom: 12 })
              Text('系统工具')
                .fontSize(14).fontColor(this.theme.textSecondary)
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
          }
          .tabBar(new BottomTabBarStyle({
            normal: new SymbolGlyphModifier($r('sys.symbol.gearshape_fill')),
            selected: new SymbolGlyphModifier($r('sys.symbol.gearshape_fill'))
          }, '系统'))
        }
        .barOverlap(true)
        .barPosition(BarPosition.End)
        .vertical(false)
        .barMode(BarMode.Fixed)
        .scrollable(false)
        .onChange((index: number) => {
          if (index === 5) {
            // 系统 Tab：跳转应用中心，保持当前 Tab 高亮（不切回首页，避免"乱跳"）
            try {
              this.getUIContext().getRouter().pushUrl({ url: 'pages/apps/AppsPage' })
            } catch (e) {
              hilog.error(0x0001, 'MainPage', `pushUrl failed: ${e}`)
            }
            return
          }
          // 相册查看器/子视图打开时：拦截 Tab 滑动穿透，强制停留在相册 Tab
          if (AppState.getInstance().isAlbumSubView()) {
            if (index !== 2) {
              this.tabsController.changeIndex(2)
            }
            return
          }
          // 广播当前 Tab，供各子页做前台感知（暂停/恢复轮询）
          AppState.getInstance().setCurrentTab(index)
          // 记录当前 Tab（点"系统"跳应用中心时记住，返回时恢复）
          if (index >= 0 && index <= 4) {
            this.lastTabIndex = index
          }
        })
        .barFloatingStyle({
          barWidth: { smallWidth: 320, mediumWidth: 400, largeWidth: 480 },
          barBottomMargin: this.navHidden ? -100 : (28 + this.bottomSafeArea),
          gradientMask: { maskColor: this.isDark ? '#22000000' : '#33E8ECF1', maskHeight: 88 },
          systemMaterialEffect: {
            materialType: hdsMaterial.MaterialType.IMMERSIVE,
            materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
          }
        })
        .layoutWeight(1)
      }
      .width('100%')
      .height('100%')
      .padding({ bottom: '4%' })
    }
    .width('100%')
    .height('100%')
  }
}
