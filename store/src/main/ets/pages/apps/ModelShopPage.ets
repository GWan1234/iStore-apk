/**
 * ModelShopPage - 本地 AI 模型商店
 * ModelScope 官方 MNN 小模型在线下载（断点续传/进度/取消）+ 本地导入 + 已装模型管理/切换
 */
import { router, window, promptAction } from '@kit.ArkUI'
import { picker } from '@kit.CoreFileKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { common } from '@kit.AbilityKit'
import { AppState } from '../../common/store/AppState'
import { LIGHT_THEME, ThemePalette } from '../../common/theme/ThemeColors'
import { LlmHolder } from '../../common/llm/LlmHolder'
import { LLMManager, MarketModel, ModelInfo } from '../../common/llm/LLMManager'

const DOMAIN = 0x0001
const TAG = 'ModelShop'

/** ModelScope 官方 MNN 小模型（用户指定 5 个，纯文本聊天跳过视觉文件） */
const MARKET_MODELS: MarketModel[] = [
  { name: 'Hunyuan-0.5B-Instruct-MNN', repo: 'MNN/Hunyuan-0.5B-Instruct-MNN', desc: '腾讯混元 0.5B · 轻量快速 · 低配机首选', sizeMB: 383 },
  { name: 'Qwen3.5-0.8B-MNN', repo: 'MNN/Qwen3.5-0.8B-MNN', desc: '通义千问 3.5 · 0.8B 多模态 · 纯文本省 60MB', sizeMB: 460, skipVisual: true },
  { name: 'DeepSeek-R1-1.5B-Qwen-MNN', repo: 'MNN/DeepSeek-R1-1.5B-Qwen-MNN', desc: 'DeepSeek-R1 推理模型 · 深度思考展示推理过程', sizeMB: 973 },
  { name: 'Hunyuan-1.8B-Instruct-MNN', repo: 'MNN/Hunyuan-1.8B-Instruct-MNN', desc: '腾讯混元 1.8B · 中文理解更强', sizeMB: 1189 },
  { name: 'Qwen3.5-2B-MNN', repo: 'MNN/Qwen3.5-2B-MNN', desc: '通义千问 3.5 · 2B 多模态 · 纯文本省 186MB', sizeMB: 1136, skipVisual: true }
]

@Entry
@Component
export struct ModelShopPage {
  @State theme: ThemePalette = LIGHT_THEME
  @State topSafeArea: number = 44
  @State installed: ModelInfo[] = []       // 已安装模型
  @State curModel: string = ''             // 当前使用模型名
  @State isLoaded: boolean = false
  @State isLoading: boolean = false
  @State downloading: string = ''          // 正在下载的模型名
  @State progress: number = 0              // 下载进度 0~100
  @State statusMsg: string = ''
  private manager: LLMManager | null = null

  aboutToAppear(): void {
    this.theme = AppState.getInstance().getTheme()
    this.loadTopSafeArea()
    const hostCtx = this.getUIContext().getHostContext() as common.UIAbilityContext
    if (hostCtx) {
      this.manager = LlmHolder.getInstance().init(hostCtx)
    }
    this.refresh()
  }

