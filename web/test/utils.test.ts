import {
  calculateAgeDays,
  shQuote,
  prStatusKey,
  parseHolds,
  parsePrs,
  generateCliCommand,
  validateEntries
} from '../src/utils.ts';

function assertEqual<T>(actual: T, expected: T, message?: string): void {
  const a = JSON.stringify(actual);
  const b = JSON.stringify(expected);
  if (a !== b) {
    throw new Error(`${message ? message + ': ' : ''}expected ${b}, got ${a}`);
  }
}

function assertIncludes(haystack: string, needle: string, message?: string): void {
  if (!haystack.includes(needle)) {
    throw new Error(`${message ? message + ': ' : ''}expected ${JSON.stringify(haystack)} to include ${JSON.stringify(needle)}`);
  }
}

let passed = 0;
function test(name: string, fn: () => void): void {
  fn();
  passed += 1;
}

test('calculateAgeDays handles empty, invalid, future, and past dates', () => {
  assertEqual(calculateAgeDays(undefined), 0);
  assertEqual(calculateAgeDays(''), 0);
  assertEqual(calculateAgeDays('not-a-date'), 0);
  const tomorrow = new Date(Date.now() + 86_400_000 * 2).toISOString().slice(0, 10);
  assertEqual(calculateAgeDays(tomorrow), 0);
  const tenDaysAgo = new Date(Date.now() - 86_400_000 * 10 - 3_600_000).toISOString().slice(0, 10);
  const days = calculateAgeDays(tenDaysAgo);
  if (days < 9 || days > 11) {
    throw new Error(`expected ~10 days, got ${days}`);
  }
});

test('shQuote escapes single quotes and preserves arbitrary shell metacharacters', () => {
  assertEqual(shQuote('simple'), "'simple'");
  assertEqual(shQuote("can't stop"), "'can'\\''t stop'");
  assertEqual(shQuote('$(rm -rf /) `id` "$HOME"'), "'$(rm -rf /) `id` \"$HOME\"'");
});

test('prStatusKey normalizes defaults and github: flake channel refs', () => {
  assertEqual(prStatusKey(42), 'NixOS/nixpkgs:42:nixos-unstable');
  assertEqual(
    prStatusKey(99, 'custom/nixpkgs', 'github:custom/nixpkgs/release/25.05'),
    'custom/nixpkgs:99:release/25.05'
  );
});

test('parseHolds classifies holds vs fixes and handles null/malformed records', () => {
  assertEqual(parseHolds(null), []);
  assertEqual(parseHolds(undefined), []);

  const items = parseHolds({
    'llama-cpp': {
      from: { rev: '1234567890abcdef', narHash: 'sha256-AAA=' },
      since: '2026-01-01',
      reason: 'CUDA regression',
      releaseWhen: 'llama-cpp',
      untilVersion: '4500',
      tests: ['llama']
    },
    waybar: {
      from: 'current',
      patches: [{ url: 'https://example.org/fix.patch', hash: 'sha256-BBB=' }],
      reason: 'Tray fix'
    },
    overrideOnly: {
      from: 'stable',
      override: 'fixes/override.nix'
    }
  });

  assertEqual(items.length, 3);
  assertEqual(items[0].kind, 'hold');
  assertEqual(items[0].sourceLabel, '12345678');
  assertEqual(items[0].untilVersion, '4500');
  assertEqual(items[1].kind, 'fix');
  assertEqual(items[1].sourceLabel, 'current nixpkgs');
  assertEqual(items[2].kind, 'fix');
  assertEqual(items[2].sourceLabel, 'nixpkgs-stable');
});

test('parsePrs maps PR fields, custom upstream, pythonPackages, and unpinned revs', () => {
  assertEqual(parsePrs(null), []);
  const items = parsePrs({
    mesh: {
      pr: 571722,
      owner: 'forkuser',
      repo: 'nixpkgs',
      rev: '',
      narHash: '',
      attrs: [],
      pythonPackages: ['mesh-py'],
      scope: ['helper'],
      paths: { 'python3Packages.mesh-py': 'pkgs/development/python-modules/mesh-py/default.nix' },
      modules: { 'mesh-llm': 'nixos/modules/services/misc/mesh-llm.nix' },
      upstream: 'custom/nixpkgs',
      untilChannel: 'nixos-25.05'
    }
  });

  assertEqual(items.length, 1);
  assertEqual(items[0].kind, 'pr');
  assertEqual(items[0].fullSource, 'forkuser/nixpkgs (unpinned)');
  assertEqual(items[0].link, 'https://github.com/custom/nixpkgs/pull/571722');
  assertEqual(items[0].upstream, 'custom/nixpkgs');
  assertEqual(items[0].pythonPackages, ['mesh-py']);
  assertEqual(items[0].untilChannel, 'nixos-25.05');
});

