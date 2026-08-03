# Standalone, single-user entrypoint for Hjem's module system.
#
# Unlike the NixOS, nix-darwin, and Finix modules, this evaluates the common
# per-user options (modules/common/user.nix) directly at the top level, so a
# configuration is written as a single user's home rather than under
# 'hjem.users.<username>'.
#
# On Linux the shared systemd module is evaluated as well, so 'systemd.services'
# and friends are available; 'hjem standalone switch' reloads user systemd after
# linking.
#
# 'hjemConfiguration' returns
# '{ manifest; packages; toplevel; config; options; }'.
#
#   - 'toplevel' is what the standalone CLI builds. It references every file
#     source (through the manifest's string context) and every package, so
#     building it realises the whole configuration into the store, and the
#     resulting out-link is a GC root for all of it. It exposes 'manifest.json'
#     and 'packages.json' at its root, and the packages merged under 'sw/'.
#   - 'manifest' and 'packages' describe the same configuration as a plain
#     value, for inspection and for linkers driven by 'nix eval'. Evaluation
#     cannot build derivations, so sources and packages that are derivation
#     outputs are named but not realised; only 'toplevel' guarantees they
#     exist.
#   - 'config' and 'options' are the evaluated module system, for introspection.
#
# 'evalStandalone' returns the full 'evalModules' result extended with the
# above, for anything else ('extendModules', '_module', ...).
let
  evalStandalone = {
    pkgs,
    modules ? [],
    specialArgs ? {},
  }: let
    lib = pkgs.lib;
    inherit (lib.modules) evalModules;

    hjem-lib = import ../../lib.nix {inherit lib pkgs;};
    inherit (import ../common/lib.nix {inherit hjem-lib lib pkgs;}) mkManifest userModules writeManifest;

    # The systemd module renders units through nixpkgs' NixOS helpers, which
    # take the surrounding NixOS config. Standalone has none, so only the
    # attributes those helpers read are supplied.
    utils = import "${pkgs.path}/nixos/lib/utils.nix" {
      inherit lib pkgs;
      config.systemd = {
        package = pkgs.systemd;
        globalEnvironment = {};
        enableStrictShellChecks = false;
      };
    };

    eval = evalModules {
      class = "hjem";
      specialArgs =
        specialArgs
        // {
          inherit hjem-lib pkgs utils;
        };
      modules =
        userModules {systemd = pkgs.stdenv.hostPlatform.isLinux;}
        ++ [
          ({config, ...}: {
            directory = lib.mkDefault "/home/${config.user}";
            clobberFiles = lib.mkDefault false;
          })
        ]
        ++ modules;
    };

    cfg = eval.config;

    manifest = mkManifest cfg;

    manifestFile = writeManifest {
      user = cfg;
      destination = "/manifest.json";
    };

    packages = map (p: "${p}") cfg.packages;

    packagesFile = pkgs.writeText "packages.json" (builtins.toJSON packages);

    sw = pkgs.buildEnv {
      name = "hjem-standalone-sw-${cfg.user}";
      paths = cfg.packages;
    };

    toplevel = pkgs.runCommandLocal "hjem-standalone-${cfg.user}" {} ''
      mkdir -p $out
      ln -s ${manifestFile}/manifest.json $out/manifest.json
      ln -s ${packagesFile} $out/packages.json
      ln -s ${sw} $out/sw
    '';
  in
    eval
    // {
      inherit manifest packages toplevel;
    };

  hjemConfiguration = args: {
    inherit (evalStandalone args) manifest packages toplevel config options;
  };
in {
  inherit evalStandalone hjemConfiguration;
}
