# The module set each platform exposes, applied to that platform's base
# module: 'hjem' (and its 'default' alias) evaluates the base module, and
# 'hjem-lib' injects Hjem's library and CLI package as module arguments.
baseModule: rec {
  hjem = {
    imports = [
      hjem-lib
      baseModule
    ];
  };
  hjem-lib = {
    lib,
    pkgs,
    ...
  }: {
    _module.args = {
      hjem-lib = import ../../lib.nix {inherit lib pkgs;};
      hjem-package =
        if pkgs ? hjem
        then pkgs.hjem
        else pkgs.callPackage ../../cli/package.nix {};
    };
  };
  default = hjem;
}
