import type { HoldEntry, PrEntry, DetourItem, DetourKind } from './types';

export function calculateAgeDays(sinceStr?: string): number {
  if (!sinceStr) return 0;
  const sinceDate = new Date(sinceStr);
  if (isNaN(sinceDate.getTime())) return 0;
  const diffTime = Date.now() - sinceDate.getTime();
  if (diffTime < 0) return 0;
  return Math.floor(diffTime / (1000 * 60 * 60 * 24));
}

export function shQuote(val: string): string {
  return "'" + val.replace(/'/g, "'\\''") + "'";
}

// Opens a native <dialog> as a modal and closes it on backdrop clicks.
export function modalDialog(el: HTMLDialogElement): () => void {
  if (!el.open) el.showModal();
  const onPointerDown = (e: PointerEvent) => {
    if (e.target === el) el.close();
  };
  el.addEventListener('pointerdown', onPointerDown);
  return () => el.removeEventListener('pointerdown', onPointerDown);
}

// Matches server.py's PR_CACHE key format ("<upstream>:<pr>:<channel>").
export function prStatusKey(
  pr: number,
  upstream = 'NixOS/nixpkgs',
  channel = 'nixos-unstable'
): string {
  let chan = channel || 'nixos-unstable';
  const match = chan.match(/^github:[^/]+\/[^/]+\/(.+)$/);
  if (match) chan = match[1];
  return `${upstream || 'NixOS/nixpkgs'}:${pr}:${chan}`;
}

export function parseHolds(holds: Record<string, HoldEntry> | null | undefined): DetourItem[] {
  if (!holds || typeof holds !== 'object') return [];
  return Object.entries(holds)
    .filter(([_, entry]) => entry && typeof entry === 'object')
    .map(([name, entry]) => {
      const isFix = Boolean((entry.patches && entry.patches.length > 0) || entry.override);
      const kind: DetourKind = isFix ? 'fix' : 'hold';

      let sourceLabel = 'previous lock';
      let fullSource = 'previous lock';
      if (entry.from === 'stable') {
        sourceLabel = 'nixpkgs-stable';
        fullSource = 'nixpkgs-stable';
      } else if (entry.from === 'current') {
        sourceLabel = 'current nixpkgs';
        fullSource = 'current nixpkgs';
      } else if (typeof entry.from === 'object' && entry.from?.rev) {
        sourceLabel = entry.from.rev.slice(0, 8);
        fullSource = `commit ${entry.from.rev}`;
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
      const upstream = entry.upstream || 'NixOS/nixpkgs';
      const targetLabel = upstream === 'NixOS/nixpkgs' ? 'Nixpkgs' : upstream;
      const fromRepo = entry.owner && entry.repo ? ` from ${entry.owner}/${entry.repo}` : '';
      return {
        id: `pr-${name}`,
        name,
        kind: 'pr' as DetourKind,
        sourceLabel: `PR #${entry.pr}`,
        fullSource: `${entry.owner}/${entry.repo} (${entry.rev ? entry.rev.slice(0, 8) : 'unpinned'})`,
        ageDays: 0,
        since: '',
        reason: `${targetLabel} PR #${entry.pr}${fromRepo}`,
        link: `https://github.com/${upstream}/pull/${entry.pr}`,
        prNumber: entry.pr,
        owner: entry.owner,
        repo: entry.repo,
        upstream: entry.upstream,
        rev: entry.rev,
        narHash: entry.narHash,
        attrs: entry.attrs,
        pythonPackages: entry.pythonPackages,
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
    let cmd = `nix-detour pr add ${shQuote(item.name)} --pr ${shQuote(String(item.prNumber))} --repo ${shQuote(`${item.owner}/${item.repo}`)}`;
    if (item.upstream && item.upstream !== 'NixOS/nixpkgs') {
      cmd += ` --upstream ${shQuote(item.upstream)}`;
    }
    if (item.attrs?.length) {
      cmd += ` --attrs ${shQuote(item.attrs.join(','))}`;
    } else if (!item.pythonPackages?.length) {
      cmd += ` --attrs ${shQuote(item.name)}`;
    }
    if (item.pythonPackages?.length) {
      for (const py of item.pythonPackages) {
        cmd += ` --python ${shQuote(py)}`;
      }
    }
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

  const rawHold = (item.raw || {}) as HoldEntry;
  let cmd = `nix-detour ${item.kind} add ${shQuote(item.name)}`;
  if (rawHold.from === 'stable') {
    cmd += ` --from stable`;
  } else if (rawHold.from === 'current' && item.kind === 'hold') {
    cmd += ` --from current`;
  } else if (rawHold.from === 'previous') {
    cmd += ` --from previous`;
  } else if (typeof rawHold.from === 'object' && rawHold.from?.rev) {
    cmd += ` --from ${shQuote(rawHold.from.rev)}`;
  }
  if (item.patches?.length) {
    for (const p of item.patches) {
      cmd += ` --patch ${shQuote(typeof p === 'string' ? p : p.url)}`;
    }
  }
  if (item.kind === 'fix' && item.override) {
    cmd += ` --override ${shQuote(item.override)}`;
  }
  if (rawHold.reason) cmd += ` --reason ${shQuote(rawHold.reason)}`;
  if (item.link) cmd += ` --link ${shQuote(item.link)}`;
  if (item.releaseWhen) cmd += ` --release-when ${shQuote(item.releaseWhen)}`;
  if (item.untilVersion) cmd += ` --until-version ${shQuote(item.untilVersion)}`;
  if (item.tests?.length) cmd += ` --tests ${shQuote(item.tests.join(','))}`;
  return cmd;
}

const isString = (v: unknown): v is string => typeof v === 'string';
const isStringList = (v: unknown): v is string[] => Array.isArray(v) && v.every(isString);
const isStringMap = (v: unknown): v is Record<string, string> =>
  !!v && typeof v === 'object' && !Array.isArray(v) && Object.values(v).every(isString);
const isPatch = (v: unknown): boolean =>
  isString(v) ||
  (!!v &&
    typeof v === 'object' &&
    !Array.isArray(v) &&
    isString((v as Record<string, unknown>).url) &&
    isString((v as Record<string, unknown>).hash));

// Returns the first schema error for imported JSON, or null when valid.
export function validateEntries(records: unknown, kind: 'hold' | 'pr'): string | null {
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
      if (!optional('pythonPackages', isStringList)) return bad('pythonPackages');
      if (!optional('paths', isStringMap)) return bad('paths');
      if (!optional('modules', isStringMap)) return bad('modules');
      if (!optional('upstream', isString)) return bad('upstream');
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
