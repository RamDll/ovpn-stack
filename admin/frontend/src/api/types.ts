export type AccountStatus = 'Active' | 'Revoked' | 'Expired'
export type ConnectionStatus = 'Connected' | 'Disconnected' | ''
export type ServerRole = 'master' | 'slave'
export type OvpnModule = 'core' | 'ccd' | (string & {})

/** Строка ответа `api/users/list`. */
export interface OpenvpnClient {
  Identity: string
  AccountStatus: AccountStatus
  ExpirationDate: string
  RevocationDate: string
  ConnectionStatus: ConnectionStatus
  Connections: number
  /** unix-время последнего появления онлайн; 0 — не видели */
  LastSeen: number
}

/** Ответ `api/server/settings`. */
export interface ServerSettings {
  serverRole: ServerRole
  modules: OvpnModule[]
  caExpireDays: number
  serverCertExpireDays: number
}

export interface CcdRoute {
  Address: string
  Mask: string
  Description: string
}

/** Ответ `api/user/ccd`, тело `api/user/ccd/apply`. */
export interface Ccd {
  User: string
  ClientAddress: string
  CustomRoutes: CcdRoute[]
}

/** Ответ `api/server/stats` — состояние хоста. */
export interface SystemStats {
  hostname: string
  /** loadavg за 1 минуту */
  load: number
  /** число ядер CPU */
  cpu: number
  memTotal: number
  memUsed: number
  /** суммарный трафик всех клиентов за текущие сутки (UTC), байт */
  trafficTodayRx: number
  trafficTodayTx: number
}

export interface MonthBytes {
  rx: number
  tx: number
}

/** Ответ `api/statistic`. */
export interface Statistic {
  monthly: { user: string; months: Record<string, MonthBytes> }[]
  session: Record<string, MonthBytes>
}

/** Элемент ответа `api/user/statistic` — активная сессия клиента. */
export interface ClientStatus {
  CommonName: string
  RealAddress: string
  BytesReceived: string
  BytesSent: string
  ConnectedSince: string
  VirtualAddress: string
  ConnectedSinceFormatted: string
  LastRefFormatted: string
}
