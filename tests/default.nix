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
                nix-detour pr remove berd
                test "$(jq -r 'keys | join(",")' nixpkgs-prs.json)" = mesh
                if nix-detour pr remove berd 2>/dev/null; then echo "removing a missing entry should fail" >&2; exit 1; fi

                # PR check command with mock gh
                cat << 'EOF' > gh
        #!/bin/sh
        if [ "$2" = "repos/NixOS/nixpkgs/pulls/571722" ]; then
          echo '{"state":"open","draft":false,"merged":false,"title":"mesh-llm"}'
        elif [ "$2" = "repos/NixOS/nixpkgs/pulls/100" ]; then
          echo '{"state":"closed","draft":false,"merged":true,"merge_commit_sha":"abc12345","title":"merged-landing"}'
        elif [ "$2" = "repos/NixOS/nixpkgs/pulls/999" ]; then
          echo '{"state":"open","draft":false,"merged":false,"title":"subpr"}'
        elif [ "$2" = "repos/NixOS/nixpkgs/compare/nixos-unstable...abc12345" ]; then
          echo '{"status":"behind"}'
        fi
        EOF
                chmod +x gh
                test "$(PATH=".:$PATH" nix-detour pr check --json mesh | jq -r .mesh.status)" = "open"
                nix-detour pr add landed --pr 100 --repo someone/nixpkgs --attrs landed-pkg
                test "$(PATH=".:$PATH" nix-detour pr check --json landed | jq -r .landed.status)" = "in-channel"
                test "$(PATH=".:$PATH" nix-detour pr check --json landed | jq -r .landed.inChannel)" = "true"
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

                nix-detour web --help > web_help.txt
                grep -q 'nix-detour web' web_help.txt
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

        test "$(post /api/release "''${json[@]}" -d '{"name":"foo","kind":"hold"}')" = 200
        test "$(jq -r 'has("foo")' held-packages.json)" = false
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
