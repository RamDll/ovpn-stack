<script setup lang="ts">
import { computed } from 'vue'
import MetricStrip from './MetricStrip.vue'
import Toolbar from './Toolbar.vue'
import UsersTable from './UsersTable.vue'
import type { RowAction } from './UsersTable.vue'
import { useUsers } from '@/composables/useUsers'
import { useServerSettings } from '@/composables/useServerSettings'
import { useToasts } from '@/composables/useToasts'
import { ovpn } from '@/api/ovpn'

const { filtered, stats, search, hideRevoked, setHideRevoked, loading, error, refresh, users } =
  useUsers()
const { role, modules, isMaster } = useServerSettings()
const toasts = useToasts()

const DAY = 86_400_000
const expiringSoon = computed(
  () =>
    users.value.filter((u) => {
      if (u.AccountStatus !== 'Active') return false
      const t = Date.parse(u.ExpirationDate.replace(' ', 'T'))
      return !Number.isNaN(t) && t - Date.now() < 30 * DAY
    }).length,
)

async function downloadConfig(username: string) {
  try {
    const text = await ovpn.showConfig(username)
    const blob = new Blob([text], { type: 'text/plain' })
    const link = document.createElement('a')
    link.href = URL.createObjectURL(blob)
    link.download = `${username}.ovpn`
    link.click()
    URL.revokeObjectURL(link.href)
  } catch (e) {
    toasts.error(`Не удалось получить конфиг для ${username}`, e instanceof Error ? e.message : undefined)
  }
}

function onAction(action: RowAction, username: string) {
  if (action === 'download-config') {
    void downloadConfig(username)
    return
  }
  // модалки — следующие коммиты (см. PROGRESS.md)
  toasts.info(`${action} → ${username}`, 'модалка в разработке')
}
</script>

<template>
  <div class="page-head">
    <h1>Users &amp; certificates</h1>
    <span class="count">{{ stats.total }} issued &middot; {{ stats.connected }} online</span>
  </div>

  <MetricStrip
    :connected="stats.connected"
    :total="stats.total"
    :revoked="stats.revoked"
    :expired="stats.expired"
    :expiring-soon="expiringSoon"
  />

  <p v-if="error" class="load-error">Не удалось загрузить список: {{ error }}</p>

  <div class="card">
    <Toolbar
      :search="search"
      :hide-revoked="hideRevoked"
      :can-create="isMaster"
      @update:search="search = $event"
      @update:hide-revoked="setHideRevoked($event)"
      @refresh="refresh"
      @add="toasts.info('Add user', 'модалка в разработке')"
    />
    <UsersTable
      :rows="filtered"
      :loading="loading"
      :role="role"
      :modules="modules"
      @action="onAction"
    />
  </div>
</template>

<style scoped>
.page-head {
  display: flex;
  align-items: baseline;
  gap: 14px;
  margin-bottom: 18px;
}
.page-head h1 {
  margin: 0;
  font-size: var(--fs-xl);
  font-weight: 600;
  letter-spacing: -0.01em;
}
.count {
  color: var(--text-faint);
  font-family: var(--mono);
  font-size: var(--fs-sm);
}
.load-error {
  margin: 0 0 16px;
  padding: 10px 14px;
  border-radius: var(--r-sm);
  background: var(--crit-soft);
  border: 1px solid var(--crit);
  color: var(--crit-text);
  font-size: var(--fs-sm);
}
.card {
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--r);
  overflow: hidden;
}
</style>
