@Component
export struct DualLineChart {
  @Prop cpuData: number[]
  @Prop memData: number[]
  @Prop chartMax: number
  @Prop chartWidth: number
  @Prop chartHeight: number

  private smoothPath(data: number[], w: number, h: number, pad: number): string {
    if (data.length < 2) return ''
    const n = data.length
    const stepX = (w - pad * 2) / (n - 1)
    const pts: [number, number][] = []
    for (let i = 0; i < n; i++) {
      const x = pad + i * stepX
      const y = h - pad - (data[i] / this.chartMax) * (h - pad * 2)
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

  build() {
    if (this.cpuData.length < 2 && this.memData.length < 2) {
      Row().width(this.chartWidth).height(this.chartHeight)
    } else {
      Stack() {
        Row()
          .width(this.chartWidth)
          .height(this.chartHeight)
          .backgroundColor('rgba(18,22,55,0.6)')
          .borderRadius(6)
          .border({ width: 0.5, color: 'rgba(100,149,237,0.15)' })

        if (this.cpuData.length >= 2) {
          Shape() {
            Path()
              .commands(this.smoothPath(this.cpuData, this.chartWidth, this.chartHeight, 12))
              .stroke('#FF9800')
              .strokeWidth(1.5)
              .antiAlias(true)
          }
          .width(this.chartWidth)
          .height(this.chartHeight)
        }

        if (this.memData.length >= 2) {
          Shape() {
            Path()
              .commands(this.smoothPath(this.memData, this.chartWidth, this.chartHeight, 12))
              .stroke('#64B5F6')
              .strokeWidth(1.5)
              .antiAlias(true)
          }
          .width(this.chartWidth)
          .height(this.chartHeight)
        }

        Text(`${this.chartMax.toFixed(0)}%`)
          .fontSize(8).fontColor('rgba(255,255,255,0.35)')
          .position({ x: 4, y: 12 })

        Text(`${(this.chartMax / 2).toFixed(0)}%`)
          .fontSize(8).fontColor('rgba(255,255,255,0.25)')
          .position({ x: 4, y: this.chartHeight / 2 - 5 })

        Text('0%')
          .fontSize(8).fontColor('rgba(255,255,255,0.25)')
          .position({ x: 4, y: this.chartHeight - 16 })
      }
      .width(this.chartWidth)
      .height(this.chartHeight)
    }
  }
}
