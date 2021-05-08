#!/bin/sh

#
# update CloudFlare DNS records with current (dynamic) IP address
#    Script by Asif Bacchus <asif@bacchus.cloud>
#    Last modified: May 7, 2021
#

### text formatting presets using tput
if command -v tput >/dev/null; then
    bold=$(tput bold)
    cyan=$(tput setaf 6)
    err=$(tput bold)$(tput setaf 1)
    magenta=$(tput setaf 5)
    norm=$(tput sgr0)
    ok=$(tput setaf 2)
    warn=$(tput bold)$(tput setaf 3)
    yellow=$(tput setaf 3)
    width=$(tput cols)
else
    bold=""
    cyan=""
    err=""
    magenta=""
    norm=""
    ok=""
    warn=""
    yellow=""
    width=80
fi

### functions
badParam() {
    if [ "$1" = "null" ]; then
        printf "\n%sERROR: '%s' cannot have a NULL (empty) value.\n" "$err" "$2"
        printf "%sPlease use '--help' for assistance.%s\n\n" "$cyan" "$norm"
        exit 1
    elif [ "$1" = "dne" ]; then
        printf "\n%sERROR: '%s %s'\n" "$err" "$2" "$3"
        printf "file or directory does not exist or is empty.%s\n\n" "$norm"
        exit 1
    elif [ "$1" = "errMsg" ]; then
        printf "\n%sERROR: %s%s\n\n" "$err" "$2" "$norm"
        exit 1
    fi
}

exitError() {
    case "$1" in
    10)
        errMsg="Unable to auto-detect IP address. Try again later or supply the IP address to be used."
        ;;
    20)
        errMsg="CloudFlare authorized email address (cfEmail) is either null or undefined. Please check your CloudFlare credentials file."
        ;;
    21)
        errMsg="CloudFlare authorized API key (cfKey) is either null or undefined. Please check your CloudFlare credentials file."
        ;;
    22)
        errMsg="CloudFlare zone id (cfZoneId) is either null or undefined. Please check your CloudFlare credentials file."
        ;;
    25)
        errMsg="Unable to query CloudFlare account. Please re-check your credentials and try again later."
        ;;
    98)
        errMsg="One or more domain updates failed. Please review this log file for details."
        ;;
    *)
        printf "%s[%s] ERROR: An unspecified error occurred. Exiting.%s\n" "$err" "$(stamp)" "$norm" >>"$logFile"
        exit 99
        ;;
    esac
    printf "%s[%s] ERROR: %s (code: %s)%s\n" "$err" "$(stamp)" "$errMsg" "$1" "$norm" >>"$logFile"
    printf "%s[%s] -- CloudFlare DDNS update-script: execution completed with error(s) --%s\n" "$err" "$(stamp)" "$norm" >>"$logFile"
    exit "$1"
}

exitOK() {
    printf "%s[%s] -- CloudFlare DDNS update-script: execution complete --%s\n" "$ok" "$(stamp)" "$norm" >>"$logFile"
    exit 0
}

stamp() {
    (date +%F" "%T)
}

scriptHelp() {
    printf "\nEventually an in-script help will be here...\n\n"
    exit 0
}

### default variable values
scriptPath="$(CDPATH='' \cd -- "$(dirname -- "$0")" && pwd -P)"
scriptName="$(basename "$0")"
logFile="$scriptPath/${scriptName%.*}.log"
accountFile="$scriptPath/cloudflare.credentials"
colourizeLogFile=1
dnsRecords=""
dnsSeparator=","
ipAddress=""
ip4=1
ip6=0
ip4DetectionSvc="http://ipv4.icanhazip.com"
ip6DetectionSvc="http://ipv6.icanhazip.com"
useCFProxy="false"
invalidDomainCount=0
failedDomainCount=0

### process startup parameters
if [ -z "$1" ]; then
    scriptHelp
fi
while [ $# -gt 0 ]; do
    case "$1" in
    -h | -\? | --help)
        # display help
        scriptHelp
        ;;
    -l | --log)
        # set log file location
        if [ -n "$2" ]; then
            logFile="${2%/}"
            shift
        else
            badParam null "$@"
        fi
        ;;
    --nc | --no-color | --no-colour)
        # do not colourize log file
        colourizeLogFile=0
        ;;
    -c | --cred* | -f)
        # path to CloudFlare credentials file
        if [ -n "$2" ]; then
            if [ -f "$2" ] && [ -s "$2" ]; then
                accountFile="${2%/}"
                shift
            else
                badParam dne "$@"
            fi
        else
            badParam null "$@"
        fi
        ;;
    -r | --record | --records)
        # DNS records to update
        if [ -n "$2" ]; then
            dnsRecords=$(printf "%s" "$2" | sed -e 's/ //g')
            shift
        else
            badParam null "$@"
        fi
        ;;
    -i | --ip | --ip-address | -a | --address)
        # IP address to use (not parsed for correctness)
        if [ -n "$2" ]; then
            ipAddress="$2"
            shift
        else
            badParam null "$@"
        fi
        ;;
    -p | --proxy)
        # use CloudFlare proxy for all updated hosts
        useCFProxy="true"
        ;;
    -4 | --ip4 | --ipv4)
        # operate in IP4 mode (default)
        ip4=1
        ip6=0
        ;;
    -6 | --ip6 | --ipv6)
        # operate in IP6 mode
        ip6=1
        ip4=0
        ;;
    *)
        printf "\n%sUnknown option: %s\n" "$err" "$1"
        printf "%sUse '--help' for valid options.%s\n\n" "$cyan" "$norm"
        exit 1
        ;;
    esac
    shift
