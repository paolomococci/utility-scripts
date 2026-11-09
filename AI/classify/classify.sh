#!/usr/bin/env bash

# ------------------------------------------------------------------
# classify.sh
#
# MIT License
#
# Copyright (c) 2026 Paolo Mococci (full-stack web developer)
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
# ------------------------------------------------------------------

# ------------------------------------------------------------------
#
# Features:
# --------
# - Auto-detects state file format (CSV, TSV, or JSON).
# - JSON input: Passes the raw JSON object directly to the `state` field.
# - CSV/TSV input: JSON-escapes the raw text to maintain compatibility with existing pipelines.
# - "Row-by-row": Processes CSV/TSV files one line at a time (useful for large datasets).
# - Flexible Networking: Accepts host:port arguments or falls back to OLLAMA_HOST.
# - Robust Parsing: Supports multiple separators (comma, colon, semicolon, pipe).
#
# Usage:
# ------
# ./classify.sh <state_file> <model_name> <questions_file> [host:port]
#
# Optional environment variables:
# ------------------------------
# OLLAMA_HOST=...            # Overrides the default host
# CLASSIFY_VERBOSE=true      # Enables detailed debugging output
# ------------------------------------------------------------------

set -euo pipefail

# ------------------------------------------------------------------
# 0.0 Text Colors
# ------------------------------------------------------------------
red_text_color=$'\033[31m'
yellow_text_color=$'\033[33m'
magenta_text_color=$'\033[35m'
cyan_text_color=$'\033[36m'
reset_default_text_color=$'\033[0m'

# ------------------------------------------------------------------
# 0.1 Dependency Verification
# ------------------------------------------------------------------
# Ensure the core binaries required for JSON processing, text parsing,
# and network communication are available in the system PATH.
for cmd in jq awk curl; do
    command -v "$cmd" >/dev/null 2>&1 || {
        printf '%s⚠️    Please install: %s is required but not found!%s\n' \
            "$yellow_text_color" "$cmd" "$reset_default_text_color" >&2
        exit 1
    }
done

# ------------------------------------------------------------------
# 0.2 Utility: Error Logging
# ------------------------------------------------------------------
# Standardized error printer that outputs to stderr with a red highlight.
error() {
    printf '%s❌    %s!%s\n' "$red_text_color" "$*" "$reset_default_text_color" >&2
}

# ------------------------------------------------------------------
# 0.3 Utility: Alert Logging
# ------------------------------------------------------------------
# Standardized alert printer that outputs to stderr with a yellow highlight.
alert() {
    printf '%s⚠️    %s!%s\n' "$yellow_text_color" "$*" "$reset_default_text_color" >&2
}

# ------------------------------------------------------------------
# 0.3 Utility: Info Logging
# ------------------------------------------------------------------
# Standardized alert printer that outputs to stderr with a magenta highlight.
info() {
    printf '%sℹ️    %s%s\n' "$magenta_text_color" "$*" "$reset_default_text_color" >&2
}

# ------------------------------------------------------------------
# 1.0 Helper: checks that the fields in a CSV/TSV file are consistent
# ------------------------------------------------------------------
# Verifies that every row in the file contains the exact same number of
# columns as the header row to prevent misaligned data.
check_consistent_fields() {
    local sep="$1"
    local file="$2"
    awk -F"$sep" '
        NR==1{n=NF;next}    # Capture the number of fields in the header
        NF!=n{exit 1}       # Exit with error if any row count mismatches
        END{exit 0}
    ' "$file"
}

# ------------------------------------------------------------------
# 1.1.0 Helper: validates CSV structure
# ------------------------------------------------------------------
# Performs a deep check of the CSV file to ensure it is well-formed.
# Covers: empty files, consistent field counts, empty lines and
# unmatched/unbalanced quotes.
validate_csv_structure() {
    local file="$1"
    local sep="$2"

    # 1.1.0 Checks if the file is empty.
    if [[ ! -s "$file" ]]; then
        error "CSV file '$file' is empty"
        return 1
    fi

    # 1.1.1 Checks that all rows have the same number of data points.
    if ! check_consistent_fields "$sep" "$file"; then
        error "CSV file has an inconsistent number of fields"
        return 1
    fi

    # 1.1.2 Checks for any missing values, except for the header row.
    if ! check_empty_lines "$file" "$sep"; then
        return 1
    fi

    # 1.1.3 Confirms that the quoted fields are in the expected format.
    if ! check_quote_balance "$file" "$sep"; then
        return 1
    fi

    return 0
}

