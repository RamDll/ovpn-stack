import { ref, computed } from 'vue'
import { ovpn } from '@/api/ovpn'
import type { OvpnModule } from '@/api/types'

const modules = ref<OvpnModule[]>([])
const caExpireDays = ref<number>(9999)
const serverCertExpireDays = ref<number>(9999)
const loaded = ref(false)

async function load() {
  const settings = await ovpn.serverSettings()
  modules.value = settings.modules ?? []
  caExpireDays.value = settings.caExpireDays ?? 9999
  serverCertExpireDays.value = settings.serverCertExpireDays ?? 9999
  loaded.value = true
}

export function useServerSettings() {
  return {
    modules,
    caExpireDays,
    serverCertExpireDays,
    loaded,
    load,
    hasModule: (m: OvpnModule) => modules.value.includes(m),
    /** минимальный запас по серверным сертификатам, дней */
    minCertDays: computed(() => Math.min(caExpireDays.value, serverCertExpireDays.value)),
  }
}
