{ pkgs }:

let
  source = pkgs.lib.cleanSourceWith {
    src = ./.;
    filter = path: type:
      builtins.baseNameOf path != "__pycache__"
      && !(pkgs.lib.hasSuffix ".pyc" path);
  };
  pythonEnv = pkgs.python3.withPackages (ps: [
    ps.requests
    ps.boto3
    ps.zstandard
  ]);
in
pkgs.stdenv.mkDerivation {
  pname = "attic-repack";
  version = "0.1.0";
  src = source;

  nativeBuildInputs = [ pkgs.makeWrapper ];

  installPhase = ''
    mkdir -p $out/bin $out/libexec/attic-repack
    cp $src/repack.py $out/libexec/attic-repack/repack.py
    chmod +x $out/libexec/attic-repack/repack.py
    makeWrapper ${pythonEnv}/bin/python3 $out/bin/attic-repack \
      --add-flags $out/libexec/attic-repack/repack.py \
      --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.nix ]}
  '';

  doCheck = true;
  checkPhase = ''
    ${pythonEnv}/bin/python3 -m unittest discover -s $src -p 'test_*.py'
  '';

  passthru = {
    inherit pythonEnv;
    tests.unittest = pkgs.runCommand "attic-repack-unittest" {
      nativeBuildInputs = [ pythonEnv pkgs.nix ];
    } ''
      cp -r ${source} ./src
      chmod -R u+w ./src
      ${pythonEnv}/bin/python3 -m unittest discover -s ./src -p 'test_*.py'
      mkdir -p $out
    '';
  };
}
