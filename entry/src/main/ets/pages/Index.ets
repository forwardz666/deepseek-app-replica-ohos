import { webview } from '@kit.ArkWeb'
import { common } from '@kit.AbilityKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { DeepSeekBridge } from '../bridge/DeepSeekBridge'

/**
 * Web 宿主页：加载 rawfile 内打包的 React 应用，注入 window.DeepSeekAndroid 桥。
 * 本地资源经 onInterceptRequest 从 rawfile 读取并附加 CSP（逐字复刻 Android 版
 * MainActivity.java:235-239 的安全策略）；外部请求（api.deepseek.com 等）放行。
 */

// 阶段 0 暂不注入 CSP：resource:// scheme 可能被赋予 opaque origin，'self' 会全拦。
// TODO 阶段 1：日志确认 origin 语义后按 Android 版 CSP（MainActivity.java:238-240）恢复。
const RAW_PREFIX = 'resource://rawfile/'

// 对齐 Web 层 AndroidBridge 的全部桥方法（不含已废弃的 update 三个）
const BRIDGE_METHODS: string[] = [
  'statusInset', 'buttonNavigationInset', 'systemFontScale',
  'openAppPermissions', 'getMusicVolume', 'openSourcePage',
  'readApiKey', 'writeApiKey', 'readChatConfig', 'writeChatConfig',
  'beginChatRequest', 'cancelChatRequest',
  'readAccountProfile', 'writeAccountProfile',
  'setDarkBars', 'setHandlesBack', 'setBackPreviewEnabled',
  'setImageViewerFullscreen', 'requestRecentPhotos', 'prefetchRecentPhotos',
  'requestHistoryExport', 'writeHistoryExport', 'finishHistoryExport',
  'beginImageSave', 'writeImageSave', 'finishImageSave',
  'requestRecording', 'finishRecording', 'recordingLevel',
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
  @State webSrc: string = 'about:blank'
  controller: webview.WebviewController = new webview.WebviewController()
  private bridge: DeepSeekBridge =
    new DeepSeekBridge(this.controller, getContext(this) as common.UIAbilityContext)
  private resourceDir: string = ''

  aboutToAppear(): void {
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

  onBackPress(): boolean {
    // 阶段 0 简化协议：Web 可后退则后退，否则交给系统退出
    // TODO 阶段 1：按 Web 层 android-back 事件协议（setHandlesBack 状态机）完整实现
    try {
      if (this.controller.accessBackward()) {
        this.controller.backward()
        return true
      }
    } catch (err) {
      console.error(`onBackPress: ${JSON.stringify(err)}`)
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
    Column() {
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
      .fileAccess(true)
      .zoomAccess(false)
      .multiWindowAccess(false)
      .geolocationAccess(false)
      .onControllerAttached(() => {
        console.info('ArkWeb controller attached')
        this.diag = `${this.diag} | attached`.substring(0, 240)
      })
      .onPageBegin((event: OnPageBeginEvent) => {
        const u: string = event.url
        this.diag3 = `begin ${u.length > 60 ? u.substring(0, 60) : u}`
        console.info(`page begin: ${u}`)
      })
      .onPageEnd((_event: OnPageEndEvent) => {
        this.diag3 = 'page loaded'
        console.info('page end')
        this.probe('t0')
        setTimeout(() => {
          this.probe('t2')
        }, 2000)
      })
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
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
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
