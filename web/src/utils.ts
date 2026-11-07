import type { HoldEntry, PrEntry, DetourItem, DetourKind } from './types';

export function calculateAgeDays(sinceStr?: string): number {
  if (!sinceStr) return 0;
  const sinceDate = new Date(sinceStr);
  if (isNaN(sinceDate.getTime())) return 0;
  const diffTime = Date.now() - sinceDate.getTime();
  if (diffTime < 0) return 0;
  return Math.floor(diffTime / (1000 * 60 * 60 * 24));
}

const FOCUSABLE =
  'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';

// Svelte action for modal dialogs: focus moves into the dialog, Tab stays in
// it, the rest of the page is inert, and on close all of that is undone.
export function dialogFocus(node: HTMLElement) {
  const previous = document.activeElement instanceof HTMLElement ? document.activeElement : null;
  const madeInert: HTMLElement[] = [];
  for (let el: HTMLElement | null = node; el && el !== document.body; el = el.parentElement) {
    for (const sibling of Array.from(el.parentElement?.children ?? [])) {
      if (sibling !== el && sibling instanceof HTMLElement && !sibling.inert) {
        sibling.inert = true;
        madeInert.push(sibling);
      }
    }
  }
  const onKeydown = (e: KeyboardEvent) => {
    if (e.key !== 'Tab') return;
    const items = Array.from(node.querySelectorAll<HTMLElement>(FOCUSABLE));
    if (items.length === 0) {
      e.preventDefault();
      return;
    }
    const first = items[0];
    const last = items[items.length - 1];
    const active = document.activeElement;
    if (e.shiftKey && (active === first || active === node)) {
      e.preventDefault();
      last.focus();
    } else if (!e.shiftKey && active === last) {
      e.preventDefault();
      first.focus();
    }
  };
  node.addEventListener('keydown', onKeydown);
  node.focus();
  return {
    destroy() {
      node.removeEventListener('keydown', onKeydown);
      for (const el of madeInert) el.inert = false;
      previous?.focus();
    }
  };
}

