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
        muslTarget = if muslPkgs == null then null else muslPkgs.stdenv.hostPlatform.rust.rustcTargetSpec;
        muslLinker =
          if muslPkgs == null then null else "${muslPkgs.stdenv.cc}/bin/${muslPkgs.stdenv.cc.targetPrefix}cc";
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
          packages =
            with pkgs;
            [
              # Elixir
              beam.packages.erlang_28.elixir_1_20
              beam.packages.erlang_28.rebar3
              beam28Packages.erlang

              # Rust
              rust-toolchain

              # Browser tests: Node runs the Playwright driver from
              # assets/node_modules; the browsers come from Nix below.
              nodejs

              # LSPs
              beamPackages.expert
              erlang-language-platform
              rust-analyzer
              yaml-language-server

              # Tools
              watchman
              docker-compose
              yamllint
              pkg-config
              openssl
              shfmt
              shellcheck
              cargo-dist
              git-cliff
              jujutsu
              postgresql
            ]
            ++ lib.optionals stdenv.isLinux [ inotify-tools ];

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

            # Playwright's downloaded browsers do not run on NixOS, so browser
            # tests use the Nix-built ones. Each Playwright release expects
            # specific browser builds, so the npm package in assets/package.json
            # must match the nixpkgs version exactly.
            export PLAYWRIGHT_BROWSERS_PATH="${pkgs.playwright-driver.browsers}"
            export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
            export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=true
            npm_playwright="$(sed -n 's/.*"playwright": *"\([^"]*\)".*/\1/p' "$repo_root/assets/package.json")"
            if [ "$npm_playwright" != "${pkgs.playwright-driver.version}" ]; then
              echo "warning: assets/package.json pins playwright $npm_playwright but nixpkgs provides ${pkgs.playwright-driver.version}; browser tests will not find their browsers" >&2
            fi
          '';

        };
      }
    );
}
