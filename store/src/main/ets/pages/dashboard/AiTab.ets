/**
 * AiTab - 底部导航「AI」页（本地 AI 专属）
 * 特性：
 *  - 只提供本地 AI 聊天（快捷问答归「网络助手」页）
 *  - 进入自动加载上次使用的模型（模型被删除则跳过）
 *  - 加载成功后的欢迎语 = 小红书风格模型介绍
 *  - 底部避让悬浮导航条（切换模型行 + 输入栏上移）
 */
import { AppState } from '../../common/store/AppState'
import { LIGHT_THEME, ThemePalette } from '../../common/theme/ThemeColors'
import { ChatMsg } from '../../common/ai/AiHelper'
import { promptAction, router } from '@kit.ArkUI'
import { pasteboard } from '@kit.BasicServicesKit'
import { common } from '@kit.AbilityKit'
import { LlmHolder } from '../../common/llm/LlmHolder'
import { LLMManager, ModelInfo, stripAnswerTags } from '../../common/llm/LLMManager'
import { FunStore } from '../../common/store/FunStore'

@Component
export struct AiTab {
  @Prop theme: ThemePalette = LIGHT_THEME
  @State messages: ChatMsg[] = []
  @State inputText: string = ''
  @State aiThinking: boolean = false
  @State whimsySparkle: boolean = false
  @State installed: ModelInfo[] = []
  @State curModel: string = ''         // 当前模型名
  @State isLoaded: boolean = false
  @State isLoading: boolean = false
  @State llmReady: boolean = false     // LlmHolder 是否初始化
  @State bottomNavInset: number = 150  // 悬浮导航条占用高度（避让用）
  private listScroller: Scroller = new Scroller()

  aboutToAppear(): void {
    const hostCtx = this.getUIContext().getHostContext() as common.UIAbilityContext
    if (hostCtx) {
      LlmHolder.getInstance().init(hostCtx)
      this.llmReady = true
      this.refreshLlm()
      this.autoLoadRemembered()
    }
    // 底部导航条避让高度（默认 150：20 手势条 + 130 悬浮条）
    this.bottomNavInset = AppState.getInstance().getBottomNavInset()
    // 默认欢迎语（未加载模型时）
    if (this.messages.length === 0) {
      this.messages.push({ role: 'ai', text: '你好，我是 iStore 本地 AI\n完全离线对话，隐私不上传。\n先去模型商店下载一个小模型吧～' })
    }
    // 订阅主 Tab 切换：切回本页时刷新模型状态
    AppState.getInstance().onTabChange((tab: number) => {
      if (tab === 1) {
        this.refreshLlm()
        this.autoLoadRemembered()
      }
    })
  }

  aboutToDisappear(): void {
    AppState.getInstance().offTabChange(() => {})
  }

  /** 自动加载上次使用的模型（模型被删除则跳过不加载） */
  autoLoadRemembered(): void {
    const mgr: LLMManager | null = LlmHolder.getInstance().get()
    if (!mgr || this.isLoading || this.isLoaded) return
    const last: string = mgr.getRememberedModel()
    if (!last) return
    // 模型已删除（不在已装列表）→ 不加载
    const found: boolean = this.installed.some((m: ModelInfo) => m.name === last)
    if (!found) return
    this.loadCurModel(last)
  }

  /** 本地 LLM 流式聊天 */
  async sendLlm(text: string): Promise<void> {
    const mgr: LLMManager | null = LlmHolder.getInstance().get()
    if (!mgr || !mgr.isLoaded) {
      promptAction.showToast({ message: '请先加载模型', duration: 1500 })
      return
    }
    // 情感触点：首次对话自我介绍
    if (!FunStore.getInstance().hasAiChatted()) {
      FunStore.getInstance().setAiChatted()
      this.messages.push({ role: 'ai', text: '你好，我是跑在路由器里的本地 AI——小管 🤫\n你问我答，数据都在家里，不会出门。开始吧！' })
    }
    this.messages.push({ role: 'user', text: text })
    this.inputText = ''
    this.aiThinking = true
    // 追加占位 ai 消息，流式填充
    this.messages.push({ role: 'ai', text: '…' })
    const idx: number = this.messages.length - 1
    let acc: string = ''
    try {
      await mgr.chat(text, (delta: string) => {
        acc += delta
        const msgs: ChatMsg[] = this.messages.slice()
        msgs[idx] = { role: 'ai', text: acc }
        this.messages = msgs
        this.scrollToBottom()
      }, () => {})
    } catch (e) {
      acc = ''
    }
    this.aiThinking = false
    // 完整回复整体清理：流式增量可能把 <answer> 标签拆成多片段，此处兜底移除
    if (acc) {
      acc = stripAnswerTags(acc)
    }
    const msgs: ChatMsg[] = this.messages.slice()
    msgs[idx] = acc
      ? { role: 'ai', text: acc }
      : { role: 'ai', text: '（模型未输出，请检查模型是否正常）' }
    this.messages = msgs
    // 回复完成微光：AI 消息右下标出星星闪烁一下
    if (acc) {
      this.whimsySparkle = true
      setTimeout(() => { this.whimsySparkle = false }, 1200)
    }
    this.scrollToBottom()
  }

