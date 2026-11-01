# opencode, with argo's ollama models as a provider alongside the hosted ones.
#
# opencode reaches ollama through the OpenAI-compatible /v1 API, so requests
# get the model's own num_ctx (131072 for Qwen3.8) or ollama's
# OLLAMA_CONTEXT_LENGTH (65536 on argo) rather than a per-request num_ctx.
{ localPkgs, ... }:
{
  programs.opencode = {
    enable = true;
    # Release-archive build defined once in flake.nix (see mkLocalPackages).
    package = localPkgs.opencode-bin;
    settings = {
      provider.ollama = {
        npm = "@ai-sdk/openai-compatible";
        name = "Ollama (argo)";
        options.baseURL = "http://argo.local.zila.dev:11434/v1";
        models = {
          "qwen3.8-flash-next:iq4xs".name = "Qwen 3.8 Flash Next 125B-A6B";
          "gemma4:26b-a4b".name = "Gemma 4 26B-A4B";
        };
      };

      # A primary agent on argo's Qwen3.8; its subagents inherit the model.
      # Ollama gives each model one slot (hosts/argo/configuration.nix), so
      # parallel subagents take turns, and they share it with Hermes.
      # gemma4's slot belongs to Home Assistant. Select it with Tab.
      agent.local = {
        mode = "primary";
        description = "Build agent on argo's Qwen3.8";
        model = "ollama/qwen3.8-flash-next:iq4xs";
      };
    };
  };
}
