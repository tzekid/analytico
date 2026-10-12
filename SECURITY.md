# Security and trust boundaries

Analytico is a self-hosted web analytics service. Its tracker sends bounded analytics records from websites that deliberately install it. It does not read browser credential stores, execute model-generated commands, expose a shell, scan local files, or authenticate to unrelated services on a visitor's behalf.

## Data collection

- Lite is the default. It stores no browser identifier.
- Session mode uses a random per-tab identifier in `sessionStorage`.
- Full mode is an explicit choice. Persistent identity, heatmaps and replay require a consented visitor or a site policy that says consent is not required. Global Privacy Control always wins.
- Raw IP addresses, complete URLs, query strings, arbitrary form values and selected text are not stored.
- Form analytics runs only on forms marked `data-analytics-form`, never records values, and excludes password, payment, token and secret-like fields. Fields use an explicit `data-analytics-field` label or a structural ordinal; DOM names and IDs are not collected.
- Replays always mask all text and input values before upload. Their final serializer also removes URL queries and fragments, hidden-field values and arbitrary attributes. Server ingestion binds every chunk to the exact consented page, visitor and session and applies page exclusions again.

## Authentication and authorization

- Browser sessions are created only by a configured sign-in ceremony. The CLI cannot mint browser sessions.
- Session, invite, OAuth, API and share tokens are stored as hashes. Provider credentials are encrypted with the instance key.
- Password changes revoke every browser session, OAuth grant and registered push device for that account before creating the replacement browser session.
- Roles and per-site grants are checked on the server. Instance-wide sign-in policy and provider credentials require Admin.
- Native-app tokens, API keys and MCP tokens have separate endpoints and scopes.

## AI boundary

AI is optional. Model-facing tools use an explicit allowlist of aggregate reports. Stable session identifiers, recent row-level activity, individual timelines, visitor records, replays and site-search terms are unavailable to AI and MCP. Page paths and traffic sources have separate disclosure controls. Every model request and aggregate payload is logged for the operator.

No model response is executed as code or a command. AI tools are fixed, read-only report functions implemented in-process.

## External services

Outbound connections are explicit operator features: configured identity and AI providers, mail, selected analytics integrations and Apple Push Notification service. The APNs relay binds to loopback and is not a public service. Signed internal ingestion is expected to remain on loopback behind the supplied Caddy configuration.

## Reporting a problem

When reviewing a suspected issue, distinguish synthetic test credentials and local stand-ins from production access. A valid report should identify the entry point, the violated boundary and the smallest reproducible input. Do not include real visitor data, access tokens or private keys.

Use bounded regression tests rather than exploit chains. Reviews must not mint reusable sessions or credentials, deliberately terminate the service, or save bearer tokens, cookies, signed requests or crash stacks in evidence artifacts. Verify malformed and extreme inputs through expected error responses and continued readiness.
