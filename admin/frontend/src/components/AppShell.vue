<script setup lang="ts">
import { useI18n } from 'vue-i18n'
import { useServerSettings } from '@/composables/useServerSettings'
import { useView } from '@/composables/useView'
import { useTheme } from '@/composables/useTheme'
import { setLocale } from '@/i18n'

const { t, locale } = useI18n()
const { role, isSlave, lastSync } = useServerSettings()
const { view, go } = useView()
const { theme, toggle: toggleTheme } = useTheme()

function toggleLocale() {
  setLocale(locale.value === 'ru' ? 'en' : 'ru')
}
</script>

<template>
  <header class="topbar">
    <div class="brand">
      <span class="glyph">ov</span>
      <span class="name">ovpn&#8209;admin</span>
    </div>

    <nav class="nav">
      <button type="button" :class="{ 'is-active': view === 'users' }" @click="go('users')">
        {{ t('nav.users') }}
      </button>
      <button type="button" :class="{ 'is-active': view === 'statistics' }" @click="go('statistics')">
        {{ t('nav.statistics') }}
      </button>
    </nav>

    <span class="spacer" />

    <span v-if="isSlave" class="sync">{{ t('shell.lastSync', { time: lastSync }) }}</span>

    <button class="icon-btn" type="button" :title="t('shell.language')" @click="toggleLocale">
      {{ locale === 'ru' ? 'РУС' : 'ENG' }}
    </button>

    <button class="icon-btn" type="button" :title="t('shell.theme')" @click="toggleTheme" aria-live="polite">
      <svg v-if="theme === 'dark'" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
        <path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z" />
      </svg>
      <svg v-else width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
        <circle cx="12" cy="12" r="4" />
        <path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4" />
      </svg>
    </button>

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
  gap: 20px;
  height: 58px;
  padding: 0 22px;
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
.nav button {
  appearance: none;
  background: transparent;
  border: 0;
  font: inherit;
  padding: 7px 12px;
  border-radius: var(--r-sm);
  color: var(--text-dim);
  font-size: var(--fs-sm);
  font-weight: 500;
  cursor: pointer;
}
.nav button.is-active {
  color: var(--text);
  background: var(--surface-2);
}
.nav button:hover:not(.is-active) {
  color: var(--text);
}
.spacer {
  flex: 1;
}
.sync {
  color: var(--text-faint);
  font-family: var(--mono);
  font-size: var(--fs-xs);
}
.icon-btn {
  appearance: none;
  background: transparent;
  border: 1px solid var(--border);
  border-radius: var(--r-sm);
  color: var(--text-dim);
  height: 30px;
  min-width: 30px;
  padding: 0 8px;
  display: grid;
  place-items: center;
  cursor: pointer;
  font-family: var(--mono);
  font-size: 11px;
  font-weight: 600;
  letter-spacing: 0.03em;
  transition: color 0.15s, border-color 0.15s;
}
.icon-btn:hover {
  color: var(--text);
  border-color: var(--accent);
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
  padding: 26px 22px 64px;
}
@media (max-width: 560px) {
  .topbar {
    gap: 12px;
    padding: 0 14px;
  }
  .brand .name {
    display: none;
  }
  .sync {
    display: none;
  }
  .role {
    display: none;
  }
}
</style>
