export type AccountStatus = 'Active' | 'Revoked' | 'Expired'
export type ConnectionStatus = 'Connected' | 'Disconnected' | ''
export type ServerRole = 'master' | 'slave'
export type OvpnModule = 'core' | 'ccd' | 'passwdAuth' | (string & {})

/** Строка ответа `api/users/list`. */
export interface OpenvpnClient {
  Identity: string
  AccountStatus: AccountStatus
  ExpirationDate: string
  RevocationDate: string
  ConnectionStatus: ConnectionStatus
  Connections: number
}

/** Ответ `api/server/settings`. */
export interface ServerSettings {
  serverRole: ServerRole
  modules: OvpnModule[]
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