done

### pre-flight checks
if ! command -v curl >/dev/null; then
    printf "\n%sThis script requires 'curl' be installed and accessible. Exiting.%s\n\n" "$err" "$norm"
    exit 2
fi
if ! command -v jq >/dev/null; then
    printf "\n%sThis script requires 'jq' be installed and accessible. Exiting.%s\n\n" "$err" "$norm"
    exit 2
fi
[ -z "$dnsRecords" ] && badParam errMsg "You must specify at least one DNS record to update. Exiting."
# turn off log file colourization if parameter is set
if [ "$colourizeLogFile" -eq 0 ]; then
    bold=""
    cyan=""
    err=""
    magenta=""
    norm=""
    ok=""
    warn=""
    yellow=""
fi

### initial log entries
{
    printf "%s[%s] -- CloudFlare DDNS update-script: execution starting --%s\n" "$ok" "$(stamp)" "$norm"
    printf "%sParameters:\n" "$magenta"
    printf "script path: %s\n" "$scriptPath/$scriptName"
    printf "credentials file: %s\n" "$accountFile"
} >>"$logFile"

if [ "$ip4" -eq 1 ]; then
    printf "mode: IP4\n" >>"$logFile"
elif [ "$ip6" -eq 1 ]; then
    printf "mode: IP6\n" >>"$logFile"
fi

# detect and report IP address
if [ -z "$ipAddress" ]; then
    # detect public ip address
    if [ "$ip4" -eq 1 ]; then
        if ! ipAddress="$(curl -s $ip4DetectionSvc)"; then
            printf "ddns ip address: %serror%s\n" "$err" "$norm" >>"$logFile"
            exitError 10
        fi
    fi
    if [ "$ip6" -eq 1 ]; then
        if ! ipAddress="$(curl -s $ip6DetectionSvc)"; then
            printf "ddns ip address: %serror%s\n" "$err" "$norm" >>"$logFile"
            exitError 10
        fi
    fi
    printf "ddns ip address (detected): %s\n" "$ipAddress" >>"$logFile"
else
    printf "ddns ip address (supplied): %s\n" "$ipAddress" >>"$logFile"
fi

# iterate DNS records to update
dnsRecordsToUpdate="$dnsRecords$dnsSeparator"
while [ "$dnsRecordsToUpdate" != "${dnsRecordsToUpdate#*${dnsSeparator}}" ] && { [ -n "${dnsRecordsToUpdate%%${dnsSeparator}*}" ] || [ -n "${dnsRecordsToUpdate#*${dnsSeparator}}" ]; }; do
    record="${dnsRecordsToUpdate%%${dnsSeparator}*}"
    dnsRecordsToUpdate="${dnsRecordsToUpdate#*${dnsSeparator}}"
    printf "updating record: %s\n" "$record" >>"$logFile"
done

printf "(end of parameter list)%s\n" "$norm" >>"$logFile"

