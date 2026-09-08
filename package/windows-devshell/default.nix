{ pkgs, linux-devshell-standalone }:
{
  windows-devshell-standalone = pkgs.runCommand "windows-devshell.ps1" {
    meta.description = "Standalone windows-devshell PowerShell script (single file)";
  } ''
    linux_dev_shell_base64=$(${pkgs.coreutils}/bin/base64 -w 0 ${linux-devshell-standalone})
    ${pkgs.gnused}/bin/sed "s|@LINUX_DEVSHELL_BASE64@|$linux_dev_shell_base64|g" \
      ${./windows-devshell.ps1} > "$out"
  '';
}
