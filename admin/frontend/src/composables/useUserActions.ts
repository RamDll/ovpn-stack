import { ovpn } from '@/api/ovpn'
import { useUsers } from './useUsers'
import { useToasts } from './useToasts'

/**
 * Мутации над пользователями: вызов API + тост об успехе + обновление списка.
 * При ошибке пробрасывает (ApiError) — модалка показывает её инлайн.
 */
export function useUserActions() {
  const { refresh } = useUsers()
  const toasts = useToasts()

  async function run<T>(fn: () => Promise<T>, okTitle: string): Promise<T> {
    const result = await fn()
    await refresh()
    toasts.success(okTitle)
    return result
  }

  return {
    create: (username: string, password: string) =>
      run(() => ovpn.createUser(username, password), `Пользователь ${username} создан`),

    changePassword: (username: string, password: string) =>
      run(() => ovpn.changePassword(username, password), `Пароль ${username} изменён`),

    rotate: (username: string, password: string) =>
      run(() => ovpn.rotateUser(username, password), `Сертификаты ${username} перевыпущены`),

    remove: (username: string) =>
      run(() => ovpn.deleteUser(username), `Пользователь ${username} удалён`),

    revoke: (username: string) =>
      run(() => ovpn.revokeUser(username), `Пользователь ${username} отозван`),

    unrevoke: (username: string) =>
      run(() => ovpn.unrevokeUser(username), `Пользователь ${username} восстановлен`),

    disconnect: (username: string) =>
      run(() => ovpn.disconnectUser(username), `Сессия ${username} разорвана`),

    applyCcd: (username: string, ccd: Parameters<typeof ovpn.applyCcd>[0]) =>
      run(() => ovpn.applyCcd(ccd), `Маршруты ${username} применены`),
  }
}
