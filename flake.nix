{
  description = "motif — multiplayer AI-driven tabletop RPG engine prototype";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      # Match the version pins in .tool-versions as closely as nixpkgs allows.
      # Patch versions track nixpkgs HEAD; exact major.minor stays stable.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system: f (import nixpkgs { inherit system; }));
    in {
      devShells = forAllSystems (pkgs:
        let
          beam = pkgs.beam.packages.erlang_27;
        in {
          default = pkgs.mkShell {
            name = "motif-dev";

            # Just the BEAM toolchain. Docker, Neo4j, and your self-hosted
            # LLM server are intentionally outside the flake — they're
            # external services, not dev-shell tools.
            packages = [
              beam.erlang
              beam.elixir_1_17
              pkgs.git
              pkgs.jq    # handy for poking at /sessions/:id/rpc responses
            ];

            shellHook = ''
              # Keep Mix metadata project-local. The global ~/.mix is not
              # touched, so this flake is safe to enter on a machine that
              # also has system-wide Elixir installed.
              export MIX_HOME="$PWD/.nix-mix"
              export HEX_HOME="$PWD/.nix-hex"
              export PATH="$MIX_HOME/escripts:$HEX_HOME/bin:$PATH"

              mkdir -p "$MIX_HOME" "$HEX_HOME"

              # First-time-only: install hex + rebar into the project-local
              # Mix dir. Idempotent — subsequent shell entries skip it.
              if [ ! -d "$MIX_HOME/archives" ]; then
                mix local.hex --force  >/dev/null
                mix local.rebar --force >/dev/null
                echo "[motif] installed hex + rebar into $MIX_HOME"
              fi

              if [ -t 1 ]; then
                echo "[motif] $(elixir --version | tail -1)"
                echo "[motif] dev shell ready — next steps:"
                echo "        mix deps.get"
                echo "        docker compose up -d --wait      # Neo4j"
                echo "        mix test"
              fi
            '';
          };
        });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-rfc-style);
    };
}
