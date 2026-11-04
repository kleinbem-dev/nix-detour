<script lang="ts">
  import type { DetourItem, PrStatusInfo } from '../types';
  import { shQuote } from '../utils';

  interface Props {
    items: DetourItem[];
    prStatuses: Record<number, PrStatusInfo>;
    onSelect: (item: DetourItem) => void;
    onRelease?: (item: DetourItem) => void;
    onTagClick?: (tag: string) => void;
    onStatusUpdate?: (prNumber: number, status: PrStatusInfo) => void;
  }

  let { items, prStatuses, onSelect, onRelease, onTagClick, onStatusUpdate }: Props = $props();

  let copiedItem = $state<string | null>(null);
  let copiedCommand = $state<string | null>(null);

  function copyName(e: MouseEvent, name: string) {
    e.stopPropagation();
    navigator.clipboard.writeText(name);
    copiedItem = name;
    setTimeout(() => {
      if (copiedItem === name) copiedItem = null;
    }, 1500);
  }

  function copyCliCommand(e: MouseEvent, name: string) {
    e.stopPropagation();
    const arg = /^[a-zA-Z0-9_.-]+$/.test(name) ? name : shQuote(name);
    navigator.clipboard.writeText(`nix-detour release ${arg}`);
    copiedCommand = name;
    setTimeout(() => {
      if (copiedCommand === name) copiedCommand = null;
    }, 1500);
  }

  function handleRelease(e: MouseEvent, item: DetourItem) {
    e.stopPropagation();
    if (confirm(`Are you sure you want to release and retire detour for "${item.name}"?`)) {
      onRelease?.(item);
    }
  }

  function handleTagClick(e: MouseEvent, tag: string) {
    e.stopPropagation();
    onTagClick?.(tag);
  }
</script>

