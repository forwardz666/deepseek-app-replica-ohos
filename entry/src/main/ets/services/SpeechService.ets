import { abilityAccessCtrl, bundleManager, common, Permissions } from '@kit.AbilityKit'
import { BridgeHost } from './BridgeHost'

/**
 * 系统语音能力（Core Speech Kit），两条链路都按官方声明形态调用：
 *   - 本地 TTS：createEngine 返回 Promise，speak 时 playType=1 由引擎直接播放
 *   - 本地 ASR：引擎自己采集麦克风做实时识别（不是把录音文件喂进去）
 *
 * 为什么用 requireNapi 动态加载：OpenHarmony SDK 26 的 `ets/api` 里没有
 * `@kit.CoreSpeechKit` 的声明文件（该 Kit 只在 HMS 的 SDK 中提供），但真机
 * 的 `/system/lib64/module/hms/ai/` 下有 `libtexttospeech.z.so` 与
 * `libspeechrecognizer.z.so`，模块名分别为 `ai.texttospeech`、
 * `ai.speechrecognizer`。直接 requireNapi 即可拿到与 `@kit.CoreSpeechKit`
 * 同一份 NAPI 实现。
 *
 * 两个引擎都是全局单例：createEngine 是重操作，反复创建会占大量内存，
 * 页面销毁时只 shutdown，不中途重建。
 */

// SDK 未声明 requireNapi，这里补一个；ArkTS 运行时本身提供该全局函数
declare function requireNapi(name: string): ESObject

const TTS_MODULES: string[] = [
  '@hms.ai.textToSpeech',
  'hms.ai.textToSpeech',
  'ai.textToSpeech',
  'ai.texttospeech'
]
const ASR_MODULES: string[] = [
  '@hms.ai.speechRecognizer',
  'hms.ai.speechRecognizer',
  'ai.speechRecognizer',
  'ai.speechrecognizer'
]
const MIC_PERMISSION: Permissions = 'ohos.permission.MICROPHONE'

/**
 * 单次喂给 TTS 引擎的文本上限。引擎上限 10000 字符，这里取 5000 ——
 * 绝大多数回复一段就能读完，避免分段带来的停顿；切得太碎还会让句间停顿明显。
 */
const TTS_CHUNK: number = 5000

/**
 * 加载系统语音 NAPI 模块，返回真正挂 createEngine 的对象。
 *
 * 三个坑：
 * 1. **必须单参数调用**。ets-loader 对标准模块生成的是
 *    `globalThis.requireNapi('xxx')`；第二参数 true 表示「从应用自己的 libs
 *    加载三方 NAPI」（`requireNapi(name, true, pkg)` 三参数形态），
 *    拿它去加载系统模块会直接抛错。
 * 2. **模块名带 hms 命名空间**。HMS SDK 的声明是
 *    `import textToSpeech from '@hms.ai.textToSpeech'`，不是 `ai.texttospeech`。
 *    不同版本运行时认的名字不完全一致，逐个试。
 * 3. **加载成功不等于可用**：未知模块可能返回空对象而不抛错，
 *    所以必须检查 createEngine 是不是函数；有的实现还会包一层 `default`。
 */
function speechModule(names: string[]): ESObject {
  const tried: string[] = []
  for (const name of names) {
    let mod: ESObject
    try {
      mod = requireNapi(name)
    } catch (err) {
      tried.push(`${name}=throw`)
      continue
    }
    if (typeof mod !== 'object' && typeof mod !== 'function') {
      tried.push(`${name}=empty`)
      continue
    }
    const direct: ESObject = mod['createEngine']
    if (typeof direct === 'function') {
      return mod
    }
    const inner: ESObject = mod['default']
    if (typeof inner === 'object') {
      const nested: ESObject = inner['createEngine']
      if (typeof nested === 'function') {
        return inner
      }
    }
    tried.push(`${name}=noCreateEngine`)
  }
  throw new Error(`speech module unavailable: ${tried.join(', ')}`)
}

/** createEngine 是否返回了 thenable（Promise 形态）；老实现只支持 callback 时返回 false */
function isThenable(value: ESObject): boolean {
  if (typeof value !== 'object') {
    return false
  }
  const then: ESObject = value['then']
  return typeof then === 'function'
}

