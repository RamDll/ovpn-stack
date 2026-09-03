import { ref, computed } from 'vue'
import { ovpn } from '@/api/ovpn'

export interface Session {
  rx: number
  tx: number
  virtualAddress: string
  realAddress: string
  connectedSince: string
}

const byUser = ref<Record<string, Session>>({})

/** Собирает данные текущей сессии по подключённым пользователям
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
        let last: (typeof sessions)[number] | undefined
        for (const s of sessions ?? []) {
          rx += Number(s.BytesReceived) || 0
          tx += Number(s.BytesSent) || 0
          last = s
        }
        return [
          name,
          {
            rx,
            tx,
            virtualAddress: last?.VirtualAddress ?? '',
            realAddress: last?.RealAddress ?? '',
            connectedSince: last?.ConnectedSince || '',
          },
        ] as const
      } catch {
        return [name, { rx: 0, tx: 0, virtualAddress: '', realAddress: '', connectedSince: '' }] as const
      }
    }),
  )
  byUser.value = Object.fromEntries(pairs)
}

export function useTraffic() {
  const total = computed(() =>
    Object.values(byUser.value).reduce(
      (acc, s) => ({ rx: acc.rx + s.rx, tx: acc.tx + s.tx }),
      { rx: 0, tx: 0 },
    ),
  )
  return { byUser, total, refresh }
}
