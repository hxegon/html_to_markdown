#!/usr/bin/env bash

# Script for converting web pages into markdown format

# TODO:
# - [ ] Pass in commands for extracting header/content html
# - [x] Download from url
#   - [ ] Error handling for:
#     - [ ] 404
#     - [ ] 403
#     - [ ] 500
# - [x] Enable consuming html from stdin
# - [x] Option for output to file with formatted name
#   - [x] Add substitution for domain
#   - [ ] Ask to make directory if -o specifies one.
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
-o/--output-file - Output to a file. Substitutes <domain> and <slug>. Only works if -u is supplied.
  - i.e. ./main.sh -u "https://google.com/foo/really_cool_page.html" -f "<domain>/<slug>.md" # -> google_com/really_cool_page.md
  - Doesn't make directories so this will fail if google_com doesn't already exist
-F/--format - is the pandoc format arg. Defaults to markdown_strict-raw_html+simple_tables
-H/--no-heading - turns off adding the file name as a heading to the final markdown doc
-s/--silent - Turns off any logging/verbose output
-v/--verbose - Show extra info when processing
--error-on-empty - Exit with an error if there is no page content after being converted
  Default behavior is to not output the page and log that it was empty, but exit successfully

Dependencies:
htmlq - preprocess html for better markdown conversion
pandoc - Actual html to markdown conversion
getopt - arg parsing
curl - Downloading page

!! This doesn't work on OS X because of various differences with the gnu vs bsd tools (sed, getopt, xargs etc.) !!
END
)

## LOGGING FUNCTIONS ##

VERBOSE=false
SILENT=false

log() {
  # TODO: Add -s/--silent option
  if [[ "$SILENT" == false ]]; then
    echo "main.sh: $@" >&2
  fi
}

verbose() {
  # Output to STDERR if verbose flag is on
  if [[ $VERBOSE == true ]]; then
    log "main.sh: $@"
  fi
}

fail() {
  log "$@"
  log "terminating..."
  exit 1
}

## INPUT HANDLING ##

# Use STDIN if there is any
STDIN=""
if [[ ! -t 0 ]]; then # non blocking check for STDIN content
  STDIN="$(cat -)"
fi

# Exit if there are no arguments
if [[ "$@" == "" && "$STDIN" == "" ]]; then
  echo "main.sh: $HELPMESSAGE"
  exit 0
fi

# Initialize argument vars
URL=""
ADD_HEADING=true
FORMAT="markdown_strict-raw_html+simple_tables"
TEST_ARGS=false
ERROR_ON_EMPTY=false
OUTPUT_FILE=""

TEMP=$(getopt -o shHvF:u:o: --longoptions url:,format:,output-file:,no-heading,test-args,verbose,error-on-empty,silent -n "$0" -- "$@")

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

    # FIX: I'm sure there are conditions where this won't work.
    # TODO: Test these
    URL_DIR=$(echo "$URL" | sed -E 's|(.+)/[^/]*$|\1|' | sed 's|/$||')  # https://foobar.com/bar/bazfoo.html -> https://foobar.com/bar
    URL_DOMAIN=$(echo "$URL" | sed -E -n 's|.*(https?://[^/]+).*|\1|p') # https://foo.bar/biz/buz.jpg -> https://foo.bar
    URL_DOMAIN_ONLY=$(echo "$URL_DOMAIN" | sed -E 's|https?://||')
    # Used in heading and generating a file name with -o
    URL_SLUG=$(echo "$URL" | sed -E 's|.+/([^/]+)\..*$|\1|') # https://foo.bar/blog/2024/big-cool-article.html -> big-cool-article
    ;;
  # Optional
  -o | --output-file)
    OUTPUT_FILE=$2
    shift 2
    ;;
  -F | --format)
    FORMAT=$2
    shift 2
    ;;
  -v | --verbose)
    VERBOSE=true
    shift 1
    ;;
  -s | --silent)
    SILENT=true
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

# Require a source of html
if [[ "$URL" == "" && "$STDIN" == "" ]]; then
  fail "No --url specified, and no html input through STDIN. Nothing to convert!"
fi

if [[ "$OUTPUT_FILE" != "" && "$URL" == "" ]]; then
  if [[ "$(echo $OUTPUT_FILE | sed -E 's/(<slug>|<domain>)/\1/')" != "" ]]; then
    fail "You specified an output file with tokens for <slug> or <domain>, but there's no url (-u) to get those from"
  fi
fi

## PROGRAM ##

# Get html
if [[ "$STDIN" == "" ]]; then
  verbose "Fetching html from $URL"
  HTML="$(curl -sSL $URL)"
else
  verbose "Reading html from STDIN"
  HTML="$STDIN"
fi

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
  if [[ "$PAGE_NAME" == "" && "$URL" != "" ]]; then
    PAGE_NAME="$(echo $URL_SLUG | sed 's/[-_]/ /g')"
  fi

  HEADING=$"# $PAGE_NAME"

  if [[ "$URL" != "" ]]; then
    HEADING+=" [SOURCE]($URL)"
  fi

  HEADING+=$'\n' # Add blank line under heading
fi

if [[ "$URL" != "" ]]; then
  # Fix href/src references to relative urls
  verbose "Correcting paths"
  HTML=$(
    echo "$HTML" |
      # correct in-page anchor links
      sed -E "s|href=\"(#[^\"]+)\"|href=\"$URL\1\"|g" |
      # correct relative same site urls i.e. src="whatever.jpg"
      sed -E "s|href=\"([^#/][^:\"]+)\"|href=\"$URL_DIR/\1\"|g" |
      sed -E "s|src=\"([^#/][^:\"]+)\"|src=\"$URL_DIR/\1\"|g" |
      # correct absolute same site urls i.e. src="/whatever.jpg"
      sed -E "s|href=\"/([^\"#]+)\"|href=\"$URL_DOMAIN/\1\"|g" |
      sed -E "s|src=\"/([^\"#]+)\"|src=\"$URL_DOMAIN/\1\"|g"
  )
fi

# Convert html content to markdown
verbose "Converting page html to markdown"
CONTENT="$(echo "$HTML" | htmlq 'div.page_content' -r '.rouge-gutter' | pandoc --from html --to "$FORMAT" --no-highlight)"

# Exit if content is empty
if [[ "$(echo $CONTENT | sed '/^\s*$/d')" == "" ]]; then
  if [[ "$ERROR_ON_EMPTY" == true ]]; then
    fail "Converted content from page was empty (url: $URL)"
  else
    log "Converted content from page was empty (url: $URL), omitting output"
    exit 0
  fi
fi

if [[ "$OUTPUT_FILE" != "" ]]; then
  if [[ "$URL" != "" ]]; then
    # TODO: Check that required URL_* vars are not empty
    # replace any substitution tokens
    CLEAN_DOMAIN_NAME="$(echo $URL_DOMAIN_ONLY | sed 's/\./_/g')"
    # TODO: ask to create folder if it's in a folder
    OUTPUT_FILE="$(echo $OUTPUT_FILE |
      sed $'s/<slug>/'$"$URL_SLUG"$'/g' |
      sed $'s|<domain>|'$"$CLEAN_DOMAIN_NAME"$'|g')"
  fi

  echo "$HEADING" >>$OUTPUT_FILE
  echo "$CONTENT" >>$OUTPUT_FILE
else # Otherwise echo to STDOUT
  echo "$HEADING"
  echo "$CONTENT"
fi

# TODO: remove, this is a temporary fix for a specific use case
echo # Add empty line at end to separate concatenated pages
