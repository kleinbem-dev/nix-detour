<script lang="ts">
  import { onMount } from 'svelte';
  import { initialHolds, initialPrs } from './defaultData';
  import { parseHolds, parsePrs } from './utils';
  import type { HoldEntry, PrEntry, DetourItem, DetourKind } from './types';
  import Header from './components/Header.svelte';
  import StatsBar from './components/StatsBar.svelte';
  import DetourCard from './components/DetourCard.svelte';
  import DetailModal from './components/DetailModal.svelte';
  import ImportModal from './components/ImportModal.svelte';
  import NewDetourModal from './components/NewDetourModal.svelte';

  // Svelte 5 state
  let rawHolds = $state<Record<string, HoldEntry>>(initialHolds);
  let rawPrs = $state<Record<string, PrEntry>>(initialPrs);
  let sourceName = $state('kleinbem/nix-detour-fleet (sample)');
  let isLocalApi = $state(false);

  let searchQuery = $state('');
  let currentFilter = $state<DetourKind | 'all' | 'stale'>('all');
  let selectedItem = $state<DetourItem | null>(null);
  let showImportModal = $state(false);
  let showNewDetourModal = $state(false);

  // Derived detours list
  let allItems = $derived.by(() => {
    const holds = parseHolds(rawHolds);
    const prs = parsePrs(rawPrs);
    return [...holds, ...prs];
  });

  // Derived stats
  let holdsCount = $derived(allItems.filter(i => i.kind === 'hold').length);
  let fixesCount = $derived(allItems.filter(i => i.kind === 'fix').length);
  let prsCount = $derived(allItems.filter(i => i.kind === 'pr').length);
  let staleCount = $derived(allItems.filter(i => i.ageDays > 14).length);

  // Filtered items
  let filteredItems = $derived.by(() => {
    const q = searchQuery.toLowerCase().trim();
    return allItems.filter(item => {
      // Filter tab
      if (currentFilter === 'stale') {
        if (item.ageDays <= 14) return false;
      } else if (currentFilter !== 'all') {
        if (item.kind !== currentFilter) return false;
      }

      // Search query
      if (!q) return true;
      return (
        item.name.toLowerCase().includes(q) ||
        item.reason.toLowerCase().includes(q) ||
        (item.releaseWhen && item.releaseWhen.toLowerCase().includes(q)) ||
        (item.untilVersion && item.untilVersion.toLowerCase().includes(q)) ||
        (item.attrs && item.attrs.some(a => a.toLowerCase().includes(q))) ||
        (item.prNumber && String(item.prNumber).includes(q))
      );
    });
  });

  onMount(async () => {
    try {
      const res = await fetch('/api/data');
      if (res.ok) {
        const data = await res.json();
        const holdsCount = Object.keys(data.holds || {}).length;
        const prsCount = Object.keys(data.prs || {}).length;
        isLocalApi = true;
        if (holdsCount > 0 || prsCount > 0) {
          rawHolds = data.holds || {};
          rawPrs = data.prs || {};
          sourceName = 'Local Repository (live sync)';
        } else {
          // Local repo has no detours yet: show sample fleet preview so UI is populated
          rawHolds = initialHolds;
          rawPrs = initialPrs;
          sourceName = 'Local Repository (sample preview)';
        }
      }
    } catch {
      // Standalone mode without backend API
    }
  });

  async function handleCreateDetour(name: string, kind: DetourKind, entry: HoldEntry | PrEntry) {
    if (kind === 'pr') {
      rawPrs = { ...rawPrs, [name]: entry as PrEntry };
    } else {
      rawHolds = { ...rawHolds, [name]: entry as HoldEntry };
    }

    if (isLocalApi) {
      try {
        await fetch('/api/detour', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ name, kind, entry })
        });
      } catch (err) {
        console.error('Failed to sync to local disk:', err);
      }
    }
  }

  async function handleReleaseDetour(item: DetourItem) {
    if (item.kind === 'pr') {
      const next = { ...rawPrs };
      delete next[item.name];
      rawPrs = next;
    } else {
      const next = { ...rawHolds };
      delete next[item.name];
      rawHolds = next;
    }

    if (isLocalApi) {
      try {
        await fetch(`/api/release`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ name: item.name, kind: item.kind })
        });
      } catch (err) {
        console.error('Failed to sync release to disk:', err);
      }
    }
  }

  function handleExportJson() {
    const holdsBlob = new Blob([JSON.stringify(rawHolds, null, 2)], { type: 'application/json' });
    const prsBlob = new Blob([JSON.stringify(rawPrs, null, 2)], { type: 'application/json' });

    const download = (blob: Blob, filename: string) => {
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = filename;
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      URL.revokeObjectURL(url);
    };

    download(holdsBlob, 'held-packages.json');
    setTimeout(() => {
      download(prsBlob, 'nixpkgs-prs.json');
    }, 200);
  }

  function handleLoadData(newHolds: Record<string, HoldEntry>, newPrs: Record<string, PrEntry>, source: string) {
    rawHolds = newHolds;
    rawPrs = newPrs;
    sourceName = source;
  }

  function handleResetDefault() {
    rawHolds = initialHolds;
    rawPrs = initialPrs;
    sourceName = 'kleinbem/nix-detour-fleet (sample)';
  }
