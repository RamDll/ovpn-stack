<script setup lang="ts">
import { useI18n } from 'vue-i18n'

defineProps<{ search: string; canCreate: boolean }>()
const emit = defineEmits<{
  'update:search': [value: string]
  add: []
  refresh: []
}>()
const { t } = useI18n()
</script>

<template>
  <div class="toolbar">
    <label class="search">
      <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" aria-hidden="true">
        <circle cx="11" cy="11" r="7" />
        <path d="M21 21l-4.3-4.3" />
      </svg>
      <input
        :value="search"
        type="text"
        :placeholder="t('users.filter')"
        @input="emit('update:search', ($event.target as HTMLInputElement).value)"
      />
    </label>

    <span class="spacer" />

    <button class="btn btn-ghost" type="button" @click="emit('refresh')">{{ t('common.refresh') }}</button>

    <button v-if="canCreate" class="btn btn-primary" type="button" @click="emit('add')">
      <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" aria-hidden="true">
        <path d="M12 5v14M5 12h14" />
      </svg>
      {{ t('users.addUser') }}
    </button>
  </div>
</template>

<style scoped>
.toolbar {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 13px 14px;
  border-bottom: 1px solid var(--border);
}
.search {
  flex: 1;
  max-width: 340px;
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 8px 11px;
  background: var(--surface-2);
  border: 1px solid var(--border);
  border-radius: var(--r-sm);
  color: var(--text-dim);
}
.search input {
  all: unset;
  flex: 1;
  color: var(--text);
  font-family: var(--sans);
  font-size: var(--fs-sm);
}
.search input::placeholder {
  color: var(--text-faint);
}
.spacer {
  flex: 1;
}
.btn {
  all: unset;
  box-sizing: border-box;
  display: inline-flex;
  align-items: center;
  gap: 6px;
  padding: 8px 13px;
  border-radius: var(--r-sm);
  font-size: var(--fs-sm);
  font-weight: 600;
  cursor: pointer;
  border: 1px solid transparent;
  white-space: nowrap;
  transition: background 0.12s, border-color 0.12s, color 0.12s;
}
.btn-primary {
  background: var(--accent);
  color: var(--accent-ink);
}
.btn-primary:hover {
  background: var(--accent-hi);
}
.btn-ghost {
  color: var(--text-dim);
  border-color: var(--border);
}
.btn-ghost:hover {
  color: var(--text);
  background: var(--surface-2);
}

@media (max-width: 560px) {
  .toolbar {
    flex-wrap: wrap;
    gap: 10px;
  }
  .search {
    max-width: none;
    flex-basis: 100%;
  }
  .spacer {
    display: none;
  }
  .btn {
    flex: 1;
    justify-content: center;
  }
}
</style>
