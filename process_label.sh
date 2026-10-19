#!/bin/zsh

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"
export LANG="en_US.UTF-8"

################################
# FUNCTIONS FUNCTIONS FUNCTIONS
################################

downloadURLFromGit() { # $1 git user name, $2 git repo name
    gitusername=${1?:"no git user name"}
    gitreponame=${2?:"no git repo name"}

    if [[ $type == "pkgInDmg" ]]; then
        filetype="dmg"
    elif [[ $type == "pkgInZip" ]]; then
        filetype="zip"
    else
        filetype=$type
    fi

    if [ -n "$archiveName" ]; then
        downloadURL=$(curl -sfL "https://api.github.com/repos/$gitusername/$gitreponame/releases/latest" | awk -F '"' "/browser_download_url/ && /$archiveName\"/ { print \$4; exit }")
        if [[ "$(echo $downloadURL | grep -ioE "https.*$archiveName")" == "" ]]; then
            #downloadURL=https://github.com$(curl -sfL "https://github.com/$gitusername/$gitreponame/releases/latest" | tr '"' "\n" | grep -i "^/.*\/releases\/download\/.*$archiveName" | head -1)
            downloadURL="https://github.com$(curl -sfL "$(curl -sfL "https://github.com/$gitusername/$gitreponame/releases/latest" | tr '"' "\n" | grep -i "expanded_assets" | head -1)" | tr '"' "\n" | grep -i "^/.*\/releases\/download\/.*$archiveName" | head -1)"
        fi
    else
        downloadURL=$(curl -sfL "https://api.github.com/repos/$gitusername/$gitreponame/releases/latest" | awk -F '"' "/browser_download_url/ && /$filetype\"/ { print \$4; exit }")
        if [[ "$(echo $downloadURL | grep -ioE "https.*.$filetype")" == "" ]]; then
            #downloadURL=https://github.com$(curl -sfL "https://github.com/$gitusername/$gitreponame/releases/latest" | tr '"' "\n" | grep -i "^/.*\/releases\/download\/.*\.$filetype" | head -1)
            downloadURL="https://github.com$(curl -sfL "$(curl -sfL "https://github.com/$gitusername/$gitreponame/releases/latest" | tr '"' "\n" | grep -i "expanded_assets" | head -1)" | tr '"' "\n" | grep -i "^/.*\/releases\/download\/.*\.$filetype" | head -1)"
        fi
    fi
    if [ -z "$downloadURL" ]; then
        cleanupAndExit 14 "could not retrieve download URL for $gitusername/$gitreponame" ERROR
    else
        echo "$downloadURL"
        return 0
    fi
}


versionFromGit() {
    gitusername=${1?:"no git user name"}
    gitreponame=${2?:"no git repo name"}

    appNewVersion=$(curl -sLI "https://github.com/$gitusername/$gitreponame/releases/latest" | grep -i "^location" | tr "/" "\n" | tail -1 | sed 's/[^0-9\.]//g')
    if [ -z "$appNewVersion" ]; then
        printlog "could not retrieve version number for $gitusername/$gitreponame" WARN
        appNewVersion=""
    else
        echo "$appNewVersion"
        return 0
    fi
}


xpath() {
    if [[ $(sw_vers -buildVersion) > "20A" ]]; then
        /usr/bin/xpath -q -e $@
    else
        /usr/bin/xpath -q $@
    fi
}


# jq-based replacement for the osascript/JXA JSON lookup Installomator normally
# uses. Labels call this as getJSONValue "$json" "some.path" or
# getJSONValue "$json" "[0].some.path" (JS-style path, no leading dot needed
# for bare keys). jq requires a leading dot for both forms, so add one
# whenever the caller's path doesn't already start with one.
getJSONValue() {
    local json="$1"
    local path="$2"
    if [[ "$path" != .* ]]; then
        path=".$path"
    fi
    local value
    if ! value=$(printf '%s' "$json" | /usr/bin/jq -r "$path" 2>/dev/null); then
        # Some labels pass real JavaScript that jq can't parse, e.g.
        # .downloads.find(item => item.name.includes('X')).urls['Mac OS X'][0]
        # Fall back to evaluating it with JXA the way Installomator does.
        value=$(getJSONValueJXA "$json" "$2")
    fi
    if [[ "$value" == "null" || "$value" == "undefined" ]]; then
        value=""
    fi
    printf '%s' "$value"
}


