import { webview } from '@kit.ArkWeb'
import { bundleManager, common } from '@kit.AbilityKit'
import { UIContext } from '@kit.ArkUI'
import { BridgeHost, GallerySaveUiHandler } from '../services/BridgeHost'
import { StorageService } from '../services/StorageService'
import { HistoryExportService } from '../services/HistoryExportService'
import { ImageSaveService } from '../services/ImageSaveService'
import { RecordingService } from '../services/RecordingService'
import { SpeechService } from '../services/SpeechService'

/**
 * DeepSeekAndroid 桥：对齐 Web 层 src/app/android.ts 的 AndroidBridge 契约。
 *
 * 注册名 window.DeepSeekAndroid；methodList 不含 updateStatus/checkForUpdate/installUpdate
 * （自更新废弃，Web 层更新入口为条件渲染，不注册即自动隐藏）。
 *
 * 本类只做「契约 + 转发」：实现按职责拆到 services/ 下的四个模块，
 * 各自持有状态、互不干扰。新增能力时只改对应模块，不必在千行文件里穿行。
 *
 * 注意：javaScriptProxy 只认这一个对象，所有桥方法必须留在本类上，
 * 且方法名与 Index.ets 的 BRIDGE_METHODS 严格一致。
 */
export class DeepSeekBridge extends BridgeHost {
  private readonly storage: StorageService
  private readonly historyExport: HistoryExportService
  private readonly imageSave: ImageSaveService
  private readonly recording: RecordingService
  private readonly speech: SpeechService

  constructor(controller: webview.WebviewController, context: common.UIAbilityContext) {
    super(controller, context)
    this.storage = new StorageService(this)
    this.historyExport = new HistoryExportService(this)
    this.imageSave = new ImageSaveService(this)
    this.recording = new RecordingService(this)
    this.speech = new SpeechService(this)
  }

  override attachUIContext(ctx: UIContext): void {
    super.attachUIContext(ctx)
  }

  /** 由 Index 注入：图片保存需要用户点安全控件时调用的面板 */
  attachGallerySaveUi(handler: GallerySaveUiHandler): void {
    super.attachGallerySaveUi(handler)
  }

  /** 由系统返回（返回键/侧滑）触发；Web 层 App.tsx 的 onBack 负责关闭最上层界面 */
  notifyBack(): void {
    try {
      this.controller.runJavaScript(
        "window.dispatchEvent(new Event('android-back', { cancelable: true }))"
      )
    } catch (err) {
      console.error(`notifyBack failed: ${JSON.stringify(err)}`)
    }
  }

  // ===== 环境三件套（值由 EntryAbility 写入 AppStorage） =====

