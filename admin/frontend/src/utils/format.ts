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

const MIN = 60
const HOUR = 3600
const DAY = 86400

/** unix-секунды -> "5 мин назад" / "3 дн назад" (локаль из аргумента) */
export function fmtAgo(unixSec: number, locale: string): string {
  if (!unixSec) return ''
  const diff = Math.max(0, Math.floor(Date.now() / 1000) - unixSec)
  const rtf = new Intl.RelativeTimeFormat(locale, { numeric: 'auto', style: 'short' })
  if (diff < MIN) return rtf.format(-diff, 'second')
  if (diff < HOUR) return rtf.format(-Math.floor(diff / MIN), 'minute')
  if (diff < DAY) return rtf.format(-Math.floor(diff / HOUR), 'hour')
  if (diff < 30 * DAY) return rtf.format(-Math.floor(diff / DAY), 'day')
  return rtf.format(-Math.floor(diff / (30 * DAY)), 'month')
}

/** "2026-09-01 03:38:12" -> "2 ч 15 м" / "2h 15m" — длительность от указанного момента */
export function fmtDuration(since: string, locale: string): string {
  const t = Date.parse(since.replace(' ', 'T'))
  if (Number.isNaN(t)) return ''
  const sec = Math.max(0, Math.floor((Date.now() - t) / 1000))
  const d = Math.floor(sec / DAY)
  const h = Math.floor((sec % DAY) / HOUR)
  const m = Math.floor((sec % HOUR) / MIN)
  const u = locale === 'ru' ? ['д', 'ч', 'м'] : ['d', 'h', 'm']
  if (d > 0) return `${d}${u[0]} ${h}${u[1]}`
  if (h > 0) return `${h}${u[1]} ${m}${u[2]}`
  return `${m}${u[2]}`
}
