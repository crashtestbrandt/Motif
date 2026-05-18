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
