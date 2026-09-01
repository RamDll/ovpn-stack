<script setup lang="ts">
import { onMounted } from 'vue'
import AppShell from '@/components/AppShell.vue'
import UsersView from '@/components/UsersView.vue'
import StatisticsView from '@/components/StatisticsView.vue'
import ToastHost from '@/components/ToastHost.vue'
import { useServerSettings } from '@/composables/useServerSettings'
import { useUsers } from '@/composables/useUsers'
import { useToasts } from '@/composables/useToasts'
import { useView } from '@/composables/useView'
import { useI18n } from 'vue-i18n'

const settings = useServerSettings()
const users = useUsers()
const toasts = useToasts()
const { view } = useView()
const { t } = useI18n()

onMounted(async () => {
  try {
    await settings.load()
  } catch (e) {
    toasts.error(t('toast.settingsError'), e instanceof Error ? e.message : undefined)
  }
  await users.refresh()
})
</script>

<template>
  <AppShell>
    <UsersView v-if="view === 'users'" />
    <StatisticsView v-else />
  </AppShell>
  <ToastHost />
</template>
