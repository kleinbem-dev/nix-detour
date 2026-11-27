<script lang="ts">
  import { onMount } from 'svelte';
  import { initialHolds, initialPrs } from '../defaultData';
  import { parseHolds, parsePrs, prStatusKey } from '../utils';
  import type {
    HoldEntry,
    PrEntry,
    DetourItem,
    DetourKind,
    DetourFilter,
    PrStatusInfo,
    ViewMode,
    SortOption,
    ToastKind
  } from '../types';
  import Header from '../components/Header.svelte';
  import StatsBar from '../components/StatsBar.svelte';
  import DetourCard from '../components/DetourCard.svelte';
  import DetourListView from '../components/DetourListView.svelte';
  import DetailModal from '../components/DetailModal.svelte';
  import ImportModal from '../components/ImportModal.svelte';
  import NewDetourModal from '../components/NewDetourModal.svelte';

  let rawHolds = $state<Record<string, HoldEntry>>({});
  let rawPrs = $state<Record<string, PrEntry>>({});
  let loadErrors = $state<Record<string, string>>({});
  let loading = $state(true);
  let sourceName = $state('Loading…');
  let isLocalApi = $state(false);
  let prStatuses = $state<Record<string, PrStatusInfo>>({});
  const inFlightPrKeys = new Set<string>();

  function getStoredViewMode(): ViewMode {
    try {
      const stored = localStorage.getItem('nix-detour-view-mode');
      if (stored === 'grid' || stored === 'list') return stored;
    } catch {}
    return 'grid';
  }

  const VALID_SORTS: SortOption[] = ['age-desc', 'age-asc', 'name-asc', 'name-desc', 'kind', 'ready'];
  function getStoredSortOption(): SortOption {
    try {
      const stored = localStorage.getItem('nix-detour-sort-option') as SortOption;
      if (VALID_SORTS.includes(stored)) return stored;
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
  let toast = $state<{ message: string; kind: ToastKind } | null>(null);
  let toastTimeout: ReturnType<typeof setTimeout> | null = null;

  function showToast(message: string, kind: ToastKind = 'info', ms = kind === 'error' ? 10000 : 3000) {
    if (toastTimeout) clearTimeout(toastTimeout);
    toast = { message, kind };
    toastTimeout = setTimeout(() => {
      toast = null;
    }, ms);
  }

  function getPrStatus(item: DetourItem): PrStatusInfo | undefined {
    if (item.kind !== 'pr' || !item.prNumber) return undefined;
    return prStatuses[prStatusKey(item.prNumber, item.upstream, item.untilChannel)];
  }

  let allItems = $derived.by(() => [...parseHolds(rawHolds), ...parsePrs(rawPrs)]);

  let holdsCount = $derived(allItems.filter((i) => i.kind === 'hold').length);
  let fixesCount = $derived(allItems.filter((i) => i.kind === 'fix').length);
  let prsCount = $derived(allItems.filter((i) => i.kind === 'pr').length);
  let staleCount = $derived(allItems.filter((i) => i.ageDays > 14).length);
  let readyCount = $derived(allItems.filter((i) => Boolean(getPrStatus(i)?.inChannel)).length);

  let filteredItems = $derived.by(() => {
    const q = searchQuery.toLowerCase().trim();
    return allItems.filter((item) => {
      if (currentFilter === 'stale') {
        if (item.ageDays <= 14) return false;
      } else if (currentFilter === 'ready') {
        if (!getPrStatus(item)?.inChannel) return false;
      } else if (currentFilter !== 'all') {
        if (item.kind !== currentFilter) return false;
      }

      if (!q) return true;
      return (
        item.name.toLowerCase().includes(q) ||
        item.reason.toLowerCase().includes(q) ||
        item.sourceLabel.toLowerCase().includes(q) ||
        (item.releaseWhen && item.releaseWhen.toLowerCase().includes(q)) ||
        (item.untilVersion && item.untilVersion.toLowerCase().includes(q)) ||
        (item.untilChannel && item.untilChannel.toLowerCase().includes(q)) ||
        (item.attrs && item.attrs.some((a) => a.toLowerCase().includes(q))) ||
        (item.pythonPackages && item.pythonPackages.some((p) => p.toLowerCase().includes(q))) ||
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
          const aReady = getPrStatus(a)?.inChannel ? 1 : 0;
          const bReady = getPrStatus(b)?.inChannel ? 1 : 0;
          if (aReady !== bReady) return bReady - aReady;
          return b.ageDays - a.ageDays;
        });
      default:
        return items;
    }
  });

  async function refreshPrStatuses(prs: Record<string, PrEntry>) {
    let freshCached: Record<string, PrStatusInfo> = {};
    try {
      const cachedRes = await fetch('/api/pr-statuses');
      if (cachedRes.ok) {
        const cached = (await cachedRes.json()) as Record<string, PrStatusInfo>;
        if (cached && typeof cached === 'object') {
          freshCached = cached;
          prStatuses = { ...prStatuses, ...cached };
        }
      }
    } catch {}

    for (const p of Object.values(prs)) {
      if (!p?.pr) continue;
      const upstream = p.upstream || 'NixOS/nixpkgs';
      const channel = p.untilChannel || 'nixos-unstable';
      const key = prStatusKey(p.pr, upstream, channel);
      if (freshCached[key] || inFlightPrKeys.has(key)) continue;
      inFlightPrKeys.add(key);
      const qs = new URLSearchParams({ pr: String(p.pr), upstream, channel });
      fetch(`/api/pr-status?${qs.toString()}`)
        .then((r) => (r.ok ? r.json() : null))
        .then((data: PrStatusInfo | null) => {
          if (data && data.pr) {
            prStatuses = { ...prStatuses, [key]: data };
          }
        })
        .catch(() => {})
        .finally(() => {
          inFlightPrKeys.delete(key);
        });
    }
  }

  async function reloadLocalData(showFeedback = false) {
    try {
      const res = await fetch('/api/data');
      if (res.ok) {
        const data = await res.json();
        isLocalApi = true;
        rawHolds = data.holds || {};
        rawPrs = data.prs || {};
        loadErrors = data.errors || {};
        sourceName =
          data.source?.holdsDiscovered || data.source?.prsDiscovered
            ? 'Git Repository Root (live sync)'
            : 'Local Repository (live sync)';
        if (showFeedback) {
          showToast('Data refreshed from disk');
        }
        await refreshPrStatuses(rawPrs);
        return;
      }
      throw new Error(`HTTP ${res.status}`);
    } catch {
      if (!isLocalApi && loading) {
        rawHolds = initialHolds;
        rawPrs = initialPrs;
        sourceName = 'kleinbem/nix-detour-fleet (sample)';
      }
      if (showFeedback) {
        showToast('Running in standalone preview mode');
      }
    } finally {
      loading = false;
    }
  }

  onMount(() => {
    reloadLocalData(false);
  });

  async function syncError(res: Response): Promise<string> {
    try {
      const data = await res.json();
      if (data?.error) return data.error;
    } catch {}
    return `HTTP ${res.status}`;
  }

  async function handleCreateDetour(
    name: string,
    kind: DetourKind,
    entry: HoldEntry | PrEntry
  ): Promise<boolean> {
    const label = kind === 'pr' ? 'PR' : kind;
    const displayName = name || (kind === 'pr' ? `PR #${(entry as PrEntry).pr}` : 'detour');
    if (!isLocalApi) {
      if (kind === 'pr') {
        rawPrs = { ...rawPrs, [name]: entry as PrEntry };
      } else {
        rawHolds = { ...rawHolds, [name]: entry as HoldEntry };
      }
      showToast(`Added ${label} detour '${displayName}'`);
      return true;
    }

    showToast(`Saving ${label} detour '${displayName}'…`, 'info', 30000);
    try {
      const res = await fetch('/api/detour', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name, kind, entry })
      });
      if (!res.ok) {
        showToast(`Could not add '${displayName}': ${await syncError(res)}`, 'error');
        return false;
      }
      await reloadLocalData(false);
      showToast(`Added ${label} detour '${displayName}'`);
      return true;
    } catch {
      showToast(`Could not add '${displayName}': local server unreachable`, 'error');
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
        const res = await fetch('/api/release', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ name: item.name, kind: item.kind })
        });
        if (!res.ok) {
          showToast(`Could not release '${item.name}': ${await syncError(res)}`, 'error');
          return;
        }
      } catch {
        showToast(`Could not release '${item.name}': local server unreachable`, 'error');
        return;
      }
    }
    removeFromView(item);
    showToast(`Released detour '${item.name}'`);
  }

  function handleExportJson() {
    const download = (content: object, filename: string) => {
      const blob = new Blob([JSON.stringify(content, null, 2) + '\n'], { type: 'application/json' });
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = filename;
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      URL.revokeObjectURL(url);
    };

    download(rawHolds, 'held-packages.json');
    setTimeout(() => {
      download(rawPrs, 'nixpkgs-prs.json');
    }, 200);
  }

  function handleLoadData(
    newHolds: Record<string, HoldEntry>,
    newPrs: Record<string, PrEntry>,
    source: string
  ) {
    rawHolds = newHolds;
    rawPrs = newPrs;
    loadErrors = {};
    sourceName = source;
    isLocalApi = false;
    void refreshPrStatuses(newPrs);
  }

  function handleResetDefault() {
    rawHolds = initialHolds;
    rawPrs = initialPrs;
    loadErrors = {};
    sourceName = 'kleinbem/nix-detour-fleet (sample)';
    isLocalApi = false;
    void refreshPrStatuses(initialPrs);
  }

  function handleWindowKeydown(e: KeyboardEvent) {
    if (e.key !== '/' || e.metaKey || e.ctrlKey || e.altKey) return;
    if (document.querySelector('dialog[open]')) return;
    const target = e.target;
    if (
      target instanceof HTMLInputElement ||
      target instanceof HTMLTextAreaElement ||
      target instanceof HTMLSelectElement ||
      (target instanceof HTMLElement && target.isContentEditable)
    ) {
      return;
    }
    e.preventDefault();
    document.getElementById('detour-search')?.focus();
  }
