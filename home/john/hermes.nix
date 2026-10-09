# Hermes Agent (Nous Research), from its upstream flake, running against the
# ollama on argo.
#
# Hermes talks to ollama through the OpenAI-compatible /v1 API, which cannot
# set num_ctx per request: ollama falls back to OLLAMA_CONTEXT_LENGTH. Hermes
# wants at least 64k of context. argo pins OLLAMA_CONTEXT_LENGTH to the same
# 262144 (gemma4's native context) that context_length declares here, and Home
# Assistant's agent asks for the same, so every client gets the one loaded
# gemma4 instance instead of ollama reloading it whenever the context size
# changes.
{ hermes-agent, ... }:
{
  imports = [ hermes-agent.homeManagerModules.default ];

  # Puts `hermes` on PATH with HERMES_HOME set; state lives in ~/.hermes.
  programs.hermes-agent.enable = true;

  # Writes the settings below into ~/.hermes/config.yaml on activation (a deep
  # merge, so keys set at runtime with `hermes config set` survive).
  services.hermes-agent.enable = true;

  services.hermes-agent.settings.model = {
    provider = "custom";
    base_url = "http://argo.local.zila.dev:11434/v1";
    default = "gemma4:26b-a4b";
    context_length = 262144;
  };
}
