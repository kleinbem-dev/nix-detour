<script lang="ts">
  import type { DetourItem, PrStatusInfo } from '../types';
  import { shQuote } from '../utils';

  interface Props {
    item: DetourItem;
    prStatus?: PrStatusInfo;
    onSelect: (item: DetourItem) => void;
    onRelease?: (item: DetourItem) => void;
    onTagClick?: (tag: string) => void;
  }

  let { item, prStatus, onSelect, onRelease, onTagClick }: Props = $props();

  let copied = $state(false);
  let copiedCommand = $state(false);
  let confirmingRelease = $state(false);
  let confirmTimer: ReturnType<typeof setTimeout> | null = null;

  async function copyName() {
    try {
      await navigator.clipboard.writeText(item.name);
      copied = true;
      setTimeout(() => {
        copied = false;
      }, 1500);
    } catch {}
  }

  const cliCommand = $derived(
    `nix-detour release ${/^[a-zA-Z0-9_.-]+$/.test(item.name) ? item.name : shQuote(item.name)}`
  );

  async function copyCliCommand() {
    try {
      await navigator.clipboard.writeText(cliCommand);
      copiedCommand = true;
      setTimeout(() => {
        copiedCommand = false;
      }, 1500);
    } catch {}
  }

  function handleReleaseClick() {
    if (!confirmingRelease) {
      confirmingRelease = true;
      if (confirmTimer) clearTimeout(confirmTimer);
      confirmTimer = setTimeout(() => {
        confirmingRelease = false;
      }, 4000);
      return;
    }
    if (confirmTimer) clearTimeout(confirmTimer);
    confirmingRelease = false;
    onRelease?.(item);
  }
</script>

