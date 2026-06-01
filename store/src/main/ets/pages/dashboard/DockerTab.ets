import { AppState } from '../../common/store/AppState'
import { ThemePalette, DARK_THEME } from '../../common/theme/ThemeColors'
import { DockerOverview, DockerContainer } from '../../models/Models'
import { ApiService } from '../../api/ApiService'
import { hilog } from '@kit.PerformanceAnalysisKit'

@Component
export struct DockerTab {
  @Prop theme: ThemePalette
  @State overview: DockerOverview = { dockerVersion: '', daemonStatus: 'stopped', containersTotal: 0, containersRunning: 0, imagesTotal: 0, diskUsed: '0', memUsedMb: '0' }
  @State containers: DockerContainer[] = []
  @State isLoading: boolean = true
  @State errorText: string = ''
  @State actionContainer: string = ''
  @State dockerStarting: boolean = false
  @State isRefreshing: boolean = false
  private api: ApiService = new ApiService()
  private refreshTimer: number = -1

  aboutToAppear(): void {
    this.loadData()
    this.refreshTimer = setInterval(() => { this.refreshSilently() }, 5000)
  }

  aboutToDisappear(): void {
    if (this.refreshTimer !== -1) {
      clearInterval(this.refreshTimer)
      this.refreshTimer = -1
    }
  }

  async loadData(): Promise<void> {
    this.isLoading = true
    this.errorText = ''
    try {
      this.overview = await this.api.fetchDockerOverview()
      if (this.overview.daemonStatus === 'running') {
        this.containers = await this.api.fetchDockerContainers()
      }
    } catch (e) {
      this.errorText = '加载失败'
    }
    this.isLoading = false
  }

  async refreshSilently(): Promise<void> {
    try {
      this.overview = await this.api.fetchDockerOverview()
      if (this.overview.daemonStatus === 'running') {
        this.containers = await this.api.fetchDockerContainers()
      }
    } catch (e) {
      hilog.error(0x0001, 'DockerTab', `refreshSilently err: ${String(e)}`)
    }
  }

  async startDocker(): Promise<void> {
    this.dockerStarting = true
    const ok = await this.api.dockerServiceAction('start')
    if (ok) {
      await this.loadData()
    } else {
      this.errorText = '启动 Docker 失败'
    }
    this.dockerStarting = false
  }

  async onRefresh(): Promise<void> {
    this.isRefreshing = true
    await this.loadData()
    this.isRefreshing = false
  }

  async containerAction(container: string, action: string): Promise<void> {
    this.actionContainer = container
    const ok = await this.api.dockerContainerAction(container, action)
    if (ok) {
      this.containers = this.containers.map((c: DockerContainer): DockerContainer => {
        if (c.name === container) {
          const updated: DockerContainer = { id: c.id, name: c.name, image: c.image, running: c.running, status: c.status }
          switch (action) {
            case 'start':
              updated.status = 'Starting...'
              break
            case 'stop':
              updated.status = 'Stopping...'
              break
            case 'restart':
              updated.status = 'Restarting...'
              updated.running = false
              break
          }
          return updated
        }
        return c
      })
      setTimeout(async () => {
        await this.refreshSilently()
        this.actionContainer = ''
        this.isRefreshing = true
        setTimeout(() => { this.isRefreshing = false }, 400)
      }, 2000)
    } else {
      this.errorText = `${action} ${container} 失败`
      this.actionContainer = ''
    }
  }

  getStatusColor(): string {
    return this.overview.daemonStatus === 'running' ? '#4CAF50' : '#FF5252'
  }

  getStatusText(): string {
    return this.overview.daemonStatus === 'running' ? '运行中' : '已停止'
  }

  containerIconUrl(image: string): string {
    if (!image) return ''
    let name = image
    const atIdx = name.indexOf('@')
    if (atIdx !== -1) {
      name = name.substring(0, atIdx)
    }
    const colonIdx = name.indexOf(':')
    if (colonIdx !== -1) {
      name = name.substring(0, colonIdx)
    }
    const parts = name.split('/')
    if (parts.length >= 3) {
      name = parts[parts.length - 2] + '/' + parts[parts.length - 1]
    }
    return `https://xuanyuan.cloud/api/logo/${name}.png`
  }

