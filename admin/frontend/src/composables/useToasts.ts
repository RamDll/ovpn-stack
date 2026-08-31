import { ref } from 'vue'

export type ToastKind = 'success' | 'warn' | 'error' | 'info'

export interface Toast {
  id: number
  kind: ToastKind
  title: string
  detail?: string
}

const toasts = ref<Toast[]>([])
let seq = 0

function push(kind: ToastKind, title: string, detail?: string) {
  const id = ++seq
  toasts.value.push({ id, kind, title, detail })
  window.setTimeout(() => dismiss(id), kind === 'error' ? 8000 : 4500)
}

function dismiss(id: number) {
  toasts.value = toasts.value.filter((t) => t.id !== id)
}

export function useToasts() {
  return {
    toasts,
    dismiss,
    success: (title: string, detail?: string) => push('success', title, detail),
    warn: (title: string, detail?: string) => push('warn', title, detail),
    error: (title: string, detail?: string) => push('error', title, detail),
    info: (title: string, detail?: string) => push('info', title, detail),
  }
}
