<script setup lang="ts">
import { computed } from 'vue'
import { useI18n } from 'vue-i18n'
import {
  DropdownMenuRoot,
  DropdownMenuTrigger,
  DropdownMenuPortal,
  DropdownMenuContent,
  DropdownMenuItem,
} from 'reka-ui'
import StatusPill from './StatusPill.vue'
import { formatBytes, fmtAgo, fmtDuration } from '@/utils/format'
import type { Session } from '@/composables/useTraffic'
import type { SortKey, SortDir } from '@/composables/useUsers'
import type { OpenvpnClient, OvpnModule, ServerRole } from '@/api/types'

export type RowAction =
  | 'revoke'
  | 'unrevoke'
  | 'rotate'
  | 'delete'
  | 'download-config'
  | 'edit-ccd'
  | 'disconnect'

const props = defineProps<{
  rows: OpenvpnClient[]
  loading: boolean
  role: ServerRole
  modules: OvpnModule[]
  traffic: Record<string, Session>
  sortKey: SortKey
  sortDir: SortDir
  filtered: boolean
}>()
const emit = defineEmits<{
  action: [action: RowAction, username: string]
  sort: [key: SortKey]
}>()
const { t, locale } = useI18n()

const DAY = 86_400_000

function parseDate(s: string): number | null {
  if (!s) return null
  const ts = Date.parse(s.replace(' ', 'T'))
  return Number.isNaN(ts) ? null : ts
}
function expiringSoon(row: OpenvpnClient): boolean {
  if (row.AccountStatus !== 'Active') return false
  const ts = parseDate(row.ExpirationDate)
  return ts !== null && ts - Date.now() < 30 * DAY
}
function fmtDate(s: string): string {
  return s ? s.split(' ')[0] : '—'
}
function cleanAddr(s: string): string {
  return s.replace(/^(udp|tcp)[46]?:/i, '').replace(/:\d+$/, '')
}
function rowClass(row: OpenvpnClient): string {
  if (row.AccountStatus === 'Revoked' || row.AccountStatus === 'Expired') return 's-crit'
  if (row.ConnectionStatus === 'Connected') return 's-ok'
  if (expiringSoon(row)) return 's-warn'
  return ''
}

interface ActionDef {
  action: RowAction
  key: string
  tone?: 'warn' | 'crit'
  when: (r: OpenvpnClient) => boolean
  roles: ServerRole[]
  module: OvpnModule
}
const ACTIONS: ActionDef[] = [
  { action: 'download-config', key: 'actions.config', when: (r) => r.AccountStatus === 'Active', roles: ['master', 'slave'], module: 'core' },
  { action: 'edit-ccd', key: 'actions.routes', when: (r) => r.AccountStatus === 'Active', roles: ['master', 'slave'], module: 'ccd' },
  { action: 'disconnect', key: 'actions.disconnect', tone: 'warn', when: (r) => r.ConnectionStatus === 'Connected', roles: ['master'], module: 'core' },
  { action: 'revoke', key: 'actions.revoke', tone: 'warn', when: (r) => r.AccountStatus === 'Active', roles: ['master'], module: 'core' },
  { action: 'unrevoke', key: 'actions.unrevoke', when: (r) => r.AccountStatus === 'Revoked', roles: ['master'], module: 'core' },
  { action: 'rotate', key: 'actions.rotate', tone: 'warn', when: (r) => r.AccountStatus !== 'Active', roles: ['master'], module: 'core' },
  { action: 'delete', key: 'actions.delete', tone: 'crit', when: (r) => r.AccountStatus !== 'Active', roles: ['master'], module: 'core' },
]
function actionsFor(row: OpenvpnClient): ActionDef[] {
  return ACTIONS.filter(
    (a) => a.when(row) && a.roles.includes(props.role) && props.modules.includes(a.module),
  )
}

function subline(row: OpenvpnClient): string {
  const bits: string[] = []
  const s = props.traffic[row.Identity]
  if (row.ConnectionStatus === 'Connected' && s) {
    if (s.virtualAddress) bits.push(s.virtualAddress)
    if (s.connectedSince) bits.push(t('table.onlineFor', { dur: fmtDuration(s.connectedSince, locale.value) }))
    if (s.realAddress) bits.push(t('table.from', { ip: cleanAddr(s.realAddress) }))
    if (s.rx + s.tx > 0) bits.push(`↓${formatBytes(s.rx)} ↑${formatBytes(s.tx)}`)
  } else if (row.LastSeen > 0) {
    bits.push(t('table.lastSeen', { ago: fmtAgo(row.LastSeen, locale.value) }))
  }
  if (row.AccountStatus === 'Revoked' && row.RevocationDate) {
    bits.push(t('table.revokedOn', { date: fmtDate(row.RevocationDate) }))
  } else if (row.ExpirationDate) {
    bits.push(t('table.expiresOn', { date: fmtDate(row.ExpirationDate) }))
  }
  return bits.join(' · ')
}

const isEmpty = computed(() => !props.loading && props.rows.length === 0)
function arrow(key: SortKey): string {
  if (props.sortKey !== key) return ''
  return props.sortDir === 'asc' ? '↑' : '↓'
}
</script>