  build() {
    Scroll() {
      Refresh({ refreshing: $$this.isRefreshing }) {
        Column() {
          Text('🐳 Docker')
            .fontSize(20).fontWeight(FontWeight.Bold)
          .fontColor(this.theme.textPrimary).width('100%').margin({ top: 12 })

        if (this.isLoading) {
          Column() {
            LoadingProgress().width(32).height(32).color(this.theme.primary)
            Text('加载中...').fontSize(13).fontColor(this.theme.textTertiary).margin({ top: 12 })
          }
          .width('100%').padding(40).alignItems(HorizontalAlign.Center).margin({ top: 20 })
        } else if (this.errorText && this.containers.length === 0) {
          Text(this.errorText)
            .fontSize(13).fontColor(this.theme.textTertiary)
            .width('100%').textAlign(TextAlign.Center).margin({ top: 40 })
        } else {
          Row() {
            Column() {
              Text('Daemon')
                .fontSize(11).fontColor(this.theme.textTertiary)
              Row() {
                Circle({ width: 8, height: 8 }).fill(this.getStatusColor())
                Text(this.getStatusText())
                  .fontSize(18).fontColor(this.getStatusColor()).fontWeight(FontWeight.Bold)
                  .margin({ left: 6 })
              }
              .margin({ top: 4 })
            }
            .alignItems(HorizontalAlign.Center).layoutWeight(1)

            Column() {
              Text('容器')
                .fontSize(11).fontColor(this.theme.textTertiary)
              Text(`${this.overview.containersRunning}/${this.overview.containersTotal}`)
                .fontSize(18).fontColor(this.theme.textPrimary).fontWeight(FontWeight.Bold)
            }
            .alignItems(HorizontalAlign.Center).layoutWeight(1)

            Column() {
              Text('镜像')
                .fontSize(11).fontColor(this.theme.textTertiary)
              Text(`${this.overview.imagesTotal}`)
                .fontSize(18).fontColor(this.theme.textPrimary).fontWeight(FontWeight.Bold)
            }
            .alignItems(HorizontalAlign.Center).layoutWeight(1)

            Column() {
              Text('磁盘')
                .fontSize(11).fontColor(this.theme.textTertiary)
              Text(this.overview.diskUsed)
                .fontSize(14).fontColor(this.theme.textPrimary).fontWeight(FontWeight.Bold)
            }
            .alignItems(HorizontalAlign.Center).layoutWeight(1)
          }
          .width('100%').padding(16).borderRadius(14).margin({ top: 12 })
          .backgroundColor(this.theme.bgCard).backdropBlur(20)
          .border({ width: 0.5, color: this.theme.borderGlass })

          if (this.overview.daemonStatus !== 'running') {
            Row() {
              Text('Docker 服务未运行')
                .fontSize(13).fontColor(this.theme.textSecondary).layoutWeight(1)
              if (this.dockerStarting) {
                Row() {
                  LoadingProgress().width(14).height(14).color(this.theme.primary)
                  Text('启动中...').fontSize(13).fontColor(this.theme.primary).margin({ left: 6 })
                }
                .padding({ top: 8, bottom: 8, left: 16, right: 16 }).borderRadius(8)
                .backgroundColor(this.theme.bgGlassLight)
              } else {
                Text('启动 Docker')
                  .fontSize(13).fontColor(this.theme.primary).fontWeight(FontWeight.Medium)
                  .padding({ top: 8, bottom: 8, left: 16, right: 16 }).borderRadius(8)
                  .backgroundColor(this.theme.bgGlassLight)
                  .onClick(() => { this.startDocker() })
              }
            }
            .width('100%').padding(14).borderRadius(12).margin({ top: 12 })
            .backgroundColor(this.theme.bgCard).backdropBlur(20)
            .border({ width: 0.5, color: this.theme.borderGlass })
          } else {
            if (this.overview.dockerVersion) {
              Text(`Docker ${this.overview.dockerVersion}`)
                .fontSize(11).fontColor(this.theme.textTertiary)
                .width('100%').padding({ left: 4, top: 14 })
            }

            if (this.containers.length > 0) {
              Text('容器列表')
                .fontSize(12).fontColor(this.theme.textTertiary)
                .width('100%').padding({ left: 4, top: 12, bottom: 6 })

              ForEach(this.containers, (c: DockerContainer) => {
                Column() {
                  Row() {
                    Column() {
                      if (this.actionContainer === c.name) {
                        LoadingProgress().width(16).height(16).color(this.theme.primary)
                      } else {
                        Image(this.containerIconUrl(c.image))
                          .width(36).height(36).objectFit(ImageFit.Cover).borderRadius(8)
                      }
                    }
                    .width(36).height(36).borderRadius(8)
                    .backgroundColor('rgba(200,200,200,0.15)')
                    .justifyContent(FlexAlign.Center)

                    Column() {
                      Text(c.name)
                        .fontSize(14).fontColor(this.theme.textPrimary).fontWeight(FontWeight.Medium)
                      Text(this.actionContainer === c.name ? '操作中...' : c.status)
                        .fontSize(11).fontColor(this.theme.textTertiary).margin({ top: 2 })
                        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    }
                    .alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 10 })

                    if (this.actionContainer === c.name) {
                      LoadingProgress().width(16).height(16).color(this.theme.primary)
                        .margin({ right: 12 })
                    } else if (c.running) {
                      Text('停止')
                        .fontSize(11).fontColor('#FF5252').fontWeight(FontWeight.Medium)
                        .padding({ top: 6, bottom: 6, left: 12, right: 12 }).borderRadius(6)
                        .backgroundColor(this.theme.bgGlassLight)
                        .onClick(() => { this.containerAction(c.name, 'stop') })
                      Text('重启')
                        .fontSize(11).fontColor(this.theme.primary).fontWeight(FontWeight.Medium)
                        .padding({ top: 6, bottom: 6, left: 12, right: 12 }).borderRadius(6)
                        .backgroundColor(this.theme.bgGlassLight).margin({ left: 6 })
                        .onClick(() => { this.containerAction(c.name, 'restart') })
                    } else {
                      Text('启动')
                        .fontSize(11).fontColor('#4CAF50').fontWeight(FontWeight.Medium)
                        .padding({ top: 6, bottom: 6, left: 16, right: 16 }).borderRadius(6)
                        .backgroundColor(this.theme.bgGlassLight)
                        .onClick(() => { this.containerAction(c.name, 'start') })
                    }
                  }
                  .width('100%')
                }
                .width('100%').padding(12).borderRadius(12).margin({ top: 6 })
                .backgroundColor(this.theme.bgCard).backdropBlur(20)
                .border({ width: 0.5, color: this.theme.borderGlass })
              }, (c: DockerContainer): string => c.id)
            } else {
              Text('暂无容器')
                .fontSize(12).fontColor(this.theme.textTertiary)
                .width('100%').textAlign(TextAlign.Center).padding(20)
            }
          }
        }
      }
      .width('100%').padding({ left: 16, right: 16, bottom: 120 })
      }
      .onRefreshing(() => { this.onRefresh() })
    }
    .width('100%').height('100%').scrollBar(BarState.Off)
  }
}
