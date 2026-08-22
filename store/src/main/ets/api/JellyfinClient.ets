/**
 * JellyfinClient — Jellyfin 媒体服务器 REST API 客户端
 * 参考 MaFei 项目（KMP）API 调用模式移植：
 *  - 登录: POST /Users/AuthenticateByName
 *  - 继续观看: GET /Users/{uid}/Items/Resume
 *  - 最近添加: GET /Users/{uid}/Items/Latest
 *  - 媒体库:   GET /Users/{uid}/Views
 *  - 接下来:   GET /Shows/NextUp
 */
import { http } from '@kit.NetworkKit'
import { hilog } from '@kit.PerformanceAnalysisKit'

const DOMAIN = 0x0001
const TAG = 'JellyfinClient'

/** 媒体条目 */
export interface JellyfinItem {
  id: string
  name: string
  type: string        // Movie / Series / Episode / MusicAlbum ...
  imageUrl: string
  overview: string
  year: number
  seriesName: string   // 剧集名（Episode 用）
  season: number
  episode: number
  progress: number     // 播放进度 0-100
  runTime: number      // 秒
}

/** 媒体库视图 */
export interface JellyfinView {
  id: string
  name: string
  type: string
  imageUrl: string
  itemCount: number
}

/** 登录结果 */
export interface JellyfinAuth {
  baseUrl: string
  token: string
  userId: string
  userName: string
}

export class JellyfinClient {
  private baseUrl: string = ''
  private token: string = ''
  private username: string = ''
  private password: string = ''
  private lastUserId: string = ''
  /** token 刷新回调（通知页面持久化新 token） */
  onTokenRefresh: ((newToken: string, userId: string) => void) | null = null

  constructor(baseUrl: string, token: string = '', username: string = '', password: string = '') {
    // 标准化：去尾部斜杠
    this.baseUrl = baseUrl.trim().replace(/\/+$/, '')
    this.token = token
    this.username = username
    this.password = password
  }

