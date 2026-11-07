import adapter from '@sveltejs/adapter-static';
import { sveltekit } from '@sveltejs/kit/vite';
import tailwindcss from '@tailwindcss/vite';
import { defineConfig } from 'vite';

export default defineConfig({
  plugins: [
    tailwindcss(),
    sveltekit({
      adapter: adapter({
        pages: 'dist',
        assets: 'dist',
        fallback: 'index.html',
        precompress: false,
        strict: true
      }),
      compilerOptions: {
        experimental: {
          async: true
        },
        fragments: 'html'
      },
      dynamicCompileOptions({ filename }) {
        if (!filename.includes('node_modules')) {
          return { runes: true };
        }
      },
      experimental: {
        forkPreloads: true
      }
    })
  ]
});
