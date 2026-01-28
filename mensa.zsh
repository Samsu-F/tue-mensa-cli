# shellcheck disable=SC2148 # unknown shell warning
# shellcheck disable=SC2296 # works in zsh

# Written by Samsu-F.
# https://github.com/Samsu-F/tue-mensa-cli


# Usage:
# `mensa [regex filters [...]]`
# Outputs all dishes that match all filters.
# - Filters are regular expressions matched against the concatenation of all fields (`|` as separator).
# - Filters are case-insensitive by default.
# - If a filter contains at least one uppercase character, it becomes case-sensitive.
# - By default, filters are treated as positive (inclusive) filters, meaning that only dishes that
#   match the regular expression are kept.
# - A filter starting with a minus (`-`) is treated as a negative (exclusive) filter. The leading minus is
#   removed, and only dishes that do *not* match the remaining regular expression are kept.
#   To use a *positive* filter whose regular expression itself begins with a literal minus, escape the minus
#   using a backslash (for example: `'\-foo'`).
# Examples:
# - `mensa` will show the full meal plan.
# - `mensa vegan 3,70` will show all vegan dishes that cost 3,70€.
# - `mensa '-\[[^\]]*S.*\]' salat` will show all meals that are not tagged as containing pork, and also include any type of salad.

# Installation:
# Save this file anywhere and just source it in your ~/.zshrc like this:
# ```
# source /path/to/mensa.zsh
# ```
# Then restart your shell or run `source ~/.zshrc`.

# Dependencies:
#   - jtbl (https://github.com/kellyjonbrazil/jtbl)
#   - jq (may be preinstalled on your system) (https://github.com/jqlang/jq)
#   - curl
#   - coreutils




############################################## CONFIG ##############################################

# the language to fetch the menu in. The stuwe website only provides de and en.
mensa_lang=de

# the color in which you want your favourite dishes highlighted:
mensa_highlight_color_good="22;1;32" # 22 = bold off & faint off; 1 = bold; 32 = green
# the color in which you want your bad dishes highlighted:
mensa_highlight_color_bad="22;91" # 91 = intense red
# the color of the grid:
mensa_highlight_color_grid="22;2;37" # 2 = faint; 37 = white (==> gray)
# the color in which you want todays dishes highlighted:
mensa_highlight_color_today="22;97"  # 97 = intense white
# the neutral text color:
mensa_base_color="22;39" # 39 = default text color of your terminal

# regex patterns you want to highlight as dishes you know you like.
# WARNING: literal forward slashes must be escaped!
mensa_patterns_good=(
    'Hack.?([Bb]äll[a-z]+|[Rr]olle)'    # matches 'Hackbällchen', 'Hack-Bälle', 'Hack Rolle', ...
    '([Ff]rikadelle.*[Vv]egan\]?)|([Vv]egan.*[Ff]rikadelle)'
    '([Tt]s|[Tt]z|[Zz])a(ts|tz|z)iki'   # Tzatziki in all spellings imaginable
    '[A-Za-z]*[Dd]ip\b'                 # controversial, I know
    '((Soja.)?|[A-Za-z]*)[Gg]yros'      # 'Soja-Gyros', 'Pfannengyros', ...
    '\[[Tt]op\]'
    '[Rr]ote.?[Bb]ete.?[Pp]uffer'
)

# regex patterns you want to highlight as dishes you know you dislike:
# WARNING: literal forward slashes must be escaped!
mensa_patterns_bad=(
    'Sesam.?[Kk]arotten.?[Ss]tick'
    '[A-Za-z\-]*[Kk]nusperbagel'
    '\[[SRFGLKW\/]+\]'                  # tags for all kinds of meat
    '[Vv]eget(ari[A-Za-z]+)?\b'
)

alias mensa_pager='more -f' # Leave empty or use 'cat' if you don't want to use a pager.
                            # Evaluated at runtime.

mensa_date_format_string='%a %d.%m.' # see `man strftime` for a list of specifiers

mensa_curry_to_haskell_easteregg=true

# Makes the heading of each table a clickable link. Disable if your terminal does not support this.
mensa_clickable_links=true

mensa_cache_time_to_live='1800' # time in seconds that cached results are valid for

