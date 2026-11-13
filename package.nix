{
  lib,
  stdenvNoCC,
  fetchNpmDeps,
  nodejs,
  npmHooks,
  makeBinaryWrapper,
  bash,
  coreutils,
  curl,
  git,
  jq,
  python3,
  versionCheckHook,
  nix-update-script,
  runCommand,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "nix-detour";
  version = "0.4.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./overlay.nix
      ./prs.nix
      ./watch.nix
      ./scripts
      ./web
    ];
  };

  npmDeps = fetchNpmDeps {
    inherit (finalAttrs) pname version src;
    sourceRoot = "${finalAttrs.src.name}/web";
    fetcherVersion = 2;
    hash = "sha256-n8grGEjz5TPxwltp+56YCmXLEGW0XT3UW7e13z2jCHc=";
  };

  npmRoot = "web";

  strictDeps = true;
  __structuredAttrs = true;

  nativeBuildInputs = [
    nodejs
    npmHooks.npmConfigHook
    makeBinaryWrapper
  ];

  buildInputs = [
    bash
    python3
  ];

  buildPhase = ''
    runHook preBuild
    npm --prefix web run build
    runHook postBuild
  '';

  doCheck = true;

  checkPhase = ''
    runHook preCheck
    npm --prefix web run check
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/bin" "$out/libexec/nix-detour" "$out/share/nix-detour"
    cp -r web/dist "$out/share/nix-detour/web"
    install -Dm644 overlay.nix prs.nix watch.nix -t "$out/share/nix-detour/nix"

    install -Dm755 scripts/release-check.sh "$out/libexec/nix-detour/release-check"
    install -Dm755 scripts/prs.sh "$out/libexec/nix-detour/prs"
    install -Dm755 web/server.py "$out/libexec/nix-detour/server.py"
    install -Dm755 scripts/nix-detour.sh "$out/bin/nix-detour"

    substituteInPlace "$out/bin/nix-detour" \
      --replace-fail "@version@" "${finalAttrs.version}" \
      --replace-fail "@releaseCheck@" "$out/libexec/nix-detour/release-check" \
      --replace-fail "@prs@" "$out/libexec/nix-detour/prs" \
      --replace-fail "@webServer@" "$out/libexec/nix-detour/web-server"

    wrapProgram "$out/libexec/nix-detour/release-check" \
      --prefix PATH : "${
        lib.makeBinPath [
          coreutils
          jq
        ]
      }"

    wrapProgram "$out/libexec/nix-detour/prs" \
      --prefix PATH : "${
        lib.makeBinPath [
          coreutils
          curl
          jq
        ]
      }"

    makeWrapper "${lib.getExe python3}" "$out/libexec/nix-detour/web-server" \
      --prefix PATH : "$out/bin:${lib.makeBinPath [ git ]}" \
      --add-flags "$out/libexec/nix-detour/server.py" \
      --add-flags "--static-dir" \
      --add-flags "$out/share/nix-detour/web"

    wrapProgram "$out/bin/nix-detour" \
      --prefix PATH : "$out/bin:${
        lib.makeBinPath [
          bash
          coreutils
          curl
          git
          jq
          python3
        ]
      }"

    runHook postInstall
  '';

  nativeInstallCheckInputs = [ versionCheckHook ];
  doInstallCheck = true;

  passthru = {
    updateScript = nix-update-script { };
    tests.cli =
      runCommand "${finalAttrs.pname}-cli-smoke"
        {
          nativeBuildInputs = [
            finalAttrs.finalPackage
            jq
          ];
        }
        ''
          nix-detour --help >/dev/null
          nix-detour hold add --file holds.json --from stable --reason "smoke test" --until-version 2.0.0 hello
          test "$(jq -r '.hello.from' holds.json)" = "stable"
          nix-detour hold list --file holds.json | grep -q "hello"
          nix-detour hold remove --file holds.json hello
          test "$(jq 'length' holds.json)" = "0"

          nix-detour pr add --file prs.json --no-pin --pr 42 --repo owner/nixpkgs --attrs foo foo
          test "$(jq -r '.foo.pr' prs.json)" = "42"
          nix-detour pr list --file prs.json | grep -q "foo"
          nix-detour pr remove --file prs.json foo
          test "$(jq 'length' prs.json)" = "0"

          test -f "${finalAttrs.finalPackage}/share/nix-detour/web/index.html"
          test -f "${finalAttrs.finalPackage}/share/nix-detour/nix/overlay.nix"
          touch "$out"
        '';
  };

  meta = {
    description = "Manage temporary package holds, fixes, and PR overlays for Nixpkgs";
    homepage = "https://github.com/kleinbem-dev/nix-detour";
    changelog = "https://github.com/kleinbem-dev/nix-detour/blob/v${finalAttrs.version}/CHANGELOG.md";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ kleinbem ];
    mainProgram = "nix-detour";
    platforms = lib.platforms.unix;
  };
})
