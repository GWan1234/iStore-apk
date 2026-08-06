import { AppState } from '../../common/store/AppState'
import { ThemePalette, DARK_THEME } from '../../common/theme/ThemeColors'
import { ImmichStore, ImmichConfig } from '../../common/store/ImmichStore'
import { ImmichClient, ImmichAlbum, ImmichServerInfo, ImmichAsset } from '../../api/ImmichClient'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { systemShare } from '@kit.ShareKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { fileUri } from '@kit.CoreFileKit'
import { http } from '@kit.NetworkKit'
import { common } from '@kit.AbilityKit'

/**
 * AlbumTab - Immich 相册（仿鸿蒙相册）
 * 未配置：显示配置表单（服务器地址 + API Key）
 * 已配置：底部导航「相片 / 相册」；相片为按天分组的时间线，相册为相册网格
 * 点击照片全屏查看（Swiper 滑动切换）
 */

/** 按天分组的照片（鸿蒙相册时间线样式） */
interface PhotoDay {
  title: string       // 日期标题（今天/昨天/YYYY年M月D日）
  dateKey: string     // 排序用的日期 key（YYYY-MM-DD）
  items: ImmichAsset[]
}

@Component
export struct AlbumTab {
  @Prop theme: ThemePalette
  @State isDark: boolean = true
  @State configured: boolean = false
  @State baseUrl: string = ''
  @State apiKey: string = ''
  @State showConfig: boolean = false
  @State isTesting: boolean = false
  @State configError: string = ''
  // 本机检测
  @State isProbing: boolean = false
  @State probeResult: string = ''     // 'found' | 'none' | ''
  @State probeMsg: string = ''
  // 相册数据
  @State albums: ImmichAlbum[] = []
  @State serverInfo: ImmichServerInfo | null = null
  @State isLoading: boolean = false
  @State errorText: string = ''
  // 相册详情
  @State activeAlbum: ImmichAlbum | null = null
  @State assets: ImmichAsset[] = []
  @State albumLoading: boolean = false
  // 主视图：底部导航（0=相片 1=相册）
  @State mainTab: number = 0
  // 主页悬浮导航条占用底部空间（相对布局，随机型动态）
  @State bottomInset: number = 150
  // 全部照片（按天分组时间线，默认首页）
  @State allPhotos: ImmichAsset[] = []
  @State allPhotosLoading: boolean = false
  // 按天分组后的时间线（key=日期标题, 照片列表）
  @State photoDays: PhotoDay[] = []
  // 分页状态
  private pageSize: number = 20
  private assetsPage: number = 1
  private assetsTotal: number = -1
  private assetsLoadingMore: boolean = false
  private allPhotosPage: number = 1
  private allPhotosTotal: number = -1
  private allPhotosLoadingMore: boolean = false
  // 内存缓存：key = 'album:<id>' 或 'all'，value = 已加载资产
  private assetCache: Map<string, ImmichAsset[]> = new Map()
  // 诊断
  @State showDiagnose: boolean = false
  @State diagnoseText: string = ''
  @State diagnosing: boolean = false
  // 全屏查看（Swiper 滑动切换）
  @State viewerList: ImmichAsset[] = []
  @State viewerIndex: number = 0
  @State viewerShowOriginal: boolean[] = []
  // 视频播放状态（与 viewerIndex 对应的索引）
  @State videoPlaying: boolean[] = []
  // 视频加载状态（转圈，播放就绪后取消）
  @State videoLoading: boolean[] = []
  // 分享状态
  @State sharing: boolean = false
  @State shareMsg: string = ''
  // 视频控制器（持久化，非 UI 状态）
  private videoControllers: VideoController[] | null = null
  // 分享下载（用于中途取消）
  private shareReq: http.HttpRequest | null = null
  private shareFilePath: string = ''

  private store: ImmichStore = ImmichStore.getInstance()
  private client: ImmichClient | null = null
  private navInsetListener: ((inset: number) => void) | null = null
  private themeListener: (() => void) | null = null

  aboutToAppear(): void {
    this.isDark = AppState.getInstance().isDarkMode
    this.theme = AppState.getInstance().getTheme()
    // 订阅主题变化（胶囊导航条颜色随主题切换）
    this.themeListener = () => {
      this.isDark = AppState.getInstance().isDarkMode
      this.theme = AppState.getInstance().getTheme()
    }
    AppState.getInstance().onThemeChange(this.themeListener)
    // 底部导航 inset（相对布局，避免被主页悬浮导航遮挡）
    this.bottomInset = AppState.getInstance().getBottomNavInset()
    this.navInsetListener = (inset: number) => {
      this.bottomInset = inset
    }
    AppState.getInstance().onBottomNavInsetChange(this.navInsetListener)
    // 注册相册返回回调（MainPage onBackPress 触发时先退出子视图）
    AppState.getInstance().onAlbumBack(() => {
      this.exitSubView()
    })
    // 设备切换时重新加载对应设备的相册配置
    AppState.getInstance().onDeviceChange(() => {
      // 退出所有子视图
      this.closeViewer()
      this.activeAlbum = null
      this.assets = []
      this.allPhotos = []
      this.photoDays = []
      this.showConfig = false
      this.mainTab = 0
      this.loadConfigForDevice()
    })
    this.loadConfigForDevice()
  }

  /** 当前路由器设备 ID（无设备时为空） */
  private currentDeviceId(): string {
    const device = AppState.getInstance().getActiveDevice()
    return device ? device.id : ''
  }

  /** 加载当前设备的 Immich 配置（按设备隔离） */
  async loadConfigForDevice(): Promise<void> {
    const deviceId: string = this.currentDeviceId()
    if (!deviceId) return
    const cfg: ImmichConfig | null = await this.store.getConfig(deviceId)
    if (cfg && cfg.baseUrl && cfg.apiKey) {
      this.baseUrl = cfg.baseUrl
      this.apiKey = cfg.apiKey
      this.configured = true
      this.client = new ImmichClient(cfg.baseUrl, cfg.apiKey)
      // 默认首页：相片时间线（按天分组）
      this.loadAllPhotos()
      this.loadAlbums()
    } else {
      // 当前设备无配置，重置为未配置状态
      this.configured = false
      this.baseUrl = ''
      this.apiKey = ''
      this.client = null
      this.albums = []
      this.allPhotos = []
      this.photoDays = []
    }
  }

