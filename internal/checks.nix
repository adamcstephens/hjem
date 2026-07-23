{
  pkgs,
  self ? ../.,
}: let
  hjemTest =
    # The first argument to this function is the test module itself
    test:
      (pkgs.testers.runNixOSTest {
        defaults.documentation.enable = pkgs.lib.mkDefault false;
        imports = [test];
      }).config.result;

  inherit (pkgs.lib.filesystem) packagesFromDirectoryRecursive;
  inherit (pkgs.lib.lists) optional;
  inherit (pkgs.lib.meta) getExe';
  inherit (pkgs.stdenv.hostPlatform) isLinux;

  prefixAttrs = prefix: pkgs.lib.mapAttrs' (name: pkgs.lib.nameValuePair "${prefix}-${name}");

  # The NixOS tests drive the CLI with hand-written manifests, so nothing there
  # evaluates the standalone entrypoint. Building its 'toplevel' covers module
  # evaluation, the manifest schema check, and the user profile.
  standaloneConfiguration = (import (self + "/modules/standalone")).hjemConfiguration {
    inherit pkgs;
    modules =
      [
        {
          user = "alice";
          files.".config/hjem-standalone-check".text = "Hello standalone!";
          packages = [pkgs.hello];
        }
      ]
      ++ optional isLinux {
        systemd.services.hjem-standalone-check = {
          description = "Hjem standalone check";
          serviceConfig.ExecStart = getExe' pkgs.coreutils "true";
          wantedBy = ["default.target"];
        };
      };
  };

  checks =
    prefixAttrs "nixos" (packagesFromDirectoryRecursive {
      callPackage = pkgs.newScope (checks
        // {
          inherit hjemTest;
          hjemModule = (import (self + "/modules/nixos")).default;
        });
      directory = ../tests/nixos;
    })
    // {
      standalone = let
        toplevel = standaloneConfiguration.toplevel;
      in
        pkgs.runCommandLocal "hjem-standalone-check" {} ''
          set -e
          grep -q '/home/alice/.config/hjem-standalone-check' ${toplevel}/manifest.json
          ${pkgs.lib.optionalString isLinux ''
            grep -q 'systemd/user/hjem-standalone-check.service' ${toplevel}/manifest.json
            grep -q 'systemd/user/default.target.wants/hjem-standalone-check.service' ${toplevel}/manifest.json
          ''}
          test -x ${toplevel}/sw/bin/hello
          touch $out
        '';

      # Formatting checks to run as a part of 'nix flake check' or manually
      # via 'nix build .#checks.<system>.formatting'.
      formatting =
        pkgs.runCommandLocal "hjem-formatting-check" {
          nativeBuildInputs = [pkgs.alejandra];
        } ''
          alejandra --check ${self}
          touch $out;
        '';
    };
in
  checks
