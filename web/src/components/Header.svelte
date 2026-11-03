<script lang="ts">
  interface Props {
    searchQuery: string;
    sourceName: string;
    onSearchChange: (val: string) => void;
    onOpenImport: () => void;
    onOpenNewDetour?: () => void;
    onExportJson?: () => void;
  }

  let { searchQuery, sourceName, onSearchChange, onOpenImport, onOpenNewDetour, onExportJson }: Props = $props();
</script>

<header class="border-b border-stone-800 bg-stone-950/80 backdrop-blur-md sticky top-0 z-40">
  <div class="max-w-7xl mx-auto px-4 sm:px-6 py-4 flex flex-col sm:flex-row items-stretch sm:items-center justify-between gap-4">
    <!-- Brand -->
    <div class="flex items-center gap-3">
      <div class="w-9 h-9 rounded-xl bg-amber-500/10 border border-amber-500/30 flex items-center justify-center text-lg">
        🔀
      </div>
      <div>
        <div class="flex items-center gap-2">
          <h1 class="text-xl font-bold font-mono tracking-tight text-stone-100">nix-detour</h1>
          <span class="text-[10px] font-mono uppercase px-1.5 py-0.5 rounded bg-amber-950/80 text-amber-300 border border-amber-800/60 font-semibold">
            fleet
          </span>
        </div>
        <p class="text-xs text-stone-400">
          Source: <span class="text-stone-300 font-mono">{sourceName}</span>
        </p>
      </div>
    </div>

    <!-- Search & Actions -->
    <div class="flex items-center gap-3">
      <div class="relative flex-1 sm:w-72">
        <input
          type="text"
          value={searchQuery}
          oninput={(e) => onSearchChange((e.target as HTMLInputElement).value)}
          placeholder="Filter packages, reasons, attrs..."
          class="w-full bg-stone-900/90 border border-stone-800 rounded-xl pl-9 pr-3 py-1.5 text-xs text-stone-200 placeholder:text-stone-500 focus:outline-none focus:border-amber-500/80 focus:ring-1 focus:ring-amber-500/30 font-mono transition"
        />
        <svg class="w-4 h-4 text-stone-500 absolute left-3 top-2.5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z" />
        </svg>
      </div>

      {#if onOpenNewDetour}
        <button
          type="button"
          onclick={onOpenNewDetour}
          class="inline-flex items-center gap-1.5 px-3 py-1.5 bg-amber-500 hover:bg-amber-400 text-stone-950 font-bold rounded-xl text-xs font-mono transition cursor-pointer shrink-0 shadow-sm shadow-amber-500/20"
        >
          <span>➕</span>
          <span>New Detour</span>
        </button>
      {/if}

      <button
        type="button"
        onclick={onOpenImport}
        class="inline-flex items-center gap-1.5 px-3 py-1.5 bg-stone-900 hover:bg-stone-800 border border-stone-700/80 rounded-xl text-xs font-medium text-stone-200 transition cursor-pointer shrink-0"
      >
        <svg class="w-3.5 h-3.5 text-amber-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-8l-4-4m0 0L8 8m4-4v12" />
        </svg>
        <span>Import</span>
      </button>

      {#if onExportJson}
        <button
          type="button"
          onclick={onExportJson}
          title="Export current JSON files"
          class="inline-flex items-center gap-1.5 px-3 py-1.5 bg-stone-900 hover:bg-stone-800 border border-stone-700/80 rounded-xl text-xs font-medium text-stone-200 transition cursor-pointer shrink-0"
        >
          <svg class="w-3.5 h-3.5 text-cyan-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-4l-4 4m0 0l-4-4m4 4V4" />
          </svg>
          <span>Export</span>
        </button>
      {/if}

      <a
        href="https://github.com/kleinbem-dev/nix-detour"
        target="_blank"
        rel="noopener noreferrer"
        class="p-2 rounded-xl bg-stone-900 hover:bg-stone-800 border border-stone-800 text-stone-400 hover:text-stone-200 transition"
        title="View GitHub repository"
      >
        <svg class="w-4 h-4 fill-current" viewBox="0 0 24 24">
          <path fill-rule="evenodd" clip-rule="evenodd" d="M12 2C6.477 2 2 6.484 2 12.017c0 4.425 2.865 8.18 6.839 9.504.5.092.682-.217.682-.483 0-.237-.008-.868-.013-1.703-2.782.605-3.369-1.343-3.369-1.343-.454-1.158-1.11-1.466-1.11-1.466-.908-.62.069-.608.069-.608 1.003.07 1.53 1.032 1.53 1.032.892 1.53 2.341 1.088 2.91.832.092-.647.35-1.088.636-1.338-2.22-.253-4.555-1.113-4.555-4.951 0-1.093.39-1.988 1.029-2.688-.103-.253-.446-1.272.098-2.65 0 0 .84-.27 2.75 1.026A9.564 9.564 0 0112 6.844c.85.004 1.705.115 2.504.337 1.909-1.296 2.747-1.027 2.747-1.027.546 1.379.202 2.398.1 2.651.64.7 1.028 1.595 1.028 2.688 0 3.848-2.339 4.695-4.566 4.943.359.309.678.92.678 1.855 0 1.338-.012 2.419-.012 2.747 0 .268.18.58.688.482A10.019 10.019 0 0022 12.017C22 6.484 17.522 2 12 2z"/>
        </svg>
      </a>
    </div>
  </div>
</header>
