#!/usr/bin/env bash
# =============================================================================
# tools/sync-editions.sh - derive the comment-free edition from this one
# =============================================================================
#
# The annotated sandbox (this directory) is the SOURCE OF TRUTH. The sibling
# directory ../agent-sandbox holds the same projects with every comment
# removed. This tool regenerates it, so the two editions can never drift:
#
#   tools/sync-editions.sh            rewrite ../agent-sandbox/<set>/ from ./<set>/
#   tools/sync-editions.sh --check    exit 1 if the pure edition is out of date
#
# A "set" is any top-level directory here except tools/. Inside a set:
#
#   * code files (*.sh, *.awk, *.ini, .env.example, .gitignore, .shellcheckrc
#     and anything in bin/) lose every FULL-LINE comment - shebangs and
#     heredoc bodies are kept, runs of blank lines are collapsed;
#   * all other files (README.md, ...) are copied verbatim;
#   * var/ and .env (local runtime state and secrets) are never touched.
#
# The stripping is sound because the annotated code follows three rules:
# comments always sit on their own line (never after code), heredoc
# delimiters are UPPER_CASE words, and no multi-line quoted string contains
# a line that starts with '#'. Every line whose first non-blank character is
# '#' is then, by bash's own grammar, a comment.
#
# Proof of equivalence, beyond this tool: run each edition's test suite
# (tests/run.sh); they must report identical results.
# =============================================================================
set -Eeuo pipefail
shopt -s nullglob dotglob

here=$(cd -P -- "${BASH_SOURCE[0]%/*}/.." && pwd)
pure=${SYNC_TARGET:-$(cd -P -- "$here/.." && pwd)/agent-sandbox}
mode=sync

case ${1-} in
  '') ;;
  --check) mode=check ;;
  -h | --help)
    sed -n '4,13p' "${BASH_SOURCE[0]}"
    exit 0
    ;;
  *)
    printf 'usage: %s [--check]\n' "${0##*/}" >&2
    exit 64
    ;;
esac

# -----------------------------------------------------------------------------
# The stripper, in awk. It is a small state machine:
#   - inside a heredoc: print verbatim until the delimiter line (for <<- the
#     delimiter may be indented with TABs, exactly as bash allows);
#   - line 1 starting with #!: keep (the shebang is an interpreter directive);
#   - comment line: drop;
#   - blank line: remember it, print at most ONE before the next code line;
#   - code line: print, then check whether it OPENS a heredoc.
# Heredoc detection requires the "<<" not to be preceded by another "<"
# (that would be a here-string, <<<) and an upper-case delimiter word.
# -----------------------------------------------------------------------------
read -r -d '' STRIP <<'AWK' || :
FNR == 1 { in_doc = 0; pending = 0; started = 0 }
in_doc {
    print
    probe = $0
    if (strip_tabs) sub(/^\t+/, "", probe)
    if (probe == delim) in_doc = 0
    next
}
FNR == 1 && /^#!/ { print; started = 1; next }
/^[ \t]*#/ { next }
/^[ \t]*$/ { pending = 1; next }
{
    if (pending && started) print ""
    pending = 0
    print
    started = 1
    if (match($0, /(^|[^<])<<-?[ \t]*['"]?[A-Z_][A-Z0-9_]*['"]?/)) {
        h = substr($0, RSTART, RLENGTH)
        sub(/^[^<]*<</, "", h)
        strip_tabs = (h ~ /^-/)
        gsub(/[-'" \t]/, "", h)
        delim = h
        in_doc = 1
    }
}
AWK

is_code() {
  case $1 in
    *.sh | *.awk | *.ini | bin/*) return 0 ;;
    .env.example | */.env.example | .gitignore | */.gitignore | .shellcheckrc | */.shellcheckrc) return 0 ;;
  esac
  return 1
}

# build SRC_SET OUT_DIR - render one set into OUT_DIR; prints statistics.
# Paths come from find as NUL-terminated "./relative/path" records; the
# leading "./" is removed with parameter expansion. Files that start with a
# shebang are made executable in the output.
build() {
  local src=$1 out=$2 rel first
  local -i stripped=0 copied=0 removed=0 before after
  while IFS= read -r -d '' rel; do
    rel=${rel#./}
    mkdir -p -- "$out/$(dirname -- "$rel")"
    if is_code "$rel"; then
      awk "$STRIP" "$src/$rel" > "$out/$rel"
      before=$(wc -l < "$src/$rel")
      after=$(wc -l < "$out/$rel")
      removed=$(( removed + before - after ))
      (( ++stripped ))
    else
      cp -- "$src/$rel" "$out/$rel"
      (( ++copied ))
    fi
    first=""
    IFS= read -r first < "$src/$rel" || :
    if [[ $first == '#!'* ]]; then
      chmod 0755 "$out/$rel" 2>/dev/null || :
    fi
  done < <(cd -- "$src" && find . \( -path ./var -o -name .env \) -prune -o -type f -print0 | LC_ALL=C sort -z)
  printf '  %-12s %3d code files stripped (%d lines removed), %d files copied\n' \
    "${src##*/}" "$stripped" "$removed" "$copied"
}

# Mirror OUT_DIR onto DEST, deleting stale files but preserving var/ and .env.
publish() {
  local out=$1 dest=$2 f rel
  mkdir -p -- "$dest"
  while IFS= read -r -d '' f; do
    rel=${f#./}
    [[ -e $out/$rel ]] || rm -f -- "$dest/$rel"
  done < <(cd -- "$dest" && find . \( -path ./var -o -name .env \) -prune -o -type f -print0)
  cp -R -- "$out/." "$dest/"
  find "$dest" -depth -type d -empty -not -path "$dest/var*" -delete 2>/dev/null || :
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/sync-editions.XXXXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
status=0
printf '%s %s -> %s\n' "$mode" "$here" "$pure"
for set_dir in "$here"/*/; do
  set_dir=${set_dir%/}
  name=${set_dir##*/}
  [[ $name != tools ]] || continue
  build "$set_dir" "$tmp/$name"
  if [[ $mode == check ]]; then
    if ! diff -r -x var -x .env -- "$tmp/$name" "$pure/$name" > "$tmp/$name.diff" 2>&1; then
      printf '  %-12s OUT OF DATE:\n' "$name"
      sed 's/^/    /' "$tmp/$name.diff" | head -n 40
      status=1
    else
      printf '  %-12s in sync\n' "$name"
    fi
  else
    publish "$tmp/$name" "$pure/$name"
  fi
done
exit "$status"
