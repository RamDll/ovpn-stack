import { ref, computed } from 'vue'
import { ovpn } from '@/api/ovpn'
import type { OpenvpnClient } from '@/api/types'

const STORAGE_KEY = 'ovpn-admin.hideRevoked'

const users = ref<OpenvpnClient[]>([])
const loading = ref(false)
const error = ref<string | null>(null)
const search = ref('')
const hideRevoked = ref(readHideRevoked())

function readHideRevoked(): boolean {
  try {
    return localStorage.getItem(STORAGE_KEY) === 'true'
  } catch {
    return false
  }
}

function setHideRevoked(v: boolean) {
  hideRevoked.value = v
  try {
    localStorage.setItem(STORAGE_KEY, String(v))
  } catch {
    /* private mode — ignore */
  }
}

async function refresh(opts: { silent?: boolean } = {}) {
  if (!opts.silent) loading.value = true
  error.value = null
  try {
    const list = await ovpn.listUsers()
    users.value = Array.isArray(list) ? list : []
  } catch (e) {
    error.value = e instanceof Error ? e.message : String(e)
    if (!opts.silent) users.value = []
  } finally {
    loading.value = false
  }
}

const filtered = computed(() => {
  const q = search.value.trim().toLowerCase()
  return users.value.filter((u) => {
    if (hideRevoked.value && u.AccountStatus !== 'Active') return false
    if (!q) return true
    return (
      u.Identity.toLowerCase().includes(q) ||
      u.AccountStatus.toLowerCase().includes(q)
    )
  })
})

const stats = computed(() => {
  const total = users.value.length
  let connected = 0
  let revoked = 0
  let expired = 0
  for (const u of users.value) {
    if (u.ConnectionStatus === 'Connected') connected++
    if (u.AccountStatus === 'Revoked') revoked++
    if (u.AccountStatus === 'Expired') expired++
  }
  return { total, connected, revoked, expired }
})

export function useUsers() {
  return {
    users,
    loading,
    error,
    search,
    hideRevoked,
    setHideRevoked,
    refresh,
    filtered,
    stats,
  }
}
