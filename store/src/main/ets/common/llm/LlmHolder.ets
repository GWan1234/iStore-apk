/**
 * LlmHolder - LLMManager 单例持有器
 * LLMManager 是构造器模式（需 UIAbilityContext），多个页面（模型商店/AI 助手）共享同一实例
 */
import { common } from '@kit.AbilityKit'
import { LLMManager } from './LLMManager'

export class LlmHolder {
  private static instance: LlmHolder
  private mgr: LLMManager | null = null

  static getInstance(): LlmHolder {
    if (!LlmHolder.instance) {
      LlmHolder.instance = new LlmHolder()
    }
    return LlmHolder.instance
  }

  /** 初始化（幂等）：拿到 manager 实例 */
  init(context: common.UIAbilityContext): LLMManager {
    if (!this.mgr) {
      this.mgr = new LLMManager(context)
    }
    return this.mgr
  }

  /** 获取 manager（未初始化返回 null） */
  get(): LLMManager | null {
    return this.mgr
  }
}
