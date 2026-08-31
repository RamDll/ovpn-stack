<script setup lang="ts">
defineProps<{
  connected: number
  total: number
  revoked: number
  expired: number
  expiringSoon: number
}>()
</script>

<template>
  <div class="metrics">
    <div class="metric">
      <div class="k">Connected now</div>
      <div class="v u-num">{{ connected }}</div>
    </div>
    <div class="metric">
      <div class="k">Issued certificates</div>
      <div class="v u-num">{{ total }}</div>
      <div class="delta">{{ revoked }} revoked &middot; {{ expired }} expired</div>
    </div>
    <div class="metric" :class="{ 'is-warn': expiringSoon > 0 }">
      <div class="k">Expiring &lt; 30 days</div>
      <div class="v u-num">{{ expiringSoon }}</div>
    </div>
    <div class="metric">
      <div class="k">Traffic, live sessions</div>
      <div class="v u-num">&mdash;</div>
      <div class="delta">подтянем из api/user/statistic</div>
    </div>
  </div>
</template>

<style scoped>
.metrics {
  display: grid;
  grid-template-columns: repeat(4, 1fr);
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
@media (max-width: 720px) {
  .metrics {
    grid-template-columns: repeat(2, 1fr);
  }
}
</style>
