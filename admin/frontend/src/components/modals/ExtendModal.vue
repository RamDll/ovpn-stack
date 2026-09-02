<script setup lang="ts">
import { ref, watch } from 'vue'
import { useI18n } from 'vue-i18n'
import ModalShell from '../ModalShell.vue'
import { useUserActions } from '@/composables/useUserActions'
import { ApiError } from '@/api/client'

const EXPIRE_DEFAULT = 825

const props = defineProps<{ open: boolean; username: string }>()
const emit = defineEmits<{ 'update:open': [value: boolean] }>()

const { t } = useI18n()
const { extend } = useUserActions()

const expireDays = ref(EXPIRE_DEFAULT)
const busy = ref(false)
const error = ref('')

watch(
  () => props.open,
  (o) => {
    if (o) {
      expireDays.value = EXPIRE_DEFAULT
      error.value = ''
      busy.value = false
    }
  },
  { immediate: true },
)

async function submit() {
  error.value = ''
  const days = Math.min(3650, Math.max(1, Math.round(expireDays.value || EXPIRE_DEFAULT)))
  busy.value = true
  try {
    await extend(props.username, days)
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
    :title="t('extend.title')"
    :description="username"
    @update:open="emit('update:open', $event)"
  >
    <form class="form" @submit.prevent="submit">
      <p class="note">{{ t('extend.note') }}</p>
      <div class="field">
        <label for="ex-days">{{ t('addUser.expire') }}</label>
        <input id="ex-days" v-model.number="expireDays" class="input" type="number" min="1" max="3650" step="1" autofocus />
        <span class="hint">{{ t('addUser.expireHint') }}</span>
      </div>
      <p v-if="error" class="alert alert-error">{{ error }}</p>
    </form>

    <template #footer>
      <button class="btn btn-ghost" type="button" :disabled="busy" @click="emit('update:open', false)">
        {{ t('common.cancel') }}
      </button>
      <button class="btn btn-primary" type="button" :disabled="busy" @click="submit">
        {{ busy ? '…' : t('extend.submit') }}
      </button>
    </template>
  </ModalShell>
</template>

<style scoped>
.form {
  display: flex;
  flex-direction: column;
  gap: 14px;
}
.note {
  margin: 0;
  color: var(--text-dim);
  font-size: var(--fs-sm);
}
</style>
