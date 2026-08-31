<script setup lang="ts">
import { useToasts } from '@/composables/useToasts'

const { toasts, dismiss } = useToasts()
</script>

<template>
  <div class="toast-host" aria-live="polite">
    <div v-for="t in toasts" :key="t.id" class="toast" :class="t.kind" role="status">
      <div class="title">{{ t.title }}</div>
      <div v-if="t.detail" class="detail">{{ t.detail }}</div>
      <button class="x" type="button" aria-label="dismiss" @click="dismiss(t.id)">&times;</button>
    </div>
  </div>
</template>

<style scoped>
.toast-host {
  position: fixed;
  left: 20px;
  bottom: 20px;
  display: flex;
  flex-direction: column;
  gap: 8px;
  z-index: 80;
  max-width: 380px;
}
.toast {
  position: relative;
  padding: 12px 34px 12px 14px;
  border-radius: var(--r-sm);
  background: var(--surface);
  border: 1px solid var(--border);
  border-left: 3px solid var(--text-faint);
  box-shadow: var(--shadow-modal);
  font-size: var(--fs-sm);
}
.toast.success {
  border-left-color: var(--ok);
}
.toast.warn {
  border-left-color: var(--warn);
}
.toast.error {
  border-left-color: var(--crit);
}
.toast.info {
  border-left-color: var(--accent);
}
.title {
  font-weight: 600;
}
.detail {
  color: var(--text-dim);
  font-size: var(--fs-xs);
  margin-top: 3px;
  font-family: var(--mono);
}
.x {
  all: unset;
  position: absolute;
  top: 8px;
  right: 10px;
  cursor: pointer;
  color: var(--text-faint);
  font-size: 16px;
  line-height: 1;
}
.x:hover {
  color: var(--text);
}
</style>
