import { defineWebConfig } from '@kleinbem/web-config/vite';

export default defineWebConfig({
  // Nothing is prerendered, so the SPA shell itself is index.html (server.py serves it).
  adapterOptions: { fallback: 'index.html' },
  server: {
    proxy: { '/api': 'http://127.0.0.1:8080' }
  }
});
