<script setup lang="ts">
import { computed } from 'vue'
import StatusPill from './StatusPill.vue'
import { formatBytes } from '@/utils/format'
import type { Traffic } from '@/composables/useTraffic'
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
  traffic: Record<string, Traffic>
}>()
const emit = defineEmits<{ action: [action: RowAction, username: string] }>()

const DAY = 86_400_000

function parseDate(s: string): number | null {
  if (!s) return null
  const t = Date.parse(s.replace(' ', 'T'))
  return Number.isNaN(t) ? null : t
}

function expiringSoon(row: OpenvpnClient): boolean {
  if (row.AccountStatus !== 'Active') return false
  const t = parseDate(row.ExpirationDate)
  return t !== null && t - Date.now() < 30 * DAY
}

function fmtDate(s: string): string {
  return s ? s.split(' ')[0] : '—'
}

function rowClass(row: OpenvpnClient): string {
  if (row.AccountStatus === 'Revoked' || row.AccountStatus === 'Expired') return 's-crit'
  if (row.ConnectionStatus === 'Connected') return 's-ok'
  if (expiringSoon(row)) return 's-warn'
  return ''
}

interface ActionDef {
  action: RowAction
  label: string
  tone?: 'warn' | 'crit'
  when: (r: OpenvpnClient) => boolean
  roles: ServerRole[]
  module: OvpnModule
}

const ACTIONS: ActionDef[] = [
  { action: 'download-config', label: 'Config', when: (r) => r.AccountStatus === 'Active', roles: ['master', 'slave'], module: 'core' },
  { action: 'edit-ccd', label: 'Routes', when: (r) => r.AccountStatus === 'Active', roles: ['master', 'slave'], module: 'ccd' },
  { action: 'change-password', label: 'Password', when: (r) => r.AccountStatus === 'Active', roles: ['master'], module: 'passwdAuth' },
  { action: 'disconnect', label: 'Disconnect', when: (r) => r.ConnectionStatus === 'Connected', roles: ['master'], module: 'core' },
  { action: 'revoke', label: 'Revoke', tone: 'warn', when: (r) => r.AccountStatus === 'Active', roles: ['master'], module: 'core' },
  { action: 'unrevoke', label: 'Unrevoke', when: (r) => r.AccountStatus === 'Revoked', roles: ['master'], module: 'core' },
  { action: 'rotate', label: 'Rotate', tone: 'warn', when: (r) => r.AccountStatus !== 'Active', roles: ['master'], module: 'core' },
  { action: 'delete', label: 'Delete', tone: 'crit', when: (r) => r.AccountStatus !== 'Active', roles: ['master'], module: 'core' },
]

function actionsFor(row: OpenvpnClient): ActionDef[] {
  return ACTIONS.filter(
    (a) => a.when(row) && a.roles.includes(props.role) && props.modules.includes(a.module),
  )
}

const isEmpty = computed(() => !props.loading && props.rows.length === 0)
</script>

<template>
  <div class="table-scroll">
    <table class="users">
      <thead>
        <tr>
          <th class="lineno">#</th>
          <th>Name</th>
          <th>Status</th>
          <th>Traffic &middot; session</th>
          <th>Expires</th>
          <th class="right">Actions</th>
        </tr>
      </thead>
      <tbody>
        <tr v-if="loading">
          <td colspan="6" class="state">Загрузка…</td>
        </tr>
        <tr v-else-if="isEmpty">
          <td colspan="6" class="state">Пользователей пока нет.</td>
        </tr>
        <tr v-for="(row, i) in rows" v-else :key="row.Identity" :class="rowClass(row)">
          <td class="lineno">{{ i + 1 }}</td>
          <td>
            <span class="identity">{{ row.Identity }}</span>
          </td>
          <td>
            <StatusPill
              :account="row.AccountStatus"
              :connection="row.ConnectionStatus"
              :expiring-soon="expiringSoon(row)"
            />
          </td>
          <td>
            <span v-if="traffic[row.Identity] && traffic[row.Identity].rx + traffic[row.Identity].tx > 0" class="traffic">
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
              <button
                v-for="a in actionsFor(row)"
                :key="a.action"
                class="act"
                :class="a.tone"
                type="button"
                @click="emit('action', a.action, row.Identity)"
              >
                {{ a.label }}
              </button>
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
  min-width: 860px;
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
  font-family: var(--mono);
  font-weight: 500;
  color: var(--text);
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
  gap: 4px;
  justify-content: flex-end;
}
.act {
  all: unset;
  box-sizing: border-box;
  display: inline-grid;
  place-items: center;
  height: 27px;
  padding: 0 9px;
  border-radius: 4px;
  border: 1px solid var(--border);
  color: var(--text-dim);
  font-size: var(--fs-xs);
  font-weight: 600;
  cursor: pointer;
  transition: background 0.12s, color 0.12s, border-color 0.12s;
}
.act:hover {
  color: var(--text);
  background: var(--surface-3);
}
.act.warn:hover {
  color: var(--warn);
  border-color: var(--warn);
}
.act.crit:hover {
  color: var(--crit);
  border-color: var(--crit);
}
</style>
