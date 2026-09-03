# opencode taken from the official release archives instead of rebuilt from
# source like nixpkgs' opencode.
#
# opencode ships several releases a day. The nixpkgs package has to re-pin the
# bun dependency FOD on every bump, so it trails upstream by days, and at the
# locked nixpkgs it sits on 1.18.25 while upstream is on 1.18.27. The release
# archives hold a single self-contained binary per platform, so unpack that and
# track the tag directly.
#
# Bump with ./scripts/update-opencode-bin.sh, which rewrites sources.json.
{
  lib,
  # makeBinaryWrapper compiles its wrapper and autoPatchelfHook wants the
  # stdenv's libc, so this needs a cc even though nothing here is built.
  stdenv,
  fetchurl,
  autoPatchelfHook,
  installShellFiles,
  makeBinaryWrapper,
  unzip,
  ripgrep,
  sysctl,
  versionCheckHook,
  writableTmpDirAsHomeHook,
}:

let
  sources = lib.importJSON ./sources.json;
  inherit (stdenv.hostPlatform) system isDarwin isLinux;
  source =
    sources.systems.${system}
      or (throw "opencode-bin: no official opencode release build for ${system}");
in
stdenv.mkDerivation {
  pname = "opencode-bin";
  version = sources.version;

  src = fetchurl { inherit (source) url hash; };

  # Every archive holds one file named opencode at the root, which the default
  # unpackPhase has no sourceRoot to settle on.
  dontUnpack = true;

  nativeBuildInputs = [
    installShellFiles
    makeBinaryWrapper
  ]
  ++ lib.optionals isDarwin [ unzip ]
  ++ lib.optionals isLinux [ autoPatchelfHook ];

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/bin"
    ${if isDarwin then ''unzip -q "$src" -d "$out/bin"'' else ''tar -xzf "$src" -C "$out/bin"''}
    chmod +x "$out/bin/opencode"

    # opencode shells out to ripgrep for its file search, and to sysctl on
    # darwin; without them on PATH it downloads its own copy at runtime.
    # Self-update has nowhere to write in the store, so turn it off.
    wrapProgram "$out/bin/opencode" \
      --prefix PATH : ${lib.makeBinPath ([ ripgrep ] ++ lib.optionals isDarwin [ sysctl ])} \
      --set OPENCODE_DISABLE_AUTOUPDATE true

    runHook postInstall
  '';

  # After fixup, not postInstall: on linux the binary only becomes runnable once
  # autoPatchelfHook has pointed it at the store's loader, and that runs in the
  # fixup phase. opencode wants a writable HOME even to print completions.
  postFixup = lib.optionalString (stdenv.buildPlatform.canExecute stdenv.hostPlatform) ''
    export HOME="$(mktemp -d)"
    installShellCompletion --cmd opencode \
      --bash <(SHELL=/bin/bash "$out/bin/opencode" completion) \
      --zsh <(SHELL=/bin/zsh "$out/bin/opencode" completion)
  '';

  # The binary carries bun's payload embedded in it, and on darwin the adhoc
  # signature the linker gave it. Stripping would disturb both.
  dontStrip = true;

  nativeInstallCheckInputs = [
    versionCheckHook
    writableTmpDirAsHomeHook
  ];
  doInstallCheck = true;
  versionCheckKeepEnvironment = [ "HOME" ];
  versionCheckProgramArg = "--version";

  meta = {
    description = "AI coding agent built for the terminal, from the official release build";
    homepage = "https://opencode.ai";
    changelog = "https://github.com/anomalyco/opencode/releases/tag/v${sources.version}";
    license = lib.licenses.mit;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "opencode";
    platforms = lib.attrNames sources.systems;
  };
}