</script>

<div class="min-h-screen flex flex-col bg-stone-950 text-stone-100 font-sans">
  <Header
    {searchQuery}
    {sourceName}
    onSearchChange={(val) => { searchQuery = val; }}
    onOpenImport={() => { showImportModal = true; }}
    onOpenNewDetour={() => { showNewDetourModal = true; }}
    onExportJson={handleExportJson}
  />

  <main class="flex-1 max-w-7xl w-full mx-auto px-4 sm:px-6 py-8">
    <!-- Top banner / intro -->
    <div class="mb-8 flex flex-col sm:flex-row items-start sm:items-center justify-between gap-4 pb-6 border-b border-stone-800/80">
      <div>
        <h2 class="text-2xl font-bold tracking-tight text-stone-100">Active Detours</h2>
        <p class="text-sm text-stone-400 mt-1 max-w-2xl">
          Single packages taking a detour from nixpkgs (held back while broken, fixed with patches, or running ahead from open PRs) until upstream catches up.
        </p>
      </div>

      <div class="flex items-center gap-3">
        {#if isLocalApi}
          <div class="flex items-center gap-1.5 font-mono text-xs text-emerald-400 bg-emerald-950/40 border border-emerald-800/60 px-2.5 py-1 rounded-xl">
            <span class="w-1.5 h-1.5 rounded-full bg-emerald-400 animate-pulse"></span>
            <span>Live Sync (Disk)</span>
          </div>
        {/if}
        <div class="flex items-center gap-2 font-mono text-xs text-stone-400 bg-stone-900/90 px-3 py-1.5 rounded-xl border border-stone-800">
          <span class="w-2 h-2 rounded-full bg-amber-400 animate-pulse"></span>
          <span>{allItems.length} active packages</span>
        </div>
      </div>
    </div>

    <!-- Stats Bar & Filter selector -->
    <StatsBar
      total={allItems.length}
      {holdsCount}
      {fixesCount}
      {prsCount}
      {staleCount}
      {currentFilter}
      onFilterChange={(f) => { currentFilter = f; }}
    />

    <!-- Cards Grid -->
    {#if allItems.length === 0}
      <div class="text-center py-16 px-4 bg-stone-900/40 rounded-2xl border border-stone-800/60 max-w-lg mx-auto">
        <div class="text-4xl mb-3">📦</div>
        <h3 class="text-base font-semibold text-stone-200">No detours found</h3>
        <p class="text-xs text-stone-400 mt-1.5 leading-relaxed">
          There are no held packages or PR detours in this repository yet.
        </p>
        <div class="mt-6 flex flex-wrap items-center justify-center gap-3">
          <button
            type="button"
            onclick={() => { showNewDetourModal = true; }}
            class="px-4 py-2 bg-amber-500 hover:bg-amber-400 text-stone-950 font-bold rounded-xl text-xs font-mono transition cursor-pointer"
          >
            ➕ Create Detour
          </button>
          <button
            type="button"
            onclick={handleResetDefault}
            class="px-4 py-2 bg-stone-800 hover:bg-stone-700 text-stone-300 rounded-xl text-xs font-mono transition cursor-pointer"
          >
            Load Sample Fleet Data
          </button>
        </div>
      </div>
    {:else if filteredItems.length === 0}
      <div class="text-center py-16 px-4 bg-stone-900/40 rounded-2xl border border-stone-800/60 max-w-lg mx-auto">
        <div class="text-3xl mb-3">🔍</div>
        <h3 class="text-base font-semibold text-stone-300">No detours match your filter</h3>
        <p class="text-xs text-stone-500 mt-1">Try clearing your search query or switching categories.</p>
        <button
          type="button"
          onclick={() => { searchQuery = ''; currentFilter = 'all'; }}
          class="mt-4 px-3 py-1.5 rounded-lg bg-stone-800 hover:bg-stone-700 text-xs font-mono text-stone-300 transition cursor-pointer"
        >
          Reset filters
        </button>
      </div>
    {:else}
      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
        {#each filteredItems as item (item.id)}
          <DetourCard
            {item}
            onSelect={(selected) => { selectedItem = selected; }}
            onRelease={handleReleaseDetour}
          />
        {/each}
      </div>
    {/if}
  </main>

  <!-- Modals -->
  {#if selectedItem}
    <DetailModal
      item={selectedItem}
      onClose={() => { selectedItem = null; }}
    />
  {/if}

  {#if showImportModal}
    <ImportModal
      onLoadData={handleLoadData}
      onResetDefault={handleResetDefault}
      onClose={() => { showImportModal = false; }}
    />
  {/if}

  {#if showNewDetourModal}
    <NewDetourModal
      isOpen={showNewDetourModal}
      onClose={() => { showNewDetourModal = false; }}
      onCreateDetour={handleCreateDetour}
    />
  {/if}

  <!-- Footer -->
  <footer class="border-t border-stone-900 py-6 text-center text-xs text-stone-500 font-mono">
    <span>nix-detour &middot; declarative package holds &middot; kleinbem fleet</span>
  </footer>
</div>
