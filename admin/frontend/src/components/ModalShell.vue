<script setup lang="ts">
import {
  DialogRoot,
  DialogPortal,
  DialogOverlay,
  DialogContent,
  DialogTitle,
  DialogDescription,
  DialogClose,
} from 'reka-ui'
import { useI18n } from 'vue-i18n'

const { t } = useI18n()
defineProps<{
  open: boolean
  title: string
  description?: string
  wide?: boolean
}>()
const emit = defineEmits<{ 'update:open': [value: boolean] }>()
</script>

<template>
  <DialogRoot :open="open" @update:open="emit('update:open', $event)">
    <DialogPortal>
      <DialogOverlay class="overlay" />
      <DialogContent class="modal" :class="{ wide }">
        <header>
          <div>
            <DialogTitle class="title">{{ title }}</DialogTitle>
            <DialogDescription v-if="description" class="desc">{{ description }}</DialogDescription>
          </div>
          <DialogClose class="x" :aria-label="t('common.close')">{{ t('common.esc') }}</DialogClose>
        </header>
        <div class="body">
          <slot />
        </div>
        <footer v-if="$slots.footer">
          <slot name="footer" />
        </footer>
      </DialogContent>
    </DialogPortal>
  </DialogRoot>
</template>

<style scoped>
.overlay {
  position: fixed;
  inset: 0;
  background: rgba(6, 9, 15, 0.66);
  backdrop-filter: blur(2px);
  z-index: 50;
}
.modal {
  position: fixed;
  top: 12vh;
  left: 50%;
  transform: translateX(-50%);
  width: min(520px, calc(100vw - 40px));
  max-height: 76vh;
  display: flex;
  flex-direction: column;
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--r);
  box-shadow: var(--shadow-modal);
  z-index: 51;
}
.modal.wide {
  width: min(680px, calc(100vw - 40px));
}
header {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 12px;
  padding: 16px 18px;
  border-bottom: 1px solid var(--border);
}
.title {
  font-weight: 600;
  font-size: var(--fs-base);
  margin: 0;
}
.desc {
  margin: 3px 0 0;
  color: var(--text-dim);
  font-size: var(--fs-xs);
}
.x {
  all: unset;
  cursor: pointer;
  color: var(--text-faint);
  font-family: var(--mono);
  font-size: var(--fs-xs);
  padding: 3px 7px;
  border-radius: 4px;
  flex: none;
}
.x:hover {
  color: var(--text);
  background: var(--surface-2);
}
.body {
  padding: 18px;
  overflow-y: auto;
}
footer {
  padding: 14px 18px;
  border-top: 1px solid var(--border);
  display: flex;
  gap: 8px;
  justify-content: flex-end;
  flex: none;
}
</style>
