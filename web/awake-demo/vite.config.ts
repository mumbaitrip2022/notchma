import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { resolve } from 'node:path'

// Builds the Keep Awake demo into docs/awake-demo.js and docs/awake-demo.css.
export default defineConfig({
  plugins: [react()],
  // Preact runs the same React code at a fraction of the size
  resolve: { alias: { react: 'preact/compat', 'react-dom/client': 'preact/compat/client', 'react-dom': 'preact/compat', 'react/jsx-runtime': 'preact/jsx-runtime' } },
  define: { 'process.env.NODE_ENV': '"production"' },
  build: {
    target: 'es2020',
    outDir: resolve(__dirname, '../../docs'),
    emptyOutDir: false,
    assetsInlineLimit: 20_000,
    cssCodeSplit: false,
    lib: { entry: resolve(__dirname, 'main.tsx'), name: 'AwakeDemo', formats: ['iife'], fileName: () => 'awake-demo.js', cssFileName: 'awake-demo' },
  },
})
