{
  config,
  hjem-lib,
  hjem-package,
  lib,
  options,
  pkgs,
  utils,
  ...
}: let
  inherit
    (builtins)
    attrValues
    concatMap
    concatStringsSep
    listToAttrs
    ;
  inherit (lib.attrsets) filterAttrs nameValuePair optionalAttrs;
  inherit (lib.meta) getExe;
  inherit
    (lib.modules)
    importApply
    mkMerge
    ;
  inherit (import ../common/lib.nix {inherit hjem-lib lib pkgs;}) mkHjemSubmodule mkLinkerFlags writeManifests;

  osConfig = config;

  cfg = config.hjem;
  _class = "nixos";

  enabledUsers = filterAttrs (_: u: u.enable) cfg.users;
  disabledUsers = filterAttrs (_: u: !u.enable) cfg.users;

  hjemCli = getExe hjem-package;

  linkerFlags = mkLinkerFlags {
    inherit hjem-package;
    inherit (cfg) linkerOptions;
    # Finix has no systemd-tmpfiles implementation, so a null linker falls
    # back to Hjem's own linker rather than to tmpfiles.
    linker =
      if cfg.linker == null
      then hjem-package
      else cfg.linker;
  };

  newManifests = writeManifests (attrValues enabledUsers);

  hjemSubmodule = mkHjemSubmodule {
    description = "Hjem submodule for Finix";
    # Finix boots finit rather than systemd, and its 'utils' carries no
    # 'systemdUtils' for the unit generators to use.
    systemd = false;
    specialArgs =
      cfg.specialArgs
      // {
        inherit
          hjem-lib
          osConfig
          pkgs
          utils
          ;
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
    (optionalAttrs (options ? system.extraDependencies) {
      system.extraDependencies = concatMap (u: u.extraDependencies) (attrValues enabledUsers);
    })

    {
      finit.tasks = let
        oldManifests = "/var/lib/hjem";
      in
        {
          hjem-prepare = {
            description = "Prepare Hjem manifests directory";
            command = pkgs.writeShellScript "hjem-prepare" ''
              mkdir -p ${oldManifests}
            '';
          };

          hjem-cleanup = {
            description = "Cleanup disabled users' manifests";
            conditions = map (user: "task/hjem-copy-${user.user}/success") (attrValues enabledUsers);
            command = pkgs.writeShellScript "hjem-cleanup" (
              if disabledUsers != {}
              then "rm -f ${
                concatStringsSep " " (map (user: "${oldManifests}/manifest-${user.user}.json") (attrValues disabledUsers))
              }"
              else "true"
            );
          };
        }
        // optionalAttrs (enabledUsers != {}) (
          listToAttrs (
            concatMap (
              user: let
                username = user.user;
                activateName = "hjem-activate-${username}";
                copyName = "hjem-copy-${username}";
              in [
                (nameValuePair activateName {
                  description = "Link files for ${username} from their manifest";
                  user = username;
                  conditions = ["task/hjem-prepare/success"];
                  command = pkgs.writeShellScript activateName ''
                    new_manifest="${newManifests}/manifest-${username}.json"
                    old_manifest="${oldManifests}/manifest-${username}.json"

                    ${hjemCli} internal activate \
                      --manifest "$new_manifest" \
                      --state "$old_manifest" \
                      --skip-state-update \
                      ${linkerFlags} \
                      --json
                  '';
                })
                (nameValuePair copyName {
                  description = "Update Hjem state manifest for ${username}";
                  conditions = ["task/${activateName}/success"];
                  command = pkgs.writeShellScript copyName ''
                    ${hjemCli} internal update-state \
                      --manifest "${newManifests}/manifest-${username}.json" \
                      --state "${oldManifests}/manifest-${username}.json"
                  '';
                })
              ]
            ) (attrValues enabledUsers)
          )
        );
    }
  ];
}
