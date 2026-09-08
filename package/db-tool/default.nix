{ dash, hectic, postgresql_17, neovim, openssh, coreutils, gawk, lib, runCommand, self }:
let
  shell = "${dash}/bin/dash";
  hecticInheritance = runCommand "hectic-inheritance" { } ''
    mkdir -p "$out/share/hectic"
    cp ${self.lib.hectic.inheritance.path} "$out/share/hectic/hectic-inheritance.sql"
  '';

  applyBundle = self.lib.hectic.applyBundleScript;

  mkDbDev =
    { postgresql ? postgresql_17 }:
    hectic.writeShellApplication {
      inherit shell;
      bashOptions = [
        "errexit"
        "nounset"
      ];
    excludeShellChecks = [ "SC1091" "SC2209" ];
      name = "database";
      runtimeInputs = [ hectic.migrator hectic.parse-uri postgresql neovim openssh coreutils gawk ];

      text = ''
        . ${hectic.helpers.posix-shell.log}/bin/log.sh
        . ${hectic.helpers.posix-shell.change_namespace}/bin/change_namespace.sh
        . ${hectic.helpers.posix-shell.quote}/bin/quote.sh
        . ${hectic.helpers.posix-shell.pager_or_cat}/bin/pager_or_cat.sh
        . ${hectic.helpers.posix-shell.with_closed_fds}/bin/with_closed_fds.sh
        ${applyBundle}
        ${builtins.readFile ./db-dev.sh}
      '';

      meta = {
        description = "PostgreSQL development database management";
        mainProgram = "database";
      };
    };

  mkDbOps =
    { postgresql ? postgresql_17 }:
    hectic.writeShellApplication {
      inherit shell;
      bashOptions = [
        "errexit"
        "nounset"
      ];
    excludeShellChecks = [ "SC1091" "SC2209" ];
      name = "db-ops";
      runtimeInputs = [ postgresql coreutils ];

      text = ''
        . ${hectic.helpers.posix-shell.log}/bin/log.sh
        . ${hectic.helpers.posix-shell.change_namespace}/bin/change_namespace.sh
        ${applyBundle}
        ${builtins.readFile ./db-ops.sh}
      '';

      meta = {
        description = "PostgreSQL operations utility";
        mainProgram = "db-ops";
      };
    };

  mkPostgresInit =
    { postgresql ? postgresql_17 }:
    hectic.writeShellApplication {
      inherit shell;
      bashOptions = [ ];
      excludeShellChecks = [ "SC1091" ];
      name = "postgres-init";
      runtimeInputs = [ postgresql coreutils ];

      text = ''
        . ${hectic.helpers.posix-shell.with_closed_fds}/bin/with_closed_fds.sh
        ${builtins.readFile ./postgres-init.sh}
      '';


      meta = {
        description = "Initialize local PostgreSQL instance";
        mainProgram = "postgres-init";
      };
    };

  mkPostgresCleanup =
    { postgresql ? postgresql_17 }:
    hectic.writeShellApplication {
      inherit shell;
      bashOptions = [ ];
      name = "postgres-cleanup";
      runtimeInputs = [ postgresql coreutils ];

      text = builtins.readFile ./postgres-cleanup.sh;

      meta = {
        description = "Clean up local PostgreSQL instance";
        mainProgram = "postgres-cleanup";
      };
    };
in
{
  "db-dev"              = lib.makeOverridable mkDbDev { };
  "db-ops"              = lib.makeOverridable mkDbOps { };
  "postgres-init"       = lib.makeOverridable mkPostgresInit { };
  "postgres-cleanup"    = lib.makeOverridable mkPostgresCleanup { };
  "hectic-inheritance"  = hecticInheritance;
}
