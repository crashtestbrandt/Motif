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
