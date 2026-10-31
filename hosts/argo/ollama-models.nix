# The two models argo's ollama keeps loaded side by side:
#   - gemma4 (26B-A4B) for Home Assistant's Assist;
#   - Qwen3.8-Flash-Next (125B-A6B, unsloth's UD-IQ4_XS) for Hermes and
#     opencode.
#
# Qwen3.8 isn't in ollama's library, so ollama-import-qwen38 builds it from
# unsloth's GGUF: it downloads the three shards at a pinned revision, checks
# their hashes, merges them (ollama create rejects split GGUFs) and imports
# the result as qwen3.8-flash-next:iq4xs-gguf. The tag clients use,
# qwen3.8-flash-next:iq4xs, is made from that on every start with the
# parameters below; that's cheap, since it reuses the imported blob.
#
# Measured with both loaded (1 slot each, 8-bit KV cache): Qwen ~64 GiB,
# gemma4 ~23 GiB, and at least 21 GiB of RAM left while both work at once.
# Qwen's ~27 GiB per-layer embedding table stays on disk and is read as
# needed (LLAMA_ARG_LAZY_MODE in configuration.nix).
#
# Load order matters. Before loading a model next to another, ollama
# estimates its size and evicts the other if the estimate exceeds 80% of
# free RAM. For Qwen it counts the whole file plus a 16-bit cache for every
# layer (92 GiB), so Qwen loading after gemma4 always evicts gemma4, while
# gemma4 loading after Qwen fits. ollama-pin-models loads them in that
# order and pins both. A request for a different context size reloads a
# model, which can evict the other the same way, so clients must leave the
# context size to ollama (see configuration.nix).
{ config, pkgs, lib, localPkgs, ... }:
let
  qwen = "qwen3.8-flash-next:iq4xs";
  qwenBase = "qwen3.8-flash-next:iq4xs-gguf";
  gemma = "gemma4:26b-a4b";

  repo = "unsloth/Qwen3.8-Flash-Next-GGUF";
  rev = "766911a6b7369840a91dbcd95f9f997acaab6cd6";
  shards = {
    "Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf" = "5ce89370720f8bf90890f439361282104c1aa1482d4013bb9a50923e758e71a4";
    "Qwen3.8-Flash-Next-UD-IQ4_XS-00002-of-00003.gguf" = "577a38a2392b40ca2193cea502e1d92f60b8cd370675d308e0ec21885d9daaa7";
    "Qwen3.8-Flash-Next-UD-IQ4_XS-00003-of-00003.gguf" = "d4634e6d84f0ebb0940be15c90d3790bf6464e3dea3a1cddc567dc0e83ad8833";
  };
  firstShard = "Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf";

  cacheDir = "/var/cache/ollama-import-qwen38";

  # Only for llama-gguf-split, which needs no GPU; argo's nixpkgs config
  # would otherwise build llama.cpp with ROCm.
  llamaCpp = pkgs.llama-cpp.override { rocmSupport = false; };

  # Chat template, tool-call parser and sampling defaults as in ollama's own
  # qwen3.8 packages.
  baseModelfile = pkgs.writeText "qwen3.8-gguf-modelfile" ''
    FROM ${cacheDir}/merged.gguf
    TEMPLATE {{ .Prompt }}
    RENDERER qwen3.8
    PARSER qwen3.5
    PARAMETER repeat_penalty 1
    PARAMETER temperature 1
    PARAMETER top_k 20
    PARAMETER top_p 0.95
    PARAMETER min_p 0
    PARAMETER presence_penalty 0
  '';
  # 131072 tokens of context, as measured above; Hermes's context_length
  # (modules/hermes-service.nix) matches. A Modelfile num_ctx overrides
  # OLLAMA_CONTEXT_LENGTH, so /v1 clients get it too.
  modelfile = pkgs.writeText "qwen3.8-modelfile" ''
    FROM ${qwenBase}
    PARAMETER num_ctx 131072
  '';

  # llama-server's prompt cache keeps the state of conversations that lost
  # their slot, so taking turns on Qwen's one slot costs ~0.3 s instead of
  # re-reading the whole prompt (~27 s at 13K tokens). Each cached
  # conversation takes ~0.6 GiB with Qwen's recurrent-state checkpoints.
  # gemma4 only serves Home Assistant, whose prompt changes with entity
  # states; there the cache would just fill with stale copies. Ollama passes
  # the same environment to every runner (LLAMA_ARG_CACHE_RAM is 0 in
  # configuration.nix), so this wrapper raises it for Qwen's model file,
  # found through Qwen's manifest.
  promptCacheMiB = 4096;
  models = config.services.ollama.models;
  qwenManifestPath = lib.replaceStrings [ ":" ] [ "/" ] qwen;
  llamaServerWrapper = pkgs.writeShellScript "llama-server" ''
    model=
    prev=
    for arg in "$@"; do
      [ "$prev" = --model ] && model=$arg
      prev=$arg
    done
    for manifest in \
      ${models}/manifests-v2/ollama.com/library/${qwenManifestPath} \
      ${models}/manifests/registry.ollama.ai/library/${qwenManifestPath}; do
      [ -r "$manifest" ] || continue
      blob=$(${pkgs.jq}/bin/jq -r \
        '.layers[] | select(.mediaType == "application/vnd.ollama.image.model") | .digest' \
        "$manifest" | ${pkgs.coreutils}/bin/tr : -)
      if [ -n "$blob" ] && [ "''${model##*/}" = "$blob" ]; then
        export LLAMA_ARG_CACHE_RAM=${toString promptCacheMiB}
      fi
      break
    done
    exec -a "$0" "''${0%/*}/.llama-server-unwrapped" "$@"
  '';
