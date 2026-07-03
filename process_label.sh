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
    value=$(printf '%s' "$json" | /usr/bin/jq -r "$path" 2>/dev/null)
    if [[ "$value" == "null" ]]; then
        value=""
    fi
    printf '%s' "$value"
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

# Try to resolve the final URL
downloadURL=$(curl -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15" -sL -o /dev/null -w '%{url_effective}' -r 0-0 "$downloadURL")

timeStamp=$(/bin/date -u +"%Y-%m-%dT%H:%M:%SZ")

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

# Output JSON
echo "$json_output"