/** 把长文本按句末标点切成不超过 limit 的片段，避免超长文本被引擎拒绝 */
function splitText(text: string, limit: number): string[] {
  const pieces: string[] = []
  let rest = text.trim()
  while (rest.length > 0) {
    if (rest.length <= limit) {
      pieces.push(rest)
      break
    }
    let cut = -1
    for (let i = limit; i > limit / 2; i--) {
      const ch = rest.charAt(i)
      if (ch === '。' || ch === '！' || ch === '？' || ch === '；' ||
        ch === '.' || ch === '!' || ch === '?' || ch === ';' || ch === '\n') {
        cut = i + 1
        break
      }
    }
    if (cut < 0) {
      cut = limit
    }
    pieces.push(rest.substring(0, cut))
    rest = rest.substring(cut).trim()
  }
  return pieces
}

/** 申请麦克风权限；已授权时直接返回 true，不再弹框 */
async function requestMicrophone(context: common.UIAbilityContext): Promise<boolean> {
  try {
    const manager = abilityAccessCtrl.createAtManager()
    const info = bundleManager.getBundleInfoForSelfSync(
      bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION
    )
    const status = manager.checkAccessTokenSync(info.appInfo.accessTokenId, MIC_PERMISSION)
    if (status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
      return true
    }
    const result = await manager.requestPermissionsFromUser(context, [MIC_PERMISSION])
    if (result.authResults.length > 0 &&
      result.authResults[0] === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
      return true
    }
    // 用户此前拒绝过时系统不再弹窗，改用二次授权弹窗引导开启
    const shown = result.dialogShownResults
    if (shown !== undefined && shown.length > 0 && shown[0] === false) {
      const retry = await manager.requestPermissionOnSetting(context, [MIC_PERMISSION])
      return retry.length > 0 && retry[0] === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED
    }
  } catch (err) {
    console.warn(`request microphone failed: ${JSON.stringify(err)}`)
  }
  return false
}

export class SpeechService {
  private readonly host: BridgeHost

  constructor(host: BridgeHost) {
    this.host = host
  }

  // ===== 本地 TTS =====

  /** 引擎句柄；用 hasTtsEngine 表示是否已创建（ArkTS 不允许 ESObject 与 null 组成联合类型） */
  private ttsEngine: ESObject = {}
  private hasTtsEngine: boolean = false
  private ttsLoading: boolean = false
  private ttsQueue: string[] = []
  private ttsRequestSeq: number = 0
  /** 当前 requestId：onComplete/onStop 只认它，避免迟到的回调推动队列 */
  private ttsCurrentId: string = ''
  /** 引擎创建期间收到的文本，创建完成后立刻播 */
  private ttsPending: string = ''

  /**
   * 开始本地播报。返回 false 表示设备没有本地合成引擎，调用方应提示用户。
   * 引擎首次创建是异步的，这里先返回 true，等 createEngine 回来再真正开播。
   */
  localTtsSpeak(text: string, _rate: number): boolean {
    // 不把 canIUse 当硬门禁：OpenHarmony 的 syscap 清单不一定声明 HMS 的 AI 能力，
    // 但 /system/lib64/module/hms/ai 下的模块实际存在。以能否加载 NAPI 为准。
    // 语速暂不支持：SpeakParams 只文档化了 style/locate/name/isBackStage，
    // 传 speed 可能被判参数错误，先保持引擎默认语速。
    if (this.hasTtsEngine) {
      this.startTtsQueue(this.ttsEngine, text)
      return true
    }
    if (this.ttsLoading) {
      // 引擎还在创建（用户连续点朗读），把文本接过来等创建完成即可
      this.ttsPending = text
      return true
    }
    let mod: ESObject
    try {
      mod = speechModule(TTS_MODULES)
    } catch (err) {
      console.warn(`local tts unavailable: ${JSON.stringify(err)}`)
      return false
    }
    this.ttsLoading = true
    this.ttsPending = text
    this.createTtsEngine(mod)
    return true
  }

  localTtsStop(): void {
    this.ttsQueue = []
    this.ttsPending = ''
    // 先让 requestId 失效：engine.stop() 触发的 onStop 是旧回调，
    // 不能再给可能刚开始的新一次朗读派发 end
    this.ttsCurrentId = ''
    if (!this.hasTtsEngine) {
      return
    }
    try {
      this.ttsEngine['stop']()
    } catch (err) {
      console.warn(`tts stop failed: ${JSON.stringify(err)}`)
    }
  }

