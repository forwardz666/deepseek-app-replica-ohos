import { preferences } from '@kit.ArkData'
import { webview } from '@kit.ArkWeb'
import { abilityAccessCtrl, common } from '@kit.AbilityKit'
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit'
import { util } from '@kit.ArkTS'
import { fileIo as fs, fileUri, Environment, picker } from '@kit.CoreFileKit'
import { photoAccessHelper } from '@kit.MediaLibraryKit'
import { promptAction, UIContext } from '@kit.ArkUI'
import { i18n } from '@kit.LocalizationKit'

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

  // ===== 相册（降级：系统选图器走 onShowFileSelector，这里保持空实现） =====

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
    // 优先官方 API（自动适配手机/平板/PC 的用户目录）
    try {
      const dir = Environment.getUserDownloadDir()
      if (dir !== '' && fs.accessSync(dir)) {
        return dir
      }
    } catch (err) {
      // 无权限或未挂载 → 退回候选路径探测
    }
    for (const base of DeepSeekBridge.DOWNLOAD_CANDIDATES) {
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
      // accessSync 对不存在路径抛异常，直接用确保目录的辅助方法
      if (!this.ensureDir(target)) {
        return 'error'
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

  // ===== 图片保存（写入沙箱临时文件，finish 后经系统弹窗存入系统相册） =====

  private imageFd: number = -1
  private imagePath: string | null = null
  private imageTitle: string | null = null
  private static readonly IMAGE_SAVES_DIR: string = 'saves'
  /** 文件名里算作图片的扩展名（含 jpeg/常见派生存法） */
  private static readonly IMAGE_NAME_EXTS: string[] =
    ['jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp', 'heic', 'heif', 'avif']
  // PC（2in1）无系统图库入口，沿用写入下载目录
  private static readonly IMAGE_PC_SUBDIR: string = 'DeepSeek Replica/Images'

  private extForMime(type: string): string {
    if (type === 'image/png') {
      return 'png'
    }
    if (type === 'image/webp') {
      return 'webp'
    }
    if (type === 'image/gif') {
      return 'gif'
    }
    if (type === 'image/jpeg' || type === 'image/jpg') {
      return 'jpg'
    }
    if (type === 'image/bmp' || type === 'image/x-ms-bmp') {
      return 'bmp'
    }
    if (type === 'image/heic' || type === 'image/heif') {
      return 'heic'
    }
    if (type === 'image/avif') {
      return 'avif'
    }
    return ''
  }

  /**
   * 推断图片扩展名，**永不返回空**。
   *
   * 为什么必须兜底：Web 层传入的 mime 来自 Blob.type，而 Blob 经 IndexedDB
   * 往返后 type 可能丢失（空串）；文件名也可能是「图片_20241121」这种无扩展名
   * 形式。旧实现在这两种情况下直接 return false —— Web 层立刻抛错，
   * 用户看到的就是「点保存马上弹无法保存」，根本没机会拉起系统界面。
   */
  private resolveImageExt(name: string, mime: string): string {
    // mime 可能带 charset 等参数，取分号前的部分
    const cleanMime = mime.toLowerCase().split(';')[0].trim()
    const byMime = this.extForMime(cleanMime)
    if (byMime !== '') {
      return byMime
    }
    const dot = name.lastIndexOf('.')
    if (dot > 0) {
      const e = name.substring(dot + 1).toLowerCase()
      if (DeepSeekBridge.IMAGE_NAME_EXTS.includes(e)) {
        return e === 'jpeg' ? 'jpg' : e
      }
    }
    // 最终兜底：按 jpeg 处理（相册侧按魔数识别，扩展名不匹配也能显示）
    return 'jpg'
  }

  /**
   * 跟随系统语言的轻提示（Web 层 i18n 不可达 native，按系统语言二选一）。
   *
   * 必须全程 try/catch：全局 promptAction.showToast 在 API 18 起已废弃，
   * 某些版本由非 UI 线程调用会直接抛异常。这个异常若是从 finishImageSave
   * 里冒出去，就会顺着 javaScriptProxy 抛回 Web —— Web 侧立刻显示
   * 「无法保存图片」，而系统弹窗还没机会出现。这正是「点保存马上报错、
   * 也不出保存菜单」的成因，所以提示失败绝不允许影响主流程。
   */
  private toast(msgZh: string, msgEn: string): void {
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

  /** 由 Index 在页面出现时注入，供 toast 走推荐的 UIContext 通道。 */
  private uiContext: UIContext | null = null

  attachUIContext(ctx: UIContext): void {
    this.uiContext = ctx
  }

  /**
   * 确保目录存在。注意：fs.accessSync 对不存在的路径会**抛出 13900002**
   * 而不是返回 false（文档 invalid），因此不能用返回值判断，必须 try/catch。
   */
  private ensureDir(dir: string): boolean {
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

  /**
   * 建立沙箱临时文件，等待 Web 分块写入。
   *
   * 旧实现在 name 无扩展名 / mime 不在白名单时直接 return false，Web 层立刻
   * 提示「无法保存图片」—— 用户看不到任何系统界面，这就是「点了没有作用」。
   * 现在扩展名一律兜底推断，只有「建目录/建文件确实失败」才返回 false。
   */
  beginImageSave(name: string, mime: string): boolean {
    const safeName = (name || '').replace(/[/\\]+/g, '_').trim()
    const ext = this.resolveImageExt(safeName, mime || '')
    // 去掉已有扩展名后作为资产名（相册展示名不带时间戳）
    const dot = safeName.lastIndexOf('.')
    let stem = dot > 0 ? safeName.substring(0, dot) : safeName
    if (stem === '' || stem === '.' || stem === '..') {
      stem = `image_${Date.now()}`
    }
    const cleanTitle = `${stem}.${ext}`
    const tempName = `${stem}_${Date.now()}.${ext}`
    const sanitized = this.sanitizeExportName(tempName)
    if (sanitized === null) {
      console.error(`beginImageSave: sanitize failed for "${tempName}"`)
      return false
    }
    try {
      const dir = `${this.context.cacheDir}/${DeepSeekBridge.IMAGE_SAVES_DIR}`
      if (!this.ensureDir(dir)) {
        return false
      }
      const file = fs.openSync(`${dir}/${sanitized}`,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC)
      this.imageFd = file.fd
      this.imagePath = `${dir}/${sanitized}`
      this.imageTitle = cleanTitle
      return true
    } catch (err) {
      console.error(`beginImageSave failed: ${JSON.stringify(err)}`)
      return false
    }
  }

  writeImageSave(bytes: string): boolean {
    if (this.imageFd < 0 || bytes.length > 65536) {
      return false
    }
    try {
      const data = new util.Base64Helper().decodeSync(bytes)
      fs.writeSync(this.imageFd, data.buffer as ArrayBuffer)
      return true
    } catch (err) {
      console.error(`writeImageSave failed: ${JSON.stringify(err)}`)
      this.finishImageSave(false)
      return false
    }
  }

  /** 读文件头魔数，返回真实图片扩展名（永远返回非空值）。 */
  private sniffImageExt(path: string): string {
    try {
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY)
      const buf = new ArrayBuffer(16)
      const read = fs.readSync(file.fd, buf, { offset: 0, length: 16 })
      fs.closeSync(file.fd)
      if (read < 4) {
        return 'jpg'
      }
      const b = new Uint8Array(buf)
      if (b[0] === 0xFF && b[1] === 0xD8) {
        return 'jpg'
      }
      if (b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4E) {
        return 'png'
      }
      if (b[0] === 0x47 && b[1] === 0x49 && b[2] === 0x46) {
        return 'gif'
      }
      if (b[0] === 0x42 && b[1] === 0x4D) {
        return 'bmp'
      }
      if (b[0] === 0x52 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x46) {
        return 'webp'
      }
      if (b[4] === 0x66 && b[5] === 0x74 && b[6] === 0x79 && b[7] === 0x70) {
        return 'heic'
      }
      return 'jpg'
    } catch (err) {
      console.error(`sniffImageExt failed: ${JSON.stringify(err)}`)
      return 'jpg'
    }
  }

  finishImageSave(keep: boolean): boolean {
    // 整个方法绝不允许向 Web 抛异常：桥方法一旦抛错，Web 层会立刻显示
    // 「无法保存图片」，而系统确认框还没来得及出现 —— 用户看到的就是
    // 「点保存马上报错，也没弹出保存菜单」。
    try {
      return this.finishImageSaveGuarded(keep)
    } catch (err) {
      console.error(`finishImageSave crashed: ${JSON.stringify(err)}`)
      return false
    }
  }

  private finishImageSaveGuarded(keep: boolean): boolean {
    const fd = this.imageFd
    let path = this.imagePath
    let title = this.imageTitle
    this.imageFd = -1
    this.imagePath = null
    this.imageTitle = null
    if (fd < 0) {
      return false
    }
    try {
      fs.closeSync(fd)
    } catch (err) {
      console.error(`closeImageSave failed: ${JSON.stringify(err)}`)
      return false
    }
    if (!keep || path === null || title === null) {
      this.removeTempImage(path)
      return false
    }
    // 空文件说明 Web 侧一个字节都没写进来（分块失败/Blob 读取失败），
    // 这种文件进相册只会在图库里留一张坏图，提前拦掉并明确告知。
    let size = 0
    try {
      size = fs.statSync(path).size
    } catch (err) {
      console.error(`stat image failed: ${JSON.stringify(err)}`)
    }
    if (size <= 0) {
      this.toast('保存失败：图片数据为空', 'Failed: empty image data')
      this.dispatchEvent('android-image-saved', 'error:empty')
      this.removeTempImage(path)
      return true
    }
    // Web 层给的 mime/文件名可能丢失或不准（Blob 经 IndexedDB 往返会掉 type），
    // 这里按字节魔数纠正扩展名，否则媒体库会因「扩展名与实际内容不符」拒绝创建。
    const realExt = this.sniffImageExt(path)
    const slash = path.lastIndexOf('/')
    const dot = path.lastIndexOf('.')
    if (dot > slash) {
      const fixed = `${path.substring(0, dot)}.${realExt}`
      if (fixed !== path) {
        try {
          fs.renameSync(path, fixed)
          path = fixed
        } catch (err) {
          console.error(`rename to real ext failed: ${JSON.stringify(err)}`)
        }
      }
    }
    const tDot = title.lastIndexOf('.')
    if (tDot > 0) {
      title = `${title.substring(0, tDot)}.${realExt}`
    }
    // 全平台统一优先存进系统图库（用户明确要求：不要图库和下载两条不一致的路径）。
    // 图库通道确实不可用时（如部分 PC 形态没有媒体库服务），2in1 再退回下载目录，
    // 其余设备报明确错误 —— 绝不再静默写到一个用户看不见的地方。
    this.saveToGallery(title, path, deviceInfo.deviceType === '2in1')
    return true
  }

  /**
   * PC 专用：写入 下载/DeepSeek Replica/Images。
   * 仅在图库三条通道都不可用时作为 2in1 的最后退路，确保用户一定能找到文件。
   */
  private saveToDownloadForPc(title: string, path: string): void {
    const dir = this.pickDownloadDir()
    if (dir === null) {
      this.toast('保存失败：无法访问下载目录', 'Failed: no download dir')
      this.dispatchEvent('android-image-saved', 'error:download')
      this.removeTempImage(path)
      return
    }
    const target = `${dir}/${DeepSeekBridge.IMAGE_PC_SUBDIR}`
    if (!this.ensureDir(target)) {
      this.toast('保存失败：无法创建目录', 'Failed: cannot create dir')
      this.dispatchEvent('android-image-saved', 'error:download')
      this.removeTempImage(path)
      return
    }
    try {
      fs.copyFileSync(path, `${target}/${title}`)
      this.toast('已保存到「下载/DeepSeek Replica/Images」', 'Saved to Downloads')
      this.dispatchEvent('android-image-saved', 'ok')
      this.removeTempImage(path)
    } catch (err) {
      console.error(`saveToDownloadForPc failed: ${JSON.stringify(err)}`)
      this.toast('保存失败', 'Failed to save')
      this.dispatchEvent('android-image-saved', 'error:download')
      this.removeTempImage(path)
    }
  }

  private removeTempImage(path: string | null): void {
    if (path === null) {
      return
    }
    try {
      fs.unlinkSync(path)
    } catch (err) {
      // 清理失败不影响主流程
    }
  }

  /**
   * 把沙箱里的图片存进系统相册。
   *
   * 为什么把「系统保存页」放第一条：showAssetsCreationDialog 有隐式的
   * 「必须由用户在原生组件上点击触发」限制，从 ArkWeb 的 JS 桥回调里调用时
   * 系统会静默返回空数组（既不弹窗也不报错）—— 这正是用户看到的
   * 「无法引出系统的图片保存菜单」。而 picker 的保存页是独立的系统 Ability，
   * 从 UIAbility 上下文就能拉起，不受该限制。
   *
   * 通道顺序：
   * 1. picker.PhotoViewPicker.save —— 系统「保存到图片」页（用户可见、可确认）
   * 2. showAssetsCreationDialog —— 直接弹「保存到相册」确认框
   * 3. MediaAssetChangeRequest.applyChanges —— 免弹窗直写（多数机型 201）
   * 4. 2in1 退回下载目录；其余设备明确报错
   */
  private saveToGallery(title: string, path: string, allowDownloadFallback: boolean): void {
    this.toast('正在保存到相册…', 'Saving to gallery…')
    this.saveViaPickerPage(title, path, allowDownloadFallback)
  }

  /**
   * 通道 1：系统「保存到图片」页（picker.PhotoViewPicker.save）。
   *
   * 必须用带 context 的构造函数 —— 无参构造是 @deprecated 的「可能失败」用法，
   * 在部分版本上直接抛异常，界面就完全出不来。
   */
  private saveViaPickerPage(title: string, path: string, allowDownloadFallback: boolean): void {
    const self = this
    let photoPicker: picker.PhotoViewPicker
    try {
      photoPicker = new picker.PhotoViewPicker(this.context)
    } catch (err) {
      console.error(`PhotoViewPicker unavailable: ${JSON.stringify(err)}`)
      this.saveViaCreationDialog(title, path, allowDownloadFallback)
      return
    }
    const options: picker.PhotoSaveOptions = { newFileNames: [title] }
    try {
      photoPicker.save(options).then((uris: Array<string>) => {
        if (uris.length === 0) {
          // 系统保存页返回空 = 用户主动取消，不算失败，不提示错误。
          self.toast('已取消保存', 'Save cancelled')
          self.dispatchEvent('android-image-saved', 'cancel')
          self.removeTempImage(path)
          return
        }
        if (self.copyIntoUri(path, uris[0])) {
          self.toast('已保存到相册', 'Saved to photos')
          self.dispatchEvent('android-image-saved', 'ok')
          self.removeTempImage(path)
        } else {
          self.toast('保存失败：写入相册出错', 'Failed: cannot write to gallery')
          self.dispatchEvent('android-image-saved', 'error:write')
        }
      }).catch((err: BusinessError) => {
        console.error(`PhotoViewPicker.save failed: ${JSON.stringify(err)}`)
        // 保存页拉不起来 → 试直接弹确认框
        self.saveViaCreationDialog(title, path, allowDownloadFallback)
      })
    } catch (err) {
      console.error(`PhotoViewPicker.save threw: ${JSON.stringify(err)}`)
      this.saveViaCreationDialog(title, path, allowDownloadFallback)
    }
  }

  /** 把沙箱文件分块写入 picker 返回的可写 uri。 */
  private copyIntoUri(srcPath: string, dstUri: string): boolean {
    let srcFd = -1
    let dstFd = -1
    try {
      srcFd = fs.openSync(srcPath, fs.OpenMode.READ_ONLY).fd
      dstFd = fs.openSync(dstUri, fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC).fd
      const buf = new ArrayBuffer(64 * 1024)
      let read = fs.readSync(srcFd, buf)
      while (read > 0) {
        fs.writeSync(dstFd, buf.slice(0, read))
        read = fs.readSync(srcFd, buf)
      }
      fs.fsyncSync(dstFd)
      return true
    } catch (err) {
      console.error(`copyIntoUri failed: ${JSON.stringify(err)}`)
      return false
    } finally {
      if (srcFd >= 0) {
        try {
          fs.closeSync(srcFd)
        } catch (err) {
          // 忽略
        }
      }
      if (dstFd >= 0) {
        try {
          fs.closeSync(dstFd)
        } catch (err) {
          // 忽略
        }
      }
    }
  }

  /**
   * 通道 2：showAssetsCreationDialog 直接弹「保存到相册」确认框。
   * PhotoCreationConfig.title 必须是**不含扩展名**的资产名，扩展名单独经
   * fileNameExtension 提供。传 'a.png' + 'png' 会让系统创建资产失败。
   */
  private saveViaCreationDialog(title: string, path: string, allowDownloadFallback: boolean): void {
    const self = this
    const dot = title.lastIndexOf('.')
    const baseName = dot > 0 ? title.substring(0, dot) : title
    const ext = dot > 0 ? title.substring(dot + 1).toLowerCase() : 'jpg'
    let helper: photoAccessHelper.PhotoAccessHelper | null = null
    let srcUri = ''
    try {
      helper = photoAccessHelper.getPhotoAccessHelper(this.context)
      srcUri = fileUri.getUriFromPath(path)
    } catch (err) {
      console.error(`saveViaCreationDialog prep failed: ${JSON.stringify(err)}`)
    }
    if (helper === null || srcUri === '') {
      this.saveViaChangeRequest(title, path, allowDownloadFallback)
      return
    }
    const config: photoAccessHelper.PhotoCreationConfig = {
      title: baseName,
      fileNameExtension: ext,
      photoType: photoAccessHelper.PhotoType.IMAGE,
      subtype: photoAccessHelper.PhotoSubtype.DEFAULT
    }
    // 桥方法由 ArkWeb 的 JS 线程同步调用，直接拉起系统弹窗会被静默丢弃，
    // 用 setTimeout 切到下一轮事件循环再弹。
    setTimeout(() => {
      const h = helper
      if (h === null) {
        self.saveViaChangeRequest(title, path, allowDownloadFallback)
        return
      }
      try {
        h.showAssetsCreationDialog([srcUri], [config]).then((uris: Array<string>) => {
          console.info(`showAssetsCreationDialog result: ${JSON.stringify(uris)}`)
          if (uris.length > 0) {
            self.toast('已保存到相册', 'Saved to photos')
            self.dispatchEvent('android-image-saved', 'ok')
            self.removeTempImage(path)
            return
          }
          // 空数组：无 UI 服务或用户取消。继续往下试免弹窗直写。
          console.warn('showAssetsCreationDialog returned empty, trying direct create')
          self.saveViaChangeRequest(title, path, allowDownloadFallback)
        }).catch((err: BusinessError) => {
          console.error(`showAssetsCreationDialog failed: ${JSON.stringify(err)}`)
          self.saveViaChangeRequest(title, path, allowDownloadFallback)
        })
      } catch (err) {
        console.error(`showAssetsCreationDialog threw: ${JSON.stringify(err)}`)
        self.saveViaChangeRequest(title, path, allowDownloadFallback)
      }
    }, 0)
  }

  /**
   * 通道 3：createImageAssetRequest + applyChanges。
   * 需要 WRITE_IMAGEVIDEO，普通应用通常拿不到（201），但成本极低，留作兜底。
   */
  private saveViaChangeRequest(title: string, path: string, allowDownloadFallback: boolean): void {
    const self = this
    const dot = title.lastIndexOf('.')
    const baseName = dot > 0 ? title.substring(0, dot) : title
    try {
      const helper = photoAccessHelper.getPhotoAccessHelper(this.context)
      const srcUri = fileUri.getUriFromPath(path)
      const request = photoAccessHelper.MediaAssetChangeRequest.createImageAssetRequest(
        this.context, srcUri)
      request.setTitle(baseName)
      helper.applyChanges(request).then(() => {
        console.info('applyChanges ok')
        self.toast('已保存到相册', 'Saved to photos')
        self.dispatchEvent('android-image-saved', 'ok')
        self.removeTempImage(path)
      }).catch((err: BusinessError) => {
        console.error(`applyChanges failed: ${JSON.stringify(err)}`)
        self.galleryUnavailable(title, path, allowDownloadFallback, err.code)
      })
    } catch (err) {
      console.error(`createImageAssetRequest failed: ${JSON.stringify(err)}`)
      this.galleryUnavailable(title, path, allowDownloadFallback, (err as BusinessError).code)
    }
  }

  /** 三条图库通道都不可用：2in1 退回下载目录（用户可见），其余明确报错。 */
  private galleryUnavailable(title: string, path: string, allowDownloadFallback: boolean,
    code?: number): void {
    if (allowDownloadFallback) {
      this.saveToDownloadForPc(title, path)
      return
    }
    const suffix = code === undefined ? '' : `（${code}）`
    const suffixEn = code === undefined ? '' : ` (${code})`
    this.toast(`保存失败：相册不可用${suffix}`, `Gallery unavailable${suffixEn}`)
    this.dispatchEvent('android-image-saved', code === undefined ? 'error' : `error:${code}`)
    this.removeTempImage(path)
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
