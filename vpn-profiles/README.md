# VPN Profiles Directory

Place your VPN configuration files here. They will be copied to the router VM
and can be activated using `vpn-assign`.

## Directory Structure

```
vpn-profiles/
├── wireguard/          # WireGuard configs (.conf)
│   ├── mullvad.conf
│   ├── client-vpn.conf
│   └── corp-vpn.conf
├── openvpn/            # OpenVPN configs (.ovpn or .conf)
│   ├── client.ovpn
│   └── corp.ovpn
└── README.md
```

## WireGuard Configuration Format

Example `mullvad.conf`:
```ini
[Interface]
PrivateKey = YOUR_PRIVATE_KEY
Address = 10.x.x.x/32
DNS = 10.64.0.1

[Peer]
PublicKey = SERVER_PUBLIC_KEY
Endpoint = SERVER:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
```

## OpenVPN Configuration

Place standard `.ovpn` files in the `openvpn/` directory.

## Deploying to Router VM

After placing configs here, copy them to the router:

```bash
# From host (after router is running)
scp -r vpn-profiles/wireguard/* traum@10.100.0.253:/etc/wireguard/
scp -r vpn-profiles/openvpn/* traum@10.100.0.253:/etc/openvpn/client/
```

Or include them in the router VM image by editing `modules/router-vm-unified.nix`.

## Usage on Router

```bash
# Connect a VPN
vpn-assign connect mullvad

# Assign network to VPN
vpn-assign pentest mullvad
vpn-assign browse mullvad

# Check status
vpn-status
```
