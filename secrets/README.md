# Hydrix Secrets Management

Secure secrets provisioning for MicroVMs using [sops-nix](https://github.com/Mic92/sops-nix).

## Overview

- **Encrypted secrets committed to repo** - safe because only your machine can decrypt them
- **Age key derived from SSH host key** - no additional key management needed
- **Per-VM opt-in** - only VMs with `secrets.github = true` receive the keys
- **Automatic provisioning** - keys appear in `~/.ssh/` inside the VM

## Security Model

| What | Where | Committed? | Safe? |
|------|-------|------------|-------|
| Encrypted secrets | `secrets/github.yaml` | Yes | Encrypted with your age key |
| Sops config | `secrets/.sops.yaml` | No | Contains machine-specific age public key |
| Age private key | `/var/lib/sops-nix/` | No | Derived from SSH host key at boot |
| Decrypted secrets | `/run/secrets/` | No | Tmpfs, never persisted |
| VM secrets | `~/.ssh/` in VM | No | Copied at VM boot |

## Quick Start

### 1. Enable secrets in your host config

Edit your machine config (`~/hydrix-config/machines/<hostname>.nix`):
```nix
hydrix.secrets = {
  enable = true;
  github.enable = true;
};

hydrix.microvmHost.vms.microvm-browsing-test = {
  enable = true;
  secrets.github = true;  # Provision to this VM
};
```

### 2. Enable in the microVM module

Edit `modules/microvm/microvm-browsing.nix` (or whichever VM):
```nix
hydrix.microvm.secrets.github = true;
```

### 3. Rebuild to generate the age key

```bash
rebuild
```

### 4. Get your age public key

```bash
sops-age-pubkey
# Output: age1abc123def456...
```

### 5. Set up sops CLI access

The age key is in `/var/lib/sops-nix/age-key.txt` (root-owned). For CLI usage:

```bash
mkdir -p ~/.config/sops/age
sudo cp /var/lib/sops-nix/age-key.txt ~/.config/sops/age/keys.txt
sudo chown $USER:users ~/.config/sops/age/keys.txt
chmod 600 ~/.config/sops/age/keys.txt
```

### 6. Create your sops config

```bash
cd ~/Hydrix/secrets
cp .sops.yaml.example .sops.yaml
```

Edit `.sops.yaml` and replace `AGE_PUBLIC_KEY_PLACEHOLDER` with your key from step 4.

### 7. Create and encrypt your secrets

```bash
cp github.yaml.example github.yaml
```

Edit `github.yaml` with your actual SSH keys. Format:
```yaml
id_ed25519: |
  -----BEGIN OPENSSH PRIVATE KEY-----
  b3BlbnNzaC1rZXktdjEAAAAABG5vbmUA...
  ...more lines...
  -----END OPENSSH PRIVATE KEY-----
id_ed25519_pub: "ssh-ed25519 AAAAC3NzaC1... user@host"
```

**Important**: The private key content must be indented (2 spaces) under `id_ed25519: |`

Encrypt:
```bash
sops -e -i github.yaml
```

Verify:
```bash
cat github.yaml      # Shows encrypted content
sops -d github.yaml  # Shows decrypted content
```

### 8. Commit and rebuild

```bash
git add secrets/github.yaml
rebuild
microvm build microvm-browsing-test
microvm start microvm-browsing-test
```

### 9. Test in the VM

```bash
microvm app microvm-browsing-test alacritty
# In the VM terminal:
ssh -T git@github.com
# Should output: Hi username! You've successfully authenticated...
```

## How It Works

```
┌─────────────────────────────────────────────────────────────────┐
│                         HOST                                     │
│                                                                  │
│  1. Boot: Age key derived from /etc/ssh/ssh_host_ed25519_key    │
│           → /var/lib/sops-nix/age-key.txt                       │
│                                                                  │
│  2. Activation: sops-nix decrypts secrets/github.yaml           │
│           → /run/secrets/github/id_ed25519{,.pub}               │
│                                                                  │
│  3. VM Start: hydrix-secrets-<vm> copies keys                   │
│           → /run/hydrix-secrets/<vm>/ssh/                       │
│                                                                  │
│  4. VM Start: microvm-virtiofsd shares directory via virtiofs   │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ virtiofs
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                      MICROVM                                     │
│                                                                  │
│  5. Boot: /mnt/vm-secrets mounted via virtiofs                  │
│                                                                  │
│  6. Boot: hydrix-secrets-provision copies to user               │
│           → ~/.ssh/id_ed25519 (mode 600)                        │
│           → ~/.ssh/id_ed25519.pub (mode 644)                    │
│           → ~/.ssh/known_hosts (github.com added)               │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

## File Structure

```
secrets/
├── .sops.yaml.example   # Template with placeholder - committed
├── .sops.yaml           # Your config with age key - gitignored
├── github.yaml.example  # Template showing format - committed
├── github.yaml          # Your encrypted secrets - committed (safe!)
└── README.md            # This file
```

## Troubleshooting

### sops: "no identity matched any of the recipients"

The age key isn't accessible. Set up CLI access (step 5 above) or use:
```bash
sudo SOPS_AGE_KEY_FILE=/var/lib/sops-nix/age-key.txt sops -d github.yaml
```

### VM doesn't have ~/.ssh/id_ed25519

Check if the provisioning service ran:
```bash
# On host
sudo journalctl -u hydrix-secrets-microvm-browsing-test

# In VM
sudo journalctl -u hydrix-secrets-provision
```

Check if the virtiofs mount exists:
```bash
# In VM
sudo ls -la /mnt/vm-secrets/ssh/
```

### Secrets mount is empty

Ensure both sides are configured:
- Host: `hydrix.microvmHost.vms.<name>.secrets.github = true`
- Guest: `hydrix.microvm.secrets.github = true`

Rebuild both host and VM after changes.

### Permission denied on /mnt/vm-secrets

This is expected - the mount is root-owned for security. The provisioning service copies keys to `~/.ssh/` with correct ownership.

## Adding to Other VMs

1. In `local/machines/host.nix`, add to the VM config:
   ```nix
   hydrix.microvmHost.vms.microvm-pentest-test = {
     enable = true;
     secrets.github = true;
   };
   ```

2. In the VM module (e.g., `modules/microvm/microvm-pentest.nix`):
   ```nix
   hydrix.microvm.secrets.github = true;
   ```

3. Rebuild host and VM:
   ```bash
   rebuild
   microvm build microvm-pentest-test
   ```

## Editing Encrypted Secrets

```bash
cd ~/Hydrix/secrets
sops github.yaml  # Opens in $EDITOR, saves encrypted
```

Or decrypt, edit, re-encrypt:
```bash
sops -d github.yaml > /tmp/secrets.yaml
# Edit /tmp/secrets.yaml
sops -e /tmp/secrets.yaml > github.yaml
rm /tmp/secrets.yaml
```

After editing, rebuild and restart VMs to pick up changes.
