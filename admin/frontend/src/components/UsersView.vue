<script setup lang="ts">
import { computed, ref, shallowRef, watch, onMounted, onBeforeUnmount } from 'vue'
import MetricStrip from './MetricStrip.vue'
import Toolbar from './Toolbar.vue'
import UsersTable from './UsersTable.vue'
import type { RowAction } from './UsersTable.vue'
import AddUserModal from './modals/AddUserModal.vue'
import PasswordModal from './modals/PasswordModal.vue'
import ConfirmModal from './modals/ConfirmModal.vue'
import type { ConfirmKind } from './modals/ConfirmModal.vue'
import ConfigModal from './modals/ConfigModal.vue'
import CcdModal from './modals/CcdModal.vue'
import { useI18n } from 'vue-i18n'
import { useUsers } from '@/composables/useUsers'
import { useServerSettings } from '@/composables/useServerSettings'
import { useTraffic } from '@/composables/useTraffic'
import { formatBytes } from '@/utils/format'

const { t } = useI18n()
const { filtered, stats, search, loading, error, refresh, users } = useUsers()
const { role, modules, isMaster, isSlave, hasModule } = useServerSettings()
const { byUser: trafficByUser, total: trafficTotal, refresh: refreshTraffic } = useTraffic()

const connectedNames = computed(() =>
  users.value.filter((u) => u.ConnectionStatus === 'Connected').map((u) => u.Identity),
)

watch(connectedNames, (names) => void refreshTraffic(names), { immediate: true })

let poll: number | undefined
onMounted(() => {
  poll = window.setInterval(() => {
    void refresh({ silent: true })
    void refreshTraffic(connectedNames.value)
  }, 15_000)
})
onBeforeUnmount(() => window.clearInterval(poll))

const trafficLabel = computed(() => {
  const tot = trafficTotal.value
  if (tot.rx + tot.tx === 0) return '—'
  return `${formatBytes(tot.rx)} ↓ · ${formatBytes(tot.tx)} ↑`
})

const DAY = 86_400_000
const expiringSoon = computed(
  () =>
    users.value.filter((u) => {
      if (u.AccountStatus !== 'Active') return false
      const ts = Date.parse(u.ExpirationDate.replace(' ', 'T'))
      return !Number.isNaN(ts) && ts - Date.now() < 30 * DAY
    }).length,
)

const addOpen = ref(false)
const pwd = shallowRef<{ mode: 'change' | 'rotate'; username: string } | null>(null)
const confirm = shallowRef<{ kind: ConfirmKind; username: string } | null>(null)
const cfg = shallowRef<string | null>(null)
const ccd = shallowRef<string | null>(null)

function onAction(action: RowAction, username: string) {
  switch (action) {
    case 'change-password':
      pwd.value = { mode: 'change', username }
      break
    case 'rotate':
      pwd.value = { mode: 'rotate', username }
      break
    case 'revoke':
    case 'unrevoke':
    case 'delete':
    case 'disconnect':
      confirm.value = { kind: action, username }
      break
    case 'download-config':
      cfg.value = username
      break
    case 'edit-ccd':
      ccd.value = username
      break
  }
}
</script>

<template>
  <div class="page-head">
    <h1>{{ t('users.title') }}</h1>
    <span class="count">{{ t('users.summary', { total: stats.total, online: stats.connected }) }}</span>
  </div>

  <MetricStrip
    :connected="stats.connected"
    :total="stats.total"
    :revoked="stats.revoked"
    :expired="stats.expired"
    :expiring-soon="expiringSoon"
    :traffic="trafficLabel"
  />

  <p v-if="error" class="load-error">{{ t('users.loadError', { error }) }}</p>

  <div class="card">
    <Toolbar
      :search="search"
      :can-create="isMaster"
      @update:search="search = $event"
      @refresh="refresh"
      @add="addOpen = true"
    />
    <UsersTable
      :rows="filtered"
      :loading="loading"
      :role="role"
      :modules="modules"
      :traffic="trafficByUser"
      @action="onAction"
    />
  </div>

  <AddUserModal v-model:open="addOpen" />

  <PasswordModal
    v-if="pwd"
    :open="true"
    :username="pwd.username"
    :mode="pwd.mode"
    :ask-password="hasModule('passwdAuth')"
    @update:open="pwd = null"
  />

  <ConfirmModal
    v-if="confirm"
    :open="true"
    :username="confirm.username"
    :kind="confirm.kind"
    @update:open="confirm = null"
  />

  <ConfigModal v-if="cfg" :open="true" :username="cfg" @update:open="cfg = null" />

  <CcdModal
    v-if="ccd"
    :open="true"
    :username="ccd"
    :readonly="isSlave"
    @update:open="ccd = null"
  />
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
