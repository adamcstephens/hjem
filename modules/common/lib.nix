# Helpers shared by every Hjem entrypoint. This is not a module; import it and
# apply it to '{hjem-lib, lib, pkgs}'.
{
  hjem-lib,
  lib,
  pkgs,
}: let
  inherit (builtins) attrValues concatMap filter isAttrs toJSON;
  inherit (hjem-lib) fileToJson userFiles;
  inherit (lib.lists) optional;
  inherit (lib.meta) getExe;
  inherit (lib.modules) mkDefault;
  inherit (lib.strings) concatMapStringsSep concatStringsSep;
  inherit (lib.trivial) flip pipe;
  inherit (lib.types) submoduleWith;

  # The manifest version and the schema it is checked against live here so that
  # a version bump is a single edit rather than one per platform module.
  version = 3;
  schema = ../../manifest/v3.cue;
in rec {
  # The manifest for a single user, as consumed by 'hjem internal activate'.
  mkManifest = user: {
    inherit version;
    files =
      concatMap (flip pipe [
        attrValues
        (filter (x: x.enable))
        (map fileToJson)
      ])
      (userFiles user);
  };

  # Rendering the manifest as a file gives every 'source' store path a
  # build-time reference through string context, so building this derivation
  # realises all file sources. 'destination' is relative to the derivation root.
  writeManifest = {
    user,
    destination ? "/manifest-${user.user}.json",
  }:
    pkgs.writeTextFile {
      name = "manifest-${user.user}.json";
      inherit destination;
      text = toJSON (mkManifest user);
      checkPhase = ''
        set -e
        export CUE_CACHE_DIR="$(pwd)/.cache"
        export CUE_CONFIG_DIR="$(pwd)/.config"

        ${getExe pkgs.cue} vet -c ${schema} $target
      '';
    };

  # A single derivation holding 'manifest-<user>.json' for each given user, as
  # the platform services expect to find them.
  writeManifests = users:
    pkgs.symlinkJoin {
      name = "hjem-manifests";
      paths = map (user: writeManifest {inherit user;}) users;
    };

  # The modules every Hjem user is evaluated with. The systemd module renders
  # units through nixpkgs' NixOS helpers, so it needs a host that both runs
  # systemd and provides 'utils.systemdUtils'.
  userModules = {systemd}: [./user.nix] ++ optional systemd ./systemd.nix;

  # The type of 'hjem.users.<username>'. Each user's defaults are taken from
  # the host's user record via 'osConfig' (from 'specialArgs').
  #
  # 'assertHostUserEnabled' is false on nix-darwin, whose 'users.users.<name>'
  # has no 'enable' option to assert against.
  mkHjemSubmodule = {
    description,
    specialArgs,
    modules,
    systemd,
    assertHostUserEnabled ? true,
  }:
    submoduleWith {
      inherit description specialArgs;
      class = "hjem";
      modules =
        userModules {inherit systemd;}
        ++ [
          ({
            config,
            name,
            osConfig,
            ...
          }: let
            hostUser = osConfig.users.users.${name};
          in {
            assertions = optional assertHostUserEnabled {
              assertion = config.enable -> hostUser.enable;
              message = "Enabled Hjem user '${name}' must also be configured and enabled in NixOS.";
            };

            user = mkDefault hostUser.name;
            directory = mkDefault hostUser.home;
            clobberFiles = mkDefault osConfig.hjem.clobberByDefault;
          })
        ]
        ++ modules;
    };

  # Linker selection for 'hjem internal activate', rendered as shell flags.
  mkLinkerFlags = {
    hjem-package,
    linker,
    linkerOptions,
  }: let
    # A null linker means the systemd-tmpfiles hook, which is configured
    # elsewhere and takes no flags here.
    useExternalLinker = linker != null && linker != hjem-package;

    prefix =
      if isAttrs linkerOptions && linkerOptions ? prefix
      then linkerOptions.prefix
      else ".backup-";

    linkerArgs =
      if isAttrs linkerOptions
      then let
        optsFile = pkgs.writeText "hjem-linker-options.json" (toJSON linkerOptions);
      in ''--linker-arg --linker-opts --linker-arg ${optsFile}''
      else concatMapStringsSep " " (arg: ''--linker-arg "${arg}"'') linkerOptions;
  in
    concatStringsSep " " (
      [''--prefix "${prefix}"'']
      ++ optional useExternalLinker ''--external-linker "${getExe linker}" ${linkerArgs}''
    );
}
