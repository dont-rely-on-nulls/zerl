{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    devenv = {
      url = "github:cachix/devenv";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    zig2nix.url = "github:Cloudef/zig2nix";
  };

  outputs = { self, nixpkgs, devenv, zig2nix, ... } @ inputs:
    let
      systems = [ "x86_64-linux" "x86_64-darwin" "aarch64-linux" "aarch64-darwin" ];
      forAllSystems = f: builtins.listToAttrs (map (name: { inherit name; value = f name; }) systems);
      getErlangLibs = erlangPkg:
        let
            erlangPath = "${erlangPkg}/lib/erlang/lib/";
            dirs = builtins.attrNames (builtins.readDir erlangPath);
            interfaceVersion = builtins.head (builtins.filter (s: builtins.substring 0 13 s == "erl_interface") dirs);
            interfacePath = erlangPath + interfaceVersion;
        in
        {
            path = erlangPath;
            dirs = dirs;
            interface = { version = interfaceVersion; path = interfacePath; };
        };

      mkEnvVars = pkgs: erlangLatest: erlangLibs:  {
        LOCALE_ARCHIVE = pkgs.lib.optionalString pkgs.stdenv.isLinux "${pkgs.glibcLocales}/lib/locale/locale-archive";
        LANG = "en_US.UTF-8";
        # https://www.erlang.org/doc/man/kernel_app.html
        ERL_AFLAGS = "-kernel shell_history enabled";
        ERL_INCLUDE_PATH = "${erlangLatest}/lib/erlang/usr/include";
        ERLANG_INTERFACE_PATH = "${erlangLibs.interface.path}";
        ERLANG_PATH = "${erlangLatest}";
      };
    in
      {
        packages = forAllSystems (system:
          let
            pkgs = nixpkgs.legacyPackages."${system}";
            env = zig2nix.outputs.zig-env.${system} {};
            system-triple = env.lib.zigTripleFromString system;
          in {
            devenv-up = self.devShells.${system}.default.config.procfileScript;
          });

      apps = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          erlangLatest = pkgs.erlang_27;
          erlangLibs = getErlangLibs erlangLatest;

          env = zig2nix.outputs.zig-env.${system} {};
          system-triple = env.lib.zigTripleFromString system;
          zigLatest = pkgs.zig;
        in {
          packages.default = env.lib.packages.target.${system-triple}.override {
            # Prefer nix friendly settings.
            zigPreferMusl = false;
            zigDisableWrap = false;
          };

          # nix run .#build
          apps.build = env.app [] "zig build --search-prefix ${erlangLatest} \"$@\"";

          # nix run .#test
          apps.test = env.app [] "zig build --search-prefix ${erlangLatest} test -- \"$@\"";
        });

      devShells = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          erlangLatest = pkgs.erlang_27;
          erlangLibs = getErlangLibs erlangLatest;

          env = zig2nix.outputs.zig-env.${system} {};
          system-triple = env.lib.zigTripleFromString system;
          zigLatest = pkgs.zig;

        in
        {
          # `nix develop .#ci`
          # reduce the number of packages to the bare minimum needed for CI
          ci = pkgs.mkShell {
            env = mkEnvVars pkgs erlangLatest erlangLibs ;
            buildInputs = with pkgs; [ erlangLatest rebar3 zigLatest ];
          };

          # `nix develop`
          default = devenv.lib.mkShell {
            inherit inputs pkgs;
            modules = [
              ({ pkgs, lib, ... }: {
                packages = with pkgs; [
                  erlang-ls
                  erlfmt
                  rebar3
                ];

                languages.erlang = {
                  enable = true;
                  package = erlangLatest;
                };

                languages.zig = {
                  enable = true;
                  package = zigLatest;
                };

                env = mkEnvVars pkgs erlangLatest erlangLibs ;

                # scripts = {
                #   build.exec = "just build";
                #   server.exec = "just server";
                # };

                enterShell = ''
                  echo "Starting Erlang environment..."
                  rebar3 get-deps
                '';

              })
            ];
          };
        });
    };
}
