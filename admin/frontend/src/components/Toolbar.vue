<script setup lang="ts">
defineProps<{
  search: string
  hideRevoked: boolean
  canCreate: boolean
}>()
const emit = defineEmits<{
  'update:search': [value: string]
  'update:hideRevoked': [value: boolean]
  add: []
  refresh: []
}>()
</script>

<template>
  <div class="toolbar">
    <label class="search">
      <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4">
        <circle cx="11" cy="11" r="7" />
        <path d="M21 21l-4.3-4.3" />
      </svg>
      <input
        :value="search"
        type="text"
        placeholder="Filter by name or status…"
        @input="emit('update:search', ($event.target as HTMLInputElement).value)"
      />
    </label>

    <span class="spacer" />

    <button
      class="toggle"
      type="button"
      :aria-pressed="hideRevoked"
      @click="emit('update:hideRevoked', !hideRevoked)"
    >
      <span class="track" :class="{ on: hideRevoked }" />
      Hide revoked
    </button>

    <button class="btn btn-ghost" type="button" @click="emit('refresh')">Refresh</button>

    <button v-if="canCreate" class="btn btn-primary" type="button" @click="emit('add')">
      <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6">
        <path d="M12 5v14M5 12h14" />
      </svg>
      Add user
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
.toggle {
  all: unset;
  display: inline-flex;
  align-items: center;
  gap: 8px;
  color: var(--text-dim);
  font-size: var(--fs-sm);
  font-weight: 500;
  cursor: pointer;
}
.toggle .track {
  width: 32px;
  height: 18px;
  border-radius: 999px;
  background: var(--surface-3);
  border: 1px solid var(--border);
  position: relative;
  transition: background 0.15s;
}
.toggle .track::after {
  content: '';
  position: absolute;
  top: 1px;
  left: 1px;
  width: 14px;
  height: 14px;
  border-radius: 50%;
  background: var(--text-dim);
  transition: transform 0.15s, background 0.15s;
}
.toggle .track.on {
  background: var(--accent-soft);
  border-color: var(--accent);
}
.toggle .track.on::after {
  transform: translateX(14px);
  background: var(--accent);
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
</style>
