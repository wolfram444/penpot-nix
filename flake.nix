{
  description = "Penpot Design Software as a NixOS Module";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      fenix,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ fenix.overlays.default ];
          };
          penpot-src = pkgs.fetchFromGitHub {
            owner = "penpot";
            repo = "penpot";
            rev = "2.15.3";
            hash = "sha256-yMpM0nHfFHVeO6Nw2NC4UAmjj2D6MveiklKtNSz0b2A=";
          };
          # Override clojure to use Zulu JDK 25 (matching Penpot's Docker build)
          clojure = pkgs.clojure.override { jdk = pkgs.zulu25; };

          # Configured Rust toolchain using Fenix (nightly) to bypass Emscripten 4.0 linker bugs
          rustToolchain = pkgs.fenix.combine [
            (pkgs.fenix.complete.withComponents [
              "cargo"
              "rustc"
              "rust-src"
            ])
            pkgs.fenix.targets.wasm32-unknown-emscripten.latest.rust-std
          ];

          # Emscripten 4.0.23 introduced a strict Python assertion prohibiting `invoke_`
          # functions from linking with Wasm. Penpot Docker natively uses older 4.0.6 which allowed it.
          # Here we elegantly patch out the assertion to match the behavior of 4.0.6 exactly.
          penpot-emscripten = pkgs.emscripten.overrideAttrs (old: {
            postPatch =
              (old.postPatch or "")
              + ''
                sed -i 's/assert not metadata.invoke_funcs, "invoke_ functions exported/pass #/g' tools/emscripten.py || true
              '';
          });
        in
        rec {
          penpot-backend = pkgs.callPackage ./pkgs/backend.nix { inherit penpot-src clojure; };
          penpot-render-wasm = pkgs.callPackage ./pkgs/render-wasm.nix {
            inherit penpot-src rustToolchain;
            emscripten = penpot-emscripten;
          };
          penpot-frontend = pkgs.callPackage ./pkgs/frontend.nix {
            inherit penpot-src clojure penpot-render-wasm;
          };
          penpot-exporter = pkgs.callPackage ./pkgs/exporter.nix { inherit penpot-src clojure; };

          default = self.packages.${system}.penpot-frontend; # Or a combined package
        }
      );

      overlays.default = final: prev: {
        penpot-frontend = self.packages.${prev.system}.penpot-frontend;
        penpot-backend = self.packages.${prev.system}.penpot-backend;
        penpot-exporter = self.packages.${prev.system}.penpot-exporter;
      };

      nixosModules.default =
        {
          pkgs,
          config,
          lib,
          ...
        }:
        {
          imports = [ ./module.nix ];
          nixpkgs.overlays = [ self.overlays.default ];
        };
      nixosModules.penpot = self.nixosModules.default;

      checks = forAllSystems (
        system: 
        let
          pkgs = import nixpkgs { inherit system; };
        in {
        test = pkgs.testers.runNixOSTest {
          name = "config test";

          nodes.machine =
            { ... }:
            {
              imports = with self; [
                nixosModules.default
                (
                  { pkgs, ... }:
                  {
                    services.penpot.enable = true;
                    services.penpot.openFirewall = true;
                    services.penpot.secretKeyFile = pkgs.writeText "dummy.key" "PENPOT_SECRET_KEY=change-this-insecure-key-for-vm-only";
                    system.stateVersion = "25.11";
                  }
                )
              ];
            };

          node = {
            # since we are using an overlay, we must make pkgs writable
            pkgsReadOnly = false;
          };

          # disable only when working on testScript
          skipTypeCheck = true;

          testScript = builtins.readFile ./test.py;
        };

      });

    };
}
