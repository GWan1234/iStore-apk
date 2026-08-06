/**
 * AppVersion - 应用版本统一读取工具
 * 版本真源：store/oh-package.json5 的 version 字段（构建时同步到 AppScope/app.json5 的 versionName）
 * 运行时通过 bundleManager 读取 versionName，所有页面共用，消除硬编码版本号
 */
import { bundleManager } from '@kit.AbilityKit'
import { hilog } from '@kit.PerformanceAnalysisKit'

const TAG = 'AppVersion'
const DOMAIN = 0x0001

let cachedVersion: string = ''

/** 获取应用版本号（如 2.8.5），读取失败返回空串 */
export function getAppVersion(): string {
  if (cachedVersion) return cachedVersion
  try {
    const info: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(
      bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT)
    cachedVersion = info.versionName
  } catch (e) {
    hilog.error(DOMAIN, TAG, `getBundleInfoForSelfSync err: ${JSON.stringify(e)}`)
    cachedVersion = ''
  }
  return cachedVersion
}

/** 带 v 前缀的版本展示文本（如 v2.8.5） */
export function getAppVersionText(): string {
  const v: string = getAppVersion()
  return v ? `v${v}` : ''
}
