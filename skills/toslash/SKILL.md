---
name: toslash
description: Give things the user makes a short, memorable to/<name> link on ToSlash, the link hub on their Mac, and look those links up later. Use right after publishing an artifact or other hosted page, after starting a local dev server the user will come back to, when the user asks to name or bookmark a link, when they ask where something they made earlier lives or which port runs an app, or when they ask to install or set up ToSlash.
---

# ToSlash

ToSlash runs on the user's Mac. `http://to/<name>` redirects to a saved URL, and
`http://to/` lists every link. Agents use its JSON API at
`http://localhost/_/api/links`.

## Is it running?

```sh
curl -sf -o /dev/null http://localhost/_/api/links
```

If this fails, ToSlash is not running. Start it:

```sh
open -b io.github.nicholasren.toslash
```

- **It starts.** Wait a second and check again.
- **`open` fails.** ToSlash is not installed. Ask the user whether to install
  it. Install it only if they agree, with Homebrew:

  ```sh
  brew tap nicholasren/toslash https://github.com/nicholasren/toslash
  brew install --cask nicholasren/toslash/toslash
  open -b io.github.nicholasren.toslash
  ```

  On first open, ToSlash asks for an administrator password to add the `to`
  name to `/etc/hosts`. Tell the user to expect that dialog. `localhost` works
  without it, and the API calls below use `localhost`.

If it still does not answer, or the user declines, carry on without it.

## Register a link

Do this after you publish an artifact or other hosted page, after you start a
dev server the user will revisit, or when the user asks.

1. **Choose the name.** It is what the user will type, so make it short,
   lowercase and kebab-case, and say what the thing is: `q3-roadmap`,
   `billing-api`, `onboarding-deck`. Never `artifact-1`, `page`, `test` or a
   date alone. Letters, digits, `.`, `_` and `-` only, starting with a letter or
   digit.
2. **Check the name is free.**
   `curl -s http://localhost/_/api/links/<name>` returns 404 when it is free.
   If it exists and points somewhere else, it belongs to something else: pick a
   more specific name. Overwrite only when the user asks, or when it is the same
   thing at a new address, such as a dev server that moved port or a new version
   of the same artifact.
3. **Save it.** `PUT` creates or updates, so a retry is safe. Send the body on
   stdin so quotes in the description cannot break the shell:

   ```sh
   curl -s -X PUT http://localhost/_/api/links/q3-roadmap \
     -H 'Content-Type: application/json' --data @- <<'EOF'
   {"url": "https://claude.ai/artifact/…", "description": "Q3 roadmap draft from the planning session"}
   EOF
   ```

   Write the description as one line: what it is and where it came from. The
   user scans these weeks later on `http://to/`.
4. **Tell the user the link** from the response's `link` field, for example
   `http://to/q3-roadmap`. Use that field rather than assuming `to/`, because
   the user can rename the short host.

Errors come back as `{"error": "…"}` with status 400. Fix the name or URL and
try again; only `http://` and `https://` URLs are accepted.

## Find a link

When the user asks for something they made before ("that dashboard from last
week", "which port runs the API"), list the links and match on name,
description and URL before searching anywhere else:

```sh
curl -s http://localhost/_/api/links
```

Each entry has `name`, `url`, `description`, `created` and `link`.

## Remove a link

Only when the user asks:

```sh
curl -s -X DELETE http://localhost/_/api/links/<name>
```

## Limits

ToSlash takes changes only from the user's own Mac, so this works for agents
running there, not for hosted chat. It assumes ToSlash serves port 80, its
default.