  loadTopSafeArea(): void {
    try {
      const hostCtx = this.getUIContext().getHostContext()
      if (hostCtx) {
        window.getLastWindow(hostCtx as Context).then((win: window.Window) => {
          const avoidArea: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM)
          const h: number = px2vp(avoidArea.topRect.height)
          if (h > 0) this.topSafeArea = h
        }).catch(() => {})
      }
    } catch (e) {}
  }

  /** 刷新已装列表与当前状态 */
  refresh(): void {
    if (!this.manager) return
    this.installed = this.manager.listModels()
    this.isLoaded = this.manager.isLoaded
    this.isLoading = this.manager.isLoading
    const dir: string = this.manager.modelDir
    this.curModel = dir.startsWith('models/') ? dir.substring(7) : ''
  }

  /** 模型是否已安装 */
  isInstalled(name: string): boolean {
    return this.installed.some((m: ModelInfo) => m.name === name)
  }

  /** 模型是否下载未完成（目录有 .tmp 残留） */
  isDownloading(name: string): boolean {
    const found = this.installed.find((m: ModelInfo) => m.name === name)
    return found !== undefined && found.downloading
  }

  /** 下载模型 */
  async download(m: MarketModel): Promise<void> {
    if (!this.manager || this.downloading) return
    this.downloading = m.name
    this.progress = 0
    this.statusMsg = ''
    try {
      const code: number = await this.manager.downloadModel(m, (received: number, total: number) => {
        this.progress = total > 0 ? Math.min(100, Math.round((received / total) * 100)) : 0
      })
      if (code === 0) {
        this.statusMsg = `✅ 「${m.name}」下载完成`
        this.refresh()
        // 下载完成自动加载
        await this.loadModel(m.name)
      } else if (code === -1) {
        this.statusMsg = '下载失败：请检查网络后重试'
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, `download err: ${String(e)}`)
      this.statusMsg = '下载异常，请重试'
    }
    this.downloading = ''
    this.progress = 0
    this.refresh()
  }

  /** 取消下载 */
  cancelDownload(): void {
    if (this.manager && this.downloading) {
      this.manager.cancelDownload()
      this.statusMsg = '已取消下载'
    }
  }

  /** 加载/切换模型 */
  async loadModel(name: string): Promise<void> {
    if (!this.manager || this.isLoading) return
    this.statusMsg = ''
    this.isLoading = true
    try {
      const code: number = await this.manager.loadModel(`models/${name}`)
      if (code === 0) {
        this.statusMsg = `🧠 已加载「${name}」`
      } else {
        const why: string = this.manager ? this.manager.lastLoadError : ''
        this.statusMsg = `⚠️ 加载失败：${why ? why + '，' : ''}请删除后重新下载`
      }
    } catch (e) {
      this.statusMsg = '加载异常'
    }
    this.refresh()
  }

  /** 删除模型 */
  async deleteModel(name: string): Promise<void> {
    if (!this.manager) return
    try {
      promptAction.showDialog({
        title: `删除 ${name}`,
        message: '将删除该模型文件，释放存储空间，是否继续？',
        buttons: [
          { text: '取消', color: '#999999' },
          { text: '删除', color: '#FF5252' }
        ]
      }).then((res: promptAction.ShowDialogSuccessResponse) => {
        if (res.index === 1) {
          this.manager?.deleteModel(name)
          this.statusMsg = `已删除「${name}」`
          this.refresh()
        }
      })
    } catch (e) {}
  }

  /** 导入模型（picker 多文件 → 复制到沙箱 models/） */
  async importModel(): Promise<void> {
    if (!this.manager) return
    try {
      const confirm = await promptAction.showDialog({
        title: '导入模型',
        message: '导入方法：\n1. MNN 模型：全选模型文件夹内所有文件（.mnn/.json/.weight/tokenizer.txt 等）\n2. GGUF 模型：只需选 1 个 .gguf 文件\n3. 缺少 config.json 将无法识别',
        buttons: [
          { text: '取消', color: '#999999' },
          { text: '选择文件', color: '#FF8A3D' }
        ]
      })
      if (confirm.index !== 1) return
      const docPicker = new picker.DocumentViewPicker()
      const result: Array<string> = await docPicker.select({
        maxSelectNumber: 50,
        fileSuffixFilters: ['.gguf', '.mnn', '.weight', '.txt', '.json', '.bin']
      })
      if (result.length === 0) return
      // 判断 GGUF / MNN
      let hasGguf: boolean = false
      let ggufUri: string = ''
      for (let i = 0; i < result.length; i++) {
        const fn: string = LLMManager.fileNameFromUri(result[i]).toLowerCase()
        if (fn.endsWith('.gguf')) {
          hasGguf = true
          ggufUri = result[i]
          break
        }
      }
      let name: string = ''
      let files: Array<string> = result
      if (hasGguf) {
        const raw: string = LLMManager.fileNameFromUri(ggufUri)
        const dot: number = raw.lastIndexOf('.')
        name = dot > 0 ? raw.substring(0, dot) : raw
        try {
          name = decodeURIComponent(name)
        } catch (e) {}
        files = [ggufUri]
      } else {
        name = LLMManager.parentDirName(result[0])
        if (!name) {
          name = '我的模型'
        }
      }
      // 复制到沙箱 models/<name>/
      const dir: string = `${this.manager.getModelsDir()}/${name}`
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir)
      }
      for (let i = 0; i < files.length; i++) {
        const fname: string = LLMManager.fileNameFromUri(files[i])
        try {
          fs.copyFileSync(files[i], `${dir}/${fname}`)
        } catch (e) {
          hilog.error(DOMAIN, TAG, `copy ${fname} err: ${String(e)}`)
        }
      }
      this.statusMsg = `✅ 已导入「${name}」`
      this.refresh()
    } catch (e) {
      hilog.error(DOMAIN, TAG, `import err: ${String(e)}`)
      this.statusMsg = '导入失败'
    }
  }

  build() {
    Column() {
      // 标题栏
      Row() {
        Row() {
          Image($r('app.media.ai_assistant')).width(18).height(18)
        }
        .width(34).height(34).borderRadius(17)
        .backgroundColor('rgba(255,138,61,0.14)')
        .justifyContent(FlexAlign.Center)

        Column() {
          Text('模型商店').fontSize(17).fontColor(this.theme.textPrimary).fontWeight(FontWeight.Bold)
          Text('本地大模型 · 完全离线').fontSize(10).fontColor(this.theme.textTertiary).margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start).margin({ left: 10 }).layoutWeight(1)

        Text('返回')
          .fontSize(13).fontColor(this.theme.primary)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .borderRadius(14)
          .backgroundColor('rgba(255,138,61,0.1)')
          .onClick(() => { router.back() })
      }
      .width('100%').padding({ left: 16, right: 16, top: this.topSafeArea + 4 })

      Scroll() {
        Column() {
          // 当前模型状态卡
          Row() {
            Column() {
              Text('当前模型').fontSize(10).fontColor(this.theme.textTertiary)
              Text(this.curModel ? this.curModel : (this.isLoading ? '加载中...' : '未加载'))
                .fontSize(15).fontColor(this.theme.textPrimary).fontWeight(FontWeight.Bold)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                .margin({ top: 3 })
            }
            .alignItems(HorizontalAlign.Start).layoutWeight(1)
            if (this.isLoaded) {
              Row() {
                Text('● 已就绪').fontSize(11).fontColor('#00C853').fontWeight(FontWeight.Bold)
              }
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .borderRadius(12)
              .backgroundColor('rgba(0,200,83,0.1)')
            } else if (this.isLoading) {
              Row() {
                LoadingProgress().width(14).height(14).color('#FF8A3D')
                Text('  加载中').fontSize(11).fontColor(this.theme.primary)
              }
            } else {
              Row() {
                Text('未加载').fontSize(11).fontColor(this.theme.textTertiary)
              }
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .borderRadius(12)
              .backgroundColor('rgba(180,160,120,0.12)')
            }
          }
          .width('100%').padding(14).borderRadius(16).margin({ top: 12 })
          .backgroundColor(this.theme.bgCard)

          if (this.statusMsg) {
            Text(this.statusMsg)
              .fontSize(11).fontColor(this.theme.primary).margin({ top: 10 })
              .textAlign(TextAlign.Center).width('100%')
          }

          // 模型市场
          Text('🏪 模型市场（ModelScope 官方）')
            .fontSize(14).fontColor(this.theme.textPrimary).fontWeight(FontWeight.Bold)
            .width('100%').margin({ top: 16 })

          ForEach(MARKET_MODELS, (m: MarketModel) => {
            Column() {
              Row() {
                Column() {
                  Row() {
                    Text(m.name).fontSize(13).fontColor(this.theme.textPrimary).fontWeight(FontWeight.Bold)
                    if (m.sizeMB <= 500) {
                      Text(' 轻量推荐').fontSize(9).fontColor('#FF8A3D')
                        .padding({ left: 5, right: 5, top: 2, bottom: 2 })
                        .borderRadius(7).backgroundColor('rgba(255,138,61,0.12)')
                    }
                    if (m.name.includes('DeepSeek')) {
                      Text(' 深度思考').fontSize(9).fontColor('#AB47BC')
                        .padding({ left: 5, right: 5, top: 2, bottom: 2 })
                        .borderRadius(7).backgroundColor('rgba(171,71,188,0.12)')
                    }
                  }
                  Text(m.desc).fontSize(10).fontColor(this.theme.textTertiary).margin({ top: 3 })
                  Text(`${m.sizeMB} MB`)
                    .fontSize(9).fontColor(this.theme.textTertiary).margin({ top: 3 })
                }
                .alignItems(HorizontalAlign.Start).layoutWeight(1)

                // 操作按钮
                if (this.downloading === m.name) {
                  Column() {
                    Text(`${this.progress}%`).fontSize(12).fontColor(this.theme.primary).fontWeight(FontWeight.Bold)
                    Progress({ value: this.progress, total: 100 })
                      .width(70).height(4).margin({ top: 4 })
                      .color('#FF8A3D').backgroundColor('#F0EBE0')
                    Text('取消').fontSize(9).fontColor('#FF5252').margin({ top: 4 })
                      .onClick(() => { this.cancelDownload() })
                  }
                  .alignItems(HorizontalAlign.Center)
                } else if (this.curModel === m.name && this.isLoaded) {
                  Row() {
                    Text('使用中').fontSize(11).fontColor('#00C853').fontWeight(FontWeight.Bold)
                  }
                  .padding({ left: 12, right: 12, top: 7, bottom: 7 })
                  .borderRadius(14)
                  .backgroundColor('rgba(0,200,83,0.12)')
                } else if (this.isDownloading(m.name)) {
                  // 下载未完成（.tmp 残留）：只允许继续下载或删除，禁止加载（避免报"权重文件缺失"）
                  Column() {
                    Text('下载中').fontSize(10).fontColor('#E6A800').fontWeight(FontWeight.Bold)
                    Text('续传').fontSize(10).fontColor('#FF8A3D').fontWeight(FontWeight.Medium).margin({ top: 3 })
                      .onClick(() => { this.download(m) })
                  }
                  .alignItems(HorizontalAlign.Center)
                } else if (this.isInstalled(m.name)) {
                  Row() {
                    Text('加载').fontSize(12).fontColor('#FFFFFF').fontWeight(FontWeight.Bold)
                  }
                  .padding({ left: 14, right: 14, top: 8, bottom: 8 })
                  .borderRadius(16)
                  .backgroundColor(this.isLoading ? '#C9A98A' : '#FF8A3D')
                  .onClick(() => { this.loadModel(m.name) })
                } else {
                  Row() {
                    Text('下载').fontSize(12).fontColor('#FFFFFF').fontWeight(FontWeight.Bold)
                  }
                  .padding({ left: 14, right: 14, top: 8, bottom: 8 })
                  .borderRadius(16)
                  .backgroundColor(this.downloading ? '#C9A98A' : '#FF8A3D')
                  .onClick(() => { this.download(m) })
                }
              }
              .width('100%')
            }
            .width('100%').padding(14).borderRadius(16).margin({ top: 8 })
            .backgroundColor(this.theme.bgCard)
          }, (m: MarketModel): string => m.name)

          // 本地导入
          Row() {
            SymbolGlyph($r('sys.symbol.folder')).fontSize(16).fontColor(['#FF8A3D'])
            Text('  导入本地模型（选择模型文件/文件夹）')
              .fontSize(13).fontColor('#FF8A3D').fontWeight(FontWeight.Medium)
          }
          .width('100%').height(46).borderRadius(23).margin({ top: 14 })
          .backgroundColor('#FFF3E7')
          .justifyContent(FlexAlign.Center)
          .onClick(() => { this.importModel() })

          // 已安装列表
          if (this.installed.length > 0) {
            Text(`📦 已安装（${this.installed.length}）`)
              .fontSize(14).fontColor(this.theme.textPrimary).fontWeight(FontWeight.Bold)
              .width('100%').margin({ top: 16 })
            ForEach(this.installed, (m: ModelInfo) => {
              Row() {
                Column() {
                  Text(m.name).fontSize(13).fontColor(this.theme.textPrimary).fontWeight(FontWeight.Medium)
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(`${m.sizeMB} MB`).fontSize(10).fontColor(this.theme.textTertiary).margin({ top: 2 })
                }
                .alignItems(HorizontalAlign.Start).layoutWeight(1)

                if (m.downloading) {
                  Text('下载中…').fontSize(10).fontColor('#E6A800').fontWeight(FontWeight.Bold).margin({ right: 10 })
                } else if (this.curModel === m.name && this.isLoaded) {
                  Text('使用中').fontSize(11).fontColor('#00C853').fontWeight(FontWeight.Bold).margin({ right: 10 })
                } else if (this.curModel !== m.name) {
                  Row() {
                    Text('切换').fontSize(11).fontColor('#FF8A3D').fontWeight(FontWeight.Bold)
                  }
                  .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                  .borderRadius(12)
                  .backgroundColor('rgba(255,138,61,0.1)')
                  .margin({ right: 8 })
                  .onClick(() => { this.loadModel(m.name) })
                }
                Row() {
                  Text('删除').fontSize(11).fontColor('#FF5252')
                }
                .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                .borderRadius(12)
                .backgroundColor('rgba(255,82,82,0.1)')
                .onClick(() => { this.deleteModel(m.name) })
              }
              .width('100%').padding(12).borderRadius(14).margin({ top: 8 })
              .backgroundColor(this.theme.bgCard)
            }, (m: ModelInfo): string => m.name)
          }

          Text('🔒 模型数据完全在本地运行，对话内容不上传')
            .fontSize(10).fontColor(this.theme.textTertiary)
            .width('100%').textAlign(TextAlign.Center).margin({ top: 16, bottom: 8 })
        }
        .width('100%').padding({ left: 16, right: 16, bottom: 30 })
      }
      .layoutWeight(1).scrollBar(BarState.Off)
    }
    .width('100%').height('100%')
    .linearGradient({
      angle: 180,
      colors: [['#F6F2EA', 0], ['#FAF7F0', 0.5], ['#F6F2EA', 1]]
    })
  }
}
