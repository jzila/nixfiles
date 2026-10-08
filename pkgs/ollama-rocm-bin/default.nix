# ollama with ROCm, taken from the official release archives instead of built
# from source like nixpkgs' ollama-rocm.
#
# nixpkgs builds ollama against its own ROCm, so it trails upstream: at the
# locked nixos-26.05 it is 0.32.3, too old to pull models such as qwen3.8. The
# release ships linux as a base archive (binary, CPU and Vulkan backends, CUDA)
# plus a ROCm archive meant to be unpacked over it, which brings its own ROCm
# runtime. Unpack both, drop CUDA, and track the tag directly.
#
# Bump with ./scripts/update-bin.sh ollama-rocm-bin, which rewrites
# sources.json. The ROCm overlay sits under its own "x86_64-linux-rocm" key so
# the script, which fetches one asset per key, handles both archives.
{
  lib,
  # autoPatchelfHook wants the stdenv's libc, so this needs a cc even though
  # nothing here is built.
  stdenv,
  fetchurl,
  autoPatchelfHook,
  zstd,
  libdrm,
  numactl,
  elfutils,
  zlib,
  vulkan-loader,
  versionCheckHook,
  writableTmpDirAsHomeHook,
}:

let
  sources = lib.importJSON ./sources.json;
  inherit (stdenv.hostPlatform) system;
  base =
    sources.systems.${system}
      or (throw "ollama-rocm-bin: no official ollama ROCm release build for ${system}");
  rocm = sources.systems."${system}-rocm";
in
stdenv.mkDerivation {
  pname = "ollama-rocm-bin";
  version = sources.version;

  srcs = [
    (fetchurl { inherit (base) url hash; })
    (fetchurl { inherit (rocm) url hash; })
  ];

  # Both archives unpack into the same bin/ and lib/ollama/ tree, the ROCm one
  # on top of the base, which the default unpackPhase can't express.
  dontUnpack = true;

  nativeBuildInputs = [
    autoPatchelfHook
    zstd
  ];

  # What the bundled backends link against beyond what they bundle themselves.
  buildInputs = [
    stdenv.cc.cc.lib
    libdrm
    numactl
    elfutils
    zlib
    vulkan-loader
  ];

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"
    for src in $srcs; do
      tar --use-compress-program=zstd -xf "$src" -C "$out"
    done

    # CUDA is about 2 GB of the base archive and useless without an NVIDIA
    # GPU. ollama probes each backend directory it finds, so a missing one is
    # simply skipped.
    rm -r "$out"/lib/ollama/cuda_v*

    runHook postInstall
  '';

  # The vulkan backend dlopens the loader rather than linking it.
  runtimeDependencies = [ vulkan-loader ];

  # Prebuilt GPU kernels (code objects) under rocm_*/ are ELF files for the GPU,
  # not the host, and must not be touched.
  dontStrip = true;

  nativeInstallCheckInputs = [
    versionCheckHook
    writableTmpDirAsHomeHook
  ];
  doInstallCheck = true;
  versionCheckKeepEnvironment = [ "HOME" ];
  versionCheckProgramArg = "--version";

  meta = {
    description = "Get up and running with large language models locally, official release build with ROCm";
    homepage = "https://ollama.com";
    changelog = "https://github.com/ollama/ollama/releases/tag/v${sources.version}";
    license = lib.licenses.mit;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "ollama";
    platforms = [ "x86_64-linux" ];
  };
}
