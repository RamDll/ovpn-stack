<script setup lang="ts">
import { computed } from 'vue'
import { useI18n } from 'vue-i18n'
import { formatBytes } from '@/utils/format'
import type { SystemStats } from '@/api/types'

const props = defineProps<{
  connected: number
  traffic: string
  sys: SystemStats | null
}>()
const { t } = useI18n()

const cpuPct = computed(() => {
  const s = props.sys
  if (!s || !s.cpu) return null
  return Math.round((s.load / s.cpu) * 100)
})
const ramLine = computed(() => {
  const s = props.sys
  if (!s || !s.memTotal) return ''
  return `${formatBytes(s.memUsed)} / ${formatBytes(s.memTotal)}`
})
const cpuClass = computed(() =>
  cpuPct.value !== null && cpuPct.value >= 90 ? 'hot' : '',
)
</script>

<template>
  <div class="metrics">
    <div class="metric">
      <div class="k">{{ t('metrics.connectedNow') }}</div>
      <div class="v u-num">{{ connected }}</div>
    </div>

    <div class="metric">
      <div class="k">{{ t('metrics.server') }}</div>
      <div class="v host" :title="sys?.hostname">{{ sys?.hostname || '—' }}</div>
      <div v-if="sys" class="delta">
        <span :class="cpuClass">{{ t('metrics.cpu') }} {{ cpuPct }}%</span>
        <span class="sep">·</span>
        <span>{{ t('metrics.ram') }} {{ ramLine }}</span>
      </div>
    </div>

    <div class="metric">
      <div class="k">{{ t('metrics.traffic') }}</div>
      <div class="v traffic-v">{{ traffic }}</div>
    </div>
  </div>
</template>

<style scoped>
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
  min-width: 0;
}
.metric:last-child {
  border-right: 0;
}
.k {
  font-size: var(--fs-xs);
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: var(--text-faint);
  font-weight: 600;
  margin-bottom: 8px;
}
.v {
  font-size: var(--fs-2xl);
  font-weight: 600;
  letter-spacing: -0.02em;
  line-height: 1;
}
.delta {
  font-size: var(--fs-xs);
  color: var(--text-faint);
  margin-top: 7px;
  font-family: var(--mono);
}
.delta .sep {
  margin: 0 5px;
  opacity: 0.5;
}
.delta .hot {
  color: var(--crit);
}
.host {
  font-size: var(--fs-base);
  font-family: var(--mono);
  font-weight: 600;
  letter-spacing: -0.01em;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.traffic-v {
  font-size: var(--fs-lg);
  font-family: var(--mono);
}
@media (max-width: 640px) {
  .metrics {
    grid-template-columns: 1fr;
  }
  .metric {
    border-right: 0;
    border-bottom: 1px solid var(--border-soft);
  }
}
</style>
