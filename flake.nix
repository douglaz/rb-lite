{
  description = "rb-lite minimal Bash implement/review loop";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.stdenvNoCC.mkDerivation {
            pname = "rb-lite";
            version = "0.1.0";
            src = self;

            dontBuild = true;

            installPhase = ''
              runHook preInstall
              install -Dm755 bin/rb-lite "$out/bin/rb-lite"
              install -Dm644 README.md "$out/share/doc/rb-lite/README.md"
              runHook postInstall
            '';
          };
        }
      );

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/rb-lite";
          meta.description = "Run rb-lite";
        };
      });

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          smoke =
            pkgs.runCommand "rb-lite-smoke"
              {
                nativeBuildInputs = [
                  pkgs.bash
                  pkgs.coreutils
                  pkgs.findutils
                  pkgs.gawk
                  pkgs.git
                  pkgs.gnugrep
                  pkgs.gnused
                ];
              }
              ''
                cp -R ${self} source
                chmod -R u+w source
                cd source

                patchShebangs bin/rb-lite tests/smoke.sh
                bash -n bin/rb-lite
                bash -n tests/smoke.sh
                bash tests/smoke.sh

                mkdir -p "$out"
                printf 'ok\n' > "$out/result"
              '';
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.bashInteractive
              pkgs.coreutils
              pkgs.git
              pkgs.just
              pkgs.ripgrep
            ];
          };
        }
      );

      formatter = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        pkgs.writeShellScriptBin "rb-lite-format" ''
          if [ "$#" -eq 0 ]; then
            exec ${pkgs.nixfmt}/bin/nixfmt flake.nix
          fi

          exec ${pkgs.nixfmt}/bin/nixfmt "$@"
        ''
      );
    };
}
