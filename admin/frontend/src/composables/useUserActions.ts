import { ovpn } from '@/api/ovpn'
import { useUsers } from './useUsers'
import { useToasts } from './useToasts'
import { t } from '@/i18n'

/**
 * Мутации над пользователями: вызов API + тост об успехе + обновление списка.
 * При ошибке пробрасывает (ApiError) — модалка показывает её инлайн.
 */
export function useUserActions() {
  const { refresh } = useUsers()
  const toasts = useToasts()

  async function run<T>(fn: () => Promise<T>, okKey: string, name: string): Promise<T> {
    const result = await fn()
    await refresh()
    toasts.success(t(okKey, { name }))
    return result
  }

  return {
    create: (username: string, password: string, expireDays = 0) =>
      run(() => ovpn.createUser(username, password, expireDays), 'toast.userCreated', username),

    changePassword: (username: string, password: string) =>
      run(() => ovpn.changePassword(username, password), 'toast.passwordChanged', username),

    rotate: (username: string, password: string, expireDays = 0) =>
      run(() => ovpn.rotateUser(username, password, expireDays), 'toast.certRotated', username),

    extend: (username: string, expireDays = 0) =>
      run(() => ovpn.extendUser(username, expireDays), 'toast.certExtended', username),

    remove: (username: string) =>
      run(() => ovpn.deleteUser(username), 'toast.userDeleted', username),

    revoke: (username: string) =>
      run(() => ovpn.revokeUser(username), 'toast.userRevoked', username),

    unrevoke: (username: string) =>
      run(() => ovpn.unrevokeUser(username), 'toast.userUnrevoked', username),

    disconnect: (username: string) =>
      run(() => ovpn.disconnectUser(username), 'toast.sessionDropped', username),

    applyCcd: (username: string, ccd: Parameters<typeof ovpn.applyCcd>[0]) =>
      run(() => ovpn.applyCcd(ccd), 'toast.ccdApplied', username),
  }
}