  /**
   * HarmonyOS 包自身的版本号（AppScope/app.json5 的 versionName）。
   *
   * Web 层「设置 → 版本信息」原先读 index.html 里的 meta，那是上游 Android
   * 工程的版本，在鸿蒙版上会误导当前版本。原生才是权威来源。
   */
  appVersion(): string {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT)
      return `${info.versionName}`
    } catch (err) {
      console.error(`appVersion failed: ${JSON.stringify(err)}`)
      return ''
    }
  }

  statusInset(): number {
    return AppStorage.get<number>('statusInset') ?? 0
  }

  buttonNavigationInset(): number {
    return AppStorage.get<number>('buttonNavigationInset') ?? 0
  }

  systemFontScale(): number {
    return AppStorage.get<number>('systemFontScale') ?? 1
  }

  // ===== 键值存储（转发 StorageService） =====

  readApiKey(): string | null {
    return this.storage.readApiKey()
  }

  writeApiKey(value: string | null): boolean {
    return this.storage.writeApiKey(value)
  }

  readChatConfig(): string | null {
    return this.storage.readChatConfig()
  }

  writeChatConfig(value: string | null): boolean {
    return this.storage.writeChatConfig(value)
  }

  readAccountProfile(): string | null {
    return this.storage.readAccountProfile()
  }

  writeAccountProfile(value: string | null): boolean {
    return this.storage.writeAccountProfile(value)
  }

  // ===== 自定义接口 SSE 转发（官方 API 直连，返回 null 走 Web 层防护） =====

  beginChatRequest(_endpoint: string, _format: string, _body: string): string | null {
    return null
  }

  cancelChatRequest(_id: string): void {
  }

  // ===== 窗口/主题 =====

  setDarkBars(dark: boolean): void {
    AppStorage.setOrCreate('darkBars', dark)
  }

  setHandlesBack(handlesBack: boolean): void {
    // Web 层计数器：有可关闭的界面层（抽屉/对话框/面板）时登记 true，
    // Index.onBackPress 据此拦截系统返回并派发 android-back 给 Web 消费
    AppStorage.setOrCreate('dsHandlesBack', handlesBack)
  }

  setBackPreviewEnabled(_enabled: boolean): void {
  }

  setImageViewerFullscreen(_fullscreen: boolean): void {
  }

  setSelectionExclusion(_sL: number, _sT: number, _sR: number, _sB: number,
    _eL: number, _eT: number, _eR: number, _eB: number, _active: boolean): void {
  }

  // ===== 选择器意图（Index.onShowFileSelector 消费） =====

  /**
   * Web 层点击「拍照/相册/文件」三个 input 前同步调用，显式声明意图。
   * 为什么不靠 accept 判断：ArkWeb 的 getAcceptType()/getMimeTypes() 在不同
   * 内核版本下返回值不一致（实测 getMimeTypes 对 image 通配返回全通配），
   * 两次导致路由错乱。显式标记是唯一确定可靠的信号。
   */
  private pickerKind: string = ''

  setPickerKind(kind: string): void {
    this.pickerKind = kind
  }

  /** 取出并清空（每次点击只消费一次，避免影响后续意图不明的选择）。 */
  consumePickerKind(): string {
    const kind = this.pickerKind
    this.pickerKind = ''
    return kind
  }

  // 应用内最近照片网格未适配（选择器直接走系统图库）
  requestRecentPhotos(): void {
  }

  prefetchRecentPhotos(): void {
  }

  // ===== 历史对话导出（转发 HistoryExportService） =====

  requestHistoryExport(name: string): void {
    this.historyExport.requestHistoryExport(name)
  }

  writeHistoryExport(bytes: string): boolean {
    return this.historyExport.writeHistoryExport(bytes)
  }

  finishHistoryExport(): boolean {
    return this.historyExport.finishHistoryExport()
  }

  // ===== 图片保存（转发 ImageSaveService） =====

  beginImageSave(name: string, mime: string): boolean {
    return this.imageSave.beginImageSave(name, mime)
  }

  writeImageSave(bytes: string): boolean {
    return this.imageSave.writeImageSave(bytes)
  }

  finishImageSave(keep: boolean): boolean {
    return this.imageSave.finishImageSave(keep)
  }

  /**
   * 安全控件拿到临时授权后由 Index 页面回调（非 Web 桥方法，不进 BRIDGE_METHODS）。
   * authorized=false 表示用户在面板上取消，或授权失败。
   */
  commitGallerySave(title: string, path: string, authorized: boolean): void {
    this.imageSave.commitSafeButtonSave(title, path, authorized)
  }

  // ===== 录音（转发 RecordingService） =====

  requestRecording(): void {
    this.recording.requestRecording()
  }

  finishRecording(keep: boolean): boolean {
    return this.recording.finishRecording(keep)
  }

  recordingLevel(): number {
    return this.recording.recordingLevel()
  }

  recordingSize(): number {
    return this.recording.recordingSize()
  }

  readRecordingChunk(offset: number, length: number): string {
    return this.recording.readRecordingChunk(offset, length)
  }

  // ===== 系统语音能力（转发 SpeechService） =====

  /** 本地 TTS 播报；返回 false 表示设备无本地合成引擎，Web 层据此回落官方 API */
  localTtsSpeak(text: string, rate: number): boolean {
    return this.speech.localTtsSpeak(text, rate)
  }

  localTtsStop(): void {
    this.speech.localTtsStop()
  }

  localAsrAvailable(): boolean {
    return this.speech.localAsrAvailable()
  }

  /** 开始端侧识别（引擎自采麦克风）；false = 设备无端侧引擎 */
  localAsrStart(): boolean {
    return this.speech.localAsrStart()
  }

  /** 结束采集，等引擎给出最终文本（经 android-local-asr 的 end: 事件回传） */
  localAsrStop(): void {
    this.speech.localAsrStop()
  }

  /** 放弃本次识别，不派发结果 */
  localAsrCancel(): void {
    this.speech.localAsrCancel()
  }

  /** 页面销毁时释放语音引擎 */
  releaseSpeech(): void {
    this.speech.release()
  }

  // ===== 其他 =====

  getMusicVolume(): number {
    return 1
  }

  openSourcePage(url: string, _dark: boolean, _closeLabel: string, _browserLabel: string,
    _loadingLabel: string, _errorLabel: string, _retryLabel: string): void {
    // Android 版为 SourceBrowserActivity（应用内浏览器）；这里直接交给系统浏览器
    try {
      this.context.openLink(url)
    } catch (err) {
      console.error(`openSourcePage openLink failed: ${JSON.stringify(err)}`)
    }
  }

  openAppPermissions(): void {
  }
}