in
{
  # Ollama finds llama-server next to its own (resolved) executable, so the
  # wrapper goes into the package itself.
  services.ollama.package = localPkgs.ollama-rocm-bin.overrideAttrs (old: {
    postInstall = (old.postInstall or "") + ''
      mv "$out"/lib/ollama/llama-server "$out"/lib/ollama/.llama-server-unwrapped
      cp ${llamaServerWrapper} "$out"/lib/ollama/llama-server
    '';
  });

  services.ollama.loadModels = [ gemma ];

  systemd.services.ollama-import-qwen38 = {
    description = "Import Qwen3.8-Flash-Next into ollama";
    after = [ "ollama.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    requires = [ "ollama.service" ];
    wantedBy = [ "multi-user.target" ];
    environment = {
      OLLAMA_HOST = "127.0.0.1:11434";
      HOME = cacheDir;
    };
    path = [ config.services.ollama.package llamaCpp pkgs.curl pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      DynamicUser = true;
      CacheDirectory = "ollama-import-qwen38";
      WorkingDirectory = cacheDir;
      # ~87 GB to download.
      TimeoutStartSec = "infinity";
    };
    script = ''
      set -euo pipefail
      until ollama list >/dev/null 2>&1; do sleep 2; done
      if ! ollama show ${qwenBase} >/dev/null 2>&1; then
        ${lib.concatStrings (lib.mapAttrsToList (file: sha256: ''
          if ! echo "${sha256}  ${file}" | sha256sum -c --status 2>/dev/null; then
            # Resumes a partial download; a bad file is removed for the next run.
            curl -fL --retry 5 -C - -o ${file} \
              https://huggingface.co/${repo}/resolve/${rev}/UD-IQ4_XS/${file} || true
            echo "${sha256}  ${file}" | sha256sum -c || { rm -f ${file}; exit 1; }
          fi
        '') shards)}
        rm -f merged.gguf
        llama-gguf-split --merge ${firstShard} merged.gguf
        rm -f ${lib.concatStringsSep " " (lib.attrNames shards)}
        ollama create ${qwenBase} -f ${baseModelfile}
        rm -f merged.gguf
      fi
      ollama create ${qwen} -f ${modelfile}
    '';
  };

  # Keep both loaded, Qwen first (see above). Ollama has no per-model
  # keep-alive, and every request resets a model's expiry to the request's
  # keep_alive or OLLAMA_KEEP_ALIVE (/v1 requests can't set one), so re-pin
  # more often than the 10-minute default expires. Pinning a loaded model is
  # a no-op. Until the first import finishes there's no Qwen to pin, so
  # gemma4 is pinned regardless.
  systemd.services.ollama-pin-models = {
    description = "Keep Qwen3.8 and gemma4 loaded in ollama";
    after = [ "ollama.service" "ollama-model-loader.service" "ollama-import-qwen38.service" ];
    requires = [ "ollama.service" ];
    serviceConfig = {
      Type = "oneshot";
      DynamicUser = true;
    };
    script =
      let
        pin = model: ''
          ${pkgs.curl}/bin/curl -fsS --retry 10 --retry-connrefused --retry-delay 5 \
            http://127.0.0.1:11434/api/generate \
            -d '{"model":"${model}","keep_alive":-1}' >/dev/null'';
      in
      ''
        ${pin qwen} || true
        ${pin gemma}
      '';
  };
  systemd.timers.ollama-pin-models = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "5min";
    };
  };
}
