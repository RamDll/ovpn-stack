<script setup lang="ts">
import { ref, reactive, watch, computed } from 'vue'
import { useI18n } from 'vue-i18n'
import ModalShell from '../ModalShell.vue'
import { ovpn } from '@/api/ovpn'
import { useUserActions } from '@/composables/useUserActions'
import { ApiError } from '@/api/client'
import type { Ccd, CcdRoute } from '@/api/types'

const props = defineProps<{ open: boolean; username: string }>()
const emit = defineEmits<{ 'update:open': [value: boolean] }>()

const { t } = useI18n()
const { applyCcd } = useUserActions()

const ccd = reactive<Ccd>({ User: '', ClientAddress: '', CustomRoutes: [] })
const draft = reactive<CcdRoute>({ Address: '', Mask: '', Description: '' })
const loading = ref(false)
const busy = ref(false)
const error = ref('')

const isDynamic = computed(() => !ccd.ClientAddress || ccd.ClientAddress === 'dynamic')

watch(
  () => props.open,
  async (o) => {
    if (!o) return
    error.value = ''
    loading.value = true
    Object.assign(draft, { Address: '', Mask: '', Description: '' })
    try {
      const data = await ovpn.getCcd(props.username)
      ccd.User = data.User ?? props.username
      ccd.ClientAddress = data.ClientAddress ?? ''
      ccd.CustomRoutes = Array.isArray(data.CustomRoutes) ? data.CustomRoutes : []
    } catch (e) {
      error.value = e instanceof Error ? e.message : String(e)
    } finally {
      loading.value = false
    }
  },
  { immediate: true },
)

function addRoute() {
  if (!draft.Address && !draft.Mask) return
  ccd.CustomRoutes.push({ ...draft })
  Object.assign(draft, { Address: '', Mask: '', Description: '' })
}
function removeRoute(i: number) {
  ccd.CustomRoutes.splice(i, 1)
}

async function save() {
  error.value = ''
  busy.value = true
  try {
    await applyCcd(props.username, {
      User: ccd.User,
      ClientAddress: ccd.ClientAddress || 'dynamic',
      CustomRoutes: ccd.CustomRoutes,
    })
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
    :title="t('ccd.title')"
    :description="username"
    wide
    @update:open="emit('update:open', $event)"
  >
    <p v-if="loading" class="muted">{{ t('common.loading') }}</p>
    <template v-else>
      <div class="field">
        <label>{{ t('ccd.staticAddress') }}</label>
        <div class="addr-row">
          <input v-model="ccd.ClientAddress" class="input" type="text" placeholder="dynamic" />
          <button
            class="btn btn-ghost"
            type="button"
            :disabled="isDynamic"
            @click="ccd.ClientAddress = 'dynamic'"
          >
            {{ t('ccd.reset') }}
          </button>
        </div>
      </div>

      <div class="routes">
        <table>
          <thead>
            <tr>
              <th>{{ t('ccd.address') }}</th>
              <th>{{ t('ccd.mask') }}</th>
              <th>{{ t('ccd.description') }}</th>
              <th />
            </tr>
          </thead>
          <tbody>
            <tr v-for="(r, i) in ccd.CustomRoutes" :key="i">
              <td><input v-model="r.Address" class="input sm" /></td>
              <td><input v-model="r.Mask" class="input sm" /></td>
              <td><input v-model="r.Description" class="input sm" /></td>
              <td class="del">
                <button class="btn btn-ghost sm" type="button" :aria-label="t('ccd.removeRoute')" @click="removeRoute(i)">✕</button>
              </td>
            </tr>
            <tr class="draft">
              <td><input v-model="draft.Address" class="input sm" placeholder="10.0.0.0" /></td>
              <td><input v-model="draft.Mask" class="input sm" placeholder="255.255.255.0" /></td>
              <td><input v-model="draft.Description" class="input sm" :placeholder="t('ccd.descPlaceholder')" /></td>
              <td class="del">
                <button class="btn btn-primary sm" type="button" :aria-label="t('ccd.addRoute')" @click="addRoute">+</button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <p v-if="error" class="alert alert-error">{{ error }}</p>
    </template>

    <template #footer>
      <button class="btn btn-ghost" type="button" :disabled="busy" @click="emit('update:open', false)">
        {{ t('common.cancel') }}
      </button>
      <button class="btn btn-primary" type="button" :disabled="busy || loading" @click="save">
        {{ busy ? t('common.saving') : t('common.save') }}
      </button>
    </template>
  </ModalShell>
</template>

<style scoped>
.muted {
  color: var(--text-faint);
  font-size: var(--fs-sm);
  font-family: var(--mono);
}
.field {
  margin-bottom: 16px;
}
.addr-row {
  display: flex;
  gap: 8px;
}
.addr-row .input {
  flex: 1;
}
.routes {
  overflow-x: auto;
}
.routes table {
  width: 100%;
  border-collapse: collapse;
  min-width: 460px;
}
.routes th {
  text-align: left;
  padding: 4px 6px;
  font-size: var(--fs-xs);
  text-transform: uppercase;
  letter-spacing: 0.06em;
  color: var(--text-faint);
  font-weight: 600;
}
.routes td {
  padding: 3px 6px;
}
.routes td.del {
  width: 34px;
}
.input.sm {
  padding: 6px 8px;
  font-size: var(--fs-xs);
}
.btn.sm {
  padding: 6px 9px;
  font-size: var(--fs-xs);
}
.routes tr.draft td {
  border-top: 1px solid var(--border-soft);
  padding-top: 8px;
}
</style>
