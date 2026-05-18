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
