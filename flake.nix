{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-utils = {
      url = "github:numtide/flake-utils/v1.0.0";
    };

    devenv = {
      url = "github:cachix/devenv";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    zig2nix.url = "github:Cloudef/zig2nix";
  };

  outputs = { self, nixpkgs, devenv, flake-utils, zig2nix, ... } @ inputs:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };
        getErlangLibs =
          erlangPkg:
          let
            erlangPath = "${erlangPkg}/lib/erlang/lib/";
            dirs = builtins.attrNames (builtins.readDir erlangPath);
            interfaceVersion = builtins.head (
              builtins.filter (s: builtins.substring 0 13 s == "erl_interface") dirs
            );
            interfacePath = erlangPath + interfaceVersion;
          in
          {
            path = erlangPath;
            dirs = dirs;
            interface = {
              version = interfaceVersion;
              path = interfacePath;
            };
          };

        version = "0.0.0";

        # Erlang
        erlangLatest = pkgs.erlang_27;
        erlangLibs = getErlangLibs erlangLatest;

        # Zig shit (Incomplete)
        zigLatest = pkgs.zig;
        raylib = pkgs.raylib;
        env = zig2nix.outputs.zig-env.${system} {
          #zig = zig2nix.outputs.packages.${system}.zig.master.bin;
          customRuntimeLibs = [
            pkgs.pkg-config
            erlangLibs
            raylib
          ];
          customRuntimeDeps = [
            erlangLibs
            raylib
          ];
        };
        system-triple = env.lib.zigTripleFromString system;

        mkEnvVars = pkgs: erlangLatest: erlangLibs: raylib: {
          LOCALE_ARCHIVE = pkgs.lib.optionalString pkgs.stdenv.isLinux "${pkgs.glibcLocales}/lib/locale/locale-archive";
          LANG = "en_US.UTF-8";
          # https://www.erlang.org/doc/man/kernel_app.html
          ERL_AFLAGS = "-kernel shell_history enabled";
          ERL_INCLUDE_PATH = "${erlangLatest}/lib/erlang/usr/include";
        };
      in
      {
        # TODO: finish this
        # nix build
        packages = {
          devenv-up = self.devShells.${system}.default.config.procfileScript;

          # nix build .#zerl
          zerl = pkgs.stdenv.mkDerivation {
            pname = "zerl";
            version = version;
            src = env.pkgs.lib.cleanSource ./.;

            nativeBuildInputs = [
              pkgs.makeBinaryWrapper
              zigLatest.hook
            ];
            buildInputs = [
              erlangLatest
            ];

            # Uncomment this to generate .nix from zon
            # nix run github:Cloudef/zig2nix#zon2nix -- build.zig.zon > zon-deps.nix
            #postPatch = ''
            #  ln -s ${pkgs.callPackage ./zon-deps.nix { }} $ZIG_GLOBAL_CACHE_DIR/p
            #'';
          };
        };

        # nix run
        apps = {
          packages.default = env.lib.packages.target.${system-triple}.override {
            # Prefer nix friendly settings.
            zigPreferMusl = false;
            zigDisableWrap = false;
          };

          # nix run .#build
          apps.build = env.app [ ] "zig build -- \"$@\"";

          # nix run .#test
          apps.test = env.app [ ] "zig build test -- \"$@\"";
        };

        devShells =
          let
            linuxPkgs = with pkgs; [
              inotify-tools
              xorg.libX11
              xorg.libXrandr
              xorg.libXinerama
              xorg.libXcursor
              xorg.libXi
              xorg.libXi
              libGL
            ];
            darwinPkgs = with pkgs.darwin.apple_sdk.frameworks; [
              CoreFoundation
              CoreServices
            ];
          in
          {
            # `nix develop .#ci`
            # reduce the number of packages to the bare minimum needed for CI
            ci = pkgs.mkShell {
              env = mkEnvVars pkgs erlangLatest erlangLibs raylib;
              buildInputs = with pkgs; [
                erlangLatest
                just
                rebar3
                zigLatest
              ];
            };

            # `nix develop`
            default = devenv.lib.mkShell {
              inherit inputs pkgs;
              modules = [
                (
                  { pkgs, lib, ... }:
                  {
                    packages =
                      with pkgs;
                      [
                        just
                      ]
                      ++ lib.optionals stdenv.isLinux (linuxPkgs)
                      ++ lib.optionals stdenv.isDarwin darwinPkgs;

                    languages.erlang = {
                      enable = true;
                      package = erlangLatest;
                    };

                    languages.zig = {
                      enable = true;
                      package = zigLatest;
                    };

                    env = mkEnvVars pkgs erlangLatest erlangLibs raylib;

                    scripts = {
                      build.exec = "just build";
                      client.exec = "just test";
                      server.exec = "just server";
                    };

                    enterShell = ''
                      echo "Starting Development Environment..."
                    '';
                  }
                )
              ];
            };
          };

        # nix fmt
        formatter = pkgs.nixfmt-rfc-style;
      }
    );
}
