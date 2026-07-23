# Standalone CLI {#standalone-cli}

Hjem can manage the current user's home outside of a NixOS, nix-darwin, or Finix
module. Install the `hjem` package from the Hjem flake, then use either
`hjem standalone` or the packaged `hjem-standalone` alias.

```sh
nix profile install github:feel-co/hjem#hjem
hjem standalone --help
```

## Getting started

`hjem standalone init` creates a small configuration in `$XDG_CONFIG_HOME/hjem`,
or `~/.config/hjem` when `XDG_CONFIG_HOME` is unset. It creates `hjem.nix`, a
matching example source under `dotfiles/`, and, unless `--no-flake` is given, a
minimal `flake.nix`.

```sh
hjem standalone init
hjem standalone switch --flake ~/.config/hjem
```

Pass `--switch` to `init` to apply the generated configuration immediately, or
`--dir PATH` to create it elsewhere.

## Manifest sources

`switch` and `build` accept exactly one source:

- `--manifest PATH` reads an already-generated manifest JSON file.
- `--config PATH` evaluates a Nix expression such as `hjem.nix`.
- `--flake REF` evaluates a flake output. By default this is
  `hjemConfigurations."$USER"`; use `--flake-attr` to select another output.

The Nix value may be either the manifest itself or an attribute set containing
`manifest`. A manifest has a version and a list of files, for example:

```nix
{
  version = 3;
  files = [
    {
      type = "symlink";
      source = ./dotfiles/example;
      target = "/home/alice/.config/example";
    }
  ];
}
```

When using `--config` or `--flake`, the same value may also contain `packages`.
Standalone packages are installed into a Hjem-managed profile for the active
generation:

```nix
{
  manifest = {
    version = 3;
    files = [ ];
  };

  packages = [
    pkgs.hello
  ];
}
```

> [!TIP]
> Add the current profile to your login environment to expose package binaries:
>
> ```sh
> export PATH="$XDG_STATE_HOME/hjem/standalone/current-profile/bin:$PATH"
> ```
>
> If `XDG_STATE_HOME` is unset, use
> `$HOME/.local/state/hjem/standalone/current-profile/bin`.

Package support is not available for `--manifest`; manifest JSON remains a
file-linking format and cannot represent Nix derivations.

## Module-based configuration {#module-based-configuration}

Writing the manifest by hand loses the ergonomics of Hjem's module system.
`hjem.lib.hjemConfiguration` evaluates the same per-user options used by the
NixOS, nix-darwin, and Finix modules — `files`, `xdg`, generators,
`environment`, `packages`, and so on — for a single user, and returns
`{ manifest; packages; toplevel; config; options; }`. The CLI reads `manifest`
and `packages`; the rest is for you. It is unsystemised: the `pkgs` you pass in
pins the system.

```nix
{
  inputs.hjem.url = "github:feel-co/hjem";

  outputs = { self, nixpkgs, hjem, ... }: {
    hjemConfigurations.alice = hjem.lib.hjemConfiguration {
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      modules = [ ./hjem.nix ];
    };
  };
}
```

```nix
# hjem.nix
{ pkgs, ... }:
{
  user = "alice";

  files.".foo".text = "bar";

  xdg.config.files."app/config.json" = {
    generator = pkgs.lib.generators.toJSON { };
    value = { some = "contents"; };
  };

  packages = [ pkgs.hello ];
}
```

`user` is required. `directory` defaults to `/home/<user>`, and `clobberFiles`
defaults to `false`; both can be set in the module. Apply the result with:

```sh
hjem standalone switch --flake .
```

### systemd user units {#standalone-systemd-units}

On Linux, the same `systemd` options the NixOS module exposes are available:
`systemd.services`, `.timers`, `.sockets`, `.paths`, `.slices`, `.targets`, and
`systemd.packages`. Units are rendered into
`~/.config/systemd/user/`, along with the `.wants/`, `.requires/`, and
`.upholds/` links implied by `wantedBy`, `requiredBy`, and `upheldBy`.

```nix
{ pkgs, config, ... }:
{
  user = "alice";

  files.".config/example.conf".text = "answer=42";

  systemd.services.example = {
    description = "Example";
    wantedBy = [ "default.target" ];
    serviceConfig.ExecStart = "${pkgs.hello}/bin/hello";
    restartTriggers = [ config.files.".config/example.conf".source ];
  };
}
```

`switch` runs `systemctl --user daemon-reload` and then restarts or reloads any
unit whose `restartTriggers` or `reloadTriggers` changed. Pass
`--no-reload` to `hjem activate` to skip that; when user systemd is not running,
the reload is skipped with a message rather than failing.

The unit options are evaluated with nixpkgs' NixOS systemd helpers, which are
reached through `pkgs.path`. They are omitted entirely on non-Linux `pkgs`.

### Realising the configuration {#realising-the-configuration}

`hjemConfigurations."<USER>"` also carries a `toplevel` derivation that
references every file source (through the manifest's string context) and every
package. Building it realises the whole configuration into the store, and gives
you a build artifact and a GC root:

```sh
nix build .#hjemConfigurations."alice".toplevel
```

### Introspection {#introspection}

`config` and `options` expose the evaluated module system:

```sh
nix eval .#hjemConfigurations."alice".options.packages.description
```

They are not JSON-serialisable, which is fine: the CLI selects `manifest` and
`packages` in Nix, so nothing else in the set is ever forced.

For the rest of the `evalModules` result, such as `extendModules`, use
`hjem.lib.evalStandalone` (same arguments).

Use `--impure` only when that Nix evaluation requires impure builtins.

## Generations

Every successful `switch` saves the manifest as a generation before making it
current. State is stored in `$XDG_STATE_HOME/hjem/standalone`, or
`~/.local/state/hjem/standalone` by default. `--state-dir PATH` overrides it for
standalone lifecycle commands.

```sh
# Evaluate and validate without applying; the result is recorded under builds/.
$ hjem standalone build --config ./hjem.nix

# Inspect, roll back, and prune generations.
$ hjem standalone generations
$ hjem standalone rollback
$ hjem standalone rollback --generation generation-1780000000-123456789
$ hjem standalone expire-generations --keep-last 10
$ hjem standalone remove-generations generation-1780000000-123456789
```

> [!NOTE]
> `rollback` and `remove-generations` refuse invalid generation identifiers, and
> the current generation cannot be removed.
