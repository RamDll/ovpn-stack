import { fileURLToPath, URL } from 'node:url'
import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

// Собираем прямо в frontend/static/ — оттуда Go встраивает через //go:embed.
// base: './' — относительные пути к ассетам, работает под любым OVPN_LISTEN_BASE_URL.
export default defineConfig({
  base: './',
  plugins: [vue()],
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url)),
    },
  },
  build: {
    outDir: 'static',
    emptyOutDir: true,
    assetsDir: 'assets',
    chunkSizeWarningLimit: 900,
  },
  server: {
    port: 5173,
    // dev: проксируем API на локально поднятый ovpn-admin
    proxy: {
      '/api': { target: 'http://127.0.0.1:8080', changeOrigin: true },
    },
  },
})
