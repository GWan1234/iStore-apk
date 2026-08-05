/**
 * TrafficLineChart - 网络流量实时折线图
 * 绘制上行/下行两条平滑曲线（数据为字节/秒），带网格背景和刻度标签
 * 曲线颜色遵循中国习惯：上行青色、下行橙色（可自定义）
 *
 * 使用方式：
 *   TrafficLineChart({ theme: this.theme, rxData: this.rxList, txData: this.txList,
 *     chartMax: 1000000, chartWidth: 320, chartHeight: 120 })
 */
import { ThemePalette } from '../theme/ThemeColors'

@Component
export struct TrafficLineChart {
  /** 主题调色板 */
  @Prop theme: ThemePalette
  /** 下行速率历史（字节/秒） */
  @Prop rxData: number[]
  /** 上行速率历史（字节/秒） */
  @Prop txData: number[]
  /** 图表 Y 轴最大值（字节/秒） */
  @Prop chartMax: number
  /** 图表宽度（vp） */
  @Prop chartWidth: number
  /** 图表高度（vp） */
  @Prop chartHeight: number

  /** 生成平滑曲线路径（三次贝塞尔插值） */
  private smoothPath(data: number[], w: number, h: number, pad: number): string {
    if (data.length < 2) return ''
    const n = data.length
    const stepX = (w - pad * 2) / (n - 1)
    const pts: [number, number][] = []
    const maxVal: number = this.chartMax > 0 ? this.chartMax : 1
    for (let i = 0; i < n; i++) {
      const x = pad + i * stepX
      const ratio: number = Math.max(0, Math.min(1, data[i] / maxVal))
      const y = h - pad - ratio * (h - pad * 2)
      pts.push([x, y])
    }
    let cmd = `M${pts[0][0].toFixed(1)},${pts[0][1].toFixed(1)}`
    for (let i = 0; i < n - 1; i++) {
      const p0 = pts[i]
      const p1 = pts[i + 1]
      if (i < n - 2) {
        const p2 = pts[i + 2]
        const cp1x = p0[0] + (p1[0] - p0[0]) * 0.5
        const cp2x = p2[0] - (p2[0] - p1[0]) * 0.5
        cmd += ` C${cp1x.toFixed(1)},${p0[1].toFixed(1)} ${cp2x.toFixed(1)},${p2[1].toFixed(1)} ${p1[0].toFixed(1)},${p1[1].toFixed(1)}`
      } else {
        const cx = p0[0] + (p1[0] - p0[0]) * 0.5
        cmd += ` Q${cx.toFixed(1)},${p0[1].toFixed(1)} ${p1[0].toFixed(1)},${p1[1].toFixed(1)}`
      }
    }
    return cmd
  }

  /** 格式化刻度值（B/KB/MB） */
  private fmtTick(v: number): string {
    if (v >= 1048576) return `${(v / 1048576).toFixed(0)}M`
    if (v >= 1024) return `${(v / 1024).toFixed(0)}K`
    return `${v}B`
  }

  build() {
    if (this.rxData.length < 2 && this.txData.length < 2) {
      // 数据不足：显示空态
      Column() {
        Text('暂无流量数据')
          .fontSize(11)
          .fontColor(this.theme.textTertiary)
      }
      .width(this.chartWidth)
      .height(this.chartHeight)
      .justifyContent(FlexAlign.Center)
    } else {
      Stack() {
        // 背景网格
        Column() {
          ForEach([0, 1, 2, 3], (i: number) => {
            Row()
              .width('100%')
              .height(0.5)
              .backgroundColor(this.theme.borderGlass)
          })
        }
        .width(this.chartWidth)
        .height(this.chartHeight)
        .justifyContent(FlexAlign.SpaceBetween)
        .padding({ top: 12, bottom: 12 })

        // 下行曲线（青色）
        if (this.rxData.length >= 2) {
          Shape() {
            Path()
              .commands(this.smoothPath(this.rxData, this.chartWidth, this.chartHeight, 12))
              .stroke('#00D4FF')
              .strokeWidth(1.5)
              .antiAlias(true)
          }
          .width(this.chartWidth)
          .height(this.chartHeight)
        }

        // 上行曲线（橙色）
        if (this.txData.length >= 2) {
          Shape() {
            Path()
              .commands(this.smoothPath(this.txData, this.chartWidth, this.chartHeight, 12))
              .stroke('#FF9800')
              .strokeWidth(1.5)
              .antiAlias(true)
          }
          .width(this.chartWidth)
          .height(this.chartHeight)
        }

        // Y 轴刻度
        Text(this.fmtTick(this.chartMax))
          .fontSize(8)
          .fontColor(this.theme.textTertiary)
          .position({ x: 2, y: 2 })
        Text(this.fmtTick(Math.round(this.chartMax / 2)))
          .fontSize(8)
          .fontColor(this.theme.textTertiary)
          .position({ x: 2, y: this.chartHeight / 2 - 4 })
        Text('0')
          .fontSize(8)
          .fontColor(this.theme.textTertiary)
          .position({ x: 2, y: this.chartHeight - 14 })
      }
      .width(this.chartWidth)
      .height(this.chartHeight)
    }
  }
}
