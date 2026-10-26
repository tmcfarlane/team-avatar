# Recipe: Issue labeled `design` → Zuko (visual dispatch)

When an issue is labeled `design`, Zuko produces a visual proposal — a mockup/icon and a
short design rationale — and posts it back to the issue.

| Field | Value |
| ----- | ----- |
| **Trigger** | GitHub issue `labeled` → **via a webhook** (see caveat) |
| **Model** | `gemini-3.1-pro` (multimodal) |
| **Repo context** | The issue's repository |
| **Tools** | Repo + image generation / computer use (on by default in 3.8) |

## ⚠️ Trigger caveat

A first-class **"non-PR issue *labeled*"** trigger is **not** in Cursor 3.8's picker (label
triggers are documented for PRs). Two ways to ship it:

- **Simple:** use the **Issue comment** trigger and have the prompt act only when the issue
  carries the `design` label (it checks, and no-ops otherwise).
- **Robust (recommended):** a generic **Webhook** automation fired by a tiny GitHub Action on
  the `issues: labeled` event. Commit this to the target repo:

```yaml
# .github/workflows/design-label-to-cursor.yml
name: design label → Cursor automation
on:
  issues:
    types: [labeled]
jobs:
  notify:
    if: github.event.label.name == 'design'
    runs-on: ubuntu-latest
    steps:
      - name: POST to the Cursor automation webhook
        run: |
          curl -fsSL -X POST "$CURSOR_WEBHOOK_URL" \
            -H 'Content-Type: application/json' \
            -d "$(jq -n --arg n "${{ github.event.issue.number }}" \
                       --arg t "${{ github.event.issue.title }}" \
                       --arg u "${{ github.event.issue.html_url }}" \
                       '{issue:$n, title:$t, url:$u}')"
        env:
          CURSOR_WEBHOOK_URL: ${{ secrets.CURSOR_WEBHOOK_URL }}
```

Create a **Webhook**-triggered automation in Cursor, copy its webhook URL into the repo secret
`CURSOR_WEBHOOK_URL`, and use the prompt below.

## The `/automate` prompt

```text
You are ZUKO, the visual firebender of Team Avatar. You turn a design request into a concrete,
reviewable visual proposal.

Context you are given: a GitHub issue (number, title, body, url) labeled `design`. If the
issue is NOT actually about a visual/design task, post a one-line comment saying so and stop.

Do exactly this:
1. Read the issue and any linked screenshots/specs. Restate the design goal in one sentence.
2. Produce ONE visual proposal: generate a mockup or icon (use image generation / computer use)
   that addresses the request. Save assets under assets/.
3. Write a short rationale: visual hierarchy (primary action prominent, supporting elements
   muted), accessibility (contrast, labels), and how it fits the existing UI.
4. Post a comment on the issue with the rationale and the generated image attached/linked.

Hard limits: do not modify application code or ship the design — propose only. Do not touch
unrelated files. One proposal per run; if the request is ambiguous, ask in a comment and stop.
```

## Notes
- `gemini-3.1-pro` matches Zuko's multimodal routing (note: a bare `gemini-3.5-flash` did
  **not** route in our validation — see `VALIDATION.md`).
- Keep "propose only, don't ship". Cloud runs get only the hooks a repository commits in `.cursor/hooks.json`, not your user or plugin hooks.
