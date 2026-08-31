<script setup lang="ts">
import { ref, watch, computed } from 'vue'
import ModalShell from '../ModalShell.vue'
import { useUserActions } from '@/composables/useUserActions'
import { ApiError } from '@/api/client'

export type ConfirmKind = 'revoke' | 'unrevoke' | 'delete' | 'disconnect'

const props = defineProps<{ open: boolean; username: string; kind: ConfirmKind }>()
const emit = defineEmits<{ 'update:open': [value: boolean] }>()

const actions = useUserActions()
const busy = ref(false)
const error = ref('')

watch(
  () => props.open,
  (o) => {
    if (o) {
      error.value = ''
      busy.value = false
    }
  },
  { immediate: true },
)

const spec = computed(() => {
  switch (props.kind) {
    case 'revoke':
      return { title: 'Отозвать сертификат', verb: 'Отозвать', tone: 'btn-warn', run: actions.revoke }
    case 'unrevoke':
      return { title: 'Восстановить пользователя', verb: 'Восстановить', tone: 'btn-primary', run: actions.unrevoke }
    case 'delete':
      return { title: 'Удалить пользователя', verb: 'Удалить', tone: 'btn-danger', run: actions.remove }
    case 'disconnect':
      return { title: 'Разорвать сессию', verb: 'Отключить', tone: 'btn-warn', run: actions.disconnect }
  }
  return { title: '', verb: '', tone: 'btn-primary', run: actions.revoke }
})

async function confirm() {
  error.value = ''
  busy.value = true
  try {
    await spec.value.run(props.username)
    emit('update:open', false)
  } catch (e) {
    error.value = e instanceof ApiError ? e.message : String(e)
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <ModalShell
    :open="open"
    :title="spec.title"
    :description="username"
    @update:open="emit('update:open', $event)"
  >
    <p class="q">
      <template v-if="kind === 'delete'">
        Пользователь и его сертификат будут удалены безвозвратно.
      </template>
      <template v-else-if="kind === 'revoke'">
        Сертификат попадёт в CRL, клиент больше не подключится.
      </template>
      <template v-else-if="kind === 'disconnect'">
        Активное соединение будет разорвано. Клиент с валидным сертификатом
        сможет переподключиться.
      </template>
      <template v-else>Сертификат будет убран из CRL и снова станет валидным.</template>
    </p>
    <p v-if="error" class="alert alert-error">{{ error }}</p>

    <template #footer>
      <button class="btn btn-ghost" type="button" :disabled="busy" @click="emit('update:open', false)">
        Отмена
      </button>
      <button class="btn" :class="spec.tone" type="button" :disabled="busy" @click="confirm">
        {{ busy ? '…' : spec.verb }}
      </button>
    </template>
  </ModalShell>
</template>

<style scoped>
.q {
  margin: 0 0 12px;
  color: var(--text-dim);
  font-size: var(--fs-sm);
}
</style>