# ------------------------------------------------------------------
# 1.1.2 Helper: Identify empty lines in CSV/TSV files
# ------------------------------------------------------------------
# This function performs a scan of the provided file to identify rows 
# that are completely empty or composed solely of whitespace characters.
# To ensure data integrity, it implements "quote-awareness," meaning 
# it will not flag lines containing a quoted space (e.g., " ") as 
# empty, as these are valid data entries in CSV/TSV formats.
check_empty_lines() {
    local file="$1"
    local status

    awk '
        {
            # Check if the entire line is wrapped in double quotes
            in_quotes = (match($0, /^[[:space:]]*"[^"]*"[[:space:]]*$/) || match($0, /^[[:space:]]*"[^"]*/))
            # If the line is blank/whitespace and not quoted, mark as found
            if (!in_quotes && ($0 ~ /^[[:space:]]*$/)) {
                found = 1
                exit
            }
        }
        END { exit found ? 1 : 0 }
    ' "$file"
    status=$?

    # Evaluate the exit status from the AWK process.
    case $status in
    # Exit code 0: File is clean.
    0) return 0 ;;
    # Exit code 1: Empty lines found. Trigger a warning but do not halt execution.
    1)
        alert "The file '$1' might contain empty lines"
        return 0
        ;;
    # Any other exit code: Indicates an execution error or system failure.
    *)
        error "Error while checking for any empty lines in the file '$1'"
        return 1
        ;;
    esac
}

# ------------------------------------------------------------------
# 1.1.3 Helper: checks quote balance in CSV
# ------------------------------------------------------------------
# Validates that every double quote in the file is part of a balanced
# pair (opened and closed). This is critical for identifying malformed
# CSV/TSV data where an unclosed quote would break standard parsers.
check_quote_balance() {
    local file="$1"
    local sep="$2"

    awk -F"$sep" -v sep="$sep" '
        BEGIN { in_quotes = 0 }
        NR == 1 {next}  # Skips the header row
        {
            line = $0
            # Counts unescaped quotes
            gsub(/""/, "", line)
            # Count the remaining unescaped quotes
            quote_count = gsub(/"/, "", line)
            # If the count is odd, a quote is left hanging
            if (quote_count % 2 != 0) {
                print "Unmatched quotes at row " NR
                exit 1
            }
        }
    ' "$file" >/dev/null 2>&1 || {
        error "CSV file has unmatched quotes"
        return 1
    }

    return 0
}

# ------------------------------------------------------------------
# 1.2 Helper: validates the state file and returns its type
# ------------------------------------------------------------------
# Identifies the state file format (JSON, TSV, or CSV) by analyzing
# file extensions, syntax and delimiter presence.
validate_file() {
    local file="$1"

    # 1.2.0 Checks if the file exists and is not empty.
    if [[ ! -s "$file" ]]; then
        error "file '$file' is empty (unknown format)"
        printf 'UNKNOWN\n'
        return 1
    fi

    # 1.2.1 Normalizes the file extension.
    local ext="${file##*.}"
    ext="${ext,,}" # lowercase
    local -r ext_json='json'
    local -r ext_tsv='tsv'

    # 1.2.2 JSON: checks the file extension or syntactic validity.
    if [[ "$ext" == "$ext_json" || "$(jq empty "$file" 2>/dev/null)" ]]; then
        if jq empty "$file" 2>/dev/null; then
            printf 'JSON\n'
            return 0
        else
            error "file '$file' is not a valid JSON file"
            printf 'UNKNOWN\n'
            return 1
        fi
    fi

    # 1.2.3 TSV: checks the file extension or the presence of tabs.
    if [[ "$ext" == "$ext_tsv" || "$(grep -q $'\t' "$file" && echo yes)" ]]; then
        if awk -F'\t' 'NF>1{exit 0} END{exit 1}' "$file" 2>/dev/null; then
            printf 'TSV\n'
            return 0
        fi
    fi

    # 1.2.4 CSV/TSV with an arbitrary separator.
    # Array of separators in priority order.
    local -a separators=(';' '|' ':' ',')
    local sep
    for s in "${separators[@]}"; do
        if grep -q "$s" "$file"; then
            sep="$s"
            break
        fi
    done
    sep="${sep:-,}" # Default to comma if no separator is identified.

    # 1.2.5 Checks that every row has the same number of fields.
    if ! check_consistent_fields "$sep" "$file"; then
        error "CSV file '$file' has an inconsistent number of fields"
        printf 'UNKNOWN\n'
        return 1
    fi

    # 1.2.6 Stricter validation (no separator inside quoted fields, no unmatched quotes).
    # Skips the header row for validation.
    if ! validate_csv_structure "$file" "$sep"; then
        printf 'UNKNOWN\n'
        return 1
    fi

    printf 'CSV\n'
    return 0
}

