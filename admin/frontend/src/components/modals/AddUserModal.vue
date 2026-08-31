<script setup lang="ts">
import { ref, watch } from 'vue'
import ModalShell from '../ModalShell.vue'
import { useUserActions } from '@/composables/useUserActions'
import { useServerSettings } from '@/composables/useServerSettings'
import { ApiError } from '@/api/client'

const props = defineProps<{ open: boolean }>()
const emit = defineEmits<{ 'update:open': [value: boolean] }>()

const { create } = useUserActions()
const { hasModule } = useServerSettings()

const name = ref('')
const password = ref('')
const busy = ref(false)
const error = ref('')

const NAME_RE = /^[a-zA-Z0-9_.\-@]+$/

watch(
  () => props.open,
  (o) => {
    if (o) {
      name.value = ''
      password.value = ''
      error.value = ''
      busy.value = false
    }
  },
  { immediate: true },
)

async function submit() {
  error.value = ''
  if (!NAME_RE.test(name.value)) {
    error.value = 'Имя: только a-z A-Z 0-9 . _ - @'
    return
  }
  busy.value = true
  try {
    await create(name.value, password.value || 'nopass')
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
    title="Новый пользователь"
    @update:open="emit('update:open', $event)"
  >
    <form class="form" @submit.prevent="submit">
      <div class="field">
        <label for="au-name">Common name</label>
        <input
          id="au-name"
          v-model="name"
          class="input"
          type="text"
          autocomplete="off"
          spellcheck="false"
          autofocus
        />
        <span class="hint">a-z A-Z 0-9 . _ - @</span>
      </div>
      <div v-if="hasModule('passwdAuth')" class="field">
        <label for="au-pass">Пароль</label>
        <input
          id="au-pass"
          v-model="password"
          class="input"
          type="password"
          minlength="6"
          autocomplete="new-password"
        />
      </div>
      <p v-if="error" class="alert alert-error">{{ error }}</p>
    </form>

    <template #footer>
      <button class="btn btn-ghost" type="button" :disabled="busy" @click="emit('update:open', false)">
        Отмена
      </button>
      <button class="btn btn-primary" type="button" :disabled="busy || !name" @click="submit">
        {{ busy ? 'Создаём…' : 'Создать и выпустить сертификат' }}
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
</style>