  /** 刷新本地模型状态 */
  refreshLlm(): void {
    const mgr: LLMManager | null = LlmHolder.getInstance().get()
    if (!mgr) return
    // 过滤下载未完成的模型（.tmp 残留）：避免误加载报"权重文件缺失"，下载中模型由商店页展示"下载中"
    this.installed = mgr.listModels().filter((m: ModelInfo) => !m.downloading)
    this.isLoaded = mgr.isLoaded
    this.isLoading = mgr.isLoading
    const dir: string = mgr.modelDir
    this.curModel = dir.startsWith('models/') ? dir.substring(7) : ''
  }

  /** 加载当前选中的已装模型 */
  async loadCurModel(name: string): Promise<void> {
    const mgr: LLMManager | null = LlmHolder.getInstance().get()
    if (!mgr || mgr.isLoading) return
    this.isLoading = true
    const code: number = await mgr.loadModel(`models/${name}`)
    this.isLoading = false
    this.refreshLlm()
    if (code === 0) {
      this.showModelWelcome(name)
    } else {
      const why: string = mgr.lastLoadError || '模型不完整'
      promptAction.showToast({ message: `加载失败：${why}，可去商店删除后重下`, duration: 2500 })
    }
  }

  /** 小红书风格模型介绍欢迎语 */
  showModelWelcome(name: string): void {
    const mgr: LLMManager | null = LlmHolder.getInstance().get()
    const sizeMB: number = this.modelSizeMB(name)
    const sizeText: string = sizeMB > 0 ? `📦 模型大小 · ${sizeMB} MB` : '📦 模型大小 · 轻量'
    const welcome: string =
      `已加载模型：${name}\n\n` +
      `${sizeText}\n` +
      `🔒 完全离线 · 对话不上传\n\n` +
      `💬 现在可以和我聊天啦～\n` +
      `试试问我：「帮我写一段周报」「解释什么是 NAT」\n\n` +
      `#本地AI #离线对话 #iStore路由管家`
    const msgs: ChatMsg[] = this.messages.slice()
    // 替换开场欢迎语（若无则插入）
    if (msgs.length > 0 && msgs[0].role === 'ai' && msgs[0].text.startsWith('你好，我是')) {
      msgs[0] = { role: 'ai', text: welcome }
    } else {
      msgs.unshift({ role: 'ai', text: welcome })
    }
    this.messages = msgs
  }

  /** 已装模型大小（MB） */
  private modelSizeMB(name: string): number {
    const found = this.installed.find((m: ModelInfo) => m.name === name)
    return found ? found.sizeMB : 0
  }

  /** 去模型商店 */
  goShop(): void {
    try {
      router.pushUrl({ url: 'pages/apps/ModelShopPage' })
    } catch (e) {}
  }

  /** 滚动到底部 */
  private scrollToBottom(): void {
    try {
      this.listScroller.scrollEdge(Edge.Bottom)
    } catch (e) {}
  }

