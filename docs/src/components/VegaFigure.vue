<script setup lang="ts">
import { onMounted, onBeforeUnmount, ref } from 'vue'
import { withBase } from 'vitepress'

const props = defineProps<{ src: string; plotId: string; caption: string }>()
const error = ref('')
const controller = new AbortController()
let mounted = true

onMounted(async () => {
  try {
    const response = await fetch(withBase('/' + props.src), { signal: controller.signal })
    if (!response.ok) throw new Error(`Figure request failed: ${response.status}`)
    const spec = await response.json()
    if (!mounted) return
    const runtime = (window as any).AoV
    if (!runtime) throw new Error('AlgebraOfVega runtime is unavailable')
    await runtime.embed(props.plotId, spec, { actions: false })
  } catch (cause) {
    if (mounted) error.value = String(cause)
  }
})
onBeforeUnmount(() => {
  mounted = false
  controller.abort()
  ;(window as any).AoV?.dispose(props.plotId)
})
</script>

<template>
  <figure class="docs-figure">
    <div :id="plotId" :aria-label="caption" />
    <p v-if="error" role="alert">{{ error }}</p>
    <figcaption>{{ caption }}</figcaption>
  </figure>
</template>

<style scoped>
.docs-figure { margin: 24px 0; min-width: 0; color: #0b0b0b; }
:global(.dark .docs-figure) { color: var(--vp-c-text-1); }
figcaption { margin-top: 12px; font-size: 14px; line-height: 1.6; }
[role="alert"] { color: var(--vp-c-danger-1); }
</style>
