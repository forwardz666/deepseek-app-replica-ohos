import { webview } from '@kit.ArkWeb'
import { common } from '@kit.AbilityKit'
import { fileIo as fs, picker } from '@kit.CoreFileKit'
import { photoAccessHelper } from '@kit.MediaLibraryKit'
import { camera, cameraPicker } from '@kit.CameraKit'
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit'
import { DeepSeekBridge } from '../bridge/DeepSeekBridge'

/**
 * Web 宿主页：加载 rawfile 内打包的 React 应用，注入 window.DeepSeekAndroid 桥。
 * 本地资源经 onInterceptRequest 从 rawfile 读取并附加 CSP（逐字复刻 Android 版
 * MainActivity.java:235-239 的安全策略）；外部请求（api.deepseek.com 等）放行。
 */

// 阶段 0 暂不注入 CSP：resource:// scheme 可能被赋予 opaque origin，'self' 会全拦。
// TODO 阶段 1：日志确认 origin 语义后按 Android 版 CSP（MainActivity.java:238-240）恢复。
const RAW_PREFIX = 'resource://rawfile/'

// accept 以扩展名形式给出时的图片后缀白名单（判断是否走相册）
const IMAGE_EXTS: string[] = ['jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp', 'heic', 'heif', 'avif']

// 手机 ArkWeb 的宽度类媒体查询按物理像素（而非 CSS vp）求值：布局宽度正确
// （innerWidth ≈ 视口 vp），但 matchMedia/@media 断点被放大 dpr 倍比较，导致
// 上游 Web 的 `min-width: 768px` 等桌面断点在手机（物理宽 1200+）全部误命中，
// 呈现平板双栏布局。修复：注入脚本先探测矛盾（断点求值结果与 innerWidth 推导
// 不一致），确认后把 CSSOM 中所有宽度断点 × devicePixelRatio 重写——在物理
// 求值的内核里等价于按 vp 求值（vp×d 与 bp×d 比较同 vp 与 bp 比较），数学上
// 设备无关；求值正常的内核（平板表现一致）探测不通过，不触碰样式。
const MQ_FIX_SCRIPT: string = `(function () {
  if (window.__DS_MQ_FIX__) return
  window.__DS_MQ_FIX__ = true
  function probeBroken() {
    var w = window.innerWidth
    var probes = [
      ['(min-width: 768px)', w >= 768],
      ['(max-width: 1023px)', w <= 1023],
      ['(max-width: 439px)', w <= 439],
      ['(min-width: 459.6px)', w >= 459.6]
    ]
    for (var i = 0; i < probes.length; i++) {
      if (window.matchMedia(probes[i][0]).matches !== probes[i][1]) return true
    }
    return false
  }
  function scale(text) {
    var d = window.devicePixelRatio || 1
    return text.replace(/(min-width|max-width):\\s*([\\d.]+)px/g, function (m, p, v) {
      return p + ': ' + Math.round(parseFloat(v) * d * 100) / 100 + 'px'
    })
  }
  function fix() {
    try {
      if (!probeBroken()) return
      var changed = 0
      for (var s = 0; s < document.styleSheets.length; s++) {
        var rules
        try { rules = document.styleSheets[s].cssRules } catch (e) { continue }
        for (var j = 0; j < rules.length; j++) {
          var r = rules[j]
          if (!r.media) continue
          var mt = r.media.mediaText || ''
          if (/(min-width|max-width):/.test(mt)) {
            var nt = scale(mt)
            if (nt !== mt) {
              try { r.media.mediaText = nt; changed++ } catch (e) {}
            }
          }
        }
      }
      if (changed > 0) console.info('[DS] media breakpoints scaled by dpr: ' + changed)
    } catch (e) {}
  }
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', fix)
    window.addEventListener('load', fix)
  } else {
    fix()
  }
})()`