### read CloudFlare credentials
printf "[%s] Reading CloudFlare credentials... " "$(stamp)" >>"$logFile"
case "$accountFile" in
/*)
    # absolute path, use as-is
    # shellcheck source=./cloudflare.credentials
    . "$accountFile"
    ;;
*)
    # relative path, rewrite
    # shellcheck source=./cloudflare.credentials
    . "./$accountFile"
    ;;
esac
if [ -z "$cfEmail" ]; then
    printf "%sERROR%s\n" "$err" "$norm" >>"$logFile"
    exitError 20
elif [ -z "$cfKey" ]; then
    printf "%sERROR%s\n" "$err" "$norm" >>"$logFile"
    exitError 21
elif [ -z "$cfZoneId" ]; then
    printf "%sERROR%s\n" "$err" "$norm" >>"$logFile"
    exitError 22
fi
printf "DONE%s\n" "$norm" >>"$logFile"

### check if records to be updated exist and if they need updating, update as required
dnsRecordsToUpdate="$dnsRecords$dnsSeparator"
if [ "$ip4" -eq 1 ]; then
    recordType="A"
elif [ "$ip6" -eq 1 ]; then
    recordType="AAAA"
fi
while [ "$dnsRecordsToUpdate" != "${dnsRecordsToUpdate#*${dnsSeparator}}" ] && { [ -n "${dnsRecordsToUpdate%%${dnsSeparator}*}" ] || [ -n "${dnsRecordsToUpdate#*${dnsSeparator}}" ]; }; do
    record="${dnsRecordsToUpdate%%${dnsSeparator}*}"
    dnsRecordsToUpdate="${dnsRecordsToUpdate#*${dnsSeparator}}"
    printf "[%s] Processing %s... " "$(stamp)" "$record" >>"$logFile"
    # check for existing record, else exit with error (this script does NOT create new records, only updates them!)
    if ! cfResult="$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${cfZoneId}/dns_records?name=${record}&type=${recordType}" \
        -H "Authorization: Bearer ${cfKey}" \
        -H "Content-Type: application/json")"; then
        printf "%sERROR%s\n" "$err" "$norm" >>"$logFile"
        exitError 25
    fi
    resultCount="$(printf "%s" "$cfResult" | jq '.result_info.count')"
    if [ "$resultCount" = "0" ]; then
        printf "%sNOT FOUND%s\n" "$warn" "$norm" >>"$logFile"
        printf "%s[%s] WARNING: Cannot find existing record to update for DNS entry: %s%s\n" "$warn" "$(stamp)" "$record" "$norm" >>"$logFile"
        invalidDomainCount=$((invalidDomainCount + 1))
    else
        objectId=$(printf "%s" "$cfResult" | jq -r '.result | .[] | .id')
        currentIpAddr=$(printf "%s" "$cfResult" | jq -r '.result | .[] | .content')
        printf "FOUND: IP = %s\n" "$currentIpAddr" >>"$logFile"
        # check if record needs updating
        if [ "$currentIpAddr" = "$ipAddress" ]; then
            printf "%s[%s] IP address for %s is already up-to-date%s\n" "$ok" "$(stamp)" "$record" "$norm" >>"$logFile"
        else
            # update record
            printf "%s[%s] Updating IP address for %s... " "$cyan" "$(stamp)" "$record" >>"$logFile"
            if [ "$ip4" -eq 1 ]; then
                updateJSON="$(jq -n \
                    --arg key0 type --arg value0 A \
                    --arg key1 name --arg value1 "${record}" \
                    --arg key2 content --arg value2 "${ipAddress}" \
                    --arg key3 ttl --arg value3 1 \
                    --arg key4 proxied --arg value4 "${useCFProxy}" \
                    '{($key0):$value0,($key1):$value1,($key2):$value2,($key3):$value3,($key4):$value4}')"
            elif [ "$ip6" -eq 1 ]; then
                updateJSON="$(jq -n \
                    --arg key0 type --arg value0 AAAA \
                    --arg key1 name --arg value1 "${record}" \
                    --arg key2 content --arg value2 "${ipAddress}" \
                    --arg key3 ttl --arg value3 1 \
                    --arg key4 proxied --arg value4 "${useCFProxy}" \
                    '{($key0):$value0,($key1):$value1,($key2):$value2,($key3):$value3,($key4):$value4}')"
            fi
            if ! cfResult="$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${cfZoneId}/dns_records/${objectId}" \
                -H "Authorization: Bearer ${cfKey}" \
                -H "Content-Type: application/json" \
                --data "${updateJSON}")"; then
                printf "%sERROR%s\n" "$err" "$norm" >>"$logFile"
                exitError 25
            fi
            updateSuccess="$(printf "%s" "$cfResult" | jq '.success')"
            if [ "$updateSuccess" = "true" ]; then
                printf "DONE%s\n" "$norm" >>"$logFile"
                printf "%s[%s] SUCCESS: IP address for %s updated%s\n" "$ok" "$(stamp)" "$record" "$norm" >>"$logFile"
            else
                printf "%sFAILED%s\n" "$err" "$norm" >>"$logFile"
                printf "%s[%s] ERROR: Unable to update IP address for %s%s\n" "$err" "$(stamp)" "$record" "$norm" >>"$logFile"
                failedDomainCount=$((failedDomainCount + 1))
            fi
        fi
    fi
done

# exit
if [ "$invalidDomainCount" -ne 0 ]; then
    printf "%s[%s] -- WARNING: %s invalid domain(s) were supplied for updating --%s\n" "$warn" "$(stamp)" "$invalidDomainCount" "$norm" >>"$logFile"
fi
if [ "$failedDomainCount" -ne 0 ]; then
    exitError 98
else
    exitOK
fi

### exit return codes
# 0:    normal exit, no errors
# 1:    invalid or unknown parameter
# 2:    cannot find or access required external program(s)
# 10:   cannot auto-detect IP address
# 20:   accountFile has a null or missing cfEmail variable
# 21:   accountFile has a null or missing cfKey variable
# 22:   accountFile has a null or missing cfZoneId variable
# 25:   unable to query CloudFlare account
# 97:   script completed with warnings
# 98:   one or more updates failed
# 99:   unspecified error occurred