export function shQuote(val: string): string {
  // Quote safely for POSIX shell using single quotes
  return "'" + val.replace(/'/g, "'\\''") + "'";
}

export function parseHolds(holds: Record<string, HoldEntry> | null | undefined): DetourItem[] {
  if (!holds || typeof holds !== 'object') return [];
  return Object.entries(holds)
    .filter(([_, entry]) => entry && typeof entry === 'object')
    .map(([name, entry]) => {
      const isFix = Boolean(
        (entry.patches && entry.patches.length > 0) || entry.override
      );
    const kind: DetourKind = isFix ? 'fix' : 'hold';

    let sourceLabel = '';
    let fullSource = '';

    if (entry.from === 'stable') {
      sourceLabel = 'nixpkgs-stable';
      fullSource = 'nixpkgs-stable';
    } else if (entry.from === 'current') {
      sourceLabel = 'current nixpkgs';
      fullSource = 'current nixpkgs';
    } else if (typeof entry.from === 'object' && entry.from?.rev) {
      sourceLabel = `${entry.from.rev.slice(0, 8)}`;
      fullSource = `commit ${entry.from.rev}`;
    } else {
      sourceLabel = 'previous lock';
      fullSource = 'previous lock';
    }

    return {
      id: `hold-${name}`,
      name,
      kind,
      sourceLabel,
      fullSource,
      ageDays: calculateAgeDays(entry.since),
      since: entry.since || 'unknown',
      reason: entry.reason || 'No description provided',
      link: entry.link,
      releaseWhen: entry.releaseWhen,
      untilVersion: entry.untilVersion,
      tests: entry.tests,
      patches: entry.patches,
      override: entry.override,
      raw: entry
    };
  });
}

export function parsePrs(prs: Record<string, PrEntry> | null | undefined): DetourItem[] {
  if (!prs || typeof prs !== 'object') return [];
  return Object.entries(prs)
    .filter(([_, entry]) => entry && typeof entry === 'object')
    .map(([name, entry]) => {
    return {
      id: `pr-${name}`,
      name,
      kind: 'pr' as DetourKind,
      sourceLabel: `PR #${entry.pr}`,
      fullSource: `${entry.owner}/${entry.repo} (${entry.rev ? entry.rev.slice(0, 8) : 'unpinned'})`,
      ageDays: 0,
      since: '',
      reason: `Nixpkgs PR #${entry.pr} from ${entry.owner}/${entry.repo}`,
      link: `https://github.com/NixOS/nixpkgs/pull/${entry.pr}`,
      prNumber: entry.pr,
      owner: entry.owner,
      repo: entry.repo,
      rev: entry.rev,
      narHash: entry.narHash,
      attrs: entry.attrs,
      scope: entry.scope,
      paths: entry.paths,
      modules: entry.modules,
      untilChannel: entry.untilChannel,
      raw: entry
    };
  });
}

export function generateCliCommand(item: DetourItem): string {
  if (item.kind === 'pr') {
    let cmd = `nix run github:kleinbem-dev/nix-detour -- pr add ${shQuote(item.name)} --pr ${shQuote(String(item.prNumber))} --repo ${shQuote(`${item.owner}/${item.repo}`)} --attrs ${shQuote(item.attrs?.join(',') || item.name)}`;
    if (item.rev) cmd += ` --rev ${shQuote(item.rev)}`;
    if (item.scope?.length) cmd += ` --scope ${shQuote(item.scope.join(','))}`;
    if (item.paths) {
      for (const [attr, p] of Object.entries(item.paths)) {
        cmd += ` --path ${shQuote(`${attr}=${p}`)}`;
      }
    }
    if (item.modules) {
      for (const [mod, p] of Object.entries(item.modules)) {
        cmd += ` --module ${shQuote(`${mod}=${p}`)}`;
      }
    }
    if (item.untilChannel) cmd += ` --channel ${shQuote(item.untilChannel)}`;
    return cmd;
  }

  if (item.kind === 'fix') {
    let cmd = `nix run github:kleinbem-dev/nix-detour -- fix add ${shQuote(item.name)}`;
    const rawHold = (item.raw || {}) as HoldEntry;
    if (rawHold.from === 'stable') {
      cmd += ` --from stable`;
    } else if (typeof rawHold.from === 'object' && rawHold.from?.rev) {
      cmd += ` --from ${shQuote(rawHold.from.rev)}`;
    }
    if (item.patches?.length) {
      for (const p of item.patches) {
        const patchUrl = typeof p === 'string' ? p : p.url;
        cmd += ` --patch ${shQuote(patchUrl)}`;
      }
    }
    if (item.override) cmd += ` --override ${shQuote(item.override)}`;
    if (item.reason) cmd += ` --reason ${shQuote(item.reason)}`;
    if (item.link) cmd += ` --link ${shQuote(item.link)}`;
    if (item.releaseWhen) cmd += ` --release-when ${shQuote(item.releaseWhen)}`;
    if (item.untilVersion) cmd += ` --until-version ${shQuote(item.untilVersion)}`;
    if (item.tests?.length) cmd += ` --tests ${shQuote(item.tests.join(','))}`;
    return cmd;
  }

  let cmd = `nix run github:kleinbem-dev/nix-detour -- hold add ${shQuote(item.name)}`;
  const rawHold = (item.raw || {}) as HoldEntry;
  if (rawHold.from === 'stable') {
    cmd += ` --from stable`;
  } else if (rawHold.from === 'current') {
    cmd += ` --from current`;
  } else if (typeof rawHold.from === 'object' && rawHold.from?.rev) {
    cmd += ` --from ${shQuote(rawHold.from.rev)}`;
  }
  if (item.patches?.length) {
    for (const p of item.patches) {
      const patchUrl = typeof p === 'string' ? p : p.url;
      cmd += ` --patch ${shQuote(patchUrl)}`;
    }
  }
  if (item.reason) cmd += ` --reason ${shQuote(item.reason)}`;
  if (item.link) cmd += ` --link ${shQuote(item.link)}`;
  if (item.releaseWhen) cmd += ` --release-when ${shQuote(item.releaseWhen)}`;
  if (item.untilVersion) cmd += ` --until-version ${shQuote(item.untilVersion)}`;
  if (item.tests?.length) cmd += ` --tests ${shQuote(item.tests.join(','))}`;
  return cmd;
}
