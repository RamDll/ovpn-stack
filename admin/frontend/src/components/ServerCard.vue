<script setup lang="ts">
import { useI18n } from 'vue-i18n'
import { useServerSettings } from '@/composables/useServerSettings'
import { useUsers } from '@/composables/useUsers'

const { t } = useI18n()
const { caExpireDays, serverCertExpireDays } = useServerSettings()
const { stats } = useUsers()

function tone(days: number): string {
  if (days <= 0) return 'crit'
  if (days < 30) return 'crit'
  if (days < 90) return 'warn'
  return ''
}
function label(days: number): string {
  return days <= 0 ? t('server.expired') : t('server.days', { n: days })
}
</script>

<template>
  <div class="server">
    <div class="cell">
      <div class="k">{{ t('server.ca') }}</div>
      <div class="v" :class="tone(caExpireDays)">{{ label(caExpireDays) }}</div>
    </div>
    <div class="cell">
      <div class="k">{{ t('server.serverCert') }}</div>
      <div class="v" :class="tone(serverCertExpireDays)">{{ label(serverCertExpireDays) }}</div>
    </div>
    <div class="cell">
      <div class="k">{{ t('server.online') }}</div>
      <div class="v u-num">{{ stats.connected }} / {{ stats.total }}</div>
    </div>
  </div>
</template>

<style scoped>
.server {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--r);
  overflow: hidden;
  margin-bottom: 22px;
}
.cell {
  padding: 16px 18px;
  border-right: 1px solid var(--border-soft);
}
.cell:last-child {
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
  font-size: var(--fs-lg);
  font-weight: 600;
  font-family: var(--mono);
}
.v.warn {
  color: var(--warn);
}
.v.crit {
  color: var(--crit);
}
@media (max-width: 560px) {
  .server {
    grid-template-columns: 1fr;
  }
  .cell {
    border-right: 0;
    border-bottom: 1px solid var(--border-soft);
  }
}
</style>
