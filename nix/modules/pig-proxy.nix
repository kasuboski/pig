{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.pig-proxy;
  stateDirectory = toString cfg.stateDirectory;
  credentialsPath = "${stateDirectory}/codex_auth.json";
  serviceTools = pkgs.runCommand "pig-proxy-service-tools" {} ''
    mkdir -p "$out/bin"
    ln -s ${cfg.package}/bin/pig-proxy "$out/bin/pig-proxy"
    cat > "$out/bin/pig-proxy-login" <<'EOF'
    #!${pkgs.runtimeShell}
    export PIG_CODEX_AUTH_PATH=${lib.escapeShellArg credentialsPath}
    exec ${cfg.package}/bin/pig-proxy-login "$@"
    EOF
    chmod +x "$out/bin/pig-proxy-login"
  '';
in {
  options.services.pig-proxy = {
    enable = lib.mkEnableOption "the pig OpenAI-compatible LLM proxy";

    package = lib.mkOption {
      type = lib.types.package;
      description = "The pig-proxy package to run.";
    };

    stateDirectory = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/pig-proxy";
      description = ''
        Persistent state directory containing rotating Codex credentials.
        The directory is created with owner-only permissions and may be any
        absolute path, such as a location managed by impermanence.
      '';
    };

    bind = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address on which pig-proxy listens.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "TCP port on which pig-proxy listens.";
    };

    upstreamBaseUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://localhost:11434/v1";
      description = "Base URL of the OpenAI-compatible upstream.";
    };

    provider = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "openai";
      description = "Optional models.dev provider key used for cost metrics.";
    };

    codex = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Use persisted ChatGPT/Codex OAuth credentials for the upstream.";
    };

    retriesPerTarget = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 1;
      description = "Additional attempts per upstream target before fallback.";
    };

    modelsDevUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://models.dev/api.json";
      description = "URL of the models.dev model and pricing catalog.";
    };

    modelsRefreshMs = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3600000;
      description = "Model catalog refresh interval in milliseconds.";
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/run/secrets/pig-proxy.env";
      description = ''
        Runtime environment file containing secrets such as
        OPENAI_COMPAT_API_KEY or OPENAI_COMPAT_CODEX_TOKEN. Its contents must
        not be produced by a Nix store derivation.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open the configured TCP port in the NixOS firewall.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.hasPrefix "/" stateDirectory;
        message = "services.pig-proxy.stateDirectory must be an absolute path";
      }
    ];

    warnings =
      lib.optional (cfg.openFirewall && cfg.bind == "127.0.0.1")
      "services.pig-proxy.openFirewall has no effect while bind is 127.0.0.1";

    users.groups.pig-proxy = {};
    users.users.pig-proxy = {
      isSystemUser = true;
      group = "pig-proxy";
      home = stateDirectory;
      description = "pig-proxy service user";
    };

    environment.systemPackages = [serviceTools];

    systemd.tmpfiles.settings."10-pig-proxy".${stateDirectory}.d = {
      user = "pig-proxy";
      group = "pig-proxy";
      mode = "0700";
    };

    networking.firewall.allowedTCPPorts = lib.optional cfg.openFirewall cfg.port;

    systemd.services.pig-proxy = {
      description = "pig OpenAI-compatible LLM proxy";
      documentation = ["https://github.com/kasuboski/pig/tree/main/packages/pig_proxy"];
      wantedBy = ["multi-user.target"];
      wants = ["network-online.target"];
      after = ["network-online.target"];

      environment =
        {
          PIG_PROXY_BIND = cfg.bind;
          PIG_PROXY_PORT = toString cfg.port;
          PIG_PROXY_RETRIES_PER_TARGET = toString cfg.retriesPerTarget;
          PIG_PROXY_MODELS_DEV_URL = cfg.modelsDevUrl;
          PIG_PROXY_MODELS_REFRESH_MS = toString cfg.modelsRefreshMs;
          PIG_CODEX_AUTH_PATH = credentialsPath;
          OPENAI_COMPAT_BASE_URL = cfg.upstreamBaseUrl;
        }
        // lib.optionalAttrs (cfg.provider != null) {
          OPENAI_COMPAT_PROVIDER = cfg.provider;
        }
        // lib.optionalAttrs cfg.codex {
          OPENAI_COMPAT_CODEX = "true";
        };

      serviceConfig =
        {
          ExecStart = "${cfg.package}/bin/pig-proxy";
          User = "pig-proxy";
          Group = "pig-proxy";
          WorkingDirectory = stateDirectory;
          ReadWritePaths = [stateDirectory];
          UMask = "0077";
          Restart = "on-failure";
          RestartSec = "5s";

          NoNewPrivileges = true;
          PrivateDevices = true;
          PrivateTmp = true;
          ProtectControlGroups = true;
          ProtectHome = true;
          ProtectKernelLogs = true;
          ProtectKernelModules = true;
          ProtectKernelTunables = true;
          ProtectSystem = "strict";
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          LockPersonality = true;
          CapabilityBoundingSet = "";
          AmbientCapabilities = "";
        }
        // lib.optionalAttrs (cfg.environmentFile != null) {
          EnvironmentFile = cfg.environmentFile;
        };
    };
  };
}