  /** 登录：用户名+密码 → token + userId */
  async login(username: string, password: string): Promise<JellyfinAuth> {
    const req = http.createHttp()
    try {
      const resp = await req.request(`${this.baseUrl}/Users/AuthenticateByName`, {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/json',
          'X-Emby-Authorization': this.authHeader(),
          'Accept': 'application/json'
        },
        extraData: JSON.stringify({
          Username: username,
          Pw: password
        }),
        connectTimeout: 8000,
        readTimeout: 12000,
        remoteValidation: 'skip'
      })
      if (resp.responseCode !== 200) {
        throw new Error(`登录失败 HTTP ${resp.responseCode}`)
      }
      const text: string = resp.result as string
      const json: Record<string, Object> = JSON.parse(text) as Record<string, Object>
      const user: Record<string, Object> = json['User'] as Record<string, Object>
      const token: string = json['AccessToken'] as string
      const userId: string = user ? (user['Id'] as string) : ''
      const name: string = user ? (user['Name'] as string) : ''
      if (!token || !userId) {
        throw new Error('登录响应缺少 Token/UserId')
      }
      this.token = token
      this.lastUserId = userId
      return { baseUrl: this.baseUrl, token: token, userId: userId, userName: name }
    } catch (e) {
      this.throwMsg(e, '登录')
      throw new Error('Jellyfin 登录失败')
    } finally {
      req.destroy()
    }
  }

  /** X-Emby-Authorization 头 */
  private authHeader(): string {
    const client = `Client="iStore", Version="1.0.0"`
    const device = `Device="HarmonyOS", DeviceId="istore-device-001"`
    return `MediaBrowser ${client}, ${device}`
  }

  /** 通用 GET */
  private async getJson(path: string, params: string = ''): Promise<Record<string, Object>> {
    const url: string = `${this.baseUrl}${path}${params}`
    const req = http.createHttp()
    try {
      hilog.info(DOMAIN, TAG, `GET ${url} token=${this.token}`)
      const resp = await req.request(url, {
        method: http.RequestMethod.GET,
        header: {
          'X-Emby-Token': this.token,
          'Accept': 'application/json'
        },
        connectTimeout: 8000,
        readTimeout: 12000,
        remoteValidation: 'skip'
      })
      if (resp.responseCode === 401 && this.username) {
        // token 失效：自动重新登录并重试一次
        const auth: JellyfinAuth = await this.login(this.username, this.password)
        this.token = auth.token
        if (this.onTokenRefresh) {
          this.onTokenRefresh(auth.token, auth.userId)
        }
        req.destroy()
        return this.getJson(path, params)
      }
      if (resp.responseCode !== 200) {
        throw new Error(`HTTP ${resp.responseCode}`)
      }
      const text: string = resp.result as string
      const parsed: Object = JSON.parse(text) as Object
      // 兼容顶层数组（Latest 接口直接返回数组）
      if (Array.isArray(parsed)) {
        const wrap: Record<string, Object> = {}
        wrap['Items'] = parsed as Object[]
        return wrap
      }
      return parsed as Record<string, Object>
    } catch (e) {
      this.throwMsg(e, '请求')
      throw new Error('Jellyfin 请求失败')
    } finally {
      req.destroy()
    }
  }

  private throwMsg(e: Object, tag: string): void {
    let msg: string = ''
    try {
      msg = (e as Error).message || String(e)
    } catch (_e) {
      msg = String(e)
    }
    hilog.error(DOMAIN, TAG, `${tag} err: ${msg}`)
  }

  /** 继续观看 */
  async getResume(userId: string): Promise<JellyfinItem[]> {
    const json = await this.getJson(`/Users/${userId}/Items/Resume`, `?limit=20&enableUserData=true`)
    return this.mapItems(json)
  }

  /** 最近添加 */
  async getLatest(userId: string): Promise<JellyfinItem[]> {
    const json = await this.getJson(`/Users/${userId}/Items/Latest`, `?limit=20&enableUserData=true`)
    // Latest 接口直接返回数组（无 Items 包裹）
    const arr: Object[] = json['Items'] as Object[]
    return this.mapArr(arr ? arr : [])
  }

  /** 媒体库视图 */
  async getViews(userId: string): Promise<JellyfinView[]> {
    const json = await this.getJson(`/Users/${userId}/Views`, `?includeExternalContent=false&includeHidden=false`)
    const items: Object[] = (json['Items'] as Object[]) || []
    const out: JellyfinView[] = []
    for (let i = 0; i < items.length; i++) {
      const d: Record<string, Object> = items[i] as Record<string, Object>
      const type: string = (d['CollectionType'] as string) || (d['Type'] as string) || ''
      // 过滤不支持的类型
      if (type === 'channels' || type === 'livetv') continue
      out.push({
        id: (d['Id'] as string) || '',
        name: (d['Name'] as string) || '',
        type: type,
        imageUrl: this.imageUrl(d),
        itemCount: Number(d['ChildCount'] || 0)
      })
    }
    return out
  }

  /** 接下来（剧集） */
  async getNextUp(userId: string): Promise<JellyfinItem[]> {
    const json = await this.getJson(`/Shows/NextUp`, `?limit=20&enableUserData=true&enableResumable=true&userId=${userId}`)
    return this.mapItems(json)
  }

  /** 媒体库内条目（recursive=true 才能取到媒体内容） */
  async getItems(userId: string, parentId: string, limit: number = 60): Promise<JellyfinItem[]> {
    const json = await this.getJson(`/Users/${userId}/Items`,
      `?ParentId=${parentId}&limit=${limit}&recursive=true&enableUserData=true` +
      `&Fields=Overview,Genres,ProductionYear,RunTimeTicks,CommunityRating,OfficialRating,Path` +
      `&ImageTypeLimit=1&EnableImageTypes=Primary,Backdrop,Thumb`)
    return this.mapItems(json)
  }

  /** Items 数组解析 */
  private mapItems(json: Record<string, Object>): JellyfinItem[] {
    const items: Object[] = (json['Items'] as Object[]) || []
    return this.mapArr(items)
  }

  private mapArr(arr: Object[]): JellyfinItem[] {
    const out: JellyfinItem[] = []
    for (let i = 0; i < arr.length; i++) {
      const d: Record<string, Object> = arr[i] as Record<string, Object>
      out.push({
        id: (d['Id'] as string) || '',
        name: (d['Name'] as string) || '',
        type: (d['Type'] as string) || '',
        imageUrl: this.imageUrlFallback(d),
        overview: (d['Overview'] as string) || '',
        year: Number(d['ProductionYear'] || 0),
        seriesName: (d['SeriesName'] as string) || '',
        season: Number(d['ParentIndexNumber'] || 0),
        episode: Number(d['IndexNumber'] || 0),
        progress: Number(d['UserData'] ? ((d['UserData'] as Record<string, Object>)['PlayedPercentage'] || 0) : 0),
        runTime: Number(d['RunTimeTicks'] || 0) / 10000000
      })
    }
    return out
  }

  /** 图片 fallback 链：Primary → Backdrop → Thumb */
  private imageUrlFallback(d: Record<string, Object>): string {
    const id: string = (d['Id'] as string) || ''
    if (!id) return ''
    const tags: Object = d['ImageTags'] as Object
    let tagName: string = ''
    try {
      const tagsObj: Record<string, Object> = tags as Record<string, Object>
      if (tagsObj['Primary'] !== undefined) {
        tagName = 'Primary'
      } else if (tagsObj['Backdrop'] !== undefined) {
        tagName = 'Backdrop'
      } else if (tagsObj['Thumb'] !== undefined) {
        tagName = 'Thumb'
      }
    } catch (_e) {
      tagName = ''
    }
    if (!tagName) return ''
    return `${this.baseUrl}/Items/${id}/Images/${tagName}?maxWidth=400&quality=80`
  }

  /** 封面 URL（Primary 图片） */
  imageUrl(d: Record<string, Object>): string {
    const id: string = (d['Id'] as string) || ''
    if (!id) return ''
    const tags: Object = d['ImageTags'] as Object
    let hasPrimary: boolean = false
    try {
      const tagsObj: Record<string, Object> = tags as Record<string, Object>
      hasPrimary = tagsObj['Primary'] !== undefined
    } catch (_e) {
      hasPrimary = false
    }
    if (!hasPrimary) return ''
    return `${this.baseUrl}/Items/${id}/Images/Primary?maxWidth=400&quality=80`
  }

  /** 视图封面 */
  viewImageUrl(viewId: string): string {
    return `${this.baseUrl}/Items/${viewId}/Images/Primary?maxWidth=400&quality=80`
  }

  /** 获取播放信息（PlaybackInfo：mediaSessionId + 播放能力） */
  async getPlaybackInfo(itemId: string, userId: string = ''): Promise<PlaybackInfo> {
    const req = http.createHttp()
    try {
      const resp = await req.request(`${this.baseUrl}/Items/${itemId}/PlaybackInfo`, {
        method: http.RequestMethod.POST,
        header: {
          'X-Emby-Token': this.token,
          'Accept': 'application/json',
          'Content-Type': 'application/json'
        },
        extraData: JSON.stringify({
          UserId: userId,
          MaxStreamingBitrate: 120000000,
          StartTimeTicks: 0,
          AutoOpenLiveStream: true
        }),
        connectTimeout: 8000,
        readTimeout: 15000,
        remoteValidation: 'skip'
      })
      if (resp.responseCode === 401 && this.username) {
        const auth: JellyfinAuth = await this.login(this.username, this.password)
        this.token = auth.token
        if (this.onTokenRefresh) {
          this.onTokenRefresh(auth.token, auth.userId)
        }
        req.destroy()
        return this.getPlaybackInfo(itemId, userId)
      }
      if (resp.responseCode !== 200) {
        throw new Error(`HTTP ${resp.responseCode}`)
      }
      const text: string = resp.result as string
      const json: Record<string, Object> = JSON.parse(text) as Record<string, Object>
      const sessionId: string = (json['PlaySessionId'] as string) || ''
      const sources: Object[] = (json['MediaSources'] as Object[]) || []
      let mediaSourceId: string = ''
      let directPlay: boolean = false
      if (sources.length > 0) {
        const src: Record<string, Object> = sources[0] as Record<string, Object>
        mediaSourceId = (src['Id'] as string) || ''
        directPlay = (src['SupportsDirectPlay'] === true)
      }
      return { itemId: itemId, sessionId: sessionId, mediaSourceId: mediaSourceId, directPlay: directPlay }
    } catch (e) {
      this.throwMsg(e, 'PlaybackInfo')
      throw new Error('获取播放信息失败')
    } finally {
      req.destroy()
    }
  }

  /** 构建播放流 URL（DirectPlay 直链，带 token） */
  buildStreamUrl(info: PlaybackInfo): string {
    return `${this.baseUrl}/Videos/${info.itemId}/stream?static=true&mediaSessionId=${info.sessionId}&mediaSourceId=${info.mediaSourceId}&api_key=${this.token}`
  }

  /** 获取条目详情（overview/genres/runtime 等） */
  async getItemDetail(itemId: string): Promise<JellyfinDetail> {
    const json = await this.getJson(`/Users/${this.lastUserId}/Items/${itemId}`,
      `?Fields=Overview,Genres,ProductionYear,RunTimeTicks,CommunityRating,OfficialRating,Path` +
      `&ImageTypeLimit=1&EnableImageTypes=Primary,Backdrop,Thumb`)
    const d: Record<string, Object> = json
    const genres: string[] = []
    const genreArr: Object[] = (d['Genres'] as Object[]) || []
    for (let i = 0; i < genreArr.length; i++) {
      genres.push(genreArr[i] as string)
    }
    return {
      overview: (d['Overview'] as string) || '',
      genres: genres,
      runTimeMs: Number(d['RunTimeTicks'] || 0) / 10000,
      officialRating: (d['OfficialRating'] as string) || '',
      communityRating: Number(d['CommunityRating'] || 0)
    }
  }
}

/** 条目详情 */
export interface JellyfinDetail {
  overview: string
  genres: string[]
  runTimeMs: number
  officialRating: string
  communityRating: number
}

/** 播放信息 */
export interface PlaybackInfo {
  itemId: string
  sessionId: string
  mediaSourceId: string
  directPlay: boolean
}
