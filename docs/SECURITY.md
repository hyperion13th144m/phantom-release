# Deployment security guide

phantom is designed for use inside a trusted office LAN. The application
services do not provide their own end-user authentication, so access control is
normally handled by the deployment environment.

At minimum, use TLS when users access phantom through a browser. If the server
is reachable by more than a very small trusted group, also add Basic
authentication, VPN-only access, or source IP restrictions at nginx or at the
network boundary.

## Recommended baseline

- Do not expose phantom directly to the public internet.
- Put phantom behind nginx, a load balancer, a VPN, or an internal reverse
  proxy.
- Enable HTTPS for browser access, even on an internal LAN.
- Add Basic authentication or IP restrictions when shared office networks,
  guest networks, or unmanaged devices can reach the server.
- Keep certificate private keys and `.htpasswd` files outside the repository.
- Use strong passwords. Basic authentication is only a simple access gate, not a
  complete identity system.
- If Basic authentication is enabled, use it together with HTTPS. Basic
  authentication credentials are only safely protected when the connection is
  encrypted.

## Where this belongs

TLS certificates, Basic authentication files, and nginx access rules are
deployment-specific. They depend on hostnames, certificate authority policy,
LAN/VPN topology, and administrator password management.

For that reason, phantom keeps the default runtime simple and provides sample
nginx configuration for administrators to adapt:

- `infra/nginx/nginx.conf`: default HTTP configuration used by Docker Compose.
- `infra/nginx/examples/nginx-https-basic-auth.conf`: example HTTPS + Basic
  authentication configuration.

## Example file layout

One practical layout on the server is:

```text
phantom-release/
  infra/nginx/examples/nginx-https-basic-auth.conf
  secrets/nginx/.htpasswd
  secrets/nginx/tls/fullchain.pem
  secrets/nginx/tls/privkey.pem
```

The `secrets/` directory is only an example. Do not commit it.

## Create a Basic authentication file

Install a tool that can generate Apache htpasswd files. On Ubuntu:

```bash
sudo apt update
sudo apt install apache2-utils
```

Create the password file:

```bash
mkdir -p secrets/nginx
htpasswd -c secrets/nginx/.htpasswd admin
```

Add more users without `-c`:

```bash
htpasswd secrets/nginx/.htpasswd another-user
```

## Prepare certificates

Choose the certificate method that fits your environment:

- Internal CA: recommended for a corporate LAN when clients already trust the
  company CA.
- Existing reverse proxy or load balancer: terminate TLS there and proxy to
  phantom over the internal network.
- Let's Encrypt: useful if the hostname is publicly resolvable and ACME
  validation is allowed.
- Self-signed certificate: acceptable for a small test LAN, but users will need
  to trust the certificate manually.

Place the certificate and key on the host, for example:

```text
secrets/nginx/tls/fullchain.pem
secrets/nginx/tls/privkey.pem
```

### Create a small local CA with OpenSSL

If there is no company CA and phantom is installed on a local LAN machine
without DNS, create a small local CA and use it to issue the nginx server
certificate. This is usually easier to manage than trusting one self-signed
server certificate on every client.

In the example below, users access phantom at `https://192.168.1.50/`. Replace
`192.168.1.50` with the actual fixed IP address of the phantom server.

Create directories:

```bash
mkdir -p secrets/nginx/ca secrets/nginx/tls
```

Create the local CA private key and CA certificate:

```bash
openssl genrsa -out secrets/nginx/ca/phantom-local-ca.key 4096

openssl req -x509 -new -nodes \
  -key secrets/nginx/ca/phantom-local-ca.key \
  -sha256 -days 3650 \
  -subj "/CN=phantom local CA" \
  -out secrets/nginx/ca/phantom-local-ca.crt
```

Create the nginx server private key:

```bash
openssl genrsa -out secrets/nginx/tls/privkey.pem 2048
```

Create an OpenSSL config file for the server certificate. The `subjectAltName`
value is important. Modern browsers check this value, not only `CN`.

```bash
cat > secrets/nginx/tls/server-openssl.cnf <<'EOF'
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = req_ext

[dn]
CN = phantom.local

[req_ext]
subjectAltName = @alt_names

[alt_names]
IP.1 = 192.168.1.50
EOF
```

Create a certificate signing request:

```bash
openssl req -new \
  -key secrets/nginx/tls/privkey.pem \
  -out secrets/nginx/tls/server.csr \
  -config secrets/nginx/tls/server-openssl.cnf
```

Sign the server certificate with the local CA:

```bash
openssl x509 -req \
  -in secrets/nginx/tls/server.csr \
  -CA secrets/nginx/ca/phantom-local-ca.crt \
  -CAkey secrets/nginx/ca/phantom-local-ca.key \
  -CAcreateserial \
  -out secrets/nginx/tls/fullchain.pem \
  -days 825 -sha256 \
  -extensions req_ext \
  -extfile secrets/nginx/tls/server-openssl.cnf
```

Use these files with nginx:

```text
secrets/nginx/tls/fullchain.pem
secrets/nginx/tls/privkey.pem
```

Install this CA certificate as a trusted certificate on each client PC:

```text
secrets/nginx/ca/phantom-local-ca.crt
```

Do not distribute the CA private key:

```text
secrets/nginx/ca/phantom-local-ca.key
```

Keep the CA private key offline or in a restricted administrator-only location.
Anyone who has the CA private key can issue certificates that client PCs will
trust.

If the server IP address changes, update `IP.1` in
`secrets/nginx/tls/server-openssl.cnf` and issue a new server certificate.

## Use the sample nginx configuration with Docker Compose

The default compose file mounts `infra/nginx/nginx.conf` and exposes
`${NGINX_PORT}:8080`. Do not edit `docker-compose.yml` directly for local
security settings. If the tracked compose file is changed on the deployment
host, a future `git pull` may fail or require manual conflict resolution.

Instead, create a separate local compose file such as
`docker-compose.secure.yml` on the deployment host:

```yaml
services:
  nginx:
    volumes:
      - ./infra/nginx/examples/nginx-https-basic-auth.conf:/etc/nginx/conf.d/default.conf:ro
      - ./infra/nginx/index.html:/usr/share/nginx/html/index.html:ro
      - ./secrets/nginx/.htpasswd:/etc/nginx/.htpasswd:ro
      - ./secrets/nginx/tls:/etc/nginx/tls:ro
    ports:
      - "80:80"
      - "443:443"
```

Make sure `docker-compose.secure.yml` is treated as a deployment-local file and
is not committed.

Then start phantom with both compose files:

```bash
docker compose -f docker-compose.yml -f docker-compose.secure.yml up -d
```

If another service already uses ports 80 or 443, change the host-side port
numbers in `docker-compose.secure.yml`.

## Verify

Check that HTTP redirects to HTTPS:

```bash
curl -I http://phantom.example.local/
```

Check that HTTPS requires authentication:

```bash
curl -k -I https://phantom.example.local/
```

Check with credentials:

```bash
curl -k -u admin https://phantom.example.local/
```

Remove `-k` when using a certificate trusted by the client.

## Optional IP restriction

If the allowed client network is fixed, add `allow` and `deny` directives to the
TLS server block in the sample configuration:

```nginx
allow 192.168.0.0/16;
allow 10.0.0.0/8;
deny all;
```

Use IP restrictions only when the reverse proxy sees the real client IP address.
If another proxy is in front of nginx, configure trusted forwarded headers
carefully before relying on client IP rules.
