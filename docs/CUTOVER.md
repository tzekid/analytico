# Direct cutover from Plausible

This runbook starts Analytico with fresh databases. Historical Plausible data
is not required for cutover and is not imported. Keep Plausible intact until
the final owner checkpoint.

## 1. Verify and install the release

On the target host:

```sh
sha256sum -c analytico-0.1.0-linux-x86_64.tar.gz.sha256
tar --same-permissions -xzf analytico-0.1.0-linux-x86_64.tar.gz
cd analytico-0.1.0-linux-x86_64
sha256sum -c SHA256SUMS
sudo install -d -o root -g root -m 0755 /opt/analytico
sudo cp -a bin lib public docs LICENSES deploy \
  README.md LICENSE THIRD_PARTY_NOTICES.md versions.json /opt/analytico/
```

The installed `bin/` and `lib/` directories must remain root-owned and
unwritable by the service account.

## 2. Initialize fresh storage

```sh
sudo useradd --system --home-dir /var/lib/analytico \
  --shell /usr/bin/nologin analytico
sudo install -d -o analytico -g analytico -m 0700 /var/lib/analytico
sudo -u analytico /opt/analytico/bin/analytico init /var/lib/analytico
```

For each site, add the public origin and any custom-event properties that
should be retained:

```sh
sudo -u analytico /opt/analytico/bin/analytico \
  site add /var/lib/analytico example "Example" https://example.com
sudo -u analytico /opt/analytico/bin/analytico \
  site property-add /var/lib/analytico example plan
sudo -u analytico /opt/analytico/bin/analytico \
  goal add /var/lib/analytico example signup event signup
sudo -u analytico /opt/analytico/bin/analytico \
  funnel add /var/lib/analytico example signup-flow \
  path=/pricing event=signup
sudo -u analytico /opt/analytico/bin/analytico \
  auth configure /var/lib/analytico https://analytics.example
```

`site add`, goal, and funnel commands fail if an identifier is invalid or
already exists. Run `analytico doctor /var/lib/analytico` after setup.

## 3. Install the tracker and merge CSP

Generate the exact snippet for each configured site:

```sh
sudo -u analytico /opt/analytico/bin/analytico \
  site install /var/lib/analytico example https://analytics.example
```

Copy its `<script>` and `<noscript>` elements into the site's HTML. Merge the
printed collector origin into the site's existing `script-src`, `connect-src`,
and `img-src` directives. Do not replace the entire Content-Security-Policy.
The script is deferred, has no dependency, and the noscript pixel records a
bounded pageview when JavaScript is disabled.

## 4. Start the process and canonical hostname

Replace `analytics.example` in `deploy/Caddyfile`, then:

```sh
sudo install -m 0644 deploy/analytico.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now analytico
curl --fail http://127.0.0.1:4318/readyz
caddy validate --config deploy/Caddyfile
```

Install or import the validated Caddy vhost. The tracker and collection routes
remain public; `/admin` and `/admin/*` are protected by Analytico's server-side
passkey session; `/` redirects to `/admin`; unknown paths return `404`. The
process remains bound to loopback.

## 5. Enroll and accept the owner passkey

With the service running behind TLS, print one ten-minute setup link without
copying it to logs or chat:

```sh
sudo -u analytico /opt/analytico/bin/analytico \
  auth bootstrap /var/lib/analytico --ttl 10m
```

Open it on the intended Apple device, create the synced owner passkey, then:

- prove `/admin/security` lists it without exposing credential material;
- add an independent second passkey when practical;
- sign out and perform a fresh passkey login;
- open the dashboard with JavaScript disabled after login;
- verify an anonymous browser receives the login page and no report state.

Record the actual Safari, Touch ID or Face ID, and iCloud synchronization check
as a manual platform result. A virtual authenticator proves the protocol and
server behavior but cannot prove Apple's synchronization UI.

## 6. Site acceptance checklist

Repeat this for every site before changing Plausible:

- Open a normal page and a second page in a browser.
- Trigger one expected custom event.
- Confirm the browser console has no CSP or network errors.
- Confirm `readyz` is `200`.
- Run today's overview, pages, sources, events, goal, and funnel reports.
- Confirm the observed paths, source, event, and counts are plausible.
- Confirm the site's tracker and noscript URLs use its generated UUID.
- Confirm the site's CSP contains the collector origin in all three directives.

Example report:

```sh
today=$(date -u +%F)
sudo -u analytico /opt/analytico/bin/analytico \
  report /var/lib/analytico example "$today" "$today" overview
```

## 7. Take and verify the first backup

```sh
sudo systemctl stop analytico
stamp=$(date -u +%Y-%m-%dT%H%M%SZ)
sudo -u analytico /opt/analytico/bin/analytico \
  backup /var/lib/analytico "/var/backups/analytico/$stamp"
sudo -u analytico /opt/analytico/bin/analytico \
  restore "/var/backups/analytico/$stamp" \
  "/var/backups/analytico/verify-$stamp" --verify
sudo -u analytico /opt/analytico/bin/analytico \
  doctor "/var/backups/analytico/verify-$stamp"
sudo systemctl start analytico
curl --fail http://127.0.0.1:4318/readyz
```

Keep the verified backup and release archive together. Restore and rollback
details are in `OPERATIONS.md`.

## 8. Optional Plausible history archive

This is separate from Analytico cutover. It does not modify or import history.
For a full export, use Plausible's site settings under **Imports & Exports →
Export Data → Export to CSV**, following
[Plausible's export documentation](https://plausible.io/docs/export-stats).

An optional aggregate JSON snapshot can be requested independently through
[Plausible Stats API v2](https://plausible.io/docs/stats-api):

```sh
read -rsp 'Plausible Stats API key: ' PLAUSIBLE_TOKEN
printf '\n'
read -rp 'Plausible site ID: ' PLAUSIBLE_SITE
curl --fail-with-body --silent --show-error \
  -X POST "${PLAUSIBLE_BASE_URL:-https://plausible.io}/api/v2/query" \
  -H "Authorization: Bearer $PLAUSIBLE_TOKEN" \
  -H 'Content-Type: application/json' \
  --data '{"site_id":"'"$PLAUSIBLE_SITE"'","metrics":["visitors","visits","pageviews","events"],"date_range":"all"}' \
  > plausible-summary.json
unset PLAUSIBLE_TOKEN PLAUSIBLE_SITE
```

Treat exported files as private analytics data. The aggregate snapshot is not
a substitute for Plausible's full CSV export.

## 9. Owner checkpoint

Do not delete Plausible, PostgreSQL, ClickHouse, their volumes, or exports as
part of the cutover. Stop the old stack only after:

- every site passes the acceptance checklist;
- a verified Analytico backup exists;
- any desired Plausible export has completed and been copied off-host; and
- the owner accepts starting Analytico with fresh history; and
- passkey logout and fresh login both work from the intended device.

If acceptance fails, remove the Analytico tracker snippet, restore the prior
CSP, and keep Plausible unchanged.
