import adapter from '@sveltejs/adapter-static';
import { sveltekit } from '@sveltejs/kit/vite';
import tailwindcss from '@tailwindcss/vite';
import { defineConfig } from 'vite';
import pkg from './package.json' with { type: 'json' };

export default defineConfig({
  server: {
    proxy: { '/api': 'http://127.0.0.1:8080' }
  },
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
      // Pin SvelteKit's build version instead of Date.now() so Nix builds are reproducible.
      version: {
        name: pkg.version
      },
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
