{
  buildGoModule,
  fetchFromGitHub,
  lib,
}:
buildGoModule {
  pname = "plgo";
  version = "0.2.1-unstable-2026-04-04";

  src = fetchFromGitHub {
    owner = "mgr43";
    repo = "plgo";
    rev = "492abd81f50f5f588794bd3f9fa103d14546b275";
    hash = "sha256-Ifd2IFA62VtkqCUP0/cD3jT4SqkjqwCpHVolslQbwkA=";
  };

  vendorHash = "sha256-KIVHepJRfVa0bkTF1A4g6ZFGxDy8OPzY3iwV3MhRyVA=";

  proxyVendor = true;

  subPackages = [ "cmd/plgo" ];

  doCheck = false;

  meta = {
    description = "Write PostgreSQL extensions in Go";
    homepage = "https://github.com/mgr43/plgo";
    license = lib.licenses.bsd3;
    mainProgram = "plgo";
  };
}
