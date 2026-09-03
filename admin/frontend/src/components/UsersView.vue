<script setup lang="ts">
import { computed, ref, shallowRef, watch, onMounted, onBeforeUnmount } from 'vue'
import MetricStrip from './MetricStrip.vue'
import Toolbar from './Toolbar.vue'
import UsersTable from './UsersTable.vue'
import type { RowAction } from './UsersTable.vue'
import AddUserModal from './modals/AddUserModal.vue'
import RotateModal from './modals/RotateModal.vue'
import ConfirmModal from './modals/ConfirmModal.vue'
import type { ConfirmKind } from './modals/ConfirmModal.vue'
import ConfigModal from './modals/ConfigModal.vue'
import CcdModal from './modals/CcdModal.vue'
import { useI18n } from 'vue-i18n'
import { useUsers } from '@/composables/useUsers'
import { useServerSettings } from '@/composables/useServerSettings'
import { useServerStats } from '@/composables/useServerStats'
import { useTraffic } from '@/composables/useTraffic'

const { t } = useI18n()
const {
  filtered, stats, search, loading, error, refresh, users,
  filterOnline, filterRevoked, sortKey, sortDir, toggleSort,
} = useUsers()
const { modules } = useServerSettings()
const { stats: sys, refresh: refreshSys } = useServerStats()

const anyFilter = computed(
  () => !!search.value.trim() || filterOnline.value || filterRevoked.value,
)
const { byUser: trafficByUser, refresh: refreshTraffic } = useTraffic()

const connectedNames = computed(() =>
  users.value.filter((u) => u.ConnectionStatus === 'Connected').map((u) => u.Identity),
)

watch(connectedNames, (names) => void refreshTraffic(names), { immediate: true })

let poll: number | undefined
onMounted(() => {
  void refreshSys()
  poll = window.setInterval(() => {
    void refresh({ silent: true })
    void refreshTraffic(connectedNames.value)
    void refreshSys()
  }, 15_000)
})
onBeforeUnmount(() => window.clearInterval(poll))


const addOpen = ref(false)
const pwd = shallowRef<{ username: string } | null>(null)
const confirm = shallowRef<{ kind: ConfirmKind; username: string } | null>(null)
const cfg = shallowRef<string | null>(null)
const ccd = shallowRef<string | null>(null)

function onAction(action: RowAction, username: string) {
  switch (action) {
    case 'rotate':
      pwd.value = { username }
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

  <MetricStrip :connected="stats.connected" :sys="sys" />

  <p v-if="error" class="load-error">{{ t('users.loadError', { error }) }}</p>

  <div class="card">
    <Toolbar
      :search="search"
      :filter-online="filterOnline"
      :filter-revoked="filterRevoked"
      :revoked-count="stats.revoked"
      @update:search="search = $event"
      @update:filter-online="filterOnline = $event"
      @update:filter-revoked="filterRevoked = $event"
      @refresh="refresh"
      @add="addOpen = true"
    />
    <UsersTable
      :rows="filtered"
      :loading="loading"
      :modules="modules"
      :traffic="trafficByUser"
      :sort-key="sortKey"
      :sort-dir="sortDir"
      :filtered="anyFilter"
      @action="onAction"
      @sort="toggleSort"
    />
  </div>

  <AddUserModal v-model:open="addOpen" />

  <RotateModal
    v-if="pwd"
    :open="true"
    :username="pwd.username"
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