// 对齐 Web 层 AndroidBridge 的全部桥方法（不含已废弃的 update 三个）
const BRIDGE_METHODS: string[] = [
  'appVersion',
  'statusInset', 'buttonNavigationInset', 'systemFontScale',
  'openAppPermissions', 'getMusicVolume', 'openSourcePage',
  'readApiKey', 'writeApiKey', 'readChatConfig', 'writeChatConfig',
  'beginChatRequest', 'cancelChatRequest',
  'readAccountProfile', 'writeAccountProfile',
  'setDarkBars', 'setHandlesBack', 'setBackPreviewEnabled',
  'setPickerKind',
  'setImageViewerFullscreen', 'requestRecentPhotos', 'prefetchRecentPhotos',
  'requestHistoryExport', 'writeHistoryExport', 'finishHistoryExport',
  'beginImageSave', 'writeImageSave', 'finishImageSave',
  'requestRecording', 'finishRecording', 'recordingLevel',
  'recordingSize', 'readRecordingChunk',
  'localTtsSpeak', 'localTtsStop', 'localAsrAvailable',
  'localAsrStart', 'localAsrStop', 'localAsrCancel',
  'setSelectionExclusion'
]

function mimeFor(path: string): string {
  const name = path.toLowerCase()
  if (name.endsWith('.js') || name.endsWith('.mjs') || name.endsWith('.cjs')) {
    return 'text/javascript'
  }
  if (name.endsWith('.css')) {
    return 'text/css'
  }
  if (name.endsWith('.html')) {
    return 'text/html'
  }
  if (name.endsWith('.svg')) {
    return 'image/svg+xml'
  }
  if (name.endsWith('.png')) {
    return 'image/png'
  }
  if (name.endsWith('.jpg') || name.endsWith('.jpeg')) {
    return 'image/jpeg'
  }
  if (name.endsWith('.webp')) {
    return 'image/webp'
  }
  if (name.endsWith('.ico')) {
    return 'image/x-icon'
  }
  if (name.endsWith('.woff2')) {
    return 'font/woff2'
  }
  if (name.endsWith('.woff')) {
    return 'font/woff'
  }
  if (name.endsWith('.ttf')) {
    return 'font/ttf'
  }
  if (name.endsWith('.json')) {
    return 'application/json'
  }
  if (name.endsWith('.wasm')) {
    return 'application/wasm'
  }
  if (name.endsWith('.wav')) {
    return 'audio/wav'
  }
  return 'application/octet-stream'
}

@Entry
@Component
struct Index {
  @State diag: string = 'v10 booting'
  @State diag2: string = ''
  @State diag3: string = ''
  @State diagErr: boolean = false
  /**
   * 空串表示「还没确定要加载的页面」——此时不创建 Web 组件。
   * 之前初始值是 'about:blank'，Web 会先绘制一张白页再被替换，
   * 深色模式下这就是启动图（黑）结束后那一下白闪的来源。
   */
  @State webSrc: string = ''
  /**
   * Web 内容首帧绘制完成前保持透明：ArkWeb 的合成层在拿到第一帧之前会
   * 先呈现一块默认白底，这层白就是深色模式下启动图之后的残影。
   * 透明期间露出的是父容器的主题色（深色 #151517），因此全程无缝。
   */
  @State webPainted: boolean = false
  /** 相册保存授权面板：非空表示正在等待用户点安全控件 */
  @State gallerySavePath: string = ''
  @State gallerySaveTitle: string = ''
  controller: webview.WebviewController = new webview.WebviewController()
  private bridge: DeepSeekBridge =
    new DeepSeekBridge(this.controller, getContext(this) as common.UIAbilityContext)
  private resourceDir: string = ''

