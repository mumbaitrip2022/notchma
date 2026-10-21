## What this changes

<!-- One or two sentences. Link the issue: Fixes #123 -->

## How you tested it

<!-- Which agent(s), which Mac (notch or not), what you clicked. Screenshots or a short video for anything visual. -->

## Checklist

- [ ] `swift test` passes
- [ ] Tried it in the running app (`make run`)
- [ ] Screenshots for visible changes
- [ ] No em or en dashes in app text (`./scripts/check-copy.sh`)
- [ ] No new network requests, analytics or data leaving the Mac
- [ ] Hooks stay fail safe: if NotchBar is closed or slow, agents fall back to their own prompts