  aboutToDisappear(): void {
    AppState.getInstance().offAlbumBack(() => {})
    if (this.navInsetListener) {
      AppState.getInstance().offBottomNavInsetChange(this.navInsetListener)
      this.navInsetListener = null
    }
    if (this.themeListener) {
      AppState.getInstance().offThemeChange(this.themeListener)
      this.themeListener = null
    }
  }

  /** 打开全屏查看器（传入照片列表和起始索引） */
  openViewer(list: ImmichAsset[], index: number): void {
    this.viewerList = list
    this.viewerIndex = index
    const originals: boolean[] = []
    const playing: boolean[] = []
    const loading: boolean[] = []
    for (let i = 0; i < list.length; i++) {
      originals.push(false)
      playing.push(false)
      loading.push(false)
    }
    this.viewerShowOriginal = originals
    this.videoPlaying = playing
    this.videoLoading = loading
    // 全屏查看时隐藏底部导航栏，并标记子视图状态（MainPage 据此拦截 Tab 滑动穿透）
    AppState.getInstance().hideNav()
    AppState.getInstance().setAlbumSubView(true)
  }

  /** 关闭全屏查看器 */
  closeViewer(): void {
    // 终止分享下载并清理缓存
    this.cancelShareDownload()
    // 停止所有视频播放
    if (this.videoControllers) {
      for (let i = 0; i < this.videoControllers.length; i++) {
        try {
          this.videoControllers[i].stop()
        } catch (_e) {}
      }
      this.videoControllers = null
    }
    this.viewerList = []
    this.viewerIndex = 0
    this.viewerShowOriginal = []
    this.videoPlaying = []
    this.videoLoading = []
    this.shareMsg = ''
    // 恢复底部导航栏；仅当不再处于相册详情子视图时清除子视图标记
    AppState.getInstance().showNav()
    if (!this.activeAlbum) {
      AppState.getInstance().setAlbumSubView(false)
    }
  }

  /** 指定索引的视频是否已开始播放 */
  isVideoPlaying(idx: number): boolean {
    if (idx < 0 || idx >= this.videoPlaying.length) {
      return false
    }
    return this.videoPlaying[idx]
  }

  /** 开始播放指定索引的视频 */
  playVideo(idx: number): void {
    if (idx < 0 || idx >= this.videoPlaying.length) {
      return
    }
    this.videoPlaying[idx] = true
    this.setVideoLoading(idx, true)
    // 延迟到组件渲染后启动播放（确保控制条可用）
    setTimeout(() => {
      try {
        const ctrl = this.getVideoController(idx)
        ctrl.start()
      } catch (e) {
        hilog.error(0x0001, 'AlbumTab', `video start err: ${JSON.stringify(e)}`)
      }
    }, 100)
  }

  /** 指定索引的视频是否加载中 */
  isVideoLoading(idx: number): boolean {
    if (idx < 0 || idx >= this.videoLoading.length) {
      return false
    }
    return this.videoLoading[idx]
  }

  /** 设置视频加载状态 */
  setVideoLoading(idx: number, loading: boolean): void {
    if (idx < 0 || idx >= this.videoLoading.length) {
      return
    }
    this.videoLoading[idx] = loading
  }

  /** 获取视频控制器（持久化，避免每次新建导致控制条状态丢失） */
  getVideoController(idx: number): VideoController {
    if (!this.videoControllers) {
      this.videoControllers = []
    }
    while (this.videoControllers.length <= idx) {
      this.videoControllers.push(new VideoController())
    }
    return this.videoControllers[idx]
  }

  /** 退出子视图（返回相册列表），供 MainPage 返回手势调用 */
  exitSubView(): void {
    if (this.viewerList.length > 0) {
      this.closeViewer()
      return
    }
    if (this.activeAlbum) {
      this.activeAlbum = null
      this.assets = []
      AppState.getInstance().setAlbumSubView(false)
      return
    }
    AppState.getInstance().setAlbumSubView(false)
  }

  /** 加载相册列表 */
  async loadAlbums(): Promise<void> {
    if (!this.client) return
    this.isLoading = true
    this.errorText = ''
    try {
      // 服务器信息（about/statistics 需要额外权限，失败仅降级显示，不影响相册）
      this.serverInfo = await this.client.fetchServerInfo()
      this.albums = await this.client.fetchAlbums()
      if (this.albums.length === 0 && !this.serverInfo) {
        this.errorText = '未能获取相册列表，请检查 API Key 权限'
      }
    } catch (e) {
      this.errorText = '加载相册失败'
    }
    this.isLoading = false
  }

  /** 打开相册（分页加载，每次 pageSize 张，滚动到底加载更多） */
  async openAlbum(album: ImmichAlbum): Promise<void> {
    if (!this.client) return
    this.activeAlbum = album
    AppState.getInstance().setAlbumSubView(true)
    this.albumLoading = true
    this.errorText = ''
    this.assets = []
    this.assetsPage = 1
    this.assetsTotal = -1
    this.assetsLoadingMore = false
    try {
      // 优先使用内存缓存
      const cacheKey: string = `album:${album.id}`
      const cached: ImmichAsset[] | undefined = this.assetCache.get(cacheKey)
      if (cached && cached.length > 0) {
        this.assets = cached
        this.assetsTotal = cached.length
        this.albumLoading = false
        return
      }
      const albumFilter: Record<string, Object> = { 'albumIds': [album.id] as Object }
      const result = await this.client.searchAssetsPage(albumFilter as Object, this.assetsPage, this.pageSize)
      if (result) {
        this.assets = result.items
        this.assetsTotal = result.total
        this.assetCache.set(cacheKey, result.items)
      }
    } catch (e) {
      this.errorText = '加载相册内容失败'
    }
    this.albumLoading = false
  }

  /** 相册内滚动到底加载下一页 */
  async loadMoreAssets(): Promise<void> {
    if (!this.client || !this.activeAlbum || this.assetsLoadingMore) return
    // 已加载全部则跳过
    if (this.assetsTotal >= 0 && this.assets.length >= this.assetsTotal) return
    this.assetsLoadingMore = true
    try {
      const nextPage: number = this.assetsPage + 1
      const albumFilter: Record<string, Object> = { 'albumIds': [this.activeAlbum.id] as Object }
      const result = await this.client.searchAssetsPage(albumFilter as Object, nextPage, this.pageSize)
      if (result && result.items.length > 0) {
        this.assetsPage = nextPage
        const merged: ImmichAsset[] = this.assets.concat(result.items)
        this.assets = merged
        this.assetsTotal = result.total
        this.assetCache.set(`album:${this.activeAlbum.id}`, merged)
      }
    } catch (e) {
      hilog.error(0x0001, 'AlbumTab', `loadMoreAssets err: ${JSON.stringify(e)}`)
    }
    this.assetsLoadingMore = false
  }

