<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import { useI18n } from 'vue-i18n'
import { ovpn } from '@/api/ovpn'
import { formatBytes } from '@/utils/format'
import ServerCard from './ServerCard.vue'
import type { Statistic, MonthBytes } from '@/api/types'

const { t } = useI18n()

const data = ref<Statistic | null>(null)
const loading = ref(true)
const error = ref('')

onMounted(async () => {
  try {
    data.value = await ovpn.statistic()
  } catch (e) {
    error.value = e instanceof Error ? e.message : String(e)
  } finally {
    loading.value = false
  }
})

const currentMonth = new Date().toISOString().slice(0, 7)

/** отсортированный список месяцев, встречающихся в данных (+ текущий) */
const months = computed(() => {
  const set = new Set<string>([currentMonth])
  for (const u of data.value?.monthly ?? []) for (const m of Object.keys(u.months)) set.add(m)
  return [...set].sort().slice(-12)
})

/** суммарный трафик по месяцам */
const byMonth = computed<Record<string, MonthBytes>>(() => {
  const acc: Record<string, MonthBytes> = {}
  for (const m of months.value) acc[m] = { rx: 0, tx: 0 }
  for (const u of data.value?.monthly ?? []) {
    for (const [m, v] of Object.entries(u.months)) {
      if (!acc[m]) continue
      acc[m].rx += v.rx
      acc[m].tx += v.tx
    }
  }
  return acc
})

const maxMonth = computed(() =>
  Math.max(1, ...months.value.map((m) => byMonth.value[m].rx + byMonth.value[m].tx)),
)

const totalThisMonth = computed(() => byMonth.value[currentMonth] ?? { rx: 0, tx: 0 })
const totalAllTime = computed(() => {
  let rx = 0
  let tx = 0
  for (const u of data.value?.monthly ?? [])
    for (const v of Object.values(u.months)) {
      rx += v.rx
      tx += v.tx
    }
  return { rx, tx }
})
const totalSession = computed(() => {
  let rx = 0
  let tx = 0
  for (const v of Object.values(data.value?.session ?? {})) {
    rx += v.rx
    tx += v.tx
  }
  return { rx, tx }
})

interface UserRow {
  user: string
  total: MonthBytes
  month: MonthBytes
  session: MonthBytes
}
const userRows = computed<UserRow[]>(() => {
  const rows: UserRow[] = []
  for (const u of data.value?.monthly ?? []) {
    let rx = 0
    let tx = 0
    for (const v of Object.values(u.months)) {
      rx += v.rx
      tx += v.tx
    }
    rows.push({
      user: u.user,
      total: { rx, tx },
      month: u.months[currentMonth] ?? { rx: 0, tx: 0 },
      session: data.value?.session[u.user] ?? { rx: 0, tx: 0 },
    })
  }
  return rows.sort((a, b) => b.total.rx + b.total.tx - (a.total.rx + a.total.tx))
})

const hasData = computed(
  () => (data.value?.monthly.length ?? 0) > 0 || totalSession.value.rx + totalSession.value.tx > 0,
)

function monthLabel(m: string) {
  const [y, mo] = m.split('-')
  return `${mo}.${y.slice(2)}`
}
</script>

<template>
  <div class="page-head">
    <h1>{{ t('stats.title') }}</h1>
  </div>

  <ServerCard />

  <p v-if="error" class="load-error">{{ t('stats.loadError') }}: {{ error }}</p>
  <p v-else-if="loading" class="muted">{{ t('common.loading') }}</p>

  <template v-else>
    <div class="metrics">
      <div class="metric">
        <div class="k">{{ t('stats.thisMonth') }}</div>
        <div class="v">{{ formatBytes(totalThisMonth.rx + totalThisMonth.tx) }}</div>
        <div class="d">&#8595;{{ formatBytes(totalThisMonth.rx) }} · &#8593;{{ formatBytes(totalThisMonth.tx) }}</div>
      </div>
      <div class="metric">
        <div class="k">{{ t('stats.allTime') }}</div>
        <div class="v">{{ formatBytes(totalAllTime.rx + totalAllTime.tx) }}</div>
        <div class="d">&#8595;{{ formatBytes(totalAllTime.rx) }} · &#8593;{{ formatBytes(totalAllTime.tx) }}</div>
      </div>
      <div class="metric">
        <div class="k">{{ t('stats.liveSessions') }}</div>
        <div class="v">{{ formatBytes(totalSession.rx + totalSession.tx) }}</div>
        <div class="d">&#8595;{{ formatBytes(totalSession.rx) }} · &#8593;{{ formatBytes(totalSession.tx) }}</div>
      </div>
    </div>

    <p v-if="!hasData" class="empty">{{ t('stats.empty') }}</p>

    <template v-else>
      <div class="card">
        <div class="card-head">{{ t('stats.byMonth') }}</div>
        <div class="chart">
          <div v-for="m in months" :key="m" class="col">
            <div class="bars">
              <span class="val">{{ formatBytes(byMonth[m].rx + byMonth[m].tx) }}</span>
              <span
                class="bar tx"
                :style="{ height: (100 * byMonth[m].tx) / maxMonth + '%' }"
              />
              <span
                class="bar rx"
                :style="{ height: (100 * byMonth[m].rx) / maxMonth + '%' }"
              />
            </div>
            <div class="lbl">{{ monthLabel(m) }}</div>
          </div>
        </div>
        <div class="legend">
          <span><i class="rx" /> {{ t('stats.received') }}</span>
          <span><i class="tx" /> {{ t('stats.sent') }}</span>
        </div>
      </div>

      <div class="card">
        <div class="card-head">{{ t('stats.byUser') }}</div>
        <div class="tbl-scroll">
          <table>
            <thead>
              <tr>
                <th>{{ t('stats.user') }}</th>
                <th>{{ t('stats.total') }}</th>
                <th>{{ t('stats.month') }}</th>
                <th>{{ t('stats.session') }}</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="r in userRows" :key="r.user">
                <td class="u">{{ r.user }}</td>
                <td class="n">{{ formatBytes(r.total.rx + r.total.tx) }}</td>
                <td class="n">{{ formatBytes(r.month.rx + r.month.tx) }}</td>
                <td class="n">
                  {{ r.session.rx + r.session.tx > 0 ? formatBytes(r.session.rx + r.session.tx) : '—' }}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </template>
  </template>
