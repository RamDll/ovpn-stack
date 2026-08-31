import { apiGet, apiForm, apiJson } from './client'
import type { OpenvpnClient, ServerSettings, Ccd, ClientStatus } from './types'

export const ovpn = {
  listUsers: () => apiGet<OpenvpnClient[]>('api/users/list'),

  serverSettings: () => apiGet<ServerSettings>('api/server/settings'),

  lastSuccessfulSync: () => apiGet<string>('api/sync/last/successful'),

  createUser: (username: string, password: string) =>
    apiForm('api/user/create', { username, password }),

  changePassword: (username: string, password: string) =>
    apiForm('api/user/change-password', { username, password }),

  rotateUser: (username: string, password: string) =>
    apiForm('api/user/rotate', { username, password }),

  deleteUser: (username: string) => apiForm('api/user/delete', { username }),

  revokeUser: (username: string) => apiForm('api/user/revoke', { username }),

  unrevokeUser: (username: string) => apiForm('api/user/unrevoke', { username }),

  showConfig: (username: string) => apiForm<string>('api/user/config/show', { username }),

  getCcd: (username: string) => apiForm<Ccd>('api/user/ccd', { username }),

  applyCcd: (ccd: Ccd) => apiJson<string>('api/user/ccd/apply', ccd),

  disconnectUser: (username: string) => apiForm<string>('api/user/disconnect', { username }),

  userStatistic: (username: string) =>
    apiForm<ClientStatus[]>('api/user/statistic', { username }),
}
