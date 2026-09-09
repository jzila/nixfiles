# kata taken from the official release archives instead of built from source.
#
# There is no kata in nixpkgs and upstream ships no flake, so pin the
# goreleaser archives the same way roborev-bin does. Each holds one statically
# linked Go binary at the root (CGO_ENABLED=0), so nothing needs a cc.
#
# This uses the *_homebrew_* archives rather than the plain ones. The two builds
# are byte-for-byte the same Go code; the homebrew one only sets
# version.Distribution=homebrew, which makes `kata update` refuse with a
# "managed by a package manager" message instead of trying to replace a binary
# it has no permission to write in the store.
#
# Bump with ./scripts/update-kata-bin.sh, which rewrites sources.json.
{
  lib,
  stdenvNoCC,
  fetchurl,
  installShellFiles,
  versionCheckHook,
  writableTmpDirAsHomeHook,
}:

let
  sources = lib.importJSON ./sources.json;
  inherit (stdenvNoCC.hostPlatform) system;
  source =
    sources.systems.${system}
      or (throw "kata-bin: no official kata release build for ${system}");
in
stdenvNoCC.mkDerivation {
  pname = "kata-bin";
  version = sources.version;

  src = fetchurl { inherit (source) url hash; };

  # Every archive holds one file named kata at the root, which the default
  # unpackPhase has no sourceRoot to settle on.
  dontUnpack = true;

  nativeBuildInputs = [ installShellFiles ];

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/bin"
    tar -xzf "$src" -C "$out/bin"
    chmod +x "$out/bin/kata"

    runHook postInstall
  '';

  # The darwin binaries are notarized with the hardened runtime, and the archive
  # carries that signature. Stripping would break it.
  dontStrip = true;

  postFixup = lib.optionalString (stdenvNoCC.buildPlatform.canExecute stdenvNoCC.hostPlatform) ''
    installShellCompletion --cmd kata \
      --bash <("$out/bin/kata" completion bash) \
      --zsh <("$out/bin/kata" completion zsh) \
      --fish <("$out/bin/kata" completion fish)
  '';

  nativeInstallCheckInputs = [
    versionCheckHook
    writableTmpDirAsHomeHook
  ];
  doInstallCheck = true;
  versionCheckKeepEnvironment = [ "HOME" ];
  # Cobra CLI: the version lives behind a subcommand as well as --version.
  versionCheckProgramArg = "version";

  meta = {
    description = "Local-first issue tracker for coding agents and the humans steering them, from the official release build";
    homepage = "https://github.com/kenn-io/kata";
    changelog = "https://github.com/kenn-io/kata/releases/tag/v${sources.version}";
    license = lib.licenses.mit;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "kata";
    platforms = lib.attrNames sources.systems;
  };
}
