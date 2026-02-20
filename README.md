# tue-mensa-cli
A customizable zsh function to view the meal plans of the Uni Tübingen refectories (Morgenstelle, Wilhelmstraße, and Prinz Karl) directly from your terminal.
Features include regex filtering, paging, caching, an Easter egg, colorful highlighting of today's meals and known favorite/disliked dishes in customizable colors, and more.
The meal plans can be shown in English or in German, see config options for more information.

All facilities with a published meal plan on the my-stuwe.de website are supported. As of February 2026, these are:
- Mensa Morgenstelle
- Cafeteria Morgenstelle
- Mensa Wilhelmstraße
- Cafeteria Wilhelmstraße
- Mensa & Cafeteria Prinz Karl
- Mensa Hohenheim
- Mensa & Cafeteria Reutlingen
- Mensa & Cafeteria Nürtingen
- Mensa & Cafeteria Sigmaringen
- Mensa & Cafeteria Albstadt
- Mensa & Cafeteria Rottenburg

Both GNU Linux and macOS should be supported. In case it does not work on your system, please let me know.


## Usage
```
mensa [regex filters [...]]
```
Outputs all dishes that match all filters.
- Filters are regular expressions matched against the concatenation of all fields (`|` as separator).
- Filters are case-insensitive by default.
- If a filter contains at least one uppercase character, it becomes case-sensitive.
- By default, filters are treated as *positive (inclusive) filters*, meaning that only dishes that
  match the regular expression are kept.
- A filter starting with a minus (`-`) is treated as a *negative (exclusive) filter*. The leading minus is
  removed, and only dishes that do *not* match the remaining regular expression are kept.
  To use a *positive* filter whose regular expression itself begins with a literal minus, escape the minus
  using a backslash (for example: `'\-foo'`).

Examples:
- `mensa` will show the full meal plan.
- `mensa vegan 3,70` will show all vegan dishes that cost 3,70€.
- `mensa '-\[[^\]]*S.*\]' salat` will show all meals that are not tagged as containing pork, and also include any type of salad.


## Installation
Save the file [`mensa.zsh`](mensa.zsh) anywhere and just source it in your `~/.zshrc` like this:
```
source /path/to/mensa.zsh
```
Then restart your shell or run `source ~/.zshrc`.


## Dependencies
- jtbl
- jq
- curl
- coreutils