  /** 加载全部照片（按天分组时间线，分页加载，每次 pageSize 张） */
  async loadAllPhotos(): Promise<void> {
    if (!this.client) return
    this.allPhotosLoading = true
    this.errorText = ''
    this.allPhotos = []
    this.allPhotosPage = 1
    this.allPhotosTotal = -1
    this.allPhotosLoadingMore = false
    try {
      // 优先使用内存缓存
      const cached: ImmichAsset[] | undefined = this.assetCache.get('all')
      if (cached && cached.length > 0) {
        this.allPhotos = cached
        this.allPhotosTotal = cached.length
        this.rebuildPhotoDays(cached)
        this.allPhotosLoading = false
        return
      }
      const emptyFilter: Record<string, Object> = {}
      const result = await this.client.searchAssetsPage(emptyFilter as Object, this.allPhotosPage, this.pageSize)
      if (result) {
        this.allPhotos = result.items
        this.allPhotosTotal = result.total
        this.assetCache.set('all', result.items)
        this.rebuildPhotoDays(result.items)
      }
    } catch (e) {
      this.errorText = '加载照片失败'
    }
    this.allPhotosLoading = false
  }

  /** 全部照片滚动到底加载下一页 */
  async loadMoreAllPhotos(): Promise<void> {
    if (!this.client || this.allPhotosLoadingMore) return
    if (this.allPhotosTotal >= 0 && this.allPhotos.length >= this.allPhotosTotal) return
    this.allPhotosLoadingMore = true
    try {
      const nextPage: number = this.allPhotosPage + 1
      const emptyFilter: Record<string, Object> = {}
      const result = await this.client.searchAssetsPage(emptyFilter as Object, nextPage, this.pageSize)
      if (result && result.items.length > 0) {
        this.allPhotosPage = nextPage
        const merged: ImmichAsset[] = this.allPhotos.concat(result.items)
        this.allPhotos = merged
        this.allPhotosTotal = result.total
        this.assetCache.set('all', merged)
        this.rebuildPhotoDays(merged)
      }
    } catch (e) {
      hilog.error(0x0001, 'AlbumTab', `loadMoreAllPhotos err: ${JSON.stringify(e)}`)
    }
    this.allPhotosLoadingMore = false
  }

  /** 将照片按天分组，生成时间线（鸿蒙相册样式：今天/昨天/日期） */
  private rebuildPhotoDays(list: ImmichAsset[]): void {
    const groups: Map<string, ImmichAsset[]> = new Map()
    for (let i = 0; i < list.length; i++) {
      const key: string = this.dateKeyOf(list[i])
      if (!key) continue
      const arr: ImmichAsset[] | undefined = groups.get(key)
      if (arr) {
        arr.push(list[i])
      } else {
        groups.set(key, [list[i]])
      }
    }
    // 按日期降序排列（最新在前）
    const keys: string[] = Array.from(groups.keys()).sort().reverse()
    const days: PhotoDay[] = []
    const todayKey: string = this.yyyymmdd(new Date())
    const yesterdayKey: string = this.yyyymmdd(new Date(Date.now() - 86400000))
    for (let i = 0; i < keys.length; i++) {
      const d: PhotoDay = {
        title: keys[i] === todayKey ? '今天' : (keys[i] === yesterdayKey ? '昨天' : this.formatCnDate(keys[i])),
        dateKey: keys[i],
        items: groups.get(keys[i]) as ImmichAsset[]
      }
      days.push(d)
    }
    this.photoDays = days
  }

  /** 资产拍摄日期 key（YYYY-MM-DD，优先拍摄时间 takenAt） */
  private dateKeyOf(asset: ImmichAsset): string {
    const src: string = asset.takenAt || asset.createdAt
    if (!src) return ''
    try {
      return this.yyyymmdd(new Date(src))
    } catch (e) {
      return ''
    }
  }

  /** Date → YYYY-MM-DD */
  private yyyymmdd(d: Date): string {
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
  }

  /** YYYY-MM-DD → 中文日期（2026年8月6日） */
  private formatCnDate(key: string): string {
    const parts: string[] = key.split('-')
    if (parts.length !== 3) return key
    return `${parts[0]}年${parseInt(parts[1])}月${parseInt(parts[2])}日`
  }

  /** 运行 API 诊断 */
  async runDiagnose(): Promise<void> {
    if (!this.client) return
    this.diagnosing = true
    this.diagnoseText = ''
    this.showDiagnose = true
    try {
      this.diagnoseText = await this.client.diagnose()
    } catch (e) {
      this.diagnoseText = '诊断异常'
    }
    this.diagnosing = false
  }

  /**
   * 检测本机（当前连接的路由器）是否安装并运行了 Immich
   * 检测成功：自动填入服务器地址
   * 检测失败：给出提示
   */
  async probeLocalImmich(): Promise<void> {
    if (this.isProbing) return
    this.isProbing = true
    this.probeResult = ''
    this.probeMsg = ''
    this.configError = ''
    try {
      const device = AppState.getInstance().getActiveDevice()
      if (!device) {
        this.probeMsg = '未连接路由器，无法检测本机'
        this.probeResult = 'none'
        this.isProbing = false
        return
      }
      const host: string = device.host
      const found: string = await ImmichClient.probeHost(host)
      if (found) {
        // 探测到，自动填入地址
        this.baseUrl = found
        this.probeResult = 'found'
        this.probeMsg = `✓ 检测到本机已运行 Immich 相册：${found}`
      } else {
        this.probeResult = 'none'
        this.probeMsg = '未检测到本机 2283 端口运行 Immich 相册，请确认已在路由器上安装，或手动输入服务器地址'
      }
    } catch (e) {
      this.probeResult = 'none'
      this.probeMsg = '检测本机失败，请手动输入服务器地址'
    }
    this.isProbing = false
  }

