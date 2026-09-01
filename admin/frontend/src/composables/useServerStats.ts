import { ref } from 'vue'
import { ovpn } from '@/api/ovpn'
import type { SystemStats } from '@/api/types'

const stats = ref<SystemStats | null>(null)

async function refresh() {
  try {
    stats.value = await ovpn.systemStats()
  } catch {
    /* тихо оставляем прежние значения — плитка не критична */
  }
}

export function useServerStats() {
  return { stats, refresh }
}
