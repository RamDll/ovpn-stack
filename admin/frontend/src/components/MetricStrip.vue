<script setup lang="ts">
import { useI18n } from 'vue-i18n'
defineProps<{
  connected: number
  total: number
  revoked: number
  expired: number
  traffic: string
}>()
const { t } = useI18n()
</script>

<template>
  <div class="metrics">
    <div class="metric">
      <div class="k">{{ t('metrics.connectedNow') }}</div>
      <div class="v u-num">{{ connected }}</div>
    </div>
    <div class="metric">
      <div class="k">{{ t('metrics.issued') }}</div>
      <div class="v u-num">{{ total }}</div>
      <div class="delta">{{ t('metrics.revokedExpired', { revoked, expired }) }}</div>
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
.is-warn .v {
  color: var(--warn);
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