<template>
  <div class="table-scroll">
    <table class="users">
      <thead>
        <tr>
          <th class="sortable" @click="emit('sort', 'name')">
            {{ t('table.name') }} <span class="arr">{{ arrow('name') }}</span>
          </th>
          <th class="sortable" @click="emit('sort', 'status')">
            {{ t('table.status') }} <span class="arr">{{ arrow('status') }}</span>
          </th>
          <th class="right">{{ t('table.actions') }}</th>
        </tr>
      </thead>
      <tbody>
        <tr v-if="loading">
          <td colspan="3" class="state">{{ t('common.loading') }}</td>
        </tr>
        <tr v-else-if="isEmpty">
          <td colspan="3" class="state">{{ filtered ? t('users.emptyFiltered') : t('users.empty') }}</td>
        </tr>
        <tr v-for="row in rows" v-else :key="row.Identity" :class="rowClass(row)">
          <td>
            <span class="identity">{{ row.Identity }}</span>
            <span v-if="subline(row)" class="sub" :class="{ soon: expiringSoon(row) }">{{ subline(row) }}</span>
          </td>
          <td>
            <StatusPill
              :account="row.AccountStatus"
              :connection="row.ConnectionStatus"
              :expiring-soon="expiringSoon(row)"
            />
          </td>
          <td>
            <div class="row-actions">
              <DropdownMenuRoot v-if="actionsFor(row).length">
                <DropdownMenuTrigger class="kebab" :aria-label="t('actions.menu')">&#8943;</DropdownMenuTrigger>
                <DropdownMenuPortal>
                  <DropdownMenuContent class="menu" align="end" :side-offset="4">
                    <DropdownMenuItem
                      v-for="a in actionsFor(row)"
                      :key="a.action"
                      class="menu-item"
                      :class="a.tone"
                      @select="emit('action', a.action, row.Identity)"
                    >
                      {{ t(a.key) }}
                    </DropdownMenuItem>
                  </DropdownMenuContent>
                </DropdownMenuPortal>
              </DropdownMenuRoot>
            </div>
          </td>
        </tr>
      </tbody>
    </table>
  </div>
</template>

<style scoped>
.table-scroll {
  overflow-x: auto;
}
.users {
  width: 100%;
  border-collapse: collapse;
  font-size: var(--fs-sm);
  min-width: 460px;
}
.users thead th {
  text-align: left;
  padding: 11px 16px;
  font-size: var(--fs-xs);
  text-transform: uppercase;
  letter-spacing: 0.07em;
  color: var(--text-faint);
  font-weight: 600;
  border-bottom: 1px solid var(--border);
  background: var(--surface);
  user-select: none;
}
.users thead th.right {
  text-align: right;
}
.users thead th.sortable {
  cursor: pointer;
}
.users thead th.sortable:hover {
  color: var(--text-dim);
}
.arr {
  color: var(--accent);
  font-weight: 700;
}
.users tbody td {
  padding: 12px 16px;
  border-bottom: 1px solid var(--border-soft);
  vertical-align: middle;
}
.users tbody tr:last-child td {
  border-bottom: 0;
}
.users tbody tr:hover td {
  background: var(--surface-2);
}
.users tbody td:first-child {
  border-left: 2px solid transparent;
}
tr.s-ok td:first-child {
  border-left-color: var(--ok);
}
tr.s-warn td:first-child {
  border-left-color: var(--warn);
}
tr.s-crit td:first-child {
  border-left-color: var(--crit);
}
.state {
  text-align: center;
  color: var(--text-faint);
  padding: 32px 16px;
  font-family: var(--mono);
  font-size: var(--fs-xs);
}
.identity {
  display: block;
  font-family: var(--mono);
  font-size: var(--fs-lg);
  font-weight: 600;
  letter-spacing: -0.01em;
  color: var(--text);
}
.sub {
  display: block;
  color: var(--text-faint);
  font-size: var(--fs-xs);
  font-family: var(--mono);
  margin-top: 4px;
}
.sub.soon {
  color: var(--warn);
}
.row-actions {
  display: flex;
  justify-content: flex-end;
}
.kebab {
  appearance: none;
  background: transparent;
  border: 1px solid var(--border);
  color: var(--text-dim);
  height: 27px;
  width: 30px;
  border-radius: 5px;
  cursor: pointer;
  font-size: 16px;
  line-height: 1;
  display: grid;
  place-items: center;
  transition: color 0.12s, border-color 0.12s, background 0.12s;
}
.kebab:hover,
.kebab[data-state='open'] {
  color: var(--text);
  background: var(--surface-3);
}
</style>

<style>
.menu {
  min-width: 168px;
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--r-sm);
  box-shadow: var(--shadow-modal);
  padding: 4px;
  z-index: 60;
}
.menu-item {
  padding: 7px 10px;
  border-radius: 4px;
  font-size: var(--fs-sm);
  color: var(--text-dim);
  cursor: pointer;
  outline: none;
  user-select: none;
}
.menu-item[data-highlighted] {
  background: var(--surface-2);
  color: var(--text);
}
.menu-item.warn[data-highlighted] {
  color: var(--warn);
}
.menu-item.crit[data-highlighted] {
  color: var(--crit);
}
</style>
