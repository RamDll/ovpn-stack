const UNITS = ['B', 'KB', 'MB', 'GB', 'TB']

/** 1536 -> "1.5 KB" (десятичные приставки, как в панелях трафика). */
export function formatBytes(n: number): string {
  if (!Number.isFinite(n) || n <= 0) return '0 B'
  let v = n
  let i = 0
  while (v >= 1000 && i < UNITS.length - 1) {
    v /= 1000
    i++
  }
  const digits = v < 10 && i > 0 ? 1 : 0
  return `${v.toFixed(digits)} ${UNITS[i]}`
}

/** "2026-09-20 14:00:00" -> "2026-09-20" */
export function dateOnly(s: string): string {
  return s ? s.split(' ')[0] : '—'
}
