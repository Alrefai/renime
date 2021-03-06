#!/usr/bin/env bash

set -o pipefail

BASE_DIR="${BASE_DIR:-.}"

# Font styling and colors
boldText=$'\e[1m'
redBoldText=$'\e[1;31m'
blueText=$'\e[34m'
redUnderlinedText=$'\e[4;31m'
reset=$'\e[0m'

# shellcheck disable=SC2034
FZF_DEFAULT_OPTS="
  --bind J:down,K:up,ctrl-a:select-all,ctrl-d:deselect-all,ctrl-t:toggle-all \
  --reverse \
  --ansi \
  --no-multi \
  --height 20% \
  --min-height 15 \
  --border \
  --select-1"

assertTask() {
  echo -e "${blueText}==>${reset} ${boldText}$*${reset}"
}

assertMissing() {
  missingMark="${redBoldText}\u2718${reset}"
  echo -e "${missingMark} ${boldText}$1${reset}" "${@:2}"
}

assertError() {
  echo -n "${redUnderlinedText}Error${reset}: " >&2

  if [[ $# == 0 ]]; then
    echo 'Something wrong happened!' >&2
  else
    echo "$*" >&2
  fi
}

trimWhiteSpace() {
  echo -e "$1" | grep "\S" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

assertSelection() {
  trimWhiteSpace "$1" | fzf "${@:2}"
}

safeFilename() {
  local regEx='
    s/^\W+|(?!
    (?:COM[0-9]|CON|LPT[0-9]|NUL|PRN|AUX|com[0-9]|con|lpt[0-9]|nul|prn|aux)
    |[\s\.])
    [\/:*\"?<>|~\\\\;]{1,254}/_/g
  '
  perl -pe "${regEx//[[:space:]]/}"
}

sanitizeFileName() {
  local ext=${1##*.}
  local fileName=${1%.*}
  sed -E 's/\[[^][]*\]//g;s/[Ss][0-9]{1,2}//;s/_|\./ /g' <<<"${fileName}" |
    safeFilename |
    sed 's/^_//' |
    awk -v ext=".${ext}" '{print $0ext}'
}

formatFileName() {
  local fileName=$1
  local seriesName=$2
  local seasonFormat=$3
  local regEx='(.*) -? *(?:[Ee][Pp]?|\d{1,2}[Xx])?(\d+(-\d+){0,2}) *'

  #! Don't replace `perl` with `sed`
  #* `sed` fails to match regex pattern in filenames that includes `&`!
  sanitizeFileName "${fileName}" |
    perl -pe "s/${regEx}/${seriesName:-\1} - ${seasonFormat}E\2/" |
    sed 's/  / /g;s/ - -/ -/'
}

initialFileRename() {
  local fileName=$1
  local seriesName=$2
  local seasonFormat=$3
  local fileExt=$4
  local increment=$5

  local newFileName
  newFileName=$(formatFileName "${fileName}" "${seriesName}" "${seasonFormat}")

  local epNumber
  epNumber=$(
    grep -oE 'E\d+(-\d+){0,2}' <<<"${newFileName}" |
      perl -pe 's/([0-9]+)/($1+'"${increment:-0}"')/ge'
  )

  echo "${newFileName/E[0-9]*/${epNumber}.${fileExt:-${newFileName##*.}}}"
}

validateOptionValue() {
  if [[ $2 =~ ^'-' ]]; then
    assertError 'Invalid value' "'$2'" 'for option' "'$1'." \
      'Do not use a value that begins with' "'-'."
    exit 1
  fi
}

while [[ -n $1 ]]; do
  case $1 in
  --series)
    validateOptionValue "$1" "$2"
    series=$(safeFilename <<<"$2" | sed 's/^_//')
    shift
    ;;

  --season)
    validateOptionValue "$1" "$2"

    if [[ ! $2 =~ ^[0-9]{1,2}$ ]]; then
      assertError 'Invalid season number.' \
        'Season number must be an integer of single digit or double digits.'
      exit 1
    fi

    season=$2
    shift
    ;;

  --no-season)
    season=''
    ;;

  --keep-season)
    season='keep'
    ;;

  --extension)
    validateOptionValue "$1" "$2"
    extension=$2
    shift
    ;;

  --increment-by)
    validateOptionValue "$1" "$2"
    incrementBy=$2
    shift
    ;;

  --skip-init)
    skipInitial=true
    ;;

  --skip-tvnamer)
    skipTvNamer=true
    ;;

  --dirname)
    validateOptionValue "$1" "$2"

    if [[ ! -d $2 ]]; then
      assertError 'Directory does not exist:' "$2"
      exit 1
    fi

    BASE_DIR=$2
    shift
    ;;

  --)
    [[ ${skipTvNamer} ]] && skipTvNamer=false
    args=("${@:2}")
    shift
    break
    ;;

  -*)
    assertError 'Unhandled option:' "$1"
    exit 1
    ;;

  *)
    if [[ ${term} ]]; then
      assertError 'Put search terms inside single or double quotes.'
      exit 1
    fi

    term=$1
    ;;
  esac
  shift
