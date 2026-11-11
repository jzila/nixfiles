# kata taken from the official release archives instead of built from source.
#
# There is no kata in nixpkgs and upstream ships no flake, so pin the
# goreleaser archives the same way roborev-bin does. Each holds one Go binary at
# the root; the Linux ones are cgo builds against glibc, so autoPatchelf fixes
# their interpreter.
#
# This uses the *_homebrew_* archives rather than the plain ones. The two builds
# are byte-for-byte the same Go code; the homebrew one only sets
# version.Distribution=homebrew, which makes `kata update` refuse with a
# "managed by a package manager" message instead of trying to replace a binary
# it has no permission to write in the store.
#
# Bump with ./scripts/update-bin.sh kata-bin, which rewrites sources.json.
{
  lib,
  stdenv,
  fetchurl,
  installShellFiles,
  autoPatchelfHook,
  versionCheckHook,
  writableTmpDirAsHomeHook,
}:

let
  sources = lib.importJSON ./sources.json;
  inherit (stdenv.hostPlatform) system;
  source =
    sources.systems.${system}
      or (throw "kata-bin: no official kata release build for ${system}");
in
stdenv.mkDerivation {
  pname = "kata-bin";
  version = sources.version;

  src = fetchurl { inherit (source) url hash; };

  # Every archive holds one file named kata at the root, which the default
  # unpackPhase has no sourceRoot to settle on.
  dontUnpack = true;

  nativeBuildInputs = [ installShellFiles ] ++ lib.optional stdenv.hostPlatform.isElf autoPatchelfHook;

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

  # The completions below run the binary, and the hook would only patch it after them.
  dontAutoPatchelf = true;
  postFixup = lib.optionalString stdenv.hostPlatform.isElf ''
    autoPatchelf "$out"
  '' + lib.optionalString (stdenv.buildPlatform.canExecute stdenv.hostPlatform) ''
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
