#!/usr/bin/env bash
# Save ToSlash's GitHub numbers to $TOSLASH_STATS_DIR (default ~/.local/share/toslash-stats).
# GitHub keeps traffic for only 14 days, so run this daily to keep the history.
#   snapshots.jsonl  one line per run: downloads per release, stars, forks, watchers,
#                    and the 14-day referrers and popular paths.
#   traffic.json     views and clones per day, merged across runs; a later run wins for a day.
set -euo pipefail
repo=nicholasren/toslash
dir="${TOSLASH_STATS_DIR:-$HOME/.local/share/toslash-stats}"
mkdir -p "$dir"
api() { gh api "repos/$repo$1" "${@:2}"; }

releases="$(api /releases --paginate --jq '.[] | {tag: .tag_name, downloads: ([.assets[].download_count] | add // 0)}' | jq -s .)"
repo_info="$(api "" --jq '{stars: .stargazers_count, forks: .forks_count, watchers: .subscribers_count}')"
referrers="$(api /traffic/popular/referrers)"
paths="$(api /traffic/popular/paths --jq '[.[] | {path, count, uniques}]')"
jq -cn --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson releases "$releases" --argjson repo "$repo_info" \
  --argjson referrers "$referrers" --argjson paths "$paths" \
  '{at: $at, releases: $releases, total_downloads: ([$releases[].downloads] | add // 0)} + $repo + {referrers: $referrers, paths: $paths}' \
  >>"$dir/snapshots.jsonl"

traffic="$dir/traffic.json"
[[ -f $traffic ]] || echo '{}' >"$traffic"
jq -n --slurpfile old "$traffic" \
  --argjson views "$(api /traffic/views)" --argjson clones "$(api /traffic/clones)" '
  def by_day: map({key: .timestamp[:10], value: {count, uniques}}) | from_entries;
  ($views.views | by_day) as $v | ($clones.clones | by_day) as $c
  | $old[0] * ([$v, $c] | map(keys) | add | unique
      | map({key: ., value: {views: ($v[.] // {count: 0, uniques: 0}), clones: ($c[.] // {count: 0, uniques: 0})}})
      | from_entries)
  ' >"$traffic.tmp"
mv "$traffic.tmp" "$traffic"
echo "saved to $dir"
