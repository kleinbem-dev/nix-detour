<script lang="ts">
  import type { HoldEntry, PrEntry } from '../types';
  import { dialogFocus } from '../utils';

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

  const isString = (v: unknown) => typeof v === 'string';
  const isStringList = (v: unknown) => Array.isArray(v) && v.every(isString);
  const isStringMap = (v: unknown) =>
    !!v && typeof v === 'object' && !Array.isArray(v) && Object.values(v).every(isString);
  // Patches are files next to the holds file, or { url, hash }.
  const isPatch = (v: unknown) =>
    isString(v) ||
    (!!v && typeof v === 'object' && isString((v as Record<string, unknown>).url) && isString((v as Record<string, unknown>).hash));

  // The first field the dashboard can't show, as an error message; null when all fit.
  function validateEntries(records: unknown, kind: 'hold' | 'pr'): string | null {
    const file = kind === 'pr' ? 'nixpkgs-prs.json' : 'held-packages.json';
    if (!records || typeof records !== 'object' || Array.isArray(records)) {
      return `${file} must be a JSON object mapping package names to entries`;
    }
    for (const [key, value] of Object.entries(records)) {
      if (!value || typeof value !== 'object' || Array.isArray(value)) {
        return `${file} entry "${key}" must be an object`;
      }
      const e = value as Record<string, unknown>;
      const bad = (field: string) => `${kind} entry "${key}" has an invalid ${field}`;
      const optional = (field: string, ok: (v: unknown) => boolean) => e[field] == null || ok(e[field]);
      if (kind === 'pr') {
        if (typeof e.pr !== 'number') return bad('pr');
        for (const f of ['owner', 'repo', 'rev', 'narHash']) if (!isString(e[f])) return bad(f);
        if (!isStringList(e.attrs)) return bad('attrs');
        if (!optional('scope', isStringList)) return bad('scope');
        if (!optional('paths', isStringMap)) return bad('paths');
        if (!optional('modules', isStringMap)) return bad('modules');
        if (!optional('untilChannel', isString)) return bad('untilChannel');
      } else {
        const from: unknown = e.from;
        const fromOk =
          from == null ||
          from === 'stable' ||
          from === 'current' ||
          (typeof from === 'object' &&
            !Array.isArray(from) &&
            isString((from as Record<string, unknown>).rev) &&
            isString((from as Record<string, unknown>).narHash));
        if (!fromOk) return bad('from');
        for (const f of ['since', 'reason', 'link', 'releaseWhen', 'untilVersion', 'override']) {
          if (!optional(f, isString)) return bad(f);
        }
        if (!optional('tests', isStringList)) return bad('tests');
        if (!optional('patches', (v) => Array.isArray(v) && v.every(isPatch))) return bad('patches');
      }
    }
    return null;
  }

  async function fetchFromGithub() {
    const targetRepo = repoInput.trim();
    if (!targetRepo || !targetRepo.includes('/')) {
      errorMsg = 'Please enter a valid owner/repo (e.g. kleinbem/nix-detour-fleet)';
      return;
    }
    loading = true;
    errorMsg = '';

    try {
      // Fetch held-packages.json
      const holdsRes = await fetch(`https://raw.githubusercontent.com/${targetRepo}/main/held-packages.json`);
      let holds: Record<string, HoldEntry> = {};
      if (holdsRes.ok) {
        holds = await holdsRes.json();
      }

      // Fetch nixpkgs-prs.json
      const prsRes = await fetch(`https://raw.githubusercontent.com/${targetRepo}/main/nixpkgs-prs.json`);
      let prs: Record<string, PrEntry> = {};
      if (prsRes.ok) {
        prs = await prsRes.json();
      }

      const invalid = validateEntries(holds, 'hold') ?? validateEntries(prs, 'pr');
      if (invalid) {
        errorMsg = invalid;
        return;
      }

      if (Object.keys(holds).length === 0 && Object.keys(prs).length === 0) {
        errorMsg = `No held-packages.json or nixpkgs-prs.json found in ${targetRepo} (or failed to fetch).`;
      } else {
        onLoadData(holds, prs, targetRepo);
        onClose();
      }
    } catch (err: any) {
      errorMsg = `Failed to fetch from GitHub: ${err?.message || String(err)}`;
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
        const raw = JSON.parse(holdsJsonText);
        parsedHolds = raw;
      } catch (err: any) {
        errorMsg = `Invalid JSON in held-packages.json: ${err.message}`;
        return;
      }
    }

    if (prsJsonText.trim()) {
      try {
        const raw = JSON.parse(prsJsonText);
        parsedPrs = raw;
      } catch (err: any) {
        errorMsg = `Invalid JSON in nixpkgs-prs.json: ${err.message}`;
        return;
      }
    }

    const invalid = validateEntries(parsedHolds, 'hold') ?? validateEntries(parsedPrs, 'pr');
    if (invalid) {
      errorMsg = invalid;
      return;
    }

    if (Object.keys(parsedHolds).length === 0 && Object.keys(parsedPrs).length === 0) {
      errorMsg = 'Please paste at least one valid JSON object.';
      return;
    }

    onLoadData(parsedHolds, parsedPrs, 'Pasted JSON');
    onClose();
  }
