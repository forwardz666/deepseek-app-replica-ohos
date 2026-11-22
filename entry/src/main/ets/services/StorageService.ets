import { preferences } from '@kit.ArkData'
import { BridgeHost } from './BridgeHost'

/**
 * 本机键值存储：API Key、聊天配置、账号资料。
 *
 * 目前是明文 preferences（原实现即如此），后续若升级 HUKS 加密只需改这里。
 * 所有读取失败都收敛成 null，写失败返回 false —— 桥方法不能把异常抛回 Web。
 */
export class StorageService {
  private readonly host: BridgeHost
  private prefs: preferences.Preferences | null = null

  constructor(host: BridgeHost) {
    this.host = host
    this.initPrefs()
  }

  private initPrefs(): void {
    try {
      this.prefs = preferences.getPreferencesSync(this.host.context, { name: 'dsreplica_store' })
    } catch (err) {
      console.error(`initPrefs failed: ${JSON.stringify(err)}`)
      this.prefs = null
    }
  }

  private read(key: string): string | null {
    if (this.prefs === null) {
      return null
    }
    try {
      const v = this.prefs.getSync(key, '') as string
      return v === '' ? null : v
    } catch (err) {
      console.error(`read ${key} failed: ${JSON.stringify(err)}`)
      return null
    }
  }

  private write(key: string, value: string | null): boolean {
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
      console.error(`write ${key} failed: ${JSON.stringify(err)}`)
      return false
    }
  }

  readApiKey(): string | null {
    return this.read('api_key')
  }

  writeApiKey(value: string | null): boolean {
    return this.write('api_key', value)
  }

  readChatConfig(): string | null {
    return this.read('chat_config')
  }

  writeChatConfig(value: string | null): boolean {
    return this.write('chat_config', value)
  }

  readAccountProfile(): string | null {
    return this.read('account_profile')
  }

  writeAccountProfile(value: string | null): boolean {
    return this.write('account_profile', value)
  }
}
