{ pkgs }:

pkgs.linkFarmFromDrvs "create-aeronautics-mods" (
  builtins.attrValues {
    Sable = pkgs.fetchurl {
      url = "https://cdn.modrinth.com/data/T9PomCSv/versions/g8CObHcP/sable-neoforge-1.21.1-1.1.3.jar";
      sha512 = "8180e214681c171c9e3b7fa307f7a92bd7de0b8125d671291425f04a4ba26b408758d8ea80a6386d8e73bb1e6b02caf3f20afb9b91ecedd48c37ed44363ac961";
    };
    Create = pkgs.fetchurl {
      url = "https://cdn.modrinth.com/data/LNytGWDc/versions/UjX6dr61/create-1.21.1-6.0.10.jar";
      sha512 = "11cc8fc049d2f67f6548c7abfada6b82a3adb5c7ca410a742de04bbca76e03862c518721b88d806f6e6d768a4d68531fdb903a85859b25d1484d550cc7bafd4b";
    };
    CreateAeronautics = pkgs.fetchurl {
      url = "https://cdn.modrinth.com/data/oWaK0Q19/versions/1sv6OtSz/create-aeronautics-bundled-1.21.1-1.1.3.jar";
      sha512 = "94831bc4702b3864524258fa0a73a50ab3cd37e9c157b5c6688a6845b866ec5838452804050b55e490549d91dad909fc37f0d619f354c5676e2e2651b9c15ec6";
    };
  }
)
