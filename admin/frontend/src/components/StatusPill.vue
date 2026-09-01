<script setup lang="ts">
import { computed } from 'vue'
import { useI18n } from 'vue-i18n'
import type { AccountStatus, ConnectionStatus } from '@/api/types'

const props = defineProps<{
  account: AccountStatus
  connection: ConnectionStatus
  expiringSoon?: boolean
}>()
const { t } = useI18n()

const view = computed(() => {
  if (props.account === 'Revoked') return { cls: 'crit', key: 'status.revoked' }
  if (props.account === 'Expired') return { cls: 'crit', key: 'status.expired' }
  if (props.connection === 'Connected') return { cls: 'ok', key: 'status.connected' }
  if (props.expiringSoon) return { cls: 'warn', key: 'status.expiring' }
  return { cls: 'idle', key: 'status.valid' }
})
</script>

<template>
  <span class="pill" :class="view.cls">
    <span class="d" />
    {{ t(view.key) }}
  </span>
</template>

<style scoped>
.pill {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  padding: 3px 10px 3px 8px;
  border-radius: 999px;
  font-size: var(--fs-xs);
  font-weight: 600;
  letter-spacing: 0.02em;
}
.d {
  width: 6px;
  height: 6px;
  border-radius: 50%;
  flex: none;
}
.ok {
  background: var(--ok-soft);
  color: var(--ok-text);
}
.ok .d {
  background: var(--ok);
}
.idle {
  background: var(--surface-3);
  color: var(--text-dim);
}
.idle .d {
  background: var(--text-faint);
}
.warn {
  background: var(--warn-soft);
  color: var(--warn-text);
}
.warn .d {
  background: var(--warn);
}
.crit {
  background: var(--crit-soft);
  color: var(--crit-text);
}
.crit .d {
  background: var(--crit);
}
</style>
