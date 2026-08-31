<script setup lang="ts">
import { computed } from 'vue'
import type { AccountStatus, ConnectionStatus } from '@/api/types'

const props = defineProps<{
  account: AccountStatus
  connection: ConnectionStatus
  expiringSoon?: boolean
}>()

const view = computed(() => {
  if (props.account === 'Revoked') return { cls: 'crit', label: 'Revoked' }
  if (props.account === 'Expired') return { cls: 'crit', label: 'Expired' }
  if (props.connection === 'Connected') return { cls: 'ok', label: 'Connected' }
  if (props.expiringSoon) return { cls: 'warn', label: 'Expiring' }
  return { cls: 'idle', label: 'Valid' }
})
</script>

<template>
  <span class="pill" :class="view.cls">
    <span class="d" />
    {{ view.label }}
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
