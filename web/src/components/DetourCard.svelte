<script lang="ts">
  import type { DetourItem } from '../types';

  interface Props {
    item: DetourItem;
    onSelect: (item: DetourItem) => void;
    onRelease?: (item: DetourItem) => void;
  }

  let { item, onSelect, onRelease }: Props = $props();

  let copied = $state(false);

  function copyName(e: MouseEvent) {
    e.stopPropagation();
    navigator.clipboard.writeText(item.name);
    copied = true;
    setTimeout(() => { copied = false; }, 1500);
  }

  function handleRelease(e: MouseEvent) {
    e.stopPropagation();
    if (confirm(`Are you sure you want to release and retire detour for "${item.name}"?`)) {
      onRelease?.(item);
    }
  }
  function handleKeyDown(e: KeyboardEvent) {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      onSelect(item);
    }
  }
</script>

<div
  role="button"
  tabindex="0"
  onclick={() => onSelect(item)}
  onkeydown={handleKeyDown}
  class="group relative bg-stone-900/70 border border-stone-800/80 hover:border-stone-700/80 hover:bg-stone-900 rounded-xl p-5 transition-all cursor-pointer flex flex-col justify-between"
>
  <div>
    <!-- Top badge bar -->
    <div class="flex items-center justify-between gap-2 mb-3">
      <div class="flex items-center gap-2">
        {#if item.kind === 'hold'}
          <span class="inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full text-xs font-semibold bg-cyan-950/70 text-cyan-300 border border-cyan-800/50">
            <span class="w-1.5 h-1.5 rounded-full bg-cyan-400"></span>
            HOLD
          </span>
        {:else if item.kind === 'fix'}
          <span class="inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full text-xs font-semibold bg-amber-950/70 text-amber-300 border border-amber-800/50">
            <span class="w-1.5 h-1.5 rounded-full bg-amber-400"></span>
            FIX
          </span>
        {:else}
          <span class="inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full text-xs font-semibold bg-emerald-950/70 text-emerald-300 border border-emerald-800/50">
            <span class="w-1.5 h-1.5 rounded-full bg-emerald-400"></span>
            PR #{item.prNumber}
          </span>
        {/if}

        <span class="text-xs font-mono px-2 py-0.5 rounded bg-stone-800/70 text-stone-300 border border-stone-700/50">
          {item.sourceLabel}
        </span>
      </div>

      {#if item.ageDays > 0}
        <span class="text-xs font-medium px-2 py-0.5 rounded {item.ageDays > 14 ? 'bg-rose-950/70 text-rose-300 border border-rose-800/50' : 'bg-stone-800/50 text-stone-400'}">
          {item.ageDays}d old
        </span>
      {/if}
    </div>

    <!-- Package Name -->
    <div class="flex items-center justify-between gap-2 mb-2">
      <h3 class="text-lg font-mono font-bold text-stone-100 group-hover:text-amber-400 transition-colors">
        {item.name}
      </h3>
      <button
        type="button"
        onclick={copyName}
        title="Copy package name"
        class="text-xs font-mono text-stone-400 hover:text-stone-200 p-1 rounded hover:bg-stone-800 transition"
      >
        {#if copied}
          <span class="text-emerald-400">copied!</span>
        {:else}
          <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <rect width="14" height="14" x="8" y="8" rx="2" ry="2" stroke-width="2"/>
            <path stroke-width="2" d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"/>
          </svg>
        {/if}
      </button>
    </div>

    <!-- Reason text -->
    <p class="text-sm text-stone-300 line-clamp-3 mb-4 leading-relaxed bg-stone-950/40 p-2.5 rounded-lg border-l-2 border-stone-700">
      {item.reason}
    </p>

    <!-- Details pills -->
    <div class="flex flex-wrap gap-1.5 mb-4 text-xs font-mono">
      {#if item.releaseWhen}
        <span class="inline-flex items-center gap-1 px-2 py-1 rounded bg-stone-800/60 text-purple-300 border border-purple-800/40" title="Release condition">
          <svg class="w-3.5 h-3.5 text-purple-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 10V3L4 14h7v7l9-11h-7z" />
          </svg>
          until {item.releaseWhen}
        </span>
      {/if}

      {#if item.untilVersion}
        <span class="inline-flex items-center gap-1 px-2 py-1 rounded bg-amber-500/10 text-amber-300 border border-amber-500/30" title="Target version condition">
          <span>🎯</span>
          <span>until &gt;= {item.untilVersion}</span>
        </span>
      {/if}

      {#if item.untilChannel}
        <span class="inline-flex items-center gap-1 px-2 py-1 rounded bg-blue-500/10 text-blue-300 border border-blue-500/30" title="Target channel condition">
          <span>⏳</span>
          <span>channel: {item.untilChannel}</span>
        </span>
      {/if}

      {#if item.patches && item.patches.length > 0}
        <span class="inline-flex items-center gap-1 px-2 py-1 rounded bg-stone-800/60 text-amber-300 border border-amber-800/40">
          {item.patches.length} {item.patches.length === 1 ? 'patch' : 'patches'}
        </span>
      {/if}

      {#if item.override}
        <span class="inline-flex items-center gap-1 px-2 py-1 rounded bg-stone-800/60 text-amber-300 border border-amber-800/40">
          override: {item.override}
        </span>
      {/if}

      {#if item.attrs && item.attrs.length > 0}
        <span class="inline-flex items-center gap-1 px-2 py-1 rounded bg-stone-800/60 text-emerald-300 border border-emerald-800/40">
          {item.attrs.length} attrs
        </span>
      {/if}

      {#if item.paths && Object.keys(item.paths).length > 0}
        <span class="inline-flex items-center gap-1 px-2 py-1 rounded bg-stone-800/60 text-blue-300 border border-blue-800/40">
          {Object.keys(item.paths).length} custom {Object.keys(item.paths).length === 1 ? 'path' : 'paths'}
        </span>
      {/if}
    </div>
  </div>

  <!-- Bottom actions / footer -->
  <div class="flex items-center justify-between pt-3 border-t border-stone-800/60 text-xs">
    {#if item.link}
      <a
        href={item.link}
        target="_blank"
        rel="noopener noreferrer"
        onclick={(e) => e.stopPropagation()}
        class="inline-flex items-center gap-1 text-cyan-400 hover:text-cyan-300 hover:underline transition"
      >
        <span>Upstream Issue / PR</span>
        <svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14" />
        </svg>
      </a>
    {:else}
      <span class="text-stone-500">No upstream link</span>
    {/if}

    <div class="flex items-center gap-2">
      {#if onRelease}
        <button
          type="button"
          onclick={handleRelease}
          title="Release and retire detour"
          class="inline-flex items-center gap-1 px-2.5 py-1 rounded-lg bg-red-950/40 hover:bg-red-900/60 text-red-300 border border-red-800/40 hover:border-red-700/60 font-mono text-[11px] transition cursor-pointer"
        >
          <svg class="w-3 h-3 text-red-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16" />
          </svg>
          <span>Release</span>
        </button>
      {/if}

      <span class="text-stone-400 group-hover:text-stone-200 inline-flex items-center gap-1 font-mono transition">
        Inspect
        <svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5l7 7-7 7" />
        </svg>
      </span>
    </div>
  </div>
</div>
