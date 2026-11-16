# Deploying to AWS (Lightsail)

One small server runs the whole stack with Docker Compose (decision D41). Caddy, already the `ui` service, gets an HTTPS certificate from Let's Encrypt and asks for a username and password before anything else. The database and API have no published ports. Cost: about $12 a month for the server, plus a domain if you use one.

```
Browser ──HTTPS + login──► ui: Caddy (80/443) ──► api: PostgREST ──► db: PostgreSQL
```

What changes from local dev: `compose.prod.yaml` replaces `compose.override.yaml`, and `deploy/caddy/Caddyfile` replaces the Caddyfile in the ui image. Everything else is the same.

**Know before you start**
- Anyone who logs in can use both tenants (LIVE and DEMO), including "Reset demo data" on DEMO.
- The audit log records the login name; the "Your name" box in the UI is ignored on the server.
- There's no logout: the browser remembers the login until it is closed.
- Nobody can reset their own password; you set it with `scripts/users.sh`.

## 1. Create the server

In the [Lightsail console](https://lightsail.aws.amazon.com/):

1. **Create instance**: pick a region near your users (e.g. London), **Linux/Unix**, **OS Only**, **Ubuntu 24.04 LTS**, the **$12 plan (2 GB RAM, dual-stack)**, name it `accomm`, **Create instance**.
2. **Networking** tab of the instance:
   - **Create static IP** and attach it to `accomm` (free while attached). Note the address, e.g. `3.8.123.45`.
   - **IPv4 firewall**: keep `SSH 22` and `HTTP 80`, **add rule** `HTTPS 443`. Optionally edit SSH and tick "Allow Lightsail browser SSH" with no other sources, so SSH is only open to the browser console.
   - **IPv6 firewall**: the same rules (or turn IPv6 networking off).
3. **Snapshots** tab: turn on **automatic snapshots** (daily backup of the whole server, a few cents a month).

## 2. Choose the address

The site needs a host name that points at the static IP, for the HTTPS certificate.

- **Your own domain**: at your DNS provider, add an `A` record, e.g. `accomm.example.com → 3.8.123.45`. Use that as `SITE_ADDRESS`.
- **No domain yet**: use `3-8-123-45.sslip.io` (the IP with dashes). [sslip.io](https://sslip.io) answers with the IP inside the name, so it works straight away. Fine for trying it out; use a real domain for anything lasting.

Check from your own machine that the name answers with the static IP:

```bash
nslookup accomm.example.com
```

## 3. Install Docker on the server

Open the instance's **Connect using SSH** (browser console) and run:

```bash
sudo apt-get update && sudo apt-get install -y docker.io docker-compose-v2 git
```

```bash
sudo usermod -aG docker ubuntu
```

Add 2 GB of swap so the UI build doesn't run out of memory:

```bash
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile && echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

Close the console and open it again (so the `docker` group applies), then check:

```bash
docker compose version
```

It should print `Docker Compose version v2.x`.

## 4. Get the code

```bash
git clone https://github.com/jackent601/TC26_4.git accomm && cd accomm && git checkout aws-host
```

If the repository is private, git asks for a username and password: give your GitHub username and a [fine-grained personal access token](https://github.com/settings/personal-access-tokens) with read-only **Contents** access to this repository only.

## 5. Settings

Create `.env` with random passwords (change `SITE_ADDRESS` to yours):

```bash
cat > .env <<EOF
POSTGRES_PASSWORD=$(openssl rand -hex 24)
API_DB_PASSWORD=$(openssl rand -hex 24)
COMPOSE_FILE=compose.yaml:compose.prod.yaml
SITE_ADDRESS=accomm.example.com
EOF
chmod 600 .env
```

`COMPOSE_FILE` makes every `docker compose` command and script on the server use the production setup. The other settings in `.env.example` keep their defaults.

## 6. Add users

At least one user is needed before the site starts.

```bash
scripts/users.sh set alice
```

It asks for the password twice (12 characters or more). Or let it make one, printed once for you to send to the person privately:

```bash
scripts/users.sh set bob --generate
```

Expected: `Password set for alice.`

## 7. Start it

```bash
scripts/deploy.sh
```

The first run builds the UI and takes several minutes. It ends with:

```
https://accomm.example.com/ : asks for a login (401). Deployed.
```

Open `https://accomm.example.com` in a browser: it asks for a username and password, then shows the app. Choose **DEMO** in the side bar for the sample data; LIVE starts empty.

The stack restarts by itself when the server reboots.

## Day to day

| Task | Command (on the server, in `~/accomm`) |
|---|---|
| Add a user, or change a password | `scripts/users.sh set <username>` (or `--generate`) |
| Remove a user | `scripts/users.sh remove <username>` |
| List users | `scripts/users.sh list` |
| Deploy the latest code | `git pull && scripts/deploy.sh` |
| See what's running | `docker compose ps` |
| Logs | `docker compose logs --tail 50 ui` (or `api`, `db`) |
| Stop / start | `docker compose down` / `scripts/deploy.sh` (data is kept) |

User changes restart Caddy, a second or two of downtime. Usernames may use letters, digits and `. _ @ -`. Passwords are stored only as bcrypt hashes, in `deploy/caddy/users.caddy` (not in git).

## If something goes wrong

- **`deploy.sh` ends with got `000`**: no answer. Check the DNS name gives the static IP and the firewall has 80 and 443 open, then look at `docker compose logs ui` for certificate errors. Let's Encrypt needs port 80 open to issue the certificate.
- **got `502`**: Caddy is up but the API isn't: `docker compose logs api`.
- **The build stops with "killed"**: out of memory; check the swap from step 3 is on (`free -h`).
- **Login keeps being refused**: set the password again with `scripts/users.sh set <username>`.
