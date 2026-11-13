<script lang="ts">
  import type { DetourItem } from '../types';
  import { generateCliCommand, modalDialog } from '../utils';

  interface Props {
    item: DetourItem;
    onClose: () => void;
  }

  let { item, onClose }: Props = $props();

  let cliCommand = $derived(generateCliCommand(item));
  let jsonString = $derived(JSON.stringify(item.raw, null, 2));

  let copiedCli = $state(false);
  let copiedJson = $state(false);

  async function copyCli() {
    try {
      await navigator.clipboard.writeText(cliCommand);
      copiedCli = true;
      setTimeout(() => {
        copiedCli = false;
      }, 1500);
    } catch {}
  }

  async function copyJson() {
    try {
      await navigator.clipboard.writeText(jsonString);
      copiedJson = true;
      setTimeout(() => {
        copiedJson = false;
      }, 1500);
    } catch {}
  }
</script>

<dialog
  {@attach modalDialog}
  onclose={onClose}
  aria-labelledby="detail-modal-title"
  class="m-auto w-[calc(100%-2rem)] max-w-2xl p-0 bg-transparent border-0 text-fg"
>
  <div class="w-full bg-surface border border-line rounded-2xl shadow-2xl p-6 overflow-hidden max-h-[90vh] flex flex-col">
    <!-- Modal Header -->
    <div class="flex items-start justify-between gap-4 pb-4 border-b border-line">
      <div class="min-w-0">
        <div class="flex items-center gap-2 mb-1 flex-wrap">
          <span
            class="badge uppercase font-bold !py-0.5 {item.kind === 'hold'
              ? 'badge-info'
              : item.kind === 'fix'
                ? 'badge-warning'
                : 'badge-success'}"
          >
            {item.kind}
          </span>
          {#if item.since && item.since !== 'unknown'}
            <span class="text-xs text-muted font-mono">Since {item.since} ({item.ageDays}d)</span>
          {/if}
        </div>
        <h2 id="detail-modal-title" class="text-2xl font-mono font-bold text-heading break-all">{item.name}</h2>
      </div>

      <button
        type="button"
        onclick={onClose}
        class="text-muted hover:text-heading p-1.5 rounded-lg hover:bg-surface-high transition cursor-pointer shrink-0"
        aria-label="Close modal"
      >
        <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
        </svg>
      </button>
    </div>

    <!-- Modal Body -->
    <div class="overflow-y-auto py-4 space-y-4 pr-1 text-sm text-fg">
      <!-- Reason -->
      <div>
        <div class="text-xs uppercase tracking-wider text-muted font-medium mb-1">Why it is in detour</div>
        <p class="bg-bg/70 p-3 rounded-lg border border-line leading-relaxed font-sans text-heading">
          {item.reason}
        </p>
      </div>

      <!-- Metadata grid -->
      <div class="grid grid-cols-1 sm:grid-cols-2 gap-3 font-mono text-xs">
        <div class="p-3 bg-bg/60 rounded-lg border border-line">
          <span class="text-muted block mb-1">Source origin</span>
          <span class="text-heading font-medium break-all">{item.fullSource}</span>
        </div>

        {#if item.releaseWhen}
          <div class="p-3 bg-bg/60 rounded-lg border border-line">
            <span class="text-status-ai block mb-1">Release trigger (releaseWhen)</span>
            <span class="text-heading font-medium break-all">{item.releaseWhen}</span>
          </div>
        {/if}

        {#if item.untilVersion}
          <div class="p-3 bg-bg/60 rounded-lg border border-line">
            <span class="text-status-warning block mb-1">Target version (untilVersion)</span>
            <span class="text-heading font-medium">&gt;= {item.untilVersion}</span>
          </div>
        {/if}

        {#if item.untilChannel}
          <div class="p-3 bg-bg/60 rounded-lg border border-line">
            <span class="text-status-info block mb-1">Target channel (untilChannel)</span>
            <span class="text-heading font-medium">{item.untilChannel}</span>
          </div>
        {/if}

        {#if item.override}
          <div class="p-3 bg-bg/60 rounded-lg border border-line">
            <span class="text-status-warning block mb-1">Override expression</span>
            <span class="text-heading font-medium break-all">{item.override}</span>
          </div>
        {/if}
      </div>

      <!-- Upstream Reference -->
      {#if item.link}
        <div>
          <div class="text-xs uppercase tracking-wider text-muted font-medium mb-1">Upstream Reference</div>
          <a
            href={item.link}
            target="_blank"
            rel="noopener noreferrer"
            class="inline-flex items-center gap-2 text-status-info hover:underline font-mono text-xs break-all"
          >
            <span>{item.link}</span>
            <svg class="w-4 h-4 shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14" />
            </svg>
          </a>
        </div>
      {/if}

      <!-- Patches -->
      {#if item.patches && item.patches.length > 0}
        <div>
          <div class="text-xs uppercase tracking-wider text-muted font-medium mb-1">Applied Patches</div>
          <div class="space-y-1.5 font-mono text-xs">
            {#each item.patches as patch, idx (idx)}
              <div class="p-2.5 bg-bg/60 rounded-lg border border-line flex items-center justify-between gap-2">
                <span class="truncate text-heading">{typeof patch === 'string' ? patch : patch.url}</span>
                {#if typeof patch !== 'string'}
                  <span class="shrink-0 text-muted text-[10px]">{patch.hash.slice(0, 18)}…</span>
                {/if}
              </div>
            {/each}
          </div>
        </div>
      {/if}

      <!-- Exported Attributes / Python / Scope / Modules / Tests -->
      {#if item.attrs && item.attrs.length > 0}
        <div>
          <div class="text-xs uppercase tracking-wider text-muted font-medium mb-1">Exported Attributes</div>
          <div class="flex flex-wrap gap-1.5 font-mono text-xs">
            {#each item.attrs as attr, idx (idx)}
              <span class="badge badge-success !py-0.5">{attr}</span>
            {/each}
          </div>
        </div>
      {/if}

      {#if item.pythonPackages && item.pythonPackages.length > 0}
        <div>
          <div class="text-xs uppercase tracking-wider text-muted font-medium mb-1">Python Packages</div>
          <div class="flex flex-wrap gap-1.5 font-mono text-xs">
            {#each item.pythonPackages as py, idx (idx)}
              <span class="badge badge-info !py-0.5">python3Packages.{py}</span>
            {/each}
          </div>
        </div>
      {/if}

      {#if item.scope && item.scope.length > 0}
        <div>
          <div class="text-xs uppercase tracking-wider text-muted font-medium mb-1">Internal Scope Dependencies</div>
          <div class="flex flex-wrap gap-1.5 font-mono text-xs">
            {#each item.scope as sc, idx (idx)}
              <span class="badge badge-muted !py-0.5">{sc}</span>
            {/each}
          </div>
        </div>
      {/if}

      {#if item.modules && Object.keys(item.modules).length > 0}
        <div>
          <div class="text-xs uppercase tracking-wider text-muted font-medium mb-1">NixOS Modules</div>
          <div class="space-y-1 font-mono text-xs">
            {#each Object.entries(item.modules) as [mod, relPath] (mod)}
              <div class="p-2 bg-bg/60 rounded-lg border border-line flex items-center justify-between gap-2">
                <span class="font-semibold text-heading">{mod}</span>
                <span class="text-muted truncate">{relPath}</span>
              </div>
            {/each}
          </div>
        </div>
      {/if}

      {#if item.tests && item.tests.length > 0}
        <div>
          <div class="text-xs uppercase tracking-wider text-muted font-medium mb-1">NixOS VM Tests</div>
          <div class="flex flex-wrap gap-1.5 font-mono text-xs">
            {#each item.tests as t, idx (idx)}
              <span class="badge badge-ai !py-0.5">nixosTests.{t}</span>
            {/each}
          </div>
        </div>
      {/if}

      <!-- CLI Command Box -->
      <div>
        <div class="flex items-center justify-between mb-1">
          <span class="text-xs uppercase tracking-wider text-muted font-medium">CLI Command</span>
          <button
            type="button"
            onclick={copyCli}
            class="text-xs font-mono text-accent-soft-fg hover:underline flex items-center gap-1 cursor-pointer"
          >
            {#if copiedCli}
              <span class="text-status-success">Copied!</span>
            {:else}
              <span>Copy CLI</span>
            {/if}
          </button>
        </div>
        <pre class="bg-bg p-3 rounded-lg border border-line overflow-x-auto text-xs font-mono text-heading whitespace-pre-wrap">{cliCommand}</pre>
      </div>

      <!-- Raw JSON Entry -->
      <div>
        <div class="flex items-center justify-between mb-1">
          <span class="text-xs uppercase tracking-wider text-muted font-medium">JSON Definition</span>
          <button
            type="button"
            onclick={copyJson}
            class="text-xs font-mono text-muted hover:text-heading cursor-pointer"
          >
            {#if copiedJson}
              <span class="text-status-success">Copied!</span>
            {:else}
              <span>Copy JSON</span>
            {/if}
          </button>
        </div>
        <pre class="bg-bg p-3 rounded-lg border border-line overflow-x-auto text-xs font-mono text-fg">{jsonString}</pre>
      </div>
    </div>

    <!-- Modal Footer -->
    <div class="pt-4 border-t border-line flex justify-end">
      <button
        type="button"
        onclick={onClose}
        class="px-4 py-2 rounded-lg bg-surface-high hover:border-outline/50 border border-line text-heading font-medium text-xs transition cursor-pointer"
      >
        Close
      </button>
    </div>
  </div>
</dialog>
