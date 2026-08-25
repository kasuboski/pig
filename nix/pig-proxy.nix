{
  lib,
  buildGleamApplication,
  beamMinimalPackages,
  runtimeShell,
  serviceStateDirectory,
}: let
  erlangPackage = beamMinimalPackages.erlang;
  serviceCredentialsPath = "${serviceStateDirectory}/codex_auth.json";
in
  buildGleamApplication {
    src = ../packages/pig_proxy;
    localPackages = [
      ../packages/pig_protocol
      ../packages/pig_transport
    ];
    inherit erlangPackage;

    postInstall = ''
      # Gleam package names use underscores; expose the conventional CLI spelling.
      ln -s pig_proxy "$out/bin/pig-proxy"

      # Run the alternate login module from the same Erlang shipment. The
      # service state path is the default, while an explicit environment value
      # still supports non-service installations.
      cat > "$out/bin/pig-proxy-login" <<EOF
      #!${runtimeShell}
      : "\''${PIG_CODEX_AUTH_PATH:=${serviceCredentialsPath}}"
      export PIG_CODEX_AUTH_PATH
      exec ${erlangPackage}/bin/erl \\
        -pa "$out"/lib/*/ebin \\
        -eval "pig_proxy@@main:run(pig_proxy@codex_login)" \\
        -noshell \\
        -extra "\$@"
      EOF
      chmod +x "$out/bin/pig-proxy-login"
    '';

    meta = {
      description = "OpenAI-compatible LLM proxy for the pig agent ecosystem";
      homepage = "https://github.com/kasuboski/pig";
      license = lib.licenses.asl20;
      mainProgram = "pig-proxy";
      platforms = lib.platforms.unix;
    };
  }
