# M6 server-rendered dashboard evidence

Measured on 2026-07-31 on the target Linux x86-64 VPS. Both Debug and
ReleaseSafe ran the real listener, embedded stores, Caddy, and Chromium.

## Complete first response

The first `/admin` response contains site selection, UTC date filters, report
navigation, overview values, goal/funnel definitions, and native management
forms. Its only subresource is the local stylesheet. There is no script,
startup API request, JSON mirror, client state store, cookie, local storage, or
session storage.

The ReleaseSafe fixture measured:

| Observation | Result | Budget |
| --- | ---: | ---: |
| Compressed first-view HTML | 1,283 bytes | ≤ 32 KiB |
| Compressed CSS | 905 bytes | ≤ 12 KiB |
| Initial requests | 2 | ≤ 3 |
| Application-authored JavaScript | 0 bytes | ≤ 2 KiB |
| API/JSON startup requests | 0 | 0 |
| RSS change after 100 complete dashboard views | -1,388 KiB | no retained per-request state |

Chromium used a 360×640 viewport, JavaScript disabled, 180 ms latency, a
64 KiB/s download ceiling, and a 32 KiB/s upload ceiling for the first view.
The useful overview was complete at `load`; network throttling was removed only
after first-view assertions.

## Real application coverage

The browser navigates overview, pages, entries, exits, sources, campaigns,
countries, browsers, operating systems, devices, events, a goal, and a funnel.
It requests a one-row report page and follows the native next link.

Through ordinary HTML forms it:

- receives a complete `422` page for an invalid goal while preserving fields;
- adds and deletes a valid goal using POST/redirect/GET; and
- adds and deletes a two-step funnel using POST/redirect/GET.

An intentionally hostile goal name containing HTML, quotes, ampersand, and
slashes passes through Turso, URL construction, HTTP, and Chromium as text.
No script node is created. Text, attribute, and URL contexts use separate
escaping rules, including control-byte replacement.

## Boundary and failure behavior

The exact checked-in dashboard Caddy template is adapted only for disposable
ports. A request without credentials receives `401`; authenticated requests
reach Analytico. A valid CSRF token submitted with a foreign `Origin` receives
a complete escaped `403` page and does not create the goal.

The service is then restarted with the supported 1 ms report deadline against
the real one-million-event fixture. The interrupted report returns a complete
`503` HTML page explaining the timeout and offering a safe dashboard link; the
same authenticated process continues serving its stylesheet.

The renderer imports only typed view data and formatting primitives. The
controller owns store reads, report execution, validation, and metadata writes.
Two identical authenticated report requests produce byte-identical HTML.
