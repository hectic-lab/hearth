{ flake, inputs, self }: let
  nixpkgs = inputs.nixpkgs;
  lib = nixpkgs.lib;
  recursiveUpdate = nixpkgs.lib.recursiveUpdate;

  envErrorMessage = varName: "Error: The ${varName} environment variable is not set.";

  AllSystems = [
    "aarch64-darwin"
    "aarch64-linux"    
    "armv5tel-linux"     
    "armv6l-linux"    
    "armv7l-linux"      
    "i686-linux"
    "mipsel-linux"
    "powerpc64le-linux"
    "riscv64-linux"
    "x86_64-darwin"
    "x86_64-linux"
  ];

  commonSystems = [
    "x86_64-linux"
    "aarch64-linux"
    "x86_64-darwin"
    "aarch64-darwin"
  ];

  cudaUnfreeNames = [
    "cuda_nvcc"
    "cuda_cudart"
    "cuda_cuobjdump"
    "cuda_cupti"
    "cuda_nvdisasm"
    "cuda_cccl"
    "cuda_nvml_dev"
    "cuda_nvrtc"
    "cuda_nvtx"
    "cuda_profiler_api"

    "libcusparse_lt"
    "libcublas"
    "libcufft"
    "libcufile"
    "libcurand"
    "libcusolver"
    "libnvjitlink"
    "libcusparse"
    "cudnn"
  ];

  cudaUnfreePredicate = pkg:
    builtins.elem (nixpkgs.lib.getName pkg) cudaUnfreeNames;

  forSystemsWithPkgs = supportedSystems: pkgOverlays: f:
    builtins.foldl' (
      acc: system: let
        pkgs = import nixpkgs {
          inherit system;
          overlays = pkgOverlays;
          config.allowUnfreePredicate = cudaUnfreePredicate;
        };
        systemOutputs = f {
          system = system;
          pkgs = pkgs;
        };
      in
        recursiveUpdate acc systemOutputs
    ) {}
    supportedSystems;

  forAllSystemsWithPkgs = pkgOverlays: f: forSystemsWithPkgs AllSystems pkgOverlays f;

  parseEnv = import ./parse-env.nix;

  dotEnv = builtins.getEnv "DOTENV";
  minorEnvironment =
    if dotEnv != ""
    then
      if builtins.pathExists dotEnv
      then parseEnv dotEnv
      else throw "${dotEnv} file not exist"
    else if builtins.pathExists ./.env
    then parseEnv ./.env
    else {};