  /** createEngine 的官方声明形态是 Promise；老实现只支持 callback，两种都兜住 */
  private createTtsEngine(mod: ESObject): void {
    const initParams: Record<string, ESObject> = {
      'language': 'zh-CN',
      'person': 0,
      'online': 1,
      'extraParams': {
        'style': 'interaction-broadcast',
        'locate': 'CN'
      } as Record<string, ESObject>
    }
    try {
      const created: ESObject = mod['createEngine'](initParams)
      if (isThenable(created)) {
        created.then((engine: ESObject) => {
          this.onTtsEngine(engine)
        }).catch((err: ESObject) => {
          this.failTts(err, 'promise')
        })
      } else {
        mod['createEngine'](initParams, (err: ESObject, engine: ESObject) => {
          if (err || !engine) {
            this.failTts(err, 'callback')
            return
          }
          this.onTtsEngine(engine)
        })
      }
    } catch (err) {
      this.failTts(err, 'throw')
    }
  }

  private onTtsEngine(engine: ESObject): void {
    this.ttsLoading = false
    this.ttsEngine = engine
    this.hasTtsEngine = true
    this.attachTtsListener(engine)
    const pending = this.ttsPending
    this.ttsPending = ''
    if (pending.length > 0) {
      this.startTtsQueue(engine, pending)
    }
  }

  private failTts(err: ESObject, stage: string): void {
    this.ttsLoading = false
    this.ttsPending = ''
    console.error(`create tts engine failed (${stage}): ${JSON.stringify(err)}`)
    this.host.dispatchEvent('android-local-tts', 'error')
  }

  /** onStart 首次出声时通知 Web 切到 playing，队列播完再派发 end */
  private attachTtsListener(engine: ESObject): void {
    const listener: Record<string, ESObject> = {
      'onStart': (requestId: string) => {
        // 每段都会回调 onStart，只有第一段需要把 Web 状态切到 playing
        this.host.dispatchEvent('android-local-tts', 'start')
      },
      'onComplete': (requestId: string, response: Record<string, number>) => {
        // requestId 不匹配说明是 stop 之前的旧回调，不能推动队列
        if (requestId !== this.ttsCurrentId) {
          return
        }
        // CompleteResponse.type: 0 = 合成完成，1 = 播放完成，同一段文本**两个阶段各回调一次**。
        // 只在「不是合成完成」时推进队列。此前忽略 response，合成一结束就当成播完：
        // 单段文本会立刻派发 end，Web 收到后调 localTtsStop() 把正在播的声音切断，
        // 表现就是「只读几个字就没声了」；多段则下一段 speak 打断上一段。
        let finished: boolean = true
        try {
          finished = response['type'] !== 0
        } catch (err) {
          // 拿不到 response 时按播放完成处理，兼容不上报 type 的实现
          finished = true
        }
        if (finished) {
          this.speakNext()
        }
      },
      'onStop': (requestId: string) => {
        if (requestId !== this.ttsCurrentId) {
          return
        }
        this.ttsCurrentId = ''
        this.ttsQueue = []
        this.host.dispatchEvent('android-local-tts', 'end')
      },
      'onData': (requestId: string, audio: ESObject) => {
        // playType=1 时音频由引擎内部播放，这里不消费 PCM
      },
      'onError': (requestId: string, errorCode: number, errorMessage: string) => {
        console.error(`tts onError ${requestId} ${errorCode} ${errorMessage}`)
        this.ttsQueue = []
        this.ttsCurrentId = ''
        this.host.dispatchEvent('android-local-tts', 'error')
      }
    }
    try {
      engine['setListener'](listener)
    } catch (err) {
      console.error(`setListener failed: ${JSON.stringify(err)}`)
    }
  }

  private startTtsQueue(engine: ESObject, text: string): void {
    this.ttsQueue = splitText(text, TTS_CHUNK)
    if (this.ttsQueue.length === 0) {
      this.host.dispatchEvent('android-local-tts', 'end')
      return
    }
    this.speakNext()
  }

  private speakNext(): void {
    if (!this.hasTtsEngine) {
      return
    }
    const next = this.ttsQueue.shift()
    if (next === undefined) {
      this.ttsCurrentId = ''
      this.host.dispatchEvent('android-local-tts', 'end')
      return
    }
    this.ttsRequestSeq++
    // requestId 只允许字母、数字和中文，带连字符可能被引擎判为非法参数
    const requestId = `dsk${this.ttsRequestSeq}`
    this.ttsCurrentId = requestId
    const params: Record<string, ESObject> = {
      'requestId': requestId,
      'extraParams': {
        'languageContext': 'zh-CN',
        // 1 = 合成后直接由引擎播放。不传时部分机型只回调 onData 不出声。
        // 其余（speed/volume/pitch）不在声明里，多传可能触发 401 参数错误，一律不带。
        'playType': 1
      } as Record<string, ESObject>
    }
    try {
      this.ttsEngine['speak'](next, params)
    } catch (err) {
      console.error(`speak failed: ${JSON.stringify(err)}`)
      this.ttsQueue = []
      this.ttsCurrentId = ''
      this.host.dispatchEvent('android-local-tts', 'error')
    }
  }

