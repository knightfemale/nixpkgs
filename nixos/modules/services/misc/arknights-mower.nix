{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.arknights-mower;

  adbPath = lib.getExe' pkgs.android-tools "adb";

  tokenEnv = lib.optional (cfg.token != null) "MOWER_TOKEN=${cfg.token}";

  # MAA namespace: enable controls provisioning, package chooses the MAA distribution.
  maaEnable = cfg.maa-assistant-arknights.enable;
  maaPkg = cfg.maa-assistant-arknights.package;
  # `package` is a non-nullable lib.types.package, so provisioning is active exactly when the
  # enable toggle is on.
  maaActive = maaEnable;

  # Assemble the MAA distribution into a writable dir under the service state dir.
  # Share assets must be symlinked individually (not the whole tree) and lib/* must
  # be symlinked per-file so the dynamically-linked MaaCore/Framework libraries are
  # resolvable by the app's bare load paths. Idempotent: ln -sfn overwrites stale
  # symlinks; skipped entirely when MAA provisioning is inactive (maaActive = false).
  # nullglob keeps the lib/* loop from producing a literal `*` symlink if the lib dir
  # is missing/empty.
  maaAssemble = lib.optionalString maaActive ''
    shopt -s nullglob
    mkdir -p "${cfg.stateDir}/maa/cache"
    ln -sfn "${maaPkg}/share/${maaPkg.pname}/Python" "${cfg.stateDir}/maa/Python"
    ln -sfn "${maaPkg}/share/${maaPkg.pname}/resource" "${cfg.stateDir}/maa/resource"
    for f in "${maaPkg}"/lib/*; do
      ln -sfn "$f" "${cfg.stateDir}/maa/$(basename "$f")"
    done
  '';

  # Overwrite maa_path and/or maa_adb_path in an existing conf.yml on warm start.
  confRewrite =
    if maaActive then
      ''
        sed -i -e 's|^\(\s*maa_path:\s*\).*|\1${cfg.stateDir}/maa|' -e 's|^\(\s*maa_adb_path:\s*\).*|\1${adbPath}|' "$conf"
      ''
    else
      ''
        sed -i 's|^\(\s*maa_adb_path:\s*\).*|\1${adbPath}|' "$conf"
      '';

  # Seed conf.yml on cold start when it does not exist yet.
  confSeed =
    if maaActive then
      ''
        printf 'maa_path: %s\nmaa_adb_path: %s\n' '${cfg.stateDir}/maa' '${adbPath}' > "$conf"
      ''
    else
      ''
        printf 'maa_adb_path: %s\n' '${adbPath}' > "$conf"
      '';
in
{
  options.services.arknights-mower = {
    enable = lib.mkEnableOption "Arknights Mower web-only service (no desktop GUI / agent / LLM)";

    package = lib.mkPackageOption pkgs "arknights-mower" {
      extraDescription = "Full-stack bundle: backend (pure API, agent/desktop GUI/LLM removed) + Vue frontend (ui/dist) + entry script `mower`. Frontend build requires network access to fetch npm dependencies (npmDepsHash pre-computed).";
    };

    maa-assistant-arknights = {
      enable = lib.mkEnableOption "MAA (MaaAssistantArknights) runtime provisioning for arknights-mower";

      package = lib.mkPackageOption pkgs "maa-assistant-arknights" {
        extraDescription = ''
          The MAA distribution installs its share/.../<pname>/{Python,resource} and lib/*
          outputs; when `enable` is true the service assembles these into
          `${cfg.stateDir}/maa/` (a writable directory under the service data dir) and points
          conf.yml's `maa_path` there. When `enable` is false (the default) MAA provisioning is
          skipped and conf.yml carries only `maa_adb_path`, matching the pre-MAA behaviour.
        '';
      };
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 58000;
      example = 58000;
      description = "Listening port (default 58000).";
    };

    token = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "my-access-token";
      description = ''
        Access token. When set, the service listens on 0.0.0.0 and injects it via MOWER_TOKEN into webserver.py; all API routes require it in the request header. When unset, listens on 127.0.0.1 only.
      '';
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--host 192.168.1.10" ];
      description = "Extra arguments passed to the entry script (forwarded to webserver.py).";
    };

    stateDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/arknights-mower";
      defaultText = "/var/lib/arknights-mower";
      example = "/srv/arknights-mower";
      description = "Service data/config directory (owned by mower, created by tmpfiles).";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.mower = {
      isSystemUser = true;
      group = "mower";
      home = cfg.stateDir;
    };
    users.groups.mower = { };

    systemd.services.arknights-mower = {
      wantedBy = [ "multi-user.target" ];
      description = "Arknights Mower Web-only Service";
      after = [ "network.target" ];
      wants = [ "network.target" ];
      serviceConfig = {
        ExecStart = "${lib.getExe cfg.package} ${lib.escapeShellArgs cfg.extraArgs}";
        Restart = "on-failure";
        RestartSec = 5;

        # The app reads maa_adb_path from conf.yml and invokes it via subprocess with no PATH
        # fallback. Overwrite the value each start so it always points to the NixOS-supplied adb
        # binary. On the first (cold) start conf.yml does not exist yet and the application itself
        # creates it with the Windows default, so seed it here: ConfModel.nested_defaults fills in
        # every remaining field with its default when the file only contains maa_adb_path. The
        # maa_path default is also a Windows path, so it is seeded/overwritten to the MAA runtime
        # assembled into ${cfg.stateDir}/maa.
        ExecStartPre = pkgs.writeShellScript "arknights-mower-prestart" ''
          conf="${cfg.stateDir}/conf.yml"

          ${maaAssemble}

          if [ -f "$conf" ]; then
            ${confRewrite}
          else
            mkdir -p "${cfg.stateDir}"
            ${confSeed}
          fi
        '';

        Environment = [
          "MOWER_PORT=${toString cfg.port}"
          "MOWER_DATA_DIR=${cfg.stateDir}"
        ]
        ++ tokenEnv;
        User = "mower";
        Group = "mower";
        RuntimeDirectory = "mower";
        WorkingDirectory = cfg.stateDir;

        # CPU Python service, connects to an external adb over TCP loopback and
        # spawns adb/sh subprocesses; see comfyui.nix for the same relaxations.
        CapabilityBoundingSet = [ "" ];
        LockPersonality = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = "tmpfs";
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        ProtectSystem = "strict";
        RemoveIPC = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [ "@system-service" ];
        ReadWritePaths = [ cfg.stateDir ];
        BindReadOnlyPaths = [ "/proc/cpuinfo" ];
        PrivateDevices = false;
        ProcSubset = "all";
      };
    };

    # Pre-create data subdirectories.  systemd does not auto-create WorkingDirectory
    # or subdirectories; tmpfiles rules create them at boot (owned by mower:mower).
    # The app does not self-create these: skland check-in writes @app/tmp/skland.csv
    # via cron (not the start route that creates @app/tmp), so a missing tmp dir causes
    # "Cannot save file into a non-existent directory"; log.py and screenshot also need
    # the directories pre-existing.
    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0700 mower mower - -"
      "d ${cfg.stateDir}/log 0700 mower mower - -"
      "d ${cfg.stateDir}/screenshot 0700 mower mower - -"
      "d ${cfg.stateDir}/tmp 0700 mower mower - -"
    ];

    networking.firewall.allowedTCPPorts = lib.mkIf (cfg.token != null) [ cfg.port ];
  };

  meta.maintainers = pkgs.arknights-mower.meta.maintainers;
}
