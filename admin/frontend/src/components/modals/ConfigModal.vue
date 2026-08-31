<script setup lang="ts">
import { ref, watch } from 'vue'
import ModalShell from '../ModalShell.vue'
import { ovpn } from '@/api/ovpn'
import { useToasts } from '@/composables/useToasts'

const props = defineProps<{ open: boolean; username: string }>()
const emit = defineEmits<{ 'update:open': [value: boolean] }>()

const toasts = useToasts()
const config = ref('')
const loading = ref(false)
const error = ref('')

watch(
  () => props.open,
  async (o) => {
    if (!o) return
    config.value = ''
    error.value = ''
    loading.value = true
    try {
      config.value = await ovpn.showConfig(props.username)
    } catch (e) {
      error.value = e instanceof Error ? e.message : String(e)
    } finally {
      loading.value = false
    }
  },
  { immediate: true },
)

async function copy() {
  try {
    await navigator.clipboard.writeText(config.value)
    toasts.success('Конфиг скопирован')
  } catch {
    toasts.error('Буфер обмена недоступен')
  }
}

function download() {
  const blob = new Blob([config.value], { type: 'text/plain' })
  const link = document.createElement('a')
  link.href = URL.createObjectURL(blob)
  link.download = `${props.username}.ovpn`
  link.click()
  URL.revokeObjectURL(link.href)
}
</script>

<template>
  <ModalShell
    :open="open"
    title="Конфигурация клиента"
    :description="username"
    wide
    @update:open="emit('update:open', $event)"
  >
    <p v-if="error" class="alert alert-error">{{ error }}</p>
    <pre v-else class="config">{{ loading ? 'Загрузка…' : config }}</pre>

    <template #footer>
      <button class="btn btn-ghost" type="button" @click="emit('update:open', false)">Закрыть</button>
      <button class="btn btn-ghost" type="button" :disabled="!config" @click="copy">Копировать</button>
      <button class="btn btn-primary" type="button" :disabled="!config" @click="download">
        Скачать .ovpn
      </button>
    </template>
  </ModalShell>
</template>

<style scoped>
.config {
  margin: 0;
  font-family: var(--mono);
  font-size: var(--fs-xs);
  line-height: 1.7;
  color: var(--text-dim);
  background: var(--bg);
  border: 1px solid var(--border);
  border-radius: var(--r-sm);
  padding: 12px 14px;
  max-height: 46vh;
  overflow: auto;
  white-space: pre-wrap;
  word-break: break-all;
}
</style>
