import { AppState } from '../../common/store/AppState'
import { ThemePalette, DARK_THEME } from '../../common/theme/ThemeColors'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit'
import { SymbolGlyphModifier, window } from '@kit.ArkUI'
import { DashboardTab } from './DashboardTab'
import { DeviceTab } from './DeviceTab'
import { IStoreTabView } from './IStoreTabView'
import { DockerTab } from './DockerTab'
import { NetworkTab } from './NetworkTab'

@Entry
@Component
struct MainPage {
  @State theme: ThemePalette = DARK_THEME
  @State isDark: boolean = true
  @State deviceName: string = ''
  @State navHidden: boolean = false
  @State bottomSafeArea: number = 20  // 默认 20vp，覆盖大部分设备的导航指示条高度
  private lastScrollOffset: number = 0
  private tabsController: HdsTabsController = new HdsTabsController()

  aboutToAppear(): void {
    this.isDark = AppState.getInstance().isDarkMode
    this.theme = AppState.getInstance().getTheme()
    const device = AppState.getInstance().getActiveDevice()
    this.deviceName = device ? (device.label || device.host) : '未连接'

    AppState.getInstance().onThemeChange(() => {
      this.isDark = AppState.getInstance().isDarkMode
      this.theme = AppState.getInstance().getTheme()
    })

    AppState.getInstance().onNavChange(() => {
      this.navHidden = AppState.getInstance().isNavHidden()
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
        }).catch(() => { /* 保持默认值 */ })
      }
    } catch (_) { /* 保持默认值 20vp */ }
  }

  aboutToDisappear(): void {
    AppState.getInstance().offNavChange(() => {})
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
            NetworkTab({ theme: this.theme })
          }
          .tabBar(new BottomTabBarStyle({
            normal: new SymbolGlyphModifier($r('sys.symbol.wifi_router_fill')),
            selected: new SymbolGlyphModifier($r('sys.symbol.wifi_router_fill'))
          }, '网络'))

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
              Text('正在打开应用中心...')
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
            try {
              this.getUIContext().getRouter().pushUrl({ url: 'pages/apps/AppsPage' })
            } catch (e) {
              hilog.error(0x0001, 'MainPage', `pushUrl failed: ${e}`)
            }
            this.tabsController.changeIndex(0)
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
        .animation({ duration: 300, curve: Curve.EaseInOut })
      }
      .width('100%')
      .height('100%')
      .padding({ bottom: '4%' })
    }
    .width('100%')
    .height('100%')
  }
}
