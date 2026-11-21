import { preferences } from '@kit.ArkData'
import { webview } from '@kit.ArkWeb'
import { abilityAccessCtrl, common } from '@kit.AbilityKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { util } from '@kit.ArkTS'
import { fileIo as fs } from '@kit.CoreFileKit'

/**
 * DeepSeekAndroid 桥：对齐 Web 层 src/app/android.ts 的 AndroidBridge 契约。
 * 注册名 window.DeepSeekAndroid；methodList 不含 updateStatus/checkForUpdate/installUpdate
 * （自更新废弃，Web 层更新入口为条件渲染，不注册即自动隐藏）。
 *
 * 阶段 0：环境三件套 + 明文键值存储（TODO 阶段 1.5 升级 HUKS 加密）+
 * 其余方法安全占位（空实现/中性默认值，保证 Web 层调用不崩）。
 */
export class DeepSeekBridge {
  private controller: webview.WebviewController
  private prefs: preferences.Preferences | null = null
  private context: common.UIAbilityContext

  constructor(controller: webview.WebviewController, context: common.UIAbilityContext) {
    this.controller = controller
    this.context = context
    this.initPrefs()
  }

  private initPrefs(): void {
    try {
      this.prefs = preferences.getPreferencesSync(this.context, { name: 'dsreplica_store' })
    } catch (err) {
      console.error(`DeepSeekBridge initPrefs failed: ${JSON.stringify(err)}`)
      this.prefs = null
    }
  }

  private readString(key: string): string | null {
    if (this.prefs === null) {
      return null
    }
    try {
      const v = this.prefs.getSync(key, '') as string
      return v === '' ? null : v
    } catch (err) {
      console.error(`DeepSeekBridge read ${key} failed: ${JSON.stringify(err)}`)
      return null
    }
  }

  private writeString(key: string, value: string | null): boolean {
    if (this.prefs === null) {
      return false
    }
    try {
      if (value === null) {
        this.prefs.deleteSync(key)
      } else {
        this.prefs.putSync(key, value)
      }
      this.prefs.flush()
      return true
    } catch (err) {
      console.error(`DeepSeekBridge write ${key} failed: ${JSON.stringify(err)}`)
      return false
    }
  }

  private dispatchEvent(name: string, detail: string): void {
    try {
      this.controller.runJavaScript(
        `window.dispatchEvent(new CustomEvent('${name}', { detail: '${detail}' }))`
      )
    } catch (err) {
      console.error(`DeepSeekBridge dispatch ${name} failed: ${JSON.stringify(err)}`)
    }
  }

  // ===== 环境三件套（值由 EntryAbility 写入 AppStorage） =====

  statusInset(): number {
    return AppStorage.get<number>('statusInset') ?? 0
  }

  buttonNavigationInset(): number {
    return AppStorage.get<number>('buttonNavigationInset') ?? 0
  }

  systemFontScale(): number {
    return AppStorage.get<number>('systemFontScale') ?? 1
  }

  // ===== 键值存储 =====

  readApiKey(): string | null {
    return this.readString('api_key')
  }

  writeApiKey(value: string | null): boolean {
    return this.writeString('api_key', value)
  }

  readChatConfig(): string | null {
    return this.readString('chat_config')
  }

  writeChatConfig(value: string | null): boolean {
    return this.writeString('chat_config', value)
  }

  readAccountProfile(): string | null {
    return this.readString('account_profile')
  }

  writeAccountProfile(value: string | null): boolean {
    return this.writeString('account_profile', value)
  }

  // ===== 自定义接口 SSE 转发（阶段 1 决策：官方 API 直连，返回 null 走 Web 层防护） =====

  beginChatRequest(_endpoint: string, _format: string, _body: string): string | null {
    return null
  }

  cancelChatRequest(_id: string): void {
  }

  // ===== 窗口/主题 =====

  setDarkBars(dark: boolean): void {
    AppStorage.setOrCreate('darkBars', dark)
  }

  setHandlesBack(_handlesBack: boolean): void {
  }

  setBackPreviewEnabled(_enabled: boolean): void {
  }

  setImageViewerFullscreen(_fullscreen: boolean): void {
  }

  setSelectionExclusion(_sL: number, _sT: number, _sR: number, _sB: number,
    _eL: number, _eT: number, _eR: number, _eB: number, _active: boolean): void {
  }

  // ===== 相册（降级：系统选图器走 onShowFileSelector，这里保持空实现） =====

