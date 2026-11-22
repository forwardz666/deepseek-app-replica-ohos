import { abilityAccessCtrl } from '@kit.AbilityKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { audio } from '@kit.AudioKit'
import { util } from '@kit.ArkTS'
import { BridgeHost } from './BridgeHost'

/**
 * 录音：AudioCapturer 采集 16kHz / 单声道 / S16LE，停止后编码成 WAV。
 *
 * Web 侧协议：
 *   requestRecording() → 等 android-recording（ready / denied / error）
 *   recordingLevel()   → 0..1 音量，驱动录音浮层波形
 *   finishRecording(keep) → keep 时落盘 cache/recording.wav
 *   recordingSize() / readRecordingChunk(offset, len) → 分块取回（base64）
 *
 * 为什么不用 fetch('/recording.wav')：页面以 file:// 加载，根路径请求不会命中
 * onInterceptRequest，取不到原生文件。分块读取与历史导出同一套机制。
 */
export class RecordingService {
  private readonly host: BridgeHost

  constructor(host: BridgeHost) {
    this.host = host
  }

  private capturer: audio.AudioCapturer | null = null
  private recordingChunks: ArrayBuffer[] = []
  private recordingBytes: number = 0
  private recordingLevelValue: number = 0
  private recordingStarting: boolean = false
  /** readData 在 release 完成前仍可能回调，用该标志丢弃迟到的音频块 */
  private recordingActive: boolean = false
  private static readonly RECORDING_FILE: string = 'recording.wav'
  private static readonly RECORDING_SAMPLE_RATE: number = 16000
  /** 超过 130 秒不再累积（Web 侧上限 120 秒，留缓冲避免内存无限增长） */
  private static readonly RECORDING_MAX_BYTES: number = 16000 * 2 * 130

  /**
   * 开始录音。结果通过 android-recording 事件异步返回：
   * ready / denied / error —— Web 层 recorder.ts 等待该事件后才认为麦克风就绪。
   */
  requestRecording(): void {
    if (this.capturer !== null) {
      this.host.dispatchEvent('android-recording', 'ready')
      return
    }
    if (this.recordingStarting) {
      return
    }
    this.recordingStarting = true
    this.recordingChunks = []
    this.recordingBytes = 0
    this.recordingLevelValue = 0
    const self = this
    this.requestMicPermission().then((granted: boolean) => {
      if (!granted) {
        self.recordingStarting = false
        self.host.dispatchEvent('android-recording', 'denied')
        return
      }
      self.startCapturer()
    }).catch((err: BusinessError) => {
      self.recordingStarting = false
      console.error(`requestRecording failed: ${JSON.stringify(err)}`)
      self.host.dispatchEvent('android-recording', 'error')
    })
  }

  private requestMicPermission(): Promise<boolean> {
    try {
      const atManager = abilityAccessCtrl.createAtManager()
      // 已授权时直接返回 0，不会重复弹窗
      return atManager.requestPermissionsFromUser(this.host.context, ['ohos.permission.MICROPHONE'])
        .then((result) => result.authResults.length > 0 && result.authResults[0] === 0)
        .catch((err: BusinessError) => {
          console.error(`mic permission failed: ${JSON.stringify(err)}`)
          return false
        })
    } catch (err) {
      console.error(`mic permission threw: ${JSON.stringify(err)}`)
      return Promise.resolve(false)
    }
  }

  private startCapturer(): void {
    const self = this
    const options: audio.AudioCapturerOptions = {
      streamInfo: {
        samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
        channels: audio.AudioChannel.CHANNEL_1,
        sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
        encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
      },
      capturerInfo: {
        source: audio.SourceType.SOURCE_TYPE_MIC,
        capturerFlags: 0
      }
    }
    audio.createAudioCapturer(options).then((capturer: audio.AudioCapturer) => {
      self.capturer = capturer
      capturer.on('readData', (buffer: ArrayBuffer) => {
        if (!self.recordingActive) {
          return
        }
        if (self.recordingBytes >= RecordingService.RECORDING_MAX_BYTES) {
          return
        }
        // buffer 由引擎复用，必须拷贝一份再保存
        const copy = buffer.slice(0)
        self.recordingChunks.push(copy)
        self.recordingBytes += copy.byteLength
        self.recordingLevelValue = RecordingService.computeLevel(copy)
      })
      capturer.on('audioInterrupt', (event: audio.InterruptEvent) => {
        // 来电等系统打断：通知 Web 取消本次录音
        console.info(`audio interrupt: ${JSON.stringify(event)}`)
        self.host.dispatchEvent('android-recording-interrupted', 'interrupt')
        self.finishRecording(false)
      })
      capturer.start().then(() => {
        self.recordingStarting = false
        self.recordingActive = true
        self.host.dispatchEvent('android-recording', 'ready')
      }).catch((err: BusinessError) => {
        console.error(`capturer start failed: ${JSON.stringify(err)}`)
        self.recordingStarting = false
        self.releaseCapturer()
        self.host.dispatchEvent('android-recording', 'error')
      })
    }).catch((err: BusinessError) => {
      console.error(`createAudioCapturer failed: ${JSON.stringify(err)}`)
      self.recordingStarting = false
      self.host.dispatchEvent('android-recording', 'error')
    })
  }

