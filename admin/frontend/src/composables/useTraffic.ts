import { ref, computed } from 'vue'
import { ovpn } from '@/api/ovpn'

export interface Traffic {
  rx: number
  tx: number
}

const byUser = ref<Record<string, Traffic>>({})

/** Собирает трафик текущей сессии по подключённым пользователям
 *  (api/user/statistic — по одному запросу на юзера, их обычно мало). */
async function refresh(connectedUsernames: string[]) {
  if (connectedUsernames.length === 0) {
    byUser.value = {}
    return
  }
  const pairs = await Promise.all(
    connectedUsernames.map(async (name) => {
      try {
        const sessions = await ovpn.userStatistic(name)
        let rx = 0
        let tx = 0
        for (const s of sessions ?? []) {
          rx += Number(s.BytesReceived) || 0
          tx += Number(s.BytesSent) || 0
        }
        return [name, { rx, tx }] as const
      } catch {
        return [name, { rx: 0, tx: 0 }] as const
      }
    }),
  )
  byUser.value = Object.fromEntries(pairs)
}

export function useTraffic() {
  const total = computed(() =>
    Object.values(byUser.value).reduce(
      (acc, t) => ({ rx: acc.rx + t.rx, tx: acc.tx + t.tx }),
      { rx: 0, tx: 0 },
    ),
  )
  return { byUser, total, refresh }
}
