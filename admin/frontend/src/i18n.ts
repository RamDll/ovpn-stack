import { createI18n } from 'vue-i18n'
import ru from './locales/ru'
import en from './locales/en'

export type Locale = 'ru' | 'en'
const STORAGE_KEY = 'ovpn-admin.locale'

function initialLocale(): Locale {
  try {
    const saved = localStorage.getItem(STORAGE_KEY)
    if (saved === 'ru' || saved === 'en') return saved
  } catch {
    /* private mode */
  }
  return navigator.language?.toLowerCase().startsWith('en') ? 'en' : 'ru'
}

export const i18n = createI18n({
  legacy: false,
  locale: initialLocale(),
  fallbackLocale: 'en',
  messages: { ru, en },
})

export function setLocale(l: Locale) {
  i18n.global.locale.value = l
  try {
    localStorage.setItem(STORAGE_KEY, l)
  } catch {
    /* ignore */
  }
  document.documentElement.setAttribute('lang', l)
}

/** для использования вне компонентов (composables с тостами) */
export const t = i18n.global.t
