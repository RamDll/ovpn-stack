import { ref } from 'vue'

export type View = 'users' | 'statistics'

const view = ref<View>('users')

export function useView() {
  return {
    view,
    go: (v: View) => {
      view.value = v
    },
  }
}
