# Architecture

```text
browser -> Caddy -> analytico serve -> SQLite <- analytico report ...
app backend -------> signed /i ---------^
```

The runtime is one executable. SQLite is compiled from `vendor/sqlite`; Caddy
owns TLS. The server listens on loopback by default and commits accepted
records directly before returning 204.

`analytico.db` contains configuration, raw evidence, report definitions,
campaign spend, and safe aggregate diagnostics. `secret.key` supplies the
daily visitor HMAC. Each site has a separate internal-ingestion secret.

The schema is append-oriented. Sessions and funnels are derived by fixed SQL;
there is no session or rollup table initially. JSON columns contain only
canonical bounded arrays or flat scalar property maps accepted by the closed
protocol.

Normal startup never migrates. `init` creates the current schema and `migrate`
advances older numbered schemas explicitly. `serve` and report commands reject
newer or older schemas.

The HTTP server has bounded headers and bodies and serves one request per
connection. SQLite serializes the single write owner. There is no ingestion
worker or accepted-but-not-durable state.
