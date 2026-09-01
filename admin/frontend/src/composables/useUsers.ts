import { ref, computed } from 'vue'
import { ovpn } from '@/api/ovpn'
import type { OpenvpnClient } from '@/api/types'

export type SortKey = 'name' | 'status'
export type SortDir = 'asc' | 'desc'

const users = ref<OpenvpnClient[]>([])
const loading = ref(false)
const error = ref<string | null>(null)
const search = ref('')
const filterOnline = ref(false)
const filterRevoked = ref(false)
const sortKey = ref<SortKey>('name')
const sortDir = ref<SortDir>('asc')

// порядок статусов при сортировке: онлайн → активен → истекает → отозван
const STATUS_ORDER: Record<string, number> = { Connected: 0, Active: 1, Expiring: 2, Revoked: 3, Expired: 3 }
function statusRank(u: OpenvpnClient): number {
  if (u.ConnectionStatus === 'Connected') return 0
  return STATUS_ORDER[u.AccountStatus] ?? 1
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

function toggleSort(key: SortKey) {
  if (sortKey.value === key) {
    sortDir.value = sortDir.value === 'asc' ? 'desc' : 'asc'
  } else {
    sortKey.value = key
    sortDir.value = 'asc'
  }
}

const filtered = computed(() => {
  const q = search.value.trim().toLowerCase()
  let rows = users.value.filter((u) => {
    if (filterOnline.value && u.ConnectionStatus !== 'Connected') return false
    if (filterRevoked.value && u.AccountStatus !== 'Revoked') return false
    if (!q) return true
    return u.Identity.toLowerCase().includes(q) || u.AccountStatus.toLowerCase().includes(q)
  })
  const dir = sortDir.value === 'asc' ? 1 : -1
  rows = [...rows].sort((a, b) => {
    if (sortKey.value === 'name') return dir * a.Identity.localeCompare(b.Identity)
    const r = statusRank(a) - statusRank(b)
    return dir * (r !== 0 ? r : a.Identity.localeCompare(b.Identity))
  })
  return rows
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
    filterOnline,
    filterRevoked,
    sortKey,
    sortDir,
    toggleSort,
    refresh,
    filtered,
    stats,
  }
}
