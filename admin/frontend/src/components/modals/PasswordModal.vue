<script setup lang="ts">
import { ref, watch } from 'vue'
import { useI18n } from 'vue-i18n'
import ModalShell from '../ModalShell.vue'
import { useUserActions } from '@/composables/useUserActions'
import { ApiError } from '@/api/client'

const props = defineProps<{
  open: boolean
  username: string
  mode: 'change' | 'rotate'
  askPassword: boolean
}>()
const emit = defineEmits<{ 'update:open': [value: boolean] }>()

const EXPIRE_DEFAULT = 825

const { t } = useI18n()
const { changePassword, rotate } = useUserActions()

const password = ref('')
const expireDays = ref(EXPIRE_DEFAULT)
const busy = ref(false)
const error = ref('')

watch(
  () => props.open,
  (o) => {
    if (o) {
      password.value = ''
      expireDays.value = EXPIRE_DEFAULT
      error.value = ''
      busy.value = false
    }
  },
  { immediate: true },
)

async function submit() {
  error.value = ''
  if (props.mode === 'change' && password.value.length < 6) {
    error.value = t('password.minLen')
    return
  }
  busy.value = true
  try {
    if (props.mode === 'change') {
      await changePassword(props.username, password.value)
    } else {
      const days = Math.min(3650, Math.max(1, Math.round(expireDays.value || EXPIRE_DEFAULT)))
      await rotate(props.username, password.value || 'nopass', days)
    }
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
    :title="mode === 'change' ? t('password.changeTitle') : t('password.rotateTitle')"
    :description="username"
    @update:open="emit('update:open', $event)"
  >
    <form class="form" @submit.prevent="submit">
      <p v-if="mode === 'rotate'" class="note">{{ t('password.rotateNote') }}</p>
      <div v-if="askPassword || mode === 'change'" class="field">
        <label for="pm-pass">{{ t('password.newPassword') }}</label>
        <input id="pm-pass" v-model="password" class="input" type="password" minlength="6" autocomplete="new-password" autofocus />
      </div>
      <div v-if="mode === 'rotate'" class="field">
        <label for="pm-expire">{{ t('addUser.expire') }}</label>
        <input id="pm-expire" v-model.number="expireDays" class="input" type="number" min="1" max="3650" step="1" />
        <span class="hint">{{ t('addUser.expireHint') }}</span>
      </div>
      <p v-if="error" class="alert alert-error">{{ error }}</p>
    </form>

    <template #footer>
      <button class="btn btn-ghost" type="button" :disabled="busy" @click="emit('update:open', false)">
        {{ t('common.cancel') }}
      </button>
      <button
        class="btn"
        :class="mode === 'rotate' ? 'btn-warn' : 'btn-primary'"
        type="button"
        :disabled="busy"
        @click="submit"
      >
        {{ busy ? '…' : mode === 'change' ? t('password.changeSubmit') : t('password.rotateSubmit') }}
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
