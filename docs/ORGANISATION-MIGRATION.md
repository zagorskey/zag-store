# Moving the repositories to the zagstore organisation

The repositories are moving from the `zagorskey` account to the `zagstore`
organisation. Shipped versions of Zag Store contain the original URLs, so
each repository is checked for what installed copies depend on before it
moves. This document records that check.

## Excluded from transfer: `zagorskey/zag-store-releases`

**Do not transfer, rename, delete or recreate `zagorskey/zag-store-releases`
while Beta 2 installations depend on it.**

Beta 2 finds Beta updates by downloading signed update information from
`https://raw.githubusercontent.com/zagorskey/zag-store-releases/main/releases/v2/beta.json`.
The shipped code fixes that location:

- `ZagUpdateV2Discovery.fetchVerified` accepts only the host
  `raw.githubusercontent.com` and a path starting with
  `/zagorskey/zag-store-releases/`.
- The same request refuses every HTTP redirect, so that the signed bytes
  always come from the pinned location.
- `ZagUpdateMetadataV2` accepts an `ipaURL` only under
  `https://github.com/zagorskey/zag-store-releases/releases/download/`.

GitHub serves a transferred or renamed repository from its old address only
through redirects. Beta 2 refuses those, so after a transfer every Beta 2
installation would fail to find updates, and could not be told about the
problem in the app. Recreating a repository with the old name would also
break the redirects that other links rely on.

The repository can move once no supported version depends on the original
location. That requires a later Beta that reads update information from the
new location, and enough time for Beta 2 installations to update to it.

## Other repositories

| Repository | Used by shipped versions as | Effect of a transfer |
|---|---|---|
| `zagorskey/zag-store` | Links in Settings and About | Links keep working through GitHub's redirect |
| `zagorskey/Zsign-Zag` | Build-time package dependency | Builds keep working through the redirect; update the package URL afterwards |
| `zagorskey/zag-store-releases`, unsigned channel files (`releases/<channel>.json`) | Stable and Nightly update checks | These requests follow redirects, but this repository is excluded anyway |

Installation URLs for released IPAs are under
`zagorskey/zag-store-releases`, so they are unaffected while that repository
stays in place.

## Before any transfer

1. Confirm the current Beta 2 update information is valid and not close to
   expiry.
2. Transfer one repository at a time and check its old URLs afterwards.
3. Do not create a new repository under `zagorskey` with the name of a
   transferred one.
