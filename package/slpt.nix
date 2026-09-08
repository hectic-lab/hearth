{ lib, fetchFromGitHub, runCommand, makeWrapper, jq }: let
  src = fetchFromGitHub {
    owner = "nativerv";
    repo = "slpt";
    rev = "8d70db4d8dfcd624ed49b9e6fb0ad449b6f25b89";
    hash = "sha256-sCHZsf7Y36iAesh7BeSxy9WhE/uQv13/VWmjlaVSEcU=";
  };
in runCommand "slpt" {
  inherit src;
  nativeBuildInputs = [ makeWrapper ];
} ''
  install -Dm755 "$src/slpt" "$out/bin/slpt"
  patchShebangs "$out/bin/slpt"
  wrapProgram "$out/bin/slpt" --prefix PATH : "${lib.makeBinPath [ jq ]}"
''