</script>

<svelte:window onkeydown={handleWindowKeydown} />

<div class="min-h-screen flex flex-col bg-bg text-fg font-sans">
  <Header
    {searchQuery}
    {sourceName}
    onSearchChange={(val) => (searchQuery = val)}
    onOpenImport={() => (showImportModal = true)}
    onOpenNewDetour={() => (showNewDetourModal = true)}
    onExportJson={handleExportJson}
    onRefresh={() => reloadLocalData(true)}
  />

  <main class="flex-1 max-w-7xl w-full mx-auto px-4 sm:px-6 py-8">
    <!-- Disk JSON parse errors -->
    {#if Object.keys(loadErrors).length > 0}
      <div
        role="alert"
        class="mb-6 p-4 rounded-xl bg-status-danger-soft border border-status-danger-border text-status-danger text-xs font-mono space-y-1"
      >
        <div class="font-bold">Could not parse detour JSON on disk:</div>
        {#each Object.entries(loadErrors) as [kind, msg] (kind)}
          <div>• {msg}</div>
        {/each}
      </div>
    {/if}

    <!-- Top banner / intro -->
    <div class="mb-8 flex flex-col sm:flex-row items-start sm:items-center justify-between gap-4 pb-6 border-b border-line">
      <div>
        <h2 class="text-2xl font-bold tracking-tight text-heading">Active Detours</h2>
        <p class="text-sm text-muted mt-1 max-w-2xl">
          Single packages taking a detour from nixpkgs (held back while broken, fixed with patches, or running ahead from open PRs) until upstream catches up.
        </p>
      </div>

      <div class="flex items-center gap-2.5 flex-wrap">
        {#if isLocalApi}
          <div class="badge badge-success">
            <span class="w-1.5 h-1.5 rounded-full bg-status-success animate-pulse" aria-hidden="true"></span>
            <span>Live Sync</span>
          </div>
        {:else if !loading}
          <div class="badge badge-muted">
            <span>Preview Mode</span>
          </div>
        {/if}
        <div class="badge badge-muted">
          <span class="w-2 h-2 rounded-full bg-status-warning" aria-hidden="true"></span>
          <span>{allItems.length} active {allItems.length === 1 ? 'package' : 'packages'}</span>
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
      onFilterChange={(f) => {
        currentFilter = f;
      }}
    />

    <!-- Toolbar: Results Count, Sort, and View Switcher -->
    {#if allItems.length > 0}
      <div class="mb-4 flex flex-col sm:flex-row sm:items-center justify-between gap-3 bg-surface p-2.5 rounded-xl border border-line">
        <div class="flex items-center gap-2 text-xs font-mono text-muted">
          <span>
            Showing <strong class="text-heading">{sortedAndFilteredItems.length}</strong> of
            <strong class="text-heading">{allItems.length}</strong> packages
          </span>
          {#if searchQuery || currentFilter !== 'all'}
            <button
              type="button"
              onclick={() => {
                searchQuery = '';
                currentFilter = 'all';
              }}
              class="text-[11px] text-accent-soft-fg hover:underline cursor-pointer ml-1"
            >
              Reset filters
            </button>
          {/if}
        </div>

        <div class="flex items-center gap-3 self-end sm:self-auto">
          <!-- Sort Dropdown -->
          <div class="flex items-center gap-1.5 text-xs text-muted font-mono">
            <label for="sort-select">Sort:</label>
            <select
              id="sort-select"
              value={sortOption}
              onchange={(e) => setSortOption((e.target as HTMLSelectElement).value as SortOption)}
              class="bg-bg border border-line rounded-lg px-2.5 py-1 text-xs font-mono text-heading focus:outline-none focus:border-accent cursor-pointer"
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
          <div class="flex items-center bg-bg border border-line rounded-xl p-0.5" role="group" aria-label="View mode">
            <button
              type="button"
              aria-pressed={viewMode === 'grid'}
              onclick={() => setViewMode('grid')}
              class="flex items-center gap-1.5 px-2.5 py-1 rounded-lg text-xs font-mono transition cursor-pointer {viewMode === 'grid'
                ? 'bg-accent text-accent-fg font-semibold shadow-xs'
                : 'text-muted hover:text-heading'}"
              title="Grid view"
            >
              <svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 6a2 2 0 012-2h2a2 2 0 012 2v2a2 2 0 01-2 2H6a2 2 0 01-2-2V6zM14 6a2 2 0 012-2h2a2 2 0 012 2v2a2 2 0 01-2 2h-2a2 2 0 01-2-2V6zM4 16a2 2 0 012-2h2a2 2 0 012 2v2a2 2 0 01-2 2H6a2 2 0 01-2-2v-2zM14 16a2 2 0 012-2h2a2 2 0 012 2v2a2 2 0 01-2 2h-2a2 2 0 01-2-2v-2z" />
              </svg>
              <span>Grid</span>
            </button>

            <button
              type="button"
              aria-pressed={viewMode === 'list'}
              onclick={() => setViewMode('list')}
              class="flex items-center gap-1.5 px-2.5 py-1 rounded-lg text-xs font-mono transition cursor-pointer {viewMode === 'list'
                ? 'bg-accent text-accent-fg font-semibold shadow-xs'
                : 'text-muted hover:text-heading'}"
              title="List view (dense)"
            >
              <svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 6h16M4 12h16M4 18h16" />
              </svg>
              <span>List</span>
            </button>
          </div>
        </div>
      </div>
    {/if}

    <!-- Content: Grid or List -->
    {#if loading}
      <div class="text-center py-16 px-4 text-xs font-mono text-muted">Loading detours…</div>
    {:else if allItems.length === 0}
      <div class="text-center py-16 px-4 bg-surface rounded-2xl border border-line max-w-lg mx-auto">
        <div class="text-4xl mb-3" aria-hidden="true">📦</div>
        <h3 class="text-base font-semibold text-heading">No detours found</h3>
        <p class="text-xs text-muted mt-1.5 leading-relaxed">
          There are no held packages or PR detours in this repository yet.
        </p>
        <div class="mt-6 flex flex-wrap items-center justify-center gap-3">
          <button
            type="button"
            onclick={() => {
              showNewDetourModal = true;
            }}
            class="px-4 py-2 bg-accent hover:bg-accent-hover text-accent-fg font-semibold rounded-xl text-xs font-mono transition cursor-pointer"
          >
            ＋ Create Detour
          </button>
          <button
            type="button"
            onclick={handleResetDefault}
            class="px-4 py-2 bg-surface-high hover:border-outline/50 border border-line text-heading rounded-xl text-xs font-mono transition cursor-pointer"
          >
            Load Sample Fleet Data
          </button>
        </div>
      </div>
    {:else if sortedAndFilteredItems.length === 0}
      <div class="text-center py-16 px-4 bg-surface rounded-2xl border border-line max-w-lg mx-auto">
        <div class="text-3xl mb-3" aria-hidden="true">🔍</div>
        <h3 class="text-base font-semibold text-heading">No detours match your filter</h3>
        <p class="text-xs text-muted mt-1">Try clearing your search query or switching categories.</p>
        <button
          type="button"
          onclick={() => {
            searchQuery = '';
            currentFilter = 'all';
          }}
          class="mt-4 px-3 py-1.5 rounded-lg bg-surface-high hover:border-outline/50 border border-line text-xs font-mono text-heading transition cursor-pointer"
        >
          Reset filters
        </button>
      </div>
    {:else if viewMode === 'grid'}
      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
        {#each sortedAndFilteredItems as item (item.id)}
          <DetourCard
            {item}
            prStatus={getPrStatus(item)}
            onSelect={(selected) => (selectedItem = selected)}
            onRelease={handleReleaseDetour}
            onTagClick={(tag) => (searchQuery = tag)}
          />
        {/each}
      </div>
    {:else}
      <DetourListView
        items={sortedAndFilteredItems}
        {getPrStatus}
        onSelect={(selected) => (selectedItem = selected)}
        onRelease={handleReleaseDetour}
        onTagClick={(tag) => (searchQuery = tag)}
      />
    {/if}
  </main>

  <!-- Modals -->
  {#if selectedItem}
    <DetailModal item={selectedItem} onClose={() => (selectedItem = null)} />
  {/if}

  {#if showImportModal}
    <ImportModal
      onLoadData={handleLoadData}
      onResetDefault={handleResetDefault}
      onClose={() => (showImportModal = false)}
    />
  {/if}

  {#if showNewDetourModal}
    <NewDetourModal
      onClose={() => (showNewDetourModal = false)}
      onCreateDetour={handleCreateDetour}
      canPin={isLocalApi}
    />
  {/if}

  <!-- Footer -->
  <footer class="border-t border-line py-6 text-center text-xs text-muted font-mono">
    <span>nix-detour &middot; declarative package holds &middot; kleinbem fleet</span>
  </footer>

  <!-- Toast Notification -->
  {#if toast}
    <div
      role={toast.kind === 'error' ? 'alert' : 'status'}
      aria-live="polite"
      class="fixed bottom-6 right-6 z-50 max-w-md px-4 py-2.5 rounded-xl border text-xs font-mono shadow-lg flex items-center gap-2 {toast.kind === 'error'
        ? 'bg-status-danger-soft border-status-danger-border text-status-danger'
        : 'bg-surface-high border-line text-heading'}"
    >
      <span
        class="w-2 h-2 rounded-full shrink-0 {toast.kind === 'error' ? 'bg-status-danger' : 'bg-status-success'}"
        aria-hidden="true"
      ></span>
      <span>{toast.message}</span>
    </div>
  {/if}
</div>