in {
  # -- For all systems --
  inherit dotEnv minorEnvironment parseEnv forAllSystemsWithPkgs forSystemsWithPkgs commonSystems AllSystems cudaUnfreeNames cudaUnfreePredicate;

  forSystems = systems: nixpkgs.lib.genAttrs systems;
  forAllSystems = nixpkgs.lib.genAttrs AllSystems;

  shellModules = {
    logs = builtins.readFile ./shell/logs.sh;
    check-tool = builtins.readFile ./shell/check-tool.sh;
    local-dir = builtins.readFile ./shell/local-dir.sh;
    load-sops = builtins.readFile ./shell/load-sops.sh;
  };

  sharedShellAliases = {
    jc = ''journalctl'';
    sc = ''journalctl'';
    nv = ''nvim'';
  };

  sharedShellAliasesForDevVm = self.lib.sharedShellAliases // {
    sd = "shutdown now";
  };

  readEnvironment = { envVarsToRead, prefix ? "" }:
    builtins.listToAttrs
    (map (name: {
        inherit name;
        value = self.lib.getEnv "${prefix}${name}";
      })
      envVarsToRead);

  # -- Env processing --
  getEnv = varName: let
    var = builtins.getEnv varName;
  in
    if var != ""
    then var
    else if minorEnvironment ? varName
    then minorEnvironment."${varName}"
    else throw (envErrorMessage varName);

  # -- Cargo.toml --
  cargoToml = src: (builtins.fromTOML (builtins.readFile "${src}/Cargo.toml"));

  # Consolidated SQL bundles for the `hectic` schema. Single source of truth
  # for everything that creates objects in the `hectic` namespace, used by
  # migrator (init-time), db-dev/database hydrate, and db-ops secrets loading. Consumers apply
  # the full bundle via lib/hook/apply-hectic-bundle.sh.
  #
  # The whole hectic system shares one `versionString`; `hectic-version.sql`
  # registers (`'hectic'`, versionString) into `hectic.version` and raises an
  # exception on mismatch. Per-hook version rows are intentionally absent.
  #
  # Each entry exposes:
  #   * .sql   — file contents as a string, with @HECTIC_VERSION@ substituted
  #   * .path  — Nix store path (only on entries that need no substitution)
  hectic = let
    versionString = lib.fileContents ./hook/sql/HECTIC_VERSION;
    static = path: { inherit path; sql = builtins.readFile path; };
    templated = path: let
      sql = builtins.replaceStrings
        [ "@HECTIC_VERSION@" ]
        [ versionString ]
        (builtins.readFile path);
    in {
      inherit sql;
      path = builtins.toFile (builtins.baseNameOf (toString path)) sql;
    };
  in rec {
    inherit versionString;
    version     = templated ./hook/sql/hectic-version.sql;
    secret      = static    ./hook/sql/hectic-secret.sql;
    migration   = static    ./hook/sql/hectic-migration.sql;
    inheritance = static    ./hook/sql/hectic-inheritance.sql;
    bundleFiles = [
      version.path
      secret.path
      migration.path
      inheritance.path
    ];
    applyBundleScript =
      builtins.replaceStrings
        [
          "@HECTIC_VERSION_SQL@"
          "@HECTIC_SECRET_SQL@"
          "@HECTIC_MIGRATION_SQL@"
          "@HECTIC_INHERITANCE_SQL@"
        ]
        [
          "${version.path}"
          "${secret.path}"
          "${migration.path}"
          "${inheritance.path}"
        ]
        (builtins.readFile ./hook/apply-hectic-bundle.sh);
  };

  # Back-compat alias. Prefer `self.lib.hectic.inheritance`.
  hecticInheritance = let
    path = ./hook/sql/hectic-inheritance.sql;
  in {
    inherit path;
    sql = builtins.readFile path;
  };

  ssh.keys = {
    hetzner-test = {
      yukkop = ''ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ8scy1tv6zfXX6xyaukhO/fsZwif5rC89DvXNc6XxOf'';
    };
  };

  readPackages = callPackage: path: extraArgs:
  with lib;
  with builtins;
  pipe path [
    readDir
    (filterAttrs (_: type: type == "directory"))
    (filterAttrs (name: _: pathExists "${path}/${name}/default.nix"))
    (mapAttrs (name: _: callPackage "${path}/${name}" extraArgs))
  ];

  # Like readModulesRecursive, but reads module structure as a one-level keys,
  # so that it is suited for `nix flake show`
  # ```nix
  # {
  #   "foo.bar" = import ./module/foo/bar.nix
  # }
  # ```
  readModulesRecursive' = path: extraArgs:
    with lib;
    with builtins; let
      collectPaths = dir: prefix:
        concatLists (mapAttrsToList (name: type: let
          path' = dir + "/${name}";
          name' = if prefix == "" then name else "${prefix}/${name}";
        in
          if type == "directory"
          then collectPaths path' name'
          else [{
            inherit path';
            name = name';
          }]
        ) (readDir dir));
      paths = filter (path': hasSuffix ".nix" path'.name) (collectPaths path "");
      pathToName = flip pipe [
        (replaceStrings ["/" ".nix"] ["." ""])
        (removeSuffix ".nix")
      ];
      attrList =
        map (path': {
          name = pathToName path'.name;
          value = import path'.path' extraArgs;
        })
        paths;
    in
      listToAttrs attrList;

  nixpkgs-lib = nixpkgs.lib;
} // rec {
  /* Supplied a directory, reads it's recursive structure into NixOS modules, so
     that provided a `./module` dir with `module/foo/bar.nix` in it it outputs
     ```nix
     {
       foo.bar = import ./module/foo/bar.nix
     }
    ```
  */
  readModulesRecursive = path:
    lib.mapAttrs' (
      name: value: let
        name' = builtins.replaceStrings [".nix"] [""] name;
      in
        if value == "regular"
        then {
          name = name';
          value = import "${path}/${name}";
        }
        else {
          inherit name;
          value = readModulesRecursive "${path}/${name}";
        }
    ) (builtins.readDir path);
}