  /** 测试并保存配置 */
  async testAndSave(): Promise<void> {
    if (this.isTesting) return
    if (!this.baseUrl.trim() || !this.apiKey.trim()) {
      this.configError = '请填写服务器地址和 API Key'
      return
    }
    this.isTesting = true
    this.configError = ''
    try {
      const client: ImmichClient = new ImmichClient(this.baseUrl, this.apiKey)
      // 1. 先 ping 确认服务器可达（无需认证）
      const reachable: boolean = await client.ping()
      if (!reachable) {
        this.configError = '连接失败：无法访问该地址，请检查地址格式（需含端口，如 http://192.168.1.1:2283）和网络'
        this.isTesting = false
        return
      }
      // 2. 验证 API Key 是否有效
      const keyOk: boolean = await client.validateApiKey()
      if (!keyOk) {
        this.configError = 'API Key 无效，请确认已正确复制（Immich 网页 → 用户设置 → API Keys）'
        this.isTesting = false
        return
      }
      // 3. 保存配置（按当前设备隔离存储）
      const deviceId: string = this.currentDeviceId()
      if (!deviceId) {
        this.configError = '未连接设备，请先连接路由器'
        this.isTesting = false
        return
      }
      const ok: boolean = await this.store.saveConfig(deviceId, this.baseUrl, this.apiKey)
      if (!ok) {
        this.configError = '配置保存失败'
        this.isTesting = false
        return
      }
      this.client = client
      this.configured = true
      this.showConfig = false
      this.loadAllPhotos()
      this.loadAlbums()
    } catch (e) {
      this.configError = '连接异常，请重试'
    }
    this.isTesting = false
  }

