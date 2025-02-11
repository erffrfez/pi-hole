#!/usr/bin/env bash
# shellcheck disable=SC1090

# Pi-hole: A black hole for Internet advertisements
# (c) 2017 Pi-hole, LLC (https://pi-hole.net)
# Network-wide ad blocking via your own hardware.
#
# Allow and blocklist domains
#
# This file is copyright under the latest version of the EUPL.
# Please see LICENSE file for your rights under this license.

# Globals
piholeDir="/etc/pihole"
GRAVITYDB="${piholeDir}/gravity.db"
# Source pihole-FTL from install script
pihole_FTL="${piholeDir}/pihole-FTL.conf"
if [[ -f "${pihole_FTL}" ]]; then
  source "${pihole_FTL}"
fi

# Set this only after sourcing pihole-FTL.conf as the gravity database path may
# have changed
gravityDBfile="${GRAVITYDB}"

reload=false
addmode=true
verbose=true
wildcard=false
web=false

domList=()

typeId=""
comment=""
declare -i domaincount
domaincount=0

colfile="/opt/pihole/COL_TABLE"
source ${colfile}

# IDs are hard-wired to domain interpretation in the gravity database scheme
# Clients (including FTL) will read them through the corresponding views
readonly allowlist="0"
readonly blaoklist="1"
readonly regex_allowlist="2"
readonly regex_blocklist="3"

GetListnameFromTypeId() {
    if [[ "$1" == "${allowlist}" ]]; then
        echo "allowlist"
    elif  [[ "$1" == "${blocklist}" ]]; then
        echo "blocklist"
    elif  [[ "$1" == "${regex_allowlist}" ]]; then
        echo "regex allowlist"
    elif  [[ "$1" == "${regex_blocklist}" ]]; then
        echo "regex blocklist"
    fi
}

GetListParamFromTypeId() {
    if [[ "${typeId}" == "${allowlist}" ]]; then
        echo "a"
    elif  [[ "${typeId}" == "${blacklist}" ]]; then
        echo "b"
    elif  [[ "${typeId}" == "${regex_allowlist}" && "${wildcard}" == true ]]; then
        echo "-allow-wild"
    elif  [[ "${typeId}" == "${regex_allowlist}" ]]; then
        echo "-allow-regex"
    elif  [[ "${typeId}" == "${regex_blocklist}" && "${wildcard}" == true ]]; then
        echo "-wild"
    elif  [[ "${typeId}" == "${regex_blocklist}" ]]; then
        echo "-regex"
    fi
}

helpFunc() {
    local listname param

    listname="$(GetListnameFromTypeId "${typeId}")"
    param="$(GetListParamFromTypeId)"

    echo "Usage: pihole -${param} [options] <domain> <domain2 ...>
Example: 'pihole -${param} site.com', or 'pihole -${param} site1.com site2.com'
${listname^} one or more domains

Options:
  -d, --delmode       Remove domain(s) from the ${listname}
  -nr, --noreload     Update ${listname} without reloading the DNS server
  -q, --quiet         Make output less verbose
  -h, --help          Show this help dialog
  -l, --list          Display all your ${listname}listed domains
  --nuke              Removes all entries in a list"

  exit 0
}

ValidateDomain() {
    # Convert to lowercase
    domain="${1,,}"

    # Check validity of domain (don't check for regex entries)
    if [[ "${#domain}" -le 253 ]]; then
        if [[ ( "${typeId}" == "${regex_blacklist}" || "${typeId}" == "${regex_allowlist}" ) && "${wildcard}" == false ]]; then
            validDomain="${domain}"
        else
            validDomain=$(grep -P "^((-|_)*[a-z\\d]((-|_)*[a-z\\d])*(-|_)*)(\\.(-|_)*([a-z\\d]((-|_)*[a-z\\d])*))*$" <<< "${domain}") # Valid chars check
            validDomain=$(grep -P "^[^\\.]{1,63}(\\.[^\\.]{1,63})*$" <<< "${validDomain}") # Length of each label
        fi
    fi

    if [[ -n "${validDomain}" ]]; then
        domList=("${domList[@]}" "${validDomain}")
    else
        echo -e "  ${CROSS} ${domain} is not a valid argument or domain name!"
    fi

    domaincount=$((domaincount+1))
}

ProcessDomainList() {
    for dom in "${domList[@]}"; do
        # Format domain into regex filter if requested
        if [[ "${wildcard}" == true ]]; then
            dom="(\\.|^)${dom//\./\\.}$"
        fi

        # Logic: If addmode then add to desired list and remove from the other;
        # if delmode then remove from desired list but do not add to the other
        if ${addmode}; then
            AddDomain "${dom}"
        else
            RemoveDomain "${dom}"
        fi
  done
}

