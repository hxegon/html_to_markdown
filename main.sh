#!/usr/bin/env bash

# Script for converting web pages into markdown format

# TODO:
# - [x] Download from url
#   - [ ] Error handling for:
#     - [ ] 404
#     - [ ] 403
#     - [ ] 500
# - [ ] Consume from stdin by default, add "page name" or "set heading" option or something
# - [x] Fix anchor links
# - [x] Fix heading issue
# - [x] log and don't output for pages with empty CONTENT
# - [x] change logging to not go to STDOUT. improve verbose logging
# - [x] deprecate base-path arg, require url always and only download if file isn't supplied
# - [x] Show help if no arguments are passed
# - [x] Clean up code blocks
# - [x] fix relative url paths
# - [x] automatically seperate relative/base urls so we can just have one option
# NOTES:
# - getopt matches abbreviated long flag names. if you pass --test as a flag, it will parse it as --test-args for example.
#   this is not a bug, it's just weird intended behavior from getopt

set -o errexit
set -o nounset
set -o pipefail

HELPMESSAGE=$(
  cat <<-END
  Converts web pages into (somewhat) nicely formatted markdown (WIP)
Required:
-u/--url - url to download and convert

Optional:
-F/--format - is the pandoc format arg. Defaults to markdown_strict-raw_html+simple_tables
-H/--no-heading - turns off adding the file name as a heading to the final markdown doc
-v/--verbose - Show extra info when processing
--error-on-empty - Exit with an error if there is no page content after being converted
  Default behavior is to not output the page and log that it was empty, but exit successfully

Dependencies:
htmlq - preprocess html for better markdown conversion
pandoc - Actual html to markdown conversion
getopt - arg parsing
curl - Downloading page

NOTE: This is not yet working cross platform. 
END
)

# Exit if there are no arguments
if [[ $@ == "" ]]; then
  fail "$HELPMESSAGE"
fi

# Initialize argument vars
URL=""
ADD_HEADING=true
FORMAT="markdown_strict-raw_html+simple_tables"
TEST_ARGS=false
VERBOSE=false
ERROR_ON_EMPTY=false

log() {
  # TODO: Add -s/--silent option
  echo "main.sh: $@" >&2
}

verbose() {
  # Output to STDERR if verbose flag is on
  if [[ $VERBOSE == true ]]; then
    log "main.sh: $@"
  fi
}

fail() {
  log "$@"
  log "main.sh terminating..."
  exit 1
}

## ARGUMENT HANDLING ##

TEMP=$(getopt -o hHvF:u: --longoptions url:,format:,no-heading,test-args,verbose,error-on-empty -n "$0" -- "$@")

# Exit if getopt has an error
if [ $? != 0 ]; then
  fail "getopt failed to parse arguments"
fi

eval set -- "$TEMP"

# Ingest command line args
while true; do
  case "$1" in
  # Check immediately
  -h | --help)
    echo "$HELPMESSAGE"
    exit 0
    ;;
  # Required
  -u | --url)
    URL=$2
    shift 2

    # FIX: I'm sure there are conditions where this won't work
    # TODO: Add logging / validations
    URL_DIR=$(echo "$URL" | sed -E 's|(.+)/[^/]*$|\1|' | sed 's|/$||')  # https://foobar.com/bar/bazfoo.html -> https://foobar.com/bar
    URL_DOMAIN=$(echo "$URL" | sed -E -n 's|.*(https?://[^/]+).*|\1|p') # https://foo.bar/biz/buz.jpg -> https://foo.bar
    # Used in heading and generating a file name with -o
    URL_FILE=$(echo "$URL" | sed -E 's|.+/([^/]+)\..*$|\1|') # https://foo.bar/blog/2024/big-cool-article.html -> big-cool-article
    ;;
  # Optional
  -F | --format)
    FORMAT=$2
    shift 2
    ;;
  -v | --verbose)
    VERBOSE=true
    shift 1
    ;;
  -H | --no-heading)
    ADD_HEADING=false
    shift 1 # Shift 1 only because it's just a on/off toggle with no value
    ;;
  --error-on-empty)
    ERROR_ON_EMPTY=true
    shift 1
    ;;
  --test-args)
    TEST_ARGS=true
    shift 1
    ;;
  --)
    shift
    break
    ;;
  *)
    break
    ;;
  esac
done

if [[ $TEST_ARGS == true ]]; then
  echo "Parsed argument string: $TEMP"
  echo "FORMAT: $FORMAT"
  echo "URL: $URL"
  echo "ADD_HEADING: $ADD_HEADING"
  echo "ERROR_ON_EMPTY: $ERROR_ON_EMPTY"
  echo "VERBOSE: $VERBOSE"
  exit 0
fi

verbose "Starting argument validations"

# Require url parameter
if [[ "$URL" == "" ]]; then
  fail "A url have been supplied. It can only be one or the other."
fi

## PROGRAM ##

# Get html
verbose "Grabbing html for $URL"
HTML="$(curl -sSL $URL)"

if [ $? != 0 ]; then
  fail "Failed to download page"
elif [[ "$HTML" == "" ]]; then
  fail "No content to convert in the downloaded page."
fi

# Make a heading
HEADING=""

if [[ $ADD_HEADING == true ]]; then
  PAGE_NAME="$(echo "$HTML" | htmlq 'div.page_title_bar' -r 'div.page_title_bar>*' | pandoc --from html --to $FORMAT --no-highlight)"

  # Backup name for the page is a slightly cleaned up version of the url's slug
  if [[ "$PAGE_NAME" == "" ]]; then
    PAGE_NAME="$(echo $URL_FILE | sed 's/[-_]/ /g')"
  fi

  HEADING=$"# $PAGE_NAME [SOURCE]($URL)"$'\n'
fi

# Fix href/src references to relative urls
verbose "Correcting paths"
HTML=$(
  echo "$HTML" |
    # TODO: Combine the href/src expressions
    # correct in-page anchor links
    sed -E "s|href=\"(#[^\"]+)\"|href=\"$URL\1\"|g" |
    # correct relative same site urls i.e. src="whatever.jpg"
    sed -E "s|href=\"([^#/][^:\"]+)\"|href=\"$URL_DIR/\1\"|g" |
    sed -E "s|src=\"([^#/][^:\"]+)\"|src=\"$URL_DIR/\1\"|g" |
    # correct absolute same site urls i.e. src="/whatever.jpg"
    sed -E "s|href=\"/([^\"#]+)\"|href=\"$URL_DOMAIN/\1\"|g" |
    sed -E "s|src=\"/([^\"#]+)\"|src=\"$URL_DOMAIN/\1\"|g"
)

# Convert html content to markdown
verbose "Converting page html to markdown"
CONTENT="$(echo "$HTML" | htmlq 'div.page_content' -r '.rouge-gutter' | pandoc --from html --to "$FORMAT" --no-highlight)"

# Check for empty content
if [[ "$(echo \"$CONTENT\" | sed '/^\s*$/d')" == "" ]]; then
  if [[ "$ERROR_ON_EMPTY" == true ]]; then
    fail "Converted content from page was empty (url: $URL)"
  else
    log "Converted content from page was empty (url: $URL), omitting output"
    exit 0
  fi
else
  echo "$HEADING"
  echo "$CONTENT"

  # TODO: remove, this is a temporary fix for a specific use case
  echo # Add empty line at end to separate concatenated pages
fi
