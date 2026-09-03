<script setup lang="ts">
import { useI18n } from 'vue-i18n'
import { useView } from '@/composables/useView'
import { useTheme } from '@/composables/useTheme'
import { setLocale } from '@/i18n'

const { t, locale } = useI18n()
const { view, go } = useView()
const { theme, toggle: toggleTheme } = useTheme()

function toggleLocale() {
  setLocale(locale.value === 'ru' ? 'en' : 'ru')
}
</script>

<template>
  <div class="page">
  <header class="topbar">
    <div class="topbar-inner">
    <div class="brand">
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
    </div>
  </header>

  <main>
    <slot />
  </main>
  </div>
</template>

<style scoped>
.page {
  max-width: 1360px;
  margin: 0 auto;
  padding: 26px 22px 64px;
}
.topbar {
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--r);
  margin-bottom: 22px;
}
.topbar-inner {
  height: 56px;
  padding: 0 18px;
  display: flex;
  align-items: center;
  gap: 20px;
}
.brand {
  display: flex;
  align-items: center;
  font-weight: 600;
  font-size: var(--fs-lg);
  letter-spacing: -0.01em;
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
@media (max-width: 640px) {
  .page {
    padding: 14px 14px 48px;
  }
  .topbar-inner {
    height: auto;
    flex-wrap: wrap;
    gap: 10px;
    padding: 11px 12px;
  }
  /* строка 1: название слева, переключатели темы/языка справа */
  .brand {
    flex: 1 1 auto;
    min-width: 0;
  }
  .spacer {
    display: none;
  }
  /* строка 2: вкладки на всю ширину, как сегментированный переключатель */
  .nav {
    order: 9;
    flex-basis: 100%;
    gap: 4px;
  }
  .nav button {
    flex: 1;
    text-align: center;
  }
}
</style>
