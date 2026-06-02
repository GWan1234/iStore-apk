import { AppState } from '../../common/store/AppState'
import { ThemePalette, DARK_THEME } from '../../common/theme/ThemeColors'
import { IStoreApp } from '../../models/Models'
import { ApiService } from '../../api/ApiService'
import { hilog } from '@kit.PerformanceAnalysisKit'

@Component
export struct IStoreTabView {
  @Prop theme: ThemePalette
  @State apps: IStoreApp[] = []
  @State isLoading: boolean = true
  @State errorText: string = ''
  private api: ApiService = new ApiService()
  private lastScrollY: number = 0
  aboutToAppear(): void {
    this.loadApps()
  }

  async loadApps(): Promise<void> {
    this.isLoading = true
    this.errorText = ''
    try {
      this.apps = await this.api.fetchIStoreApps()
      if (this.apps.length === 0) {
        this.errorText = '暂无已安装的应用'
      }
    } catch (e) {
      this.errorText = '加载失败，请重试'
    }
    this.isLoading = false
  }

  getIconUrl(app: IStoreApp): string {
    if (app.icon) {
      const device = AppState.getInstance().getActiveDevice()
      if (device) {
        const base = `http://${device.host}:${device.port}`
        return app.icon.startsWith('http') ? app.icon : `${base}${app.icon}`
      }
    }
    return ''
  }

  build() {
    Scroll() {
      Column() {
        Text('📦 iStore')
          .fontSize(20).fontWeight(FontWeight.Bold)
          .fontColor(this.theme.textPrimary).width('100%').margin({ top: 12 })

        Text('已安装的应用列表')
          .fontSize(13).fontColor(this.theme.textSecondary).margin({ top: 8 }).width('100%')

        if (this.isLoading) {
          Column() {
            LoadingProgress().width(32).height(32).color(this.theme.primary)
            Text('加载中...').fontSize(13).fontColor(this.theme.textTertiary).margin({ top: 12 })
          }
          .width('100%').padding(40).alignItems(HorizontalAlign.Center).margin({ top: 20 })
        } else if (this.errorText) {
          Text(this.errorText)
            .fontSize(13).fontColor(this.theme.textTertiary)
            .width('100%').textAlign(TextAlign.Center).margin({ top: 40 })
        } else {
          Column() {
            ForEach(this.apps, (app: IStoreApp) => {
              Row() {
                Column() {
                  Image(this.getIconUrl(app))
                    .width(44).height(44).objectFit(ImageFit.Cover).borderRadius(12)
                }
                .width(44).height(44).borderRadius(12)
                .backgroundColor(this.theme.bgGlassLight)
                .justifyContent(FlexAlign.Center)

                Column() {
                  Text(app.title || app.name)
                    .fontSize(14).fontColor(this.theme.textPrimary).fontWeight(FontWeight.Medium)
                  Text(app.version ? `v${app.version}` : '')
                    .fontSize(11).fontColor(this.theme.textTertiary).margin({ top: 2 })
                }
                .alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 12 })

                Text('打开 ›')
                  .fontSize(12).fontColor(this.theme.primary).fontWeight(FontWeight.Medium)
              }
              .width('100%').padding({ top: 14, bottom: 14, left: 14, right: 14 })
              .borderRadius(12).margin({ bottom: 8 })
              .backgroundColor(this.theme.bgCard).backdropBlur(20)
              .border({ width: 0.5, color: this.theme.borderGlass })
              .onClick(() => {
                if (app.link) {
                  const device = AppState.getInstance().getActiveDevice()
                  if (device) {
                    const base = `http://${device.host}:${device.port}`
                    const url = app.link.startsWith('http') ? app.link : `${base}${app.link}`
                    try {
                      this.getUIContext().getRouter().pushUrl({
                        url: 'pages/apps/WebViewPage',
                        params: { url: url }
                      })
                    } catch (e) {
                      hilog.error(0x0001, 'IStoreTab', `pushUrl failed: ${e}`)
                    }
                  }
                }
              })
            }, (app: IStoreApp): string => app.name)
          }
          .width('100%').margin({ top: 12 })
        }
      }
      .width('100%').padding({ left: 16, right: 16, bottom: 120 })
    }
    .width('100%').height('100%').scrollBar(BarState.Off)
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
