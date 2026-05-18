# Umbrella-wide compile-time configuration. All apps share this file
# (per Mix umbrella convention). Runtime overrides live in config/runtime.exs.
import Config

# Boltx connection to Neo4j. Defaults match docker-compose.yml dev creds.
# runtime.exs reads NEO4J_URI / NEO4J_USER / NEO4J_PASSWORD env vars if set.
config :boltx, MotifEngine.Bolt,
  uri: "bolt://localhost:7687",
  auth: [username: "neo4j", password: "motifdev"],
  pool_size: 10,
  name: MotifEngine.Bolt

# motif_mcp HTTP listener. SSE deferred (see ADR-0013); milestone-4 uses
# request/response JSON-RPC. The port is bound to 127.0.0.1 only.
config :motif_mcp,
  http_ip: {127, 0, 0, 1},
  http_port: 4001

# motif_web Phoenix endpoint.
config :motif_web, MotifWeb.Endpoint,
  url: [host: "localhost"],
  http: [ip: {127, 0, 0, 1}, port: 4000],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: MotifWeb.ErrorHTML],
    layout: false
  ],
  pubsub_server: Motif.PubSub,
  live_view: [signing_salt: "motif-dev-signing-salt"],
  secret_key_base: "motif-dev-secret-key-base-please-replace-in-prod-this-is-just-for-dev",
  server: true

config :motif_web,
  mcp_base_url: "http://127.0.0.1:4001",
  # Self-hosted, OpenAI-compatible inference endpoint (ADR-0014).
  # Dev default: LM Studio. Override via LLM_BASE_URL / LLM_MODEL at runtime.
  llm_base_url: "http://127.0.0.1:1234/v1",
  llm_model: "local-model"

config :phoenix, :json_library, Jason
