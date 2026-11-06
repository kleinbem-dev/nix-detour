<script lang="ts">
  import { onMount } from 'svelte';
  import { initialHolds, initialPrs } from '../defaultData';
  import { parseHolds, parsePrs } from '../utils';
  import type { HoldEntry, PrEntry, DetourItem, DetourKind, DetourFilter, PrStatusInfo, ViewMode, SortOption } from '../types';
  import Header from '../components/Header.svelte';
  import StatsBar from '../components/StatsBar.svelte';
  import DetourCard from '../components/DetourCard.svelte';
  import DetourListView from '../components/DetourListView.svelte';
  import DetailModal from '../components/DetailModal.svelte';
  import ImportModal from '../components/ImportModal.svelte';
  import NewDetourModal from '../components/NewDetourModal.svelte';

  // Svelte 5 state
  let rawHolds = $state<Record<string, HoldEntry>>(initialHolds);
  let rawPrs = $state<Record<string, PrEntry>>(initialPrs);
  let sourceName = $state('kleinbem/nix-detour-fleet (sample)');
  let isLocalApi = $state(false);
  let prStatuses = $state<Record<number, PrStatusInfo>>({});

  function getStoredViewMode(): ViewMode {
    try {
      if (typeof localStorage !== 'undefined') {
        const stored = localStorage.getItem('nix-detour-view-mode') as ViewMode;
        if (stored === 'grid' || stored === 'list') return stored;
      }
    } catch {}
    return 'grid';
  }

  function getStoredSortOption(): SortOption {
    try {
      if (typeof localStorage !== 'undefined') {
        const stored = localStorage.getItem('nix-detour-sort-option') as SortOption;
        if (stored) return stored;
      }
    } catch {}
    return 'age-desc';
  }

  let searchQuery = $state('');
  let currentFilter = $state<DetourFilter>('all');
  let viewMode = $state<ViewMode>(getStoredViewMode());
  let sortOption = $state<SortOption>(getStoredSortOption());

  function setViewMode(mode: ViewMode) {
    viewMode = mode;
    try {
      localStorage.setItem('nix-detour-view-mode', mode);
    } catch {}
  }

  function setSortOption(sort: SortOption) {
    sortOption = sort;
    try {
      localStorage.setItem('nix-detour-sort-option', sort);
    } catch {}
  }
  let selectedItem = $state<DetourItem | null>(null);
  let showImportModal = $state(false);
  let showNewDetourModal = $state(false);
  let toastMessage = $state<string | null>(null);
  let toastTimeout: ReturnType<typeof setTimeout> | null = null;

  // Errors stay longer: they can carry the CLI's message.
  function showToast(msg: string, ms = 3000) {
    if (toastTimeout) clearTimeout(toastTimeout);
    toastMessage = msg;
    toastTimeout = setTimeout(() => {
      toastMessage = null;
    }, ms);
  }

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
  let readyCount = $derived(
    allItems.filter(i => i.kind === 'pr' && i.prNumber && prStatuses[i.prNumber]?.inChannel).length
  );

  // Filtered items
  let filteredItems = $derived.by(() => {
    const q = searchQuery.toLowerCase().trim();
    return allItems.filter(item => {
      // Filter tab
      if (currentFilter === 'stale') {
        if (item.ageDays <= 14) return false;
      } else if (currentFilter === 'ready') {
        if (item.kind !== 'pr' || !item.prNumber) return false;
        const status = prStatuses[item.prNumber];
        if (!status?.inChannel) return false;
      } else if (currentFilter !== 'all') {
        if (item.kind !== currentFilter) return false;
      }

      // Search query
      if (!q) return true;
      return (
        item.name.toLowerCase().includes(q) ||
        item.reason.toLowerCase().includes(q) ||
        (item.sourceLabel && item.sourceLabel.toLowerCase().includes(q)) ||
        (item.releaseWhen && item.releaseWhen.toLowerCase().includes(q)) ||
        (item.untilVersion && item.untilVersion.toLowerCase().includes(q)) ||
        (item.untilChannel && item.untilChannel.toLowerCase().includes(q)) ||
        (item.attrs && item.attrs.some(a => a.toLowerCase().includes(q))) ||
        (item.prNumber && String(item.prNumber).includes(q))
      );
    });
  });

  let sortedAndFilteredItems = $derived.by(() => {
    const items = [...filteredItems];
    switch (sortOption) {
      case 'age-desc':
        return items.sort((a, b) => b.ageDays - a.ageDays);
      case 'age-asc':
        return items.sort((a, b) => a.ageDays - b.ageDays);
      case 'name-asc':
        return items.sort((a, b) => a.name.localeCompare(b.name));
      case 'name-desc':
        return items.sort((a, b) => b.name.localeCompare(a.name));
      case 'kind':
        return items.sort((a, b) => a.kind.localeCompare(b.kind) || a.name.localeCompare(b.name));
      case 'ready':
        return items.sort((a, b) => {
          const aReady = a.kind === 'pr' && a.prNumber && prStatuses[a.prNumber]?.inChannel ? 1 : 0;
          const bReady = b.kind === 'pr' && b.prNumber && prStatuses[b.prNumber]?.inChannel ? 1 : 0;
          if (aReady !== bReady) return bReady - aReady;
          return b.ageDays - a.ageDays;
        });
      default:
        return items;
    }
  });

  async function reloadLocalData(showFeedback = false) {
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
          if (data.source?.holdsDiscovered || data.source?.prsDiscovered) {
            sourceName = 'Workspace Fleet (discovered)';
          } else {
            sourceName = 'Local Repository (live sync)';
          }
        } else {
          // Local repo has no detours yet: show sample fleet preview so UI is populated
          rawHolds = initialHolds;
          rawPrs = initialPrs;
          sourceName = 'Local Repository (sample preview)';
        }
        if (showFeedback) {
          showToast('Data refreshed from disk');
        }
      }

      try {
        const cachedRes = await fetch('/api/pr-statuses');
        if (cachedRes.ok) {
          const cached = await cachedRes.json();
          const byPr: Record<number, PrStatusInfo> = {};
          for (const val of Object.values(cached)) {
            const entry = val as PrStatusInfo;
            if (entry && entry.pr) {
              byPr[entry.pr] = entry;
            }
          }
          prStatuses = { ...prStatuses, ...byPr };
        }
      } catch {}

      // Eagerly fetch statuses for all known PR detours
      for (const p of Object.values(rawPrs)) {
        if (p.pr && !prStatuses[p.pr]) {
          fetch(`/api/pr-status?pr=${p.pr}`)
            .then(r => r.ok ? r.json() : null)
            .then(data => {
              if (data && data.pr) {
                prStatuses = { ...prStatuses, [data.pr]: data };
              }
            })
            .catch(() => {});
        }
      }
    } catch {
      // Standalone mode without backend API
      if (showFeedback) {
        showToast('Running in standalone preview mode');
      }
    }
  }

  onMount(() => {
    reloadLocalData(false);
  });

  // The server's error message, or the HTTP status.
  async function syncError(res: Response): Promise<string> {
    try {
      const data = await res.json();
      if (data?.error) return data.error;
    } catch {}
    return `HTTP ${res.status}`;
  }

  // True once saved; the form stays open otherwise.
  async function handleCreateDetour(name: string, kind: DetourKind, entry: HoldEntry | PrEntry): Promise<boolean> {
    const label = kind === 'pr' ? 'PR' : kind;
    if (!isLocalApi) {
      if (kind === 'pr') {
        rawPrs = { ...rawPrs, [name]: entry as PrEntry };
      } else {
        rawHolds = { ...rawHolds, [name]: entry as HoldEntry };
      }
      showToast(`Added ${label} detour '${name}'`);
      return true;
    }

    // The server writes the entry (holds and fixes through the CLI, which
    // pins revisions and patch URLs by hash), so show what it saved.
    showToast(`Saving ${label} detour '${name}'…`);
    try {
      const res = await fetch('/api/detour', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name, kind, entry })
      });
      if (!res.ok) {
        showToast(`Could not add '${name}': ${await syncError(res)}`, 10000);
        return false;
      }
      await reloadLocalData(false);
      showToast(`Added ${label} detour '${name}'`);
      return true;
    } catch (err) {
      console.error('Failed to sync to local disk:', err);
      showToast(`Could not add '${name}': the local server is not reachable`, 10000);
      return false;
    }
  }

  function removeFromView(item: DetourItem) {
    if (item.kind === 'pr') {
      const next = { ...rawPrs };
      delete next[item.name];
      rawPrs = next;
    } else {
      const next = { ...rawHolds };
      delete next[item.name];
      rawHolds = next;
    }
  }

  async function handleReleaseDetour(item: DetourItem) {
    if (isLocalApi) {
      try {
        const res = await fetch(`/api/release`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ name: item.name, kind: item.kind })
        });
        if (!res.ok) {
          showToast(`Could not release '${item.name}': ${await syncError(res)}`, 10000);
          return;
        }
      } catch (err) {
        console.error('Failed to sync release to disk:', err);
        showToast(`Could not release '${item.name}': the local server is not reachable`, 10000);
        return;
      }
    }
    removeFromView(item);
    showToast(`Released detour '${item.name}'`);
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
    // Not the local files any more: create and release stay in the page.
    isLocalApi = false;
  }

  function handleResetDefault() {
    rawHolds = initialHolds;
    rawPrs = initialPrs;
    sourceName = 'kleinbem/nix-detour-fleet (sample)';
    isLocalApi = false;
  }

  function handleWindowKeydown(e: KeyboardEvent) {
    if (e.key === '/' && !(e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement)) {
      e.preventDefault();
      const input = document.querySelector('input[type="text"]') as HTMLInputElement | null;
      input?.focus();
    }
  }