<div class="overflow-x-auto rounded-2xl border border-stone-800/80 bg-stone-900/50 shadow-md">
  <table class="w-full text-left border-collapse">
    <thead>
      <tr class="border-b border-stone-800 bg-stone-900/80 text-[11px] font-mono uppercase tracking-wider text-stone-400">
        <th scope="col" class="py-3 px-4">Package</th>
        <th scope="col" class="py-3 px-3">Type</th>
        <th scope="col" class="py-3 px-3">Source / Details</th>
        <th scope="col" class="py-3 px-3">Age</th>
        <th scope="col" class="py-3 px-3">Status / Trigger</th>
        <th scope="col" class="py-3 px-4 text-right">Actions</th>
      </tr>
    </thead>
    <tbody class="divide-y divide-stone-800/50 text-xs">
      {#each items as item (item.id)}
        {@const status = item.prNumber ? prStatuses[item.prNumber] : null}
        <tr
          role="button"
          tabindex="0"
          onclick={() => onSelect(item)}
          onkeydown={(e) => {
            if (e.key === 'Enter' || e.key === ' ') {
              e.preventDefault();
              onSelect(item);
            }
          }}
          class="group hover:bg-stone-800/50 transition cursor-pointer"
        >
          <!-- Package Name & Quick Copy -->
          <td class="py-3 px-4 font-mono font-medium text-stone-100">
            <div class="flex items-center gap-2">
              <span class="text-sm font-bold text-stone-100 group-hover:text-amber-300 transition">
                {item.name}
              </span>
              <button
                type="button"
                onclick={(e) => copyName(e, item.name)}
                title="Copy package name"
                class="opacity-0 group-hover:opacity-100 hover:text-stone-200 text-stone-500 transition p-0.5 rounded cursor-pointer"
              >
                {#if copiedItem === item.name}
                  <span class="text-emerald-400 text-xs font-sans">✓</span>
                {:else}
                  <svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z" />
                  </svg>
                {/if}
              </button>
            </div>
            {#if item.reason}
              <div class="text-[11px] font-sans text-stone-400 truncate max-w-xs mt-0.5" title={item.reason}>
                {item.reason}
              </div>
            {/if}
          </td>

          <!-- Type badge -->
          <td class="py-3 px-3 shrink-0">
            {#if item.kind === 'hold'}
              <span class="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-md text-[10px] font-mono font-bold bg-cyan-950/70 text-cyan-300 border border-cyan-800/60">
                <span class="w-1.5 h-1.5 rounded-full bg-cyan-400"></span>
                HOLD
              </span>
            {:else if item.kind === 'fix'}
              <span class="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-md text-[10px] font-mono font-bold bg-amber-950/70 text-amber-300 border border-amber-800/60">
                <span class="w-1.5 h-1.5 rounded-full bg-amber-400"></span>
                FIX
              </span>
            {:else}
              <span class="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-md text-[10px] font-mono font-bold bg-emerald-950/70 text-emerald-300 border border-emerald-800/60">
                <span class="w-1.5 h-1.5 rounded-full bg-emerald-400"></span>
                PR #{item.prNumber}
              </span>
            {/if}
          </td>

          <!-- Source / Details -->
          <td class="py-3 px-3 text-stone-300 font-mono text-[11px]">
            <div class="flex items-center gap-2">
              {#if item.kind === 'pr'}
                <a
                  href={`https://github.com/${item.owner}/${item.repo}/pull/${item.prNumber}`}
                  target="_blank"
                  rel="noreferrer"
                  onclick={(e) => e.stopPropagation()}
                  class="text-emerald-400 hover:text-emerald-300 hover:underline truncate max-w-xs"
                >
                  {item.owner}/{item.repo}#{item.prNumber}
                </a>
              {:else}
                <span class="text-stone-300 truncate max-w-xs">
                  {item.sourceLabel || item.fullSource || 'pinned'}
                </span>
                {#if item.patches && item.patches.length > 0}
                  <span class="text-[10px] px-1.5 py-0.2 rounded bg-amber-950/60 text-amber-400 border border-amber-900/50">
                    +{item.patches.length} patch{item.patches.length > 1 ? 'es' : ''}
                  </span>
                {/if}
              {/if}
            </div>
            {#if item.attrs && item.attrs.length > 0}
              <div class="flex items-center gap-1 mt-1 overflow-hidden">
                {#each item.attrs.slice(0, 2) as attr}
                  <button
                    type="button"
                    onclick={(e) => handleTagClick(e, attr)}
                    class="text-[10px] font-mono px-1 py-0.2 rounded bg-stone-800/80 text-stone-400 hover:text-stone-200 hover:bg-stone-700 transition cursor-pointer"
                  >
                    {attr}
                  </button>
                {/each}
                {#if item.attrs.length > 2}
                  <span class="text-[10px] text-stone-500 font-mono">+{item.attrs.length - 2}</span>
                {/if}
              </div>
            {/if}
          </td>

          <!-- Age -->
          <td class="py-3 px-3 font-mono shrink-0">
            <div class="flex items-center gap-1.5">
              <span class="text-stone-200 {item.ageDays > 14 ? 'text-rose-400 font-bold' : ''}">
                {item.ageDays}d
              </span>
              {#if item.ageDays > 14}
                <span class="px-1.5 py-0.2 rounded text-[10px] uppercase font-bold bg-rose-950/80 text-rose-300 border border-rose-800/60">
                  stale
                </span>
              {/if}
            </div>
            {#if item.since}
              <div class="text-[10px] text-stone-500">{item.since}</div>
            {/if}
          </td>

          <!-- Status / Release Trigger -->
          <td class="py-3 px-3">
            {#if item.kind === 'pr'}
              {#if status}
                {#if status.status === 'in-channel'}
                  <span class="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-[10px] font-mono font-bold bg-emerald-900/60 text-emerald-300 border border-emerald-500/50 shadow-sm shadow-emerald-500/10">
                    <span class="w-1.5 h-1.5 rounded-full bg-emerald-400 animate-pulse"></span>
                    In Channel (Ready)
                  </span>
                {:else if status.status === 'merged'}
                  <span class="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-[10px] font-mono font-semibold bg-purple-950/70 text-purple-300 border border-purple-800/50">
                    <span class="w-1.5 h-1.5 rounded-full bg-purple-400"></span>
                    Merged Upstream
                  </span>
                {:else if status.status === 'open'}
                  <span class="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-[10px] font-mono font-semibold bg-blue-950/70 text-blue-300 border border-blue-800/50">
                    <span class="w-1.5 h-1.5 rounded-full bg-blue-400"></span>
                    PR Open
                  </span>
                {:else if status.status === 'draft'}
                  <span class="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-[10px] font-mono text-stone-400 bg-stone-800/60 border border-stone-700/50">
                    Draft PR
                  </span>
                {:else}
                  <span class="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-[10px] font-mono text-stone-400 bg-stone-800/60 border border-stone-700/50">
                    {status.status}
                  </span>
                {/if}
              {:else}
                <span class="text-stone-500 font-mono text-[11px]">—</span>
              {/if}
            {:else if item.releaseWhen}
              <div class="text-[11px] font-mono text-stone-300 flex items-center gap-1">
                <span class="text-stone-500 text-[10px]">until</span>
                <span class="text-amber-300 font-semibold">{item.releaseWhen}</span>
                <span class="text-stone-500 text-[10px]">builds</span>
              </div>
            {:else if item.untilVersion}
              <div class="text-[11px] font-mono text-stone-300 flex items-center gap-1">
                <span class="text-stone-500 text-[10px]">until</span>
                <span class="text-cyan-300 font-semibold">v{item.untilVersion}</span>
              </div>
            {:else}
              <span class="text-stone-500 font-mono text-[11px]">manual hold</span>
            {/if}
          </td>

          <!-- Actions -->
          <td class="py-3 px-4 text-right">
            <div class="inline-flex items-center gap-1.5" onclick={(e) => e.stopPropagation()}>
              <button
                type="button"
                onclick={(e) => copyCliCommand(e, item.name)}
                title="Copy release CLI command"
                class="px-2 py-1 rounded-lg bg-stone-800/80 hover:bg-stone-700 text-stone-300 hover:text-stone-100 text-[11px] font-mono transition cursor-pointer flex items-center gap-1 border border-stone-700/50"
              >
                {#if copiedCommand === item.name}
                  <span class="text-emerald-400 text-xs">✓ Copied</span>
                {:else}
                  <span>📋 CLI</span>
                {/if}
              </button>

              <button
                type="button"
                onclick={(e) => handleRelease(e, item)}
                title={`Release detour '${item.name}'`}
                class="px-2 py-1 rounded-lg bg-stone-800/80 hover:bg-rose-950/70 hover:border-rose-800/80 text-stone-400 hover:text-rose-300 text-[11px] font-mono transition cursor-pointer border border-stone-700/50"
              >
                Release
              </button>
            </div>
          </td>
        </tr>
      {/each}
    </tbody>
  </table>
</div>
