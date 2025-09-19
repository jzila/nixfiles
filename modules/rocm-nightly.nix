# Expose a pre-extracted TheRock ROCm nightly tree as Nix packages and
# set up convenient environment wiring (ROCM_PATH, ROCM_HOME, etc.).
{ config
, pkgs
, lib
, rocmRoot ? "/opt/rocm-nightly"
, packageName ? "rocm-nightly"
, enablePackages ? true
, enableEnv ? true
, envOverrides ? {
    HSA_OVERRIDE_GFX_VERSION = "11.5.1"; # Strix Halo (RDNA 3.5) is reported as gfx1151
  }
, extraPackages ? []
, version ? "7.0.0-rc20250917"
, overrideComponents ? [
    "rocminfo"
    "rocm-core"
    "rocm-device-libs"
    "rocm-cmake"
    "rocm-smi"
    "rocclr"
    "hsa-rocr"
    "hip"
    "hip-runtime"
    "hipcc"
    "hipify"
    "hipblas"
    "hipblasLt"
    "hipblaslt"
    "hipfft"
    "hiprand"
    "rocblas"
    "rocblasLt"
    "rocblaslt"
    "rocsolver"
    "rocsparse"
    "rocfft"
    "rocrand"
    "rocprim"
    "rocthrust"
    "rocprofiler-register"
    "rocprofiler-sdk"
    "roctracer"
    "rccl"
    "miopen"
  ]
, ...
}:

let
  inherit (lib) mkOption types optionalAttrs mapAttrs isDerivation isPath; 
  hasNightly = builtins.pathExists (rocmRoot + "/share/therock/dist_info.json");
  srcPath =
    if hasNightly then
      builtins.path {
        path = rocmRoot;
        name = "the-rock-nightly";
        recursive = true;
      }
    else null;

  rocmNightlyDrv =
    if hasNightly then pkgs.runCommandLocal packageName {}
      ''
        mkdir -p "$out"
        cp -a ${srcPath}/. "$out/"
      ''
    else null;

  rocmNightlyEnvDrv =
    if hasNightly then pkgs.buildFHSEnv {
      name = "${packageName}-env";
      targetPkgs = pkgs': [ rocmNightlyDrv ] ++ extraPackages;
      runScript = "${rocmNightlyDrv}/bin/rocminfo";
    } else null;

  overlay = final: prev:
    if !hasNightly then {}
    else let
      rocmOverrides =
        (lib.genAttrs overrideComponents (_: rocmNightlyDrv)) // {
          version = version;
        };
      basePackages = prev.rocmPackages or {};
    in {
      ${packageName} = rocmNightlyDrv;
      "${packageName}Env" = rocmNightlyEnvDrv;
      rocmPackages = basePackages // rocmOverrides;
    };

  defaultEnv =
    (if rocmNightlyDrv != null then {
      ROCM_PATH = toString rocmNightlyDrv;
      ROCM_HOME = toString rocmNightlyDrv;
    } else {}) // envOverrides;

  nightlySystemPackages =
    lib.optionals (enablePackages && hasNightly) (
      [ rocmNightlyDrv ]
      ++ lib.optional (enableEnv && rocmNightlyEnvDrv != null) rocmNightlyEnvDrv
      ++ extraPackages
    );
in
{
  options.rocm.nightly = {
    package = mkOption {
      type = types.nullOr types.package;
      default = null;
      description = "ROCm nightly package derivation copied from ${rocmRoot}.";
      readOnly = true;
    };
    envPackage = mkOption {
      type = types.nullOr types.package;
      default = null;
      description = "FHS shell for the ROCm nightly tree.";
      readOnly = true;
    };
    available = mkOption {
      type = types.bool;
      default = false;
      description = "Whether the ROCm nightly directory was detected at ${rocmRoot}.";
      readOnly = true;
    };
    root = mkOption {
      type = types.str;
      default = rocmRoot;
      description = "Host path containing the extracted ROCm nightly tree.";
      readOnly = true;
    };
  };

  config = {
    nixpkgs.overlays = [ overlay ];

    rocm.nightly.package = rocmNightlyDrv;
    rocm.nightly.envPackage = rocmNightlyEnvDrv;
    rocm.nightly.available = hasNightly;
    rocm.nightly.root = rocmRoot;

    environment.systemPackages = nightlySystemPackages;

    environment.variables = optionalAttrs (enableEnv && hasNightly) (
      mapAttrs (_: value:
        if isDerivation value || isPath value then toString value else value
      ) defaultEnv
    );

    programs.nix-ld = lib.mkIf hasNightly {
      enable = true;
      libraries = [ rocmNightlyDrv pkgs.stdenv.cc.cc pkgs.zlib pkgs.libdrm pkgs.libglvnd ];
    };

    warnings = lib.optionals (!hasNightly) [
      "ROCm nightly overlay skipped because '${rocmRoot}' was not found."
    ];
  };
}
