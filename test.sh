#!/usr/bin/env bash
# Build a throwaway ToSlash, run it on a spare port with an empty link file, and check its HTTP behaviour.
# When en0 has an address, a second copy allows other devices and is reached through that address.
# Exits with the number of failed checks.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
port=7799
store="$tmp/links.json"
"$here/build.sh" "$tmp" >/dev/null 2>&1 || { echo "build failed"; exit 1; }
pids=()
launch() { "$tmp/ToSlash.app/Contents/MacOS/ToSlash" -port "$1" -store "$2" -host to "${@:3}" & pids+=($!); }
await() { for _ in $(seq 50); do curl -s -o /dev/null "$@" && break; sleep 0.1; done; }
trap 'kill "${pids[@]}" 2>/dev/null; wait 2>/dev/null; rm -rf "$tmp"' EXIT

launch "$port" "$store"
B="http://127.0.0.1:$port"
await -H 'Host: to' "$B/"

fails=0
check() {
  if [[ $3 == "$2" ]]; then echo "ok    $1"; else echo "FAIL  $1: want '$2', got '$3'"; fails=$((fails + 1)); fi
}
status() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
code() { status -H 'Host: to' "$@"; }
field() { curl -s -H 'Host: to' "$B/_/api/links/$1" | python3 -I -c "import json,sys; print(json.load(sys.stdin).get('$2'))"; }
put() { code -X PUT -H 'Content-Type: application/json' -d "$2" "$B/_/api/links/$1"; }

check "PUT creates a link" 200 "$(put web '{"url":"http://localhost:4390","description":"Frame room"}')"
check "GET returns its description" "Frame room" "$(field web description)"
check "GET returns its short link (localhost:<port> off port 80)" "http://localhost:$port/web" "$(field web link)"
check "page has the filter box" 1 "$(curl -s -H 'Host: to' "$B/" | grep -c 'class=filter')"
check "page shows the description" 1 "$(curl -s -H 'Host: to' "$B/" | grep -c 'class=d>Frame room')"
check "page links the app icon" 1 "$(curl -s -H 'Host: to' "$B/" | grep -c 'rel=icon href=/_/icon.png')"
check "app icon is a PNG" "200 image/png" "$(curl -s -o /dev/null -w '%{http_code} %{content_type}' -H 'Host: to' "$B/_/icon.png")"
created="$(field web created)"
sleep 1
check "PUT on an existing name updates it" 200 "$(put web '{"url":"http://localhost:4391","description":"Frame room v2"}')"
check "update changes the URL" "http://localhost:4391" "$(field web url)"
check "update keeps the created date" "$created" "$(field web created)"
check "list names every link" "web" "$(curl -s -H 'Host: to' "$B/_/api/links" | python3 -I -c 'import json,sys; print(",".join(l["name"] for l in json.load(sys.stdin)))')"
check "non-http URL refused" 400 "$(put x '{"url":"file:///etc/hosts"}')"
check "non-JSON body refused" 400 "$(code -X PUT -d 'url=http://a' "$B/_/api/links/x")"
check "bad name refused" 400 "$(put -bad '{"url":"http://a"}')"
check "unknown name is 404" 404 "$(code "$B/_/api/links/nope")"
check "PUT from another site refused" 403 "$(code -X PUT -H 'Origin: https://other.example' -d '{"url":"http://a"}' "$B/_/api/links/x")"

check "redirect passes path and query" "302 http://localhost:4391/a/b?x=1" \
  "$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' -H 'Host: to' "$B/web/a/b?x=1")"
check "unknown short link is 404" 404 "$(code "$B/nope")"
check "foreign Host header refused" 403 "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: other.example' "$B/web")"
lan="$(ipconfig getifaddr en0 2>/dev/null || true)"
if [[ -n $lan ]]; then
  check "connection from the network never reaches the server" 000 "$(curl -s -o /dev/null -w '%{http_code}' "http://$lan:$port/web")"
fi

check "form adds a link" 303 "$(code -d 'name=doc&url=https://example.com&description=Spec' "$B/_/add")"
check "form refuses an existing name" 400 "$(code -d 'name=doc&url=https://example.com' "$B/_/add")"
check "form renames a link" 303 "$(code -d 'old=doc&name=spec&url=https://example.com/v2' "$B/_/add")"
check "renamed link moved" "404 200" "$(code "$B/_/api/links/doc") $(code "$B/_/api/links/spec")"
check "form post from another site refused" 403 "$(code -H 'Origin: https://other.example' -d 'name=x&url=http://a' "$B/_/add")"

check "DELETE removes a link" 200 "$(code -X DELETE "$B/_/api/links/spec")"
check "DELETE again still succeeds" 200 "$(code -X DELETE "$B/_/api/links/spec")"
check "deleted link is gone" 404 "$(code "$B/_/api/links/spec")"

echo 'not json' > "$store"
check "unreadable link file refuses writes" 400 "$(put y '{"url":"http://a"}')"
check "unreadable link file is left untouched" "not json" "$(cat "$store")"

if [[ -n $lan ]]; then
  launch 7798 "$tmp/network.json" -allowNetwork YES
  N="http://$lan:7798"
  M="http://127.0.0.1:7798"
  await "$N/"
  json=(-X PUT -H 'Content-Type: application/json')
  check "this Mac adds links through 127.0.0.1" "200 200" \
    "$(code "${json[@]}" -d '{"url":"http://localhost:4390"}' "$M/_/api/links/web") $(code "${json[@]}" -d '{"url":"https://example.com/x"}' "$M/_/api/links/ex")"
  check "another device gets the page" 200 "$(status "$N/")"
  check "page for another device has no add form" 0 "$(curl -s "$N/" | grep -c 'class=add')"
  check "page for another device has no edit button" 0 "$(curl -s "$N/" | grep -c 'class=edit')"
  check "page names the address the device used" 1 "$(curl -s "$N/" | grep -c "http://$lan:7798/&lt;name&gt;")"
  redirect() { curl -s -o /dev/null -w '%{http_code} %{redirect_url}' "$@"; }
  check "localhost link redirects to the Mac's address" "302 http://$lan:4390/a?x=1" "$(redirect "$N/web/a?x=1")"
  check "localhost link redirects to a bracketed IPv6 host" "302 http://[fd00::1]:4390/" "$(redirect -H 'Host: [fd00::1]:7798' "$N/web")"
  check "other link redirects unchanged" "302 https://example.com/x" "$(redirect "$N/ex")"
  check "another device cannot post the add form" 403 "$(status -d 'name=x&url=http://a' "$N/_/add")"
  check "another device cannot post the remove form" 403 "$(status -d 'name=web' "$N/_/rm")"
  check "another device cannot PUT" 403 "$(status "${json[@]}" -d '{"url":"http://a"}' "$N/_/api/links/x")"
  check "another device cannot DELETE" 403 "$(status -X DELETE "$N/_/api/links/web")"
  check "another device reads the API" "200 200" "$(status "$N/_/api/links") $(status "$N/_/api/links/web")"
  check "another device gets the icon" 200 "$(status "$N/_/icon.png")"
  check "another device naming a foreign host refused" 403 "$(status -H 'Host: evil.example' "$N/")"
  name="$(scutil --get LocalHostName 2>/dev/null || true)"
  if [[ -n $name ]]; then
    check "another device may use the Bonjour name, in any case" 200 "$(status -H "Host: $(tr '[:lower:]' '[:upper:]' <<<"$name").local" "$N/")"
  fi
  check "this Mac still writes through 127.0.0.1" 200 "$(code -X DELETE "$M/_/api/links/web")"
fi

echo "$fails failed"
exit "$fails"
