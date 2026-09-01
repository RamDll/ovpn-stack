<script setup lang="ts">
import { ref, watch, computed } from 'vue'
import { useI18n } from 'vue-i18n'
import ModalShell from '../ModalShell.vue'
import { useUserActions } from '@/composables/useUserActions'
import { ApiError } from '@/api/client'

export type ConfirmKind = 'revoke' | 'unrevoke' | 'delete' | 'disconnect'

const props = defineProps<{ open: boolean; username: string; kind: ConfirmKind }>()
const emit = defineEmits<{ 'update:open': [value: boolean] }>()

const { t } = useI18n()
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

const runner = computed(() => {
  switch (props.kind) {
    case 'revoke': return { tone: 'btn-warn', run: actions.revoke }
    case 'unrevoke': return { tone: 'btn-primary', run: actions.unrevoke }
    case 'delete': return { tone: 'btn-danger', run: actions.remove }
    case 'disconnect': return { tone: 'btn-warn', run: actions.disconnect }
  }
  return { tone: 'btn-primary', run: actions.revoke }
})

async function confirm() {
  error.value = ''
  busy.value = true
  try {
    await runner.value.run(props.username)
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
    :title="t(`confirm.${kind}.title`)"
    :description="username"
    @update:open="emit('update:open', $event)"
  >
    <p class="q">{{ t(`confirm.${kind}.text`) }}</p>
    <p v-if="error" class="alert alert-error">{{ error }}</p>

    <template #footer>
      <button class="btn btn-ghost" type="button" :disabled="busy" @click="emit('update:open', false)">
        {{ t('common.cancel') }}
      </button>
      <button class="btn" :class="runner.tone" type="button" :disabled="busy" @click="confirm">
        {{ busy ? '…' : t(`confirm.${kind}.verb`) }}
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
