/**
 * WhimsyUtil - 愉悦体验公共设施
 * 文案库 / 震动反馈 / 彩蛋计数（连点触发）
 */
import { promptAction } from '@kit.ArkUI'
import { vibrator } from '@kit.SensorServiceKit'
import { hilog } from '@kit.PerformanceAnalysisKit'

const DOMAIN = 0x0001
const TAG = 'Whimsy'

/** 加载状态随机小字（轮换使用，增加等待趣味） */
export const LOADING_WORDS: string[] = [
  '正在数有几个设备在摸鱼…',
  '正在看网速脸色…',
  '把 CPU 温度读出来…',
  '正在给数据排队…',
  '翻一下最近的上网记录…',
  '把每个接口都点个名…'
]

/** 刷新鼓励语 */
export const REFRESH_WORDS: string[] = [
  '冲！',
  '让数据飞一会儿 🚀',
  '稍等，网络在呼吸…',
  '正在捞新鲜数据…'
]

/** 空状态拟人文案（各页面直接内联使用，见 EMPTY_WORDS 替换） */

/** 彩蛋：连点 N 次触发（计数器，内存态） */
export class Whimsy {
  private static countMap: Map<string, number> = new Map()

  /**
   * 连点计数：同一 key 在 1.5 秒内连点，达到 times 返回 true 并清零
   * @param key 彩蛋标识
   * @param times 触发次数
   */
  static tap(key: string, times: number): boolean {
    const now: number = Date.now()
    const last: number = Whimsy.countMap.get(key) || 0
    const cnt: number = Whimsy.countMap.get(`${key}_n`) || 0
    if (now - last > 1500) {
      Whimsy.countMap.set(`${key}_n`, 1)
    } else {
      Whimsy.countMap.set(`${key}_n`, cnt + 1)
    }
    Whimsy.countMap.set(key, now)
    const n: number = Whimsy.countMap.get(`${key}_n`) || 0
    if (n >= times) {
      Whimsy.countMap.set(`${key}_n`, 0)
      return true
    }
    return false
  }

  /** 轻震动反馈（30ms 短震） */
  static vibrate(): void {
    try {
      vibrator.startVibration({
        type: 'time',
        duration: 30
      }, {
        id: 0,
        usage: 'alarm'
      }).catch(() => {})
    } catch (e) {
      hilog.error(DOMAIN, TAG, `vibrate err: ${JSON.stringify(e)}`)
    }
  }

  /** 随机取一句文案 */
  static pick(words: string[]): string {
    const idx: number = Math.floor(Math.random() * words.length)
    return words[idx]
  }
}
