# Patch: `.github/workflows/ci.yml`

The existing CI only builds on push to `dev` or `master`. You're on branch `claude/ai-search-frigate-9mNG1`, so builds won't trigger automatically.

## Option A — Manual trigger (easiest, no changes needed)

1. Go to your Frigate fork → **Actions** tab → **CI / Build** workflow
2. Click **Run workflow** dropdown → select your branch → **Run workflow**
3. Wait ~30-60 min for the AMD64 build to complete
4. Image will be at: `ghcr.io/btoth525/frigate:<short-sha>-amd64`

## Option B — Auto-build on push (one-line change)

In `.github/workflows/ci.yml`, find:

```yaml
on:
  workflow_dispatch:
  push:
    branches:
      - dev
      - master
    paths-ignore:
      - "docs/**"
```

Change to:

```yaml
on:
  workflow_dispatch:
  push:
    branches:
      - dev
      - master
      - claude/ai-search-frigate-9mNG1
    paths-ignore:
      - "docs/**"
```

Now every push to your branch triggers a build automatically.

---

## After the build completes

Check Packages on your fork: https://github.com/btoth525?tab=packages

The image tag for Unraid will look like:
```
ghcr.io/btoth525/frigate:<short-sha>-amd64
```

Or if you want "latest" semantics, push a tag:
```bash
git tag v1.0-expo-push
git push origin v1.0-expo-push
```

## Unraid update steps

1. In Unraid → Docker tab → click your Frigate container → **Edit**
2. Change the **Repository** field to your new image:
   `ghcr.io/btoth525/frigate:<sha>-amd64`
3. Click **Apply** — Unraid pulls and recreates the container
4. Check container logs for: `Registered Expo Push token for admin: …`
