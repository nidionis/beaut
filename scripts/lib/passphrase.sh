#!/usr/bin/env bash
# lib/passphrase.sh — word, random material, and secret generation (sourced).
#
# Generic primitives shared by virtual attributions, invites, device identities
# and the hidden personal tree. Nothing here touches the filesystem except the
# optional dictionary file.
set -uo pipefail

PASSPHRASE_BUILTIN_WORDS=(
  amber anchor apple arrow basin beacon birch breeze bridge candle
  canyon cedar cipher clover comet coral crimson dawn delta ember
  falcon fern fjord flint forest fossil frost garnet glacier granite
  harbor hazel heron hollow ivory jade juniper kettle lagoon lantern
  larch lava lemon lilac linen maple marble meadow mint mirror
  mist moss nectar nickel north oak oasis olive onyx orchid
  pebble pine plume pond quartz quill rain raven reed ridge
  river robin root saffron sage sand shade silver slate snow
  solar spruce star steam stone storm summit thistle thunder tide
  timber topaz tulip umber valley vapor velvet violet walnut wave
  willow wind winter wolf zephyr
)

# Print an integer in [0, upper_bound). Falls back to bash's RANDOM when
# /dev/urandom is unavailable, which keeps the function usable in minimal
# environments and in tests.
passphrase_random_integer() {
  local upper_bound="${1:?missing upper bound}" value=""
  if (( upper_bound <= 1 )); then
    printf '0'
    return 0
  fi
  if [[ -r /dev/urandom ]]; then
    value="$(od -An -N4 -tu4 /dev/urandom 2>/dev/null | tr -d '[:space:]')"
  fi
  if [[ ! "${value:-}" =~ ^[0-9]+$ ]]; then
    value="$RANDOM"
  fi
  printf '%s' "$(( value % upper_bound ))"
}

# Print random bytes as lowercase hexadecimal.
passphrase_random_hex() {
  local byte_count="${1:-24}" value=""
  if [[ -r /dev/urandom ]]; then
    value="$(od -An -N"$byte_count" -tx1 /dev/urandom 2>/dev/null | tr -d '[:space:]')"
  fi
  if [[ -z "${value:-}" ]]; then
    value="$(printf '%04x%04x%04x%04x' "$RANDOM" "$RANDOM" "$RANDOM" "$RANDOM")"
  fi
  printf '%s' "$value"
}

# Print random lowercase alphanumeric characters, for short opaque identifiers
# and for the default hidden personal-tree path. No pipeline: each character is
# drawn from /dev/urandom through passphrase_random_integer.
passphrase_random_alphanumeric() {
  local length="${1:-8}" alphabet='abcdefghijklmnopqrstuvwxyz0123456789'
  local value="" position index
  for (( position = 0; position < length; position++ )); do
    index="$(passphrase_random_integer ${#alphabet})"
    value+="${alphabet:index:1}"
  done
  printf '%s' "$value"
}

# Load words from an optional dictionary file into PASSPHRASE_WORDS. Empty or
# duplicated lines are ignored; the built-in list is the fallback.
passphrase_words_load() {
  local dictionary="${1:-}" word
  local -A seen_words=()
  PASSPHRASE_WORDS=()
  if [[ -n "$dictionary" && -r "$dictionary" ]]; then
    while IFS= read -r word; do
      word="${word//[[:space:]]/}"
      [[ -n "$word" ]] || continue
      [[ -n "${seen_words[$word]:-}" ]] && continue
      seen_words[$word]=1
      PASSPHRASE_WORDS+=("$word")
    done < "$dictionary"
  fi
  if (( ${#PASSPHRASE_WORDS[@]} == 0 )); then
    PASSPHRASE_WORDS=("${PASSPHRASE_BUILTIN_WORDS[@]}")
  fi
}

# Generate a hyphen-separated passphrase of distinct words.
passphrase_generate_passphrase() {
  local word_count="${1:-4}" dictionary="${2:-}"
  local index word result="" total_words
  local -A used_words=()
  passphrase_words_load "$dictionary"
  total_words=${#PASSPHRASE_WORDS[@]}
  (( total_words > 0 )) || {
    printf 'no dictionary words available\n' >&2
    return 1
  }
  (( word_count > total_words )) && word_count=$total_words
  (( word_count > 0 )) || word_count=1
  while (( ${#used_words[@]} < word_count )); do
    index="$(passphrase_random_integer "$total_words")"
    word="${PASSPHRASE_WORDS[$index]}"
    [[ -n "${used_words[$word]:-}" ]] && continue
    used_words[$word]=1
    result="${result:+$result-}$word"
  done
  printf '%s' "$result"
}

# Generate a secret as hexadecimal random bytes.
passphrase_generate_secret() {
  local byte_count="${1:-${PASSPHRASE_SECRET_BYTES:-24}}"
  passphrase_random_hex "$byte_count"
}
