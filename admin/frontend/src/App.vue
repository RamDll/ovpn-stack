<script setup lang="ts">
import { onMounted } from 'vue'
import AppShell from '@/components/AppShell.vue'
import UsersView from '@/components/UsersView.vue'
import ToastHost from '@/components/ToastHost.vue'
import { useServerSettings } from '@/composables/useServerSettings'
import { useUsers } from '@/composables/useUsers'
import { useToasts } from '@/composables/useToasts'

const settings = useServerSettings()
const users = useUsers()
const toasts = useToasts()

onMounted(async () => {
  try {
    await settings.load()
  } catch (e) {
    toasts.error('Не удалось получить настройки сервера', e instanceof Error ? e.message : undefined)
  }
  await users.refresh()
})
</script>

<template>
  <AppShell>
    <UsersView />
  </AppShell>
  <ToastHost />
</template>
