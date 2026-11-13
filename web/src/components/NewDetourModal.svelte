<script lang="ts">
  import type { DetourKind, HoldEntry, HoldSource, PrEntry } from '../types';
  import { modalDialog } from '../utils';

  interface Props {
    onClose: () => void;
    onCreateDetour: (name: string, kind: DetourKind, entry: HoldEntry | PrEntry) => Promise<boolean>;
    canPin: boolean;
  }

  let { onClose, onCreateDetour, canPin }: Props = $props();

  let activeTab = $state<DetourKind>('fix');
  let packageName = $state('');
  let reason = $state('');
  let link = $state('');
  let untilVersion = $state('');
  let releaseWhen = $state('');

  // Hold / Fix specific
  let fromSource = $state<'current' | 'stable' | 'previous' | 'custom'>('current');
  let customRev = $state('');
  let patchInput = $state('');
  let patches = $state<string[]>([]);
  let overrideFile = $state('');

  // PR specific
  let prRefInput = $state('');
  let prAutoDetect = $state(true);
  let prRepo = $state('');
  let prUpstream = $state('NixOS/nixpkgs');
  let prAttrs = $state('');
  let prPython = $state('');
  let prChannel = $state('nixos-unstable');

  let errorMsg = $state('');
  let saving = $state(false);

  const effectiveAuto = $derived(canPin && prAutoDetect);

  function addPatch() {
    if (!patchInput.trim()) return;
    patches = [...patches, patchInput.trim()];
    patchInput = '';
  }

  function removePatch(idx: number) {
    patches = patches.filter((_, i) => i !== idx);
  }

  function handleTabChange(tab: DetourKind) {
    activeTab = tab;
    if (tab === 'fix') {
      fromSource = 'current';
    } else if (tab === 'hold') {
      fromSource = 'stable';
    }
    errorMsg = '';
  }

  function parsePrRef(raw: string): { pr: number; upstream?: string } | null {
    const trimmed = raw.trim();
    const urlMatch = trimmed.match(/github\.com\/([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)\/pull\/(\d+)/);
    if (urlMatch) {
      return { upstream: urlMatch[1], pr: Number(urlMatch[2]) };
    }
    const shortMatch = trimmed.match(/^(?:([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+))?#?(\d+)$/);
    if (shortMatch) {
      return { upstream: shortMatch[1], pr: Number(shortMatch[2]) };
    }
    return null;
  }

  async function save(name: string, kind: DetourKind, entry: HoldEntry | PrEntry) {
    saving = true;
    try {
      if (await onCreateDetour(name, kind, entry)) {
        onClose();
      }
    } finally {
      saving = false;
    }
  }

  async function handleSubmit(e: SubmitEvent) {
    e.preventDefault();
    if (saving) return;
    errorMsg = '';
    const name = packageName.trim();

    if (name && !/^[A-Za-z0-9_][A-Za-z0-9_+.-]*$/.test(name)) {
      errorMsg = 'Package name must start with an alphanumeric character or underscore';
      return;
    }

    if (activeTab === 'pr') {
      const parsed = parsePrRef(prRefInput);
      if (!parsed || parsed.pr <= 0) {
        errorMsg = 'Enter a valid PR number or GitHub PR URL (e.g. 571722)';
        return;
      }
      const upstream = (parsed.upstream || prUpstream.trim() || 'NixOS/nixpkgs');
      if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(upstream)) {
        errorMsg = 'Upstream repository must be formatted as owner/repo';
        return;
      }

      if (effectiveAuto) {
        const entry: PrEntry = {
          pr: parsed.pr,
          owner: '',
          repo: '',
          rev: '',
          narHash: '',
          attrs: [],
          upstream: upstream !== 'NixOS/nixpkgs' ? upstream : undefined,
          untilChannel: prChannel.trim() || 'nixos-unstable',
          auto: true
        };
        await save(name, 'pr', entry);
        return;
      }

      if (!name) {
        errorMsg = 'Package name is required when manual PR fields are used';
        return;
      }
      const fork = prRepo.trim() || 'NixOS/nixpkgs';
      const parts = fork.split('/');
      if (parts.length !== 2 || !parts[0] || !parts[1]) {
        errorMsg = 'Fork repository must be formatted as owner/repo';
        return;
      }
      const attrsList = prAttrs.trim()
        ? prAttrs.split(',').map((s) => s.trim()).filter(Boolean)
        : prPython.trim()
          ? []
          : [name];
      const pyList = prPython.trim()
        ? prPython.split(',').map((s) => s.trim()).filter(Boolean)
        : undefined;

      const entry: PrEntry = {
        pr: parsed.pr,
        owner: parts[0],
        repo: parts[1],
        rev: '',
        narHash: '',
        attrs: attrsList,
        pythonPackages: pyList,
        upstream: upstream !== 'NixOS/nixpkgs' ? upstream : undefined,
        untilChannel: prChannel.trim() || 'nixos-unstable'
      };

      await save(name, 'pr', entry);
      return;
    }

    if (!name) {
      errorMsg = 'Package name is required';
      return;
    }
    if (!reason.trim()) {
      errorMsg = 'Reason is required';
      return;
    }
    const cleanUntil = untilVersion.trim();
    if (cleanUntil && /^[<>=]/.test(cleanUntil)) {
      errorMsg = 'Enter a bare version number (e.g. 2.31.0) without >= operators';
      return;
    }

    let sourceVal: HoldSource = fromSource === 'custom' ? 'current' : fromSource;
    if (fromSource === 'previous' && !canPin) {
      errorMsg = 'Previous flake.lock revision requires the local server (`nix-detour web`)';
      return;
    }
    if (fromSource === 'custom') {
      if (!customRev.trim()) {
        errorMsg = 'Commit SHA is required when custom source is selected';
        return;
      }
      if (!canPin) {
        errorMsg = 'A specific revision needs the local server (`nix-detour web`) to pin its hash';
        return;
      }
      sourceVal = { rev: customRev.trim(), narHash: '' };
    }

    const isFix = activeTab === 'fix';
    if (isFix && patches.length === 0 && !overrideFile.trim()) {
      errorMsg = 'Fix requires at least one patch URL/file or an override expression file';
      return;
    }
    if (isFix && !canPin && patches.some((p) => /^https?:\/\//.test(p))) {
      errorMsg = 'A patch URL needs the local server (`nix-detour web`) to pin its hash';
      return;
    }

    const entry: HoldEntry = {
      from: sourceVal,
      since: new Date().toISOString().slice(0, 10),
      reason: reason.trim(),
      link: link.trim() || undefined,
      releaseWhen: releaseWhen.trim() || undefined,
      untilVersion: cleanUntil || undefined,
      patches: isFix && patches.length > 0 ? patches : undefined,
      override: isFix ? overrideFile.trim() || undefined : undefined
    };

    await save(name, activeTab, entry);
  }
</script>

<dialog
  {@attach modalDialog}
  onclose={onClose}
  aria-labelledby="new-detour-title"
  class="m-auto w-[calc(100%-2rem)] max-w-xl p-0 bg-transparent border-0 text-fg"
>
  <form
    onsubmit={handleSubmit}
    class="bg-surface border border-line rounded-2xl w-full shadow-2xl flex flex-col max-h-[90vh] overflow-hidden"
  >
    <!-- Header -->
    <div class="px-6 py-4 border-b border-line flex items-center justify-between">
      <div class="flex items-center gap-2">
        <span class="text-accent font-bold text-lg" aria-hidden="true">＋</span>
        <h2 id="new-detour-title" class="text-lg font-bold text-heading font-mono">Create Detour</h2>
      </div>
      <button
        type="button"
        onclick={onClose}
        aria-label="Close dialog"
        class="text-muted hover:text-heading p-1.5 rounded-lg hover:bg-surface-high transition cursor-pointer"
      >
        <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
        </svg>
      </button>
    </div>

    <!-- Type Tabs -->
    <div class="flex border-b border-line bg-bg/50 px-6 pt-3 gap-2" role="tablist" aria-label="Detour type">
      <button
        type="button"
        role="tab"
        aria-selected={activeTab === 'fix'}
        onclick={() => handleTabChange('fix')}
        class="px-3.5 py-2 rounded-t-xl text-xs font-mono font-medium transition cursor-pointer border-b-2 {activeTab === 'fix'
          ? 'border-accent text-heading bg-surface'
          : 'border-transparent text-muted hover:text-fg'}"
      >
        🔧 Fix (Patch / Override)
      </button>
      <button
        type="button"
        role="tab"
        aria-selected={activeTab === 'pr'}
        onclick={() => handleTabChange('pr')}
        class="px-3.5 py-2 rounded-t-xl text-xs font-mono font-medium transition cursor-pointer border-b-2 {activeTab === 'pr'
          ? 'border-accent text-heading bg-surface'
          : 'border-transparent text-muted hover:text-fg'}"
      >
        🔀 Nixpkgs PR Overlay
      </button>
      <button
        type="button"
        role="tab"
        aria-selected={activeTab === 'hold'}
        onclick={() => handleTabChange('hold')}
        class="px-3.5 py-2 rounded-t-xl text-xs font-mono font-medium transition cursor-pointer border-b-2 {activeTab === 'hold'
          ? 'border-accent text-heading bg-surface'
          : 'border-transparent text-muted hover:text-fg'}"
      >
        📌 Hold
      </button>
    </div>

    <!-- Form Body -->
    <div class="p-6 overflow-y-auto space-y-4 text-xs font-mono">
      {#if errorMsg}
        <div role="alert" class="p-3 bg-status-danger-soft border border-status-danger-border rounded-xl text-status-danger flex items-center gap-2">
          <span aria-hidden="true">⚠️</span>
          <span>{errorMsg}</span>
        </div>
      {/if}

      {#if activeTab === 'pr'}
        <div>
          <label for="pr-ref" class="block text-fg font-semibold mb-1">PR Number or GitHub URL *</label>
          <input
            id="pr-ref"
            type="text"
            bind:value={prRefInput}
            placeholder="e.g. 571722 or https://github.com/NixOS/nixpkgs/pull/571722"
            class="w-full bg-bg border border-line rounded-xl px-3 py-2 text-heading focus:outline-none focus:border-accent"
          />
        </div>

        {#if canPin}
          <label class="flex items-center gap-2.5 p-3 rounded-xl bg-bg/60 border border-line cursor-pointer">
            <input type="checkbox" bind:checked={prAutoDetect} class="accent-accent" />
            <span class="text-fg">Auto-detect fork, commit, attributes &amp; modules from GitHub PR</span>
          </label>
        {/if}

        <div>
          <label for="pkg-name" class="block text-fg font-semibold mb-1">
            Entry Name {effectiveAuto ? '(optional)' : '*'}
          </label>
          <input
            id="pkg-name"
            type="text"
            bind:value={packageName}
            placeholder={effectiveAuto ? 'Auto-detected from PR title/files if blank' : 'e.g. mesh-llm'}
            class="w-full bg-bg border border-line rounded-xl px-3 py-2 text-heading focus:outline-none focus:border-accent"
          />
        </div>

        {#if !effectiveAuto}
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
            <div>
              <label for="pr-repo" class="block text-fg font-semibold mb-1">Fork Repository *</label>
              <input
                id="pr-repo"
                type="text"
                bind:value={prRepo}
                placeholder="fork-owner/nixpkgs"
                class="w-full bg-bg border border-line rounded-xl px-3 py-2 text-heading focus:outline-none focus:border-accent"
              />
            </div>
            <div>
              <label for="pr-upstream" class="block text-fg font-semibold mb-1">Upstream Repository</label>
              <input
                id="pr-upstream"
                type="text"
                bind:value={prUpstream}
                placeholder="NixOS/nixpkgs"
                class="w-full bg-bg border border-line rounded-xl px-3 py-2 text-heading focus:outline-none focus:border-accent"
              />
            </div>
          </div>

          <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
            <div>
              <label for="pr-attrs" class="block text-fg font-semibold mb-1">Attributes (comma-separated)</label>
              <input
                id="pr-attrs"
                type="text"
                bind:value={prAttrs}
                placeholder="Defaults to entry name"
                class="w-full bg-bg border border-line rounded-xl px-3 py-2 text-heading focus:outline-none focus:border-accent"
              />
            </div>
            <div>
              <label for="pr-python" class="block text-fg font-semibold mb-1">Python Packages</label>
              <input
                id="pr-python"
                type="text"
                bind:value={prPython}
                placeholder="e.g. fastmcp"
                class="w-full bg-bg border border-line rounded-xl px-3 py-2 text-heading focus:outline-none focus:border-accent"
              />
            </div>
          </div>
        {/if}

        <div>
          <label for="pr-chan" class="block text-fg font-semibold mb-1">Target Channel</label>
          <input
            id="pr-chan"
            type="text"
            bind:value={prChannel}
            placeholder="nixos-unstable"
            class="w-full bg-bg border border-line rounded-xl px-3 py-2 text-heading focus:outline-none focus:border-accent"
          />
          <p class="text-[11px] text-muted mt-1">Channel monitored until the PR lands and the detour can be retired.</p>
        </div>
      {:else}
        <div>
          <label for="pkg-name" class="block text-fg font-semibold mb-1">Package Name *</label>
          <input
            id="pkg-name"
            type="text"
            bind:value={packageName}
            placeholder="e.g. fastfetch, ripgrep, qdrant"
            class="w-full bg-bg border border-line rounded-xl px-3 py-2 text-heading focus:outline-none focus:border-accent"
          />
        </div>

        <div>
          <label for="fix-reason" class="block text-fg font-semibold mb-1">Reason *</label>
          <input
            id="fix-reason"
            type="text"
            bind:value={reason}
            placeholder="e.g. Wayland multi-monitor crash on LLVM 22"
            class="w-full bg-bg border border-line rounded-xl px-3 py-2 text-heading focus:outline-none focus:border-accent"
          />
        </div>

        <div>
          <label for="fix-link" class="block text-fg font-semibold mb-1">Upstream PR / Issue Link</label>
          <input
            id="fix-link"
            type="url"
            bind:value={link}
            placeholder="https://github.com/NixOS/nixpkgs/issues/..."
            class="w-full bg-bg border border-line rounded-xl px-3 py-2 text-heading focus:outline-none focus:border-accent"
          />
        </div>

        <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
          <div>
            <label for="fix-release-when" class="block text-fg font-semibold mb-1">Release Trigger (releaseWhen)</label>
            <input
              id="fix-release-when"
              type="text"
              bind:value={releaseWhen}
              placeholder="e.g. python3Packages.fastmcp"
              class="w-full bg-bg border border-line rounded-xl px-3 py-2 text-heading focus:outline-none focus:border-accent"
            />
          </div>
          <div>
            <label for="fix-until" class="block text-fg font-semibold mb-1">Until Version (bare version)</label>
            <input
              id="fix-until"
              type="text"
              bind:value={untilVersion}
              placeholder="e.g. 2.31.0"
              class="w-full bg-bg border border-line rounded-xl px-3 py-2 text-heading focus:outline-none focus:border-accent"
            />
          </div>
        </div>

        {#if activeTab === 'fix'}
          <div class="space-y-2">
            <label for="patch-input" class="block text-fg font-semibold">Patches (URL or local file)</label>
            <div class="flex gap-2">
              <input
                id="patch-input"
                type="text"
                bind:value={patchInput}
                placeholder="https://github.com/.../123.patch"
                onkeydown={(e) => {
                  if (e.key === 'Enter') {
                    e.preventDefault();
                    addPatch();
                  }
                }}
                class="flex-1 bg-bg border border-line rounded-xl px-3 py-2 text-heading focus:outline-none focus:border-accent"
              />
              <button
                type="button"
                onclick={addPatch}
                class="px-3 py-2 bg-surface-high hover:border-outline/50 border border-line text-heading rounded-xl transition cursor-pointer shrink-0"
              >
                Add Patch
              </button>
            </div>

            {#if patches.length > 0}
              <div class="space-y-1.5 mt-2">
                {#each patches as p, idx (idx)}
                  <div class="flex items-center justify-between bg-bg border border-line rounded-lg px-2.5 py-1.5 text-[11px]">
                    <span class="truncate text-heading">{p}</span>
                    <button
                      type="button"
                      onclick={() => removePatch(idx)}
                      aria-label="Remove patch {p}"
                      class="text-status-danger hover:opacity-80 ml-2 cursor-pointer"
                    >
                      ✕
                    </button>
                  </div>
                {/each}
              </div>
            {/if}
          </div>

          <div>
            <label for="fix-override" class="block text-fg font-semibold mb-1">Override File (optional)</label>
            <input
              id="fix-override"
              type="text"
              bind:value={overrideFile}
              placeholder="e.g. fixes/pkg-override.nix"
              class="w-full bg-bg border border-line rounded-xl px-3 py-2 text-heading focus:outline-none focus:border-accent"
            />
          </div>
        {/if}

        <div>
          <label for="fix-from" class="block text-fg font-semibold mb-1">Base Nixpkgs Source</label>
          <select
            id="fix-from"
            bind:value={fromSource}
            class="w-full bg-bg border border-line rounded-xl px-3 py-2 text-heading focus:outline-none focus:border-accent cursor-pointer"
          >
            <option value="current">Current Nixpkgs</option>
            <option value="stable">Nixpkgs Stable</option>
            {#if canPin}
              <option value="previous">Previous flake.lock Revision</option>
            {/if}
            <option value="custom">Specific Commit Revision</option>
          </select>
        </div>

        {#if fromSource === 'custom'}
          <div>
            <label for="fix-rev" class="block text-fg font-semibold mb-1">Commit SHA</label>
            <input
              id="fix-rev"
              type="text"
              bind:value={customRev}
              placeholder="Full 40-char git commit SHA"
              class="w-full bg-bg border border-line rounded-xl px-3 py-2 text-heading focus:outline-none focus:border-accent"
            />
          </div>
        {/if}
      {/if}
    </div>

    <!-- Footer -->
    <div class="px-6 py-4 border-t border-line bg-bg/50 flex items-center justify-end gap-3">
      <button
        type="button"
        onclick={onClose}
        class="px-4 py-2 rounded-xl text-muted hover:text-heading hover:bg-surface-high transition cursor-pointer font-mono text-xs"
      >
        Cancel
      </button>
      <button
        type="submit"
        disabled={saving}
        class="px-4 py-2 bg-accent hover:bg-accent-hover text-accent-fg font-semibold rounded-xl shadow-xs transition cursor-pointer font-mono text-xs flex items-center gap-1.5 disabled:opacity-50 disabled:cursor-wait"
      >
        <span aria-hidden="true">✓</span>
        <span>{saving ? 'Saving…' : 'Create Detour'}</span>
      </button>
    </div>
  </form>
</dialog>
