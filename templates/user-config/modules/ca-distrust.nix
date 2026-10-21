# CA distrust - imported by common.nix and by every mkInfraVm VM in flake.nix
# (those skip common.nix), so every host and VM bundle drops these roots.
{
  # eMudhra intermediate CA compromise (2026-10-20): eight intermediates
  # whose private keys can be recovered from the certificates, chaining to
  # these two roots. Browsers block them via CT and CRLSets/OneCRL, but
  # non-CT clients (curl, git, nix, Python, Go) trust the system bundle.
  # Remove once nixpkgs ships NSS >= 3.131.1 (cacert drops both).
  # https://emudhra.we-have-a-problem.com/
  # Plain list, not mkDefault: entries merge with any other blacklist.
  security.pki.caCertificateBlacklist = [
    "Comodo AAA Services root"
    "emSign ECC Root CA - G3"
  ];
}
