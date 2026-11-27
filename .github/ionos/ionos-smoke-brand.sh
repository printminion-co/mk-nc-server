#!/usr/bin/env bash
# Brand check and theme probes of an installed instance (07-validation.md, "Brand check"). No flavor specific code:
# what is expected comes from the RESOLVED flavor (`ncw resolve`) and from the settings the archive itself carries.
#
#   ionos-smoke-brand.sh <base url> <tree> <resolved.yaml> <output folder>
#   ionos-smoke-brand.sh --scan <pages folder> [<allow-list>]       (only the text check, on pages already fetched)
#
# 1. The pages: the login page (no session), then, with a session from the login form: the files page, the admin
#    settings, the admin overview, the personal settings, the user theming section and the admin theming section; a
#    sample system mail made by the real mail template of the instance (ionos-smoke-mail.php, run in the tree) as HTML
#    and as text. They are kept in <output folder>/pages. The text of a page is the HTML as sent plus every
#    initial-state value decoded (the pages carry their settings Base64 encoded), with JSON slashes unescaped.
# 2. The brand check: the text "Nextcloud", in any case, must not be on a page unless an entry of the allow-list
#    (ionos-smoke-brand-allowlist.txt) takes it out first. Entries are `<page glob> :: <perl regexp> :: <reason>`;
#    the regexps are case sensitive and are removed from the text of the matching pages before the check. Every
#    occurrence left is reported with its page and some context, and fails the check. An entry that matched on no
#    page is reported as a notice (stale).
# 3. The theme probes, only for what the flavor says (nothing runs for a flavor without the feature):
#    - enforce_theme in the resolved flavor: `occ config:system:get enforce_theme` says it, the login page carries
#      data-theme-<id> and the stylesheet of the theme (/index.php/apps/theming/theme/<id>.css) answers 200 with
#      the scope [data-theme-<id>] and the primary color variable; the theme list of the user theming section lists
#      only the enforced theme
#    - app-config-special.json of the archive sets theming disable-user-theming: the user theming section says it is
#      disabled (user controls gone)
#    - the system setting `theme` is set (the legacy theme folder): the admin theming section says the instance is not
#      themeable (admin controls gone)
#    - the system setting mail_template_class is set: the sample mail was made by exactly that class
#    - the unpacked archive has a theme folder with images (themes/<theme>/core/img, <theme> = the system setting
#      `theme`): the logo and icon URLs the instance really hands out must point into that folder, answer 200 and be
#      byte-identical (sha256) to the file of the archive, and must not be the Nextcloud default of the same name. The
#      URLs: the favicon, touch icon, mask icon, web manifest and og:image links of the login page, the --image-logo
#      and --image-logoheader variables of the stylesheet of the enforced theme (they make the logo of the login page
#      and of the header), and the logo of the sample mail
# Every probe runs; each prints "ok - <name>" or an ::error:: line "FAIL - <name>: <why>"; the exit status is 1 when
# one failed or the brand check found a text.
# Environment: SMOKE_ADMIN_USER, SMOKE_ADMIN_PASS, PHP (default php), SMOKE_BRAND_ALLOWLIST (default: the file next to this script).
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export LOG_PREFIX=ionos-smoke-brand
# shellcheck source=ionos-lib.sh
. "$HERE/ionos-lib.sh"

PHP=${PHP:-php}
ALLOWLIST=${SMOKE_BRAND_ALLOWLIST:-$HERE/ionos-smoke-brand-allowlist.txt}
failed=0

pass() { echo "ok - $1"; }
miss() { echo "::error::${LOG_PREFIX}: FAIL - $1: $2"; failed=$((failed + 1)); }

# ---- the text of a page: HTML as sent, JSON slashes unescaped, initial-state values decoded and appended
page_text() { # page_text <file>
  perl -MMIME::Base64 -0777 -ne '
    my $t = $_; my $extra = "";
    while ($t =~ /id="initial-state-([^"]+)"\s+value="([^"]*)"/g) {
      my ($id, $v) = ($1, $2);
      my $d = decode_base64($v);
      $d =~ s/\\\//\//g;
      $extra .= "\ninitial-state-$id => $d\n";
    }
    $t =~ s/\\\//\//g;
    print $t, $extra;' "$1"
}

# initial_state <file> <id>: the decoded value of the initial state "<id>" of a page, empty when it is not there
initial_state() {
  local id=$2
  ID="$id" perl -MMIME::Base64 -0777 -ne 'print decode_base64($1) if /id="initial-state-\Q$ENV{ID}\E"\s+value="([^"]*)"/;' "$1"
}

