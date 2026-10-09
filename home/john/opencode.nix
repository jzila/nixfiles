# opencode, with argo's ollama models as a provider alongside the hosted ones.
#
# opencode reaches ollama through the OpenAI-compatible /v1 API, so requests
# get ollama's OLLAMA_CONTEXT_LENGTH (262144 on argo, both models' native
# context) rather than a per-request num_ctx.
{ localPkgs, ... }:
{
  programs.opencode = {
    enable = true;
    # Release-archive build defined once in flake.nix (see mkLocalPackages).
    package = localPkgs.opencode-bin;
    settings.provider.ollama = {
      npm = "@ai-sdk/openai-compatible";
      name = "Ollama (argo)";
      options.baseURL = "http://argo.local.zila.dev:11434/v1";
      models = {
        "qwen3.6:35b-a3b".name = "Qwen 3.6 35B-A3B";
        "gemma4:26b-a4b".name = "Gemma 4 26B-A4B";
      };
    };
  };
}
