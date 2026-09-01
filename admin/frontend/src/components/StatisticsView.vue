<script setup lang="ts">
import { useI18n } from 'vue-i18n'
const { t } = useI18n()
</script>

<template>
  <div class="page-head">
    <h1>{{ t('nav.statistics') }}</h1>
  </div>
  <div class="stub">Раздел в разработке (P2).</div>
</template>

<style scoped>
.page-head {
  margin-bottom: 18px;
}
.page-head h1 {
  margin: 0;
  font-size: var(--fs-xl);
  font-weight: 600;
  letter-spacing: -0.01em;
}
.stub {
  padding: 40px;
  text-align: center;
  color: var(--text-faint);
  font-family: var(--mono);
  font-size: var(--fs-sm);
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--r);
}
</style>
