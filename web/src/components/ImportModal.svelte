<script lang="ts">
  import type { HoldEntry, PrEntry } from '../types';
  import { modalDialog, validateEntries } from '../utils';

  interface Props {
    onLoadData: (holds: Record<string, HoldEntry>, prs: Record<string, PrEntry>, sourceName: string) => void;
    onResetDefault: () => void;
    onClose: () => void;
  }

  let { onLoadData, onResetDefault, onClose }: Props = $props();

  let repoInput = $state('kleinbem/nix-detour-fleet');
  let holdsJsonText = $state('');
  let prsJsonText = $state('');
  let loading = $state(false);
  let errorMsg = $state('');

  async function fetchFromGithub() {
    const targetRepo = repoInput.trim();
    if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(targetRepo)) {
      errorMsg = 'Enter a valid owner/repository (e.g. kleinbem/nix-detour-fleet)';
      return;
    }
    loading = true;
    errorMsg = '';

    try {
      const [holdsRes, prsRes] = await Promise.all([
        fetch(`https://raw.githubusercontent.com/${targetRepo}/main/held-packages.json`),
        fetch(`https://raw.githubusercontent.com/${targetRepo}/main/nixpkgs-prs.json`)
      ]);

      const holds: Record<string, HoldEntry> = holdsRes.ok ? await holdsRes.json() : {};
      const prs: Record<string, PrEntry> = prsRes.ok ? await prsRes.json() : {};

      const invalid = validateEntries(holds, 'hold') ?? validateEntries(prs, 'pr');
      if (invalid) {
        errorMsg = invalid;
        return;
      }

      if (Object.keys(holds).length === 0 && Object.keys(prs).length === 0) {
        errorMsg = `No held-packages.json or nixpkgs-prs.json entries found in ${targetRepo}.`;
        return;
      }

      onLoadData(holds, prs, targetRepo);
      onClose();
    } catch (err: unknown) {
      errorMsg = `Failed to fetch from GitHub: ${err instanceof Error ? err.message : String(err)}`;
    } finally {
      loading = false;
    }
  }

  function applyPastedJson() {
    errorMsg = '';
    let parsedHolds: Record<string, HoldEntry> = {};
    let parsedPrs: Record<string, PrEntry> = {};

    if (holdsJsonText.trim()) {
      try {
        parsedHolds = JSON.parse(holdsJsonText);
      } catch (err: unknown) {
        errorMsg = `Invalid JSON in held-packages.json: ${err instanceof Error ? err.message : String(err)}`;
        return;
      }
    }

    if (prsJsonText.trim()) {
      try {
        parsedPrs = JSON.parse(prsJsonText);
      } catch (err: unknown) {
        errorMsg = `Invalid JSON in nixpkgs-prs.json: ${err instanceof Error ? err.message : String(err)}`;
        return;
      }
    }

    const invalid = validateEntries(parsedHolds, 'hold') ?? validateEntries(parsedPrs, 'pr');
    if (invalid) {
      errorMsg = invalid;
      return;
    }

    if (Object.keys(parsedHolds).length === 0 && Object.keys(parsedPrs).length === 0) {
      errorMsg = 'Paste at least one non-empty JSON object.';
      return;
    }

    onLoadData(parsedHolds, parsedPrs, 'Pasted JSON');
    onClose();
  }
</script>

<dialog
  {@attach modalDialog}
  onclose={onClose}
  aria-labelledby="import-modal-title"
  class="m-auto w-[calc(100%-2rem)] max-w-xl p-0 bg-transparent border-0 text-fg"
>
  <div class="w-full bg-surface border border-line rounded-2xl shadow-2xl p-6 overflow-hidden max-h-[90vh] flex flex-col">
    <div class="flex items-center justify-between pb-3 border-b border-line">
      <h2 id="import-modal-title" class="text-lg font-bold text-heading font-mono">Load / Import Detours</h2>
      <button
        type="button"
        onclick={onClose}
        class="text-muted hover:text-heading p-1.5 rounded-lg hover:bg-surface-high transition cursor-pointer"
        aria-label="Close modal"
      >
        <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
        </svg>
      </button>
    </div>

    <div class="py-4 space-y-5 text-sm overflow-y-auto">
      {#if errorMsg}
        <div role="alert" class="p-3 rounded-lg bg-status-danger-soft border border-status-danger-border text-status-danger text-xs font-mono">
          {errorMsg}
        </div>
      {/if}

      <!-- Option 1: Live GitHub fetch -->
      <div class="space-y-2">
        <label for="repo-input" class="text-xs uppercase tracking-wider font-semibold text-fg block">
          Fetch from GitHub Repository
        </label>
        <div class="flex gap-2">
          <input
            id="repo-input"
            type="text"
            bind:value={repoInput}
            placeholder="owner/repository"
            class="flex-1 bg-bg border border-line rounded-lg px-3 py-2 text-heading text-xs font-mono focus:outline-none focus:border-accent"
          />
          <button
            type="button"
            onclick={fetchFromGithub}
            disabled={loading}
            class="px-4 py-2 bg-accent hover:bg-accent-hover disabled:opacity-50 text-accent-fg font-semibold text-xs rounded-lg transition cursor-pointer shrink-0"
          >
            {loading ? 'Fetching…' : 'Fetch'}
          </button>
        </div>
        <p class="text-xs text-muted">Reads <code>main</code> branch JSON files via GitHub raw CDN (preview only).</p>
      </div>

      <div class="relative flex py-1 items-center">
        <div class="flex-grow border-t border-line"></div>
        <span class="flex-shrink mx-4 text-xs font-mono uppercase text-muted">or paste JSON</span>
        <div class="flex-grow border-t border-line"></div>
      </div>

      <!-- Option 2: Paste JSON -->
      <div class="space-y-3">
        <div>
          <label for="holds-json" class="text-xs uppercase tracking-wider font-semibold text-fg block mb-1">
            held-packages.json content
          </label>
          <textarea
            id="holds-json"
            bind:value={holdsJsonText}
            placeholder="Paste held-packages.json content…"
            rows="3"
            class="w-full bg-bg border border-line rounded-lg p-2.5 text-heading font-mono text-xs focus:outline-none focus:border-accent resize-none"
          ></textarea>
        </div>

        <div>
          <label for="prs-json" class="text-xs uppercase tracking-wider font-semibold text-fg block mb-1">
            nixpkgs-prs.json content
          </label>
          <textarea
            id="prs-json"
            bind:value={prsJsonText}
            placeholder="Paste nixpkgs-prs.json content (optional)…"
            rows="3"
            class="w-full bg-bg border border-line rounded-lg p-2.5 text-heading font-mono text-xs focus:outline-none focus:border-accent resize-none"
          ></textarea>
        </div>

        <button
          type="button"
          onclick={applyPastedJson}
          class="w-full py-2 bg-surface-high hover:border-outline/50 border border-line text-heading font-medium text-xs rounded-lg transition cursor-pointer"
        >
          Apply Pasted JSON
        </button>
      </div>
    </div>

    <div class="pt-4 border-t border-line flex items-center justify-between">
      <button
        type="button"
        onclick={() => {
          onResetDefault();
          onClose();
        }}
        class="text-xs text-muted hover:text-heading underline cursor-pointer"
      >
        Load fleet sample data
      </button>

      <button
        type="button"
        onclick={onClose}
        class="px-4 py-2 rounded-lg bg-surface-high hover:border-outline/50 border border-line text-heading font-medium text-xs transition cursor-pointer"
      >
        Cancel
      </button>
    </div>
  </div>
</dialog>
