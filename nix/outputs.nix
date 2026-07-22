{
  self,
  nixpkgs,
  nix-gleam,
  ...
}: let
  defaults = import ./defaults.nix;
  forAllSystems = nixpkgs.lib.genAttrs nixpkgs.lib.systems.flakeExposed;
in {
  packages = forAllSystems (
    system: let
      pig-proxy = nixpkgs.legacyPackages.${system}.callPackage ./pig-proxy.nix {
        inherit (nix-gleam.packages.${system}) buildGleamApplication;
        serviceStateDirectory = defaults.stateDirectory;
      };
    in {
      inherit pig-proxy;
      default = pig-proxy;
    }
  );

  apps = forAllSystems (system: {
    pig-proxy = {
      type = "app";
      program = "${self.packages.${system}.pig-proxy}/bin/pig-proxy";
      meta.description = "Run the pig OpenAI-compatible LLM proxy";
    };
    pig-proxy-login = {
      type = "app";
      program = "${self.packages.${system}.pig-proxy}/bin/pig-proxy-login";
      meta.description = "Authenticate pig-proxy with ChatGPT/Codex OAuth";
    };
    default = self.apps.${system}.pig-proxy;
  });

  checks = forAllSystems (
    system: let
      pkgs = nixpkgs.legacyPackages.${system};
      moduleConfig = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          self.nixosModules.pig-proxy
          {
            system.stateVersion = "26.05";
            services.pig-proxy = {
              enable = true;
              codex = true;
              stateDirectory = "/persist/pig-proxy";
              upstreamBaseUrl = "https://chatgpt.com/backend-api/codex";
              environmentFile = "/run/secrets/pig-proxy.env";
            };
          }
        ];
      };
      defaultModuleConfig = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          self.nixosModules.pig-proxy
          {
            system.stateVersion = "26.05";
            services.pig-proxy.enable = true;
          }
        ];
      };
      moduleCheck = assert toString defaultModuleConfig.config.services.pig-proxy.stateDirectory
      == defaults.stateDirectory;
      assert moduleConfig.config.systemd.services.pig-proxy.environment.PIG_CODEX_AUTH_PATH
      == "/persist/pig-proxy/codex_auth.json";
      assert moduleConfig.config.systemd.services.pig-proxy.serviceConfig.ReadWritePaths
      == ["/persist/pig-proxy"];
      assert moduleConfig.config.users.users.pig-proxy.home
      == "/persist/pig-proxy";
      assert moduleConfig.config.systemd.tmpfiles.settings."10-pig-proxy"."/persist/pig-proxy".d.user
      == "pig-proxy";
      assert moduleConfig.config.systemd.tmpfiles.settings."10-pig-proxy"."/persist/pig-proxy".d.group
      == "pig-proxy";
      assert moduleConfig.config.systemd.tmpfiles.settings."10-pig-proxy"."/persist/pig-proxy".d.mode
      == "0700";
      assert moduleConfig.config.systemd.services.pig-proxy.serviceConfig.EnvironmentFile
      == "/run/secrets/pig-proxy.env";
        pkgs.runCommand "pig-proxy-module-check" {} "touch $out";
    in
      {
        inherit (self.packages.${system}) pig-proxy;
      }
      // nixpkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        pig-proxy-module = moduleCheck;
      }
  );

  formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.alejandra);

  nixosModules = {
    pig-proxy = {
      lib,
      pkgs,
      ...
    }: {
      imports = [./modules/pig-proxy.nix];
      _module.args.pigProxyDefaults = defaults;
      services.pig-proxy.package =
        lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.pig-proxy;
    };
    default = self.nixosModules.pig-proxy;
  };
}
