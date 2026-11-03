## What

<!-- What changes for someone using Scope, in a sentence or two. -->

## How it was tested

- [ ] Relevant checks pass (`make test` for engine changes; links/rendering for docs)
- [ ] Built and tried in Scope Dev, changing files only in `~/ScopeScratch`
- [ ] Screenshots attached for visible changes, inspected for personal content

## Safety

- [ ] File access still goes through `FileEngine` and `PathGuard`
- [ ] Scope Dev still restricts changes to `~/ScopeScratch`
- [ ] Tests use disposable fixtures and never the user's real Trash or files
