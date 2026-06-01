import { AppState } from '../../common/store/AppState'
import { ThemePalette, DARK_THEME } from '../../common/theme/ThemeColors'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit'
import { SymbolGlyphModifier } from '@kit.ArkUI'
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
            normal: new SymbolGlyphModifier($r('sys.symbol.rectangle_on_rectangle_fill')),
            selected: new SymbolGlyphModifier($r('sys.symbol.rectangle_on_rectangle_fill'))
          }, '设备'))

          TabContent() {
            NetworkTab({ theme: this.theme })
          }
          .tabBar(new BottomTabBarStyle({
            normal: new SymbolGlyphModifier($r('sys.symbol.square_on_square_fill')),
            selected: new SymbolGlyphModifier($r('sys.symbol.square_on_square_fill'))
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
            normal: new SymbolGlyphModifier($r('sys.symbol.square_fill')),
            selected: new SymbolGlyphModifier($r('sys.symbol.square_fill'))
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
          barBottomMargin: 24,
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
    }
    .width('100%')
    .height('100%')
  }
}
