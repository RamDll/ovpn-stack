import { createApp } from 'vue'
import './styles/base.css'
import './composables/useTheme' // проставляет data-theme до первого рендера
import { i18n } from './i18n'
import App from './App.vue'

createApp(App).use(i18n).mount('#app')
