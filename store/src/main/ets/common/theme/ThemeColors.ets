/**
 * 主题色彩系统（统一亮色米色风格，无黑夜模式）
 * 全应用固定使用 LIGHT_THEME 米色主题：浅暖米色底 + 纯白大圆角卡片 + 暖橙高亮
 * 组件通过 AppState.getTheme() 获取主题，无需关注切换
 */

/**
 * 主题调色板接口
 * 组件使用 this.theme.xxx 引用，无需硬编码颜色值
 */
export interface ThemePalette {
  // --- 主色调 ---
  primary: string           // 主题色（按钮、链接、强调元素）
  primaryDark: string       // 主题深色变体（按下态）
  secondary: string         // 辅助色（次要强调）
  accent: string            // 点缀色（图标高亮、标签）

  // --- 语义色 ---
  success: string           // 成功/正常状态
  warning: string           // 警告状态
  danger: string            // 危险/错误状态
  info: string              // 信息提示

  // --- 背景色 ---
  bgDark: string            // 页面主背景
  bgCard: string            // 卡片背景
  bgCardHover: string       // 卡片悬停/按下背景
  bgGlass: string           // 毛玻璃面板背景
  bgGlassLight: string      // 浅色毛玻璃背景
  bgCardSolid: string       // 不透明卡片背景（弹窗/浮层用，保证内容清晰）

  // --- 文本颜色 ---
  textPrimary: string       // 主要文本（标题、正文）
  textSecondary: string     // 次要文本（描述、标签）
  textTertiary: string      // 辅助文本（时间戳、次要标签）
  textAccent: string        // 强调文本（数值、高亮关键词）

  // --- 边框颜色 ---
  borderGlass: string       // 毛玻璃边框（默认态）
  borderGlassFocus: string  // 毛玻璃边框（聚焦/悬停态）

  // --- 光感（沉浸式投影） ---
  cardShadow: string        // 卡片柔和投影颜色（透明色，如 rgba(0,0,0,0.14)）
  cardShadowRadius: number  // 卡片投影模糊半径（vp）
}

/**
 * 统一亮色主题调色板（米色商务风格）
 * 浅暖米色底 #F6F2EA + 纯白卡片 + 暖橙色高亮 #FF8A3D + 绿色在线 + 黄色告警
 */
export const LIGHT_THEME: ThemePalette = {
  primary: '#FF8A3D',
  primaryDark: '#E07020',
  secondary: '#5B4CC4',
  accent: '#FF8A3D',

  success: '#00A84D',
  warning: '#E6A800',
  danger: '#D93025',
  info: '#1A73E8',

  bgDark: '#F5F1EE',
  bgCard: '#F6F2E9',
  bgCardHover: 'rgba(0, 0, 0, 0.05)',
  bgGlass: '#F6F2E9',
  bgGlassLight: 'rgba(0, 0, 0, 0.03)',
  bgCardSolid: '#F6F2E9',

  textPrimary: '#2B2A26',
  textSecondary: 'rgba(0, 0, 0, 0.62)',
  textTertiary: 'rgba(0, 0, 0, 0.38)',
  textAccent: '#FF8A3D',

  borderGlass: 'rgba(0, 0, 0, 0.08)',
  borderGlassFocus: 'rgba(0, 0, 0, 0.2)',

  cardShadow: 'rgba(180, 160, 120, 0.14)',
  cardShadowRadius: 14
}
