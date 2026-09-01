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
import { formatBytes } from '@/utils/format'
import type { Session } from '@/composables/useTraffic'
import type { OpenvpnClient, OvpnModule, ServerRole } from '@/api/types'

export type RowAction =
  | 'change-password'
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
}>()
const emit = defineEmits<{ action: [action: RowAction, username: string] }>()
const { t } = useI18n()

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
function fmtTime(s: string): string {
  const parts = s.split(' ')
  return parts.length > 1 ? parts[1].slice(0, 5) : s
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
  { action: 'change-password', key: 'actions.password', when: (r) => r.AccountStatus === 'Active', roles: ['master'], module: 'passwdAuth' },
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
  const s = props.traffic[row.Identity]
  if (row.ConnectionStatus === 'Connected' && s) {
    const bits = []
    if (s.virtualAddress) bits.push(s.virtualAddress)
    if (s.connectedSince) bits.push(t('table.onlineSince', { time: fmtTime(s.connectedSince) }))
    if (s.realAddress) bits.push(t('table.from', { ip: s.realAddress }))
    return bits.join(' · ')
  }
  if (row.ExpirationDate) return t('table.expiresOn', { date: fmtDate(row.ExpirationDate) })
  return ''
}

const isEmpty = computed(() => !props.loading && props.rows.length === 0)
</script>

<template>
  <div class="table-scroll">
    <table class="users">
      <thead>
        <tr>
          <th class="lineno">#</th>
          <th>{{ t('table.name') }}</th>
          <th>{{ t('table.status') }}</th>
          <th>{{ t('table.trafficSession') }}</th>
          <th>{{ t('table.expires') }}</th>
          <th class="right">{{ t('table.actions') }}</th>
        </tr>
      </thead>
      <tbody>
        <tr v-if="loading">
          <td colspan="6" class="state">{{ t('common.loading') }}</td>
        </tr>
        <tr v-else-if="isEmpty">
          <td colspan="6" class="state">{{ t('users.empty') }}</td>
        </tr>
        <tr v-for="(row, i) in rows" v-else :key="row.Identity" :class="rowClass(row)">
          <td class="lineno">{{ i + 1 }}</td>
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
            <span
              v-if="traffic[row.Identity] && traffic[row.Identity].rx + traffic[row.Identity].tx > 0"
              class="traffic"
            >
              <span><span class="ar">&#8595;</span>{{ formatBytes(traffic[row.Identity].rx) }}</span>
              <span><span class="ar">&#8593;</span>{{ formatBytes(traffic[row.Identity].tx) }}</span>
            </span>
            <span v-else class="traffic none">&mdash;</span>
          </td>
          <td>
            <span class="when" :class="{ soon: expiringSoon(row) }">{{ fmtDate(row.ExpirationDate) }}</span>
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
  min-width: 820px;
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
}
.users thead th.right {
  text-align: right;
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
.lineno {
  color: var(--text-faint);
  font-family: var(--mono);
  font-size: var(--fs-xs);
  width: 34px;
}
.identity {
  display: block;
  font-family: var(--mono);
  font-weight: 500;
  color: var(--text);
}
.sub {
  display: block;
  color: var(--text-faint);
  font-size: var(--fs-xs);
  font-family: var(--mono);
  margin-top: 3px;
}
.sub.soon {
  color: var(--warn);
}
.traffic {
  display: inline-flex;
  gap: 12px;
  font-family: var(--mono);
  font-size: var(--fs-xs);
  font-variant-numeric: tabular-nums;
  color: var(--text-dim);
}
.traffic .ar {
  color: var(--text-faint);
  margin-right: 3px;
}
.traffic.none {
  color: var(--text-faint);
}
.when {
  font-family: var(--mono);
  font-size: var(--fs-xs);
  color: var(--text-dim);
  font-variant-numeric: tabular-nums;
}
.when.soon {
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
/* меню в портале — не scoped */
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
