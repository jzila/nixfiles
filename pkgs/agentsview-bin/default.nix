# agentsview taken from the official release archives instead of built from
# source.
#
# There is no agentsview in nixpkgs and upstream ships no flake, so pin the
# goreleaser archives the same way roborev-bin does. Each holds one Go binary
# at the root.
#
# Unlike roborev, the linux binaries are built with cgo (sqlite) and link
# dynamically against glibc, libstdc++ and libgcc_s, so linux runs
# autoPatchelfHook over them. The darwin binaries only need libSystem.
#
# Bump with ./scripts/update-agentsview-bin.sh, which rewrites sources.json.
{
  lib,
  # autoPatchelfHook wants the stdenv's libc and cc.lib, so this needs a cc on
  # linux even though nothing here is compiled.
  stdenv,
  fetchurl,
  autoPatchelfHook,
  installShellFiles,
  versionCheckHook,
  writableTmpDirAsHomeHook,
}:

let
  sources = lib.importJSON ./sources.json;
  inherit (stdenv.hostPlatform) system isLinux;
  source =
    sources.systems.${system}
      or (throw "agentsview-bin: no official agentsview release build for ${system}");
in
stdenv.mkDerivation {
  pname = "agentsview-bin";
  version = sources.version;

  src = fetchurl { inherit (source) url hash; };

  # Every archive holds one file named agentsview at the root, which the
  # default unpackPhase has no sourceRoot to settle on.
  dontUnpack = true;

  nativeBuildInputs = [ installShellFiles ] ++ lib.optionals isLinux [ autoPatchelfHook ];

  # libstdc++ and libgcc_s for the cgo sqlite build on linux.
  buildInputs = lib.optionals isLinux [ stdenv.cc.cc.lib ];

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/bin"
    tar -xzf "$src" -C "$out/bin"
    chmod +x "$out/bin/agentsview"

    runHook postInstall
  '';

  # The darwin binaries carry the adhoc signature the linker gave them.
  # Stripping would break it.
  dontStrip = true;

  # After fixup, not postInstall: on linux the binary only becomes runnable once
  # autoPatchelfHook has pointed it at the store's loader, and that runs in the
  # fixup phase.
  postFixup = lib.optionalString (stdenv.buildPlatform.canExecute stdenv.hostPlatform) ''
    installShellCompletion --cmd agentsview \
      --bash <("$out/bin/agentsview" completion bash) \
      --zsh <("$out/bin/agentsview" completion zsh) \
      --fish <("$out/bin/agentsview" completion fish)
  '';

  nativeInstallCheckInputs = [
    versionCheckHook
    writableTmpDirAsHomeHook
  ];
  doInstallCheck = true;
  versionCheckKeepEnvironment = [ "HOME" ];
  versionCheckProgramArg = "--version";

  meta = {
    description = "Local-first session search, analytics and token statistics for coding agents, from the official release build";
    homepage = "https://github.com/kenn-io/agentsview";
    changelog = "https://github.com/kenn-io/agentsview/releases/tag/v${sources.version}";
    license = lib.licenses.mit;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "agentsview";
    platforms = lib.attrNames sources.systems;
  };
}
