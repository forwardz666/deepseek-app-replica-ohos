import { abilityAccessCtrl } from '@kit.AbilityKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { BridgeHost } from './BridgeHost'

/**
 * 历史对话导出：写入公共 Download/DeepSeek Replica/。
 *
 * 采用「打开文件 → 分块 base64 追加 → 关闭」的三段式协议，
 * Web 层负责串行推进并展示进度（android-export 事件）。
 */
export class HistoryExportService {
  private static readonly EXPORT_SUBDIR: string = 'DeepSeek Replica'
  private static readonly MAX_CHUNK: number = 65536

  private readonly host: BridgeHost
  private exportFd: number = -1

  constructor(host: BridgeHost) {
    this.host = host
  }

  /** 打开导出文件；返回 'ready' | 'error'。 */
  private openExportFile(rawName: string): string {
    const dir = this.host.pickDownloadDir()
    if (dir === null) {
      return 'error'
    }
    const name = this.host.sanitizeFileName(rawName)
    if (name === null) {
      return 'error'
    }
    try {
      const target = `${dir}/${HistoryExportService.EXPORT_SUBDIR}`
      if (!this.host.ensureDir(target)) {
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
      this.host.dispatchEvent('android-export', 'ready')
      return
    }
    const atManager = abilityAccessCtrl.createAtManager()
    atManager.requestPermissionsFromUser(this.host.context,
      ['ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY'])
      .then(() => {
        this.host.dispatchEvent('android-export', this.openExportFile(name))
      })
      .catch((err: BusinessError) => {
        console.error(`export permission request failed: ${JSON.stringify(err)}`)
        this.host.dispatchEvent('android-export', 'error')
      })
  }

  writeHistoryExport(bytes: string): boolean {
    if (this.exportFd < 0 || bytes.length > HistoryExportService.MAX_CHUNK) {
      return false
    }
    try {
      const data = BridgeHost.decodeBase64(bytes)
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
}