done

if [[ ${term} ]]; then
  assertTask 'Search term:' "${term}"
else
  assertTask 'Awaiting user selection...'
fi

foundFiles=$(find -s . -maxdepth 1 -iname "*${term}*" -type f)

if [[ -z ${foundFiles} ]]; then
  assertError 'No files found.'
  exit 1
fi

selectedFiles=$(fzf -m --with-nth 2 --delimiter '/' <<<"${foundFiles}")
[[ ${selectedFiles} ]] || exit 1

renamedFiles=$(mktemp -t renimeXXXX)

if [[ ${skipInitial} != true ]]; then
  formatSeason() {
    local file=$1

    if [[ ${season} && ${season} != 'keep' ]]; then
      echo "S${season}"
    elif [[ ${season} == 'keep' ]]; then
      grep -oE '[Ss][0-9]{1,2}' <<<"${file}" || echo 'S1'
    elif [[ -z ${season} && ${season+set} ]]; then
      echo ''
    else
      echo 'S1'
    fi
  }

  while IFS= read -r file; do
    seasonFormat=$(formatSeason "${file}")

    newFile=$(
      initialFileRename \
        "${file}" "${series}" "${seasonFormat^}" "${extension}" "${incrementBy}"
    )

    echo "${file#.\/} -> ${newFile}"
  done <<<"${selectedFiles}"

  confirmRename=$(
    assertSelection "
      Confirm rename...
      Yes
      No
    " --header-lines 1
  )

  if [[ ${confirmRename} != 'Yes' ]]; then
    assertError 'Aborted by user'
    exit 1
  fi

  while IFS= read -r file; do
    seasonFormat=$(formatSeason "${file}")

    newFile=$(
      initialFileRename \
        "${file}" "${series}" "${seasonFormat^}" "${extension}" "${incrementBy}"
    )

    echo "${newFile}" >>"${renamedFiles}"
    mv -- "${file}" "${newFile}" 2>/dev/null
  done <<<"${selectedFiles}"
else
  echo "${selectedFiles}" | tee "${renamedFiles}"
fi

[[ -s ${renamedFiles} && ${skipTvNamer} != true ]] || exit
echo
assertTask 'Processing files with tvnamer...'

while IFS= read -r file; do
  tvRenamed=$(
    tvnamer --not-batch --dry-run --selectfirst --move \
      --movedestination "${BASE_DIR}/%(seriesname)s" "${args[@]}" "${file}" |
      grep -E 'Old filename|New filename|moved to' |
      sed '$!d'
  ) || exit 1

  tvRenamedFile=$(awk -F ' will be moved to ' 'END{print $1}' <<<"${tvRenamed}")
  tvRenamedDir=$(awk -F ' will be moved to ' 'END{print $2}' <<<"${tvRenamed}")
  echo "${file} -> ${tvRenamedDir}/${tvRenamedFile}"
done <"${renamedFiles}"

confirmTvRename=$(
  assertSelection '
    Confirm TVrename
    Yes
    No
  ' --header-lines 1
)

if [[ ${confirmTvRename} != 'Yes' ]]; then
  assertError 'Aborted by user'
  exit 1
fi

echo
while IFS= read -r file; do
  tvnamer --batch --move --movedestination "${BASE_DIR}/%(seriesname)s" \
    "${args[@]}" "${file}"
done <"${renamedFiles}"

exit
