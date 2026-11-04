<script lang="ts">
  import type { DetourKind } from '../types';

  interface Props {
    total: number;
    holdsCount: number;
    fixesCount: number;
    prsCount: number;
    staleCount: number;
    currentFilter: DetourKind | 'all' | 'stale';
    onFilterChange: (filter: DetourKind | 'all' | 'stale') => void;
  }

  let {
    total,
    holdsCount,
    fixesCount,
    prsCount,
    staleCount,
    currentFilter,
    onFilterChange
  }: Props = $props();
</script>

<div class="grid grid-cols-2 sm:grid-cols-5 gap-3 mb-6">
  <button
    type="button"
    onclick={() => onFilterChange('all')}
    class="text-left p-3.5 rounded-xl border transition-all cursor-pointer {currentFilter === 'all' ? 'bg-stone-900 border-amber-500/50 shadow-sm ring-1 ring-amber-500/30' : 'bg-stone-900/60 border-stone-800/80 hover:bg-stone-900 hover:border-stone-700'}"
  >
    <div class="text-xs uppercase tracking-wider text-stone-400 font-medium">All Detours</div>
    <div class="text-2xl font-bold font-mono text-stone-100 mt-1">{total}</div>
  </button>

  <button
    type="button"
    onclick={() => onFilterChange('hold')}
    class="text-left p-3.5 rounded-xl border transition-all cursor-pointer {currentFilter === 'hold' ? 'bg-stone-900 border-cyan-500/50 shadow-sm ring-1 ring-cyan-500/30' : 'bg-stone-900/60 border-stone-800/80 hover:bg-stone-900 hover:border-stone-700'}"
  >
    <div class="flex items-center justify-between">
      <span class="text-xs uppercase tracking-wider text-cyan-400 font-medium">Holds</span>
      <span class="w-2 h-2 rounded-full bg-cyan-400"></span>
    </div>
    <div class="text-2xl font-bold font-mono text-stone-100 mt-1">{holdsCount}</div>
  </button>

  <button
    type="button"
    onclick={() => onFilterChange('fix')}
    class="text-left p-3.5 rounded-xl border transition-all cursor-pointer {currentFilter === 'fix' ? 'bg-stone-900 border-amber-500/50 shadow-sm ring-1 ring-amber-500/30' : 'bg-stone-900/60 border-stone-800/80 hover:bg-stone-900 hover:border-stone-700'}"
  >
    <div class="flex items-center justify-between">
      <span class="text-xs uppercase tracking-wider text-amber-400 font-medium">Fixes</span>
      <span class="w-2 h-2 rounded-full bg-amber-400"></span>
    </div>
    <div class="text-2xl font-bold font-mono text-stone-100 mt-1">{fixesCount}</div>
  </button>

  <button
    type="button"
    onclick={() => onFilterChange('pr')}
    class="text-left p-3.5 rounded-xl border transition-all cursor-pointer {currentFilter === 'pr' ? 'bg-stone-900 border-emerald-500/50 shadow-sm ring-1 ring-emerald-500/30' : 'bg-stone-900/60 border-stone-800/80 hover:bg-stone-900 hover:border-stone-700'}"
  >
    <div class="flex items-center justify-between">
      <span class="text-xs uppercase tracking-wider text-emerald-400 font-medium">PRs (Ahead)</span>
      <span class="w-2 h-2 rounded-full bg-emerald-400"></span>
    </div>
    <div class="text-2xl font-bold font-mono text-stone-100 mt-1">{prsCount}</div>
  </button>

  <button
    type="button"
    onclick={() => onFilterChange('stale')}
    class="col-span-2 sm:col-span-1 text-left p-3.5 rounded-xl border transition-all cursor-pointer {currentFilter === 'stale' ? 'bg-stone-900 border-rose-500/50 shadow-sm ring-1 ring-rose-500/30' : 'bg-stone-900/60 border-stone-800/80 hover:bg-stone-900 hover:border-stone-700'}"
  >
    <div class="flex items-center justify-between">
      <span class="text-xs uppercase tracking-wider text-rose-400 font-medium">Stale (&gt;14d)</span>
      <span class="w-2 h-2 rounded-full bg-rose-400 {staleCount > 0 ? 'animate-pulse' : ''}"></span>
    </div>
    <div class="text-2xl font-bold font-mono text-stone-100 mt-1">{staleCount}</div>
  </button>
</div>
