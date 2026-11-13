<script lang="ts">
  import type { DetourItem, PrStatusInfo } from '../types';
  import { shQuote } from '../utils';

  interface Props {
    items: DetourItem[];
    getPrStatus: (item: DetourItem) => PrStatusInfo | undefined;
    onSelect: (item: DetourItem) => void;
    onRelease?: (item: DetourItem) => void;
    onTagClick?: (tag: string) => void;
  }

  let { items, getPrStatus, onSelect, onRelease, onTagClick }: Props = $props();

  let copiedItem = $state<string | null>(null);
  let copiedCommand = $state<string | null>(null);
  let confirmingItem = $state<string | null>(null);
  let confirmTimer: ReturnType<typeof setTimeout> | null = null;

  async function copyName(name: string) {
    try {
      await navigator.clipboard.writeText(name);
      copiedItem = name;
      setTimeout(() => {
        if (copiedItem === name) copiedItem = null;
      }, 1500);
    } catch {}
  }

  async function copyCliCommand(name: string) {
    const arg = /^[a-zA-Z0-9_.-]+$/.test(name) ? name : shQuote(name);
    try {
      await navigator.clipboard.writeText(`nix-detour release ${arg}`);
      copiedCommand = name;
      setTimeout(() => {
        if (copiedCommand === name) copiedCommand = null;
      }, 1500);
    } catch {}
  }

  function handleReleaseClick(item: DetourItem) {
    if (confirmingItem !== item.id) {
      confirmingItem = item.id;
      if (confirmTimer) clearTimeout(confirmTimer);
      confirmTimer = setTimeout(() => {
        if (confirmingItem === item.id) confirmingItem = null;
      }, 4000);
      return;
    }
    if (confirmTimer) clearTimeout(confirmTimer);
    confirmingItem = null;
    onRelease?.(item);
  }
</script>