</script>

<div
  class="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/75 backdrop-blur-sm"
  onclick={onClose}
  onkeydown={(e) => { if (e.key === 'Escape') onClose(); }}
  role="presentation"
>
  <div
    class="relative w-full max-w-xl bg-stone-900 border border-stone-700/80 rounded-2xl shadow-2xl p-6 overflow-hidden flex flex-col"
    onclick={(e) => e.stopPropagation()}
    onkeydown={(e) => {
      if (e.key === 'Escape') onClose();
      e.stopPropagation();
    }}
    use:dialogFocus
    role="dialog"
    tabindex="-1"
    aria-modal="true"
    aria-labelledby="import-modal-title"
  >
    <div class="flex items-center justify-between pb-3 border-b border-stone-800">
      <h3 id="import-modal-title" class="text-lg font-bold text-stone-100 font-mono">Load / Import Detours</h3>
      <button
        type="button"
        onclick={onClose}
        class="text-stone-400 hover:text-stone-200 p-1.5 rounded-lg hover:bg-stone-800 transition cursor-pointer"
        aria-label="Close"
      >
        <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
        </svg>
      </button>
    </div>

    <div class="py-4 space-y-5 text-sm">
      {#if errorMsg}
        <div class="p-3 rounded-lg bg-rose-950/70 border border-rose-800/80 text-rose-300 text-xs">
          {errorMsg}
        </div>
      {/if}

      <!-- Option 1: Live GitHub fetch -->
      <div class="space-y-2">
        <label for="repo-input" class="text-xs uppercase tracking-wider font-semibold text-stone-300 block">
          Fetch from GitHub Repository
        </label>
        <div class="flex gap-2">
          <input
            id="repo-input"
            type="text"
            bind:value={repoInput}
            placeholder="owner/repository"
            class="flex-1 bg-stone-950 border border-stone-700/80 rounded-lg px-3 py-2 text-stone-200 text-xs font-mono focus:outline-none focus:border-amber-500"
          />
          <button
            type="button"
            onclick={fetchFromGithub}
            disabled={loading}
            class="px-4 py-2 bg-amber-600 hover:bg-amber-500 disabled:opacity-50 text-stone-950 font-semibold text-xs rounded-lg transition cursor-pointer shrink-0"
          >
            {loading ? 'Fetching...' : 'Fetch'}
          </button>
        </div>
        <p class="text-xs text-stone-400">Reads `main` branch raw JSON files via GitHub CDN.</p>
      </div>

      <div class="relative flex py-1 items-center">
        <div class="flex-grow border-t border-stone-800"></div>
        <span class="flex-shrink mx-4 text-xs font-mono uppercase text-stone-500">or paste JSON</span>
        <div class="flex-grow border-t border-stone-800"></div>
      </div>

      <!-- Option 2: Paste JSON -->
      <div class="space-y-3">
        <div>
          <label for="holds-json" class="text-xs uppercase tracking-wider font-semibold text-stone-300 block mb-1">
            held-packages.json content
          </label>
          <textarea
            id="holds-json"
            bind:value={holdsJsonText}
            placeholder="Paste held-packages.json content..."
            rows="3"
            class="w-full bg-stone-950 border border-stone-700/80 rounded-lg p-2.5 text-stone-200 font-mono text-xs focus:outline-none focus:border-amber-500 resize-none"
          ></textarea>
        </div>

        <div>
          <label for="prs-json" class="text-xs uppercase tracking-wider font-semibold text-stone-300 block mb-1">
            nixpkgs-prs.json content
          </label>
          <textarea
            id="prs-json"
            bind:value={prsJsonText}
            placeholder="Paste nixpkgs-prs.json content (optional)..."
            rows="3"
            class="w-full bg-stone-950 border border-stone-700/80 rounded-lg p-2.5 text-stone-200 font-mono text-xs focus:outline-none focus:border-amber-500 resize-none"
          ></textarea>
        </div>

        <button
          type="button"
          onclick={applyPastedJson}
          class="w-full py-2 bg-stone-800 hover:bg-stone-700 text-stone-100 font-medium text-xs rounded-lg transition cursor-pointer"
        >
          Apply Pasted JSON
        </button>
      </div>
    </div>

    <div class="pt-4 border-t border-stone-800 flex items-center justify-between">
      <button
        type="button"
        onclick={() => { onResetDefault(); onClose(); }}
        class="text-xs text-stone-400 hover:text-stone-200 underline cursor-pointer"
      >
        Reset to fleet sample data
      </button>

      <button
        type="button"
        onclick={onClose}
        class="px-4 py-2 rounded-lg bg-stone-800 hover:bg-stone-700 text-stone-200 font-medium text-xs transition cursor-pointer"
      >
        Cancel
      </button>
    </div>
  </div>
</div>
