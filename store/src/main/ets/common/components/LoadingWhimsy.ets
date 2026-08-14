/**
 * LoadingWhimsy - 拟人化加载组件
 * 三颗错峰弹跳圆点 + 随机轮换小字，替代干巴巴的"加载中..."
 */
import { LOADING_WORDS } from '../utils/WhimsyUtil'

@Component
export struct LoadingWhimsy {
  @Prop message: string = ''   // 自定义文案（可选）
  @State pulse: boolean = false
  private timer: number = -1

  aboutToAppear(): void {
    this.pulse = false
    this.timer = setInterval(() => {
      this.pulse = !this.pulse
    }, 400)
  }

  aboutToDisappear(): void {
    if (this.timer !== -1) {
      clearInterval(this.timer)
      this.timer = -1
    }
  }

  /** 圆点动画（0/2 同相，1 反相 → 波浪弹跳） */
  @Builder
  dot(phase: number) {
    Circle()
      .width(9)
      .height(9)
      .fill('#FF8A3D')
      .translate({ y: this.pulse === (phase === 1) ? -6 : 3 })
      .animation({ duration: 380, curve: Curve.EaseInOut })
  }

  build() {
    Column({ space: 14 }) {
      Row({ space: 6 }) {
        this.dot(0)
        this.dot(1)
        this.dot(2)
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)

      Text(this.message.length > 0 ? this.message : LOADING_WORDS[Math.floor(Math.random() * LOADING_WORDS.length)])
        .fontSize(13)
        .fontColor('#A69B8F')
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
  }
}