  aboutToAppear(): void {
    // toast 从 API 18 起推荐走 UIContext.getPromptAction()，全局 promptAction
    // 在非 UI 线程上会抛异常。桥接层与此页面同生命周期，提前注入。
    try {
      this.bridge.attachUIContext(this.getUIContext())
    } catch (err) {
      console.warn(`attachUIContext failed: ${JSON.stringify(err)}`)
    }
    // 图片保存需要用户点安全控件授权，桥接层通过这个回调把请求转给本页面
    try {
      this.bridge.attachGallerySaveUi((title: string, path: string): boolean => {
        this.gallerySaveTitle = title
        this.gallerySavePath = path
        return true
      })
    } catch (err) {
      console.warn(`attachGallerySaveUi failed: ${JSON.stringify(err)}`)
    }
    // v9：改用 resfile 方案（官方 electron.hap 验证可行）：dist 放
    // resources/resfile/web/，安装时解包为真实文件，运行时直接 file:// 加载，
    // 彻底绕开 resource manager（v8 实证其对本 HAP 全瘫：media 9001001 / rawfile
    // 9001005；根因是官方 index 用 STORED 而 mmap 解析，我们的 DEFLATED 失败）。
    const ctx = getContext(this) as common.UIAbilityContext
    const parts: string[] = []
    parts.push(`rdir:${ctx.resourceDir !== '' ? 'set' : 'empty'}`)
    const htmlPath = `${ctx.resourceDir}/web/index.html`
    parts.push(fs.accessSync(htmlPath).valueOf() ? 'html:yes' : 'html:no')
    try {
      const st = fs.statSync(htmlPath)
      parts.push(`sz:${st.size}`)
    } catch (err) {
      parts.push(`sz:${(err as BusinessError).code}`)
    }
    this.resourceDir = ctx.resourceDir
    this.diag = parts.join(' ')
    this.diag3 = ctx.resourceDir.substring(0, 110)
    if (parts.includes('html:yes')) {
      // v10：声明式加载（@State 驱动 Web src），消除 onControllerAttached
      // 里 loadUrl 被初始 src 竞争静默忽略的问题（v9 实证）
      this.webSrc = `file://${ctx.resourceDir}/web/index.html`
      this.diag = `${this.diag} | src set`
    } else {
      this.diagErr = true
    }
  }

  aboutToDisappear(): void {
    // 语音引擎（本地 TTS / 离线识别）是重资源，页面销毁时必须释放
    try {
      this.bridge.releaseSpeech()
    } catch (err) {
      console.warn(`releaseSpeech failed: ${JSON.stringify(err)}`)
    }
  }

  onBackPress(): boolean {
    // Web 层 android-back 协议：Web 通过 setHandlesBack 登记是否有可关闭的
    // 界面层（抽屉/对话框/面板）。有 → 派发 android-back 由 Web 关闭最上层；
    // 无 → 交给系统（退出应用）。侧滑手势与返回键同样走本回调。
    if (AppStorage.get<boolean>('dsHandlesBack') === true) {
      this.bridge.notifyBack()
      return true
    }
    return false
  }

  /** 页面加载后探测：主文档 URL/类型/DOM 内容、桥、React root、script 列表。 */
  private probe(tag: string): void {
    const script = "JSON.stringify({" +
      "h:location.href," +
      "ct:document.contentType||'-'," +
      "d:(document.documentElement?document.documentElement.outerHTML.substring(0,150):'NOHTML')," +
      "b:typeof window.DeepSeekAndroid," +
      "r:(document.getElementById('root')||{childElementCount:-2}).childElementCount," +
      "sc:Array.prototype.map.call(document.scripts,function(s){return s.src?s.src.substring(s.src.lastIndexOf('/')+1):'inline'}).join(';')" +
      "})"
    try {
      this.controller.runJavaScript(script, (_err: object, result: string) => {
        if (result && result.length > 0) {
          this.diag2 = `${tag} ${result}`.substring(0, 280)
        }
      })
    } catch (err) {
      this.diag2 = `probe fail ${JSON.stringify(err)}`.substring(0, 280)
    }
  }