  /** 由 S16LE 采样块估算 0..1 的音量（Web 层驱动录音浮层波形）。 */
  private static computeLevel(buffer: ArrayBuffer): number {
    const samples = new Int16Array(buffer)
    if (samples.length === 0) {
      return 0
    }
    let sum = 0
    for (let i = 0; i < samples.length; i++) {
      const v = samples[i] / 32768
      sum += v * v
    }
    const rms = Math.sqrt(sum / samples.length)
    // 人声 RMS 通常在 0.02~0.2，乘 5 让波形更饱满
    return Math.min(1, rms * 5)
  }

  private releaseCapturer(): void {
    const capturer = this.capturer
    this.capturer = null
    this.recordingActive = false
    if (capturer === null) {
      return
    }
    try {
      capturer.off('readData')
      capturer.off('audioInterrupt')
    } catch (err) {
      console.warn(`capturer off failed: ${JSON.stringify(err)}`)
    }
    capturer.stop().then(() => capturer.release()).catch((err: BusinessError) => {
      console.error(`capturer stop failed: ${JSON.stringify(err)}`)
    })
  }

  /**
   * 结束录音。keep=true 时把采集到的 PCM 编码成 WAV 落到沙箱，
   * Web 层随后通过 recordingSize / readRecordingChunk 分块取回。
   */
  finishRecording(keep: boolean): boolean {
    const chunks = this.recordingChunks
    const total = this.recordingBytes
    this.recordingChunks = []
    this.recordingBytes = 0
    this.recordingLevelValue = 0
    this.recordingStarting = false
    this.releaseCapturer()
    if (!keep) {
      return true
    }
    if (total <= 0) {
      return false
    }
    try {
      const wav = RecordingService.buildWav(chunks, total)
      const path = `${this.host.context.cacheDir}/${RecordingService.RECORDING_FILE}`
      const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC)
      fs.writeSync(file.fd, wav)
      fs.closeSync(file.fd)
      return true
    } catch (err) {
      console.error(`finishRecording write failed: ${JSON.stringify(err)}`)
      return false
    }
  }

  /** 最近一次录音的字节数（供 Web 层分块读取）。 */
  recordingSize(): number {
    try {
      return fs.statSync(`${this.host.context.cacheDir}/${RecordingService.RECORDING_FILE}`).size
    } catch (err) {
      return 0
    }
  }

  /** 读取录音文件的某一段，返回 base64（单次最多 64 KB，避免桥参数过大）。 */
  readRecordingChunk(offset: number, length: number): string {
    const size = Math.max(0, Math.min(length, 65536))
    if (size === 0) {
      return ''
    }
    let fd = -1
    try {
      fd = fs.openSync(`${this.host.context.cacheDir}/${RecordingService.RECORDING_FILE}`,
        fs.OpenMode.READ_ONLY).fd
      const buf = new ArrayBuffer(size)
      const read = fs.readSync(fd, buf, { offset: offset, length: size })
      return new util.Base64Helper().encodeToStringSync(new Uint8Array(buf.slice(0, read)))
    } catch (err) {
      console.error(`readRecordingChunk failed: ${JSON.stringify(err)}`)
      return ''
    } finally {
      if (fd >= 0) {
        try {
          fs.closeSync(fd)
        } catch (err) {
          // 忽略
        }
      }
    }
  }

  /** 拼 44 字节标准 WAV 头 + PCM 数据。 */
  private static buildWav(chunks: ArrayBuffer[], total: number): ArrayBuffer {
    const header = new ArrayBuffer(44)
    const view = new DataView(header)
    const writeStr = (offset: number, text: string) => {
      for (let i = 0; i < text.length; i++) {
        view.setUint8(offset + i, text.charCodeAt(i))
      }
    }
    const sampleRate = RecordingService.RECORDING_SAMPLE_RATE
    const channels = 1
    const bits = 16
    writeStr(0, 'RIFF')
    view.setUint32(4, 36 + total, true)
    writeStr(8, 'WAVE')
    writeStr(12, 'fmt ')
    view.setUint32(16, 16, true)
    view.setUint16(20, 1, true)          // PCM
    view.setUint16(22, channels, true)
    view.setUint32(24, sampleRate, true)
    view.setUint32(28, sampleRate * channels * bits / 8, true)
    view.setUint16(32, channels * bits / 8, true)
    view.setUint16(34, bits, true)
    writeStr(36, 'data')
    view.setUint32(40, total, true)
    const out = new Uint8Array(44 + total)
    out.set(new Uint8Array(header), 0)
    let offset = 44
    for (const chunk of chunks) {
      out.set(new Uint8Array(chunk), offset)
      offset += chunk.byteLength
    }
    return out.buffer
  }

  recordingLevel(): number {
    return this.recordingLevelValue
  }
}
