# opencode, with argo's ollama models as a provider alongside the hosted ones.
#
# opencode reaches ollama through the OpenAI-compatible /v1 API, so requests
# get ollama's OLLAMA_CONTEXT_LENGTH (262144 on argo, both models' native
# context) rather than a per-request num_ctx.
{ localPkgs, ... }:
let
  qwen = "ollama/qwen3.6:35b-a3b";
  gemma = "ollama/gemma4:26b-a4b";
in
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
          "qwen3.6:35b-a3b".name = "Qwen 3.6 35B-A3B";
          "gemma4:26b-a4b".name = "Gemma 4 26B-A4B";
        };
      };

      # A primary agent on qwen3.6 whose subagents run on gemma4. Ollama gives
      # qwen3.6 a single slot, so subagents inheriting it (opencode's default)
      # would queue behind the agent that launched them; gemma4 has parallel
      # slots. Select it with Tab.
      agent = {
        local = {
          mode = "primary";
          description = "Build agent on argo's qwen3.6, with subagents on gemma4";
          model = qwen;
          permission.task = {
            "*" = "deny";
            "local-*" = "allow";
          };
        };
        local-general = {
          mode = "subagent";
          hidden = true;
          description = "General-purpose agent for researching complex questions and executing multi-step tasks, including running several units of work in parallel";
          model = gemma;
        };
        local-explore = {
          mode = "subagent";
          hidden = true;
          description = "Fast read-only agent for exploring codebases: finding files by pattern, searching code for keywords, and answering questions about how the code works";
          model = gemma;
          permission = {
            edit = "deny";
            bash = "deny";
          };
        };
      };
    };
  };
}