  requestRecentPhotos(): void {
  }

  prefetchRecentPhotos(): void {
  }

  // ===== 历史对话导出（写入公共 Download/DeepSeek Replica/，Web 层展示进度） =====

  private exportFd: number = -1
  private static readonly EXPORT_SUBDIR: string = 'DeepSeek Replica'
  // 沙箱挂载点：<currentUserId> 为数字用户 ID（标准）或 currentUser 别名（PC 形态）
  private static readonly DOWNLOAD_CANDIDATES: string[] =
    ['/storage/Users/100/Download', '/storage/Users/currentUser/Download']

  private pickDownloadDir(): string | null {
    for (const base of DeepSeekBridge.DOWNLOAD_CANDIDATES) {
      try {
        if (fs.accessSync(base).valueOf()) {
          return base
        }
      } catch (err) {
        // 未授权时沙箱未挂载该路径 → 尝试下一个候选
      }
    }
    return null
  }

  private sanitizeExportName(raw: string): string | null {
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

  /** 打开导出文件；返回 'ready' | 'error'。 */
  private openExportFile(rawName: string): string {
    const dir = this.pickDownloadDir()
    if (dir === null) {
      return 'error'
    }
    const name = this.sanitizeExportName(rawName)
    if (name === null) {
      return 'error'
    }
    try {
      const target = `${dir}/${DeepSeekBridge.EXPORT_SUBDIR}`
      if (!fs.accessSync(target).valueOf()) {
        fs.mkdirSync(target, true)
      }
      const file = fs.openSync(`${target}/${name}`,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC)
      this.exportFd = file.fd
      return 'ready'
    } catch (err) {
      console.error(`openExportFile failed: ${JSON.stringify(err)}`)
      return 'error'
    }
  }

  private closeExport(): boolean {
    const fd = this.exportFd
    this.exportFd = -1
    if (fd < 0) {
      return false
    }
    try {
      fs.closeSync(fd)
      return true
    } catch (err) {
      console.error(`closeExport failed: ${JSON.stringify(err)}`)
      return false
    }
  }

  requestHistoryExport(name: string): void {
    // 权限已授予时直接打开；未授权（首启拒绝/未弹）时申请权限后重试
    if (this.openExportFile(name) === 'ready') {
      this.dispatchEvent('android-export', 'ready')
      return
    }
    const atManager = abilityAccessCtrl.createAtManager()
    atManager.requestPermissionsFromUser(this.context,
      ['ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY'])
      .then(() => {
        this.dispatchEvent('android-export', this.openExportFile(name))
      })
      .catch((err: BusinessError) => {
        console.error(`export permission request failed: ${JSON.stringify(err)}`)
        this.dispatchEvent('android-export', 'error')
      })
  }

  writeHistoryExport(bytes: string): boolean {
    if (this.exportFd < 0 || bytes.length > 65536) {
      return false
    }
    try {
      const data = new util.Base64Helper().decodeSync(bytes)
      fs.writeSync(this.exportFd, data.buffer as ArrayBuffer)
      return true
    } catch (err) {
      console.error(`writeHistoryExport failed: ${JSON.stringify(err)}`)
      this.closeExport()
      return false
    }
  }

  finishHistoryExport(): boolean {
    return this.closeExport()
  }

  beginImageSave(_name: string, _mime: string): boolean {
    return false
  }

  writeImageSave(_bytes: string): boolean {
    return false
  }

  finishImageSave(_keep: boolean): boolean {
    return false
  }

  // ===== 录音（阶段 2 实现） =====

  requestRecording(): void {
  }

  finishRecording(_keep: boolean): boolean {
    return false
  }

  recordingLevel(): number {
    return 0
  }

  // ===== 其他 =====

  getMusicVolume(): number {
    return 1
  }

  openSourcePage(url: string, _dark: boolean, _closeLabel: string, _browserLabel: string,
    _loadingLabel: string, _errorLabel: string, _retryLabel: string): void {
    // Android 版为 SourceBrowserActivity（应用内浏览器）；阶段 0 直接交给系统
    // 浏览器打开，dark/close/browser 等标签参数不适用（服务协议/隐私政策/
    // 帮助反馈/开源页/聊天内链接均走此方法）
    try {
      this.context.openLink(url)
    } catch (err) {
      console.error(`openSourcePage openLink failed: ${JSON.stringify(err)}`)
    }
  }

  openAppPermissions(): void {
  }
}
