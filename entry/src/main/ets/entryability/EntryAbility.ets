import { AbilityConstant, ConfigurationConstant, UIAbility, Want, abilityAccessCtrl, Permissions } from '@kit.AbilityKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { window } from '@kit.ArkUI'
import display from '@ohos.display'
import { hilog } from '@kit.PerformanceAnalysisKit'

const TAG = 'EntryAbility'

export default class EntryAbility extends UIAbility {
  /** avoid area 返回物理 px，Web 层 CSS px = vp，按 Android /density 语义换算 */
  private toVp(px: number): number {
    const d = display.getDefaultDisplaySync().densityPixels
    return d > 0 ? px / d : px
  }

  onCreate(_want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0000, TAG, 'onCreate')
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // 全屏沉浸式：Web 层通过桥读取 insets 自行避让（对齐 Android 版 adjustResize + fitsSystemWindows 语义）
    try {
      const mainWin = windowStage.getMainWindowSync()
      mainWin.setWindowLayoutFullScreen(true)
      // 窗口自身底色跟随深浅色，且与 Web 深色主题背景（rgb(21,21,23)）一致：
      // 启动图消失到 Web 首帧绘制之间的间隙若沿用系统默认白底，深色下会闪白。
      const dark = this.context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK
      try {
        mainWin.setWindowBackgroundColor(dark ? '#151517' : '#FFFFFF')
      } catch (err) {
        hilog.error(0x0000, TAG, `setWindowBackgroundColor failed: ${JSON.stringify(err)}`)
      }

      const systemArea = mainWin.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM)
      const navArea = mainWin.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR)
      const keyboardArea = mainWin.getWindowAvoidArea(window.AvoidAreaType.TYPE_KEYBOARD)
      AppStorage.setOrCreate<number>('statusInset', this.toVp(systemArea.topRect.height))
      AppStorage.setOrCreate<number>('buttonNavigationInset', this.toVp(navArea.bottomRect.height))
      AppStorage.setOrCreate<number>('keyboardInset', this.toVp(keyboardArea.bottomRect.height))
      hilog.info(0x0000, TAG,
        `insets status=${systemArea.topRect.height} nav=${navArea.bottomRect.height} kb=${keyboardArea.bottomRect.height}`)

      // 键盘/避让区变化 → 通知 Index 派发 data-keyboard 状态
      mainWin.on('avoidAreaChange', (data) => {
        if (data.type === window.AvoidAreaType.TYPE_KEYBOARD) {
          AppStorage.setOrCreate<number>('keyboardInset', data.area.bottomRect.height)
          AppStorage.setOrCreate<boolean>('keyboardVisible', data.area.bottomRect.height > 0)
        } else if (data.type === window.AvoidAreaType.TYPE_SYSTEM) {
          AppStorage.setOrCreate<number>('statusInset', this.toVp(data.area.topRect.height))
        } else if (data.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
          AppStorage.setOrCreate<number>('buttonNavigationInset', this.toVp(data.area.bottomRect.height))
        }
      })
    } catch (err) {
      hilog.error(0x0000, TAG, `window init failed: ${JSON.stringify(err)}`)
    }

    // 系统字体缩放（对应 Android systemFontScale 桥方法的数据源）
    const fontScale = this.context.config.fontSizeScale
    if (fontScale !== undefined) {
      AppStorage.setOrCreate<number>('systemFontScale', fontScale)
    }

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(0x0000, TAG, `loadContent failed: ${JSON.stringify(err)}`)
        return
      }
      hilog.info(0x0000, TAG, 'loadContent ok')

      // 首次启动申请 Download 目录读写（导出历史对话到用户可见目录）
      const perms: Array<Permissions> = ['ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY']
      try {
        abilityAccessCtrl.createAtManager()
          .requestPermissionsFromUser(this.context, perms)
          .then((result) => {
            hilog.info(0x0000, TAG, `download permission authResults: ${result.authResults.join(',')}`)
          })
          .catch((err: BusinessError) => {
            hilog.error(0x0000, TAG, `permission request failed: ${JSON.stringify(err)}`)
          })
      } catch (e) {
        hilog.error(0x0000, TAG, `permission request error: ${JSON.stringify(e)}`)
      }
    })
  }

  onDestroy(): void {
    hilog.info(0x0000, TAG, 'onDestroy')
  }
}