getJSONValueJXA() { # $1 json, $2 JS-style path
    local path="$2"
    if [[ "$path" != .* && "$path" != \[* ]]; then
        path=".$path"
    fi
    printf '%s' "$1" | /usr/bin/osascript -l JavaScript \
        -e 'const data = $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile' \
        -e 'const json = $.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding).js' \
        -e "const value = JSON.parse(json)$path" \
        -e 'typeof value === "object" ? JSON.stringify(value) : String(value)' 2>/dev/null
}


# Returns success if the URL carries a signed/expiring query string (GitHub
# release-assets, S3, CloudFront, GCS, Akamai tokens, etc.). Saving one of
# these is pointless since it stops working shortly after it's generated.
isSignedURL() { # $1 url
    local query="${1#*\?}"
    [[ "$query" == "$1" ]] && return 1
    [[ "$query" =~ '(^|&|&amp;)(sig|se|skoid|jwt|token|__token__|__gda__|hdnea|Signature|Expires|Key-Pair-Id|GoogleAccessId|AuthParam|X-Amz-[A-Za-z]+|X-Goog-[A-Za-z]+)=' ]]
}


# Follow redirects one hop at a time and return the last URL before any
# signed/expiring hop, so we still resolve "latest" style links to a
# versioned URL without saving a link that will expire.
resolveStableURL() { # $1 url
    local url="$1"
    local next
    local hops=0
    while (( hops++ < 10 )); do
        # Some servers ignore the range request and send the whole file (e.g.
        # a 400+ MB dmg), so cap the size and time spent. -w still prints the
        # redirect URL when curl bails out on either limit.
        next=$(curl -A "$userAgent" -s -o /dev/null -w '%{redirect_url}' -r 0-0 --max-filesize 1048576 --max-time 15 "$url")
        [[ -z "$next" ]] && break
        isSignedURL "$next" && break
        url="$next"
    done
    echo "$url"
}


cleanupAndExit() { # $1 exit code, $2 message, $3 log level
    local code="${1:-1}"
    local message="${2:-}"
    local level="${3:-ERROR}"
    printlog "$message" "$level"
    exit "$code"
}


printlog() { # $1 message, $2 level
    local message="${1:-}"
    local level="${2:-DEBUG}"
    echo "[$label] [$level] $message" >&2
}

################################
# MAIN  MAIN  MAIN  MAIN  MAIN
################################

if [[ -z "$1" ]]; then
    echo "Label file path required"
    exit 1
fi

fullPathToLabel="$1"

# Ensure the label file exists
if [[ ! -f "$fullPathToLabel" ]]; then
    echo "Label file does not exist: $fullPathToLabel"
    exit 1
fi

# Get the label from the full path for the eval
label=$fullPathToLabel:t:r

# Surpress helper tools from running when labels are evaluated
INSTALL="force"

# Read contents of the label into variable
labelFile=$(/bin/cat "${fullPathToLabel}")

# Load all values in label into respective variables
eval 'case "$label" in '"$labelFile"'; esac' >/dev/null 2>&1

userAgent="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

# Try to resolve the final URL. Labels using downloadURLFromGit already have a
# stable github.com release URL; resolving it only yields a short-lived signed
# release-assets link, so keep it as-is.
if [[ "$labelFile" != *downloadURLFromGit* ]]; then
    downloadURL=$(resolveStableURL "$downloadURL")
fi

timeStamp=$(/bin/date -u +"%Y-%m-%dT%H:%M:%SZ")

# Labels that scrape HTTP headers (curl -I | grep location | cut ...) keep the
# header's trailing CR, e.g. appNewVersion="4.5\r". Strip it so it doesn't
# end up in the JSON values.
appNewVersion="${appNewVersion//$'\r'/}"
downloadURL="${downloadURL//$'\r'/}"

# A label whose version scrape is broken can leave multiple lines or leftover
# URL/query-string text in appNewVersion (e.g. "9.16.0" followed by a signed
# redirect URL). Blank it rather than record garbage as a real version.
if [[ "$appNewVersion" =~ $'\n|://|[?&=]' ]]; then
    printlog "appNewVersion doesn't look like a version, discarding: $appNewVersion" WARN
    appNewVersion=""
fi

# Serialize blockingProcesses array as newline-separated string so each element
# is preserved as a distinct entry (zsh "$arrayVar" collapses all elements into one scalar)
blockingProcessesSerialized="${(j:
:)blockingProcesses}"

# Build the JSON output with jq instead of osascript/JXA so this also runs
# on a GitHub Actions macOS runner without relying on JXA quirks.
json_output=$(/usr/bin/jq -n \
    --arg appName "$appName" \
    --arg appNewVersion "$appNewVersion" \
    --arg blockingProcessesSerialized "$blockingProcessesSerialized" \
    --arg downloadURL "$downloadURL" \
    --arg expectedTeamID "$expectedTeamID" \
    --arg label "$label" \
    --arg name "$name" \
    --arg timeStamp "$timeStamp" \
    --arg type "$type" \
    '{
        appName: $appName,
        appNewVersion: $appNewVersion,
        blockingProcesses: ($blockingProcessesSerialized | split("\n") | map(select(length > 0))),
        downloadURL: $downloadURL,
        expectedTeamID: $expectedTeamID,
        label: $label,
        name: $name,
        timeStamp: $timeStamp,
        type: $type
    }')

if [[ -z "$json_output" ]]; then
    echo "jq failed to build JSON output for $label" >&2
    exit 1
fi

# Output JSON. Use printf, not echo: zsh's echo interprets backslash escapes,
# which would turn jq's escaped "\r", "\n", "\\" etc. back into raw characters
# and produce invalid JSON.
printf '%s\n' "$json_output"
