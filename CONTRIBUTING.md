# Contributing

Thanks for looking. This is a v1 blueprint and feedback is the point. Small fixes count.

## Good contributions
- A wrong or risky default in a manifest, or a missing hardening step
- A cheaper or simpler way to do the same thing
- Testing a guide on a real K3s cluster and reporting what broke
- Clearer docs, typo fixes, better explanations of the "why"
- Items from the [open issues](../../issues), especially `good first issue` and `help wanted`

## How to propose a change
1. **Open an issue first** for anything bigger than a typo, so we can agree on the approach.
2. Fork, create a branch, make the change, open a pull request.
3. Say in the PR **what you tested and how** (cluster version, which guide steps you ran). "Not tested" is an acceptable answer. Please say it.

## Rules
- **No real data.** Use placeholders only: `example.com`, `203.0.113.x` (documentation IP range), `acme`, `CHANGE_ME_*`. Never commit real domains, IPs, credentials, tokens or anything from a private system.
- Keep templates as `{{UPPER_CASE}}` tokens and add any new token to `templates/vars.env` with a comment.
- Pin versions (chart versions, image tags). No `latest`.
- Keep YAML valid. A quick check: replace the tokens with the `vars.env` values and parse every file.
- `templates/init.sh` needs bash 4+ (on macOS: `brew install bash`).
- Docs: explain the why, not only the commands. Keep the existing tone: short, direct, honest about what is untested.

## Credit
Contributors are listed automatically by GitHub. Non-code help (testing, docs feedback, reviews) is credited in [CONTRIBUTORS.md](CONTRIBUTORS.md).

Be respectful. Disagreement about technical choices is welcome; personal attacks are not.
