{
  symlinkJoin,
  hectic,
  dash,
  socat,
  curl,
  jq,
  coreutils,
  gawk,
  gnugrep,
  gnused,
  openssl,
}:
let
  shell = "${dash}/bin/dash";
  bashOptions = [
    "errexit"
    "nounset"
  ];
  # SC2329: lib units are sourced wholesale into both binaries; the reconciler
  # and webhook each leave a few wrapper functions unreferenced by design.
  excludeShellChecks = [
    "SC2086" # word splitting on purpose: env lists and profile triples
    "SC2046" # same, command substitution into set --
    "SC2329"
  ];

  runtimeDeps = [
    curl
    jq
    coreutils
    gawk
    gnugrep
    gnused
    openssl
  ];

  lib = ''
    ${builtins.readFile ./log.sh}
    ${builtins.readFile ./state.sh}
    ${builtins.readFile ./decide.sh}
    ${builtins.readFile ./hcloud.sh}
    ${builtins.readFile ./gitea.sh}
  '';

  handler = hectic.writeShellApplication {
    inherit shell bashOptions;
    inherit excludeShellChecks;
    name = "gcr-webhook-handler";
    runtimeInputs = [ socat ] ++ runtimeDeps;
    text = ''
      ${lib}
      ${builtins.readFile ./webhook.sh}
      gcr_state_init
      gcr_handle_webhook || gcr_respond 500 "internal error"
      exit 0
    '';
  };

  webhook = hectic.writeShellApplication {
    inherit shell bashOptions;
    inherit excludeShellChecks;
    name = "gitea-runner-webhook";
    runtimeInputs = [ socat ];
    text = ''
      : "''${GCR_LISTEN_ADDR:=127.0.0.1}"
      : "''${GCR_LISTEN_PORT:=8787}"
      exec ${socat}/bin/socat -T5 -t5 \
        "TCP-LISTEN:$GCR_LISTEN_PORT,bind=$GCR_LISTEN_ADDR,reuseaddr,fork" \
        EXEC:"${handler}/bin/gcr-webhook-handler",pipes
    '';
  };

  controller = hectic.writeShellApplication {
    inherit shell bashOptions;
    inherit excludeShellChecks;
    name = "gitea-runner-controller";
    runtimeInputs = runtimeDeps;
    text = ''
      ${lib}
      ${builtins.readFile ./controller.sh}
      gcr_main
    '';
  };
in
symlinkJoin {
  name = "gitea-runner-controller";
  paths = [
    controller
    webhook
  ];
}
