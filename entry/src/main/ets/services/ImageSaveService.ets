import { picker, fileUri } from '@kit.CoreFileKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { photoAccessHelper } from '@kit.MediaLibraryKit'
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit'
import { util } from '@kit.ArkTS'
import { BridgeHost } from './BridgeHost'

/**
 * 图片保存：把 Web 传来的分块写入沙箱临时文件，再交给系统相册。
 *
 * Web 侧协议（三段式，与 Android 版一致）：
 *   beginImageSave(name, mime) → writeImageSave(base64)* → finishImageSave(keep)
 * 结果统一经 android-image-saved 事件回传：ok / cancel / error[:原因]。
 *
 * 入相册的三条通道（按可靠性排序，任何一条成功即返回）：
 *   1. photoPicker.save —— 系统「保存到图片」页，独立 Ability，最可靠
 *   2. showAssetsCreationDialog —— 「保存到相册」确认框
 *   3. createImageAssetRequest + applyChanges —— 免弹窗直写（多数机型 201）
 * 2in1 在三条都不可用时退回下载目录；其余设备报明确错误码。
 */
export class ImageSaveService {
  private readonly host: BridgeHost

  constructor(host: BridgeHost) {
    this.host = host
  }

  private imageFd: number = -1
  private imagePath: string | null = null
  private imageTitle: string | null = null
  /** 最近一次图库通道的错误码，用于最终失败时给出可定位的原因 */
  private lastGalleryError: number | undefined = undefined
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
      if (ImageSaveService.IMAGE_NAME_EXTS.includes(e)) {
        return e === 'jpeg' ? 'jpg' : e
      }
    }
    // 最终兜底：按 jpeg 处理（相册侧按魔数识别，扩展名不匹配也能显示）
    return 'jpg'
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
    const sanitized = this.host.sanitizeFileName(tempName)
    if (sanitized === null) {
      console.error(`beginImageSave: sanitize failed for "${tempName}"`)
      return false
    }
    try {
      const dir = `${this.host.context.cacheDir}/${ImageSaveService.IMAGE_SAVES_DIR}`
      if (!this.host.ensureDir(dir)) {
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
      this.host.toast('保存失败：图片数据为空', 'Failed: empty image data')
      this.host.dispatchEvent('android-image-saved', 'error:empty')
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
    const dir = this.host.pickDownloadDir()
    if (dir === null) {
      this.host.toast('保存失败：无法访问下载目录', 'Failed: no download dir')
      this.host.dispatchEvent('android-image-saved', 'error:download')
      this.removeTempImage(path)
      return
    }
    const target = `${dir}/${ImageSaveService.IMAGE_PC_SUBDIR}`
    if (!this.host.ensureDir(target)) {
      this.host.toast('保存失败：无法创建目录', 'Failed: cannot create dir')
      this.host.dispatchEvent('android-image-saved', 'error:download')
      this.removeTempImage(path)
      return
    }
    try {
      fs.copyFileSync(path, `${target}/${title}`)
      this.host.toast('已保存到「下载/DeepSeek Replica/Images」', 'Saved to Downloads')
      this.host.dispatchEvent('android-image-saved', 'ok')
      this.removeTempImage(path)
    } catch (err) {
      console.error(`saveToDownloadForPc failed: ${JSON.stringify(err)}`)
      this.host.toast('保存失败', 'Failed to save')
      this.host.dispatchEvent('android-image-saved', 'error:download')
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
   * 通道可靠性差异很大，因此用**有序尝试链**，而不是互相回退：
   *   - 手机 / 平板：SaveButton 安全控件（唯一能拿到「保存到相册」临时授权的
   *                  方式，必须由用户亲手点）→ showAssetsCreationDialog
   *                  → PhotoViewPicker.save → createImageAssetRequest
   *   - 2in1：PhotoViewPicker.save → showAssetsCreationDialog → 直写 → 下载目录
   *
   * 为什么 SaveButton 必须放第一位：API 18 起 picker.PhotoViewPicker.save 已废弃，
   * photoAccessHelper 的写入接口对三方应用要求 WRITE_IMAGEVIDEO（系统级，拿不到），
   * 真机上这三条老通道全部报 201/14000011 —— 用户看到的就是「无法保存图片」。
   * 安全控件点击时系统会下发一次性临时授权，只有拿到它才能真正落库。
   *
   * 为什么必须是有序链：早先的实现让两个通道互相调用，任一失败就跳对方，
   * 在两条都不可用的机型上会无限循环，界面既不弹窗也不返回 —— 用户看到的
   * 就是「点了保存没有任何作用」。
   */
  private saveToGallery(title: string, path: string, allowDownloadFallback: boolean): void {
    this.host.toast('正在保存到相册…', 'Saving to gallery…')
    const steps: string[] = deviceInfo.deviceType === '2in1'
      ? [ImageSaveService.STEP_PICKER, ImageSaveService.STEP_DIALOG,
        ImageSaveService.STEP_CREATE, ImageSaveService.STEP_SAFE_BUTTON]
      : [ImageSaveService.STEP_SAFE_BUTTON, ImageSaveService.STEP_DIALOG,
        ImageSaveService.STEP_PICKER, ImageSaveService.STEP_CREATE]
    this.runSaveStep(steps, 0, title, path, allowDownloadFallback)
  }

  private static readonly STEP_SAFE_BUTTON: string = 'safeButton'
  private static readonly STEP_DIALOG: string = 'dialog'
  private static readonly STEP_PICKER: string = 'picker'
  private static readonly STEP_CREATE: string = 'create'

  /** 依次尝试通道；只有全部失败才报错。 */
  private runSaveStep(steps: string[], index: number, title: string, path: string,
    allowDownloadFallback: boolean): void {
    if (index >= steps.length) {
      this.galleryUnavailable(title, path, allowDownloadFallback)
      return
    }
    const step = steps[index]
    const next = () => this.runSaveStep(steps, index + 1, title, path, allowDownloadFallback)
    if (step === ImageSaveService.STEP_SAFE_BUTTON) {
      this.saveViaSafeButton(title, path, next)
    } else if (step === ImageSaveService.STEP_DIALOG) {
      this.saveViaCreationDialog(title, path, next)
    } else if (step === ImageSaveService.STEP_PICKER) {
      this.saveViaPickerPage(title, path, next)
    } else {
      this.saveViaChangeRequest(title, path, next)
    }
  }

  /**
   * 通道：界面上的 SaveButton 安全控件（系统唯一认可的三方相册写入授权）。
   *
   * 桥方法由 ArkWeb 同步调用，不能在这里直接弹 UI；把请求交给 Index 页面的
   * 覆盖层，用户点一下安全控件后系统下发临时授权，再由 onAuthorized 回填。
   * 页面没接（返回 false）或用户取消 → 交给 next()，不在这里判失败。
   */
  private saveViaSafeButton(title: string, path: string, next: () => void): void {
    const accepted = this.host.requestGallerySave(title, path)
    if (!accepted) {
      next()
    }
  }

  /** 安全控件拿到临时授权后由页面回调，真正把文件写进相册。 */
  commitSafeButtonSave(title: string, path: string, authorized: boolean): void {
    if (!authorized) {
      this.host.toast('已取消保存', 'Save cancelled')
      this.host.dispatchEvent('android-image-saved', 'cancel')
      this.removeTempImage(path)
      return
    }
    this.writeAsset(title, path)
  }

  /**
   * 用已获得的临时授权创建媒体资产并写入字节。
   * 授权只在该次点击的调用栈内有效，因此必须同步开始创建。
   */
  private writeAsset(title: string, path: string): void {
    const dot = title.lastIndexOf('.')
    const baseName = dot > 0 ? title.substring(0, dot) : title
    const ext = dot > 0 ? title.substring(dot + 1).toLowerCase() : 'jpg'
    let helper: photoAccessHelper.PhotoAccessHelper
    try {
      helper = photoAccessHelper.getPhotoAccessHelper(this.host.context)
    } catch (err) {
      console.error(`writeAsset helper failed: ${JSON.stringify(err)}`)
      this.galleryUnavailable(title, path, false)
      return
    }
    helper.createAsset(photoAccessHelper.PhotoType.IMAGE, ext,
      { title: baseName, subtype: photoAccessHelper.PhotoSubtype.DEFAULT })
      .then((uri: string) => {
        if (this.copyIntoUri(path, uri)) {
          this.host.toast('已保存到相册', 'Saved to photos')
          this.host.dispatchEvent('android-image-saved', 'ok')
        } else {
          this.host.toast('保存失败：无法写入相册', 'Failed to write to gallery')
          this.host.dispatchEvent('android-image-saved', 'error:write')
        }
        this.removeTempImage(path)
      })
      .catch((err: BusinessError) => {
        console.error(`createAsset failed: ${JSON.stringify(err)}`)
        this.lastGalleryError = err.code
        this.host.toast(`保存失败：相册不可用（${err.code}）`, `Gallery unavailable (${err.code})`)
        this.host.dispatchEvent('android-image-saved', `error:${err.code}`)
        this.removeTempImage(path)
      })
  }

  /**
   * 通道：系统「保存到图片」页（picker.PhotoViewPicker.save）。
   *
   * 必须用带 context 的构造函数 —— 无参构造是 @deprecated 的「可能失败」用法，
   * 在部分版本上直接抛异常，界面就完全出不来。
   *
   * 失败一律交给 next()（有序链的下一条），绝不回调其它通道，避免互相调用成环。
   */
  private saveViaPickerPage(title: string, path: string, next: () => void): void {
    const self = this
    let photoPicker: picker.PhotoViewPicker
    try {
      photoPicker = new picker.PhotoViewPicker(this.host.context)
    } catch (err) {
      console.error(`PhotoViewPicker unavailable: ${JSON.stringify(err)}`)
      next()
      return
    }
    const options: picker.PhotoSaveOptions = { newFileNames: [title] }
    try {
      photoPicker.save(options).then((uris: Array<string>) => {
        if (uris.length === 0) {
          // 系统保存页返回空 = 用户主动取消，不算失败，不再尝试其它通道。
          self.host.toast('已取消保存', 'Save cancelled')
          self.host.dispatchEvent('android-image-saved', 'cancel')
          self.removeTempImage(path)
          return
        }
        if (self.copyIntoUri(path, uris[0])) {
          self.host.toast('已保存到相册', 'Saved to photos')
          self.host.dispatchEvent('android-image-saved', 'ok')
          self.removeTempImage(path)
        } else {
          // 部分机型返回的媒体 URI 不允许应用 openSync 写入。
          console.warn('PhotoViewPicker returned a non-writable URI, trying next channel')
          next()
        }
      }).catch((err: BusinessError) => {
        console.error(`PhotoViewPicker.save failed: ${JSON.stringify(err)}`)
        next()
      })
    } catch (err) {
      console.error(`PhotoViewPicker.save threw: ${JSON.stringify(err)}`)
      next()
    }
  }

  /** 把沙箱文件分块写入 picker 返回的可写 uri。 */
  private copyIntoUri(srcPath: string, dstUri: string): boolean {
    let srcFd = -1
    let dstFd = -1
    let copied = false
    try {
      srcFd = fs.openSync(srcPath, fs.OpenMode.READ_ONLY).fd
      dstFd = fs.openSync(dstUri, fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC).fd
      const buf = new ArrayBuffer(64 * 1024)
      let read = fs.readSync(srcFd, buf)
      while (read > 0) {
        fs.writeSync(dstFd, buf.slice(0, read))
        read = fs.readSync(srcFd, buf)
      }
      copied = true
    } catch (err) {
      console.error(`copyIntoUri failed: ${JSON.stringify(err)}`)
      return false
    } finally {
      // fsync / close 的异常只记录，不能把「已经写完」的写入判成失败 ——
      // 否则图库里已有图片，界面却报「无法保存」。
      if (dstFd >= 0) {
        try {
          fs.fsyncSync(dstFd)
        } catch (err) {
          console.warn(`fsync picked uri failed: ${JSON.stringify(err)}`)
        }
      }
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
    return copied
  }

  /**
   * 通道：showAssetsCreationDialog 直接弹「保存到相册」确认框（免权限）。
   *
   * PhotoCreationConfig.title 必须是**不含扩展名**的资产名，扩展名单独经
   * fileNameExtension 提供。传 'a.png' + 'png' 会让系统创建资产失败。
   *
   * 空数组有两种含义：用户取消，或该形态没有媒体库 UI 服务。两者无法区分，
   * 因此继续走下一条通道 —— 但绝不回头调用已经试过的通道。
   */
  private saveViaCreationDialog(title: string, path: string, next: () => void): void {
    const self = this
    const dot = title.lastIndexOf('.')
    const baseName = dot > 0 ? title.substring(0, dot) : title
    const ext = dot > 0 ? title.substring(dot + 1).toLowerCase() : 'jpg'
    let helper: photoAccessHelper.PhotoAccessHelper | null = null
    let srcUri = ''
    try {
      helper = photoAccessHelper.getPhotoAccessHelper(this.host.context)
      srcUri = fileUri.getUriFromPath(path)
    } catch (err) {
      console.error(`saveViaCreationDialog prep failed: ${JSON.stringify(err)}`)
    }
    if (helper === null || srcUri === '') {
      next()
      return
    }
    const h: photoAccessHelper.PhotoAccessHelper = helper
    const config: photoAccessHelper.PhotoCreationConfig = {
      title: baseName,
      fileNameExtension: ext,
      photoType: photoAccessHelper.PhotoType.IMAGE,
      subtype: photoAccessHelper.PhotoSubtype.DEFAULT
    }
    // 桥方法由 ArkWeb 的 JS 线程同步调用，直接拉起系统弹窗会被静默丢弃，
    // 用 setTimeout 切到下一轮事件循环再弹。
    setTimeout(() => {
      let settled = false
      const startedAt = Date.now()
      const fallback = () => {
        if (settled) {
          return
        }
        settled = true
        next()
      }
      try {
        h.showAssetsCreationDialog([srcUri], [config]).then((uris: Array<string>) => {
          if (settled) {
            return
          }
          settled = true
          const elapsed = Date.now() - startedAt
          console.info(`showAssetsCreationDialog result: ${JSON.stringify(uris)} in ${elapsed}ms`)
          if (uris.length > 0) {
            self.host.toast('已保存到相册', 'Saved to photos')
            self.host.dispatchEvent('android-image-saved', 'ok')
            self.removeTempImage(path)
            return
          }
          // 空数组有两种含义，用耗时区分：
          //   - 立刻返回（<500ms）：用户不可能这么快确认，说明该形态没有媒体库
          //     确认框（返回空即「接口不可用」），继续下一条通道。
          //   - 停留一段时间后返回：用户自己在确认框里取消了，按取消处理，
          //     不再弹出下一个界面。
          if (elapsed < 500) {
            console.warn('showAssetsCreationDialog returned empty immediately, treating as unavailable')
            next()
            return
          }
          self.host.toast('已取消保存', 'Save cancelled')
          self.host.dispatchEvent('android-image-saved', 'cancel')
          self.removeTempImage(path)
        }).catch((err: BusinessError) => {
          console.error(`showAssetsCreationDialog failed: ${JSON.stringify(err)}`)
          fallback()
        })
      } catch (err) {
        console.error(`showAssetsCreationDialog threw: ${JSON.stringify(err)}`)
        fallback()
      }
    }, 0)
  }

  /**
   * 通道：createImageAssetRequest + applyChanges。
   * 需要 WRITE_IMAGEVIDEO，普通应用通常拿不到（201），但成本极低，留作兜底。
   */
  private saveViaChangeRequest(title: string, path: string, next: () => void): void {
    const self = this
    const dot = title.lastIndexOf('.')
    const baseName = dot > 0 ? title.substring(0, dot) : title
    try {
      const helper = photoAccessHelper.getPhotoAccessHelper(this.host.context)
      const srcUri = fileUri.getUriFromPath(path)
      const request = photoAccessHelper.MediaAssetChangeRequest.createImageAssetRequest(
        this.host.context, srcUri)
      request.setTitle(baseName)
      helper.applyChanges(request).then(() => {
        console.info('applyChanges ok')
        self.host.toast('已保存到相册', 'Saved to photos')
        self.host.dispatchEvent('android-image-saved', 'ok')
        self.removeTempImage(path)
      }).catch((err: BusinessError) => {
        console.error(`applyChanges failed: ${JSON.stringify(err)}`)
        self.lastGalleryError = err.code
        next()
      })
    } catch (err) {
      console.error(`createImageAssetRequest failed: ${JSON.stringify(err)}`)
      this.lastGalleryError = (err as BusinessError).code
      next()
    }
  }

  /** 全部通道都失败：2in1 退回下载目录（用户可见），其余明确报错。 */
  private galleryUnavailable(title: string, path: string, allowDownloadFallback: boolean,
    code?: number): void {
    if (allowDownloadFallback) {
      this.saveToDownloadForPc(title, path)
      return
    }
    const reason = code === undefined ? this.lastGalleryError : code
    const suffix = reason === undefined ? '' : `（${reason}）`
    const suffixEn = reason === undefined ? '' : ` (${reason})`
    this.host.toast(`保存失败：相册不可用${suffix}`, `Gallery unavailable${suffixEn}`)
    this.host.dispatchEvent('android-image-saved', reason === undefined ? 'error' : `error:${reason}`)
    this.removeTempImage(path)
  }
}
