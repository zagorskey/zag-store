# Zag Mobile Data Toggle

Generator and inspector for the official **Zag Mobile Data Toggle** Shortcut
(protocol v1), which Zag Store runs with `status`, `off` or `on`.

| Input    | Behaviour                                                   | Output                                           |
|----------|-------------------------------------------------------------|--------------------------------------------------|
| `status` | changes nothing                                             | `zag-mobile-data-toggle:v1:ready`                |
| `off`    | Set Mobile Data **Off** (explicit, never Toggle)            | `zag-mobile-data-toggle:v1:off:done`             |
| `on`     | Set Mobile Data **On** (explicit, never Toggle)             | `zag-mobile-data-toggle:v1:on:done`              |
| other    | changes nothing                                             | `zag-mobile-data-toggle:v1:error:unknown-command` |

## Build and sign

    python3 -I build.py unsigned.shortcut
    shortcuts sign --mode anyone --input unsigned.shortcut --output "Zag Mobile Data Toggle.shortcut"

`shortcuts sign` only signs the file; Apple's signing does not check that the
actions are configured correctly. Only running it in Shortcuts proves that.

## Inspect

    python3 -I inspect.py "Zag Mobile Data Toggle.shortcut"

Verifies the AEA signature against the file's own Apple certificate chain,
unpacks `Shortcut.wflow` and prints every action with all its parameters.
Use it to compare generated files with shortcuts exported from Apple's editor.

## History

- `dist/Zag Mobile Data Toggle build1-failed.shortcut`: imports, but every
  command fails with "Please choose a value for each parameter in this
  action." (iPhone, iOS 27.2, and reproduced on macOS with `shortcuts run`).
  Kept for comparison.
