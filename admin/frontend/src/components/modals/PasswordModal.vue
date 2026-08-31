<script setup lang="ts">
import { ref, watch } from 'vue'
import ModalShell from '../ModalShell.vue'
import { useUserActions } from '@/composables/useUserActions'
import { ApiError } from '@/api/client'

const props = defineProps<{
  open: boolean
  username: string
  /** 'change' — сменить пароль; 'rotate' — перевыпуск сертификата (пароль опционален) */
  mode: 'change' | 'rotate'
  /** показывать поле пароля (passwdAuth включён) */
  askPassword: boolean
}>()
const emit = defineEmits<{ 'update:open': [value: boolean] }>()

const { changePassword, rotate } = useUserActions()

const password = ref('')
const busy = ref(false)
const error = ref('')

watch(
  () => props.open,
  (o) => {
    if (o) {
      password.value = ''
      error.value = ''
      busy.value = false
    }
  },
  { immediate: true },
)

async function submit() {
  error.value = ''
  if (props.mode === 'change' && password.value.length < 6) {
    error.value = 'Минимум 6 символов'
    return
  }
  busy.value = true
  try {
    if (props.mode === 'change') {
      await changePassword(props.username, password.value)
    } else {
      await rotate(props.username, password.value || 'nopass')
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
    :title="mode === 'change' ? 'Смена пароля' : 'Перевыпуск сертификата'"
    :description="username"
    @update:open="emit('update:open', $event)"
  >
    <form class="form" @submit.prevent="submit">
      <p v-if="mode === 'rotate'" class="note">
        Текущий сертификат будет отозван и выпущен новый. Клиенту нужен новый
        <code>.ovpn</code>.
      </p>
      <div v-if="askPassword || mode === 'change'" class="field">
        <label for="pm-pass">Новый пароль</label>
        <input
          id="pm-pass"
          v-model="password"
          class="input"
          type="password"
          minlength="6"
          autocomplete="new-password"
          autofocus
        />
      </div>
      <p v-if="error" class="alert alert-error">{{ error }}</p>
    </form>

    <template #footer>
      <button class="btn btn-ghost" type="button" :disabled="busy" @click="emit('update:open', false)">
        Отмена
      </button>
      <button
        class="btn"
        :class="mode === 'rotate' ? 'btn-warn' : 'btn-primary'"
        type="button"
        :disabled="busy"
        @click="submit"
      >
        {{ busy ? '…' : mode === 'change' ? 'Сменить пароль' : 'Перевыпустить' }}
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
.note code {
  font-family: var(--mono);
  color: var(--text);
}
</style>