  // ===== 本地离线识别（ASR，引擎自采麦克风） =====

  private asrEngine: ESObject = {}
  private hasAsrEngine: boolean = false
  /** 从点开始到真正 startListening 之间为 true（含申请权限、建引擎） */
  private asrStarting: boolean = false
  /** 用户在引擎就绪前就点了结束，startListening 后立刻 finish */
  private asrStopQueued: boolean = false
  private asrSessionId: string = ''
  /** 最近一次识别文本；onComplete 时一次性交给 Web */
  private asrText: string = ''

  localAsrAvailable(): boolean {
    // 以「能拿到带 createEngine 的模块」为准，不看 syscap 声明
    try {
      speechModule(ASR_MODULES)
      return true
    } catch (err) {
      return false
    }
  }

  /**
   * 开始识别。返回 false = 设备没有端侧引擎。
   * 权限申请与建引擎都是异步的，真正开始采集后派发 `state:listening`，
   * 结束派发 `end:文本`，失败派发 `error:原因`。
   */
  localAsrStart(): boolean {
    // 先确认模块可用，失败要同步返回 false，让 Web 立刻提示而不是干等事件
    try {
      speechModule(ASR_MODULES)
    } catch (err) {
      return false
    }
    if (this.asrStarting) {
      return true
    }
    this.abortAsr()
    this.asrText = ''
    this.asrStarting = true
    this.asrStopQueued = false
    this.beginAsr()
    return true
  }

  /** 用户点结束：停止采集，等引擎给出最终结果 */
  localAsrStop(): void {
    if (this.asrStarting) {
      // 引擎还没就绪，等 startListening 之后立刻结束
      this.asrStopQueued = true
      return
    }
    if (this.asrSessionId.length === 0) {
      this.host.dispatchEvent('android-local-asr', 'end:')
      return
    }
    try {
      this.asrEngine['finish'](this.asrSessionId)
    } catch (err) {
      console.error(`asr finish failed: ${JSON.stringify(err)}`)
      this.asrSessionId = ''
      this.host.dispatchEvent('android-local-asr', 'error:finish')
    }
  }

  /** 放弃本次识别（取消、切后台、页面销毁），不派发结果 */
  localAsrCancel(): void {
    this.asrStarting = false
    this.asrStopQueued = false
    this.asrText = ''
    this.abortAsr()
  }

  private beginAsr(): void {
    requestMicrophone(this.host.context).then((granted: boolean) => {
      if (!this.asrStarting) {
        return
      }
      if (!granted) {
        this.asrStarting = false
        this.host.dispatchEvent('android-local-asr', 'error:denied')
        return
      }
      if (this.hasAsrEngine) {
        this.startListening(this.asrEngine)
        return
      }
      this.createAsrEngine()
    }).catch((err: ESObject) => {
      this.asrStarting = false
      console.error(`request microphone threw: ${JSON.stringify(err)}`)
      this.host.dispatchEvent('android-local-asr', 'error:mic')
    })
  }

  private createAsrEngine(): void {
    let mod: ESObject
    try {
      mod = speechModule(ASR_MODULES)
    } catch (err) {
      this.asrStarting = false
      this.host.dispatchEvent('android-local-asr', 'error:unavailable')
      return
    }
    const initParams: Record<string, ESObject> = {
      'language': 'zh-CN',
      // 1 = 允许在线识别；纯离线(0)要求设备已下载离线模型，未下载时建引擎失败
      'online': 1,
      'extraParams': {
        'locate': 'CN',
        'recognizerMode': 'short'
      } as Record<string, ESObject>
    }
    try {
      const created: ESObject = mod['createEngine'](initParams)
      if (isThenable(created)) {
        created.then((engine: ESObject) => {
          this.onAsrEngine(engine)
        }).catch((err: ESObject) => {
          this.failAsr(err, 'promise')
        })
      } else {
        mod['createEngine'](initParams, (err: ESObject, engine: ESObject) => {
          if (err || !engine) {
            this.failAsr(err, 'callback')
            return
          }
          this.onAsrEngine(engine)
        })
      }
    } catch (err) {
      this.failAsr(err, 'throw')
    }
  }

  private onAsrEngine(engine: ESObject): void {
    this.asrEngine = engine
    this.hasAsrEngine = true
    this.attachAsrListener(engine)
    if (this.asrStarting) {
      this.startListening(engine)
    }
  }