# Columns to display from the menu data. Only listed columns are shown and used for argument
# filtering. Comment out to hide a column or reorder lines to change the display order.
# Columns can be renamed using the syntax '"newName":.oldName'.
# Set this to an empty array to show all columns.
mensa_columns=(
    # id
    menuLine
    '"price":.studentPrice'
    # guestPrice
    # pupilPrice
    '"date":.menuDate'
    menu
    # meats
    # icons
    # filtersInclude
    #  allergens        # ⚠️ WARNING: Allergen and additive info shown here is only a preview.
                        # Only the daily labels at the Mensa (on-site monitors or notices) are
                        # official, and even those are not always reliable.
    # longAllergens
    # additives
    # longAdditives
    co2
)

# Samsu's recommendation:
# alias m='mensa vegan'

####################################################################################################





# Temporarily change options.
'builtin' 'local' '-a' 'mensa_zsh_options'
[[ -o 'unset'           ]] && mensa_zsh_options+=('unset')
[[ -o 'no_brace_expand' ]] && mensa_zsh_options+=('no_brace_expand')
[[ -o 'aliases'         ]] && mensa_zsh_options+=('aliases')
'builtin' 'setopt' 'no_aliases' 'no_unset' 'brace_expand'


# shellcheck disable=SC1073,SC1072
() {
    emulate -L zsh


    if [ -z "$ZSH_VERSION" ]; then
        # You may be able to port it to bash or even sh if you really want, but it will certainly
        # not work out of the box.
        printf "\033[1;31mtue-mensa-cli: Error: tue-mensa-cli must be sourced in zsh.\033[0m\n" >&2
        return 1
    fi

    local cmd
    for cmd in jq jtbl curl grep sed awk openssl; do
        if ! command -pv "${cmd}" &>/dev/null; then
            printf "\033[1;31mtue-mensa-cli: Error: missing dependency '%s'.\033[0m\n" "${cmd}" >&2
            return 1
        fi
    done

    # _mensa_file_mtime: a function to get the modification timestamp of a file
    case "$(uname)" in
        Linux)
            function _mensa_file_mtime() { stat -c %Y "$1"; }
            function _mensa_date_tomorrow() { date --date=tomorrow '+%Y-%m-%d'; }
            ;;
        Darwin|FreeBSD|OpenBSD|NetBSD|DragonFly)
            function _mensa_file_mtime() { stat -f %m "$1"; }
            function _mensa_date_tomorrow() { date -v+1d '+%Y-%m-%d'; }
            ;;
        *)
            printf "\033[1;33mtue-mensa-cli: Warning: Unexpected OS '%s'. Defaulting to assuming GNU coreutils are available.\033[0m\n" "$(uname)" >&2
            function _mensa_file_mtime() { stat -c %Y "$1"; }
            function _mensa_date_tomorrow() { date --date=tomorrow '+%Y-%m-%d'; }
            ;;
    esac



    function mensa()
    {
        emulate -L zsh; setopt localoptions no_unset no_monitor # for reliability independent of which options are set
        local filters mensa_date file_suffix file_final_tables mensa_dir filters_concatenated heading_morgenstelle heading_wilhelmstrasse
        filters=("$@")

        # By setting a path here, you grant this function absolute freedom to create, edit, and delete any file in this directory and the directory itself.
        # ==> Do not set it to a directory shared with any other application or a directory containing files you wish to keep.
        mensa_dir='/tmp/tue-mensa-cli'
        mkdir -p "${mensa_dir}"

        mensa_date="$(date '+%Y-%m-%d')"
        if [ "$(date '+%H%M')" -gt "1400" ]; then mensa_date="$(_mensa_date_tomorrow)"; fi

        file_final_tables="${mensa_dir}/final_tables_$(_mensa_generate_file_suffix "${filters[@]}" "${mensa_date}")"
        local file_morgenstelle="${mensa_dir}/morgenstelle_${mensa_lang}.json"
        local file_wilhelmstrasse="${mensa_dir}/wilhelmstrasse_${mensa_lang}.json"

        # if the final file or the json files it is based on do not exist or exceeded time to live
        if [ ! -f "${file_final_tables}" ] || [ "$(($(date '+%s') - $(_mensa_file_mtime "${file_final_tables}") ))" -gt "${mensa_cache_time_to_live}" ] \
        || [ ! -f "${file_morgenstelle}" ] || [ "$(($(date '+%s') - $(_mensa_file_mtime "${file_morgenstelle}") ))" -gt "${mensa_cache_time_to_live}" ]; then
            local curl_pid_ms curl_pid_ws curl_success=1
            # only use curl if needed (if json files do not exist or are no longer valid)
            if [ ! -f "${file_morgenstelle}" ] || [ "$(($(date '+%s') - $(_mensa_file_mtime "${file_morgenstelle}") ))" -gt "${mensa_cache_time_to_live}" ]; then
                curl -sf "http://www.my-stuwe.de/wp-json/mealplans/v1/canteens/621?lang=${mensa_lang}" > "${file_morgenstelle}_curl.tmp"   & curl_pid_ms=$!
                curl -sf "http://www.my-stuwe.de/wp-json/mealplans/v1/canteens/611?lang=${mensa_lang}" > "${file_wilhelmstrasse}_curl.tmp" & curl_pid_ws=$!
                wait $curl_pid_ms || curl_success=0
                wait $curl_pid_ws || curl_success=0
                if (( $curl_success )); then
                    mv "${file_morgenstelle}_curl.tmp" "${file_morgenstelle}"
                    mv "${file_wilhelmstrasse}_curl.tmp" "${file_wilhelmstrasse}"
                    # It is an intentional choice to not use a variable containing the filename prefix in the following glob, to ensure we
                    # never run 'rm /*' or something similarly bad, even if something went wrong and the variables contain the empty string.
                    local -a mensa_invalid_cache_files=( "${mensa_dir}/final_tables_"*(N) )
                    (( ${#mensa_invalid_cache_files} )) && rm --one-file-system "${mensa_invalid_cache_files[@]}"
                else
                    rm "${file_morgenstelle}_curl.tmp" "${file_wilhelmstrasse}_curl.tmp"
                fi
            fi

            if [ ! -f "${file_morgenstelle}" ]; then
                printf 'curl failed and there is noch cached data :(\nPlease check your internet connection.\n' >&2
                return 1
            fi
            {
                _mensa_json_to_table "621" "${mensa_date}" "${filters[@]}" <"${file_morgenstelle}"   >"${file_morgenstelle}.tmp" &
                _mensa_json_to_table "611" "${mensa_date}" "${filters[@]}" <"${file_wilhelmstrasse}" >"${file_wilhelmstrasse}.tmp" &
                wait

                if [ "${mensa_clickable_links}" = "true" ]; then
                    heading_morgenstelle="\033[1m\033]8;;https://www.my-stuwe.de/mensa/mensa-morgenstelle-tuebingen/\033\\\\Morgenstelle\033]8;;\033\\\\\033[0m"
                    heading_wilhelmstrasse="\033[1m\033]8;;https://www.my-stuwe.de/mensa/mensa-wilhelmstrasse-tuebingen/\033\\\\Wilhelmstraße\033]8;;\033\\\\\033[0m"
                else
                    heading_morgenstelle="\033[1mMorgenstelle\033[0m"
                    heading_wilhelmstrasse="\033[1mWilhelmstraße\033[0m"
                fi
                (( ! $curl_success )) && printf \
                    ' \033[1;33mWarning: Unable to retrieve new data. Using cached data past its expiration time (last updated %s).\033[0m\n' \
                    "$(_mensa_ago_string "$(_mensa_file_mtime "${file_morgenstelle}")")"
                print " ${heading_morgenstelle}"
                cat "${file_morgenstelle}.tmp"
                print "\n ${heading_wilhelmstrasse}"
                cat "${file_wilhelmstrasse}.tmp"
                rm "${file_morgenstelle}.tmp" "${file_wilhelmstrasse}.tmp"
            } | _mensa_display "${mensa_date}" > "${file_final_tables}"
        fi

        cat "${file_final_tables}" | eval "${aliases[mensa_pager]:-cat}" # alias for an optional pager or cat
    }



    # generates a hash based on everything that affects the final tables, to be used like a unique id in the cache
    function _mensa_generate_file_suffix() {
        local values=("$@")
        local unit_sep="$(printf '\037')"
        local record_sep="$(printf '\036')"
        values+=(   # add everything that affects the content of the final table file
            "$(tput cols)"
            "${mensa_lang}"
            "${mensa_highlight_color_good}"
            "${mensa_highlight_color_bad}"
            "${mensa_highlight_color_grid}"
            "${mensa_highlight_color_today}"
            "${mensa_base_color}"
            "${mensa_date_format_string}"
            "${mensa_curry_to_haskell_easteregg}"
            "${mensa_clickable_links}"
            # use a Record Separator ASCII character to mark border between arrays
            "${record_sep}${mensa_patterns_good[@]}"
            "${record_sep}${mensa_patterns_bad[@]}"
            "${record_sep}${mensa_columns[@]}"
        )
        local values_concatenated=''
        local val
        for val in "${values[@]}"; do
            values_concatenated+="${unit_sep}${val}"
        done
        printf '%s' "${values_concatenated}" | openssl dgst -sha256 | awk '{print $NF}'
    }



    function _mensa_json_to_table()
    {
        local mensa_id="$1"
        local mensa_date="$2"
        shift 2
        local filters=("$@")
        local jq_filters=""
        local fil
        for fil in "${filters[@]}"; do
            fil="$(printf '%s' "${fil}" | sed -E 's/\\|"/\\&/g')" # jq needs escaped backslashes
            local optional_not=''
            if [[ "${fil:0:1}" == "-" ]]; then
                fil="${fil:1}" # Remove the first character (the minus)
                optional_not='| not'
            fi
            local optional_downcase='| ascii_downcase'   # default: case insensitive filtering
            if printf '%s\n' "${fil}" | grep -qE '[[:upper:]]'; then
                optional_downcase='' # case sensitive regex if filter contains uppercase characters
            fi
            jq_filters+=" | select([.. | scalars | tostring] | join(\"|\") ${optional_downcase} | test(\"${fil}\") ${optional_not}) "
        done

        local jq_column_selection="| { ${(j:, :)mensa_columns} }"
        if [[ ${#mensa_columns[@]} -eq 0 ]]; then jq_column_selection=""; fi # show every column if mensa_columns is empty

        jq -r "$(_mensa_jq_lookup_tables_def)"'
                def excluded_menulines: [
                    "Salad bar / vegetable buffet (price per 100g)",
                    "Side dishes",
                    "Side dishes (self-service)",
                    "Desserts",
                    "Desserts (self-service)",
                    "Salat-/ Gemüsebuffet 100g",
                    "Beilagen vorport.",
                    "Beilagen SB",
                    "Dessert vorport.",
                    "Dessert SB"
                ];
                '"
                [ .\"${mensa_id}\".menus[]
                    | del(.photo)
                    | select(.menuDate >= \"${mensa_date}\")
                    | select(.menuLine | IN(excluded_menulines[]) | not)
                    | .menu=(.menu | join(\", \"))
                    | .icons=(.icons | join(\", \"))
                    | .filtersInclude=(.filtersInclude | join(\", \"))
                    | .meats=(.meats | join(\", \"))
                    | .longAllergens = (.allergens | map(allergen_map[.] // .) | join(\", \"))
                    | .allergens=(.allergens | join(\", \"))
                    | .longAdditives = (.additives | map(additives_map[.] // .) | join(\", \"))
                    | .additives=(.additives | join(\", \"))
                    | .studentPrice += (if (.studentPrice | contains(\",\")) then \" €\" else \"\" end)
                    | .guestPrice   += (if (.guestPrice   | contains(\",\")) then \" €\" else \"\" end)
                    | .pupilPrice   += (if (.pupilPrice   | contains(\",\")) then \" €\" else \"\" end)

                ]
                | sort_by(.menuDate)
                |
                [ .[]
                    | .menuDate |= (strptime(\"%Y-%m-%d\") | strftime(\"${mensa_date_format_string}\"))
                    ${jq_column_selection}
                    ${jq_filters}
                ]" \
            | if [ "${mensa_curry_to_haskell_easteregg}" = "true" ]; then sed 's/curry/haskell/g' | sed 's/Curry/Haskell/g'; else cat - ; fi \
            | jtbl -f --cols="$(tput cols)"
    }



    function _mensa_jq_lookup_tables_def() {
        local lang="${mensa_lang}"
        if [[ "${lang}" != 'de' && "${lang}" != 'en' ]]; then
            printf "Warning: invalid value '%s' for variable mensa_lang, please set it to either 'de' or 'en'.\n" "${mensa_lang}" >&2
            if printf '%s\n' "${LC_ALL:-} ${LANG:-} ${LANGUAGE:-}" | grep -qE '(\b|:|_)de(\b|:|_)'; then
                lang=de
            else
                lang=en
            fi
        fi
        if  [[ "${lang}" == 'de' ]]; then
            printf '%s' \
                'def allergen_map: {
                    "Ei":   "Ei",
                    "Er":   "Erdnüsse",
                    "Fi":   "Fisch",
                    "Gl-a": "Gluten (Weizen)",
                    "Gl-b": "Gluten (Roggen)",
                    "Gl-c": "Gluten (Gerste)",
                    "Gl-d": "Gluten (Hafer)",
                    "Gl-e": "Gluten (Dinkel)",
                    "Gl-f": "Gluten (Kamut)",
                    "Gl":   "Gluten",
                    "Kr":   "Krebstiere",
                    "Lu":   "Lupine",
                    "ML":   "Milch / Laktose",
                    "Mu":   "Weichtiere",
                    "Nu-a": "Mandeln",
                    "Nu-b": "Haselnüsse",
                    "Nu-c": "Walnüsse",
                    "Nu-d": "Cashewkerne",
                    "Nu-e": "Pekannüsse",
                    "Nu-f": "Paranüsse",
                    "Nu-g": "Pistazien",
                    "Nu-h": "Macadamianüsse",
                    "Nu-i": "Queenslandnüsse",
                    "Nu":   "Schalenfrüchte (Nüsse)",
                    "Sa":   "Sesam",
                    "Se":   "Sellerie",
                    "Sf":   "Schwefeldioxid / Sulfite",
                    "Sl":   "Sesam",
                    "Sn":   "Senf",
                    "So":   "Soja",
                    "We":   "Weichtiere",
                };
                def additives_map: {
                    "1":  "Farbstoff",
                    "2":  "Konservierungsstoff",
                    "3":  "Nitritpökelsalz",
                    "4":  "Antioxidationsmittel",
                    "5":  "Geschmacksverstärker",
                    "6":  "geschwefelt",
                    "7":  "geschwärzt",
                    "8":  "gewachst",
                    "9":  "Süßungsmittel",
                    "10": "enthält eine Phenylalaninquelle",
                    "11": "Phosphat",
                };'
            return 0
        fi
        if [[ "${lang}" == 'en' ]]; then
            printf '%s' \
                'def allergen_map: {
                    "Ei":   "egg",
                    "Er":   "peanuts",
                    "Fi":   "fish",
                    "Gl-a": "gluten (wheat)",
                    "Gl-b": "gluten (rye)",
                    "Gl-c": "gluten (barley)",
                    "Gl-d": "gluten (oats)",
                    "Gl-e": "gluten (spelt)",
                    "Gl-f": "gluten (kamut)",
                    "Gl":   "gluten",
                    "Kr":   "crustaceans",
                    "Lu":   "lupin",
                    "ML":   "milk / lactose",
                    "Mu":   "molluscs",
                    "Nu-a": "almonds",
                    "Nu-b": "hazelnuts",
                    "Nu-c": "walnuts",
                    "Nu-d": "cashews",
                    "Nu-e": "pecans",
                    "Nu-f": "brazil nuts",
                    "Nu-g": "pistachios",
                    "Nu-h": "macadamia nuts",
                    "Nu-i": "queensland nuts",
                    "Nu":   "tree nuts",
                    "Sa":   "sesame",
                    "Se":   "celery",
                    "Sf":   "sulphur dioxide / sulphites",
                    "Sl":   "sesame",
                    "Sn":   "mustard",
                    "So":   "soy",
                    "We":   "molluscs",
                };
                def additives_map: {
                    "1":  "colouring",
                    "2":  "preservative",
                    "3":  "nitrite curing salt",
                    "4":  "antioxidant",
                    "5":  "flavour enhancer",
                    "6":  "sulphurated",
                    "7":  "blackened",
                    "8":  "waxed",
                    "9":  "sweetener",
                    "10": "contains a source of phenylalanine",
                    "11": "phosphate",
                };'
            return 0
        fi
        printf 'Error: function %s failed.\n' "${funcstack[1]}" >&2
        return 1
    }



    function _mensa_display()
    {
        local mensa_date_iso mensa_date_formatted regex_good
        regex_good="(${(j:)|(:)mensa_patterns_good})"
        regex_bad="(${(j:)|(:)mensa_patterns_bad})"
        mensa_date_iso="$1"
        # use jq to format to ensure the formatting is the same as in the table
        mensa_date_formatted="$(printf '%s' "${mensa_date_iso}" | jq -Rr "strptime(\"%Y-%m-%d\") | strftime(\"${mensa_date_format_string}\")" )"
        sed -E "s/^.*$/$(printf '\033')[${mensa_base_color}m&$(printf '\033')[0m/" \
        | _mensa_highlight " .*${mensa_date_formatted}.* " "${mensa_highlight_color_today}" \
        | _mensa_highlight '[═├┼┤│─╤╧╪╒╕╞╡╘╛]+' "${mensa_highlight_color_grid}" \
        | _mensa_highlight "${regex_good}" "${mensa_highlight_color_good}" \
        | _mensa_highlight "${regex_bad}" "${mensa_highlight_color_bad}"
    }



    # # probably not that reliable but supports nested / overlapping highlighting
    function _mensa_highlight()
    {
        local regex_pattern="$1"
        local color="$2"
        local ESC US # US = Unit Separator ascii character
        ESC="$(printf '\033')"  # the escape character because sed treats the string '\033' as just 4 literal characters
        US="$(printf '\037')"
        sed -E "s/(${regex_pattern})/${ESC}[${color}m\1${US}/g" \
        | awk '
            BEGIN {
                ESC   = sprintf("%c", 27)
                US    = sprintf("%c", 31)
                RESET = ESC "[0m"
                stack_size = 0
            }

            {
                line = $0
                out = ""

                while (length(line)) {

                    # ANSI escape sequence: ESC [ ... m
                    if (match(line, "^" ESC "\\[[0-9;]*m")) {
                        seq = substr(line, RSTART, RLENGTH)
                        stack[++stack_size] = seq
                        out = out seq
                        line = substr(line, RLENGTH + 1)
                        continue
                    }

                    # Unit Separator
                    if (substr(line, 1, 1) == US) {
                        # pop
                        if (stack_size > 0)
                            stack_size--

                        # peek (with RESET fallback)
                        if (stack_size > 0)
                            out = out stack[stack_size]
                        else
                            out = out RESET

                        line = substr(line, 2)
                        continue
                    }

                    # normal character
                    out = out substr(line, 1, 1)
                    line = substr(line, 2)
                }

                print out
            }'
    }



    # given an epoch time stamp, format in a human readably string how long ago that was
    # precision depends on the delta time, we do not care about the seconds if it was days ago
    _mensa_ago_string() {
        local delta="$(( EPOCHSECONDS - $1 ))"
        local d="$(( delta / 86400 ))"
        local h="$(( (delta % 86400) / 3600 ))"
        local m="$(( (delta % 3600) / 60 ))"
        local s="$(( delta % 60 ))"
        (( delta < 0 )) && { printf 'in the future\n'; return 1; }

        local d_unit='days' h_unit='hours' m_unit='minutes' s_unit='seconds'
        (( d == 1 )) && d_unit='day'
        (( h == 1 )) && h_unit='hour'
        (( m == 1 )) && m_unit='minute'
        (( s == 1 )) && s_unit='second'

        if (( d > 0 )); then
            printf '%s %s %s %s ago\n' "$d" "$d_unit" "$h" "$h_unit"
        elif (( h > 0 )); then
            printf '%s %s %s %s ago\n' "$h" "$h_unit" "$m" "$m_unit"
        elif (( m > 0 )); then
            printf '%s %s %s %s ago\n' "$m" "$m_unit" "$s" "$s_unit"
        else
            printf '%s %s ago\n' "$s" "$s_unit"
        fi
    }

}

# restore temporarily changed options
(( ${#mensa_zsh_options} )) && setopt ${mensa_zsh_options[@]}
'builtin' 'unset' 'mensa_zsh_options'