</script>

<svelte:window onkeydown={handleWindowKeydown} />

<div class="min-h-screen flex flex-col bg-stone-950 text-stone-100 font-sans">
  <Header
    {searchQuery}
    {sourceName}
    onSearchChange={(val) => { searchQuery = val; }}
    onOpenImport={() => { showImportModal = true; }}
    onOpenNewDetour={() => { showNewDetourModal = true; }}
    onExportJson={handleExportJson}
    onRefresh={() => reloadLocalData(true)}
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
            <span>Live Sync</span>
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
      {readyCount}
      {currentFilter}
      onFilterChange={(f) => { currentFilter = f; }}
    />

    <!-- Toolbar: Results Count, Sort, and View Switcher -->
    {#if allItems.length > 0}
      <div class="mb-4 flex flex-col sm:flex-row sm:items-center justify-between gap-3 bg-stone-900/40 p-2.5 rounded-xl border border-stone-800/60">
        <div class="flex items-center gap-2 text-xs font-mono text-stone-400">
          <span>
            Showing <strong class="text-stone-200">{sortedAndFilteredItems.length}</strong> of <strong class="text-stone-200">{allItems.length}</strong> packages
          </span>
          {#if searchQuery || currentFilter !== 'all'}
            <button
              type="button"
              onclick={() => { searchQuery = ''; currentFilter = 'all'; }}
              class="text-[11px] text-amber-400 hover:text-amber-300 underline cursor-pointer ml-1"
            >
              Reset filters
            </button>
          {/if}
        </div>

        <div class="flex items-center gap-3 self-end sm:self-auto">
          <!-- Sort Dropdown -->
          <div class="flex items-center gap-1.5 text-xs text-stone-400 font-mono">
            <label for="sort-select">Sort:</label>
            <select
              id="sort-select"
              value={sortOption}
              onchange={(e) => setSortOption((e.target as HTMLSelectElement).value as SortOption)}
              class="bg-stone-900 border border-stone-800 rounded-lg px-2.5 py-1 text-xs font-mono text-stone-200 focus:outline-none focus:border-amber-500/80 cursor-pointer"
            >
              <option value="age-desc">Age: Oldest first</option>
              <option value="age-asc">Age: Newest first</option>
              <option value="name-asc">Name: A to Z</option>
              <option value="name-desc">Name: Z to A</option>
              <option value="ready">Ready to release</option>
              <option value="kind">Kind (Hold/Fix/PR)</option>
            </select>
          </div>

          <!-- View Mode Toggle -->
          <div class="flex items-center bg-stone-900 border border-stone-800 rounded-xl p-0.5" role="group" aria-label="View mode">
            <button
              type="button"
              onclick={() => setViewMode('grid')}
              class="flex items-center gap-1.5 px-2.5 py-1 rounded-lg text-xs font-mono transition cursor-pointer {viewMode === 'grid' ? 'bg-amber-500 text-stone-950 font-bold shadow-sm' : 'text-stone-400 hover:text-stone-200'}"
              title="Grid view"
            >
              <svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 6a2 2 0 012-2h2a2 2 0 012 2v2a2 2 0 01-2 2H6a2 2 0 01-2-2V6zM14 6a2 2 0 012-2h2a2 2 0 012 2v2a2 2 0 01-2 2h-2a2 2 0 01-2-2V6zM4 16a2 2 0 012-2h2a2 2 0 012 2v2a2 2 0 01-2 2H6a2 2 0 01-2-2v-2zM14 16a2 2 0 012-2h2a2 2 0 012 2v2a2 2 0 01-2 2h-2a2 2 0 01-2-2v-2z" />
              </svg>
              <span>Grid</span>
            </button>

            <button
              type="button"
              onclick={() => setViewMode('list')}
              class="flex items-center gap-1.5 px-2.5 py-1 rounded-lg text-xs font-mono transition cursor-pointer {viewMode === 'list' ? 'bg-amber-500 text-stone-950 font-bold shadow-sm' : 'text-stone-400 hover:text-stone-200'}"
              title="List view (dense)"
            >
              <svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 6h16M4 12h16M4 18h16" />
              </svg>
              <span>List</span>
            </button>
          </div>
        </div>
      </div>
    {/if}

    <!-- Content: Grid or List -->
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
    {:else if sortedAndFilteredItems.length === 0}
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
      {#if viewMode === 'grid'}
        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
          {#each sortedAndFilteredItems as item (item.id)}
            <DetourCard
              {item}
              onSelect={(selected) => { selectedItem = selected; }}
              onRelease={handleReleaseDetour}
              onTagClick={(tag) => { searchQuery = tag; }}
              onStatusUpdate={(prNum, status) => {
                prStatuses = { ...prStatuses, [prNum]: status };
              }}
            />
          {/each}
        </div>
      {:else}
        <DetourListView
          items={sortedAndFilteredItems}
          {prStatuses}
          onSelect={(selected) => { selectedItem = selected; }}
          onRelease={handleReleaseDetour}
          onTagClick={(tag) => { searchQuery = tag; }}
          onStatusUpdate={(prNum, status) => {
            prStatuses = { ...prStatuses, [prNum]: status };
          }}
        />
      {/if}
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
      canPin={isLocalApi}
    />
  {/if}

  <!-- Footer -->
  <footer class="border-t border-stone-900 py-6 text-center text-xs text-stone-500 font-mono">
    <span>nix-detour &middot; declarative package holds &middot; kleinbem fleet</span>
  </footer>

  <!-- Toast Notification -->
  {#if toastMessage}
    <div class="fixed bottom-6 right-6 z-50 px-4 py-2.5 rounded-xl bg-stone-900/95 border border-amber-500/50 text-stone-200 text-xs font-mono shadow-lg shadow-black/50 flex items-center gap-2">
      <span class="w-2 h-2 rounded-full bg-emerald-400"></span>
      <span>{toastMessage}</span>
    </div>
  {/if}
</div>
