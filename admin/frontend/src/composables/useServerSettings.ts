import { ref, computed } from 'vue'
import { ovpn } from '@/api/ovpn'
import type { OvpnModule, ServerRole } from '@/api/types'

const role = ref<ServerRole>('master')
const modules = ref<OvpnModule[]>([])
const lastSync = ref<string>('unknown')
const loaded = ref(false)

async function load() {
  const settings = await ovpn.serverSettings()
  role.value = settings.serverRole
  modules.value = settings.modules ?? []
  if (role.value === 'slave') {
    try {
      lastSync.value = await ovpn.lastSuccessfulSync()
    } catch {
      lastSync.value = 'unknown'
    }
  }
  loaded.value = true
}

export function useServerSettings() {
  return {
    role,
    modules,
    lastSync,
    loaded,
    load,
    isMaster: computed(() => role.value === 'master'),
    isSlave: computed(() => role.value === 'slave'),
    hasModule: (m: OvpnModule) => modules.value.includes(m),
  }
}
