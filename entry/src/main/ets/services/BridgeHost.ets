import { webview } from '@kit.ArkWeb'
import { common } from '@kit.AbilityKit'
import { util } from '@kit.ArkTS'
import { fileIo as fs, Environment } from '@kit.CoreFileKit'
import { promptAction, UIContext } from '@kit.ArkUI'
import { i18n } from '@kit.LocalizationKit'

/**
 * 相册保存的授权 UI 回调：(资产名, 沙箱路径) → 是否已经接下这次请求。
 *
 * 为什么需要这一层：API 18 起系统相册对三方应用只认安全控件 SaveButton 的
 * **临时授权**，photoPicker.save / showAssetsCreationDialog 在真机上会被拒绝
 * （201 / 14000011）。安全控件必须由用户亲手点击，因此只能由页面（Index）
 * 弹一个带 SaveButton 的面板，桥接层把待存文件交给它。
 */
export type GallerySaveUiHandler = (title: string, path: string) => boolean

/**
 * 桥接层共享宿主：控件引用、上下文、以及各 service 都会用到的公共能力。
 *
 * 拆分的起因是原来的 DeepSeekBridge 长到 1100+ 行，图片、录音、导出、存储
 * 全挤在一个类里，任何一处改动都要先读完整个文件。现在按职责拆成
 * StorageService / HistoryExportService / ImageSaveService / RecordingService，
 * 由 DeepSeekBridge 继承本类后转发。
 */
export class BridgeHost {
  readonly controller: webview.WebviewController
  readonly context: common.UIAbilityContext

  /** 由 Index 在页面出现时注入，供 toast 走推荐的 UIContext 通道 */
  private uiContext: UIContext | null = null
  /** 由 Index 注入：需要用户点安全控件授权时调用的面板 */
  private gallerySaveUi: GallerySaveUiHandler | null = null

  constructor(controller: webview.WebviewController, context: common.UIAbilityContext) {
    this.controller = controller
    this.context = context
  }

  attachUIContext(ctx: UIContext): void {
    this.uiContext = ctx
  }

  attachGallerySaveUi(handler: GallerySaveUiHandler): void {
    this.gallerySaveUi = handler
  }

  /**
   * 请求页面弹出安全控件面板。返回 false 表示页面没接（例如宿主导航已切走），
   * 调用方应继续走下一条通道。
   */
  requestGallerySave(title: string, path: string): boolean {
    const ui = this.gallerySaveUi
    if (ui === null) {
      return false
    }
    try {
      return ui(title, path)
    } catch (err) {
      console.error(`requestGallerySave failed: ${JSON.stringify(err)}`)
      return false
    }
  }

  /** 向 Web 层派发异步事件（android-* 协议） */
  dispatchEvent(name: string, detail: string): void {
    try {
      // detail 需要转义：离线识别的文本可能含引号、换行，直接拼进 JS 字面量会语法错误
      this.controller.runJavaScript(
        `window.dispatchEvent(new CustomEvent('${name}', { detail: ${JSON.stringify(detail)} }))`
      )
    } catch (err) {
      console.error(`dispatch ${name} failed: ${JSON.stringify(err)}`)
    }
  }

  /**
   * 跟随系统语言的轻提示。
   *
   * 必须全程 try/catch：全局 promptAction.showToast 在 API 18 起已废弃，
   * 某些版本由非 UI 线程调用会直接抛异常。这个异常若冒回 Web，就会让按钮
   * 立刻显示失败文案，而系统界面还没机会出现。
   */
  toast(msgZh: string, msgEn: string): void {
    let zh = true
    try {
      zh = i18n.System.getSystemLanguage().startsWith('zh')
    } catch (err) {
      // 默认中文
    }
    const message = zh ? msgZh : msgEn
    const ctx = this.uiContext
    if (ctx !== null) {
      try {
        ctx.getPromptAction().showToast({ message: message, duration: 2000 })
        return
      } catch (err) {
        console.warn(`toast via UIContext failed: ${JSON.stringify(err)}`)
      }
    }
    try {
      promptAction.showToast({ message: message, duration: 2000 })
    } catch (err) {
      console.warn(`toast failed: ${JSON.stringify(err)}`)
    }
  }

  /**
   * 确保目录存在。fs.accessSync 对不存在的路径会**抛出 13900002**
   * 而不是返回 false，因此不能用返回值判断，必须 try/catch。
   */
  ensureDir(dir: string): boolean {
    try {
      if (fs.accessSync(dir)) {
        return true
      }
    } catch (err) {
      // 不存在（13900002）或其他异常：尝试创建
    }
    try {
      fs.mkdirSync(dir, true)
      return true
    } catch (err) {
      console.error(`ensureDir failed: ${dir} ${JSON.stringify(err)}`)
      return false
    }
  }

  // 沙箱挂载点：<currentUserId> 为数字用户 ID（标准）或 currentUser 别名（PC 形态）
  private static readonly DOWNLOAD_CANDIDATES: string[] =
    ['/storage/Users/100/Download', '/storage/Users/currentUser/Download']

  /** 解析公共下载目录；优先官方 API，其次候选路径探测。 */
  pickDownloadDir(): string | null {
    try {
      const dir = Environment.getUserDownloadDir()
      if (dir !== '' && fs.accessSync(dir)) {
        return dir
      }
    } catch (err) {
      // 无权限或未挂载 → 退回候选路径探测
    }
    for (const base of BridgeHost.DOWNLOAD_CANDIDATES) {
      try {
        if (fs.accessSync(base)) {
          return base
        }
      } catch (err) {
        // 未授权时沙箱未挂载该路径 → 尝试下一个候选
      }
    }
    return null
  }

  /** 把任意文件名收敛成安全的单段文件名（去掉路径与非常规字符）。 */
  sanitizeFileName(raw: string): string | null {
    let name = raw
    const slash = Math.max(name.lastIndexOf('/'), name.lastIndexOf('\\'))
    if (slash >= 0) {
      name = name.substring(slash + 1)
    }
    name = name.replace(/[^\w.\-]+/g, '_')
    if (name === '' || name === '.' || name === '..') {
      return null
    }
    return name
  }

  /** base64 → 字节，供需要写文件的 service 复用。 */
  static decodeBase64(bytes: string): Uint8Array {
    return new util.Base64Helper().decodeSync(bytes)
  }
}
