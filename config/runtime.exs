# Runtime configuration — evaluated at boot time (after compile),
# so it can read environment variables. Keep all secrets here.
import Config

if uri = System.get_env("NEO4J_URI") do
  username = System.get_env("NEO4J_USER", "neo4j")
  password = System.fetch_env!("NEO4J_PASSWORD")

  config :boltx, MotifEngine.Bolt,
    uri: uri,
    auth: [username: username, password: password]
end

# Self-hosted LLM endpoint configuration (ADR-0014). All optional —
# defaults from compile-time config target LM Studio on localhost.
if base = System.get_env("LLM_BASE_URL"), do: config(:motif_web, llm_base_url: base)
if model = System.get_env("LLM_MODEL"), do: config(:motif_web, llm_model: model)

# LLM_API_KEY is optional; most self-hosted servers don't require one.
# Provide it if the endpoint is behind a gateway that does.
if key = System.get_env("LLM_API_KEY"), do: config(:motif_web, llm_api_key: key)