  private failAsr(err: ESObject, stage: string): void {
    this.asrStarting = false
    console.error(`create asr engine failed (${stage}): ${JSON.stringify(err)}`)
    this.host.dispatchEvent('android-local-asr', 'error:engine')
  }

  private attachAsrListener(engine: ESObject): void {
    const listener: Record<string, ESObject> = {
      'onStart': (sessionId: string) => {
        if (sessionId !== this.asrSessionId) {
          return
        }
        this.host.dispatchEvent('android-local-asr', 'state:listening')
        // 用户在就绪前已点结束
        if (this.asrStopQueued) {
          this.asrStopQueued = false
          this.localAsrStop()
        }
      },
      'onEvent': (sessionId: string, eventCode: number) => {
        console.info(`asr onEvent ${sessionId} ${eventCode}`)
      },
      'onResult': (sessionId: string, result: ESObject) => {
        if (sessionId !== this.asrSessionId) {
          return
        }
        // 中间结果与最终结果共用 result 字段，取最后一次即最佳
        const piece: ESObject = result['result']
        if (typeof piece === 'string') {
          this.asrText = piece
        }
      },
      'onComplete': (sessionId: string) => {
        if (sessionId !== this.asrSessionId) {
          return
        }
        this.finishAsr()
      },
      'onError': (sessionId: string, errorCode: number, errorMessage: string) => {
        console.error(`asr onError ${sessionId} ${errorCode} ${errorMessage}`)
        if (sessionId !== this.asrSessionId) {
          return
        }
        this.asrSessionId = ''
        this.asrText = ''
        this.host.dispatchEvent('android-local-asr', `error:${errorCode}`)
      }
    }
    try {
      engine['setListener'](listener)
    } catch (err) {
      console.error(`asr setListener failed: ${JSON.stringify(err)}`)
    }
  }

  private startListening(engine: ESObject): void {
    const sessionId = `dsreplica-${Date.now()}`
    this.asrSessionId = sessionId
    const startParams: Record<string, ESObject> = {
      'sessionId': sessionId,
      // 引擎从麦克风采集；audioType 固定 pcm
      'audioInfo': {
        'audioType': 'pcm',
        'sampleRate': 16000,
        'soundChannel': 1,
        'sampleBit': 16
      } as Record<string, ESObject>,
      'extraParams': {
        // 0 = 短语音模式（一句话/一段话）。缺这个字段时引擎按长语音处理
        'recognitionMode': 0,
        // 开头允许的静音时长：用户点完按钮常常还没开口
        'vadBegin': 8000,
        'vadEnd': 3000,
        'maxAudioDuration': 60000
      } as Record<string, ESObject>
    }
    try {
      engine['startListening'](startParams)
    } catch (err) {
      console.error(`startListening failed: ${JSON.stringify(err)}`)
      this.asrStarting = false
      this.asrSessionId = ''
      this.host.dispatchEvent('android-local-asr', 'error:start')
      return
    }
    this.asrStarting = false
    this.host.dispatchEvent('android-local-asr', 'state:listening')
    if (this.asrStopQueued) {
      this.asrStopQueued = false
      this.localAsrStop()
    }
  }

  /** 结束一次识别：把累积文本派发出去，Web 端据此填输入框 */
  private finishAsr(): void {
    const text = this.asrText.trim()
    this.asrSessionId = ''
    this.asrText = ''
    this.host.dispatchEvent('android-local-asr', `end:${text}`)
  }

  private abortAsr(): void {
    const sessionId = this.asrSessionId
    this.asrSessionId = ''
    if (sessionId.length > 0 && this.hasAsrEngine) {
      try {
        this.asrEngine['cancel'](sessionId)
      } catch (err) {
        // 引擎未实现 cancel 时忽略，sessionId 已失效，旧回调会被丢弃
      }
    }
  }

  /** 页面销毁时释放引擎：TTS/ASR 都是重资源，进程活着会一直占内存 */
  release(): void {
    this.localTtsStop()
    this.localAsrCancel()
    if (this.hasTtsEngine) {
      try {
        this.ttsEngine['shutdown']()
      } catch (err) {
        // 忽略
      }
      this.ttsEngine = {}
      this.hasTtsEngine = false
    }
    if (this.hasAsrEngine) {
      try {
        this.asrEngine['shutdown']()
      } catch (err) {
        // 忽略
      }
      this.asrEngine = {}
      this.hasAsrEngine = false
    }
  }
}
