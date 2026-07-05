{ pkgs }:

let
  pythonEnv = pkgs.python3.withPackages (ps: let
    torch = ps.torchWithCuda;
    accelerate = ps.accelerate.override { inherit torch; };
  in [
    accelerate
    ps.diffusers
    ps.fastapi
    ps.imageio
    ps.imageio-ffmpeg
    ps.pillow
    ps.python-multipart
    ps.safetensors
    torch
    ps.transformers
    ps.uvicorn
  ]);
in

pkgs.stdenv.mkDerivation {
  pname = "stable-video-diffusion-api";
  version = "0.1.0";
  src = ./.;

  nativeBuildInputs = [ pkgs.makeWrapper ];

  installPhase = ''
    mkdir -p $out/bin $out/libexec/stable-video-diffusion-api
    cp $src/app.py $out/libexec/stable-video-diffusion-api/app.py
    chmod +x $out/libexec/stable-video-diffusion-api/app.py

    makeWrapper ${pythonEnv}/bin/python3 $out/bin/stable-video-diffusion-api \
      --add-flags $out/libexec/stable-video-diffusion-api/app.py \
      --set-default SVD_API_HOST 127.0.0.1 \
      --set-default SVD_API_PORT 8000 \
      --set-default SVD_MODEL_ID stabilityai/stable-video-diffusion-img2vid-xt \
      --set-default SVD_OUTPUT_DIR /var/lib/stable-video-diffusion-api/outputs
  '';
}