  build() {
    Stack() {
      Column() {
        // 只在确定 URL 后才创建 Web：避免 about:blank 先画一帧白底
        if (this.webSrc !== '') {
        Web({ src: this.webSrc, controller: this.controller })
      .javaScriptProxy({
        object: this.bridge,
        name: 'DeepSeekAndroid',
        methodList: BRIDGE_METHODS,
        controller: this.controller
      })
      .onInterceptRequest((event) => {
        const url = event.request.getRequestUrl()
        if (!url.startsWith(RAW_PREFIX)) {
          // 外部请求（api.deepseek.com 等）放行
          return undefined
        }
        let path = url.substring(RAW_PREFIX.length)
        const q = path.indexOf('?')
        if (q >= 0) {
          path = path.substring(0, q)
        }
        try {
          path = decodeURIComponent(path)
        } catch (err) {
          // 保留原样
        }
        if (path.includes('../') || path.includes('..\\')) {
          return this.notFound()
        }
        try {
          const data = getContext(this).resourceManager.getRawFileContentSync(path)
          const response = new WebResourceResponse()
          response.setResponseData(data.buffer)
          response.setResponseEncoding('utf-8')
          response.setResponseMimeType(mimeFor(path))
          response.setResponseCode(200)
          response.setReasonMessage('OK')
          return response
        } catch (err) {
          // 未知路径留在打包 origin 内（对齐 Android 版 "Unknown paths must stay inside"）
          return this.notFound()
        }
      })
      .domStorageAccess(true)
      .databaseAccess(true)
      .javaScriptAccess(true)
      .javaScriptOnDocumentStart([{ script: MQ_FIX_SCRIPT, scriptRules: ['file://*', 'resource://*'] }])
      .fileAccess(true)
      .zoomAccess(false)
      .multiWindowAccess(false)
      .geolocationAccess(false)
      .onControllerAttached(() => {
        console.info('ArkWeb controller attached')
        this.diag = `${this.diag} | attached`.substring(0, 240)
      })
      .onShowFileSelector((event: OnShowFileSelectorEvent): boolean => {
        // 整个处理必须包裹：任何同步异常都会让引擎按 false 处理 → 弹默认 UI
        try {
          this.onWebFileSelector(event)
          return true
        } catch (err) {
          console.error(`onShowFileSelector failed: ${JSON.stringify(err)}`)
          return false
        }
      })
      .onPageBegin((event: OnPageBeginEvent) => {
        const u: string = event.url
        this.diag3 = `begin ${u.length > 60 ? u.substring(0, 60) : u}`
        console.info(`page begin: ${u}`)
      })
      .onPageEnd((_event: OnPageEndEvent) => {
        this.diag3 = 'page loaded'
        console.info('page end')
        // 兜底：个别情况下首帧回调不触发，页面加载完也要显示
        this.webPainted = true
        this.probe('t0')
        setTimeout(() => {
          this.probe('t2')
        }, 2000)
      })
      .onFirstContentfulPaint((_event: OnFirstContentfulPaintEvent) => {
        this.webPainted = true
      })
      .opacity(this.webPainted ? 1 : 0)
      .onHttpErrorReceive((event: OnHttpErrorReceiveEvent) => {
        const u: string = event.request.getRequestUrl()
        const code: number = event.response.getResponseCode()
        const short: string = u.substring(u.lastIndexOf('/') + 1)
        this.diag2 = `HTTP ${code} ${short}`.substring(0, 180)
        this.diagErr = true
        console.error(`http error: ${u} code=${code}`)
      })
      .onConsole((event: OnConsoleEvent): boolean => {
        const msg: ConsoleMessage = event.message
        const level: MessageLevel = msg.getMessageLevel()
        const text: string = msg.getMessage()
        console.info(`web console [${level}]: ${text}`)
        if (level === MessageLevel.Error) {
          this.diag2 = `JS ERR ${text}`.substring(0, 180)
          this.diagErr = true
        } else if (level === MessageLevel.Warn && this.diag2 === '') {
          this.diag2 = `JS WARN ${text}`.substring(0, 180)
        }
        return false
      })
      .onErrorReceive((event: OnErrorReceiveEvent) => {
        const u: string = event.request.getRequestUrl()
        const e: string = `${event.error.getErrorCode()} ${event.error.getErrorInfo()}`
        this.diag3 = `ERR ${e} ${u.length > 40 ? u.substring(0, 40) : u}`.substring(0, 120)
        this.diagErr = true
        console.error(`resource error: ${u} ${e}`)
      })
      .darkMode(WebDarkMode.Auto)
      // 与启动窗口背景同色：Web 首帧尚未绘制时不会露出系统默认白底，
      // 深色模式下从黑底启动图过渡到页面是无缝的
      .backgroundColor($r('app.color.start_window_background'))
      .width('100%')
      .layoutWeight(1)
        }
      }
      .width('100%')
      .height('100%')
      // 相册保存授权面板：系统只认可安全控件 SaveButton 的临时授权，
      // 因此用户点「保存到相册」时先浮出这一层，让用户亲手点一下安全控件。
      if (this.gallerySavePath !== '') {
        this.gallerySavePanel()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.start_window_background'))
  }

  /**
   * 相册保存授权面板。
   *
   * 为什么必须有这层 UI：三方应用写相册需要 WRITE_IMAGEVIDEO（系统级权限，拿不到），
   * 唯一合法路径是用户点击 SaveButton 安全控件时系统下发的一次性临时授权。
   * 授权只在该次点击的调用栈内有效，所以这里一拿到 SUCCESS 就立刻交给桥接层写文件。
   */
  @Builder
  gallerySavePanel() {
    Column() {
      Column() {
        Text(this.gallerySaveTitle)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.panel_text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ bottom: 8 })
        Text('点击下方按钮授权保存到系统相册')
          .fontSize(13)
          .fontColor($r('app.color.panel_text_secondary'))
          .margin({ bottom: 20 })
        SaveButton({ icon: SaveIconStyle.FULL_FILLED, text: SaveDescription.SAVE_IMAGE })
          .onClick((_event: ClickEvent, result: SaveButtonOnClickResult) => {
            this.closeGallerySavePanel(result === SaveButtonOnClickResult.SUCCESS)
          })
          .width('100%')
          .height(40)
        Button('取消')
          .backgroundColor(Color.Transparent)
          .fontColor($r('app.color.panel_text_secondary'))
          .fontSize(15)
          .width('100%')
          .height(40)
          .margin({ top: 4 })
          .onClick(() => {
            this.closeGallerySavePanel(false)
          })
      }
      .width('82%')
      .constraintSize({ maxWidth: 360 })
      .padding(24)
      .borderRadius(20)
      .backgroundColor($r('app.color.panel_background'))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.panel_mask'))
    // 刻意不给遮罩加 onClick：ArkUI 的点击会向上冒泡，加了之后用户点安全控件
    // 会先被遮罩的「取消」截走，临时授权拿不到就永远存不进相册。
    // 关闭面板只走下方「取消」按钮。
  }

  /** 关闭授权面板并把结果交给桥接层（true = 已获得临时授权）。 */
  private closeGallerySavePanel(authorized: boolean): void {
    const path = this.gallerySavePath
    const title = this.gallerySaveTitle
    if (path === '') {
      return
    }
    this.gallerySavePath = ''
    this.gallerySaveTitle = ''
    this.bridge.commitGallerySave(title, path, authorized)
  }

  /**
   * Web 侧 input[type=file] 触发的选择器：手机/平板上图片类一步直达系统相册
   * （PhotoViewPicker 图库网格），2in1 与非图片类走系统文件选择器。
   * 选中后复制到沙箱临时文件再 handleFileList 回传（ArkWeb 无法直接读媒体 uri），
   * Web 层按 File 对象继续原有上传流程，无需改动。
   */
  private onWebFileSelector(event: OnShowFileSelectorEvent): void {
    // 首选 Web 显式声明的意图（点击按钮时 setPickerKind 同步写入）。
    // 若拿不到（旧包/异常路径），退回 accept 解析。
    const kind = this.bridge.consumePickerKind()
    if (kind === 'camera') {
      this.pickWithCamera(event)
      return
    }
    const wantsGallery = kind === 'gallery'
      || (kind === '' && !event.fileSelector.isCapture() && this.isGalleryPicker(event.fileSelector))
    if (wantsGallery && deviceInfo.deviceType !== '2in1') {
      this.pickFromGallery(event)
      return
    }
    this.pickWithDocumentPicker(event)
  }

  /**
   * 拍照：cameraPicker.pick（免权限，系统相机 UI）。
   * 之前走 DocumentViewPicker，用户点「拍照」看到的是文件管理器 —— 明显不对。
   */
  private pickWithCamera(event: OnShowFileSelectorEvent): void {
    const ctx = getContext(this) as common.UIAbilityContext
    const profile: cameraPicker.PickerProfile = {
      cameraPosition: camera.CameraPosition.CAMERA_POSITION_BACK
    }
    try {
      cameraPicker.pick(ctx, [cameraPicker.PickerMediaType.PHOTO], profile)
        .then((result: cameraPicker.PickerResult) => {
          // resultCode 0 = 成功；取消时 uri 为空
          if (result.resultCode !== 0 || result.resultUri === '') {
            event.result.handleFileList([])
            return
          }
          const copied = this.copyPickedToSandbox(result.resultUri, 'shot')
          event.result.handleFileList(copied === '' ? [] : [`file://${copied}`])
        })
        .catch((err: BusinessError) => {
          console.error(`cameraPicker failed: ${JSON.stringify(err)}`)
          event.result.handleFileList([])
        })
    } catch (err) {
      console.error(`cameraPicker unavailable: ${JSON.stringify(err)}`)
      event.result.handleFileList([])
    }
  }

  /**
   * 判断 Web 侧是否**只要图片**（严格，只看 getAcceptType）。
   *
   * 为什么不用 getMimeTypes()：v1.0.9 实测本位对 accept 为 image 通配时，
   * getMimeTypes() 返回全通配（星号-斜杠-星号），与 getAcceptType() 合并后
   * tokens 里出现非图片项 → 图片按钮被判成选文件，两个按钮都落到文件管理器。
   * 而 v1.0.8 的反向证据（文件按钮的数百项扩展名被原样读出）说明
   * getAcceptType() 是逐字返回 accept 的，可靠。
   *
   * 严格判据：accept 的**每一项**都必须是图片（image 通配或图片扩展名）。
   * 文件按钮的 accept 是全格式扩展名长列表（含 .jpg/.png），必含 .pdf/.js 等
   * 非图片项 → 返回 false，走文件管理器。
   */
  private isGalleryPicker(selector: FileSelectorParam): boolean {
    let accept: Array<string> = []
    try {
      accept = selector.getAcceptType()
    } catch (err) {
      console.error(`getAcceptType failed: ${JSON.stringify(err)}`)
      return false
    }
    if (accept.length === 0) {
      return false
    }
    let sawImage = false
    for (let i = 0; i < accept.length; i++) {
      const t = accept[i].toLowerCase().trim()
      if (t === '') {
        continue
      }
      const isImageMime = t === 'image/*' || (t.startsWith('image/') && !t.includes('*'))
      const isImageExt = t.startsWith('.') && IMAGE_EXTS.includes(t.substring(1))
      if (!isImageMime && !isImageExt) {
        // 出现任意非图片项（.pdf/.js/.json 等）→ 这是「选择文件」
        return false
      }
      sawImage = true
    }
    return sawImage
  }

  private pickFromGallery(event: OnShowFileSelectorEvent): void {
    let photoPicker: photoAccessHelper.PhotoViewPicker
    try {
      photoPicker = new photoAccessHelper.PhotoViewPicker()
    } catch (err) {
      // 内核不支持时退回系统文件选择器，至少不弹空
      console.error(`PhotoViewPicker unavailable: ${JSON.stringify(err)}`)
      this.pickWithDocumentPicker(event)
      return
    }
    const options: photoAccessHelper.PhotoSelectOptions = {
      MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
      maxSelectNumber: 9
    }
    photoPicker.select(options).then((result: photoAccessHelper.PhotoSelectResult) => {
      const uris: Array<string> = result.photoUris
      if (!uris || uris.length === 0) {
        event.result.handleFileList([])
        return
      }
      const files: string[] = []
      const stamp = Date.now()
      for (let i = 0; i < uris.length; i++) {
        const dst = this.copyPickedToSandbox(uris[i], `pick_${stamp}_${i}`)
        if (dst !== '') {
          files.push(`file://${dst}`)
        }
      }
      event.result.handleFileList(files)
    }).catch((err: BusinessError) => {
      console.error(`gallery pick failed: ${JSON.stringify(err)}`)
      event.result.handleFileList([])
    })
  }

  /**
   * 把系统媒体 uri 复制到沙箱并补上扩展名，返回沙箱路径（失败返回 ''）。
   * ArkWeb 无法直接读媒体 uri，必须落地成真实文件再回传 file:// 路径；
   * uri 不携带可靠扩展名，靠魔数嗅探。
   */
  private copyPickedToSandbox(uri: string, nameHint: string): string {
    try {
      const ctx = getContext(this) as common.UIAbilityContext
      const dir = `${ctx.cacheDir}/picked`
      this.ensureDir(dir)
      const src = fs.openSync(uri, fs.OpenMode.READ_ONLY)
      const tmp = `${dir}/${nameHint}`
      fs.copyFileSync(src.fd, tmp)
      fs.closeSync(src.fd)
      const dst = `${tmp}.${this.sniffImageExt(tmp)}`
      try {
        fs.renameSync(tmp, dst)
        return dst
      } catch (err) {
        // 改名失败则返回无扩展名临时文件（Web 侧仍能读到内容）
        return tmp
      }
    } catch (err) {
      console.error(`copyPickedToSandbox failed: ${JSON.stringify(err)}`)
      return ''
    }
  }

  /** fs.accessSync 对不存在的路径会抛异常而非返回 false，必须 try/catch。 */
  private ensureDir(dir: string): void {
    try {
      if (fs.accessSync(dir)) {
        return
      }
    } catch (err) {
      // 不存在或其他异常：尝试创建
    }
    try {
      fs.mkdirSync(dir, true)
    } catch (err) {
      console.error(`ensureDir failed: ${dir} ${JSON.stringify(err)}`)
    }
  }

  /** 读头部魔数推断扩展名（相册 uri 不携带文件名信息）。 */
  private sniffImageExt(path: string): string {
    try {
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY)
      const buf = new ArrayBuffer(12)
      fs.readSync(file.fd, buf, { offset: 0, length: 12 })
      fs.closeSync(file.fd)
      const b = new Uint8Array(buf)
      if (b[0] === 0xFF && b[1] === 0xD8) {
        return 'jpg'
      }
      if (b[0] === 0x89 && b[1] === 0x50) {
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
      return 'jpg'
    }
  }

  /** 2in1 与非图片类：系统文件选择器（保持 PC 现状）。 */
  private pickWithDocumentPicker(event: OnShowFileSelectorEvent): void {
    const ctx = getContext(this) as common.UIAbilityContext
    const docPicker = new picker.DocumentViewPicker(ctx)
    const options: picker.DocumentSelectOptions = {
      maxSelectNumber: 9
    }
    docPicker.select(options).then((uris: Array<string>) => {
      event.result.handleFileList(uris)
    }).catch((err: BusinessError) => {
      console.error(`document pick failed: ${JSON.stringify(err)}`)
      event.result.handleFileList([])
    })
  }

  private notFound(): WebResourceResponse {
    const response = new WebResourceResponse()
    response.setResponseData(new ArrayBuffer(0))
    response.setResponseMimeType('text/plain')
    response.setResponseCode(404)
    response.setReasonMessage('Not Found')
    return response
  }
}
