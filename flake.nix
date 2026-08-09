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

        muslPkgs =
          if system == "x86_64-linux" then
            pkgs.pkgsCross.musl64
          else if system == "aarch64-linux" then
            pkgs.pkgsCross.aarch64-multiplatform-musl
          else
            null;
        muslTarget =
          if muslPkgs == null then null else muslPkgs.stdenv.hostPlatform.rust.rustcTargetSpec;
        muslLinker =
          if muslPkgs == null then
            null
          else
            "${muslPkgs.stdenv.cc}/bin/${muslPkgs.stdenv.cc.targetPrefix}cc";
        muslLinkerEnv =
          if muslTarget == null then
            null
          else
            "CARGO_TARGET_${pkgs.lib.toUpper (builtins.replaceStrings [ "-" ] [ "_" ] muslTarget)}_LINKER";

        rust-toolchain = pkgs.rust-bin.stable."1.96.0".default.override {
          extensions = [
            "rust-src"
            "rust-analyzer"
            "clippy"
            "rustfmt"
          ];
          targets = pkgs.lib.optionals (muslTarget != null) [ muslTarget ];
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
            cargo-dist
            git-cliff
            postgresql
          ];

          shellHook = ''
            repo_root="$(git rev-parse --show-toplevel)"
            export MIX_HOME="$repo_root/.nix/mix"
            export HEX_HOME="$repo_root/.nix/hex"
            export REBAR_CACHE_DIR="$repo_root/.nix/rebar3"
            export ERL_AFLAGS="-kernel shell_history enabled"
            ${pkgs.lib.optionalString (muslLinker != null) ''
              export ${muslLinkerEnv}="${muslLinker}"
            ''}

            mkdir -p "$MIX_HOME" "$HEX_HOME" "$REBAR_CACHE_DIR"
          '';

        };
      }
    );
}
