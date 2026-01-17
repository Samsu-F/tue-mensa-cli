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
# Examples:
# - `mensa` will show the full meal plan.
# - `mensa vegan 3,70` will show all vegan dishes that cost 3,70€.
# - `mensa '^([^\[]|\[[^S]+\])*$' salat` will show all meals that are not tagged as containing pork, and also include any type of salad.

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

# the color in which you want your favourite dishes highlighted:
export mensa_highlight_color_good="22;1;32" # 22 = bold off & faint off; 1 = bold; 32 = green
# the color in which you want your bad dishes highlighted:
export mensa_highlight_color_bad="22;91" # 91 = intense red
# the color of the grid:
export mensa_highlight_color_grid="22;2;37" # 2 = faint; 37 = white (==> gray)
# the color in which you want todays dishes highlighted:
export mensa_highlight_color_today="22;97"  # 97 = intense white
# the neutral text color:
export mensa_base_color="22;39" # 39 = default text color of your terminal

# regex patterns you want to highlight as dishes you know you like.
# WARNING: literal forward slashes must be escaped!
export mensa_patterns_good=(
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
export mensa_patterns_bad=(
    'Sesam.?[Kk]arotten.?[Ss]tick'
    '\[[SRFGLKW\/]\]'                   # tags for all kinds of meat
)

alias mensa_pager='more -f' # Leave empty or use 'cat' if you don't want to use a pager.
                            # Evaluated at runtime.

export mensa_date_format_string='%a %d.%m.' # see `man strftime` for a list of specifiers

export mensa_curry_to_haskell_easteregg=true

# Makes the heading of each table a clickable link. Disable if your terminal does not support this.
export mensa_clickable_links=true

export mensa_cache_time_to_live='600' # time in seconds that cached results are valid for

# The columns that will be removed before applying the argument filters. Comment out the columns
# that you want to see.
export mensa_excluded_columns=(
    'id'
    # 'menuLine'
    # 'studentPrice'
    'guestPrice'
    'pupilPrice'
    # 'menuDate'
    # 'menu'
    'meats'
    'icons'
    'filtersInclude'
    'allergens'
    'additives'
    # 'co2'
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
    for cmd in jq jtbl curl grep sed awk; do
        if ! command -pv "${cmd}" &>/dev/null; then
            printf "\033[1;31mtue-mensa-cli: Error: missing dependency '%s'.\033[0m\n" "${cmd}" >&2
            return 1
        fi
    done

    # mensa_file_mtime: a function to get the modification timestamp of a file
    case "$(uname)" in
        Linux)
            function mensa_file_mtime() { stat -c %Y "$1"; }
            function mensa_date_tomorrow() { date --date=tomorrow '+%Y-%m-%d'; }
            ;;
        Darwin|FreeBSD|OpenBSD|NetBSD|DragonFly)
            function mensa_file_mtime() { stat -f %m "$1"; }
            function mensa_date_tomorrow() { date -v+1d '+%Y-%m-%d'; }
            ;;
        *)
            printf "\033[1;33mtue-mensa-cli: Warning: Unsupported OS '%s'. Defaulting to assuming GNU coreutils are available.\033[0m\n" "$(uname)" >&2
            function mensa_file_mtime() { stat -c %Y "$1"; }
            function mensa_date_tomorrow() { date --date=tomorrow '+%Y-%m-%d'; }
            ;;
    esac



    function mensa()
    {
        emulate -L zsh; setopt localoptions no_unset # for reliability independent of which options are set
        local filters mensa_date file_suffix file_final_tables mensa_dir filters_concatenated heading_morgenstelle heading_wilhelmstrasse heading_prinzkarl
        filters=("$@")
        mensa_dir='/tmp/tue-mensa-cli'
        mkdir -p "${mensa_dir}"

        mensa_date="$(date '+%Y-%m-%d')"
        if [ "$(date '+%H%M')" -gt "1400" ]; then mensa_date="$(mensa_date_tomorrow)"; fi

        file_final_tables="${mensa_dir}/final_tables_$(mensa_generate_file_suffix "${filters[@]}" "${mensa_date}")"
        local file_morgenstelle="${mensa_dir}/json_morgenstelle_${mensa_date}"
        local file_wilhelmstrasse="${mensa_dir}/json_wilhelmstrasse_${mensa_date}"
        local file_prinzkarl="${mensa_dir}/json_prinzkarl_${mensa_date}"

        # if the final file or the json files it is based on do not exist or exceeded time to live
        if [ ! -f "${file_final_tables}" ] || [ "$(($(date '+%s') - $(mensa_file_mtime "${file_final_tables}") ))" -gt "${mensa_cache_time_to_live}" ] \
        || [ ! -f "${file_morgenstelle}" ] || [ "$(($(date '+%s') - $(mensa_file_mtime "${file_morgenstelle}") ))" -gt "${mensa_cache_time_to_live}" ]; then
            (
                # only use curl if needed (if json files do not exist or are no longer valid)
                if [ ! -f "${file_morgenstelle}" ] || [ "$(($(date '+%s') - $(mensa_file_mtime "${file_morgenstelle}") ))" -gt "${mensa_cache_time_to_live}" ]; then
                    curl -Ss "http://www.my-stuwe.de/wp-json/mealplans/v1/canteens/621" > "${file_morgenstelle}" &
                    curl -Ss "http://www.my-stuwe.de/wp-json/mealplans/v1/canteens/611" > "${file_wilhelmstrasse}" &
                    curl -Ss "http://www.my-stuwe.de/wp-json/mealplans/v1/canteens/623" > "${file_prinzkarl}" &
                    wait
                fi

                mensa_json_to_table "621" "${mensa_date}" "${filters[@]}" <"${file_morgenstelle}"   >"${file_morgenstelle}.tmp" &
                mensa_json_to_table "611" "${mensa_date}" "${filters[@]}" <"${file_wilhelmstrasse}" >"${file_wilhelmstrasse}.tmp" &
                mensa_json_to_table "623" "${mensa_date}" "${filters[@]}" <"${file_prinzkarl}"      >"${file_prinzkarl}.tmp" &
                wait

                if [ "${mensa_clickable_links}" = "true" ]; then
                    heading_morgenstelle="\033[1m\033]8;;https://www.my-stuwe.de/mensa/mensa-morgenstelle-tuebingen/\033\\\\Morgenstelle\033]8;;\033\\\\\033[0m"
                    heading_wilhelmstrasse="\033[1m\033]8;;https://www.my-stuwe.de/mensa/mensa-wilhelmstrasse-tuebingen/\033\\\\Wilhelmstraße\033]8;;\033\\\\\033[0m"
                    heading_prinzkarl="\033[1m\033]8;;https://www.my-stuwe.de/mensa/mensa-prinz-karl-tuebingen/\033\\\\Prinz Karl\033]8;;\033\\\\\033[0m"
                else
                    heading_morgenstelle="\033[1mMorgenstelle\033[0m"
                    heading_wilhelmstrasse="\033[1mWilhelmstraße\033[0m"
                    heading_prinzkarl="\033[1mPrinz Karl\033[0m"
                fi
                print " ${heading_morgenstelle}"
                cat "${file_morgenstelle}.tmp"
                print "\n ${heading_wilhelmstrasse}"
                cat "${file_wilhelmstrasse}.tmp"
                print "\n ${heading_prinzkarl}"
                cat "${file_prinzkarl}.tmp"
                rm "${file_morgenstelle}.tmp" "${file_wilhelmstrasse}.tmp" "${file_prinzkarl}.tmp"
            ) | mensa_display "${mensa_date}" > "${file_final_tables}"
        fi

        cat "${file_final_tables}" | eval "${aliases[mensa_pager]:-cat}" # alias for an optional pager or cat
    }



    # generates a hash based on everything that affects the final tables, to be used like a unique id in the cache
    function mensa_generate_file_suffix() {
        local values=("$@")
        local unit_sep="$(printf '\037')"
        local record_sep="$(printf '\036')"
        values+=(   # add everything that affects the content of the final table file
            "$(tput cols)"
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
            "${record_sep}${mensa_excluded_columns[@]}"
        )
        local values_concatenated=''
        local val
        for val in "${values[@]}"; do
            values_concatenated+="${unit_sep}${val}"
        done
        printf '%s' "${values_concatenated}" | openssl dgst -sha256 | awk '{print $NF}'
    }



    function mensa_json_to_table()
    {
        local mensa_id="$1"
        local mensa_date="$2"
        shift 2
        local filters=("$@")
        local jq_filters=""
        local item
        for item in "${filters[@]}"; do
            item="$(printf '%s' "${item}" | sed -E 's/\\/\\\\/g')" # jq needs escaped backslashes
            if printf '%s\n' "${item}" | grep -qE '[[:upper:]]'; then
                # case sensitive regex if pattern filter contains uppercase characters
                jq_filters="${jq_filters} | select([.. | scalars | tostring] | join(\"|\") | test(\"${item}\")) "
            else
                # default: case insensitive filtering
                jq_filters="${jq_filters} | select([.. | scalars | tostring] | join(\"|\") | ascii_downcase | test(\"${item}\")) "
            fi
        done

        local jq_del_columns=${(j:,:)mensa_excluded_columns/#/.}    # this expansion must not be quoted!
        if [ -n "${jq_del_columns}" ]; then jq_del_columns="| del(${jq_del_columns})"; else jq_del_columns=""; fi

        jq -r "[ .\"${mensa_id}\".menus[] \
                    | del(.photo) \
                    | select(.menuDate >= \"${mensa_date}\") \
                    | select(.menuLine != \"Salat-/ Gemüsebuffet 100g\") \
                    | select(.menuLine != \"Beilagen vorport.\") \
                    | .menu=(.menu | join(\", \")) \
                    | select(.menu != \"Frisches Obst\") \
                    | select(.menu != \"Dessertauswahltheke\") \
                    | select(.menu != \"Beilagenbuffet MM\") \
                    | .icons=(.icons | join(\", \")) \
                    | .filtersInclude=(.filtersInclude | join(\", \")) \
                    | .meats=(.meats | join(\", \")) \
                    | .allergens=(.allergens | join(\", \")) \
                    | .additives=(.additives | join(\", \")) \
                ] \
                | sort_by(.menuDate) \
                | \
                [ .[] \
                    | .menuDate |= (strptime(\"%Y-%m-%d\") | strftime(\"${mensa_date_format_string}\")) \
                    ${jq_del_columns} \
                    ${jq_filters} \
                ]" \
            | if [ "${mensa_curry_to_haskell_easteregg}" = "true" ]; then sed 's/curry/haskell/g' | sed 's/Curry/Haskell/g'; else cat - ; fi \
            | jtbl -f --cols="$(tput cols)"
    }



    function mensa_display()
    {
        local mensa_date_iso mensa_date_formatted regex_good
        regex_good="(${(j:)|(:)mensa_patterns_good})"
        regex_bad="(${(j:)|(:)mensa_patterns_bad})"
        mensa_date_iso="$1"
        # use jq to format to ensure the formatting is the same as in the table
        mensa_date_formatted="$(printf '%s' "${mensa_date_iso}" | jq -Rr "strptime(\"%Y-%m-%d\") | strftime(\"${mensa_date_format_string}\")" )"
        sed -E "s/^.*$/$(printf '\033')[${mensa_base_color}m&$(printf '\033')[0m/" \
        | mensa_highlight " .*${mensa_date_formatted}.* " "${mensa_highlight_color_today}" \
        | mensa_highlight '[═├┼┤│─╤╧╪╒╕╞╡╘╛]+' "${mensa_highlight_color_grid}" \
        | mensa_highlight "${regex_good}" "${mensa_highlight_color_good}" \
        | mensa_highlight "${regex_bad}" "${mensa_highlight_color_bad}"
    }



    # # probably not that reliable but supports nested / overlapping highlighting
    function mensa_highlight()
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

}

# restore temporarily changed options
(( ${#mensa_zsh_options} )) && setopt ${mensa_zsh_options[@]}
'builtin' 'unset' 'mensa_zsh_options'