test('generateCliCommand emits idiomatic nix-detour commands across hold, fix, and pr items', () => {
  const [holdItem] = parseHolds({
    foo: {
      from: 'stable',
      reason: "broken 'build'",
      untilVersion: '2.0.0',
      tests: ['t1', 't2']
    }
  });
  const holdCmd = generateCliCommand(holdItem);
  assertIncludes(holdCmd, "nix-detour hold add 'foo'");
  assertIncludes(holdCmd, '--from stable');
  assertIncludes(holdCmd, "--reason 'broken '\\''build'\\'''");
  assertIncludes(holdCmd, "--until-version '2.0.0'");
  assertIncludes(holdCmd, "--tests 't1,t2'");

  const [fixItem] = parseHolds({
    bar: {
      from: 'current',
      patches: ['local.patch'],
      override: 'bar.nix',
      reason: 'fix'
    }
  });
  const fixCmd = generateCliCommand(fixItem);
  assertIncludes(fixCmd, "nix-detour fix add 'bar'");
  assertIncludes(fixCmd, "--patch 'local.patch'");
  assertIncludes(fixCmd, "--override 'bar.nix'");

  const [prItem] = parsePrs({
    baz: {
      pr: 42,
      owner: 'alice',
      repo: 'nixpkgs',
      rev: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      narHash: 'sha256-AAA=',
      attrs: [],
      pythonPackages: ['py-baz'],
      upstream: 'org/nixpkgs',
      modules: { baz: 'nixos/modules/baz.nix' },
      untilChannel: 'nixos-unstable'
    }
  });
  const prCmd = generateCliCommand(prItem);
  assertIncludes(prCmd, "nix-detour pr add 'baz'");
  assertIncludes(prCmd, "--pr '42'");
  assertIncludes(prCmd, "--upstream 'org/nixpkgs'");
  assertIncludes(prCmd, "--python 'py-baz'");
  assertIncludes(prCmd, "--module 'baz=nixos/modules/baz.nix'");
});

test('validateEntries accepts valid schemas and rejects malformed hold and PR entries', () => {
  assertEqual(validateEntries({}, 'hold'), null);
  assertEqual(validateEntries({}, 'pr'), null);

  assertIncludes(validateEntries([], 'hold') ?? '', 'must be a JSON object');
  assertIncludes(validateEntries(null, 'pr') ?? '', 'must be a JSON object');
  assertIncludes(validateEntries({ bad: [] }, 'hold') ?? '', 'entry "bad" must be an object');

  assertEqual(
    validateEntries(
      {
        pkg: {
          from: { rev: 'abc', narHash: 'sha256-x' },
          reason: 'ok',
          patches: ['a.patch', { url: 'https://x/b.patch', hash: 'sha256-y' }],
          tests: ['vm']
        }
      },
      'hold'
    ),
    null
  );

  assertIncludes(
    validateEntries({ pkg: { from: 'invalid-source' } }, 'hold') ?? '',
    'invalid from'
  );
  assertIncludes(
    validateEntries({ pkg: { from: 'stable', patches: [{ url: 'missing-hash' }] } }, 'hold') ?? '',
    'invalid patches'
  );

  assertEqual(
    validateEntries(
      {
        prpkg: {
          pr: 10,
          owner: 'o',
          repo: 'r',
          rev: '',
          narHash: '',
          attrs: ['prpkg'],
          pythonPackages: ['py-foo'],
          upstream: 'NixOS/nixpkgs',
          untilChannel: 'nixos-unstable'
        }
      },
      'pr'
    ),
    null
  );

  assertIncludes(
    validateEntries({ prpkg: { pr: '10', owner: 'o', repo: 'r', rev: '', narHash: '', attrs: [] } }, 'pr') ?? '',
    'invalid pr'
  );
  assertIncludes(
    validateEntries({ prpkg: { pr: 10, owner: 'o', repo: 'r', rev: '', narHash: '', attrs: [123] } }, 'pr') ?? '',
    'invalid attrs'
  );
});

console.log(`web unit tests: ${passed} passed`);
