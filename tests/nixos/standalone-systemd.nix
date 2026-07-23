{
  hjemTest,
  pkgs,
  lib,
}: let
  inherit (lib.meta) getExe';
  user = "alice";
  userHome = "/home/${user}";

  hjemLib = import ../../modules/standalone;

  # A oneshot service that stays "active" via RemainAfterExit. Restarting it
  # produces a new ActiveEnterTimestamp, making restarts unambiguously detectable.
  mkConfiguration = version:
    hjemLib.hjemConfiguration {
      inherit pkgs;
      modules = [
        ({config, ...}: {
          inherit user;
          directory = userHome;

          files.".config/restart-test.conf".text = "version=${version}";

          systemd.services.restart-test = {
            description = "Hjem standalone restartTriggers test – ${version}";
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = getExe' pkgs.coreutils "true";
            };
            restartTriggers = [config.files.".config/restart-test.conf".source];
          };
        })
      ];
    };

  v1 = mkConfiguration "1";
  v2 = mkConfiguration "2";
in
  hjemTest {
    name = "hjem-standalone-systemd";
    nodes.node1 = {
      users = {
        groups.${user} = {};
        users.${user} = {
          isNormalUser = true;
          home = userHome;
          password = "";
        };
      };

      environment = {
        systemPackages = [(pkgs.callPackage ../../cli/package.nix {})];

        etc = {
          "hjem-standalone-v1".source = v1.toplevel;
          "hjem-standalone-v2".source = v2.toplevel;
        };
      };
    };

    testScript = ''
      node1.succeed("loginctl enable-linger ${user}")
      uid = node1.succeed("id -u ${user}").strip()
      xdg = f"/run/user/{uid}"
      node1.wait_for_unit(f"user@{uid}.service")

      def alice(cmd):
          return node1.succeed(
              f"su ${user} -c 'env HOME=${userHome} XDG_RUNTIME_DIR={xdg} {cmd}'"
          )

      def alice_show(unit, prop):
          return alice(f"systemctl --user show {unit} --property={prop} --value").strip()

      with subtest("Standalone links units declared through systemd options"):
          alice("hjem standalone switch --manifest /etc/hjem-standalone-v1/manifest.json")
          node1.succeed("test -L ${userHome}/.config/systemd/user/restart-test.service")
          node1.succeed(
              "grep -q 'Hjem standalone restartTriggers test' "
              "${userHome}/.config/systemd/user/restart-test.service"
          )

      with subtest("Standalone switch reloads the systemd user daemon"):
          # A unit only becomes startable once 'daemon-reload' has run, so this
          # would fail if 'switch' had not reloaded on its own.
          alice("systemctl --user start restart-test.service")
          alice("systemctl --user is-active restart-test.service")

          ts_before = alice_show("restart-test.service", "ActiveEnterTimestamp")
          assert ts_before != "", "restart-test has no ActiveEnterTimestamp; service did not start"

      with subtest("Standalone switch restarts units whose triggers changed"):
          alice("hjem standalone switch --manifest /etc/hjem-standalone-v2/manifest.json")
          alice("systemctl --user is-active restart-test.service")

          ts_after = alice_show("restart-test.service", "ActiveEnterTimestamp")
          assert ts_before != ts_after, (
              f"restart-test was NOT restarted: timestamps unchanged ({ts_before})"
          )

      with subtest("--no-reload leaves units untouched"):
          alice(
              "hjem activate --no-reload "
              "--manifest /etc/hjem-standalone-v1/manifest.json "
              "--state ${userHome}/.local/state/hjem/standalone/current/manifest.json"
          )
          alice("systemctl --user is-active restart-test.service")

          ts_final = alice_show("restart-test.service", "ActiveEnterTimestamp")
          assert ts_after == ts_final, (
              f"restart-test was restarted despite --no-reload: {ts_after} -> {ts_final}"
          )
    '';
  }
