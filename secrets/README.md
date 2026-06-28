# Hydrix Secrets

Encrypted secrets for this hydrix-config. Safe to commit: files are age-encrypted and only your machine can decrypt them.

## File structure

```
secrets/
├── .sops.yaml          # sops config (age recipients) -- commit this
├── github.yaml         # GitHub SSH keys -- commit this
├── wifi.yaml           # WiFi credentials -- commit this (force-add if gitignored)
└── README.md           # This file
```

## First-time setup

### 1. Enable secrets and rebuild

In `machines/<serial>.nix`:

```nix
hydrix.secrets.enable = true;
```

Then rebuild:

```bash
rebuild
```

This generates the age key (derived from the SSH host key) and makes it available to user-level sops commands automatically.

### 2. Create secrets/.sops.yaml

```bash
hydrix-sops-setup
```

This creates `secrets/.sops.yaml` with your machine's age public key. Commit it:

```bash
git add -f secrets/.sops.yaml && git commit -m 'feat(secrets): init sops'
```

### 3. Create encrypted secret files

```bash
# GitHub SSH keys:
sops secrets/github.yaml
```

Example content (decrypted view, sops encrypts on save):

```yaml
id_ed25519: |
  -----BEGIN OPENSSH PRIVATE KEY-----
  b3BlbnNzaC1rZXktdjEA...
  -----END OPENSSH PRIVATE KEY-----
id_ed25519_pub: "ssh-ed25519 AAAAC3NzaC1... user@host"
```

```bash
# WiFi credentials (or use setup-wifi-secrets to migrate from modules/wifi.nix):
sops secrets/wifi.yaml
```

Example content:

```yaml
networks: '[{"ssid":"HomeNetwork","psk":"password","priority":100}]'
```

Use `setup-wifi-secrets` to populate this from an existing `modules/wifi.nix`.

### 4. Declare secrets in your machine config

```nix
hydrix.secrets = {
  enable = true;
  githubSecretsFile = ../secrets/github.yaml;
  wifiSecretsFile   = ../secrets/wifi.yaml;
};

hydrix.microvmHost.vms."microvm-router".secrets = [ "wifi" ];
hydrix.microvmHost.vms."microvm-dev".secrets    = [ "github" ];
```

### 5. Commit and rebuild

```bash
git add -f secrets/github.yaml secrets/wifi.yaml
git commit -m 'feat(secrets): add encrypted credentials'
rebuild
```

## How secrets reach VMs

```
secrets/wifi.yaml (age-encrypted, git-tracked)
  |
  | hydrix-sops-decrypt-wifi.service (host, runs at boot)
  v
/run/secrets/wifi/networks.json (decrypted, tmpfs)
  |
  | hydrix-secrets-microvm-router.service (host)
  v
/run/hydrix-secrets/microvm-router/wifi/ (host, tmpfs)
  |
  | virtiofs (live passthrough)
  v
/mnt/vm-secrets/wifi/networks.json (inside router VM only)
```

Other VMs have no access to `/mnt/vm-secrets/wifi/`. The pentest, browsing, and dev VMs only receive the secret types listed in their `secrets = [...]` declaration.

## Adding arbitrary secrets

The `hydrix.secrets.files` attrset accepts any sops-encrypted YAML file:

```nix
# Whole-file mode (no 'keys'): decrypts the entire file as-is
hydrix.secrets.files.discord = {
  file  = ../secrets/discord.yaml;
  vmDir = "browser";
};
hydrix.microvmHost.vms."microvm-browsing".secrets = [ "discord" ];
```

Inside the browsing VM: `/mnt/vm-secrets/browser/discord.yaml`.

## Applying credential changes without rebuilding

After editing a secrets file, restart the relevant host services:

```bash
sudo systemctl restart hydrix-sops-decrypt-wifi
sudo systemctl restart hydrix-secrets-microvm-router
```

The VM sees the updated file immediately via virtiofs. No rebuild or VM restart required.

## Adding a second machine

Each machine has its own age key derived from its SSH host key.

1. On the new machine after first rebuild: `sops-age-pubkey` to get its public key.
2. Add the key to the `age:` list in `secrets/.sops.yaml`.
3. On a machine that can already decrypt: `sops updatekeys secrets/*.yaml`.
4. Commit the updated `.sops.yaml` and re-encrypted files.

Until this is done, decrypt services exit with a warning and VMs start without secrets.

## Troubleshooting

**`sops: could not decrypt`**

The age key may not be set up yet. Run `rebuild` once to generate and install it.

**Secret not appearing in VM**

Check the host decrypt service:
```bash
journalctl -u hydrix-sops-decrypt-wifi
```

Check the provisioning service:
```bash
journalctl -u hydrix-secrets-microvm-router
```

Check the virtiofs mount inside the VM:
```bash
ls /mnt/vm-secrets/
```

**`wifi-sync list` shows 0 networks after setup**

The `secrets/wifi.yaml` may not be committed. sops files referenced via `wifiSecretsFile` must be git-tracked (Nix copies them into the store at eval time):
```bash
git add -f secrets/wifi.yaml && git commit -m 'feat(secrets): add wifi credentials'
rebuild
```