</template>

<style scoped>
.page-head {
  margin-bottom: 18px;
}
.page-head h1 {
  margin: 0;
  font-size: var(--fs-xl);
  font-weight: 600;
  letter-spacing: -0.01em;
}
.muted {
  color: var(--text-faint);
  font-family: var(--mono);
  font-size: var(--fs-sm);
}
.load-error {
  padding: 10px 14px;
  border-radius: var(--r-sm);
  background: var(--crit-soft);
  border: 1px solid var(--crit);
  color: var(--crit-text);
  font-size: var(--fs-sm);
}
.metrics {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--r);
  overflow: hidden;
  margin-bottom: 22px;
}
.metric {
  padding: 16px 18px;
  border-right: 1px solid var(--border-soft);
}
.metric:last-child {
  border-right: 0;
}
.metric .k {
  font-size: var(--fs-xs);
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: var(--text-faint);
  font-weight: 600;
  margin-bottom: 8px;
}
.metric .v {
  font-size: var(--fs-xl);
  font-weight: 600;
  font-family: var(--mono);
  letter-spacing: -0.01em;
}
.metric .d {
  font-size: var(--fs-xs);
  color: var(--text-faint);
  font-family: var(--mono);
  margin-top: 6px;
}
.empty {
  padding: 40px;
  text-align: center;
  color: var(--text-faint);
  font-family: var(--mono);
  font-size: var(--fs-sm);
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--r);
}
.card {
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--r);
  overflow: hidden;
  margin-bottom: 18px;
}
.card-head {
  padding: 12px 16px;
  border-bottom: 1px solid var(--border);
  font-size: var(--fs-xs);
  text-transform: uppercase;
  letter-spacing: 0.07em;
  color: var(--text-faint);
  font-weight: 600;
}
.chart {
  display: flex;
  align-items: flex-end;
  justify-content: center;
  gap: 10px;
  height: 190px;
  padding: 20px 16px 8px;
  overflow-x: auto;
}
.chart .col {
  flex: 1 1 0;
  min-width: 44px;
  max-width: 76px;
  display: flex;
  flex-direction: column;
  align-items: center;
  height: 100%;
}
.chart .bars {
  flex: 1;
  width: 60%;
  min-width: 22px;
  display: flex;
  flex-direction: column;
  justify-content: flex-end;
  position: relative;
}
.chart .val {
  position: absolute;
  top: -15px;
  left: 50%;
  transform: translateX(-50%);
  font-size: 9px;
  font-family: var(--mono);
  color: var(--text-faint);
  white-space: nowrap;
}
.chart .bar {
  display: block;
  width: 100%;
}
.chart .bar.rx {
  background: var(--accent);
  border-radius: 2px 2px 0 0;
}
.chart .bar.tx {
  background: var(--text-faint);
}
.chart .lbl {
  margin-top: 8px;
  font-size: 9.5px;
  font-family: var(--mono);
  color: var(--text-faint);
}
.legend {
  display: flex;
  gap: 18px;
  padding: 0 16px 14px;
  font-size: var(--fs-xs);
  color: var(--text-dim);
  font-family: var(--mono);
}
.legend i {
  display: inline-block;
  width: 10px;
  height: 10px;
  border-radius: 2px;
  margin-right: 5px;
  vertical-align: middle;
}
.legend i.rx {
  background: var(--accent);
}
.legend i.tx {
  background: var(--text-faint);
}
.tbl-scroll {
  overflow-x: auto;
}
table {
  width: 100%;
  border-collapse: collapse;
  font-size: var(--fs-sm);
  min-width: 460px;
}
th {
  text-align: left;
  padding: 10px 16px;
  font-size: var(--fs-xs);
  text-transform: uppercase;
  letter-spacing: 0.06em;
  color: var(--text-faint);
  font-weight: 600;
  border-bottom: 1px solid var(--border);
}
td {
  padding: 10px 16px;
  border-bottom: 1px solid var(--border-soft);
}
tr:last-child td {
  border-bottom: 0;
}
td.u {
  font-family: var(--mono);
  color: var(--text);
}
td.n {
  font-family: var(--mono);
  font-variant-numeric: tabular-nums;
  color: var(--text-dim);
}
@media (max-width: 560px) {
  .metrics {
    grid-template-columns: 1fr;
  }
}
</style>
