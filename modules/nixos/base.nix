{
  config,
  hjem-lib,
  lib,
  options,
  pkgs,
  hjem-package,
  utils,
  ...
}: let
  inherit (builtins) attrValues concatMap concatStringsSep filter mapAttrs;
  inherit (hjem-lib) userFiles;
  inherit (lib.attrsets) filterAttrs optionalAttrs;
  inherit (lib.modules) importApply mkIf mkMerge;
  inherit (lib.strings) concatMapStringsSep optionalString;
  inherit (lib.trivial) pipe;
  inherit (lib.meta) getExe;
  inherit (import ../common/lib.nix {inherit hjem-lib lib pkgs;}) mkHjemSubmodule mkLinkerFlags writeManifests;

  osConfig = config;

  cfg = config.hjem;
  _class = "nixos";

  enabledUsers = filterAttrs (_: u: u.enable) cfg.users;

  hjemCli = getExe hjem-package;

  linkerFlags = mkLinkerFlags {
    inherit hjem-package;
    inherit (cfg) linker linkerOptions;
  };

  newManifests = writeManifests (attrValues enabledUsers);

  hjemSubmodule = mkHjemSubmodule {
    description = "Hjem submodule for NixOS";
    systemd = true;
    specialArgs =
      cfg.specialArgs
      // {
        inherit hjem-lib osConfig pkgs utils;
        osOptions = options;
      };
    # Evaluate additional modules under 'hjem.users.<username>' so that
    # module systems built on Hjem are more ergonomic.
    modules = cfg.extraModules;
  };
in {
  inherit _class;

  imports = [
    (importApply ../common/top-level.nix {inherit hjemSubmodule _class;})
  ];

  config = mkMerge [
    {
      system.extraDependencies = concatMap (u: u.extraDependencies) (attrValues enabledUsers);
    }

    # Constructed rule string that consists of the type, target, and source
    # of a tmpfile. Files with 'null' sources are filtered before the rule
    # is constructed.
    (mkIf (cfg.linker == null) {
      systemd.user.tmpfiles.users =
        mapAttrs (_: u: {
          rules = pipe (userFiles u) [
            (concatMap attrValues)
            (filter (f: f.enable && f.source != null))
            (map (
              file:
              # L+ will recreate, i.e., clobber existing files.
              "L${optionalString file.clobber "+"} '${file.target}' - - - - ${file.source}"
            ))
          ];
        })
        enabledUsers;
    })

    (mkIf (cfg.linker != null) {
      /*
      The different Hjem services expect the manifest to be generated under `/var/lib/hjem/manifest-{user}.json`.
      */
      systemd.targets.hjem = {
        description = "Hjem File Management";
        unitConfig.X-StopOnReconfiguration = true;
        after = ["local-fs.target"];
        wantedBy = ["sysinit-reactivation.target" "multi-user.target"];
        before = ["sysinit-reactivation.target"];
        requires = let
          requiredUserServices = name: [
            "hjem-activate@${name}.service"
            "hjem-reload@${name}.service"
            "hjem-update-state@${name}.service"
          ];
        in
          concatMap requiredUserServices (map (u: u.user) (attrValues enabledUsers))
          ++ ["hjem-cleanup.service"];
      };

      systemd.services = let
        oldManifests = "/var/lib/hjem";
        homeDirectories = map (u: u.directory) (attrValues enabledUsers);
        checkEnabledUsers = ''
          case "$1" in
            ${concatStringsSep "|" (map (u: u.user) (attrValues enabledUsers))}) ;;
            *) echo "User '%i' is not configured for Hjem" >&2; exit 0 ;;
          esac
        '';
      in
        optionalAttrs (enabledUsers != {}) {
          hjem-prepare = {
            description = "Prepare Hjem manifests directory";
            enableStrictShellChecks = true;
            script = "mkdir -p ${oldManifests}";
            serviceConfig.Type = "oneshot";
            unitConfig.RefuseManualStart = true;
          };

          "hjem-activate@" = {
            description = "Link files for %i from their manifest";
            enableStrictShellChecks = true;
            unitConfig.RequiresMountsFor = homeDirectories;
            serviceConfig = {
              User = "%i";
              Type = "oneshot";
            };
            requires = ["hjem-prepare.service"];
            after = ["hjem-prepare.service"];
            scriptArgs = "%i";
            script = ''
              ${checkEnabledUsers}
              new_manifest="${newManifests}/manifest-$1.json"
              old_manifest="${oldManifests}/manifest-$1.json"

              ${hjemCli} internal activate \
                --manifest "$new_manifest" \
                --state "$old_manifest" \
                --skip-state-update \
                --no-reload \
                ${linkerFlags} \
                --json
            '';
          };

          "hjem-reload@" = {
            description = "Reload systemd user units for %i after Hjem file activation";
            enableStrictShellChecks = true;
            serviceConfig = {
              User = "%i";
              Type = "oneshot";
            };
            unitConfig.RequiresMountsFor = homeDirectories;
            requires = ["hjem-activate@%i.service"];
            after = ["hjem-activate@%i.service"];
            path = [config.systemd.package pkgs.coreutils-full];
            scriptArgs = "%i";
            script = ''
              ${checkEnabledUsers}

              XDG_RUNTIME_DIR=$(loginctl show-user "$1" --property=RuntimePath --value 2>/dev/null || true)
              if [ -z "$XDG_RUNTIME_DIR" ]; then
                echo "Could not determine XDG runtime directory for $1. Skipping."
                exit 0
              fi
              export XDG_RUNTIME_DIR

              systemd_status=$(systemctl --user is-system-running 2>&1 || true)
              if [ "$systemd_status" != "running" ] && [ "$systemd_status" != "degraded" ]; then
                echo "User systemd for $1 is not running (status: $systemd_status). Skipping."
                exit 0
              fi

              ${hjemCli} internal reload-actions \
                --old-manifest "${oldManifests}/manifest-$1.json" \
                --new-manifest "${newManifests}/manifest-$1.json" \
                --user "$1" \
                --require-running-systemd
            '';
          };

          "hjem-update-state@" = {
            description = "Update Hjem state manifest for %i";
            enableStrictShellChecks = true;
            serviceConfig.Type = "oneshot";
            requires = ["hjem-reload@%i.service"];
            unitConfig.RequiresMountsFor = homeDirectories;
            after = ["hjem-reload@%i.service"];
            scriptArgs = "%i";
            script = ''
              ${checkEnabledUsers}

              ${hjemCli} internal update-state \
                --manifest "${newManifests}/manifest-$1.json" \
                --state "${oldManifests}/manifest-$1.json"
            '';
          };

          hjem-cleanup = {
            description = "Cleanup disabled users' manifests";
            enableStrictShellChecks = true;
            serviceConfig.Type = "oneshot";
            after = ["hjem.target"];
            unitConfig.RefuseManualStart = false;
            script = ''
              ${hjemCli} internal cleanup-state \
                --state-dir ${oldManifests} \
                ${concatMapStringsSep " " (u: ''--enabled-user "${u.user}"'') (attrValues enabledUsers)}
            '';
          };
        };
    })
  ];
}