# ------------------------------------------------------------------
# 1.3 Helper: validates empty JSON arrays
# ------------------------------------------------------------------
# Ensures that the provided file is a well-formed JSON array and
# contains at least one element. This prevents the script from
# proceeding with an empty data set, which would result in no
# operations being performed.
validate_json_array() {
    local file="$1"
    local content

    # Attempt to parse the file using jq.
    # The -c (compact) flag is used to ensure the output is
    # condensed into a single line, making it directly
    # comparable to the empty array literal "[]".
    if ! content=$(jq -c . "$file" 2>/dev/null); then
        # If jq returns a non-zero exit code, the JSON syntax is invalid.
        return 1
    fi

    # Check if the parsed content is exactly an empty JSON array.
    if [[ "$content" == "[]" ]]; then
        error "JSON array in '$file' is empty"
        return 1
    fi

    # If the file is a valid, non-empty JSON array, return success.
    return 0
}

# ------------------------------------------------------------------
# 1.4 Helper: host environment variable sanitization function
# ------------------------------------------------------------------
# Normalizes the input host string by stripping surrounding whitespace,
# removing protocol schemes (http/https) and eliminating trailing
# slashes. This ensures that the host string is in a clean "hostname:port"
# format before being used to construct network URLs.
sanitize_host() {
    local h="$1"

    # 1.3.0 Removes leading and trailing spaces.
    # This allows the script to manage the protocol internally.
    h="${h#"${h%%[![:space:]]*}"}" # leading
    h="${h%"${h##*[![:space:]]}"}" # trailing

    # 1.3.1 Removes any prefixes to the protocol.
    h="${h#http://}"
    h="${h#https://}"

    # 1.3.2 Removes any final slash.
    # This prevents malformed URLs (e.g., "host:port//path") when
    # concatenating the host with the API endpoint path.
    h="${h%/}"

    echo "$h"
}

# ------------------------------------------------------------------
# 1.5 Helper: extracts headers from a CSV/TSV file
# ------------------------------------------------------------------
# This command extracts the header row of a delimited file and transforms it into a JSON array of strings.
# It tokenizes the first line using the specified separator, converts each field into a raw string and slurps them into a single JSON array, ensuring the result is non-empty.
extract_headers() {
    local sep="$1"
    local file="$2"
    # 1. Extraction:    `head -n 1` retrieves the first line (header) of the file.
    # 2. Tokenization:  `awk` splits the line into individual fields based on the delimiter and prints each one on a new line.
    # 3. Serialization: `jq -R` treats each line as a raw string.
    # 4. Aggregation:   `jq -s` (slurp) collects those strings into a single JSON array, while the final filter ensures that an empty result is discarded.
    head -n 1 "$file" | awk -F"$sep" '{for (i=1; i<=NF; i++) print $i}' | jq -R . | jq -s '. | if length > 0 then . else empty end'
}

# ------------------------------------------------------------------
# 1.6 Helper: detects the separator for CSV files
# ------------------------------------------------------------------
# Heuristically determines the CSV separator by counting occurrences
# outside of quoted strings in the header row.
detect_separator() {
    local file="$1"
    local -a separators=(';' '|' ':' ',')

    # First, checks if the file is empty.
    if [[ ! -s "$file" ]]; then
        echo ","
        return 0
    fi

    # Tries to detect the separator by checking the header row.
    local header=$(head -n 1 "$file")
    local detected_sep=""

    # Skip detection if header is empty or has no separators.
    if [[ -z "$header" || "$header" =~ ^[[:space:]]*$ ]]; then
        echo ","
        return 0
    fi

    # For each candidate separator, count occurrences outside quotes.
    for s in "${separators[@]}"; do
        local count=$(count_separator_occurrences "$file" "$s")
        if [[ $count -gt 1 ]]; then
            detected_sep="$s"
            break
        fi
    done

    # Falls back to comma if no clear separator is found.
    echo "${detected_sep:-,}"
}

# ------------------------------------------------------------------
# 1.6.1 Helper: counts separator occurrences outside quotes
# ------------------------------------------------------------------
count_separator_occurrences() {
    local file="$1"
    local sep="$2"

    # Count occurrences of separator outside quoted strings.
    awk -F"$sep" 'BEGIN { RS="\"" } { print NR-1 }' "$file" | awk '{sum+=$1} END {print sum}' 2>/dev/null || echo 0
    # `-F"$sep"`: This sets the Field Separator (FS).
    # `BEGIN { RS="\"" }`: This is the most critical part. It overrides the Record Separator (RS).
    # `{ print NR-1 }`: For every record found (every double quote), `awk` prints the current Record Number (NR) minus one.
    # `"$file"`: The input file being processed.
    # `|`: The pipe takes the Standard Output (stdout) of the first `awk` command and feeds it into the Standard Input (stdin) of the second `awk` command.
    # `{sum+=$1}`: This iterates through every line received from the pipe. It takes the first field (`$1`), which is the number we printed in the previous step and adds it to a running variable called `sum`.
    # `END {print sum}`: Once the entire input has been processed, this block executes, printing the final total.
    # `2>/dev/null`: This redirects Standard Error (stderr) to the "null" device.
    # `|| echo 0`: This is a logical OR operation based on the exit status of the pipeline.
}

# ------------------------------------------------------------------
# 1.7.0 Helper: escape a string for JSON
# ------------------------------------------------------------------
# Prepares a raw string for safe inclusion as a value within a JSON
# object. It performs a multi-step sanitization process: normalizing
# various quote types, escaping control characters and stripping
# redundant wrapping quotes.
escape_json_string() {
    local str="$1"
    local escaped

    # Preserve existing backslash escapes.
    # This prevents the subsequent escaping logic from incorrectly
    # processing characters that were already manually escaped.
    escaped=${str//\\/\\}
    escaped=${escaped//\"/\"}

    # Normalize various typographic and alternative quotes to standard
    # single or double quotes. This handles "curly" quotes (U+2018-201C)
    # and backticks often found in copy-pasted text.
    # U+0060 (Backtick)
    escaped=${escaped//\`/\'}
    # U+2018 (Left Single Quotation Mark)
    escaped=${escaped//\‘/\'}
    # U+2019 (Right Single Quotation Mark)
    escaped=${escaped//\’/\'}
    # U+201C (Left Double Quotation Mark)
    escaped=${escaped//\“/\"}
    # U+201D (Right Double Quotation Mark)
    escaped=${escaped//\”/\"}

    # Escape special characters and control sequences required by the
    # JSON specification. This ensures that newlines, tabs and
    # literal double quotes do not break the JSON structure.
    escaped=${escaped//\"/\\\"}
    escaped=${escaped//$'\n'/\\n}
    escaped=${escaped//$'\r'/\\r}
    escaped=${escaped//$'\t'/\\t}

    # Strip leading and trailing escaped quotes if they exist.
    # This is useful for inputs that were already wrapped in quotes
    # at the source (e.g., if the input was "\"Value\"").
    if [[ $escaped == *\\\"* ]]; then
        # Check if first and last characters are escaped quotes.
        if [[ "${escaped:0:2}" == \\\" && "${escaped: -2:2}" == \\\" ]]; then
            # Remove the leading and trailing escaped quotes.
            escaped="${escaped:2:-2}"
        fi
    fi

    echo "$escaped"
}

# ------------------------------------------------------------------
# 1.7.1 Helper: converts a CSV/TSV line to a JSON object
# ------------------------------------------------------------------
# Converts a CSV/TSV header line and a matching data row into a JSON object string.
# Automatically detects the column separator if it is not explicitly provided
# or cannot be confirmed from both the header and row (e.g., separator absent in input).
# Prints the JSON object followed by a newline ('\n'). Exits with an error if no
# separator can be detected-this avoids silent mis-parsing. Numeric values (including
# optional decimals and scientific notation like "1.2" or "3e-4") are output raw (no quotes);
# all other values (including keys, non-numeric strings and edge cases like ".5" or "1.")
# are JSON-escaped and quoted. Space (' ') is handled separately via IFS to avoid splitting
# on internal spaces/tabs within fields.
#
# Note: The numeric regex is intentionally simple-it matches basic integer/decimal/scientific
# patterns but does *not* allow leading/trailing dots (e.g., ".5" or "1."), which are safely
# treated as strings. For stricter numeric validation, adjust the regex as needed.
csv_line_to_json() {
    local header="$1" row="$2" sep=${3:-}
    local candidate rest key value escaped i
    local -a headers=() values=()

    # If separator is empty/unverified (no third arg or separator not found in both header/row),
    # try common candidates to detect it automatically.
    if [[ -z $sep || $header != *"$sep"* || $row != *"$sep"* ]]; then
        sep=
        for candidate in ',' ':' ';' '|' $'\t' ' '; do
            if [[ $header == *"$candidate"* && $row == *"$candidate"* ]]; then
                sep=$candidate
                break
            fi
        done
    fi

    # If still no separator found after detection, report error and exit.
    if [[ -z $sep ]]; then
        error "Separator not found"
        return 1
    fi

    # Split headers and values using the determined separator.
    # Space (' ') is handled via IFS ($' \t') because splitting on plain space would break fields
    # containing internal spaces/tabs. Other separators use explicit while loops to avoid IFS pitfalls.
    if [[ $sep == ' ' ]]; then
        IFS=$' \t' read -r -a headers <<<"$header"
        IFS=$' \t' read -r -a values <<<"$row"
    else
        # Split header line: repeatedly take the part before the first separator,
        # then drop the separator and separator-prefixed remainder.
        # Last field (no trailing sep) is added after the loop.
        rest=$header
        while [[ $rest == *"$sep"* ]]; do
            headers+=("${rest%%"$sep"*}") # Field before separator.
            rest=${rest#*"$sep"}          # Remainder after separator.
        done
        headers+=("$rest") # Final field.

        # Same logic for the data row.
        rest=$row
        while [[ $rest == *"$sep"* ]]; do
            values+=("${rest%%"$sep"*}")
            rest=${rest#*"$sep"}
        done
        values+=("$rest")
    fi

    # Build the JSON object string.
    printf '{'
    for ((i = 0; i < ${#headers[@]}; i++)); do
        ((i > 0)) && printf ','

        key=${headers[i]}
        value=${values[i]}

        # Keys are always JSON-escaped and quoted (required by JSON spec).
        escaped_key=$(escape_json_string "$key")
        printf '"%s":' "$escaped_key"

        # Numeric pattern: optional '-', digits, optional '.'+digits, optional 'e/E'±digits.
        # Matches things like "123", "-0.45", "1e+2", but *not* ".5" or "1." (which stay strings).
        if [[ $value =~ ^-?[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$ ]]; then
            printf '%s' "$value"
        else
            escaped_value=$(escape_json_string "$value")
            printf '"%s"' "$escaped_value" # Quote and escape non-numeric values.
        fi
    done
    printf '}\n'
}

# ------------------------------------------------------------------
# 1.8 Helper: Checks if the specified model exists on the Ollama server
# ------------------------------------------------------------------
# Verifies that the requested model is loaded and available on the Ollama server.
check_model() {
    local model="$1"
    local url="http://${HOST_ONLY}:${PORT}/v1/models/${model}"
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" "$url")
    [[ "$http_code" -eq 200 ]]
}

# ------------------------------------------------------------------
# 1.9 Helper: Generic validation and error handling function
# ------------------------------------------------------------------
# Orchestrates all format-specific validation logic based on the detected type.
validate_and_check() {
    local file="$1"
    local file_type="$2"

    # Checks if the file exists and is not empty.
    if [[ ! -s "$file" ]]; then
        error "file '$file' is empty (classified as $file_type format)"
        return 1
    fi

    # Checks if the file is JSON if required.
    if [[ "$file_type" == "JSON" ]] && ! jq empty "$file" 2>/dev/null; then
        error "file '$file' is not a valid JSON file"
        return 1
    fi

    # Checks if the file is JSON array and not empty
    if [[ "$file_type" == "JSON" ]]; then
        if ! validate_json_array "$file"; then
            return 1
        fi
    fi

    # Checks if the file is TSV if required.
    if [[ "$file_type" == "TSV" ]] && ! awk -F'\t' 'NF>1{exit 0} END{exit 1}' "$file" 2>/dev/null; then
        error "file '$file' is not a valid TSV file"
        return 1
    fi

    # Checks if the file is CSV if required.
    if [[ "$file_type" == "CSV" ]]; then
        local sep
        # Array of separators in priority order.
        local -a separators=(';' '|' ':' ',')
        for s in "${separators[@]}"; do
            if grep -q "$s" "$file"; then
                sep="$s"
                break
            fi
        done
        sep="${sep:-,}"

        # Checks that every row has the same number of fields.
        if ! check_consistent_fields "$sep" "$file"; then
            error "CSV file '$file' has an inconsistent number of fields"
            return 1
        fi

        # Performs stricter checks only.
        if ! validate_csv_structure "$file" "$sep"; then
            return 1
        fi
    fi

    return 0
}

# ------------------------------------------------------------------
# 1.10 Helper: Generic function for connection and model management
# ------------------------------------------------------------------
# Verifies both network reachability (via nc or curl) and the
# existence of the specific model on the remote server.
check_connection_and_model() {
    local host_only="$1"
    local port="$2"
    local model_name="$3"

    # Connectivity test: prefer `nc` (netcat) for speed, fall back to `curl`.
    if command -v nc >/dev/null 2>&1; then
        if ! nc -z -w5 "$host_only" "$port"; then
            error "Cannot connect to ${host_only}:${port}"
            return 1
        fi
    else
        if ! curl -s --fail --head --max-time 5 "http://${host_only}:${port}/api/tags" >/dev/null; then
            error "Cannot connect to ${host_only}:${port} (curl HEAD failed)"
            return 1
        fi
    fi

    # Checks if the model exists.
    local url="http://${host_only}:${port}/v1/models/${model_name}"
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" "$url")
    if [[ "$http_code" -ne 200 ]]; then
        error "model '$model_name' is not found on host '$host_only' at port '$port'"
        return 1
    fi

    return 0
}

# ------------------------------------------------------------------
# 1.11 Helper: Generic function for host and port management
# ------------------------------------------------------------------
# Parses the host/port argument and applies logic to prioritize
# OLLAMA_HOST environment variable over CLI arguments.
resolve_host_and_port() {
    local host_arg="$1"

    if [[ -z "$host_arg" ]]; then
        HOST_ONLY="localhost"
        PORT="11434"
    else
        # Parse host:port (e.g., 192.168.1.51:11434).
        if [[ "$host_arg" =~ ^([^:]+):([0-9]+)$ ]]; then
            HOST_ONLY="${BASH_REMATCH[1]}"
            PORT="${BASH_REMATCH[2]}"
        elif [[ "$host_arg" =~ ^[0-9]+$ ]]; then
            HOST_ONLY="localhost"
            PORT="$host_arg"
        else
            HOST_ONLY="$host_arg"
            PORT="11434"
        fi
    fi

    # Handles the OLLAMA_HOST environment variable.
    if [[ -n "${OLLAMA_HOST:-}" ]]; then
        SANITIZED_HOST=$(sanitize_host "$OLLAMA_HOST")
        if ! curl -s --fail --head --max-time 5 "http://$SANITIZED_HOST:$PORT/api/tags" >/dev/null; then
            error "Ollama is not reachable at ${SANITIZED_HOST}:${PORT}"
            error "Falling back to localhost:${PORT}"
            HOST_ONLY="localhost"
        else
            HOST_ONLY="$SANITIZED_HOST"
        fi
    fi

    # Checks if Ollama is running on localhost.
    if [[ "$HOST_ONLY" == "localhost" ]]; then
        if ! curl -s --fail --fail-early --head --max-time 5 "http://$HOST_ONLY:$PORT/api/tags" >/dev/null; then
            error "Ollama is not running on localhost:${PORT}"
            error "Please start Ollama and ensure it is listening on port ${PORT}."
            return 1
        fi
    fi

    return 0
}

# ------------------------------------------------------------------
# 1.12 Helper: Sends a single request (the state is passed in $1)
# ------------------------------------------------------------------
# Construct the final JSON payload and execute the POST request to
# the Ollama /v1/systemone endpoint.
send_request() {
    local state_payload="$1"
    local payload
    # Merge the dynamic state with the static base payload (questions).
    payload=$(jq -n \
        --argjson state "$state_payload" \
        --argjson base "$BASE_PAYLOAD" \
        '(. + $base) | .state = $state')
    local curl_opts=(
        -s                # Silent mode
        --fail            # Fail on HTTP errors
        --fail-early      # Fail as soon as possible
        --max-time 120    # Timeout after 2 minutes
        --retry 3         # Retry on transient network errors
        --retry-delay 5   # Wait 5s between retries
        -w "%{http_code}" # Capture HTTP status code
        -X POST "$OLLAMA_URL"
        -H "Content-Type: application/json"
        -d "$payload"
        -o "$TMP_RESPONSE" # writes the body to the temp file
    )

    # If verbose mode is enabled, prints debugging information.
    if [[ "${CLASSIFY_VERBOSE:-false}" == "true" ]]; then
        info "===   Sending request to: $OLLAMA_URL"
        info "===   Payload size: ${#payload} bytes"
        printf '===   curl %s\n' "${curl_opts[@]}" >&2 # securely prints the cURL command
    fi

    # Executes curl and captures the HTTP status code (the last output from curl).
    local http_status
    http_status=$(curl "${curl_opts[@]}")

    # If the server responded with a status other than 200 OK, reports it.
    if [[ "$http_status" -ne 200 ]]; then
        error "Ollama responded with HTTP $http_status"
        echo "Response body:" >&2
        cat "$TMP_RESPONSE" >&2
        exit 1
    fi

    jq . "$TMP_RESPONSE" 2>/dev/null || cat "$TMP_RESPONSE"
}

# ------------------------------------------------------------------
# 2.0 Argument handling
# ------------------------------------------------------------------
# Simple --help / --version support.
usage() {
    cat <<EOF >&2
${yellow_text_color}
🤓  Usage: ./classify.sh <state_file> <model_name> <questions_file> [host:port]

👉  Options:
    -h, --help      Show this help message and exit.
    -v, --version   Print script version and exit.

👉  Environment variables (optional):
    OLLAMA_HOST=...            # Overrides the default localhost value.
    CLASSIFY_VERBOSE=true      # Enables verbose output.
${reset_default_text_color}
EOF
}

# Parse flags.
while [[ $# -gt 0 ]]; do
    case "$1" in
    -h | --help)
        usage
        exit 0
        ;;
    -v | --version)
        echo "${cyan_text_color}💬   Version: 0.1${reset_default_text_color}"
        exit 0
        ;;
    *) break ;;
    esac
    shift
done

# Verify that the script was called with 3 or 4 arguments.
if [[ $# -lt 3 || $# -gt 4 ]]; then
    usage
    exit 1
fi

# ------------------------------------------------------------------
# 2.1 Bind positional arguments to descriptive variable names
# ------------------------------------------------------------------
STATE_FILE="$1"
MODEL_NAME="$2"
QUESTIONS_FILE="$3"
HOST_ARG="${4:-localhost:11434}"

# ------------------------------------------------------------------
# 3.0 Basic file checks
# ------------------------------------------------------------------
# Ensures that both the state file and the questions file actually exist.
# If either is missing, reports the error and terminates.
for f in "$STATE_FILE" "$QUESTIONS_FILE"; do
    [[ -f $f ]] || {
        error "file '$f' not found"
        exit 1
    }
done

# ------------------------------------------------------------------
# 4.0 Host/Port Resolution
# ------------------------------------------------------------------
if ! resolve_host_and_port "$HOST_ARG"; then
    exit 1
fi

# ------------------------------------------------------------------
# 5.0 Connectivity & Model Check
# ------------------------------------------------------------------
if ! check_connection_and_model "$HOST_ONLY" "$PORT" "$MODEL_NAME"; then
    exit 1
fi

# ------------------------------------------------------------------
# 6.0 Loads the state file (JSON, CSV or TSV)
# ------------------------------------------------------------------
STATE_FORMAT=$(validate_file "$STATE_FILE")

STATE_JSON=""
ROW_MODE=false
RAW_DATA=""
SEPARATOR="," # Default initialization.

# If the file is CSV, detects the separator.
if [[ "$STATE_FORMAT" == "CSV" ]]; then
    SEPARATOR=$(detect_separator "$STATE_FILE")
fi

case "$STATE_FORMAT" in
"JSON")
    STATE_JSON=$(jq -c . "$STATE_FILE")
    # Empty JSON array.
    if ! validate_and_check "$STATE_FILE" "JSON"; then
        exit 1
    fi
    ;;
"TSV" | "CSV*" | "CSV")
    # Always in row-by-row mode.
    ROW_MODE=true
    RAW_DATA=$(<"$STATE_FILE")
    STATE_JSON=$(jq -Rs . <<<"$RAW_DATA")
    ;;
*)
    error "state file '$STATE_FILE' is not a valid JSON, CSV or TSV"
    exit 1
    ;;
esac

# ------------------------------------------------------------------
# 7.0 Validates the questions file (must be valid JSON)
# ------------------------------------------------------------------
if ! jq empty "$QUESTIONS_FILE" 2>/dev/null; then
    error "questions file is not valid JSON"
    exit 1
fi

# ------------------------------------------------------------------
# 8.0 Prepares the base payload (excluding state, which may vary per row)
# ------------------------------------------------------------------
# Constructs the JSON payload expected by the Ollama endpoint.
# `jq -n` starts with an empty object, then we add fields.
BASE_PAYLOAD=$(jq -n \
    --arg model "$MODEL_NAME" \
    --argjson questions "$(cat "$QUESTIONS_FILE")" \
    '{model: $model, questions: $questions}')

# ------------------------------------------------------------------
# 9.0 Builds the Ollama endpoint URL
# ------------------------------------------------------------------
# Uses the environment variable OLLAMA_HOST if set; otherwise, builds the URL
# from the host/port variables. The default path is /v1/systemone.
OLLAMA_URL="http://${HOST_ONLY}:${PORT}/v1/systemone"

# ------------------------------------------------------------------
# 10.0 Temporary file for the response body
# ------------------------------------------------------------------
# Creates a temporary file to store the response body.
# `mktemp` creates the file atomically, so there's no "time-of-check-time-of-use" vulnerability.
TMP_RESPONSE=$(mktemp -p /tmp classify-response-XXXXXX) || {
    error "cannot create temp file"
    exit 1
}
trap 'rm -f "$TMP_RESPONSE"' EXIT

# ------------------------------------------------------------------
# 11.0 Main Execution Logic
# ------------------------------------------------------------------
if [[ "${ROW_MODE:-false}" == "true" ]]; then
    # Extract headers from the first line of the CSV/TSV.
    headers=$(extract_headers "$SEPARATOR" "$STATE_FILE")

    # Converts headers to a space-separated string for the function.
    headers_str=$(jq -r 'join(",")' <<<"$headers")

    # Iterate through each data row, skipping the header.
    tail -n +2 "$STATE_FILE" | {
        data_lines_found=0
        line_count=1
        empty_line_count=0

        while IFS= read -r line || [[ -n "$line" ]]; do
            line_count=$((line_count + 1))

            # Check for empty lines.
            if [[ -z "$line" || "$line" =~ ^[[:space:]]*$ ]]; then
                empty_line_count=$((empty_line_count + 1))
                if [[ "${CLASSIFY_VERBOSE:-false}" == "true" ]]; then
                    alert "===   Skipping empty line (line $line_count)"
                fi
                continue
            fi

            # Convert the current row into its JSON equivalent.
            state_payload=$(csv_line_to_json "$headers_str" "$line" "$SEPARATOR")

            # Debug output if verbose mode is enabled.
            if [[ "${CLASSIFY_VERBOSE:-false}" == "true" ]]; then
                info "===   Processing row $line_count: $line"
                info "===   JSON payload: $state_payload"
            fi

            # Sends the request and gets the response.
            send_request "$state_payload"
            data_lines_found=$((data_lines_found + 1))
        done

        # Check if we processed any data lines
        if [[ $data_lines_found -eq 0 ]]; then
            if [[ $empty_line_count -gt 0 ]]; then
                error "No data rows found in '$STATE_FILE' (only headers and $empty_line_count empty line(s))"
            else
                error "No data rows found in '$STATE_FILE' (only headers)"
            fi
            exit 1
        fi

        if [[ $empty_line_count -gt 0 && "${CLASSIFY_VERBOSE:-false}" == "true" ]]; then
            info "===   Skipped $empty_line_count empty line(s)"
        fi
    }

else
    # --- JSON OBJECT/ARRAY EXECUTION ---
    # Read the entire file and determine if it's a single object or an array.
    RAW_DATA=$(tail -n +1 "$STATE_FILE")

    if ! json_type=$(printf '%s\n' "$RAW_DATA" | jq -r 'type'); then
        echo "Invalid JSON" >&2
        exit 1
    fi

    case "$json_type" in
    array)
        # Iterate over each element in the JSON array.
        while IFS= read -r object; do
            # Sends an element of array JSON in the request and receives the response.
            send_request "$object"
        done < <(printf '%s\n' "$RAW_DATA" | jq -c '.[]')
        ;;
    object)
        # Send the single JSON object.
        send_request "$(printf '%s\n' "$RAW_DATA" | jq -c '.')"
        ;;
    *)
        echo "Unexpected JSON type: $json_type" >&2
        exit 1
        ;;
    esac
fi

# Exits with a success status.
exit 0
