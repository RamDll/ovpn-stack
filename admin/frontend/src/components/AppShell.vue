<script setup lang="ts">
import { useServerSettings } from '@/composables/useServerSettings'

const { role, isSlave, lastSync } = useServerSettings()
</script>

<template>
  <header class="topbar">
    <div class="brand">
      <span class="glyph">ov</span>
      <span class="name">ovpn&#8209;admin</span>
    </div>
    <nav class="nav">
      <a href="#" class="is-active">Users</a>
    </nav>
    <span class="spacer" />
    <span v-if="isSlave" class="sync">last sync: {{ lastSync }}</span>
    <span class="role" :class="`role--${role}`">
      <span class="dot" />
      {{ role }}
    </span>
  </header>

  <main class="wrap">
    <slot />
  </main>
</template>

<style scoped>
.topbar {
  display: flex;
  align-items: center;
  gap: 26px;
  height: 58px;
  padding: 0 28px;
  background: var(--surface);
  border-bottom: 1px solid var(--border);
  position: sticky;
  top: 0;
  z-index: 20;
}
.brand {
  display: flex;
  align-items: center;
  gap: 10px;
  font-weight: 600;
  font-size: var(--fs-lg);
  letter-spacing: -0.01em;
}
.glyph {
  width: 28px;
  height: 28px;
  display: grid;
  place-items: center;
  border-radius: var(--r-sm);
  background: linear-gradient(150deg, var(--accent), #2f7f99);
  color: var(--accent-ink);
  font-family: var(--mono);
  font-weight: 600;
  font-size: 14px;
}
.nav {
  display: flex;
  gap: 2px;
}
.nav a {
  padding: 7px 13px;
  border-radius: var(--r-sm);
  color: var(--text-dim);
  font-size: var(--fs-sm);
  font-weight: 500;
}
.nav a.is-active {
  color: var(--text);
  background: var(--surface-2);
}
.spacer {
  flex: 1;
}
.sync {
  color: var(--text-faint);
  font-family: var(--mono);
  font-size: var(--fs-xs);
}
.role {
  display: inline-flex;
  align-items: center;
  gap: 7px;
  padding: 4px 11px 4px 9px;
  border: 1px solid var(--border);
  border-radius: 999px;
  font-size: var(--fs-xs);
  letter-spacing: 0.06em;
  text-transform: uppercase;
  color: var(--text-dim);
  font-weight: 600;
}
.role .dot {
  width: 6px;
  height: 6px;
  border-radius: 50%;
  background: var(--ok);
  box-shadow: 0 0 0 3px var(--ok-soft);
}
.role--slave .dot {
  background: var(--warn);
  box-shadow: 0 0 0 3px var(--warn-soft);
}
.wrap {
  max-width: 1360px;
  margin: 0 auto;
  padding: 26px 28px 64px;
}
</style>