<article class="group relative bg-surface border border-line hover:border-outline/50 rounded-xl p-5 transition-all flex flex-col justify-between shadow-xs">
  <div>
    <!-- Top badge bar -->
    <div class="flex items-center justify-between gap-2 mb-3 flex-wrap">
      <div class="flex items-center gap-1.5 flex-wrap">
        {#if item.kind === 'hold'}
          <span class="badge badge-info !py-0.5">
            <span class="w-1.5 h-1.5 rounded-full bg-status-info" aria-hidden="true"></span>
            HOLD
          </span>
        {:else if item.kind === 'fix'}
          <span class="badge badge-warning !py-0.5">
            <span class="w-1.5 h-1.5 rounded-full bg-status-warning" aria-hidden="true"></span>
            FIX
          </span>
        {:else}
          <span class="badge badge-success !py-0.5">
            <span class="w-1.5 h-1.5 rounded-full bg-status-success" aria-hidden="true"></span>
            PR #{item.prNumber}
          </span>
          {#if prStatus}
            {#if prStatus.status === 'in-channel'}
              <span class="badge badge-success !py-0.5 animate-pulse" title={prStatus.details}>
                In Channel
              </span>
            {:else if prStatus.status === 'merged'}
              <span class="badge badge-ai !py-0.5" title={prStatus.details}>
                Merged Upstream
              </span>
            {:else if prStatus.status === 'draft'}
              <span class="badge badge-warning !py-0.5" title={prStatus.details}>
                Draft
              </span>
            {:else if prStatus.status === 'closed'}
              <span class="badge badge-danger !py-0.5" title={prStatus.details}>
                Closed
              </span>
            {:else if prStatus.status === 'open'}
              <span class="badge badge-info !py-0.5" title={prStatus.details}>
                Open Upstream
              </span>
            {/if}
          {/if}
        {/if}

        <button
          type="button"
          onclick={() => onTagClick?.(item.sourceLabel)}
          class="badge badge-muted !py-0.5 hover:border-outline/60 hover:text-heading transition cursor-pointer"
          title="Filter by source"
        >
          {item.sourceLabel}
        </button>
      </div>

      {#if item.ageDays > 0}
        <span class="badge {item.ageDays > 14 ? 'badge-danger' : 'badge-muted'} !py-0.5">
          {item.ageDays}d old
        </span>
      {/if}
    </div>

    {#if prStatus?.status === 'in-channel'}
      <div class="mb-3 px-3 py-2 rounded-lg bg-status-success-soft border border-status-success-border flex items-center justify-between gap-2 text-xs text-status-success">
        <div class="flex items-center gap-1.5">
          <span aria-hidden="true">✨</span>
          <span><strong>Ready:</strong> PR #{item.prNumber} is in {prStatus.channel || 'nixos-unstable'}</span>
        </div>
        {#if onRelease}
          <button
            type="button"
            onclick={handleReleaseClick}
            class="px-2 py-0.5 rounded bg-status-success text-bg font-semibold text-xs transition cursor-pointer shrink-0"
          >
            {confirmingRelease ? 'Confirm?' : 'Release'}
          </button>
        {/if}
      </div>
    {/if}

    <!-- Package Name -->
    <div class="flex items-center justify-between gap-2 mb-2">
      <h3 class="text-lg font-mono font-bold min-w-0">
        <button
          type="button"
          onclick={() => onSelect(item)}
          class="text-left text-heading hover:text-accent transition-colors cursor-pointer truncate max-w-full block"
        >
          {item.name}
        </button>
      </h3>
      <button
        type="button"
        onclick={copyName}
        aria-label="Copy package name {item.name}"
        title="Copy package name"
        class="text-xs font-mono text-muted hover:text-heading p-1 rounded hover:bg-surface-high transition cursor-pointer shrink-0"
      >
        {#if copied}
          <span class="text-status-success font-semibold">copied!</span>
        {:else}
          <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">
            <rect width="14" height="14" x="8" y="8" rx="2" ry="2" stroke-width="2" />
            <path stroke-width="2" d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2" />
          </svg>
        {/if}
      </button>
    </div>

    <!-- Reason text -->
    <p class="text-sm text-fg line-clamp-3 mb-4 leading-relaxed bg-bg/60 p-2.5 rounded-lg border-l-2 border-outline/40">
      {item.reason}
    </p>

    <!-- Details pills -->
    <div class="flex flex-wrap gap-1.5 mb-4 text-xs font-mono">
      {#if item.releaseWhen}
        <button
          type="button"
          onclick={() => onTagClick?.(item.releaseWhen || '')}
          class="badge badge-ai !py-0.5 hover:opacity-90 transition cursor-pointer"
          title="Filter by release condition"
        >
          until {item.releaseWhen}
        </button>
      {/if}

      {#if item.untilVersion}
        <span class="badge badge-warning !py-0.5" title="Target version condition">
          until &gt;= {item.untilVersion}
        </span>
      {/if}

      {#if item.untilChannel}
        <button
          type="button"
          onclick={() => onTagClick?.(item.untilChannel || '')}
          class="badge badge-info !py-0.5 hover:opacity-90 transition cursor-pointer"
          title="Filter by channel"
        >
          channel: {item.untilChannel}
        </button>
      {/if}

      {#if item.patches && item.patches.length > 0}
        <span class="badge badge-warning !py-0.5">
          {item.patches.length} {item.patches.length === 1 ? 'patch' : 'patches'}
        </span>
      {/if}

      {#if item.override}
        <span class="badge badge-warning !py-0.5">
          override: {item.override}
        </span>
      {/if}

      {#if item.attrs && item.attrs.length > 0}
        <span class="badge badge-success !py-0.5">
          {item.attrs.length} {item.attrs.length === 1 ? 'attr' : 'attrs'}
        </span>
      {/if}

      {#if item.pythonPackages && item.pythonPackages.length > 0}
        <span class="badge badge-info !py-0.5">
          {item.pythonPackages.length} python
        </span>
      {/if}

      {#if item.paths && Object.keys(item.paths).length > 0}
        <span class="badge badge-muted !py-0.5">
          {Object.keys(item.paths).length} custom {Object.keys(item.paths).length === 1 ? 'path' : 'paths'}
        </span>
      {/if}
    </div>
  </div>

  <!-- Bottom actions / footer -->
  <div class="flex items-center justify-between gap-2 pt-3 border-t border-line text-xs flex-wrap">
    {#if item.link || prStatus?.url}
      <a
        href={item.link || prStatus?.url}
        target="_blank"
        rel="noopener noreferrer"
        class="inline-flex items-center gap-1 text-status-info hover:underline transition"
      >
        <span>Upstream Link</span>
        <svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14" />
        </svg>
      </a>
    {:else}
      <span class="text-muted">No upstream link</span>
    {/if}

    <div class="flex items-center gap-1.5">
      <button
        type="button"
        onclick={copyCliCommand}
        title="Copy CLI release command ({cliCommand})"
        class="inline-flex items-center gap-1 px-2 py-1 rounded-lg bg-surface-high hover:border-outline/50 text-fg hover:text-heading border border-line font-mono text-[11px] transition cursor-pointer"
      >
        {#if copiedCommand}
          <span class="text-status-success font-semibold">copied!</span>
        {:else}
          <span>CLI</span>
        {/if}
      </button>

      {#if onRelease}
        <button
          type="button"
          onclick={handleReleaseClick}
          onkeydown={(e) => {
            if (e.key === 'Escape' && confirmingRelease) {
              e.stopPropagation();
              confirmingRelease = false;
            }
          }}
          title={confirmingRelease ? 'Click again to confirm release' : 'Release and retire detour'}
          class="inline-flex items-center gap-1 px-2.5 py-1 rounded-lg font-mono text-[11px] transition cursor-pointer border {confirmingRelease
            ? 'bg-status-danger text-bg border-status-danger font-bold'
            : 'bg-status-danger-soft text-status-danger border-status-danger-border hover:opacity-90'}"
        >
          <span>{confirmingRelease ? 'Confirm?' : 'Release'}</span>
        </button>
      {/if}

      <button
        type="button"
        onclick={() => onSelect(item)}
        class="inline-flex items-center gap-1 px-2 py-1 rounded-lg text-muted hover:text-heading hover:bg-surface-high font-mono text-[11px] transition cursor-pointer"
      >
        <span>Inspect</span>
        <svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5l7 7-7 7" />
        </svg>
      </button>
    </div>
  </div>
</article>
