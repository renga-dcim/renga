{
  description = "Renga - DCIM";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      rust-overlay,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
          overlays = [ rust-overlay.overlays.default ];
        };

        rust-toolchain = pkgs.rust-bin.stable."1.96.0".default.override {
          extensions = [
            "rust-src"
            "rust-analyzer"
            "clippy"
            "rustfmt"
          ];
        };
      in
      {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            # Elixir
            beam.packages.erlang_28.elixir_1_20
            beam.packages.erlang_28.rebar3
            erlang_28

            # Rust
            rust-toolchain

            # LSPs
            beamPackages.expert
            erlang-language-platform
            rust-analyzer
            yaml-language-server

            # Tools
            watchman
            docker-compose
            inotify-tools
            yamllint
            pkg-config
            openssl
            shfmt
            shellcheck
            git-cliff
            postgresql
          ];

          shellHook = ''
            repo_root="$(git rev-parse --show-toplevel)"
            export MIX_HOME="$repo_root/.nix/mix"
            export HEX_HOME="$repo_root/.nix/hex"
            export REBAR_CACHE_DIR="$repo_root/.nix/rebar3"
            export ERL_AFLAGS="-kernel shell_history enabled"

            mkdir -p "$MIX_HOME" "$HEX_HOME" "$REBAR_CACHE_DIR"
          '';

        };
      }
    );
}
