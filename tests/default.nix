# Tests of mkHolds and mkPrs, on a small list of holds from nixpkgs-stable
# and PRs from a local tree (no extra downloads). Evaluation only: a failing
# test fails `nix flake check`.
{
  pkgs,
  nixpkgs,
  nixpkgs-stable,
  mkHolds,
  mkPrs,
  watch,
  nix-detour,
}:
let
  inherit (pkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;
  stable = import nixpkgs-stable { inherit system; };

  # The consumer's own package, defined differently in its two nixpkgs.
  own = final: _: { own-package = final.writeText "own-package" final.lib.version; };

  holds = mkHolds {
    inherit nixpkgs-stable;
    extraOverlays = [ own ];
    holds = {
      hello.from = "stable";
      unrar.from = "stable";
      own-package.from = "stable";
      not-in-nixpkgs.from = "stable";
      figlet = {
        from = "stable";
        releaseWhen = "python3Packages.jq";
      };
    };
  };

  missingRelease = mkHolds {
    inherit nixpkgs-stable;
    holds = {
      hello = {
        from = "stable";
        releaseWhen = "nonExistent.subpackage";
      };
    };
  };

  versionMet = mkHolds {
    inherit nixpkgs-stable;
    holds = {
      hello = {
        from = "stable";
        untilVersion = "2.0.0";
      };
    };
  };

  versionUnmet = mkHolds {
    inherit nixpkgs-stable;
    holds = {
      hello = {
        from = "stable";
        untilVersion = "99.0.0";
      };
    };
  };

  consumer =
    config:
    import nixpkgs {
      inherit system config;
      overlays = [
        own
        holds.overlay
      ];
    };
  # Two PRs from a local tree: fake-a needs the unexported fake-b of its PR,
  # and an older hello than nixpkgs' with a NixOS module.
  prs = mkPrs {
    fetch = _: ./fake-pr;
    prs = {
      fake = {
        pr = 1;
        attrs = [ "fake-a" ];
        scope = [ "fake-b" ];
      };
      old-hello = {
        pr = 2;
        attrs = [ "hello" ];
        modules = {
          fake = "nixos/fake.nix";
          fake-attrs = "nixos/fake-attrs.nix";
        };
      };
      custom = {
        pr = 3;
        attrs = [ "custom-pkg" ];
        paths.custom-pkg = "pkgs/development/custom-pkg/default.nix";
      };
      # A scope and a Python package that needs a package of its PR.
      platform = {
        pr = 4;
        attrs = [
          "fake-app"
          "fake-lib"
          "fake-plugins"
        ];
        paths.fake-plugins = "pkgs/development/fake-plugins/default.nix";
        pythonPackages = [
          "fake-py"
          "fake-py-user"
        ];
      };
    };
  };
  withPrs = import nixpkgs {
    inherit system;
    overlays = [ prs.overlay ];
  };
  prChecks = prs.checks pkgs;
  fakeModule = prs.nixosModules.fake { inherit lib; };

  # The update action's watch list: top-level packages only, the same
  # package as the attribute, and a broken one whose attribute is broken too.
  brokenPkgs = pkgs.extend (
    _: prev: {
      figlet = prev.figlet.overrideAttrs { meta.broken = true; };
    }
  );
  watched = watch.packages {
    pkgs = brokenPkgs;
    packages = [
      brokenPkgs.hello
      brokenPkgs.figlet
      (brokenPkgs.writeText "not-top-level" "x")
      (brokenPkgs.hello.overrideAttrs {
        pname = "hello";
        version = "0-other";
        __intentionallyOverridingVersion = true;
      })
      brokenPkgs.python3Packages.six
    ];
  };

  # Fixes: the current or a held package with a patch or an override, from a
  # holds file whose relative paths resolve next to it.
  fixes = mkHolds {
    inherit nixpkgs-stable;
    holds = ./fix/held.json;
  };
  fixedPkgs = import nixpkgs {
    inherit system;
    overlays = [ fixes.overlay ];
  };
  # The same as an attrset: relative paths have nothing to resolve against.
  relativeWithoutFile = import nixpkgs {
    inherit system;
    overlays = [
      (mkHolds {
        inherit nixpkgs-stable;
        holds.hello = {
          from = "current";
          patches = [ "hello.patch" ];
        };
      }).overlay
    ];
  };

  held = consumer { };
  heldUnfree = consumer { allowUnfree = true; };

  failed = lib.runTests {
    testHeldFromStable = {
      expr = held.hello.outPath;
      expected = stable.hello.outPath;
    };
    testOwnPackageHeld = {
      expr = held.own-package.outPath;
      expected = (own stable stable).own-package.outPath;
    };
    testMissingLeftOut = {
      expr = held ? not-in-nixpkgs;
      expected = false;
    };
    # The consumer's config reaches the held package set: no unfree package
    # unless the consumer allows it.
    testUnfreeRefused = {
      expr = (builtins.tryEval held.unrar.drvPath).success;
      expected = false;
    };
    testUnfreeAllowed = {
      expr = (builtins.tryEval heldUnfree.unrar.drvPath).success;
      expected = true;
    };
    testReleaseWhen = {
      expr = (holds.releaseChecks pkgs).figlet.outPath;
      expected = pkgs.python3Packages.jq.outPath;
    };
    # The release tools read each hold from its check.
    testReleaseCheckCarriesEntry = {
      expr = (holds.releaseChecks pkgs).figlet.nixHolds;
      expected = {
        from = "stable";
        releaseWhen = "python3Packages.jq";
      };
    };
    testReleaseChecksSkipMissing = {
      expr = builtins.attrNames (holds.releaseChecks pkgs);
      expected = [
        "figlet"
        "hello"
        "unrar"
      ];
    };
    testReleaseChecksMissingReleaseWhen = {
      expr = (missingRelease.releaseChecks pkgs).hello.nixHolds.releaseWhen;
      expected = "nonExistent.subpackage";
    };
    testUntilVersionMet = {
      expr = (versionMet.releaseChecks pkgs).hello.outPath;
      expected = pkgs.hello.outPath;
    };
    testUntilVersionUnmet = {
      expr = (versionUnmet.releaseChecks pkgs).hello ? outPath;
      expected = false;
    };

    testPrPackageInOverlay = {
      expr = withPrs.fake-a.text;
      expected = "${withPrs.writeText "fake-b" "b"}";
    };
    testPrScopeNotExported = {
      expr = withPrs ? fake-b;
      expected = false;
    };
    testPrReplacesNixpkgs = {
      expr = withPrs.hello.version;
      expected = "0.1";
    };
    testPrCustomPathInOverlay = {
      expr = withPrs.custom-pkg.version;
      expected = "2.0";
    };
    testPrMerged = {
      expr = lib.mapAttrs (_: c: c.merged) prChecks;
      expected = {
        custom = false;
        fake = false;
        old-hello = true;
        platform = false;
      };
    };
    testPrScopeInOverlay = {
      expr = withPrs.fake-plugins.one.version;
      expected = "1.0";
    };
    testPrPythonInEveryPythonSet = {
      expr = map (python: python.pkgs.fake-py.text) [
        withPrs.python3
        withPrs.python313
      ];
      expected = map (python: "${python.pythonVersion} ${withPrs.fake-lib}") [
        withPrs.python3
        withPrs.python313
      ];
    };
    # The tools evaluate each check package's drvPath, so a scope's packages
    # are listed one by one.
    testPrChecksListDerivations = {
      expr = builtins.attrNames prChecks.platform.packages;
      expected = [
        "fake-app"
        "fake-lib"
        "fake-plugins.one"
        "python3Packages.fake-py"
        "python3Packages.fake-py-user"
      ];
    };
    # A Python package of the PR that needs another one, in the overlay and
    # in the checks, as real derivations of a Python set.
    testPrPythonFindsItsSibling = {
      expr = map (p: (builtins.tryEval p.drvPath).success) [
        withPrs.python3Packages.fake-py-user
        prChecks.platform.packages."python3Packages.fake-py-user"
      ];
      expected = [
        true
        true
      ];
    };
    # A top-level package of the PR that needs one of its Python packages.
    testPrAppFindsItsPython = {
      expr = [
        withPrs.fake-app.text
        prChecks.platform.packages.fake-app.text
      ];
      expected = [
        "${withPrs.python3Packages.fake-py}"
        "${prChecks.platform.packages."python3Packages.fake-py"}"
      ];
    };
    # Without a version on either side, nixpkgs' package is no evidence that
    # the PR is in.
    testPrMergedNeedsVersions = {
      expr =
        (
          (mkPrs {
            fetch = _: ./fake-pr;
            prs.unversioned = {
              attrs = [ "fake-b" ];
            };
          }).checks
            (pkgs.extend (final: _: { fake-b = final.writeText "fake-b" "other"; }))
        ).unversioned.merged;
      expected = false;
    };
    testPrPythonSiblingResolved = {
      expr = prChecks.platform.packages."python3Packages.fake-py-user".text;
      expected = "${prChecks.platform.packages."python3Packages.fake-py"}";
    };
    testPrPythonCheckUsesItsPr = {
      expr = prChecks.platform.packages."python3Packages.fake-py".text;
      expected = "${pkgs.python3.pythonVersion} ${prChecks.platform.packages.fake-lib}";
    };
    testPrDuplicatePythonRefused = {
      expr =
        (builtins.tryEval
          (mkPrs {
            fetch = _: ./fake-pr;
            prs = {
              a = {
                attrs = [ ];
                pythonPackages = [ "fake-py" ];
              };
              b = {
                attrs = [ ];
                pythonPackages = [ "fake-py" ];
              };
            };
          }).overlay
        ).success;
      expected = false;
    };
    testPrCheckCarriesEntry = {
      expr = prChecks.fake.nixPrs.pr;
      expected = 1;
    };
    testPrModuleWithoutDoc = {
      expr = fakeModule.meta;
      expected = {
        maintainers = [ ];
      };
    };
    testPrAttrsetModuleWithoutDoc = {
      expr = prs.nixosModules.fake-attrs.meta;
      expected = {
        maintainers = [ ];
      };
    };
    testPrDuplicateModuleRefused = {
      expr =
        (builtins.tryEval
          (mkPrs {
            fetch = _: ./fake-pr;
            prs = {
              a = {
                attrs = [ ];
                modules.fake = "nixos/fake.nix";
              };
              b = {
                attrs = [ ];
                modules.fake = "nixos/fake-attrs.nix";
              };
            };
          }).nixosModules
        ).success;
      expected = false;
    };
    testWatchNames = {
      expr = builtins.attrNames watched;
      expected = [
        "figlet"
        "hello"
      ];
    };
    testWatchBrokenStaysBroken = {
      expr = (builtins.tryEval watched.figlet.drvPath).success;
      expected = false;
    };
    testWatchNixos = {
      expr = builtins.attrNames (
        watch.nixos {
          pkgs = brokenPkgs;
          config = {
            environment.systemPackages = [ brokenPkgs.hello ];
            home-manager.users.u.home.packages = [ brokenPkgs.figlet ];
          };
        }
      );
      expected = [
        "figlet"
        "hello"
      ];
    };
    testWatchNixosWithoutHomeManager = {
      expr = builtins.attrNames (
        watch.nixos {
          pkgs = brokenPkgs;
          config = {
            environment.systemPackages = [ brokenPkgs.hello ];
          };
        }
      );
      expected = [
        "hello"
      ];
    };
    testWatchTarget = {
      expr =
        let
          t = watch.target {
            pkgs = brokenPkgs;
            config.system.build.toplevel = brokenPkgs.hello;
          };
        in
        [
          t.pkgs.figlet.meta.broken
          (t.target.outPath == brokenPkgs.hello.outPath)
        ];
      expected = [
        true
        true
      ];
    };
    # fixedPkgs holds hello from current with a patch; held from stable.
    testUnreachedUnheldCopy = {
      expr = watch.unreached {
        pkgs = fixedPkgs;
        plain = pkgs;
        names = [ "hello" ];
        closure = [
          fixedPkgs.hello.drvPath
          pkgs.hello.drvPath
        ];
      };
      expected = {
        hello = [ pkgs.hello.drvPath ];
      };
    };
    testUnreachedOnlyHeld = {
      expr = watch.unreached {
        pkgs = fixedPkgs;
        plain = pkgs;
        names = [ "hello" ];
        closure = [
          fixedPkgs.hello.drvPath
          pkgs.hello.src.drvPath
        ];
      };
      expected = { };
    };
    testUnreachedOtherVersion = {
      expr = watch.unreached {
        pkgs = held;
        plain = pkgs;
        names = [
          "hello"
          "not-in-pkgs"
        ];
        closure = [
          held.hello.drvPath
          pkgs.hello.drvPath
        ];
      };
      expected = {
        hello = [ pkgs.hello.drvPath ];
      };
    };
    # Can't tell an override of the held package from an unheld copy: listed,
    # and the report says it may be either.
    testUnreachedOverrideOfHeld = {
      expr = watch.unreached {
        pkgs = fixedPkgs;
        plain = pkgs;
        names = [ "hello" ];
        closure = [ (fixedPkgs.hello.overrideAttrs { DETOUR_TEST = "1"; }).drvPath ];
      };
      expected = {
        hello = [ (fixedPkgs.hello.overrideAttrs { DETOUR_TEST = "1"; }).drvPath ];
      };
    };
    testFixCurrentKeepsVersion = {
      expr = fixedPkgs.hello.version;
      expected = pkgs.hello.version;
    };
    testFixAddsPatch = {
      expr = map baseNameOf (fixedPkgs.hello.patches or [ ]);
      expected = map baseNameOf (pkgs.hello.patches or [ ]) ++ [ "hello.patch" ];
    };
    testFixOverrideOnHeld = {
      expr = [
        fixedPkgs.figlet.version
        (fixedPkgs.figlet ? fixedWith)
      ];
      expected = [
        stable.figlet.version
        true
      ];
    };
    testFixRelativeNeedsFile = {
      expr = (builtins.tryEval (builtins.deepSeq relativeWithoutFile.hello.patches null)).success;
      expected = false;
    };
    testFixReleaseCheckUnfixed = {
      expr = (fixes.releaseChecks pkgs).hello.outPath;
      expected = pkgs.hello.outPath;
    };
    testPrModuleArgs = {
      expr = lib.functionArgs prs.nixosModules.fake;
      expected = {
        lib = false;
      };
    };
    testNixosTestsDefaultAndCustom = {
      expr =
        let
          h = mkHolds {
            inherit nixpkgs-stable;
            holds = {
              hello.from = "stable";
              figlet = {
                from = "stable";
                tests = [
                  "custom1"
                  "custom2"
                ];
              };
              unrar = {
                from = "stable";
                tests = [ ];
              };
              jq = {
                from = "stable";
                tests = [ "custom1" ];
              };
            };
          };
          mockPkgs = pkgs // {
            nixosTests = {
              hello = "t-hello";
              figlet = "t-figlet";
              unrar = "t-unrar";
              custom1 = "t-c1";
              custom2 = "t-c2";
            };
          };
        in
        h.nixosTests mockPkgs;
      expected = {
        hello = "t-hello";
        custom1 = "t-c1";
        custom2 = "t-c2";
      };
    };
    testExplicitConfigOverridesConsumer = {
      expr =
        let
          explicitHolds = mkHolds {
            inherit nixpkgs-stable;
            config = {
              allowUnfree = true;
            };
            holds.unrar.from = "stable";
          };
          p = import nixpkgs {
            inherit system;
            config = { };
            overlays = [ explicitHolds.overlay ];
          };
        in
        (builtins.tryEval p.unrar.drvPath).success;
      expected = true;
    };
    testPrDuplicateAttrRefused = {
      expr =
        (builtins.tryEval
          (mkPrs {
            fetch = _: ./fake-pr;
            prs = {
              a.attrs = [ "hello" ];
              b.attrs = [ "hello" ];
            };
          }).overlay
        ).success;
      expected = false;
    };
    testWatchPackagesEmpty = {
      expr = watch.packages {
        pkgs = brokenPkgs;
        packages = [ ];
      };
      expected = { };
    };
    testWatchUnreachedEmptyClosure = {
      expr = watch.unreached {
        pkgs = fixedPkgs;
        plain = pkgs;
        names = [ "hello" ];
        closure = [ ];
      };
      expected = { };
    };
  };
