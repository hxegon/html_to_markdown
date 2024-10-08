#!/usr/bin/bash

# Script for converting an appian html into markdown format

# TODO:
# - [ ] Output file arg with a substitution option
# - [ ] Consume from stdin by default, add "page name" or "set heading" option or something
# - [ ] If base-path is included, add a markdown link under the heading?
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
Converts appian page html into (somewhat) nicely formatted markdown
Required:
-f/--file - is what file to convert
-F/--format - is the pandoc format arg. Defaults to markdown_strict-raw_html

Optional:
-o/--outfile (NOT IMPLEMENTED) - file to write output too. substitutes {} with the basename of the file
  - i.e. -o "foo/bar/{}_converted.md"
-H/--no-heading - turns off adding the file name as a heading to the final markdown doc
-p/--pretty-heading - Formats filenames a bit prettier into the markdown headings i.e. foo_bar-baz.html -> # foo bar baz
-v/--verbose - Show extra info when processing
--base-path <base-path> - Prepend non-absolute resource paths with a base path
  i.e. with --base-path="https://google.com/foobar"
  - src="images/foo.jpg" -> src="https://google.com/foobar/images/foo.jpg"
  - src="/images/foo.jpg" -> src="https://google.com/images/foo.jpg"

Dependencies:
htmlq - preprocess html for better markdown conversion
pandoc - Actual html to markdown conversion
sed - for cleaning up the headings
getopt (gnu version) - arg parsing
END
)

# Exit if there are no arguments
if [[ $@ == "" ]]; then
  echo "$HELPMESSAGE"
  exit 1
fi

## ARGUMENT HANDLING ##

TEMP=$(getopt -o phHvf:F: --longoptions file:,format:,base-path:,heading,pretty-heading,test-args,verbose -n "$0" -- "$@")

# Exit if getopt has an error
if [ $? != 0 ]; then
  echo "Terminating..." >&2
  exit 1
fi

eval set -- "$TEMP"

FILE=""
FORMAT="markdown_strict-raw_html+simple_tables"
ADD_HEADING=true
TEST_ARGS=false
PRETTY_HEADINGS=false
BASE_PATH=""
VERBOSE=false
OUTFILE=""

# Ingest command line args
while true; do
  case "$1" in
  # Check immediately
  -h | --help)
    echo "$HELPMESSAGE"
    exit 0
    ;;
  # Required
  -f | --file)
    FILE=$2
    shift 2 # Shift 2 to drop flag name & argument
    ;;
  -F | --format)
    FORMAT=$2
    shift 2
    ;;
  # Optional
  -v | --verbose)
    VERBOSE=true
    shift 1
    ;;
  -H | --no-heading)
    ADD_HEADING=false
    shift 1 # Shift 1 only because it's just a on/off toggle with no value
    ;;
  -p | --pretty-heading)
    PRETTY_HEADINGS=true
    shift 1
    ;;
  --test-args)
    TEST_ARGS=true
    shift 1
    ;;
  --base-path)
    BASE_PATH=$2
    shift 2
    ;;
  -o | --outfile)
    OUTFILE=$2
    shift 2
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
  echo "FILE: $FILE"
  echo "ADD_HEADING: $ADD_HEADING"
  echo "PRETTY_HEADINGS: $PRETTY_HEADINGS"
  exit 0
fi

## VALIDATIONS ##

# Require file argument
if [[ "$FILE" == "" ]]; then
  echo -e "-f/--file is a required argument. see --help\nTerminating..."
  exit 1
fi

# Check that file exists
if [[ ! -f "$FILE" ]]; then
  echo -e "File to convert not found: $FILE\nTerminating..."
  exit 1
fi

## PROGRAM ##

verbose() {
  if [[ $VERBOSE == true ]]; then
    echo "verbose message: $1"
  fi
}

if [[ $OUTFILE != "" ]]; then
  verbose "constructing outfile path"
  OUT_BASENAME=$(echo "$OUTFILE" | sed "s/{}/$(basename $FILE .html)")
  OUTFILE="$(dirname $OUTFILE)/$OUT_BASENAME"
fi

# output() {
#   if [[ $OUTFILE != "" ]]; then
#     echo $1 >>$OUTFILE
#   else
#     echo $1
#   fi
# }

CONTENT=$(cat $FILE)

if [[ $BASE_PATH != "" ]]; then
  verbose "starting base path corrections"

  verbose "getting base domain"
  BASE_PATH=$(echo $BASE_PATH | sed 's/\/$//')                                # Ensure any trailing slashes are stripped
  BASE_DOMAIN=$(echo $BASE_PATH | sed -E -n 's/.*(https?:\/\/[^\/]+).*/\1/p') # https://foo.bar/biz/buz.jpg -> https://foo.bar

  verbose "Correcting paths..."
  CONTENT=$(
    echo "$CONTENT" |
      # correct relative same site urls i.e. src="whatever.jpg"
      sed -E "s|href=\"([^/][^:\"]+)\"|href=\"$BASE_PATH/\1\"|g" |
      sed -E "s|src=\"([^/][^:\"]+)\"|src=\"$BASE_PATH/\1\"|g" |
      # correct absolute same site urls i.e. src="/whatever.jpg"
      sed -E "s|href=\"/([^\"]+)\"|href=\"$BASE_DOMAIN/\1\"|g" |
      sed -E "s|src=\"/([^\"]+)\"|src=\"$BASE_DOMAIN/\1\"|g"
  )
  verbose "Paths corrected"
fi

# Add heading if enabled e
if [[ $ADD_HEADING == true ]]; then
  verbose "Adding heading"
  if [[ $PRETTY_HEADINGS = true ]]; then
    echo -e "# $(basename $FILE .html | sed "s/[-_]/ /g")\n"
  else
    echo -e "# Converted HTML to $FORMAT from: $(basename $FILE)\n"
  fi
fi

verbose "Converting page"
echo "$CONTENT" |
  htmlq 'div.page_content' -r '.rouge-gutter' |    # Extract and clean html
  pandoc --from html --to "$FORMAT" --no-highlight # Convert to markdown
