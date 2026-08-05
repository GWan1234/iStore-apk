/**
 * GlassCard - 毛玻璃卡片容器组件
 * 提供统一的玻璃拟态卡片外观：半透明背景 + 背景模糊 + 细边框
 * 支持标题栏（可选标题/副标题/右侧操作区）和自定义内容槽
 *
 * 使用方式：
 *   GlassCard({ theme: this.theme, title: '系统监控' }) {
 *     Text('自定义内容').fontColor(this.theme.textPrimary)
 *   }
 */
import { ThemePalette } from '../theme/ThemeColors'

@Component
export struct GlassCard {
  /** 主题调色板（由页面传入） */
  @Prop theme: ThemePalette
  /** 卡片标题（可省略） */
  @Prop title: string = ''
  /** 标题右侧的补充文字（可省略） */
  @Prop subtitle: string = ''
  /** 内容槽：卡片主体内容 */
  @BuilderParam content: () => void

  build() {
    Column() {
      if (this.title || this.subtitle) {
        Row() {
          Text(this.title)
            .fontSize(14)
            .fontColor(this.theme.textPrimary)
            .fontWeight(FontWeight.Medium)
          if (this.subtitle) {
            Text(`  ${this.subtitle}`)
              .fontSize(11)
              .fontColor(this.theme.textTertiary)
          }
          Blank()
        }
        .width('100%')
        .margin({ bottom: 12 })
      }

      this.content()
    }
    .width('100%')
    .padding(16)
    .borderRadius(14)
    .backgroundColor(this.theme.bgCard)
    .backdropBlur(20)
    .border({ width: 0.5, color: this.theme.borderGlass })
  }
}
