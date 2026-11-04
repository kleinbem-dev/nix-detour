<script lang="ts">
  import type { DetourItem } from '../types';
  import { generateCliCommand } from '../utils';

  interface Props {
    item: DetourItem;
    onClose: () => void;
  }

  let { item, onClose }: Props = $props();

  let cliCommand = $derived(generateCliCommand(item));
  let jsonString = $derived(JSON.stringify(item.raw, null, 2));

  let copiedCli = $state(false);
  let copiedJson = $state(false);

  function copyCli() {
    navigator.clipboard.writeText(cliCommand);
    copiedCli = true;
    setTimeout(() => { copiedCli = false; }, 1500);
  }

  function copyJson() {
    navigator.clipboard.writeText(jsonString);
    copiedJson = true;
    setTimeout(() => { copiedJson = false; }, 1500);
  }
</script>

<div
  class="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/75 backdrop-blur-sm"
  onclick={onClose}
  onkeydown={(e) => { if (e.key === 'Escape') onClose(); }}
  role="presentation"
>
  <div
    class="relative w-full max-w-2xl bg-stone-900 border border-stone-700/80 rounded-2xl shadow-2xl p-6 overflow-hidden max-h-[90vh] flex flex-col"
    onclick={(e) => e.stopPropagation()}
    onkeydown={(e) => e.stopPropagation()}
    role="dialog"
    tabindex="-1"
    aria-modal="true"
  >
    <!-- Modal Header -->
    <div class="flex items-start justify-between pb-4 border-b border-stone-800">
      <div>
        <div class="flex items-center gap-2 mb-1">
          <span class="text-xs uppercase font-bold tracking-wider px-2 py-0.5 rounded font-mono
            {item.kind === 'hold' ? 'bg-cyan-950 text-cyan-400 border border-cyan-800/50' :
             item.kind === 'fix' ? 'bg-amber-950 text-amber-400 border border-amber-800/50' :
             'bg-emerald-950 text-emerald-400 border border-emerald-800/50'}">
            {item.kind}
          </span>
          {#if item.since}
            <span class="text-xs text-stone-400 font-mono">Since {item.since} ({item.ageDays}d)</span>
          {/if}
        </div>
        <h2 class="text-2xl font-mono font-bold text-stone-100">{item.name}</h2>
      </div>

      <button
        type="button"
        onclick={onClose}
        class="text-stone-400 hover:text-stone-200 p-1.5 rounded-lg hover:bg-stone-800 transition cursor-pointer"
        aria-label="Close modal"
      >
        <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
        </svg>
      </button>
    </div>

    <!-- Modal Body -->
    <div class="overflow-y-auto py-4 space-y-4 pr-1 text-sm text-stone-300">
      <!-- Reason -->
      <div>
        <div class="text-xs uppercase tracking-wider text-stone-400 font-medium mb-1">Why it is in detour</div>
        <p class="bg-stone-950/70 p-3 rounded-lg border border-stone-800/80 leading-relaxed font-sans text-stone-200">
          {item.reason}
        </p>
      </div>

      <!-- Links & Release condition -->
      <div class="grid grid-cols-1 sm:grid-cols-2 gap-3 font-mono text-xs">
        <div class="p-3 bg-stone-950/50 rounded-lg border border-stone-800/60">
          <span class="text-stone-500 block mb-1">Source origin</span>
          <span class="text-stone-200 font-medium">{item.fullSource}</span>
        </div>

        {#if item.releaseWhen}
          <div class="p-3 bg-stone-950/50 rounded-lg border border-stone-800/60">
            <span class="text-purple-400 block mb-1">Release trigger (releaseWhen)</span>
            <span class="text-stone-200 font-medium">{item.releaseWhen}</span>
          </div>
        {/if}
      </div>

      <!-- Links row -->
      {#if item.link}
        <div>
          <div class="text-xs uppercase tracking-wider text-stone-400 font-medium mb-1">Upstream Reference</div>
          <a
            href={item.link}
            target="_blank"
            rel="noopener noreferrer"
            class="inline-flex items-center gap-2 text-cyan-400 hover:text-cyan-300 hover:underline font-mono text-xs break-all"
          >
            <span>{item.link}</span>
            <svg class="w-4 h-4 shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14" />
            </svg>
          </a>
        </div>
      {/if}

      <!-- Patches or PR Attrs -->
      {#if item.patches && item.patches.length > 0}
        <div>
          <div class="text-xs uppercase tracking-wider text-stone-400 font-medium mb-1">Applied Patches</div>
          <div class="space-y-1.5 font-mono text-xs">
            {#each item.patches as patch}
              <div class="p-2.5 bg-stone-950/60 rounded border border-stone-800/80 flex items-center justify-between gap-2">
                <span class="truncate">{typeof patch === 'string' ? patch : patch.url}</span>
                {#if typeof patch !== 'string'}
                  <span class="shrink-0 text-stone-500 text-[10px]">{patch.hash.slice(0, 16)}...</span>
                {/if}
              </div>
            {/each}
          </div>
        </div>
      {/if}

      {#if item.attrs && item.attrs.length > 0}
        <div>
          <div class="text-xs uppercase tracking-wider text-stone-400 font-medium mb-1">Exported Attributes</div>
          <div class="flex flex-wrap gap-1 font-mono text-xs">
            {#each item.attrs as attr}
              <span class="px-2 py-0.5 rounded bg-emerald-950/60 text-emerald-300 border border-emerald-800/50">
                {attr}
              </span>
            {/each}
          </div>
        </div>
      {/if}

      <!-- CLI Command Box -->
      <div>
        <div class="flex items-center justify-between mb-1">
          <span class="text-xs uppercase tracking-wider text-stone-400 font-medium">CLI Command</span>
          <button
            type="button"
            onclick={copyCli}
            class="text-xs font-mono text-amber-400 hover:text-amber-300 flex items-center gap-1 cursor-pointer"
          >
            {#if copiedCli}
              <span class="text-emerald-400">Copied!</span>
            {:else}
              <span>Copy CLI</span>
            {/if}
          </button>
        </div>
        <pre class="bg-stone-950 p-3 rounded-lg border border-stone-800 overflow-x-auto text-xs font-mono text-amber-300/90 whitespace-pre-wrap">{cliCommand}</pre>
      </div>

      <!-- Raw JSON Entry -->
      <div>
        <div class="flex items-center justify-between mb-1">
          <span class="text-xs uppercase tracking-wider text-stone-400 font-medium">JSON Definition</span>
          <button
            type="button"
            onclick={copyJson}
            class="text-xs font-mono text-stone-400 hover:text-stone-200 cursor-pointer"
          >
            {#if copiedJson}
              <span class="text-emerald-400">Copied!</span>
            {:else}
              <span>Copy JSON</span>
            {/if}
          </button>
        </div>
        <pre class="bg-stone-950 p-3 rounded-lg border border-stone-800 overflow-x-auto text-xs font-mono text-stone-300">{jsonString}</pre>
      </div>
    </div>

    <!-- Modal Footer -->
    <div class="pt-4 border-t border-stone-800 flex justify-end">
      <button
        type="button"
        onclick={onClose}
        class="px-4 py-2 rounded-lg bg-stone-800 hover:bg-stone-700 text-stone-200 font-medium text-xs transition cursor-pointer"
      >
        Close
      </button>
    </div>
  </div>
</div>
