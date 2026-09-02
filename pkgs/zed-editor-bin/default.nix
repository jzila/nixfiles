# Zed packaged from the official macOS release build instead of compiled from
# source like nixpkgs' zed-editor.
#
# nixpkgs builds the whole Rust workspace, and Hydra's aarch64-darwin queue
# runs days behind the nixos-unstable channel bump, so a `nix flake update`
# regularly leaves zed-editor with no binary substitute. Zed publishes signed
# .dmg builds per release, so unpack one of those.
#
# Bump with ./scripts/update-zed-editor-bin.sh, which rewrites sources.json.
{
  lib,
  stdenvNoCC,
  fetchurl,
  _7zz,
}:

let
  sources = lib.importJSON ./sources.json;
  inherit (stdenvNoCC.hostPlatform) system;
  source =
    sources.systems.${system}
      or (throw "zed-editor-bin: no official Zed release build for ${system}");
in
stdenvNoCC.mkDerivation {
  pname = "zed-editor-bin";
  version = sources.version;

  src = fetchurl { inherit (source) url hash; };

  # Zed's .dmg holds an APFS volume, which undmg cannot read.
  nativeBuildInputs = [ _7zz ];
  unpackCmd = ''7zz x -bso0 -bsp0 "$curSrc"'';
  sourceRoot = "Zed.app";

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/Applications/Zed.app" "$out/bin"
    cp -R . "$out/Applications/Zed.app"

    # The bundle ships its own git in Contents/MacOS, so unlike the nixpkgs
    # source build there is nothing to graft in here.

    # Zed resolves the app to launch from the physical location of the cli
    # binary, so the entry in bin/ has to be a symlink into the bundle.
    ln -s "$out/Applications/Zed.app/Contents/MacOS/cli" "$out/bin/zeditor"

    runHook postInstall
  '';

  # Guard against a truncated or restructured bundle. This reads the plist
  # rather than running `zeditor --version`, because launching the app from
  # inside $out makes macOS stamp provenance file flags on the bundle that Nix
  # then cannot clear, which fails the build during output registration.
  postInstall = ''
    plist="$out/Applications/Zed.app/Contents/Info.plist"
    if ! grep -q "<string>${sources.version}</string>" "$plist"; then
      echo "zed-editor-bin: $plist does not report version ${sources.version}" >&2
      exit 1
    fi
  '';

  # Rewriting anything inside the bundle invalidates Zed's code signature, and
  # patchShebangs would happily do that to the scripts under Contents.
  dontFixup = true;

  meta = {
    description = "High-performance, multiplayer code editor, from the official macOS release build";
    homepage = "https://zed.dev";
    changelog = "https://github.com/zed-industries/zed/releases/tag/v${sources.version}";
    license = lib.licenses.gpl3Only;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "zeditor";
    platforms = lib.attrNames sources.systems;
  };
}
