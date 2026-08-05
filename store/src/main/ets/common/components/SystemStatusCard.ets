/**
 * SystemStatusCard - 系统状态指标卡片
 * 展示单个系统指标（如 CPU/内存/温度/存储），带渐变进度条
 * 进度条颜色自动根据阈值分级：正常(绿) < 警告(黄) < 危险(红)
 *
 * 使用方式：
 *   SystemStatusCard({ theme: this.theme, label: 'CPU', value: '23%',
 *     percent: 23, warnThreshold: 70, dangerThreshold: 90 })
 */
import { ThemePalette } from '../theme/ThemeColors'

@Component
export struct SystemStatusCard {
  /** 主题调色板 */
  @Prop theme: ThemePalette
  /** 指标名称 */
  @Prop label: string
  /** 展示值（如 "23%"、"1.2 GHz"） */
  @Prop value: string
  /** 百分比 0-100（用于进度条和阈值判断） */
  @Prop percent: number
  /** 警告阈值（默认 70） */
  @Prop warnThreshold: number = 70
  /** 危险阈值（默认 90） */
  @Prop dangerThreshold: number = 90

  /** 根据阈值返回进度条颜色（绿→黄→红） */
  private barColor(): string {
    if (this.percent >= this.dangerThreshold) {
      return this.theme.danger
    }
    if (this.percent >= this.warnThreshold) {
      return this.theme.warning
    }
    return this.theme.success
  }

  build() {
    Column() {
      Row() {
        Text(this.label)
          .fontSize(11)
          .fontColor(this.theme.textTertiary)
        Blank()
        Text(this.value)
          .fontSize(16)
          .fontColor(this.theme.textPrimary)
          .fontWeight(FontWeight.Bold)
      }
      .width('100%')

      // 进度条：底层轨道 + 上层渐变填充
      Stack({ alignContent: Alignment.Start }) {
        Row()
          .width('100%')
          .height(6)
          .borderRadius(3)
          .backgroundColor(this.theme.bgGlassLight)
        Row()
          .width(`${Math.max(0, Math.min(100, this.percent))}%`)
          .height(6)
          .borderRadius(3)
          .linearGradient({
            angle: 90,
            colors: [[this.barColor(), 0], [this.barColor(), 1]]
          })
      }
      .width('100%')
      .margin({ top: 8 })
    }
    .width('100%')
    .padding(14)
    .borderRadius(12)
    .backgroundColor(this.theme.bgCard)
    .backdropBlur(20)
    .border({ width: 0.5, color: this.theme.borderGlass })
  }
}
