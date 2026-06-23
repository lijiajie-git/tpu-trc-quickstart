# Contributing

Field experience contributions are welcome. The content of this repo drifts with GCP/TRC behavior; the most valuable PRs distill new pitfalls / new models you have hit into the repo.

## What to add and where

| What you want to add | Where it goes |
|---|---|
| New error → handling | `references/error-map.md` (classified by capacity / structural / SSH / billing) |
| New TPU model / runtime | `SKILL.md` §5 command matrix + `resources.conf.template` comments |
| New zone quota experience | `resources.conf.example` + note the verification date |
| Process improvement | The corresponding section of `SKILL.md` |

## Rules

- **Run shellcheck on script changes first** (locally — there is no CI), and keep them **bash 3.2 compatible** (the version bundled with macOS has no `declare -A`, no `timeout`).
- **Time-sensitive assertions carry a date**: when writing "field-tested X", note the SDK version + date (this feeds the last-verified field in `CHANGELOG.md`).
- **Do not include any real credentials / project ID / email**: `resources.conf` is already in `.gitignore`; use `<PLACEHOLDER>` or `example-*` in PRs.
- Style: Chinese-primary, English commands; terse, tables first, data first.
