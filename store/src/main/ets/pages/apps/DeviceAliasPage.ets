/**
 * 设备外号生成器
 * 根据设备厂商/信号/在线状态生成趣味「社交外号」
 */
import { AppState } from '../../common/store/AppState'
import { LIGHT_THEME, ThemePalette } from '../../common/theme/ThemeColors'
import { ApiService } from '../../api/ApiService'
import { ConnectedDevice } from '../../models/Models'
import { hilog } from '@kit.PerformanceAnalysisKit'

interface AliasRow {
  name: string
  alias: string
  emoji: string
  isOnline: boolean
}

@Entry
@Component
export struct DeviceAliasPage {
  @State theme: ThemePalette = LIGHT_THEME
  @State topSafeArea: number = 44
  @State rows: AliasRow[] = []
  @State loading: boolean = false
  private api: ApiService = new ApiService()

  aboutToAppear(): void {
    this.theme = AppState.getInstance().getTheme()
    this.load()
  }

  async load(): Promise<void> {
    this.loading = true
    try {
      const devs: ConnectedDevice[] = await this.api.fetchConnectedDevices()
      const list: AliasRow[] = []
      for (let i = 0; i < devs.length; i++) {
        const d: ConnectedDevice = devs[i]
        const alias = this.genAlias(d, i)
        list.push({
          name: d.hostname || d.vendor || d.ip,
          alias: alias[0],
          emoji: alias[1],
          isOnline: d.isOnline
        })
      }
      this.rows = list
    } catch (e) {
      hilog.error(0x0001, 'DeviceAlias', `load err: ${String(e)}`)
    }
    this.loading = false
  }

  /** 生成外号：[外号, emoji] */
  private genAlias(d: ConnectedDevice, idx: number): string[] {
    const vendor: string = (d.vendor || '').toLowerCase()
    const host: string = (d.hostname || '').toLowerCase()
    const sig: number = d.signalStrength
    const rx: number = d.rxRate
    // 关键词匹配
    if (vendor.includes('apple') || host.includes('iphone') || host.includes('ipad') || host.includes('mac')) {
      return ['果粉大户', '🍎']
    }
    if (vendor.includes('xiaomi') || host.includes('mi ') || host.includes('redmi')) {
      return ['小米钉子户', '📱']
    }
    if (vendor.includes('huawei') || host.includes('huawei')) {
      return ['国产之光', '🇨🇳']
    }
    if (host.includes('nas') || host.includes('synology') || host.includes('qnap')) {
      return ['数据仓库管理员', '🗄']
    }
    if (host.includes('tv') || host.includes('box') || host.includes('miot') || host.includes('dangbei')) {
      return ['客厅剧粉', '📺']
    }
    if (host.includes('printer') || host.includes('print')) {
      return ['打印小工', '🖨']
    }
    if (host.includes('camera') || host.includes('ipc')) {
      return ['监控探头', '📹']
    }
    if (host.includes('xiaodu') || host.includes('tianmao') || host.includes('genie')) {
      return ['语音小助手', '🔊']
    }
    // 信号与流量
    if (rx >= 500000) {
      return ['大水管', '💦']
    }
    if (sig < -75 && sig !== 0) {
      return ['信号难民', '📶']
    }
    if (sig > -45) {
      return ['贴脸蹭网选手', '😈']
    }
    const pool: string[][] = [
      ['神秘访客', '🕵️'], ['网速刺客', '🗡'], ['隐形设备', '👻'],
      ['蹭网嫌疑犯', '🕸'], ['深夜下载党', '🌙'], ['老实巴交设备', '🐑']
    ]
    return pool[idx % pool.length]
  }

  build() {
    Column() {
      // 标题栏
      Row() {
        Row() {
          Text('‹')
            .fontSize(22).fontColor(this.theme.textPrimary)
            .padding({ left: 10, right: 6 })
          Text('设备外号生成器')
            .fontSize(16).fontColor(this.theme.textPrimary).fontWeight(FontWeight.Medium)
        }
        .padding({ left: 4, right: 16, top: 6, bottom: 6 })
        .borderRadius(100)
        .backgroundColor(this.theme.bgCard)
        .border({ width: 0.5, color: this.theme.borderGlass })
        .onClick(() => { this.getUIContext().getRouter().back() })
        Blank()
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: this.topSafeArea + 4, bottom: 8 })

      Scroll() {
        Column() {
          ForEach(this.rows, (row: AliasRow) => {
            Row() {
              Text(row.emoji).fontSize(28).width(44)
              Column() {
                Text(row.alias)
                  .fontSize(14).fontColor(this.theme.textPrimary).fontWeight(FontWeight.Bold)
                Text(row.name)
                  .fontSize(10).fontColor(this.theme.textTertiary).margin({ top: 3 })
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .alignItems(HorizontalAlign.Start).layoutWeight(1)
              .margin({ left: 10 })
              Circle({ width: 6, height: 6 })
                .fill(row.isOnline ? '#00C853' : '#C9C4B8')
              Text(row.isOnline ? ' 在线' : ' 离线')
                .fontSize(9).fontColor(row.isOnline ? '#00C853' : '#B0A99A')
            }
            .width('100%')
            .padding({ left: 14, right: 14, top: 12, bottom: 12 })
            .borderRadius(16)
            .margin({ top: 10 })
            .backgroundColor(this.theme.bgCard)
          }, (row: AliasRow): string => row.name)

          if (this.rows.length === 0 && !this.loading) {
            Text('没有在线设备，外号无处安放')
              .fontSize(12).fontColor(this.theme.textTertiary).margin({ top: 30 })
          }

          Row() {
            Text('↻ 重新起外号')
              .fontSize(13).fontColor('#FFFFFF').fontWeight(FontWeight.Medium)
          }
          .width('100%').height(44).borderRadius(22)
          .backgroundColor('#FF8A3D')
          .justifyContent(FlexAlign.Center)
          .margin({ top: 16 })
          .onClick(() => { this.load() })
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 40 })
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
    }
    .width('100%').height('100%')
    .linearGradient({
      angle: 135,
      colors: [['#F6F2EA', 0], ['#FAF7F0', 0.5], ['#F6F2EA', 1]]
    })
  }
}
