# roborev taken from the official release archives instead of built from source.
#
# roborev used to ship a flake, and this config consumed it as an input.
# Upstream dropped the flake and moved to github:kenn-io/roborev, so pin the
# goreleaser archives instead. They hold one statically linked Go binary per
# platform, so there is nothing to patch or link against.
#
# Bump with ./scripts/update-roborev-bin.sh, which rewrites sources.json.
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
      or (throw "roborev-bin: no official roborev release build for ${system}");
in
stdenvNoCC.mkDerivation {
  pname = "roborev-bin";
  version = sources.version;

  src = fetchurl { inherit (source) url hash; };

  # Every archive holds one file named roborev at the root, which the default
  # unpackPhase has no sourceRoot to settle on.
  dontUnpack = true;

  nativeBuildInputs = [ installShellFiles ];

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/bin"
    tar -xzf "$src" -C "$out/bin"
    chmod +x "$out/bin/roborev"

    runHook postInstall
  '';

  # The darwin binaries are notarized, and the release archive carries the
  # signature the linker gave them. Stripping would break it.
  dontStrip = true;

  postFixup = lib.optionalString (stdenvNoCC.buildPlatform.canExecute stdenvNoCC.hostPlatform) ''
    installShellCompletion --cmd roborev \
      --bash <("$out/bin/roborev" completion bash) \
      --zsh <("$out/bin/roborev" completion zsh) \
      --fish <("$out/bin/roborev" completion fish)
  '';

  nativeInstallCheckInputs = [
    versionCheckHook
    writableTmpDirAsHomeHook
  ];
  doInstallCheck = true;
  versionCheckKeepEnvironment = [ "HOME" ];
  # Cobra CLI: the version lives behind a subcommand, not a --version flag.
  versionCheckProgramArg = "version";

  meta = {
    description = "Automatic code review daemon for git commits, from the official release build";
    homepage = "https://github.com/kenn-io/roborev";
    changelog = "https://github.com/kenn-io/roborev/releases/tag/v${sources.version}";
    license = lib.licenses.mit;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "roborev";
    platforms = lib.attrNames sources.systems;
  };
}