in
{
  # The CLI on a git repo whose flake.lock moved nixpkgs from rev a to b.
  cli =
    pkgs.runCommand "nix-detour-cli-tests"
      {
        nativeBuildInputs = [
          nix-detour
          pkgs.git
          pkgs.jq
        ];
      }
      ''
        set -euo pipefail
        lock() {
          jq -n --arg rev "$1" '{nodes: {root: {inputs: {nixpkgs: "nixpkgs"}},
            nixpkgs: {locked: {type: "github", owner: "NixOS", repo: "nixpkgs", rev: $rev, narHash: ("sha256-" + $rev)}}}}' > flake.lock
        }
        export HOME=$TMPDIR GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
        git init -q .
        lock a; git add flake.lock; git commit -qm a
        lock b

        # Uncommitted update: the committed lock is the previous one.
        nix-detour hold add foo --reason "broken in b" --link https://example.org/1
        test "$(jq -c .foo.from held-packages.json)" = '{"rev":"a","narHash":"sha256-a"}'
        test "$(jq -r .foo.link held-packages.json)" = https://example.org/1

        # Committed update: found in the history.
        git add flake.lock; git commit -qm b
        nix-detour hold add bar --reason r --release-when python3Packages.bar --tests t1,t2
        test "$(jq -r .bar.from.rev held-packages.json)" = a
        test "$(jq -r .bar.releaseWhen held-packages.json)" = python3Packages.bar
        test "$(jq -c .bar.tests held-packages.json)" = '["t1","t2"]'

        nix-detour hold add baz --from stable --reason r --until-version 2.31.0
        test "$(jq -r .baz.from held-packages.json)" = stable
        test "$(jq -r .baz.untilVersion held-packages.json)" = 2.31.0
        test "$(jq -r 'keys | join(",")' held-packages.json)" = bar,baz,foo

        nix-detour hold list | grep -q '^foo  *a  '
        jq '.nodate = {from: "stable", reason: "r", releaseWhen: "python3Packages.x"}' held-packages.json > h && mv h held-packages.json
        nix-detour hold list | grep -q '^nodate  *stable  *no date  until python3Packages.x builds$'
        nix-detour hold remove nodate
        nix-detour hold remove foo
        test "$(jq -r 'keys | join(",")' held-packages.json)" = bar,baz
        if nix-detour hold remove foo 2>/dev/null; then echo "removing a missing hold should fail" >&2; exit 1; fi
        if nix-detour hold add qux 2>/dev/null; then echo "add without --reason should fail" >&2; exit 1; fi
        if nix-detour hold add qux --reason 2>/dev/null; then echo "an option without a value should fail" >&2; exit 1; fi

        # Fixes: a patch file next to the holds file, an override, the fix shorthand.
        echo patch > f.patch
        echo '{ pkgs, package }: package' > o.nix
        nix-detour hold add qux --from current --patch f.patch --reason r > out.txt
        grep -q '^fixing qux on current$' out.txt
        test "$(jq -c .qux.patches held-packages.json)" = '["f.patch"]'
        nix-detour fix add quux --override o.nix --reason r
        test "$(jq -c '[.quux.from, .quux.override]' held-packages.json)" = '["current","o.nix"]'
        nix-detour hold list > list.txt
        grep -q '^quux  *current+fix ' list.txt
        nix-detour fix list > fixlist.txt
        grep -q '^quux  *current+fix ' fixlist.txt
        if grep -q '^bar ' fixlist.txt; then echo "bar is not a fix; should not be in fix list" >&2; exit 1; fi
        if nix-detour fix add nofix --reason r 2>/dev/null; then echo "fix add without a fix should fail" >&2; exit 1; fi
        if nix-detour fix add missing --patch nope.patch --reason r 2>/dev/null; then echo "a missing patch file should fail" >&2; exit 1; fi
        nix-detour fix remove quux
        nix-detour hold remove qux

        # An invalid holds file stays as it is.
        echo '{ broken' > bad.json
        if nix-detour hold add qux --reason r --from stable --file bad.json 2>/dev/null; then echo "add to an invalid file should fail" >&2; exit 1; fi
        test "$(cat bad.json)" = '{ broken'
        if nix-detour hold remove bar --file bad.json 2>/dev/null; then echo "remove from an invalid file should fail" >&2; exit 1; fi
        test "$(cat bad.json)" = '{ broken'

        # Top-level list and release
        nix-detour list > list_all.txt
        grep -q '=== Holds & Fixes ===' list_all.txt
        grep -q '^bar ' list_all.txt
        nix-detour release bar
        test "$(jq -r 'keys | join(",")' held-packages.json)" = baz
        if nix-detour release missing 2>/dev/null; then echo "releasing a missing entry should fail" >&2; exit 1; fi

        # Positional path handling
        mkdir -p sub
        echo '{"subpkg": {"from": "stable", "since": "2026-11-01"}}' > sub/held-packages.json
        nix-detour list sub > sub_list.txt
        grep -q '^subpkg ' sub_list.txt
        ! grep -q '^baz ' sub_list.txt
        nix-detour list sub/held-packages.json > sub_file_list.txt
        grep -q '^subpkg ' sub_file_list.txt
        ! grep -q '^baz ' sub_file_list.txt
        if nix-detour list nonexistent 2>/dev/null; then echo "list with nonexistent path should fail" >&2; exit 1; fi
        if nix-detour list --file held-packages.json sub 2>/dev/null; then echo "list with both --file and positional path should fail" >&2; exit 1; fi
        cp held-packages.json before_release.json
        cp sub/held-packages.json sub_before_release.json
        if nix-detour release baz nonexistent 2>/dev/null; then echo "release with nonexistent path should fail" >&2; exit 1; fi
        if nix-detour release subpkg --file held-packages.json sub 2>/dev/null; then echo "release with both --file and positional path should fail" >&2; exit 1; fi
        cmp held-packages.json before_release.json
        cmp sub/held-packages.json sub_before_release.json

        # Help, unknown commands, custom --lock / --input, and non-git previous failure
        nix-detour --help | grep -q 'nix-detour'
        if nix-detour unknown-cmd 2>/dev/null; then echo "unknown command should fail" >&2; exit 1; fi
        if nix-detour hold add --bogus-flag 2>/dev/null; then echo "unknown flag should fail" >&2; exit 1; fi

        mkdir -p custom_lock_repo && (
          cd custom_lock_repo
          git init -q .
          jq -n '{
            root: "root",
            nodes: {
              root: { inputs: { mypkgs: "mypkgs", sub: "sub" } },
              sub: { inputs: { nixpkgs: ["mypkgs"] } },
              mypkgs: { locked: { rev: "rev1", narHash: "sha256-1" } }
            }
          }' > custom.lock
          git add custom.lock && git commit -qm c1
          jq '.nodes.mypkgs.locked = {rev: "rev2", narHash: "sha256-2"}' custom.lock > f && mv f custom.lock
          nix-detour hold add custompkg --lock custom.lock --input sub/nixpkgs --reason "follows input"
          test "$(jq -c .custompkg.from held-packages.json)" = '{"rev":"rev1","narHash":"sha256-1"}'
        )

        # --version, malformed since in list, corrupt JSON in top-level list, and flag-name rejection
        test "$(nix-detour --version)" = "nix-detour 0.3.1"
        if nix-detour hold add --reason r --from stable -- --evil 2>/dev/null; then echo "flag-like package name should fail" >&2; exit 1; fi
        mkdir -p bad_since && (
          cd bad_since
          echo '{"weird": {"from": "stable", "since": "not-a-date", "reason": "r"}}' > held-packages.json
          nix-detour hold list | grep -q '^weird  *stable  *not-a-date$'
          nix-detour list | grep -q '^weird  *stable  *not-a-date$'
          echo '{corrupt' > held-packages.json
          if nix-detour list 2>/dev/null; then echo "top-level list on corrupt JSON should fail" >&2; exit 1; fi
        )

        mkdir -p nogit && (
          cd nogit
          echo '{}' > flake.lock
          if nix-detour hold add p --reason r 2>/dev/null; then echo "previous outside git repo should fail" >&2; exit 1; fi
        )

        touch $out
      '';

  # The PR CLI, without the commands that fetch (pin) or evaluate a flake.
  pr-cli =
    pkgs.runCommand "nix-detour-pr-cli-tests"
      {
        nativeBuildInputs = [
          nix-detour
          pkgs.jq
        ];
      }
      ''
                set -euo pipefail
                nix-detour pr --help | grep -q 'nix-detour pr'
                if nix-detour pr bogus 2>/dev/null; then echo "unknown pr subcommand should fail" >&2; exit 1; fi

                nix-detour pr add mesh --pr 571722 --repo someone/nixpkgs --attrs mesh-llm,skippy \
                  --scope skippy-runtime --module mesh-llm=nixos/modules/services/misc/mesh-llm.nix
                test "$(jq -c .mesh nixpkgs-prs.json)" = '{"pr":571722,"owner":"someone","repo":"nixpkgs","rev":"","narHash":"","attrs":["mesh-llm","skippy"],"scope":["skippy-runtime"],"modules":{"mesh-llm":"nixos/modules/services/misc/mesh-llm.nix"}}'
                nix-detour pr add berd --pr 2 --repo someone/nixpkgs --attrs berd
                test "$(jq -r 'keys | join(",")' nixpkgs-prs.json)" = berd,mesh
                test "$(jq -c .berd nixpkgs-prs.json)" = '{"pr":2,"owner":"someone","repo":"nixpkgs","rev":"","narHash":"","attrs":["berd"]}'
                nix-detour pr list | grep -q '^mesh  *#571722  *not pinned  *mesh-llm,skippy$'
                nix-detour pr add custom --pr 3 --repo someone/nixpkgs --attrs custom-pkg \
                  --path custom-pkg=pkgs/development/custom-pkg/default.nix
                test "$(jq -c .custom.paths nixpkgs-prs.json)" = '{"custom-pkg":"pkgs/development/custom-pkg/default.nix"}'
                if nix-detour pr add bad --pr 4 --repo a/b --attrs bad --path bad 2>/dev/null; then echo "a path without = should fail" >&2; exit 1; fi
                if nix-detour pr add bad --pr 4 --repo a/b --attrs pkg --path other=path 2>/dev/null; then echo "a path for an unexported package should fail" >&2; exit 1; fi
                nix-detour pr remove custom
                if nix-detour pr pin berd abc 2>/dev/null; then echo "pin with a short sha should fail" >&2; exit 1; fi
                if nix-detour pr pin nope 0000000000000000000000000000000000000000 2>/dev/null; then echo "pin of a missing entry should fail" >&2; exit 1; fi
                if nix-detour pr add x --pr 3 --attrs x 2>/dev/null; then echo "add without --repo should fail" >&2; exit 1; fi
                if nix-detour pr add x --pr 3 --repo a/b --attrs x --module bad 2>/dev/null; then echo "a module without a path should fail" >&2; exit 1; fi
                if nix-detour pr add berd --pr 2 --repo other/nixpkgs --attrs berd 2>/dev/null; then echo "adding an existing entry should fail" >&2; exit 1; fi
                test "$(jq -r .berd.owner nixpkgs-prs.json)" = someone
                # A --rev that can't be pinned adds nothing.
                if nix-detour pr add x --pr 3 --repo a/b --attrs x --rev abc 2>/dev/null; then echo "add with a short --rev should fail" >&2; exit 1; fi
                test "$(jq -r 'has("x")' nixpkgs-prs.json)" = false

                # Corrupt nixpkgs-prs.json stays untouched on error
                echo '{ bad json' > bad-prs.json
                if nix-detour pr add x --pr 3 --repo a/b --attrs x --file bad-prs.json 2>/dev/null; then echo "pr add on corrupt json should fail" >&2; exit 1; fi
                test "$(cat bad-prs.json)" = '{ bad json'
                if nix-detour pr remove mesh --file bad-prs.json 2>/dev/null; then echo "pr remove on corrupt json should fail" >&2; exit 1; fi
                test "$(cat bad-prs.json)" = '{ bad json'

                nix-detour pr remove berd
                test "$(jq -r 'keys | join(",")' nixpkgs-prs.json)" = mesh
                if nix-detour pr remove berd 2>/dev/null; then echo "removing a missing entry should fail" >&2; exit 1; fi

                # PR check command with mock gh
                cat << 'EOF' > gh
        #!${pkgs.runtimeShell}
        if [ "$2" = "repos/NixOS/nixpkgs/pulls/571722" ]; then
          echo '{"state":"open","draft":false,"merged":false,"title":"mesh-llm"}'
        elif [ "$2" = "repos/NixOS/nixpkgs/pulls/100" ]; then
          echo '{"state":"closed","draft":false,"merged":true,"merge_commit_sha":"abc12345","title":"merged-landing"}'
        elif [ "$2" = "repos/NixOS/nixpkgs/pulls/101" ]; then
          echo '{"state":"open","draft":true,"merged":false,"title":"wip-pkg"}'
        elif [ "$2" = "repos/NixOS/nixpkgs/pulls/102" ]; then
          echo '{"state":"closed","draft":false,"merged":true,"merge_commit_sha":"notyet00","title":"merged-waiting"}'
        elif [ "$2" = "repos/NixOS/nixpkgs/pulls/103" ]; then
          echo '{"state":"closed","draft":false,"merged":false,"title":"abandoned-pkg"}'
        elif [ "$2" = "repos/NixOS/nixpkgs/pulls/999" ]; then
          echo '{"state":"open","draft":false,"merged":false,"title":"subpr"}'
        elif [ "$2" = "repos/NixOS/nixpkgs/compare/nixos-unstable...abc12345" ]; then
          echo '{"status":"behind"}'
        elif [ "$2" = "repos/NixOS/nixpkgs/compare/nixos-unstable...notyet00" ]; then
          echo '{"status":"ahead"}'
        elif [ "$2" = "repos/NixOS/nixpkgs/pulls/500" ]; then
          echo '{"head":{"repo":{"full_name":"autouser/nixpkgs"},"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"title":"autopkg: init at 1.0.0"}'
        elif [ "$2" = "repos/NixOS/nixpkgs/pulls/500/files" ]; then
          echo '[{"filename":"pkgs/by-name/au/autopkg/package.nix"},{"filename":"nixos/modules/services/misc/autopkg.nix"}]'
        elif [ "$2" = "repos/NixOS/nixpkgs/pulls/501" ]; then
          echo '{"head":{"repo":{"full_name":"autouser/nixpkgs"},"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"title":"otherpkg: init at 0.1.0"}'
        elif [ "$2" = "repos/NixOS/nixpkgs/pulls/501/files" ]; then
          echo '[{"filename":"pkgs/by-name/ot/otherpkg/package.nix"}]'
        elif [ "$2" = "repos/custom/nixpkgs/pulls/502" ]; then
          echo '{"head":{"repo":{"full_name":"pyuser/nixpkgs"},"sha":"cccccccccccccccccccccccccccccccccccccccc"},"title":"python3Packages.pyfoo: init at 1.0"}'
        elif [ "$2" = "repos/custom/nixpkgs/pulls/502/files" ]; then
          echo '[]'
        else
          exit 1
        fi
        EOF
                chmod +x gh

                cat << 'EOF' > nix
        #!${pkgs.runtimeShell}
        if [ "$1" = "flake" ] && [ "$2" = "prefetch" ]; then
          echo '{"hash":"sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}'
        fi
        EOF
                chmod +x nix

                # Shorthand pr add with auto-detection of repo, attrs, modules, and pin
                PATH=".:$PATH" nix-detour pr add 500
                test "$(jq -r .autopkg.owner nixpkgs-prs.json)" = "autouser"
                test "$(jq -r .autopkg.rev nixpkgs-prs.json)" = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                test "$(jq -r .autopkg.narHash nixpkgs-prs.json)" = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
                test "$(jq -r '.autopkg.attrs | first' nixpkgs-prs.json)" = "autopkg"
                test "$(jq -r .autopkg.modules.autopkg nixpkgs-prs.json)" = "nixos/modules/services/misc/autopkg.nix"

                # --python with custom --path, --upstream, --channel (untilChannel), --no-pin
                PATH=".:$PATH" nix-detour pr add pyfoo --pr 502 --upstream custom/nixpkgs --python py-foo \
                  --path python3Packages.py-foo=pkgs/development/python-modules/py-foo/custom.nix \
                  --channel nixos-25.05 --no-pin --auto
                test "$(jq -c .pyfoo.pythonPackages nixpkgs-prs.json)" = '["py-foo"]'
                test "$(jq -r '.pyfoo.paths["python3Packages.py-foo"]' nixpkgs-prs.json)" = "pkgs/development/python-modules/py-foo/custom.nix"
                test "$(jq -r .pyfoo.upstream nixpkgs-prs.json)" = "custom/nixpkgs"
                test "$(jq -r .pyfoo.untilChannel nixpkgs-prs.json)" = "nixos-25.05"
                test "$(jq -r .pyfoo.rev nixpkgs-prs.json)" = ""
                nix-detour pr remove pyfoo

                # Empty nixpkgs-prs.json does not crash pr check
                echo '{}' > empty-prs.json
                PATH=".:$PATH" nix-detour pr check --file empty-prs.json | grep -q 'no entries'
                test "$(PATH=".:$PATH" nix-detour pr check --json --file empty-prs.json)" = '{}'

                # Shorthand pr add with full URL
                PATH=".:$PATH" nix-detour pr add https://github.com/NixOS/nixpkgs/pull/501
                test "$(jq -r .otherpkg.owner nixpkgs-prs.json)" = "autouser"
                test "$(jq -r .otherpkg.rev nixpkgs-prs.json)" = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

                # Pin update check
                PATH=".:$PATH" nix-detour pr pin otherpkg > pin_one.txt
                grep -q "is already up to date" pin_one.txt
                PATH=".:$PATH" nix-detour pr pin --all > pin_all.txt
                grep -q "is already up to date" pin_all.txt

                nix-detour pr remove autopkg
                nix-detour pr remove otherpkg

                test "$(PATH=".:$PATH" nix-detour pr check --json mesh | jq -r .mesh.status)" = "open"
                nix-detour pr add landed --pr 100 --repo someone/nixpkgs --attrs landed-pkg
                nix-detour pr add drafty --pr 101 --repo someone/nixpkgs --attrs drafty-pkg
                nix-detour pr add waiting --pr 102 --repo someone/nixpkgs --attrs waiting-pkg
                nix-detour pr add closedp --pr 103 --repo someone/nixpkgs --attrs closed-pkg
                nix-detour pr add offline --pr 404 --repo someone/nixpkgs --attrs offline-pkg
                checks_json=$(PATH=".:$PATH" nix-detour pr check --json landed drafty waiting closedp offline)
                test "$(jq -r .landed.status <<<"$checks_json")" = "in-channel"
                test "$(jq -r .landed.inChannel <<<"$checks_json")" = "true"
                test "$(jq -r .drafty.status <<<"$checks_json")" = "draft"
                test "$(jq -r .waiting.status <<<"$checks_json")" = "merged"
                test "$(jq -r .waiting.inChannel <<<"$checks_json")" = "false"
                test "$(jq -r .closedp.status <<<"$checks_json")" = "closed"
                test "$(jq -r .offline.status <<<"$checks_json")" = "unknown"
                nix-detour pr remove drafty
                nix-detour pr remove waiting
                nix-detour pr remove closedp
                nix-detour pr remove offline

                PATH=".:$PATH" nix-detour check > check_out.txt
                grep -q '=== PRs ===' check_out.txt
                grep -q 'landed' check_out.txt
                nix-detour list > list_prs.txt
                grep -q '=== PRs ===' list_prs.txt
                nix-detour release landed
                test "$(jq -r 'has("landed")' nixpkgs-prs.json)" = false

                # Positional path handling for PRs
                mkdir -p subpr
                echo '{"subpr": {"pr": 999, "owner": "o", "repo": "r", "attrs": ["subpr"]}}' > subpr/nixpkgs-prs.json
                nix-detour pr list subpr > subpr_list.txt
                grep -q '^subpr ' subpr_list.txt
                if grep -q '^mesh ' subpr_list.txt; then echo "mesh should not be in subpr_list" >&2; exit 1; fi
                nix-detour list subpr > sub_prs_list.txt
                grep -q '^subpr ' sub_prs_list.txt
                if grep -q '^mesh ' sub_prs_list.txt; then echo "mesh should not be in sub_prs_list" >&2; exit 1; fi
                if nix-detour pr list nonexistent 2>/dev/null; then echo "pr list with nonexistent path should fail" >&2; exit 1; fi
                if nix-detour pr list --file nixpkgs-prs.json subpr 2>/dev/null; then echo "pr list with both --file and positional path should fail" >&2; exit 1; fi
                # Bare directory name without matching PR entry checks that directory's PR file
                PATH=".:$PATH" nix-detour pr check subpr > subpr_check.txt
                grep -q '^subpr[[:space:]]\+#999' subpr_check.txt
                # Directory matching existing entry name still checks the entry
                mkdir -p mesh
                PATH=".:$PATH" nix-detour pr check mesh > mesh_check.txt
                grep -q '^mesh[[:space:]]\+#571722' mesh_check.txt
                # Explicit relative path forces directory check
                echo '{"meshdir": {"pr": 999, "owner": "o", "repo": "r", "attrs": ["meshdir"]}}' > mesh/nixpkgs-prs.json
                PATH=".:$PATH" nix-detour pr check ./mesh > mesh_dir_check.txt
                grep -q '^meshdir[[:space:]]\+#999' mesh_dir_check.txt
                # Bare file without matching PR entry checks that file
                echo '{"prsfile": {"pr": 999, "owner": "o", "repo": "r", "attrs": ["prsfile"]}}' > bare-prs-file
                PATH=".:$PATH" nix-detour pr check bare-prs-file > bare_file_check.txt
                grep -q '^prsfile[[:space:]]\+#999' bare_file_check.txt

                # Combined check preserves per-entry untilChannel unless --channel is explicit
                mkdir -p chan_dir
                echo '{"waiting": {"pr": 102, "owner": "o", "repo": "r", "attrs": ["w"], "untilChannel": "nixos-25.05"}}' > chan_dir/nixpkgs-prs.json
                PATH=".:$PATH" nix-detour check chan_dir > chan_check.txt
                grep -q 'waiting for nixos-25.05' chan_check.txt

                # pr check rejects entries with invalid PR numbers
                echo '{"badpr": {"pr": "bad", "owner": "o", "repo": "r", "attrs": ["b"]}}' > bad-prs.json
                if PATH=".:$PATH" nix-detour pr check --json --file bad-prs.json 2>/dev/null; then
                  echo "pr check should fail on non-numeric pr" >&2
                  exit 1
                fi

                # release validates both files before mutating either
                mkdir -p atomic_rel
                echo '{"keepme": {"from": "stable", "reason": "r"}}' > atomic_rel/held-packages.json
                echo '{corrupt' > atomic_rel/nixpkgs-prs.json
                if nix-detour release keepme atomic_rel 2>/dev/null; then
                  echo "release should fail when sibling PR file is corrupt" >&2
                  exit 1
                fi
                test "$(jq -r 'has("keepme")' atomic_rel/held-packages.json)" = true

                nix-detour web --help > web_help.txt
                grep -q 'nix-detour web' web_help.txt
                touch $out
      '';

  # Action helper scripts: moved.sh, clone-holds.sh, release-check.sh, update.sh, reach.sh, hold.sh.
  actions =
    pkgs.runCommand "nix-detour-actions-tests"
      {
        nativeBuildInputs = [
          nix-detour
          pkgs.bash
          pkgs.coreutils
          pkgs.findutils
          pkgs.gawk
          pkgs.git
          pkgs.gnugrep
          pkgs.gnused
          pkgs.jq
        ];
      }
      ''
        set -euo pipefail
        export HOME=$TMPDIR GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
        mkdir -p repo_under_test
        cp -r ${../scripts} repo_under_test/scripts
        cp ${../watch.nix} repo_under_test/watch.nix
        chmod -R u+w repo_under_test
        patchShebangs repo_under_test/scripts
        scripts=$PWD/repo_under_test/scripts

        # 1. moved.sh: SKIP_UNMOVED=false, unmoved, moved, and follows-array input paths
        mkdir -p origin_repo work_repo
        git init -q --bare origin_repo
        (
          cd work_repo
          git init -q -b main .
          git remote add origin "$PWD/../origin_repo"
          jq -n '{
            root: "root",
            nodes: {
              root: { inputs: { nixpkgs: "nixpkgs", sub: "sub" } },
              sub: { inputs: { nixpkgs: ["nixpkgs"] } },
              nixpkgs: { locked: { rev: "1111111111111111111111111111111111111111", narHash: "sha256-111" } }
            }
          }' > flake.lock
          git add flake.lock && git commit -qm init
          git push -q origin main

          : > gh_out
          SKIP_UNMOVED=false FLAKE=. INPUT=nixpkgs BASE=main GITHUB_OUTPUT=$PWD/gh_out bash "$scripts/moved.sh" >/dev/null
          grep -qx 'moved=true' gh_out

          : > gh_out
          SKIP_UNMOVED=true FLAKE=. INPUT=nixpkgs BASE=main GITHUB_OUTPUT=$PWD/gh_out bash "$scripts/moved.sh" >/dev/null
          grep -qx 'moved=false' gh_out

          : > gh_out
          SKIP_UNMOVED=true FLAKE=. INPUT=sub/nixpkgs BASE=main GITHUB_OUTPUT=$PWD/gh_out bash "$scripts/moved.sh" >/dev/null
          grep -qx 'moved=false' gh_out

          jq '.nodes.nixpkgs.locked.rev = "2222222222222222222222222222222222222222"' flake.lock > f && mv f flake.lock
          : > gh_out
          SKIP_UNMOVED=true FLAKE=. INPUT=sub/nixpkgs BASE=main GITHUB_OUTPUT=$PWD/gh_out bash "$scripts/moved.sh" >/dev/null
          grep -qx 'moved=true' gh_out
        )

        # 2. clone-holds.sh: validation and local repository checkout at locked rev
        mkdir -p holds_remote
        (
          cd holds_remote
          git init -q -b main .
          echo '{"oldhold":{"from":"stable"}}' > held-packages.json
          git add held-packages.json && git commit -qm first
          first_rev=$(git rev-parse HEAD)
          echo '{"oldhold":{"from":"stable"},"newhold":{"from":"stable"}}' > held-packages.json
          git add held-packages.json && git commit -qm second

          cd "$TMPDIR/work_repo"
          jq --arg r "$first_rev" '.nodes.root.inputs["my-holds"] = "myholds" | .nodes.myholds = {locked: {rev: $r}}' flake.lock > f && mv f flake.lock

          if RUNNER_TEMP=$TMPDIR GITHUB_ENV=$TMPDIR/env HOLDS_REPO=$TMPDIR/holds_remote bash "$scripts/clone-holds.sh" 2>/dev/null; then
            echo "clone-holds without HOLDS_INPUT should fail" >&2
            exit 1
          fi
          if RUNNER_TEMP=$TMPDIR GITHUB_ENV=$TMPDIR/env HOLDS_REPO=$TMPDIR/holds_remote HOLDS_INPUT=missing-input bash "$scripts/clone-holds.sh" 2>/dev/null; then
            echo "clone-holds with unknown input should fail" >&2
            exit 1
          fi
          : > "$TMPDIR/env"
          RUNNER_TEMP=$TMPDIR GITHUB_ENV=$TMPDIR/env HOLDS_REPO=$TMPDIR/holds_remote HOLDS_INPUT=my-holds FLAKE=. bash "$scripts/clone-holds.sh"
          grep -qx "NIX_DETOUR_HOLDS_CLONE=$TMPDIR/holds-repo" "$TMPDIR/env"
          grep -qx "NIX_DETOUR_OVERRIDE=--override-input my-holds path:$TMPDIR/holds-repo" "$TMPDIR/env"
          test "$(jq -r 'keys | join(",")' "$TMPDIR/holds-repo/held-packages.json")" = "oldhold"
        )

        # 3. release-check.sh: release vs held with valid and malformed since dates
        mkdir -p mockbin
        cat << 'EOF' > mockbin/nix
        #!${pkgs.runtimeShell}
        case "$*" in
          *"builtins.currentSystem"*) printf 'x86_64-linux' ;;
          *"#releaseChecks.x86_64-linux --override-input"*)
            echo '{"good":{"since":"2026-01-01"},"stillbroken":{"since":"2026-01-01"},"badsince":{"since":"not-a-date"}}'
            ;;
          *'build --no-link'*'"good"'*) exit 0 ;;
          *'build --no-link'*) exit 1 ;;
          *) exit 1 ;;
        esac
        EOF
        chmod +x mockbin/nix
        PATH="$PWD/mockbin:$PATH" "$scripts/release-check.sh" . github:NixOS/nixpkgs/nixos-unstable > rel.out 2> rel.err
        grep -qx 'release good' rel.out
        grep -q '^held stillbroken [0-9]\+$' rel.out
        grep -qx 'held badsince' rel.out
        grep -q '::warning::badsince:' rel.err

        # 4. update.sh + reach.sh + hold.sh offline verification
        cat << 'EOF' > mockbin/nix
        #!${pkgs.runtimeShell}
        # Delegate nix run (from hold.sh) to nix-detour CLI and mock nix flake prefetch
        if [ "$1" = "run" ]; then
          shift 3
          exec nix-detour "$@"
        fi
        if [ "$1" = "flake" ] && [ "$2" = "prefetch" ]; then
          echo '{"hash":"sha256-111"}'
          exit 0
        fi
        case "$*" in
          *"builtins.currentSystem"*) printf 'x86_64-linux' ;;
          *"#nixDetourWatch.x86_64-linux --apply x: \"yes\""*) printf 'yes' ;;
          *"#nixDetourTargets.x86_64-linux --apply x: \"yes\""*) printf 'yes' ;;
          *"#nixDetourWatch.x86_64-linux --apply"*)
            if [ -n "''${MOCK_ROUND2:-}" ]; then
              # pkgA was fixed by hold; pkgB still fails even when held!
              echo '{"pkgA":{"drv":"/nix/store/aaaa-pkgA.drv","out":"/nix/store/aaaa-pkgA"},"pkgB":null,"netpkg":{"drv":"/nix/store/nnnn-netpkg.drv","out":"/nix/store/nnnn-netpkg"}}'
            else
              echo '{"okpkg":{"drv":"/nix/store/oooo-okpkg.drv","out":"/nix/store/oooo-okpkg"},"pkgA":null,"pkgB":null,"netpkg":{"drv":"/nix/store/nnnn-netpkg.drv","out":"/nix/store/nnnn-netpkg"},"buildfail":{"drv":"/nix/store/bbbb-buildfail.drv","out":"/nix/store/bbbb-buildfail"}}'
            fi
            ;;
          *'#nixDetourWatch.x86_64-linux."pkgA".drvPath'*)
            echo "error: Package ‘pkgA-1.0’ in /nix/store/xxx/pkg.nix:10 is marked as broken" >&2
            exit 1
            ;;
          *'#nixDetourWatch.x86_64-linux."pkgB".drvPath'*)
            echo "error: evaluation failed for pkgB" >&2
            exit 1
            ;;
          *"--dry-run"*)
            echo "these 2 derivations will be built:" >&2
            echo "  /nix/store/nnnn-netpkg.drv" >&2
            echo "  /nix/store/bbbb-buildfail.drv" >&2
            echo "these 0 paths will be fetched:" >&2
            ;;
          *"--keep-going"*) exit 1 ;;
          *"path-info /nix/store/oooo-okpkg"*|*"path-info /nix/store/aaaa-pkgA"*) exit 0 ;;
          *"path-info"*) exit 1 ;;
          *"build"*"/nix/store/nnnn-netpkg.drv^*"*)
            echo "error: unable to download 'https://example.org/src.tar.gz': HTTP error 502" >&2
            exit 1
            ;;
          *"build"*"/nix/store/bbbb-buildfail.drv^*"*)
            echo "builder for '/nix/store/bbbb-buildfail.drv' failed with exit code 2" >&2
            exit 1
            ;;
          *"#nixDetourTargets.x86_64-linux --apply builtins.attrNames"*)
            echo '["hostA"]'
            ;;
          *'#nixDetourTargets.x86_64-linux."hostA".target.drvPath'*)
            if [ -n "''${MOCK_REACH:-}" ]; then
              printf '/nix/store/hhhh-hostA.drv'
              exit 0
            fi
            echo "error:" >&2
            echo "while evaluating derivation 'system-path'" >&2
            echo "while evaluating derivation 'tracepkg-2.0'" >&2
            echo "error: tracepkg failed assertion" >&2
            exit 1
            ;;
          *'#nixDetourTargets.x86_64-linux."hostA".pkgs --apply'*)
            printf 'tracepkg'
            ;;
          *) exit 1 ;;
        esac
        EOF
        cat << 'EOF' > mockbin/nix-store
        #!${pkgs.runtimeShell}
        echo "store daemon unavailable in sandbox" >&2
        exit 1
        EOF
        chmod +x mockbin/nix mockbin/nix-store

        PATH="$PWD/mockbin:$PATH" bash "$scripts/update.sh" . > upd.out 2>/dev/null
        grep -q '^broken pkgA Package .* is marked as broken$' upd.out
        grep -qx 'broken pkgB evaluation failed for pkgB' upd.out
        grep -q '^unavailable netpkg error: unable to download .* HTTP error 502$' upd.out
        grep -qx 'broken buildfail fails to build' upd.out
        grep -qx 'broken tracepkg tracepkg failed assertion (in hostA)' upd.out
        grep -qx 'ok x86_64-linux 1' upd.out

        # reach.sh reports unchecked when nix-store -qR cannot query closure
        echo '{"pkgA":{"from":"stable"}}' > reach-holds.json
        MOCK_REACH=1 PATH="$PWD/mockbin:$PATH" bash "$scripts/reach.sh" . reach-holds.json > reach.out
        grep -q '^unchecked hostA closure query failed:' reach.out

        # hold.sh: multi-round hold & rollback of still-broken hold in report mode + commit safety checks
        (
          cd work_repo
          echo '{}' > held-packages.json
          cat << 'EOF' > round0.txt
        broken pkgA broken in unstable
        broken pkgB broken everywhere
        EOF
          mkdir -p rtemp
          : > gh_out
          : > gh_summary
          MOCK_ROUND2=1 MOCK_REACH=1 PATH="$TMPDIR/mockbin:$PATH" \
            FLAKE=. HOLDS=held-packages.json INPUT=nixpkgs BASE=main MODE=report BRANCH=main BUILD=false \
            RUNNER_TEMP=$PWD/rtemp GITHUB_OUTPUT=$PWD/gh_out GITHUB_STEP_SUMMARY=$PWD/gh_summary \
            bash "$scripts/hold.sh" round0.txt
          grep -qx 'held=pkgA' gh_out
          grep -qx 'failed=pkgB' gh_out
          test "$(cat held-packages.json)" = '{}'

          # Commit mode rejects mismatched EXPECTED_HEAD and pull_request events without EXPECTED_HEAD
          if PATH="$TMPDIR/mockbin:$PATH" FLAKE=. HOLDS=held-packages.json INPUT=nixpkgs BASE=main MODE=commit BRANCH=main BUILD=false \
            EXPECTED_HEAD=deadbeef RUNNER_TEMP=$PWD/rtemp GITHUB_OUTPUT=$PWD/gh_out GITHUB_STEP_SUMMARY=$PWD/gh_summary \
            bash "$scripts/hold.sh" round0.txt 2>/dev/null; then
            echo "hold.sh commit mode with wrong EXPECTED_HEAD should fail" >&2
            exit 1
          fi
          if PATH="$TMPDIR/mockbin:$PATH" FLAKE=. HOLDS=held-packages.json INPUT=nixpkgs BASE=main MODE=commit BRANCH=main BUILD=false \
            GITHUB_EVENT_NAME=pull_request RUNNER_TEMP=$PWD/rtemp GITHUB_OUTPUT=$PWD/gh_out GITHUB_STEP_SUMMARY=$PWD/gh_summary \
            bash "$scripts/hold.sh" round0.txt 2>/dev/null; then
            echo "hold.sh commit mode on pull_request without EXPECTED_HEAD should fail" >&2
            exit 1
          fi
        )

        touch $out
      '';

  # The dashboard server: adds holds through the CLI, refuses other sites.
  web-server =
    pkgs.runCommand "nix-detour-web-server-tests"
      {
        nativeBuildInputs = [
          pkgs.curl
          pkgs.jq
          pkgs.python3
        ];
        __darwinAllowLocalNetworking = true;
      }
      ''
        set -euo pipefail
        port=18765 url=http://127.0.0.1:18765
        python3 ${../web/server.py} --port $port --static-dir . --holds "$PWD/held-packages.json" \
          --prs "$PWD/nixpkgs-prs.json" --cli ${lib.getExe nix-detour} 2>server.log &
        trap 'kill $!' EXIT
        for _ in $(seq 100); do curl -sf -o /dev/null $url/api/data && break; sleep 0.1; done
        # HTTP status of a POST to $1, the rest are curl's arguments; the body goes to resp.json.
        post() {
          local path="$1"
          shift
          curl -s -o resp.json -w '%{http_code}' -X POST "$url$path" "$@"
        }
        json=(-H 'Content-Type: application/json')
        hold='{"name":"foo","kind":"hold","entry":{"from":"stable","reason":"r"}}'

        # HEAD, Cache-Control, pr-statuses, invalid pr/upstream/channel queries, unknown POST, invalid JSON, Content-Length
        curl -sI $url/api/data | grep -qi '^Cache-Control: no-cache'
        test "$(curl -s -o /dev/null -w '%{http_code}' -I $url/api/data)" = 200
        test "$(curl -sf $url/api/pr-statuses)" = '{}'
        test "$(curl -s -o /dev/null -w '%{http_code}' "$url/api/pr-status?pr=notanumber")" = 400
        test "$(curl -s -o /dev/null -w '%{http_code}' "$url/api/pr-status?pr=1&upstream=../../user")" = 400
        test "$(curl -s -o /dev/null -w '%{http_code}' "$url/api/pr-status?pr=1&channel=../evil")" = 400
        test "$(curl -s -o /dev/null -w '%{http_code}' "$url/api/pr-status?pr=1&channel=github:../../evil/main")" = 400
        test "$(curl -s -o /dev/null -w '%{http_code}' "$url/api/pr-status?pr=1&channel=github:NixOS/nixpkgs/nixos-unstable")" = 200
        test "$(post /api/unknown "''${json[@]}" -d '{}')" = 404
        test "$(post /api/detour "''${json[@]}" -d '{broken')" = 400
        test "$(post /api/detour "''${json[@]}" -H 'Content-Length: bogus' -d '{}')" = 400
        test "$(post /api/detour "''${json[@]}" -H 'Content-Length: 2000000' -d '{}')" = 413
        test "$(post /api/detour "''${json[@]}" -d '{"name":"--evil","kind":"hold","entry":{"from":"stable","reason":"r"}}')" = 400
        test "$(post /api/detour "''${json[@]}" -d '{"name":"foo","kind":"hold","entry":{"from":"stable","reason":"r","untilVersion":">= 2.0"}}')" = 400

        test "$(post /api/detour "''${json[@]}" -H "Origin: $url" -d "$hold")" = 200
        test "$(jq -c '.foo | [.from, .reason]' held-packages.json)" = '["stable","r"]'
        # The CLI checks the fix; its error comes back.
        test "$(post /api/detour "''${json[@]}" -d '{"name":"bar","kind":"fix","entry":{"from":"current","reason":"r","patches":["nope.patch"]}}')" = 400
        jq -e '.error | test("nope.patch is not a file")' resp.json
        test "$(jq -r 'has("bar")' held-packages.json)" = false
        # PR entries are pinned to the PR head; without network there is none, so nothing is saved.
        pr='{"name":"mesh","kind":"pr","entry":{"pr":1,"owner":"NixOS","repo":"nixpkgs","rev":"","narHash":"","attrs":["mesh"]}}'
        test "$(post /api/detour "''${json[@]}" -d "$pr")" = 400
        jq -e '.error | test("head commit of NixOS/nixpkgs#1")' resp.json
        test "$(post /api/detour "''${json[@]}" -d '{"name":"m","kind":"pr","entry":{"pr":1,"owner":"o","repo":"r","attrs":[]}}')" = 400
        test ! -e nixpkgs-prs.json

        # Requests from other sites.
        test "$(post /api/detour -H 'Content-Type: text/plain' -d "$hold")" = 403
        test "$(post /api/detour "''${json[@]}" -H 'Origin: http://evil.example' -d "$hold")" = 403
        test "$(post /api/release "''${json[@]}" -H 'Host: evil.example' -d '{"name":"foo"}')" = 403
        test "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: evil.example' $url/api/data)" = 403
        test "$(jq -r 'has("foo")' held-packages.json)" = true

        # Releasing missing entry fails with 400; releasing foo succeeds; corrupt JSON surfaces in /api/data.errors
        test "$(post /api/release "''${json[@]}" -d '{"name":"missing","kind":"hold"}')" = 400
        test "$(post /api/release "''${json[@]}" -d '{"name":"foo","kind":"hold"}')" = 200
        test "$(jq -r 'has("foo")' held-packages.json)" = false
        echo '{corrupt' > held-packages.json
        curl -sf $url/api/data | jq -e '.errors.holds != null' >/dev/null
        touch $out
      '';

  # The fix's patch applies and the package builds with it.
  fix-builds = fixedPkgs.hello;

  # A patch on top of patches an earlier overlay set to null.
  fix-null-patches =
    let
      nulled = import nixpkgs {
        inherit system;
        overlays = [
          (_: prev: { hello = prev.hello.overrideAttrs { patches = null; }; })
          fixes.overlay
        ];
      };
    in
    pkgs.writeText "fix-null-patches" (builtins.toJSON (map baseNameOf nulled.hello.patches));

  mk-holds =
    if failed == [ ] then
      pkgs.writeText "mk-holds-tests" "ok"
    else
      throw "mkHolds/mkPrs tests failed: ${builtins.toJSON failed}";
}
