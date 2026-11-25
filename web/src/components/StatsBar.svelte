<script lang="ts">
  import type { DetourFilter } from '../types';

  interface Props {
    total: number;
    holdsCount: number;
    fixesCount: number;
    prsCount: number;
    staleCount: number;
    readyCount: number;
    currentFilter: DetourFilter;
    onFilterChange: (filter: DetourFilter) => void;
  }

  let {
    total,
    holdsCount,
    fixesCount,
    prsCount,
    staleCount,
    readyCount,
    currentFilter,
    onFilterChange
  }: Props = $props();

  const cards = $derived([
    { key: 'all' as DetourFilter, label: 'All Detours', count: total, labelClass: 'text-muted', dotClass: '', pulse: false, activeRing: 'border-accent ring-1 ring-accent/30' },
    { key: 'ready' as DetourFilter, label: 'Ready', count: readyCount, labelClass: 'text-status-success', dotClass: 'bg-status-success', pulse: readyCount > 0, activeRing: 'border-status-success ring-1 ring-status-success/30' },
    { key: 'hold' as DetourFilter, label: 'Holds', count: holdsCount, labelClass: 'text-status-info', dotClass: 'bg-status-info', pulse: false, activeRing: 'border-status-info ring-1 ring-status-info/30' },
    { key: 'fix' as DetourFilter, label: 'Fixes', count: fixesCount, labelClass: 'text-status-warning', dotClass: 'bg-status-warning', pulse: false, activeRing: 'border-status-warning ring-1 ring-status-warning/30' },
    { key: 'pr' as DetourFilter, label: 'PRs (Ahead)', count: prsCount, labelClass: 'text-status-success', dotClass: 'bg-status-success', pulse: false, activeRing: 'border-status-success ring-1 ring-status-success/30' },
    { key: 'stale' as DetourFilter, label: 'Stale (>14d)', count: staleCount, labelClass: 'text-status-danger', dotClass: 'bg-status-danger', pulse: staleCount > 0, activeRing: 'border-status-danger ring-1 ring-status-danger/30' }
  ]);
</script>

<div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-6 gap-3 mb-6" role="group" aria-label="Filter detours by category">
  {#each cards as card (card.key)}
    <button
      type="button"
      aria-pressed={currentFilter === card.key}
      onclick={() => onFilterChange(card.key)}
      class="text-left p-3.5 rounded-xl border transition-all cursor-pointer {currentFilter === card.key
        ? `bg-surface-high shadow-xs ${card.activeRing}`
        : 'bg-surface border-line hover:bg-surface-high hover:border-outline/50'}"
    >
      <div class="flex items-center justify-between gap-2">
        <span class="text-xs uppercase tracking-wider font-medium {card.labelClass}">{card.label}</span>
        {#if card.dotClass}
          <span class="w-2 h-2 rounded-full {card.dotClass} {card.pulse ? 'animate-pulse' : ''}" aria-hidden="true"></span>
        {/if}
      </div>
      <div class="text-2xl font-bold font-mono text-heading mt-1">{card.count}</div>
    </button>
  {/each}
</div>
