# ToSlash

Short links for everything you work with, from the menu bar. Type `to/<name>`
in your browser and land on the right place: a dev server on some port, a box
on your home network, or a page an AI agent made for you last week.

- `to/api` opens `http://localhost:4390`, so you stop guessing which port runs which app.
- `to/roadmap` opens a hosted page, such as a Claude artifact, that would otherwise be lost in chat history.
- `to/` lists every link with its description, the date it was added, and a live dot: green when a local or LAN target answers, red when it does not.

Extra path and query pass through: `to/api/users?id=7` opens
`http://localhost:4390/users?id=7`.

## Install

1. Download `ToSlash-<version>.dmg` from [Releases](../../releases) and drag ToSlash to Applications.
2. Open it. ToSlash is not notarized, so macOS blocks the first open. Go to
   System Settings > Privacy & Security and click **Open Anyway**, or run:

   ```sh
   xattr -dr com.apple.quarantine /Applications/ToSlash.app
   ```

3. ToSlash asks to add `127.0.0.1 to` to `/etc/hosts` so the `to/` name reaches
   it. macOS asks for an administrator password. Without this line, use
   `http://localhost/` instead.

Requires macOS 14 or later, on Apple silicon or Intel.

## Use

Open `http://to/` to add, edit, rename and remove links. Visiting a name that
does not exist yet opens the add form with the name filled in.

The menu bar icon starts, stops and restarts the server, and turns Open at
Login on or off.

Links live in `~/Library/Application Support/ToSlash/links.json`.

## Let your agent name things for you

Coding agents make pages and start servers faster than anyone can bookmark
them. ToSlash has a small JSON API and an agent skill so the agent registers
each one under a name you will remember.

**The skill.** `skills/toslash/SKILL.md` tells an agent when to register a
link, how to pick a good name, and how to look links up later. Copy the folder
into your agent's skills directory, for Claude Code:

```sh
cp -R skills/toslash ~/.claude/skills/
```

Then ask for things as usual: "publish this as an artifact", "start the API
server", "where is that roadmap from last week?".

**The API.** It answers only on your own Mac.

```sh
# Create or update a link. Safe to repeat; the created date is kept.
curl -X PUT http://localhost/_/api/links/roadmap \
  -H 'Content-Type: application/json' \
  -d '{"url": "https://example.com/roadmap", "description": "Q3 roadmap draft"}'

curl http://localhost/_/api/links            # list every link
curl http://localhost/_/api/links/roadmap    # one link
curl -X DELETE http://localhost/_/api/links/roadmap
```

Each link comes back as `name`, `url`, `description`, `created` and `link`
(its short URL). Errors come back as `{"error": "…"}` with status 400.

## How it works

ToSlash runs a small HTTP server on port 80. macOS lets an app use port 80
without root only when it listens on all network interfaces, so ToSlash
refuses every request that does not come from your own Mac. It also refuses
requests that name another host, and writes from other websites, so a page you
visit cannot change your links.

If `to/` is already taken on your network, for example by a work VPN, pick
another name:

```sh
defaults write io.github.nicholasren.toslash host <name>
```

## Build

```sh
./build.sh            # build into ~/Applications and relaunch it if running
./test.sh             # run a throwaway copy on port 7799 and check its HTTP behaviour
./package.sh          # build a universal app into dist/ToSlash-<version>.dmg
```

`icon/make-icon.swift` renders `icon/AppIcon.icns`; rerun it only when the
icon design changes.

## License

MIT