<div class="overflow-x-auto rounded-2xl border border-line bg-surface shadow-xs">
  <table class="w-full text-left border-collapse">
    <thead>
      <tr class="border-b border-line bg-surface-high text-[11px] font-mono uppercase tracking-wider text-muted">
        <th scope="col" class="py-3 px-4">Package</th>
        <th scope="col" class="py-3 px-3">Type</th>
        <th scope="col" class="py-3 px-3">Source / Details</th>
        <th scope="col" class="py-3 px-3">Age</th>
        <th scope="col" class="py-3 px-3">Status / Trigger</th>
        <th scope="col" class="py-3 px-4 text-right">Actions</th>
      </tr>
    </thead>
    <tbody class="divide-y divide-line text-xs">
      {#each items as item (item.id)}
        {@const status = getPrStatus(item)}
        <tr class="group hover:bg-surface-high/60 transition">
          <!-- Package Name & Quick Copy -->
          <td class="py-3 px-4 font-mono font-medium">
            <div class="flex items-center gap-2">
              <button
                type="button"
                onclick={() => onSelect(item)}
                class="text-sm font-bold text-heading hover:text-accent transition text-left cursor-pointer"
              >
                {item.name}
              </button>
              <button
                type="button"
                onclick={() => copyName(item.name)}
                aria-label="Copy package name {item.name}"
                title="Copy package name"
                class="opacity-0 group-hover:opacity-100 focus-visible:opacity-100 hover:text-heading text-muted transition p-0.5 rounded cursor-pointer"
              >
                {#if copiedItem === item.name}
                  <span class="text-status-success text-xs font-sans">✓</span>
                {:else}
                  <svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z" />
                  </svg>
                {/if}
              </button>
            </div>
            {#if item.reason}
              <div class="text-[11px] font-sans text-muted truncate max-w-xs mt-0.5" title={item.reason}>
                {item.reason}
              </div>
            {/if}
          </td>

          <!-- Type badge -->
          <td class="py-3 px-3 shrink-0">
            {#if item.kind === 'hold'}
              <span class="badge badge-info !py-0.5 !px-2 !text-[10px] font-bold">HOLD</span>
            {:else if item.kind === 'fix'}
              <span class="badge badge-warning !py-0.5 !px-2 !text-[10px] font-bold">FIX</span>
            {:else}
              <span class="badge badge-success !py-0.5 !px-2 !text-[10px] font-bold">PR #{item.prNumber}</span>
            {/if}
          </td>

          <!-- Source / Details -->
          <td class="py-3 px-3 text-fg font-mono text-[11px]">
            <div class="flex items-center gap-2">
              {#if item.kind === 'pr'}
                <a
                  href={item.link || `https://github.com/${item.upstream || 'NixOS/nixpkgs'}/pull/${item.prNumber}`}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="text-status-info hover:underline truncate max-w-xs"
                >
                  {item.owner}/{item.repo}#{item.prNumber}
                </a>
              {:else}
                <span class="text-fg truncate max-w-xs">
                  {item.sourceLabel || item.fullSource || 'pinned'}
                </span>
                {#if item.patches && item.patches.length > 0}
                  <span class="badge badge-warning !py-0 !px-1.5 !text-[10px]">
                    +{item.patches.length} patch{item.patches.length > 1 ? 'es' : ''}
                  </span>
                {/if}
              {/if}
            </div>
            {#if item.attrs && item.attrs.length > 0}
              <div class="flex items-center gap-1 mt-1 overflow-hidden">
                {#each item.attrs.slice(0, 2) as attr, idx (idx)}
                  <button
                    type="button"
                    onclick={() => onTagClick?.(attr)}
                    class="text-[10px] font-mono px-1.5 py-0.5 rounded bg-surface-high border border-line text-muted hover:text-heading transition cursor-pointer"
                  >
                    {attr}
                  </button>
                {/each}
                {#if item.attrs.length > 2}
                  <span class="text-[10px] text-muted font-mono">+{item.attrs.length - 2}</span>
                {/if}
              </div>
            {/if}
          </td>

          <!-- Age -->
          <td class="py-3 px-3 font-mono shrink-0">
            <div class="flex items-center gap-1.5">
              {#if item.ageDays > 0 || (item.since && item.since !== 'unknown')}
                <span class={item.ageDays > 14 ? 'text-status-danger font-bold' : 'text-heading'}>
                  {item.ageDays}d
                </span>
                {#if item.ageDays > 14}
                  <span class="badge badge-danger !py-0 !px-1.5 !text-[10px] uppercase font-bold">stale</span>
                {/if}
              {:else}
                <span class="text-muted text-[11px]">—</span>
              {/if}
            </div>
            {#if item.since && item.since !== 'unknown'}
              <div class="text-[10px] text-muted">{item.since}</div>
            {/if}
          </td>

          <!-- Status / Release Trigger -->
          <td class="py-3 px-3">
            {#if item.kind === 'pr'}
              {#if status}
                {#if status.status === 'in-channel'}
                  <span class="badge badge-success !py-0.5 !px-2 !text-[10px] font-bold">
                    <span class="w-1.5 h-1.5 rounded-full bg-status-success animate-pulse" aria-hidden="true"></span>
                    In Channel (Ready)
                  </span>
                {:else if status.status === 'merged'}
                  <span class="badge badge-ai !py-0.5 !px-2 !text-[10px] font-semibold">Merged Upstream</span>
                {:else if status.status === 'open'}
                  <span class="badge badge-info !py-0.5 !px-2 !text-[10px] font-semibold">PR Open</span>
                {:else if status.status === 'draft'}
                  <span class="badge badge-warning !py-0.5 !px-2 !text-[10px]">Draft PR</span>
                {:else if status.status === 'closed'}
                  <span class="badge badge-danger !py-0.5 !px-2 !text-[10px]">Closed</span>
                {:else}
                  <span class="badge badge-muted !py-0.5 !px-2 !text-[10px]">{status.status}</span>
                {/if}
              {:else}
                <span class="text-muted font-mono text-[11px]">—</span>
              {/if}
            {:else if item.releaseWhen}
              <div class="text-[11px] font-mono text-fg flex items-center gap-1">
                <span class="text-muted text-[10px]">until</span>
                <span class="text-status-ai font-semibold">{item.releaseWhen}</span>
                <span class="text-muted text-[10px]">builds</span>
              </div>
            {:else if item.untilVersion}
              <div class="text-[11px] font-mono text-fg flex items-center gap-1">
                <span class="text-muted text-[10px]">until</span>
                <span class="text-status-warning font-semibold">&gt;= {item.untilVersion}</span>
              </div>
            {:else}
              <span class="text-muted font-mono text-[11px]">manual hold</span>
            {/if}
          </td>

          <!-- Actions -->
          <td class="py-3 px-4 text-right">
            <div class="inline-flex items-center gap-1.5">
              <button
                type="button"
                onclick={() => onSelect(item)}
                class="px-2 py-1 rounded-lg bg-surface-high hover:border-outline/50 text-fg hover:text-heading text-[11px] font-mono transition cursor-pointer border border-line"
              >
                Inspect
              </button>

              <button
                type="button"
                onclick={() => copyCliCommand(item.name)}
                title="Copy release CLI command"
                class="px-2 py-1 rounded-lg bg-surface-high hover:border-outline/50 text-fg hover:text-heading text-[11px] font-mono transition cursor-pointer border border-line"
              >
                {#if copiedCommand === item.name}
                  <span class="text-status-success">✓ Copied</span>
                {:else}
                  <span>CLI</span>
                {/if}
              </button>

              {#if onRelease}
                <button
                  type="button"
                  onclick={() => handleReleaseClick(item)}
                  onkeydown={(e) => {
                    if (e.key === 'Escape' && confirmingItem === item.id) {
                      e.stopPropagation();
                      confirmingItem = null;
                    }
                  }}
                  title={confirmingItem === item.id ? 'Click again to confirm release' : `Release detour '${item.name}'`}
                  class="px-2 py-1 rounded-lg text-[11px] font-mono transition cursor-pointer border {confirmingItem === item.id
                    ? 'bg-status-danger text-bg border-status-danger font-bold'
                    : 'bg-status-danger-soft text-status-danger border-status-danger-border hover:opacity-90'}"
                >
                  {confirmingItem === item.id ? 'Confirm?' : 'Release'}
                </button>
              {/if}
            </div>
          </td>
        </tr>
      {/each}
    </tbody>
  </table>
</div>