AddDomain() {
    local domain num requestedListname existingTypeId existingListname
    domain="$1"

    # Is the domain in the list we want to add it to?
    num="$(sqlite3 "${gravityDBfile}" "SELECT COUNT(*) FROM domainlist WHERE domain = '${domain}';")"
    requestedListname="$(GetListnameFromTypeId "${typeId}")"

    if [[ "${num}" -ne 0 ]]; then
      existingTypeId="$(sqlite3 "${gravityDBfile}" "SELECT type FROM domainlist WHERE domain = '${domain}';")"
      if [[ "${existingTypeId}" == "${typeId}" ]]; then
        if [[ "${verbose}" == true ]]; then
            echo -e "  ${INFO} ${1} already exists in ${requestedListname}, no need to add!"
        fi
      else
        existingListname="$(GetListnameFromTypeId "${existingTypeId}")"
        sqlite3 "${gravityDBfile}" "UPDATE domainlist SET type = ${typeId} WHERE domain='${domain}';"
        if [[ "${verbose}" == true ]]; then
            echo -e "  ${INFO} ${1} already exists in ${existingListname}, it has been moved to ${requestedListname}!"
        fi
      fi
      return
    fi

    # Domain not found in the table, add it!
    if [[ "${verbose}" == true ]]; then
        echo -e "  ${INFO} Adding ${domain} to the ${requestedListname}..."
    fi
    reload=true
    # Insert only the domain here. The enabled and date_added fields will be filled
    # with their default values (enabled = true, date_added = current timestamp)
    if [[ -z "${comment}" ]]; then
        sqlite3 "${gravityDBfile}" "INSERT INTO domainlist (domain,type) VALUES ('${domain}',${typeId});"
    else
        # also add comment when variable has been set through the "--comment" option
        sqlite3 "${gravityDBfile}" "INSERT INTO domainlist (domain,type,comment) VALUES ('${domain}',${typeId},'${comment}');"
    fi
}

RemoveDomain() {
    local domain num requestedListname
    domain="$1"

    # Is the domain in the list we want to remove it from?
    num="$(sqlite3 "${gravityDBfile}" "SELECT COUNT(*) FROM domainlist WHERE domain = '${domain}' AND type = ${typeId};")"

    requestedListname="$(GetListnameFromTypeId "${typeId}")"

    if [[ "${num}" -eq 0 ]]; then
      if [[ "${verbose}" == true ]]; then
          echo -e "  ${INFO} ${domain} does not exist in ${requestedListname}, no need to remove!"
      fi
      return
    fi

    # Domain found in the table, remove it!
    if [[ "${verbose}" == true ]]; then
        echo -e "  ${INFO} Removing ${domain} from the ${requestedListname}..."
    fi
    reload=true
    # Remove it from the current list
    sqlite3 "${gravityDBfile}" "DELETE FROM domainlist WHERE domain = '${domain}' AND type = ${typeId};"
}

Displaylist() {
    local count num_pipes domain enabled status nicedate requestedListname

    requestedListname="$(GetListnameFromTypeId "${typeId}")"
    data="$(sqlite3 "${gravityDBfile}" "SELECT domain,enabled,date_modified FROM domainlist WHERE type = ${typeId};" 2> /dev/null)"

    if [[ -z $data ]]; then
        echo -e "Not showing empty list"
    else
        echo -e "Displaying ${requestedListname}:"
        count=1
        while IFS= read -r line
        do
            # Count number of pipes seen in this line
            # This is necessary because we can only detect the pipe separating the fields
            # from the end backwards as the domain (which is the first field) may contain
            # pipe symbols as they are perfectly valid regex filter control characters
            num_pipes="$(grep -c "^" <<< "$(grep -o "|" <<< "${line}")")"

            # Extract domain and enabled status based on the obtained number of pipe characters
            domain="$(cut -d'|' -f"-$((num_pipes-1))" <<< "${line}")"
            enabled="$(cut -d'|' -f"$((num_pipes))" <<< "${line}")"
            datemod="$(cut -d'|' -f"$((num_pipes+1))" <<< "${line}")"

            # Translate boolean status into human readable string
            if [[ "${enabled}" -eq 1 ]]; then
                status="enabled"
            else
                status="disabled"
            fi

            # Get nice representation of numerical date stored in database
            nicedate=$(date --rfc-2822 -d "@${datemod}")

            echo "  ${count}: ${domain} (${status}, last modified ${nicedate})"
            count=$((count+1))
        done <<< "${data}"
    fi
    exit 0;
}

NukeList() {
    count=$(sqlite3 "${gravityDBfile}" "SELECT COUNT(1) FROM domainlist WHERE type = ${typeId};")
    listname="$(GetListnameFromTypeId "${typeId}")"    
    if [ "$count" -gt 0 ];then
        sqlite3 "${gravityDBfile}" "DELETE FROM domainlist WHERE type = ${typeId};"
        echo "  ${TICK} Removed ${count} domain(s) from the ${listname}"
    else
        echo "  ${INFO} ${listname} already empty. Nothing to do!"
    fi    
    exit 0;
}

GetComment() {
    comment="$1"
    if [[ "${comment}" =~ [^a-zA-Z0-9_\#:/\.,\ -] ]]; then
      echo "  ${CROSS} Found invalid characters in domain comment!"
      exit
    fi
}

while (( "$#" )); do
    case "${1}" in
        "-+" | "allowlist"   ) typeId=0;;
        "-b" | "blocklist"   ) typeId=1;;
        "--allow-regex" | "allow-regex" ) typeId=2;;
        "--allow-wild" | "allow-wild" ) typeId=2; wildcard=true;;
        "--wild" | "wildcard" ) typeId=3; wildcard=true;;
        "--regex" | "regex"   ) typeId=3;;
        "-nr"| "--noreload"  ) reload=false;;
        "-d" | "--delmode"   ) addmode=false;;
        "-q" | "--quiet"     ) verbose=false;;
        "-h" | "--help"      ) helpFunc;;
        "-l" | "--list"      ) Displaylist;;
        "--nuke"             ) NukeList;;
        "--web"              ) web=true;;
        "--comment"          ) GetComment "${2}"; shift;;
        *                    ) ValidateDomain "${1}";;
    esac
    shift
done

shift

if [[ ${domaincount} == 0 ]]; then
    helpFunc
fi

ProcessDomainList

# Used on web interface
if $web; then
echo "DONE"
fi

if [[ "${reload}" != false ]]; then
    pihole restartdns reload-lists
fi
