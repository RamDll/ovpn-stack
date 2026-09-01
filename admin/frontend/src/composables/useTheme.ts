import { ref } from 'vue'

export type Theme = 'dark' | 'light'
const STORAGE_KEY = 'ovpn-admin.theme'

function initial(): Theme {
  try {
    const s = localStorage.getItem(STORAGE_KEY)
    if (s === 'dark' || s === 'light') return s
  } catch {
    /* private mode */
  }
  return window.matchMedia?.('(prefers-color-scheme: light)').matches ? 'light' : 'dark'
}

const theme = ref<Theme>(initial())

function apply(t: Theme) {
  document.documentElement.setAttribute('data-theme', t)
}
apply(theme.value)

export function useTheme() {
  function toggle() {
    theme.value = theme.value === 'dark' ? 'light' : 'dark'
    apply(theme.value)
    try {
      localStorage.setItem(STORAGE_KEY, theme.value)
    } catch {
      /* ignore */
    }
  }
  return { theme, toggle }
}