  /** 复制消息文本到剪贴板 */
  copyText(text: string): void {
    try {
      const data = pasteboard.createData('text/plain', text)
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        promptAction.showToast({ message: '已复制', duration: 1200 })
      }).catch(() => {
        promptAction.showToast({ message: '复制失败', duration: 1200 })
      })
    } catch (e) {
      promptAction.showToast({ message: '复制失败', duration: 1200 })
    }
  }

  /** 消息气泡 */
  @Builder
  bubble(msg: ChatMsg, idx: number) {
    Row() {
      if (msg.role === 'user') {
        Blank()
        Column() {
          Text(msg.text)
            .fontSize(14)
            .fontColor('#FFFFFF')
            .lineHeight(20)
            .padding({ left: 14, right: 14, top: 10, bottom: 10 })
            .borderRadius(16)
            .backgroundColor(this.theme.primary)
            .wordBreak(WordBreak.BREAK_WORD)
            .constraintSize({ maxWidth: '75%' })
          // 用户消息：复制图标
          Row() {
            SymbolGlyph($r('sys.symbol.doc_plaintext'))
              .fontSize(11)
              .fontColor(['rgba(255,255,255,0.6)'])
            Text(' 复制')
              .fontSize(9)
              .fontColor('rgba(255,255,255,0.6)')
          }
          .margin({ top: 4, right: 4 })
          .onClick(() => { this.copyText(msg.text) })
        }
        .alignItems(HorizontalAlign.End)
      } else {
        Column() {
          Row() {
            Image($r('app.media.ai_chat'))
              .width(18)
              .height(18)
            Text(' 本地 AI')
              .fontSize(10)
              .fontColor(this.theme.textTertiary)
            Blank()
            // AI 消息：复制图标 + 回复完成微光
            Row() {
              SymbolGlyph($r('sys.symbol.doc_plaintext'))
                .fontSize(11)
                .fontColor([this.theme.textTertiary])
              Text(' 复制')
                .fontSize(9)
                .fontColor(this.theme.textTertiary)
            }
            .onClick(() => { this.copyText(msg.text) })
            if (this.whimsySparkle && idx === this.messages.length - 1) {
              Text(' ✨')
                .fontSize(12)
                .opacity(this.whimsySparkle ? 1 : 0)
                .animation({ duration: 600, curve: Curve.EaseOut })
                .margin({ left: 6 })
            }
          }
          .width('100%')
          .margin({ bottom: 6 })

          Text(msg.text)
            .fontSize(14)
            .fontColor(this.theme.textPrimary)
            .lineHeight(21)
            .wordBreak(WordBreak.BREAK_WORD)
            .constraintSize({ maxWidth: '100%' })
        }
        .alignItems(HorizontalAlign.Start)
        .padding(12)
        .borderRadius(14)
        .backgroundColor(this.theme.bgCard)
        .backdropBlur(20)
        .border({ width: 0.5, color: this.theme.borderGlass })
        .constraintSize({ maxWidth: '85%' })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .margin({ top: 10 })
  }

  build() {
    Column() {
      // 标题栏
      Row() {
        Row() {
          Image($r('app.media.ai_chat'))
            .width(24)
            .height(24)
          Text(' 本地 AI')
            .fontSize(20)
            .fontColor(this.theme.textPrimary)
            .fontWeight(FontWeight.Bold)
          Text('  离线对话')
            .fontSize(11)
            .fontColor(this.theme.textSecondary)
            .margin({ left: 4, top: 3 })
        }
        Blank()
        if (this.llmReady) {
          // 模型状态胶囊（点击进商店）
          Row() {
            if (this.isLoading) {
              LoadingProgress().width(12).height(12).color('#FF8A3D')
              Text('  加载中').fontSize(10).fontColor(this.theme.primary)
            } else if (this.isLoaded) {
              Image($r('app.media.ai_chat')).width(14).height(14)
              Text(this.curModel).fontSize(10).fontColor('#00C853').fontWeight(FontWeight.Bold)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            } else if (this.installed.length > 0) {
              Text('📦 未加载 点击加载').fontSize(10).fontColor('#E6A800')
            } else {
              Text('🏪 去模型商店').fontSize(10).fontColor(this.theme.primary)
            }
          }
          .constraintSize({ maxWidth: 150 })
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .borderRadius(12)
          .backgroundColor('rgba(255,255,255,0.7)')
          .border({ width: 0.5, color: 'rgba(180,160,120,0.3)' })
          .onClick(() => { this.goShop() })
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })

      // 消息列表
      List({ scroller: this.listScroller, space: 2 }) {
        ForEach(this.messages, (msg: ChatMsg, idx: number) => {
          ListItem() {
            this.bubble(msg, idx)
          }
        }, (msg: ChatMsg, idx: number): string => `${idx}_${msg.role}_${msg.text.length}`)

        if (this.aiThinking) {
          ListItem() {
            Row() {
              LoadingProgress().width(16).height(16).color(this.theme.primary)
              Text(' 本地模型思考中…')
                .fontSize(12)
                .fontColor(this.theme.textTertiary)
                .margin({ left: 8 })
            }
            .width('100%')
            .padding({ top: 14 })
          }
        }
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: 14, right: 14 })
      .scrollBar(BarState.Off)
      .align(Alignment.Top)

      // 模型状态引导行（未加载时）
      if (!this.llmReady) {
        Row() {
          Text('本地 AI 初始化中...').fontSize(11).fontColor(this.theme.textTertiary)
        }
        .width('100%').padding(10)
      } else if (this.installed.length === 0) {
        // 无模型：引导
        Row() {
          Column() {
            Text('🤖 尚未安装本地模型').fontSize(13).fontColor(this.theme.textPrimary).fontWeight(FontWeight.Medium)
            Text('下载一个小模型（约 400MB），完全离线对话').fontSize(10).fontColor(this.theme.textTertiary).margin({ top: 3 })
          }
          .alignItems(HorizontalAlign.Start).layoutWeight(1)
          Row() {
            Text('去模型商店').fontSize(11).fontColor('#FFFFFF').fontWeight(FontWeight.Bold)
          }
          .padding({ left: 12, right: 12, top: 7, bottom: 7 })
          .borderRadius(14).backgroundColor('#FF8A3D')
          .onClick(() => { this.goShop() })
        }
        .width('100%').padding(12).borderRadius(14)
        .backgroundColor(this.theme.bgCard)
        .margin({ left: 14, right: 14, top: 4, bottom: 6 })
      } else if (!this.isLoaded && !this.isLoading) {
        // 有模型未加载：加载 + 去商店管理（损坏模型可删除重下）
        Row() {
          Column() {
            Text(`📦 ${this.installed.length} 个模型已安装，未加载`).fontSize(11).fontColor(this.theme.textSecondary)
            Text('加载失败可去商店删除后重新下载').fontSize(9).fontColor(this.theme.textTertiary).margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start).layoutWeight(1)
          Row() {
            Text('去商店').fontSize(11).fontColor('#FF8A3D').fontWeight(FontWeight.Bold)
          }
          .padding({ left: 10, right: 10, top: 7, bottom: 7 })
          .borderRadius(14)
          .backgroundColor('rgba(255,138,61,0.1)')
          .margin({ right: 6 })
          .onClick(() => { this.goShop() })
          Row() {
            Text('加载模型').fontSize(11).fontColor('#FFFFFF').fontWeight(FontWeight.Bold)
          }
          .padding({ left: 12, right: 12, top: 7, bottom: 7 })
          .borderRadius(14).backgroundColor('#FF8A3D')
          .onClick(() => { this.loadCurModel(this.installed[0].name) })
        }
        .width('100%').padding(12).borderRadius(14)
        .backgroundColor(this.theme.bgCard)
        .margin({ left: 14, right: 14, top: 4, bottom: 6 })
      } else if (this.isLoaded) {
        // 已加载：模型切换行（随时切换已装模型 + 模型商店入口）
        Column() {
          Scroll() {
            Row({ space: 6 }) {
              ForEach(this.installed, (m: ModelInfo) => {
                Row() {
                  Text(m.name)
                    .fontSize(10)
                    .fontColor(this.curModel === m.name && this.isLoaded ? '#FFFFFF' : this.theme.textSecondary)
                    .fontWeight(this.curModel === m.name && this.isLoaded ? FontWeight.Bold : FontWeight.Medium)
                  if (this.curModel === m.name && this.isLoaded) {
                    Text(' ✓').fontSize(9).fontColor('#FFFFFF')
                  }
                }
                .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                .borderRadius(12)
                .backgroundColor(this.curModel === m.name && this.isLoaded ? '#FF8A3D' : 'rgba(255,255,255,0.7)')
                .border({ width: 0.5, color: 'rgba(180,160,120,0.25)' })
                .onClick(() => {
                  if (!(this.curModel === m.name && this.isLoaded)) {
                    this.loadCurModel(m.name)
                  }
                })
              }, (m: ModelInfo): string => m.name)
              // 模型商店入口（与模型 chip 同款胶囊样式）
              Row() {
                Text('🏪 模型商店').fontSize(10)
                  .fontColor('#FF8A3D')
                  .fontWeight(FontWeight.Bold)
              }
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .borderRadius(12)
              .backgroundColor('rgba(255,138,61,0.1)')
              .border({ width: 0.5, color: 'rgba(255,138,61,0.35)' })
              .onClick(() => { this.goShop() })
            }
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%').margin({ top: 4 })
        }
        .width('100%').padding({ left: 14, right: 14, top: 4, bottom: 6 })
      }

      // 输入栏（底部避让悬浮导航条）
      Row() {
        TextInput({ placeholder: '和本地 AI 聊聊…', text: this.inputText })
          .placeholderColor(this.theme.textTertiary)
          .fontColor(this.theme.textPrimary)
          .backgroundColor(this.theme.bgCard)
          .height(42)
          .borderRadius(21)
          .layoutWeight(1)
          .onChange((v: string) => { this.inputText = v })
          .onSubmit(() => { this.sendLlm(this.inputText) })
        Row() {
          Text('发送')
            .fontSize(13)
            .fontColor('#FFFFFF')
            .fontWeight(FontWeight.Medium)
        }
        .width(64)
        .height(42)
        .borderRadius(21)
        .backgroundColor(this.theme.primary)
        .justifyContent(FlexAlign.Center)
        .margin({ left: 8 })
        .opacity(this.aiThinking ? 0.5 : 1)
        .onClick(() => { this.sendLlm(this.inputText) })
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 6, bottom: this.bottomNavInset })
    }
    .width('100%')
    .height('100%')
  }
}
