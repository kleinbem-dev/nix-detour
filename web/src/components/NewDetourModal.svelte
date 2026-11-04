<script lang="ts">
  import type { DetourKind, HoldEntry, PrEntry } from '../types';

  interface Props {
    isOpen: boolean;
    onClose: () => void;
    onCreateDetour: (name: string, kind: DetourKind, entry: HoldEntry | PrEntry) => void;
  }

  let { isOpen, onClose, onCreateDetour }: Props = $props();

  let activeTab = $state<DetourKind>('fix');
  let packageName = $state('');
  let reason = $state('');
  let link = $state('');
  let untilVersion = $state('');
  let releaseWhen = $state('');

  // Hold / Fix specific
  let fromSource = $state('current'); // 'current', 'stable', or revision
  let customRev = $state('');
  let patchInput = $state('');
  let patches = $state<string[]>([]);
  let overrideFile = $state('');

  // PR specific
  let prNumber = $state<number | string>('');
  let prRepo = $state('NixOS/nixpkgs');
  let prAttrs = $state('');
  let prChannel = $state('nixos-unstable');

  let errorMsg = $state('');

  function addPatch() {
    if (!patchInput.trim()) return;
    patches = [...patches, patchInput.trim()];
    patchInput = '';
  }

  function removePatch(idx: number) {
    patches = patches.filter((_, i) => i !== idx);
  }

  function resetForm() {
    packageName = '';
    reason = '';
    link = '';
    untilVersion = '';
    releaseWhen = '';
    fromSource = activeTab === 'fix' ? 'current' : 'stable';
    customRev = '';
    patchInput = '';
    patches = [];
    overrideFile = '';
    prNumber = '';
    prRepo = 'NixOS/nixpkgs';
    prAttrs = '';
    prChannel = 'nixos-unstable';
    errorMsg = '';
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

  function handleSubmit() {
    errorMsg = '';
    const name = packageName.trim();
    if (!name) {
      errorMsg = 'Package name is required';
      return;
    }

    if (activeTab === 'pr') {
      const num = Number(prNumber);
      if (!prNumber || isNaN(num) || num <= 0) {
        errorMsg = 'Valid positive PR number is required';
        return;
      }
      const [owner, repo] = prRepo.includes('/') ? prRepo.split('/') : ['NixOS', 'nixpkgs'];
      const attrsList = prAttrs.trim() ? prAttrs.split(',').map((s) => s.trim()).filter(Boolean) : [name];

      const entry: PrEntry = {
        pr: num,
        owner: owner.trim(),
        repo: repo.trim(),
        rev: '',
        narHash: '',
        attrs: attrsList,
        untilChannel: prChannel.trim() || 'nixos-unstable'
      };

      onCreateDetour(name, 'pr', entry);
      resetForm();
      onClose();
      return;
    }

    // Hold or Fix
    if (!reason.trim()) {
      errorMsg = 'Reason is required';
      return;
    }

    let sourceVal: any = fromSource;
    if (fromSource === 'custom') {
      if (!customRev.trim()) {
        errorMsg = 'Commit hash is required when custom source is selected';
        return;
      }
      sourceVal = { rev: customRev.trim(), narHash: '' };
    }

    if (activeTab === 'fix' && patches.length === 0 && !overrideFile.trim()) {
      errorMsg = 'Fix requires at least one patch URL/file or an override expression file';
      return;
    }

    const entry: HoldEntry = {
      from: sourceVal,
      since: new Date().toISOString().slice(0, 10),
      reason: reason.trim(),
      link: link.trim() || undefined,
      releaseWhen: releaseWhen.trim() || undefined,
      untilVersion: untilVersion.trim() || undefined,
      patches: patches.length > 0 ? patches : undefined,
      override: overrideFile.trim() || undefined
    };

    onCreateDetour(name, activeTab, entry);
    resetForm();
    onClose();
  }
</script>

{#if isOpen}
  <div
    class="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/80 backdrop-blur-sm"
    role="presentation"
    onclick={onClose}
    onkeydown={(e) => {
      if (e.key === 'Escape') onClose();
    }}
  >
    <div
      class="bg-stone-900 border border-stone-800 rounded-2xl w-full max-w-xl shadow-2xl flex flex-col max-h-[90vh] overflow-hidden"
      role="dialog"
      aria-modal="true"
      aria-labelledby="new-detour-title"
      tabindex="-1"
      onclick={(e) => e.stopPropagation()}
      onkeydown={(e) => {
        if (e.key === 'Escape') onClose();
        e.stopPropagation();
      }}
    >
      <!-- Header -->
      <div class="px-6 py-4 border-b border-stone-800 flex items-center justify-between">
        <div class="flex items-center gap-2">
          <span class="text-amber-400 text-lg">➕</span>
          <h2 id="new-detour-title" class="text-lg font-bold text-stone-100 font-mono">Create Detour</h2>
        </div>
        <button
          type="button"
          onclick={onClose}
          aria-label="Close dialog"
          class="text-stone-400 hover:text-stone-200 p-1.5 rounded-lg hover:bg-stone-800 transition cursor-pointer"
        >
          <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
          </svg>
        </button>
      </div>

      <!-- Type Tabs -->
      <div class="flex border-b border-stone-800 bg-stone-950/40 px-6 pt-3 gap-2">
        <button
          type="button"
          onclick={() => handleTabChange('fix')}
          class="px-4 py-2 rounded-t-xl text-xs font-mono font-medium transition cursor-pointer border-b-2 {activeTab === 'fix' ? 'border-amber-400 text-amber-300 bg-stone-900' : 'border-transparent text-stone-400 hover:text-stone-200'}"
        >
          🔧 Fix (Patch / Override)
        </button>
        <button
          type="button"
          onclick={() => handleTabChange('pr')}
          class="px-4 py-2 rounded-t-xl text-xs font-mono font-medium transition cursor-pointer border-b-2 {activeTab === 'pr' ? 'border-amber-400 text-amber-300 bg-stone-900' : 'border-transparent text-stone-400 hover:text-stone-200'}"
        >
          🔀 Nixpkgs PR Overlay
        </button>
        <button
          type="button"
          onclick={() => handleTabChange('hold')}
          class="px-4 py-2 rounded-t-xl text-xs font-mono font-medium transition cursor-pointer border-b-2 {activeTab === 'hold' ? 'border-amber-400 text-amber-300 bg-stone-900' : 'border-transparent text-stone-400 hover:text-stone-200'}"
        >
          📌 Legacy Hold
        </button>
      </div>

      <!-- Form Body -->
      <div class="p-6 overflow-y-auto space-y-4 text-xs font-mono">
        {#if errorMsg}
          <div class="p-3 bg-red-950/60 border border-red-800/80 rounded-xl text-red-200 flex items-center gap-2">
            <span>⚠️</span>
            <span>{errorMsg}</span>
          </div>
        {/if}

        <!-- Package Name -->
        <div>
          <label for="pkg-name" class="block text-stone-300 font-semibold mb-1">Package Name *</label>
          <input
            id="pkg-name"
            type="text"
            bind:value={packageName}
            placeholder="e.g. fastfetch, ripgrep, cosmic-term"
            class="w-full bg-stone-950 border border-stone-800 rounded-xl px-3 py-2 text-stone-200 focus:outline-none focus:border-amber-500/80"
          />
        </div>

        {#if activeTab === 'pr'}
          <!-- PR Number & Repo -->
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
            <div>
              <label for="pr-num" class="block text-stone-300 font-semibold mb-1">PR Number *</label>
              <input
                id="pr-num"
                type="number"
                bind:value={prNumber}
                placeholder="e.g. 345678"
                class="w-full bg-stone-950 border border-stone-800 rounded-xl px-3 py-2 text-stone-200 focus:outline-none focus:border-amber-500/80"
              />
            </div>
            <div>
              <label for="pr-repo" class="block text-stone-300 font-semibold mb-1">Repository</label>
              <input
                id="pr-repo"
                type="text"
                bind:value={prRepo}
                placeholder="NixOS/nixpkgs or fork/repo"
                class="w-full bg-stone-950 border border-stone-800 rounded-xl px-3 py-2 text-stone-200 focus:outline-none focus:border-amber-500/80"
              />
            </div>
          </div>

          <!-- Target Channel -->
          <div>
            <label for="pr-chan" class="block text-stone-300 font-semibold mb-1">Target Channel</label>
            <input
              id="pr-chan"
              type="text"
              bind:value={prChannel}
              placeholder="nixos-unstable"
              class="w-full bg-stone-950 border border-stone-800 rounded-xl px-3 py-2 text-stone-200 focus:outline-none focus:border-amber-500/80"
            />
            <p class="text-[11px] text-stone-500 mt-1">Channel to monitor until PR lands and detour is retired.</p>
          </div>

          <!-- Exported Attrs -->
          <div>
            <label for="pr-attrs" class="block text-stone-300 font-semibold mb-1">Attributes (comma-separated)</label>
            <input
              id="pr-attrs"
              type="text"
              bind:value={prAttrs}
              placeholder="defaults to package name"
              class="w-full bg-stone-950 border border-stone-800 rounded-xl px-3 py-2 text-stone-200 focus:outline-none focus:border-amber-500/80"
            />
          </div>
        {:else}
          <!-- Reason -->
          <div>
            <label for="fix-reason" class="block text-stone-300 font-semibold mb-1">Reason *</label>
            <input
              id="fix-reason"
              type="text"
              bind:value={reason}
              placeholder="e.g. Fix Wayland multi-monitor crash"
              class="w-full bg-stone-950 border border-stone-800 rounded-xl px-3 py-2 text-stone-200 focus:outline-none focus:border-amber-500/80"
            />
          </div>

          <!-- Link -->
          <div>
            <label for="fix-link" class="block text-stone-300 font-semibold mb-1">Upstream PR / Issue Link</label>
            <input
              id="fix-link"
              type="url"
              bind:value={link}
              placeholder="https://github.com/..."
              class="w-full bg-stone-950 border border-stone-800 rounded-xl px-3 py-2 text-stone-200 focus:outline-none focus:border-amber-500/80"
            />
          </div>

          <!-- Expiration Condition (untilVersion) -->
          <div class="p-3 bg-amber-500/5 border border-amber-500/20 rounded-xl space-y-2">
            <div class="flex items-center justify-between">
              <label for="fix-until" class="text-amber-300 font-semibold flex items-center gap-1.5">
                <span>🎯</span>
                <span>Until Version (Retirement Condition)</span>
              </label>
              <span class="text-[10px] text-amber-400/80 uppercase">Auto-expiry</span>
            </div>
            <input
              id="fix-until"
              type="text"
              bind:value={untilVersion}
              placeholder="e.g. 2.31.0 or >= 2.31.0"
              class="w-full bg-stone-950 border border-stone-800 rounded-lg px-3 py-1.5 text-stone-200 focus:outline-none focus:border-amber-500/80"
            />
            <p class="text-[11px] text-stone-400">
              When upstream nixpkgs reaches this version, detour will automatically flag as ready to release.
            </p>
          </div>

          {#if activeTab === 'fix'}
            <!-- Patches -->
            <div class="space-y-2">
              <label for="patch-input" class="block text-stone-300 font-semibold">Patches (URL or file) *</label>
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
                  class="flex-1 bg-stone-950 border border-stone-800 rounded-xl px-3 py-2 text-stone-200 focus:outline-none focus:border-amber-500/80"
                />
                <button
                  type="button"
                  onclick={addPatch}
                  class="px-3 py-2 bg-stone-800 hover:bg-stone-700 text-stone-200 rounded-xl transition cursor-pointer"
                >
                  Add Patch
                </button>
              </div>

              {#if patches.length > 0}
                <div class="space-y-1.5 mt-2">
                  {#each patches as p, idx}
                    <div class="flex items-center justify-between bg-stone-950/80 border border-stone-800 rounded-lg px-2.5 py-1.5 text-[11px]">
                      <span class="truncate text-amber-200">{p}</span>
                      <button
                        type="button"
                        onclick={() => removePatch(idx)}
                        class="text-red-400 hover:text-red-300 ml-2 cursor-pointer"
                      >
                        ✕
                      </button>
                    </div>
                  {/each}
                </div>
              {/if}
            </div>

            <!-- Override -->
            <div>
              <label for="fix-override" class="block text-stone-300 font-semibold mb-1">Override File (optional)</label>
              <input
                id="fix-override"
                type="text"
                bind:value={overrideFile}
                placeholder="e.g. override.nix"
                class="w-full bg-stone-950 border border-stone-800 rounded-xl px-3 py-2 text-stone-200 focus:outline-none focus:border-amber-500/80"
              />
            </div>
          {/if}

          <!-- From Source -->
          <div>
            <label for="fix-from" class="block text-stone-300 font-semibold mb-1">Base Nixpkgs Source</label>
            <select
              id="fix-from"
              bind:value={fromSource}
              class="w-full bg-stone-950 border border-stone-800 rounded-xl px-3 py-2 text-stone-200 focus:outline-none focus:border-amber-500/80 cursor-pointer"
            >
              <option value="current">Current Nixpkgs</option>
              <option value="stable">Nixpkgs Stable</option>
              <option value="custom">Specific Commit Revision</option>
            </select>
          </div>

          {#if fromSource === 'custom'}
            <div>
              <label for="fix-rev" class="block text-stone-300 font-semibold mb-1">Commit SHA</label>
              <input
                id="fix-rev"
                type="text"
                bind:value={customRev}
                placeholder="Full 40-char git commit SHA"
                class="w-full bg-stone-950 border border-stone-800 rounded-xl px-3 py-2 text-stone-200 focus:outline-none focus:border-amber-500/80"
              />
            </div>
          {/if}
        {/if}
      </div>

      <!-- Footer -->
      <div class="px-6 py-4 border-t border-stone-800 bg-stone-950/60 flex items-center justify-end gap-3">
        <button
          type="button"
          onclick={onClose}
          class="px-4 py-2 rounded-xl text-stone-400 hover:text-stone-200 hover:bg-stone-800 transition cursor-pointer font-mono text-xs"
        >
          Cancel
        </button>
        <button
          type="button"
          onclick={handleSubmit}
          class="px-4 py-2 bg-amber-500 hover:bg-amber-400 text-stone-950 font-bold rounded-xl shadow-lg shadow-amber-500/10 transition cursor-pointer font-mono text-xs flex items-center gap-1.5"
        >
          <span>✓</span>
          <span>Create Detour</span>
        </button>
      </div>
    </div>
  </div>
{/if}
