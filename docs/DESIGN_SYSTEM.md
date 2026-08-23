# Analytico 1.0 design system

Status: normative visual-token contract for Analytico 1.0. Issue #15 owns the
first production mapping. Later shell, component, chart, and mobile work may
consume these tokens but must not silently redefine them.

## Authority and references

`design-tokens.json` is the machine-readable source. `src/web/style.css`
mirrors every token as a CSS custom property using its JSON group and key, for
example `light.brandStrong` becomes `--color-brandStrong` and `space.4`
becomes `--space-4`.

The planning package's written design language, token rules, responsive rules,
and deterministic HTML/CSS prototype clarify intended presentation. The
prototype is a hierarchy and behavior reference, not production markup. The
two AI exploration boards are non-binding and cannot override written product,
accessibility, data, or server-rendering contracts.

## Production mapping

Analytico uses system UI fonts, a Georgia serif wordmark, and tabular lining
figures for metrics, dates, and numeric table cells. It loads no external font
or CSS dependency.

Brand red is an interaction and focus signal, not a status color or page
background. The approved light `brand` token does not provide 4.5:1 contrast
with normal white text, so light links and filled actions use `brandStrong`;
hover uses `brandHover`. Dark links and actions use `brand`. Filled-action text
uses the theme canvas token. These are functional aliases over approved tokens,
not palette changes.

The warm `borderStrong` token is suitable for structural separation but does
not alone reach the 3:1 non-text contrast threshold against every surface.
Inputs and secondary buttons therefore use the approved `inkMuted` token as
their functional control border in both themes.

Successful notices use `positive` and `positiveWash`. Errors use `danger` and
`dangerWash`. Warning tokens are reserved for explicitly labeled incomplete or
risk states; normal warning text uses readable ink on `warningWash` rather than
assuming the warning hue is always a normal-text foreground. Color never
replaces status text, signs, labels, or ARIA roles.

The CSS also defines two non-palette implementation values from the written
design language: 120 ms interaction transitions and a minimal panel shadow.
Reduced-motion preference removes transitions. These do not change the
machine-readable color, spacing, radius, type, or layout tokens.

## Ticket boundary

Issue #15 applies tokens to the existing server-rendered dashboard and owner
authentication pages. The current pre-1.0 page frame retains its existing
76 rem content width until issue #16 implements the approved shell and consumes
the 216 px sidebar and 1440 px content tokens. Issue #17 owns new shared
components, chart primitives, warning/empty/loading variants, and mobile record
tables. No prototype shell or component markup is copied by this token ticket.

The stylesheet is self-hosted at a versioned `/admin/app.v3.css` path. Changing
its bytes requires another path revision because existing responses may be
cached privately for 24 hours.

## Verification

`zig build test` parses `design-tokens.json`, verifies that every token has an
exact production CSS declaration, checks the intended normal-text contrast
pairs, and rejects external CSS/font loading. The real dashboard browser
scenario checks computed light and dark theme values, functional action/link
mappings, numeric figures, wordmark typography, and mobile touch targets.

The production budget remains 12 KiB gzip for CSS. Record raw and gzip bytes in
the issue/PR evidence using the exact embedded stylesheet served by the real
dashboard route. Light, dark, desktop, and mobile review compares hierarchy and
semantics with the deterministic references rather than requiring pixel
identity.
