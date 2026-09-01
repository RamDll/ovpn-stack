/**
 * Тонкая обёртка над fetch. Пути — относительные (без ведущего слэша),
 * резолвятся от каталога текущего документа, поэтому работает и когда
 * панель смонтирована под OVPN_LISTEN_BASE_URL (напр. /ovpn/).
 */

const API_BASE = new URL('.', document.baseURI).href

export class ApiError extends Error {
  status: number
  body: string
  constructor(status: number, body: string) {
    super(extractMessage(body) || `HTTP ${status}`)
    this.name = 'ApiError'
    this.status = status
    this.body = body
  }
}

function extractMessage(body: string): string {
  const trimmed = body.trim()
  if (trimmed.startsWith('{')) {
    try {
      const parsed = JSON.parse(trimmed) as { message?: string; error?: string }
      return parsed.message || parsed.error || ''
    } catch {
      /* fall through */
    }
  }
  return trimmed
}

function url(path: string): string {
  return new URL(path, API_BASE).href
}

async function parse<T>(res: Response): Promise<T> {
  const text = await res.text()
  if (!res.ok) throw new ApiError(res.status, text)
  // ovpn-admin отдаёт Content-Type: text/plain даже для JSON — определяем по телу
  const trimmed = text.trim()
  if (trimmed && (trimmed[0] === '{' || trimmed[0] === '[')) {
    try {
      return JSON.parse(trimmed) as T
    } catch {
      /* не JSON — вернём как текст */
    }
  }
  return text as unknown as T
}

export function apiGet<T>(path: string): Promise<T> {
  return fetch(url(path), { headers: { Accept: 'application/json' } }).then((r) => parse<T>(r))
}

export function apiForm<T = string>(path: string, fields: Record<string, string>): Promise<T> {
  const body = new URLSearchParams(fields)
  return fetch(url(path), {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body,
  }).then((r) => parse<T>(r))
}

export function apiJson<T = string>(path: string, payload: unknown): Promise<T> {
  return fetch(url(path), {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  }).then((r) => parse<T>(r))
}