  formatBytes(bytes: number): string {
    if (bytes <= 0) return '0 B'
    const units: string[] = ['B', 'KB', 'MB', 'GB', 'TB']
    let v: number = bytes
    let i: number = 0
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024
      i++
    }
    return `${v.toFixed(1)} ${units[i]}`
  }

  formatDate(s: string): string {
    if (!s) return ''
    try {
      const d = new Date(s)
      return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
    } catch (e) {
      return ''
    }
  }

  build() {
    Stack() {
      Column() {
        // 标题栏
        Row() {
          Text('📷 相册')
            .fontSize(20)
            .fontColor(this.theme.textPrimary)
            .fontWeight(FontWeight.Bold)
          Blank()
          if (this.configured && !this.activeAlbum) {
            Text('设置')
              .fontSize(12)
              .fontColor(this.theme.textSecondary)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .borderRadius(14)
              .backgroundColor(this.theme.bgGlassLight)
              .onClick(() => {
                this.showConfig = true
              })
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 4, bottom: 4 })

        if (this.activeAlbum) {
          // 相册详情（覆盖式，隐藏底部导航）
          this.albumDetailView()
        } else if (this.showConfig || !this.configured) {
          // 配置视图
          this.configView()
        } else {
          // 主视图：自绘底部导航「相片 / 相册」
          Column() {
            // 内容区（Stack + 过渡动画切换）
            Stack({ alignContent: Alignment.Top }) {
              if (this.mainTab === 0) {
                Column() {
                  this.photoTimelineView()
                }
                .width('100%')
                .height('100%')
                .transition(TransitionEffect.OPACITY.animation({ duration: 220, curve: Curve.EaseOut }))
              } else {
                Column() {
                  this.albumListView()
                }
                .width('100%')
                .height('100%')
                .transition(TransitionEffect.OPACITY.animation({ duration: 220, curve: Curve.EaseOut }))
              }
            }
            .width('100%')
            .layoutWeight(1)

            // 自绘底部导航条（相片 / 相册，居中悬浮）
            Row() {
              this.bottomNavBar()
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)

            // 底部相对留白：= 主页悬浮导航条占用空间（随机型动态计算，不写死）
            Row()
              .width('100%')
              .height(this.bottomInset)
              .backgroundColor(Color.Transparent)
          }
          .width('100%')
          .height('100%')
        }
      }
      .width('100%')
      .height('100%')

      // 全屏查看器（覆盖整个页面）
      if (this.viewerList.length > 0) {
        this.viewerBuilder()
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 全屏照片查看器（Swiper 左右滑动切换，默认缩略图，可加载原图） */
  @Builder
  viewerBuilder(): void {
    Stack() {
      // 背景
      Column()
        .width('100%').height('100%')
        .backgroundColor('#000000')

      // 左右滑动切换照片
      Swiper() {
        ForEach(this.viewerList, (asset: ImmichAsset, idx: number) => {
          Stack() {
            if (asset.type === 'VIDEO') {
              // 视频：先显示缩略图，点击后用 Video 播放
              if (!this.isVideoPlaying(idx)) {
                Stack() {
                  Image(asset.thumbnailUrl)
                    .width('100%').height('100%')
                    .objectFit(ImageFit.Contain)
                  // 播放按钮
                  Circle()
                    .width(64).height(64)
                    .fill('rgba(0,0,0,0.45)')
                  Text('▶')
                    .fontSize(28).fontColor('#FFFFFF')
                }
                .width('100%').height('100%')
                .onClick(() => { this.playVideo(idx) })
              } else {
                Stack() {
                  Video({
                    src: asset.videoUrl,
                    previewUri: asset.thumbnailUrl,
                    controller: this.getVideoController(idx)
                  })
                    .width('100%').height('100%')
                    .controls(true)
                    .objectFit(ImageFit.Contain)
                    .onStart(() => {
                      // 真正开始播放才取消转圈
                      this.setVideoLoading(idx, false)
                    })
                    .onError(() => {
                      this.setVideoLoading(idx, false)
                    })
                  // 加载转圈（开始播放后自动消失）
                  if (this.isVideoLoading(idx)) {
                    Column() {
                      LoadingProgress()
                        .width(48).height(48)
                        .color('#FFFFFF')
                      Text('视频加载中…')
                        .fontSize(12).fontColor('#FFFFFF')
                        .margin({ top: 10 })
                    }
                    .width('100%').height('100%')
                    .justifyContent(FlexAlign.Center)
                    .backgroundColor('rgba(0,0,0,0.5)')
                  }
                }
                .width('100%').height('100%')
                // 底部留白，让视频控制条完整露出（避开系统手势条）
                .padding({ bottom: 80 })
              }
            } else {
              Image(this.isOriginalLoaded(idx)
                ? asset.originalUrl
                : asset.thumbnailUrl)
                .width('100%')
                .height('100%')
                .objectFit(ImageFit.Contain)
            }
          }
          .width('100%').height('100%')
        }, (asset: ImmichAsset, idx: number): string => asset.id)
      }
      .index(this.viewerIndex)
      .indicator(false)
      .loop(false)
      .width('100%').height('100%')
      .onChange((index: number) => {
        // 切换照片时：停止所有视频播放（回到缩略图），避免多个视频同时出声
        if (index !== this.viewerIndex) {
          // 滑走时终止分享下载并清理缓存
          this.cancelShareDownload()
          const reset: boolean[] = []
          for (let i = 0; i < this.videoPlaying.length; i++) {
            reset.push(false)
          }
          this.videoPlaying = reset
        }
        this.viewerIndex = index
      })

      // 顶部关闭
      Text('✕')
        .fontSize(22).fontColor('#FFFFFF')
        .padding(12)
        .position({ x: 16, y: 16 })
        .onClick(() => { this.closeViewer() })

      // 顶部分享按钮（下载中状态显示文字，右移避免被边缘裁剪）
      Text(this.sharing ? '下载中…' : '📤')
        .fontSize(this.sharing ? 13 : 18)
        .fontColor('#FFFFFF')
        .padding(10)
        .borderRadius(16)
        .backgroundColor(this.sharing ? 'rgba(0,0,0,0.4)' : 'transparent')
        .position({ x: '72%', y: 16 })
        .onClick(() => { this.shareCurrentAsset() })

      // 顶部索引指示
      Text(`${this.viewerIndex + 1} / ${this.viewerList.length}`)
        .fontSize(13).fontColor('#FFFFFF')
        .position({ x: '45%', y: 24 })

      // 底部信息（视频播放时隐藏，避免遮挡进度条；图片始终显示）
      if (!(this.currentViewerAsset() && this.currentViewerAsset()!.type === 'VIDEO'
        && this.isVideoPlaying(this.viewerIndex))) {
        this.viewerInfoBar()
      }
    }
    .width('100%').height('100%')
    .backgroundColor('#000000')
    .transition(TransitionEffect.OPACITY
      .combine(TransitionEffect.scale({ x: 0.95, y: 0.95 }))
      .animation({ duration: 200, curve: Curve.EaseOut }))
  }

  /** 查看器底部信息栏（文件名 + 日期 + 加载原图按钮） */
  @Builder
  viewerInfoBar(): void {
    Column() {
      Text(this.currentViewerAsset() ? this.currentViewerAsset()!.originalFileName : '')
        .fontSize(12).fontColor('#FFFFFF')
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.currentViewerAsset() && this.currentViewerAsset()!.createdAt) {
        Text(this.formatDate(this.currentViewerAsset()!.createdAt))
          .fontSize(10).fontColor('#BBBBBB')
          .margin({ top: 4 })
      }
      // 图片：加载原图按钮；视频：提示
      if (this.currentViewerAsset() && this.currentViewerAsset()!.type === 'VIDEO') {
        Text('🎬 视频 · 点击 ▶ 播放')
          .fontSize(11).fontColor('#BBBBBB')
          .margin({ top: 10 })
      } else if (!this.isOriginalLoaded(this.viewerIndex)) {
        Text('⚡ 加载原图')
          .fontSize(12).fontColor('#FFFFFF')
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .borderRadius(16)
          .backgroundColor('rgba(255,255,255,0.2)')
          .margin({ top: 10 })
          .onClick(() => { this.loadOriginal(this.viewerIndex) })
      } else {
        Text('已加载原图')
          .fontSize(11).fontColor('#BBBBBB')
          .margin({ top: 10 })
      }
      // 分享状态提示
      if (this.shareMsg) {
        Text(this.shareMsg)
          .fontSize(11).fontColor('#FFFFFF')
          .margin({ top: 8 })
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor('rgba(0,0,0,0.5)')
    .position({ x: 0, y: '78%' })
  }

  /** 当前查看的资产 */
  currentViewerAsset(): ImmichAsset | null {
    if (this.viewerIndex < 0 || this.viewerIndex >= this.viewerList.length) {
      return null
    }
    return this.viewerList[this.viewerIndex]
  }

  /** 指定索引是否已加载原图 */
  isOriginalLoaded(idx: number): boolean {
    if (idx < 0 || idx >= this.viewerShowOriginal.length) {
      return false
    }
    return this.viewerShowOriginal[idx]
  }

  /** 加载指定索引的原图 */
  loadOriginal(idx: number): void {
    if (idx < 0 || idx >= this.viewerShowOriginal.length) {
      return
    }
    this.viewerShowOriginal[idx] = true
  }

  /**
   * 分享当前查看的照片/视频
   * 流程：下载原文件到沙箱缓存 → 构造 file:// URI → 调起系统分享面板
   * 切走时通过 cancelShareDownload 终止下载并删除缓存
   */
  async shareCurrentAsset(): Promise<void> {
    if (this.sharing) return
    const asset: ImmichAsset | null = this.currentViewerAsset()
    if (!asset) return
    this.sharing = true
    this.shareMsg = ''
    let cancelled: boolean = false
    try {
      // 1. 下载原文件（图片用 originalUrl，视频用 videoUrl 或 originalUrl）
      const downloadUrl: string = asset.type === 'VIDEO' ? asset.videoUrl : asset.originalUrl
      const req: http.HttpRequest = http.createHttp()
      this.shareReq = req
      let filePath: string = ''
      try {
        const r: http.HttpResponse = await req.request(downloadUrl, {
          method: http.RequestMethod.GET,
          expectDataType: http.HttpDataType.ARRAY_BUFFER,
          connectTimeout: 15000,
          readTimeout: 60000
        })
        if (this.shareReq === null) {
          // 已被取消
          cancelled = true
          return
        }
        if (r.responseCode !== 200) {
          this.shareMsg = '下载失败，请稍后重试'
          return
        }
        const buf: ArrayBuffer = r.result as ArrayBuffer
        // 2. 写入缓存目录
        const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext
        const cacheDir: string = ctx.cacheDir
        const ext: string = asset.type === 'VIDEO' ? '.mp4' : this.fileExt(asset.originalFileName)
        filePath = `${cacheDir}/immich_share_${Date.now()}${ext}`
        this.shareFilePath = filePath
        const file = fs.openSync(filePath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE)
        fs.writeSync(file.fd, buf)
        fs.closeSync(file)
      } finally {
        req.destroy()
        this.shareReq = null
      }
      if (cancelled) {
        this.cleanupShareFile()
        return
      }
      // 3. 构造分享数据并调起系统分享面板
      const uri: string = fileUri.getUriFromPath(filePath)
      const record: systemShare.SharedRecord = {
        uri: uri,
        title: asset.originalFileName,
        description: 'iStore 相册分享',
        utd: asset.type === 'VIDEO' ? 'general.video' : 'general.image'
      }
      const data: systemShare.SharedData = new systemShare.SharedData(record)
      const controller: systemShare.ShareController = new systemShare.ShareController(data)
      const options: systemShare.ShareControllerOptions = {}
      const abilityCtx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext
      await controller.show(abilityCtx, options)
      this.shareMsg = '分享面板已打开'
    } catch (e) {
      hilog.error(0x0001, 'AlbumTab', `share failed: ${JSON.stringify(e)}`)
      this.shareMsg = '分享失败，请重试'
    } finally {
      this.sharing = false
      this.shareReq = null
      this.cleanupShareFile()
    }
  }

  /**
   * 终止分享下载（用户滑走/关闭查看器时调用）
   * 终止请求并删除已下载的缓存文件
   */
  cancelShareDownload(): void {
    if (this.shareReq) {
      try {
        // destroy 会终止进行中的请求
        this.shareReq.destroy()
      } catch (e) {
        hilog.error(0x0001, 'AlbumTab', `cancel share req err: ${JSON.stringify(e)}`)
      }
      this.shareReq = null
    }
    this.sharing = false
    this.shareMsg = ''
    this.cleanupShareFile()
  }

  /** 删除分享下载的缓存文件 */
  private cleanupShareFile(): void {
    if (this.shareFilePath) {
      try {
        const f = fs.openSync(this.shareFilePath, fs.OpenMode.READ_WRITE)
        fs.closeSync(f)
        fs.unlinkSync(this.shareFilePath)
      } catch (e) {
        hilog.error(0x0001, 'AlbumTab', `cleanup share file err: ${JSON.stringify(e)}`)
      }
      this.shareFilePath = ''
    }
  }

  /** 从文件名提取扩展名 */
  fileExt(name: string): string {
    const idx: number = name.lastIndexOf('.')
    if (idx >= 0 && idx < name.length - 1) {
      return name.substring(idx)
    }
    return '.jpg'
  }

  /** 服务器统计条（图标 + 中文标签 + 数值） */
  @Builder
  statsBar(): void {
    Row() {
      // 照片
      Column() {
        Row() {
          SymbolGlyph($r('sys.symbol.picture'))
            .fontSize(13).fontColor([this.theme.textSecondary])
          Text(' 相册')
            .fontSize(10).fontColor(this.theme.textSecondary)
        }
        Text(`${this.serverInfo ? this.serverInfo.statistics.totalImages : 0}`)
          .fontSize(14).fontColor(this.theme.textPrimary).fontWeight(FontWeight.Bold)
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)

      // 视频
      Column() {
        Row() {
          SymbolGlyph($r('sys.symbol.resolution_video'))
            .fontSize(13).fontColor([this.theme.textSecondary])
          Text(' 视频')
            .fontSize(10).fontColor(this.theme.textSecondary)
        }
        Text(`${this.serverInfo ? this.serverInfo.statistics.totalVideos : 0}`)
          .fontSize(14).fontColor(this.theme.textPrimary).fontWeight(FontWeight.Bold)
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)

      // 存储占用
      Column() {
        Row() {
          SymbolGlyph($r('sys.symbol.externaldrive'))
            .fontSize(13).fontColor([this.theme.textSecondary])
          Text(' 占用')
            .fontSize(10).fontColor(this.theme.textSecondary)
        }
        Text(this.formatBytes(this.serverInfo ? this.serverInfo.statistics.totalBytes : 0))
          .fontSize(14).fontColor(this.theme.textPrimary).fontWeight(FontWeight.Bold)
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)

      // 版本
      Column() {
        Row() {
          SymbolGlyph($r('sys.symbol.label'))
            .fontSize(13).fontColor([this.theme.textSecondary])
          Text(' 版本')
            .fontSize(10).fontColor(this.theme.textSecondary)
        }
        Text(`${this.serverInfo ? this.serverInfo.version : '--'}`)
          .fontSize(14).fontColor(this.theme.primary).fontWeight(FontWeight.Bold)
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .height(52)
    .padding({ left: 8, right: 8 })
    .borderRadius(12)
    .backgroundColor(this.theme.bgCard)
    .border({ width: 0.5, color: this.theme.borderGlass })
    .margin({ left: 12, right: 12, top: 2, bottom: 0 })
  }

  @Builder
  configView(): void {
    Scroll() {
      Column() {
        Text('📷 Immich 相册')
          .fontSize(22)
          .fontColor(this.theme.textPrimary)
          .fontWeight(FontWeight.Bold)
          .margin({ top: 30 })

        Text('连接你的自托管相册服务')
          .fontSize(13)
          .fontColor(this.theme.textSecondary)
          .margin({ top: 6, bottom: 24 })

        // 服务器地址
        Column() {
          Text('服务器地址').fontSize(12).fontColor(this.theme.textSecondary)
            .width('100%').margin({ bottom: 8 })
          TextInput({ placeholder: 'http://192.168.1.1:2283', text: this.baseUrl })
            .placeholderColor(this.theme.textTertiary).fontColor(this.theme.textPrimary)
            .backgroundColor('transparent')
            .onChange((v: string) => { this.baseUrl = v })
            .width('100%').height(48)
        }
        .width('100%')
        .padding(14)
        .borderRadius(16)
        .backgroundColor(this.theme.bgCard)
        .border({ width: 0.5, color: this.theme.borderGlass })
        .margin({ bottom: 10 })

        // 检测本机 Immich
        Row() {
          Text(this.isProbing ? '检测中…' : '🔍 检测本机安装的immich')
            .fontSize(13)
            .fontColor(this.theme.primary)
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .borderRadius(14)
            .backgroundColor('rgba(68,138,255,0.08)')
            .border({ width: 0.5, color: '#448AFF33' })
            .onClick(() => this.probeLocalImmich())

          if (this.probeResult === 'found') {
            Text('✓ 已填入上方地址')
              .fontSize(11)
              .fontColor(this.theme.success)
              .margin({ left: 10 })
          }
        }
        .width('100%')
        .margin({ bottom: 14 })

        if (this.probeMsg) {
          Text(this.probeMsg)
            .fontSize(11)
            .fontColor(this.probeResult === 'found' ? this.theme.success : this.theme.warning)
            .width('100%')
            .lineHeight(16)
            .margin({ bottom: 14 })
        }

        // API Key
        Column() {
          Text('API Key').fontSize(12).fontColor(this.theme.textSecondary)
            .width('100%').margin({ bottom: 8 })
          TextInput({ placeholder: '在 Immich 网页端创建', text: this.apiKey })
            .placeholderColor(this.theme.textTertiary).fontColor(this.theme.textPrimary)
            .backgroundColor('transparent').type(InputType.Password)
            .onChange((v: string) => { this.apiKey = v })
            .width('100%').height(48)
        }
        .width('100%')
        .padding(14)
        .borderRadius(16)
        .backgroundColor(this.theme.bgCard)
        .border({ width: 0.5, color: this.theme.borderGlass })
        .margin({ bottom: 14 })

        Text('如何获取 API Key：登录 Immich 网页 → 账号设置 → API 密钥 → 新建API密钥 → 全选权限 → 创建即可')
          .fontSize(10)
          .fontColor(this.theme.textTertiary)
          .width('100%')
          .lineHeight(16)
          .margin({ bottom: 20 })

        if (this.configError) {
          Text('⚠ ' + this.configError)
            .fontSize(12).fontColor(this.theme.danger)
            .width('100%').margin({ bottom: 12 })
        }

        Button() {
          Text(this.isTesting ? '连接中…' : '测试并保存')
            .fontSize(15)
            .fontColor('#FFFFFF')
            .fontWeight(FontWeight.Medium)
        }
        .width('100%').height(50).borderRadius(25)
        .linearGradient({ angle: 135, colors: [[this.theme.primary, 0], [this.theme.secondary, 1]] })
        .enabled(!this.isTesting)
        .onClick(() => this.testAndSave())

        if (this.configured) {
          Text('取消')
            .fontSize(14)
            .fontColor(this.theme.textSecondary)
            .width('100%').textAlign(TextAlign.Center)
            .padding({ top: 14, bottom: 14 })
            .onClick(() => { this.showConfig = false })
        }
      }
      .width('100%')
      .padding({ left: 24, right: 24, bottom: 30 })
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
  }

  @Builder
  albumListView(): void {
    Scroll() {
      Column() {
        if (this.isLoading) {
          Column() {
            LoadingProgress().color(this.theme.primary).width(32).height(32)
            Text('加载相册中…').fontSize(13).fontColor(this.theme.textTertiary).margin({ top: 12 })
          }.width('100%').padding({ top: 60 })
        } else if (this.errorText) {
          Column() {
            Text('⚠ ' + this.errorText).fontSize(13).fontColor(this.theme.warning)
            Text('点击重试').fontSize(13).fontColor(this.theme.primary)
              .padding({ top: 10 })
              .onClick(() => this.loadAlbums())
          }.width('100%').padding({ top: 60 })
        } else if (this.albums.length === 0) {
          Column() {
            Text('📁 暂无相册').fontSize(15).fontColor(this.theme.textPrimary)
            Text('在 Immich 网页端创建相册后，下拉刷新查看')
              .fontSize(12).fontColor(this.theme.textTertiary).margin({ top: 8 })
          }.width('100%').padding({ top: 80 })
        } else {
          // 相册网格（两列）
          Grid() {
            ForEach(this.albums, (album: ImmichAlbum) => {
              GridItem() {
                Column() {
                  Stack() {
                    if (album.coverThumbnailUrl) {
                      Image(album.coverThumbnailUrl)
                        .width('100%').height(90).objectFit(ImageFit.Cover)
                    } else {
                      Column() {
                        Text('📁').fontSize(32)
                      }
                      .width('100%').height(90)
                      .justifyContent(FlexAlign.Center)
                      .backgroundColor(this.theme.bgGlassLight)
                    }
                  }
                  .width('100%').height(90).borderRadius(12)
                  .clip(true)

                  // 名称 + 张数（同一行）
                  Row() {
                    Text(album.albumName)
                      .fontSize(12)
                      .fontColor(this.theme.textPrimary)
                      .fontWeight(FontWeight.Medium)
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1)
                    Text(`${album.assetCount} 张`)
                      .fontSize(10)
                      .fontColor(this.theme.textTertiary)
                      .margin({ left: 4 })
                  }
                  .width('100%')
                  .margin({ top: 8 })
                }
                .padding(10)
                .borderRadius(16)
                .backgroundColor(this.theme.bgCard)
                .border({ width: 0.5, color: this.theme.borderGlass })
                .onClick(() => this.openAlbum(album))
              }
            })
          }
          .columnsTemplate('1fr 1fr')
          .columnsGap(10)
          .rowsGap(10)
          .width('100%')
        }
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 0, bottom: 130 })
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .align(Alignment.Top)
  }

  @Builder
  albumDetailView(): void {
    Column() {
      // 相册头部
      Row() {
        Row() {
          Text('←').fontSize(18).fontColor(this.theme.primary)
          Text(' ' + (this.activeAlbum ? this.activeAlbum.albumName : ''))
            .fontSize(15).fontColor(this.theme.textPrimary).fontWeight(FontWeight.Medium)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .padding({ left: 12, right: 16, top: 6, bottom: 6 })
        .borderRadius(100).backgroundColor(this.theme.bgCard)
        .border({ width: 0.5, color: this.theme.borderGlass })
        .onClick(() => { this.activeAlbum = null; this.assets = []; AppState.getInstance().setAlbumSubView(false) })

        Blank()
        Text(`${this.assets.length} 张`)
          .fontSize(11).fontColor(this.theme.textTertiary)
      }
      .width('100%').padding({ left: 16, right: 16, top: 4, bottom: 8 })

      if (this.albumLoading) {
        Column() {
          LoadingProgress().color(this.theme.primary).width(32).height(32)
          Text('加载中…').fontSize(13).fontColor(this.theme.textTertiary).margin({ top: 12 })
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (this.assets.length === 0) {
        Column() {
          Text('📷 相册是空的').fontSize(14).fontColor(this.theme.textSecondary)
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column() {
            Grid() {
              ForEach(this.assets, (asset: ImmichAsset, idx: number) => {
                GridItem() {
                  Stack() {
                    Image(asset.thumbnailUrl)
                      .width('100%').height('100%')
                      .objectFit(ImageFit.Cover)
                      .borderRadius(8)
                    // 视频角标
                    if (asset.type === 'VIDEO') {
                      Text('🎬')
                        .fontSize(14)
                        .padding(4)
                        .borderRadius(6)
                        .backgroundColor('rgba(0,0,0,0.55)')
                        .position({ x: 6, y: 6 })
                    }
                  }
                  .width('100%').height(110)
                  .clip(true)
                  .onClick(() => { this.openViewer(this.assets, idx) })
                }
              }, (asset: ImmichAsset): string => asset.id)
            }
            .columnsTemplate('1fr 1fr 1fr')
            .columnsGap(4)
            .rowsGap(4)
            .width('100%')
            .padding({ left: 8, right: 8 })
            // 滚动到底加载下一页
            .onReachEnd(() => { this.loadMoreAssets() })
            // 加载更多提示
            if (this.assetsLoadingMore) {
              Row() {
                LoadingProgress().width(18).height(18).color(this.theme.textTertiary)
                Text(' 加载更多…').fontSize(12).fontColor(this.theme.textTertiary)
              }.width('100%').justifyContent(FlexAlign.Center).padding({ top: 8, bottom: 8 })
            } else if (this.assetsTotal >= 0 && this.assets.length >= this.assetsTotal && this.assets.length > 0) {
              Text('已加载全部')
                .fontSize(11).fontColor(this.theme.textTertiary)
                .width('100%').textAlign(TextAlign.Center).padding({ top: 8, bottom: 8 })
            }
          }
          .width('100%')
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      }
    }
    .width('100%')
    .height('100%')
    .transition(TransitionEffect.OPACITY.animation({ duration: 200, curve: Curve.EaseOut }))
  }

  /** 自绘底部导航条（仿主页悬浮胶囊样式，缩小版） */
  @Builder
  bottomNavBar(): void {
    Row() {
      // 相片
      this.navItem(0, '相片', $r('sys.symbol.picture'))
      // 相册
      this.navItem(1, '相册', $r('sys.symbol.rectangle_stack'))
    }
    .width(240)
    .height(44)
    .borderRadius(22)
    .backgroundColor(this.isDark ? 'rgba(30,34,64,0.72)' : 'rgba(255,255,255,0.75)')
    .backdropBlur(20)
    .border({ width: 0.5, color: this.theme.borderGlass })
    .shadow({
      radius: 12,
      color: this.isDark ? 'rgba(0,0,0,0.35)' : 'rgba(31,47,94,0.10)',
      offsetY: 4
    })
  }

  /** 单个导航项（选中态高亮 + 图标 + 文字，仿 BottomTabBarStyle） */
  @Builder
  navItem(tab: number, label: string, icon: Resource): void {
    Column() {
      // 图标
      SymbolGlyph(icon)
        .fontSize(17)
        .fontColor([this.mainTab === tab ? this.theme.primary : this.theme.textTertiary])
      // 文字
      Text(label)
        .fontSize(10)
        .fontColor(this.mainTab === tab ? this.theme.primary : this.theme.textTertiary)
        .fontWeight(this.mainTab === tab ? FontWeight.Medium : FontWeight.Normal)
        .margin({ top: 1 })
    }
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      if (this.mainTab !== tab) {
        this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
          this.mainTab = tab
        })
      }
    })
  }

  /** 相片时间线视图（按天分组，仿鸿蒙相册首页） */
  @Builder
  photoTimelineView(): void {
    Column() {
      if (this.allPhotosLoading) {
        Column() {
          LoadingProgress().color(this.theme.primary).width(32).height(32)
          Text('加载中…').fontSize(13).fontColor(this.theme.textTertiary).margin({ top: 12 })
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (this.allPhotos.length === 0) {
        Column() {
          Text('📷 暂无照片').fontSize(14).fontColor(this.theme.textSecondary)
          Text('在 Immich 网页端上传照片后，下拉刷新查看')
            .fontSize(11).fontColor(this.theme.textTertiary).margin({ top: 6 })
          Text(this.diagnosing ? '诊断中…' : '🔧 诊断 API')
            .fontSize(12).fontColor(this.theme.primary)
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .borderRadius(12)
            .backgroundColor('rgba(68,138,255,0.08)')
            .margin({ top: 16 })
            .onClick(() => this.runDiagnose())
          if (this.showDiagnose) {
            Text(this.diagnoseText)
              .fontSize(10).fontColor(this.theme.textTertiary)
              .fontFamily('monospace')
              .width('85%').lineHeight(15)
              .padding(10).borderRadius(10)
              .backgroundColor(this.theme.bgGlassLight)
              .margin({ top: 10 })
          }
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else {
        List({ space: 2 }) {
          // 按天分组：每组一个 ListItem = 日期标题 + 照片流
          ForEach(this.photoDays, (day: PhotoDay) => {
            ListItem() {
              Column() {
                // 日期标题
                Row() {
                  Text(day.title)
                    .fontSize(15)
                    .fontColor(this.theme.textPrimary)
                    .fontWeight(FontWeight.Bold)
                  Text(`${day.items.length} 张`)
                    .fontSize(11)
                    .fontColor(this.theme.textTertiary)
                    .margin({ left: 8 })
                }
                .width('100%')
                .padding({ left: 12, right: 12, top: 10, bottom: 8 })

                // 当天照片流（Flex 换行，3 列）
                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(day.items, (asset: ImmichAsset, idxInDay: number) => {
                    Stack() {
                      Image(asset.thumbnailUrl)
                        .width('100%').height('100%')
                        .objectFit(ImageFit.Cover)
                      // 视频角标
                      if (asset.type === 'VIDEO') {
                        Text('🎬')
                          .fontSize(13)
                          .padding(3)
                          .borderRadius(5)
                          .backgroundColor('rgba(0,0,0,0.55)')
                          .position({ x: 5, y: 5 })
                      }
                    }
                    .width('33.3%')
                    .aspectRatio(1)
                    .clip(true)
                    .padding({ left: 1.5, right: 1.5, bottom: 3 })
                    .onClick(() => {
                      this.openViewer(this.allPhotos, this.photoIndexByDay(day, idxInDay))
                    })
                  }, (asset: ImmichAsset): string => asset.id)
                }
                .width('100%')
                .padding({ left: 6.5, right: 6.5 })
              }
              .width('100%')
            }
          }, (day: PhotoDay): string => day.dateKey)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .onReachEnd(() => { this.loadMoreAllPhotos() })

        // 加载更多提示（固定在 List 下方）
        if (this.allPhotosLoadingMore) {
          Row() {
            LoadingProgress().width(18).height(18).color(this.theme.textTertiary)
            Text(' 加载更多…').fontSize(12).fontColor(this.theme.textTertiary)
          }.width('100%').justifyContent(FlexAlign.Center).padding({ top: 8, bottom: 8 })
        } else if (this.allPhotosTotal >= 0 && this.allPhotos.length >= this.allPhotosTotal && this.allPhotos.length > 0) {
          Text('已加载全部')
            .fontSize(11).fontColor(this.theme.textTertiary)
            .width('100%').textAlign(TextAlign.Center).padding({ top: 8, bottom: 8 })
        }
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 计算某天照片在全局列表中的索引（供查看器定位） */
  private photoIndexByDay(day: PhotoDay, idxInDay: number): number {
    let base: number = 0
    for (let i = 0; i < this.photoDays.length; i++) {
      if (this.photoDays[i].dateKey === day.dateKey) {
        return base + idxInDay
      }
      base += this.photoDays[i].items.length
    }
    return idxInDay
  }
}