# ---- the allow-list
# allow_entries <allow-list>: prints "<glob>\t<regexp>\t<reason>" per entry; returns 1 (with a message) for a bad file or entry
allow_entries() {
  local file=$1 line n=0 glob re reason
  [ -f "$file" ] || { echo "::error::${LOG_PREFIX}: no allow-list at $file" >&2; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    if [[ $line != *' :: '*' :: '* ]]; then
      echo "::error::${LOG_PREFIX}: $file:$n: an entry is '<page glob> :: <perl regexp> :: <reason>'" >&2; return 1
    fi
    glob=${line%% :: *}; line=${line#* :: }
    re=${line%% :: *}; reason=${line#* :: }
    if [ -z "${glob// }" ] || [ -z "${re// }" ] || [ -z "${reason// }" ]; then
      echo "::error::${LOG_PREFIX}: $file:$n: page, regexp and reason must all be given" >&2; return 1
    fi
    if ! RE="$re" perl -e 'my $r = eval { qr/$ENV{RE}/ }; exit($r ? 0 : 1)' 2>/dev/null; then
      echo "::error::${LOG_PREFIX}: $file:$n: the regexp is not valid: $re" >&2; return 1
    fi
    # a regexp that matches the empty string would "allow" nothing but also hides intent
    if RE="$re" perl -e 'exit("" =~ /$ENV{RE}/ ? 0 : 1)'; then
      echo "::error::${LOG_PREFIX}: $file:$n: the regexp matches the empty string" >&2; return 1
    fi
    printf '%s\t%s\t%s\n' "$glob" "$re" "$reason"
  done < "$file"
}

# scan_pages <pages folder> <allow-list>: the brand check; sets BRAND_FOUND to the number of occurrences left
scan_pages() {
  local dir=$1 entries file name text glob re reason left count allowed
  local -A used=()
  BRAND_FOUND=0
  entries=$(allow_entries "$2") || { BRAND_FOUND=1; failed=$((failed + 1)); return 1; }
  local pages=()
  while IFS= read -r file; do pages+=("$file"); done < <(find "$dir" -maxdepth 1 -type f \( -name '*.html' -o -name '*.txt' \) | sort)
  if [ ${#pages[@]} -eq 0 ]; then
    miss "brand check" "no page to check in $dir"; BRAND_FOUND=1; return 1
  fi
  for file in "${pages[@]}"; do
    name=$(basename "$file"); name=${name%.*}
    text=$(mktemp)
    page_text "$file" > "$text"
    allowed=0
    while IFS=$'\t' read -r glob re reason; do
      [ -n "$glob" ] || continue
      # shellcheck disable=SC2254 # the glob of the entry is the pattern
      case "$name" in $glob) ;; *) continue ;; esac
      count=$(RE="$re" perl -0777 -ne '$c = () = /$ENV{RE}/g; print $c + 0;' "$text")
      if [ "$count" -gt 0 ]; then
        used["$glob :: $re"]=1
        allowed=$((allowed + count))
        RE="$re" perl -0777 -i -pe 's/$ENV{RE}//g' "$text"
      fi
    done <<<"$entries"
    left=$(grep -ioP '.{0,60}nextcloud.{0,60}' "$text" || true)
    if [ -n "$left" ]; then
      count=$(grep -oi 'nextcloud' "$text" | wc -l)
      BRAND_FOUND=$((BRAND_FOUND + count))
      echo "::error::${LOG_PREFIX}: FAIL - brand check, page $name: $count occurrence(s) of the text \"Nextcloud\" outside the allow-list:"
      while IFS= read -r line; do echo "    ...${line}..."; done <<<"$left"
      failed=$((failed + 1))
    else
      pass "brand check, page $name ($allowed allowed occurrence(s))"
    fi
    rm -f "$text"
  done
  while IFS=$'\t' read -r glob re reason; do
    [ -n "$glob" ] || continue
    [ -n "${used["$glob :: $re"]:-}" ] || echo "::notice::${LOG_PREFIX}: the allow-list entry for $glob matched nothing: $re"
  done <<<"$entries"
  return 0
}

# ---- --scan: only the text check
if [ "${1:-}" = --scan ]; then
  if [ $# -lt 2 ] || [ $# -gt 3 ]; then die "usage: ionos-smoke-brand.sh --scan <pages folder> [<allow-list>]"; fi
  [ -d "$2" ] || die "no pages folder at $2"
  scan_pages "$2" "${3:-$ALLOWLIST}"
  if [ "$failed" -gt 0 ]; then echo "${LOG_PREFIX}: the brand check failed" >&2; exit 1; fi
  log "the brand check passed"
  exit 0
fi

[ $# -eq 4 ] || die "usage: ionos-smoke-brand.sh <base url> <tree> <resolved.yaml> <output folder>  |  --scan <pages folder> [<allow-list>]"
BASE=${1%/}
TREE=$2
RESOLVED=$3
OUT=$4
USER_NAME=${SMOKE_ADMIN_USER:?SMOKE_ADMIN_USER is required}
PASS=${SMOKE_ADMIN_PASS:?SMOKE_ADMIN_PASS is required}
[ -d "$TREE" ] || die "no tree at $TREE"
[ -f "$RESOLVED" ] || die "no resolved flavor at $RESOLVED"
PAGES="$OUT/pages"
mkdir -p "$PAGES"
JAR="$OUT/cookies.txt"
: > "$JAR"

# req <output file> <curl args...>: prints the HTTP status code (000 when curl itself failed)
req() {
  local out=$1; shift
  curl -sS --max-time 120 -o "$out" -w '%{http_code}' "$@" 2>>"$OUT/curl-errors.log" || true
}
occ() { ( cd "$TREE" && timeout 300 "$PHP" occ "$@" 2>>"$OUT/occ-errors.log" ); }

# ---- 1. the pages
code=$(req "$PAGES/login.html" -c "$JAR" -b "$JAR" "$BASE/index.php/login")
token=""
if [ "$code" = 200 ]; then
  token=$(grep -o 'data-requesttoken="[^"]*"' "$PAGES/login.html" | head -n1 | sed 's/^data-requesttoken="//; s/"$//' || true)
else
  miss "page login" "HTTP $code, wanted 200"
fi
session=false
if [ -n "$token" ]; then
  code=$(curl -sS --max-time 120 -o "$OUT/login-post.html" -w '%{http_code} %{redirect_url}' -c "$JAR" -b "$JAR" -H "Origin: $BASE" \
    --data-urlencode "user=$USER_NAME" --data-urlencode "password=$PASS" --data-urlencode "requesttoken=$token" \
    --data-urlencode timezone=UTC --data-urlencode timezone_offset=0 "$BASE/index.php/login" 2>>"$OUT/curl-errors.log" || true)
  case "$code" in
    30[123]\ *"/login"*) ;;
    30[123]\ *) session=true ;;
  esac
fi
[ "$session" = true ] || miss "login session" "no session: the pages that need one cannot be checked"

page() { # page <name> <path>
  local c
  [ "$session" = true ] || return 0
  c=$(req "$PAGES/$1.html" -c "$JAR" -b "$JAR" -L "$BASE$2")
  if [ "$c" != 200 ]; then miss "page $1" "HTTP $c, wanted 200"; rm -f "$PAGES/$1.html"; fi
}
page files /index.php/apps/files/
page settings /index.php/settings/admin
page overview /index.php/settings/admin/overview
page personal /index.php/settings/user
page user-theming /index.php/settings/user/theming
page admin-theming /index.php/settings/admin/theming

# the sample mail, made by the real template of the instance
MAIL_JSON="$OUT/mail.json"
if ( cd "$TREE" && timeout 300 "$PHP" "$HERE/ionos-smoke-mail.php" "$TREE" ) > "$MAIL_JSON" 2>"$OUT/mail-errors.log" \
    && jq -e '(.class | type == "string") and (.html | length > 0) and (.text | length > 0)' "$MAIL_JSON" >/dev/null 2>&1; then
  jq -r '.html' "$MAIL_JSON" > "$PAGES/mail-html.html"
  jq -r '.text' "$MAIL_JSON" > "$PAGES/mail-text.txt"
else
  miss "sample mail" "ionos-smoke-mail.php did not produce a mail: $(head -c 300 "$OUT/mail-errors.log" 2>/dev/null)"
  MAIL_JSON=""
fi

# ---- 2. the brand check
scan_pages "$PAGES" "$ALLOWLIST"

# ---- 3. the theme probes
enforced=$(awk '/^enforce_theme:/ { v = $2; gsub(/["\047]/, "", v); print v; exit }' "$RESOLVED")
if [ -n "$enforced" ]; then
  [[ $enforced =~ ^[a-z0-9-]+$ ]] || { miss "enforced theme" "enforce_theme '$enforced' of the resolved flavor is no theme id"; enforced=""; }
fi
if [ -n "$enforced" ]; then
  got=$(occ config:system:get enforce_theme | head -n1)
  if [ "$got" = "$enforced" ]; then pass "enforce_theme is $enforced (occ config:system:get)"; else miss "enforce_theme" "occ says '$got', the resolved flavor says '$enforced'"; fi

  if grep -q "data-theme-$enforced" "$PAGES/login.html" 2>/dev/null; then pass "the login page carries data-theme-$enforced"
  else miss "enforced theme on the login page" "no data-theme-$enforced in the page"; fi

  code=$(req "$OUT/theme.css" "$BASE/index.php/apps/theming/theme/$enforced.css?plain=0")
  if [ "$code" != 200 ]; then miss "theme stylesheet" "HTTP $code for theme/$enforced.css, wanted 200"
  elif grep -q "\[data-theme-$enforced\]" "$OUT/theme.css" && grep -q -- '--color-primary:' "$OUT/theme.css"; then pass "theme stylesheet of $enforced (200, scope and tokens)"
  else miss "theme stylesheet" "theme/$enforced.css answers 200 but has no [data-theme-$enforced] scope with the token --color-primary"; fi

  if [ -f "$PAGES/user-theming.html" ]; then
    listed=$(initial_state "$PAGES/user-theming.html" theming-themes | jq -r '[.[].id] | join(",")' 2>/dev/null || true)
    if [ "$listed" = "$enforced" ]; then pass "the user theming section lists only the enforced theme"
    else miss "theme list" "the user theming section lists '$listed', wanted only '$enforced'"; fi
  fi
fi

if jq -e 'map(select(.app == "theming" and .key == "disable-user-theming")) | length > 0' "$TREE/app-config-special.json" >/dev/null 2>&1; then
  if [ -f "$PAGES/user-theming.html" ]; then
    got=$(initial_state "$PAGES/user-theming.html" theming-isUserThemingDisabled)
    if [ "$got" = true ]; then pass "user theming is disabled (the controls are gone)"
    else miss "user theming" "the archive sets disable-user-theming but the user theming section says isUserThemingDisabled=${got:-unset}"; fi
  else miss "user theming" "no user theming section to check"; fi
fi

theme_dir=$(occ config:system:get theme | head -n1)
if [ -n "$theme_dir" ]; then
  if [ -f "$PAGES/admin-theming.html" ]; then
    got=$(initial_state "$PAGES/admin-theming.html" theming-adminThemingInfo | jq -r '.isThemeable' 2>/dev/null || true)
    if [ "$got" = false ]; then pass "admin theming is locked (the instance uses the custom theme '$theme_dir')"
    else miss "admin theming" "the system setting theme is '$theme_dir' but the admin theming section says isThemeable=${got:-unset}"; fi
  else miss "admin theming" "no admin theming section to check"; fi
fi

mail_class=$(occ config:system:get mail_template_class | head -n1)
if [ -n "$mail_class" ]; then
  if [ -n "$MAIL_JSON" ]; then
    got=$(jq -r '.class' "$MAIL_JSON")
    if [ "$got" = "$mail_class" ]; then pass "system mail uses the template $mail_class"
    else miss "mail template" "the sample mail was made by '$got', mail_template_class is '$mail_class'"; fi
  else miss "mail template" "no sample mail to check"; fi
fi

# ---- the logo and icon probes
# unescape_html: the few entities that matter in an attribute value
unescape_html() { sed 's/&amp;/\&/g; s/&#0*39;/'"'"'/g; s/&quot;/"/g'; }
# link_href <file> <rel>: the href of the first <link rel="<rel>">
link_href() { REL=$2 perl -0777 -ne 'if (/<link\b[^>]*\brel="\Q$ENV{REL}\E"[^>]*\bhref="([^"]*)"/s || /<link\b[^>]*\bhref="([^"]*)"[^>]*\brel="\Q$ENV{REL}\E"/s) { print $1 }' "$1" | unescape_html; }
# og_image <file>: the content of <meta property="og:image">
og_image() { perl -0777 -ne 'print $1 if /<meta\b[^>]*\bproperty="og:image"[^>]*\bcontent="([^"]*)"/s' "$1" | unescape_html; }
# css_var_url <file> <variable>: the url() of a CSS variable
css_var_url() { VAR=$2 perl -0777 -ne 'print $1 if /\Q$ENV{VAR}\E:\s*url\(\s*[\x27"]?([^\x27")]*)/' "$1"; }
# mail_logo <file>: the src of the logo image of the mail
mail_logo() { perl -0777 -ne 'print $1 if /<img\b[^>]*\bclass="logo[^"]*"[^>]*\bsrc="([^"]*)"/s' "$1" | unescape_html; }

ORIGIN=$(sed -E 's#^(https?://[^/]+).*#\1#' <<<"$BASE")
sha() { sha256sum "$1" | cut -d' ' -f1; }

# probe_theme_image <name> <url> <theme folder>: the url must point into themes/<theme>/core/img/, answer 200 and
# hold the bytes of the file of the archive, which is not a copy of the Nextcloud default of the same name
probe_theme_image() {
  local name=$1 url=$2 theme=$3 path rel file served code
  if [ -z "$url" ]; then miss "$name" "no such link or value found"; return; fi
  path=$url
  if [[ $url == *://* ]]; then path=/${url#*://*/}; fi
  path=${path%%[?#]*}
  if [[ ! $path =~ /themes/$theme/core/img/(.+)$ ]]; then
    miss "$name" "$url does not point into the theme folder themes/$theme/core/img/ (the default image of the server)"; return
  fi
  rel=${BASH_REMATCH[1]}
  file="$TREE/themes/$theme/core/img/$rel"
  if [ ! -f "$file" ]; then miss "$name" "$url: the archive has no themes/$theme/core/img/$rel"; return; fi
  served="$OUT/logo-probes/$(echo "$rel" | tr '/' '_')"
  code=$(req "$served" "$ORIGIN$path")
  if [ "$code" != 200 ]; then miss "$name" "$ORIGIN$path answers HTTP $code, wanted 200"; return; fi
  if [ "$(sha "$served")" != "$(sha "$file")" ]; then miss "$name" "$ORIGIN$path is not byte-identical to themes/$theme/core/img/$rel of the archive"; return; fi
  if [ -f "$TREE/core/img/$rel" ] && [ "$(sha "$served")" = "$(sha "$TREE/core/img/$rel")" ]; then
    miss "$name" "$ORIGIN$path is the Nextcloud default core/img/$rel"; return
  fi
  pass "$name: $rel is served from the theme folder (200, sha256 $(sha "$served" | cut -c1-12))"
}

if [ -n "$theme_dir" ] && [[ $theme_dir =~ ^[A-Za-z0-9_-]+$ ]] && [ -n "$(find "$TREE/themes/$theme_dir/core/img" -type f 2>/dev/null | head -n1)" ]; then
  mkdir -p "$OUT/logo-probes"
  if [ -f "$PAGES/login.html" ]; then
    probe_theme_image "login favicon" "$(link_href "$PAGES/login.html" icon)" "$theme_dir"
    probe_theme_image "login touch icon" "$(link_href "$PAGES/login.html" apple-touch-icon)" "$theme_dir"
    probe_theme_image "login mask icon" "$(link_href "$PAGES/login.html" mask-icon)" "$theme_dir"
    probe_theme_image "login web manifest" "$(link_href "$PAGES/login.html" manifest)" "$theme_dir"
    probe_theme_image "login og:image" "$(og_image "$PAGES/login.html")" "$theme_dir"
  else miss "login icons" "no login page to check"; fi
  if [ -f "$OUT/theme.css" ] && [ -n "$enforced" ]; then
    probe_theme_image "login and header logo (--image-logo)" "$(css_var_url "$OUT/theme.css" --image-logo)" "$theme_dir"
    probe_theme_image "header logo (--image-logoheader)" "$(css_var_url "$OUT/theme.css" --image-logoheader)" "$theme_dir"
  else miss "logo variables" "no stylesheet of an enforced theme to read --image-logo from"; fi
  if [ -f "$PAGES/mail-html.html" ]; then
    probe_theme_image "mail logo" "$(mail_logo "$PAGES/mail-html.html")" "$theme_dir"
  else miss "mail logo" "no sample mail to check"; fi
fi

rm -f "$JAR"
if [ "$failed" -gt 0 ]; then echo "${LOG_PREFIX}: brand check and theme probes: $failed failed" >&2; exit 1; fi
log "the brand check and the theme probes passed"
