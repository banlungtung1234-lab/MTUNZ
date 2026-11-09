# MTUNZ remote signaling + TURN deployment (Linux VPS)

This is an **optional self-hosting template**, not a public service operated by the MTUNZ project. It deploys:

- the Go signaling server in a small, non-root container;
- Caddy as the HTTPS reverse proxy for the signaling API;
- coturn for authenticated TURN relay over UDP and TCP.

The example is intended for a Linux VPS with a public IPv4 address. The coturn service uses host networking because the relay port range is large; the official coturn image documentation recommends host networking for this deployment shape. See [coturn Docker image guidance](https://hub.docker.com/r/coturn/coturn) and [Caddy automatic HTTPS](https://caddyserver.com/docs/automatic-https).

## 1. Requirements

- A Linux VPS with Docker Engine and the Docker Compose plugin.
- Two DNS A records pointing to the VPS public IPv4:
  - `signal.example.com` — signaling HTTPS endpoint.
  - `turn.example.com` — TURN endpoint.
- Permission to open the ports listed below in both the VPS firewall and cloud-provider firewall.

This compose file uses Linux `network_mode: host` for coturn. Do not run this specific TURN container configuration on Windows Docker Desktop as a substitute for a Linux public host.

## 2. Configure secrets and hostnames

From the repository root:

```bash
cp deploy/.env.example deploy/.env
openssl rand -hex 32
```

Edit `deploy/.env`:

1. Replace `MTUNZ_DOMAIN` with the signaling DNS name.
2. Set `TURN_REALM` to the TURN DNS name.
3. Set `TURN_EXTERNAL_IP` to the VPS public IPv4. If the VPS is behind a 1:1 NAT, use coturn's `public-ip/private-ip` form.
4. Replace `MTUNZ_TURN_SHARED_SECRET` with the 64-character hex value printed by `openssl rand -hex 32`.
5. Keep the same secret for the signaling and coturn services. Never commit `deploy/.env` or post its contents publicly.
6. Make sure `MTUNZ_TURN_URLS` matches the TURN hostname.

The signaling server issues coturn REST credentials using the timestamped username and HMAC-SHA1 construction required by coturn's TURN REST API. The shared secret remains server-side; clients receive only temporary credentials. The configured default lifetime is 900 seconds. See [coturn TURN REST API documentation](https://github.com/coturn/coturn/blob/master/README.turnserver).

## 3. Open firewall ports

| Port | Protocol | Purpose |
|---|---|---|
| 80 | TCP | Caddy HTTP challenge / HTTPS redirect |
| 443 | TCP and UDP | HTTPS signaling; UDP also allows HTTP/3 to Caddy |
| 3478 | UDP and TCP | Coturn client connections |
| 49160–49200 | UDP and TCP | Coturn relay allocation range |

This template does not enable TURN-over-TLS on port 5349. The signaling endpoint is HTTPS; TURN transport uses UDP/TCP with time-limited credentials, while WebRTC peer media/data remains encrypted by the peer connection. Add a TURN TLS certificate and `turns:` endpoint separately when a network requires TLS-only relay.

## 4. Validate and start

From the repository root:

```bash
docker compose --env-file deploy/.env -f deploy/compose.yaml config --quiet
docker compose --env-file deploy/.env -f deploy/compose.yaml up -d --build
docker compose --env-file deploy/.env -f deploy/compose.yaml ps
docker compose --env-file deploy/.env -f deploy/compose.yaml logs -f signaling coturn caddy
```

Caddy can obtain and renew the HTTPS certificate after the signaling DNS record resolves publicly and TCP ports 80/443 are reachable. The Go server remains private to the Compose network; do not publish port 8787 directly.

Check:

```bash
curl https://signal.example.com/healthz
```

The response should contain `"ok":true`. Then set the MTUNZ server URL on both devices to:

```text
https://signal.example.com
```

When a device joins a room, the signaling API returns the temporary TURN credentials and configured ICE URLs automatically.

## 5. Troubleshooting relay connectivity

- If `/healthz` fails, check `docker compose logs signaling caddy`, DNS, and ports 80/443.
- If rooms work but the peer connection never reaches connected, check `docker compose logs coturn`, the TURN DNS record, `TURN_EXTERNAL_IP`, the shared secret, and the full relay port range.
- If the VPS is behind NAT, verify that the public-to-private address mapping is correct and that every relay port is forwarded.
- Do not expose the coturn shared secret, temporary TURN credentials or `deploy/.env`.
- A successful container start is not proof of external NAT traversal. Test from two devices on different networks and inspect whether ICE selects a relay candidate.

## 6. Stop and upgrade

```bash
docker compose --env-file deploy/.env -f deploy/compose.yaml down
```

Before upgrading, back up `deploy/.env`, review image versions and rebuild the signaling container. Caddy certificate state is stored in Docker volumes `caddy_data` and `caddy_config`; keep these volumes between restarts.
