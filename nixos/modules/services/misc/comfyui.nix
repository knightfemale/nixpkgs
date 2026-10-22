{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.comfyui;

  # By default a StateDirectory is used; anything else needs its own directory and a hole in the unit's mount namespace.
  isDefaultDataDir = cfg.dataDir == "/var/lib/comfyui";

  package = cfg.package.override (oldArgs: {
    extraPackages =
      ps:
      lib.unique (
        (oldArgs.extraPackages or (_: [ ])) ps
        ++ cfg.extraPackages ps
        ++ lib.concatMap (node: node.extraPackages ps) cfg.customNodes
      );
  });

  modelDrvs = map (m: {
    inherit m;
    drv = pkgs.fetchurl (lib.filterAttrs (n: _: n == "name" || n == "url" || n == "hash") m);
  }) cfg.models;

  modelSymlinks = lib.concatMapStringsSep "\n" (
    x:
    lib.concatMapStringsSep "\n" (p: ''
      mkdir -p ${lib.escapeShellArg "${cfg.dataDir}/models/${p}"}
      ln -sn ${lib.escapeShellArg "${x.drv}"} ${lib.escapeShellArg "${cfg.dataDir}/models/${p}/${x.m.name}"}
    '') x.m.installPaths
  ) modelDrvs;

  customNodeSymlinks = lib.concatMapStringsSep "\n" (node: ''
    if [[ ! -d ${lib.escapeShellArg "${node.src}"} ]]; then
      echo "services.comfyui.customNodes.${node.name}: source is not a directory: ${node.src}" >&2
      exit 1
    fi
    if [[ -e ${lib.escapeShellArg "${cfg.dataDir}/custom_nodes/${node.name}"} || -L ${lib.escapeShellArg "${cfg.dataDir}/custom_nodes/${node.name}"} ]]; then
      echo "services.comfyui.customNodes.${node.name}: destination already exists: ${cfg.dataDir}/custom_nodes/${node.name}" >&2
      exit 1
    fi
    ln -sn ${lib.escapeShellArg "${node.src}"} ${lib.escapeShellArg "${cfg.dataDir}/custom_nodes/${node.name}"}
  '') cfg.customNodes;
in
{
  options = {
    services.comfyui = {
      enable = lib.mkEnableOption "ComfyUI";
      package = lib.mkPackageOption pkgs "comfyui" { };

      dataDir = lib.mkOption {
        type = lib.types.path;
        default = "/var/lib/comfyui";
        example = "/srv/comfyui";
        description = ''
          Directory holding ComfyUI's state: models, custom nodes, inputs, outputs and the database.

          Defaults to the unit's `StateDirectory`.
          Any other directory is created with systemd-tmpfiles and bind-mounted into the service.

          Existing state is not migrated, you need to move it yourself.
        '';
      };

      finalPackage = lib.mkOption {
        type = lib.types.package;
        internal = true;
        readOnly = true;
        default = package;
        description = "The final ComfyUI package which is being used in the service.";
      };

      listen = lib.mkOption {
        type = with lib.types; listOf str;
        default = [
          "127.0.0.1"
          "::1"
        ];
        example = [
          "0.0.0.0"
          "::"
        ];
        description = ''
          The host addresses on which ComfyUI should listen.
        '';
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 8188;
        example = 1234;
        description = ''
          The port on that ComfyUI will listen.
        '';
      };

      extraArgs = lib.mkOption {
        type = with lib.types; listOf str;
        default = [ ];
        example = [
          "--enable-assets"
          "--preview-method=auto"
        ];
        description = ''
          Extra arguments to pass to the server. See `comfyui --help` for available args.

          Flags set by the module are prepended with `lib.mkBefore`, so any user supplied flag wins over that.
        '';
      };

      models = lib.mkOption {
        type = lib.types.listOf (
          lib.types.submodule {
            options = {
              name = lib.mkOption {
                type = lib.types.str;
                description = ''
                  The model file name, used as the link name in `models/<installPath>/<name>`.
                  It must be unique within the same `<installPath>`, to avoid conflicts.
                '';
              };
              url = lib.mkOption {
                type = lib.types.str;
                description = ''
                  The download URL of the model file.
                  Pinned-resolve URLs (e.g. HuggingFace's `/resolve/<commit>/<file>`) are recommended to have a stable hash.
                '';
              };
              hash = lib.mkOption {
                type = lib.types.str;
                example = lib.fakeHash;
                description = ''
                  The SRI hash of the model file. Generate it with `nix-prefetch-url <url>`,
                  or set this to `lib.fakeHash`, build once and copy the hash from the error message.
                '';
              };
              installPaths = lib.mkOption {
                # A directory string is converted to a list.
                type =
                  with lib.types;
                  coercedTo (strMatching "[A-Za-z0-9_-]+") lib.singleton (
                    nonEmptyListOf (strMatching "[A-Za-z0-9_-]+")
                  );
                description = ''
                  String or list of target subdirectory names below `models/`, such as `upscale_models`, `loras`, `checkpoints`.
                  Write bare directory names (the module assembles them into `models/<installPath>`,
                  one symlink per install path); a single string is also accepted and upgraded to a one-element list.
                '';
                example = [ "upscale_models" ];
              };
            };
          }
        );
        default = [ ];
        example = lib.literalExpression ''
          [ {
            name = "RealESRGAN_x4plus_anime_6B.pth";
            url = "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.2.4/RealESRGAN_x4plus_anime_6B.pth";
            hash = "sha256-+HLYN9PJDtLgUie+1xGvVnGm/RyffX6RyRGmHxVemdo=";
            installPaths = "upscale_models";
          } ]
        '';
        description = ''
          ComfyUI models to fetch and symlink into `''${services.comfyui.dataDir}/models/<installPath>/<name>`.
          Files placed manually in the `models` directory are left untouched.
        '';
      };

      customNodes = lib.mkOption {
        type = lib.types.listOf (
          lib.types.submodule {
            options = {
              name = lib.mkOption {
                type = lib.types.addCheck (lib.types.strMatching "[A-Za-z0-9._-]+") (
                  name: name != "." && name != ".."
                );
                description = ''
                  Directory name below `custom_nodes`.

                  It must be unique and is used as the link name, so it has to be a
                  single path component.
                '';
              };

              src = lib.mkOption {
                type = lib.types.path;
                description = ''
                  Source of the custom node: a derivation whose output is the node
                  directory, or a path to such a directory.

                  The directory must contain the node's `__init__.py`. The source is
                  linked into the data directory and is therefore read-only; nodes
                  that need build steps or patches should be passed as a derivation.

                  The source must be readable inside the service's sandbox; paths
                  below `/home` are hidden by `ProtectHome`.
                '';
              };

              extraPackages = lib.mkOption {
                type = lib.types.functionTo (lib.types.listOf lib.types.package);
                default = _: [ ];
                defaultText = lib.literalExpression "ps: [ ]";
                example = lib.literalExpression "ps: with ps; [ numpy ]";
                description = ''
                  Python packages required by the node, resolved against ComfyUI's
                  Python package set and added to its environment.

                  Dependencies are not read from the node's `requirements.txt`; list
                  them explicitly here. These packages belong to the node: removing it
                  from `customNodes` also removes them. Use the top-level
                  `extraPackages` for packages shared by multiple nodes.
                '';
              };
            };
          }
        );
        default = [ ];
        example = lib.literalExpression ''
          [
            {
              name = "ComfyUI-Manager";
              src = pkgs.fetchFromGitHub {
                owner = "ltdrdata";
                repo = "ComfyUI-Manager";
                rev = "d47c9346190397e1c316bc5a82155faaf9f5d700";
                hash = "sha256-ACHHTyIZ3U23GwWv6tgN/jWbkJbv372I10jAUi9ix5o=";
              };
              extraPackages = ps: with ps; [
                gitpython
                rich
                toml
              ];
            }
          ]
        '';
        description = ''
          ComfyUI custom nodes to install declaratively.

          Each node's `src` is symlinked to `dataDir/custom_nodes/<name>`.
          Store symlinks below `custom_nodes` are managed by this option: stale
          ones are removed on start, while files and symlinks not pointing into
          the Nix store are left untouched.
        '';
      };

      extraPackages = lib.mkOption {
        type = lib.types.functionTo (lib.types.listOf lib.types.package);
        default = _: [ ];
        defaultText = lib.literalExpression "ps: with ps; [ ]";
        example = lib.literalExpression ''
          ps: with ps; [ comfyui-manager ]
        '';
        description = ''
          List of packages to add to ComfyUI's Python environment.

          Use this for packages shared by multiple custom nodes or needed by the
          ComfyUI environment itself; node-specific packages belong in
          `customNodes.*.extraPackages`.

          A popular example is `python3Packages.comfyui-manager` for installing and
          managing custom nodes from within ComfyUI.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    services.comfyui.extraArgs = lib.mkBefore [
      "--base-directory=${cfg.dataDir}"
      "--database-url=sqlite:///${cfg.dataDir}/user/comfyui.db"
      "--listen=${lib.concatStringsSep "," cfg.listen}"
      "--port=${toString cfg.port}"
    ];

    assertions = [
      {
        assertion =
          lib.length (lib.unique (map (node: node.name) cfg.customNodes)) == lib.length cfg.customNodes;
        message = "services.comfyui.customNodes: names must be unique.";
      }
    ];

    # owner read back from the unit, not spelled out: StateDirectory= infers it, this rule has to be told
    systemd.tmpfiles.settings = lib.mkIf (!isDefaultDataDir) {
      "10-comfyui".${cfg.dataDir}.d = {
        user = config.systemd.services.comfyui.serviceConfig.User;
        group = config.systemd.services.comfyui.serviceConfig.Group;
        mode = "0700";
      };
    };

    systemd.services.comfyui = {
      description = "Powerful and modular diffusion model GUI, api and backend";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      preStart = ''
        for d in custom_nodes input output models; do
          if [[ ! -d "${cfg.dataDir}/$d" ]]; then
            cp --no-preserve=all -r ${cfg.finalPackage}/share/comfyui/$d "${cfg.dataDir}/"
          fi
        done

        # Remove all symlinks pointing into /nix/store, then relink them, so that no stale ones are left behind.
        readarray -d "" stale < <(find "${cfg.dataDir}/models" -type l -print0)
        for link in "''${stale[@]}"; do
          if [[ "$(readlink "$link")" == ${lib.escapeShellArg builtins.storeDir}/* ]]; then
            rm "$link"
          fi
        done

        # Only the top level of custom_nodes is managed; do not touch symlinks inside a node's source.
        readarray -d "" stale < <(find "${cfg.dataDir}/custom_nodes" -maxdepth 1 -type l -print0)
        for link in "''${stale[@]}"; do
          if [[ "$(readlink "$link")" == ${lib.escapeShellArg builtins.storeDir}/* ]]; then
            rm "$link"
          fi
        done

        # Rebuild model symlinks
        ${modelSymlinks}

        # Rebuild custom node symlinks
        ${customNodeSymlinks}
      '';

      serviceConfig = {
        ExecStart = "${lib.getExe cfg.finalPackage} ${lib.escapeShellArgs cfg.extraArgs}";
        Group = "comfyui";
        Restart = "always";
        RestartSec = "5sec"; # don't crash loop immediately
        StateDirectory = lib.mkIf isDefaultDataDir "comfyui";
        Type = "simple";
        User = "comfyui";

        # This is a bind mount, not ReadWritePaths, so that with ProtectHome it is not shadowed by a tmpfs.
        BindPaths = lib.mkIf (!isDefaultDataDir) [ cfg.dataDir ];

        # required for Torch and GPU acceleration
        BindReadOnlyPaths = [ "/proc/cpuinfo" ];
        PrivateDevices = false;
        ProcSubset = "all";

        CapabilityBoundingSet = [ "" ];
        DeviceAllow = null;
        LockPersonality = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateUsers = true;
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
        RuntimeDirectoryMode = "700";
        StateDirectoryMode = "700";
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@system-service"
        ];
      };
    };

    users = {
      groups.comfyui = { };
      users.comfyui = {
        group = "comfyui";
        home = cfg.dataDir;
        isSystemUser = true;
      };
    };
  };

  meta.maintainers = pkgs.comfyui.meta.maintainers;
}
