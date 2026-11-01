#!/usr/bin/env bash
set -euo pipefail
[ "$#" = 2 ] || exit 2
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
[ -d "$1" ] && [ -d "$2" ] || exit 2
work=$(mktemp -d "${TMPDIR:-/tmp}/dispatch-compare.XXXXXX")
[ -n "$work" ] || exit 1
trap 'rm -rf "$work"' EXIT
normalise() {
  # Perl's raw slurp preserves a missing final newline and literal path bytes.
  perl -e '
    use strict; use warnings;
    my ($dir,$file,$state)=@ARGV;
    local $/;
    my @paths;
    for my $key (qw(impl_bin scn_tmp run_dir)) {
      open my $fh,"<","$dir/$key" or die "$key: $!";
      my $path=<$fh>; $path =~ s/\n\z//;
      length $path or die "empty $key";
      push @paths, [$path, $key eq "impl_bin" ? "<IMPL_BIN>" : $key eq "scn_tmp" ? "<SCN_TMP>" : "<RUN>"];
    }
    open my $fh,"<","$dir/$file" or die "$file: $!";
    my $text=<$fh> // "";
    for my $pair (@paths) { $text =~ s/\Q$pair->[0]\E/$pair->[1]/g; }
    my @known;
    if (open my $in,"<",$state) { while (<$in>) { push @known, split /\n/; } }
    my @full;
    for my $candidate (sort glob("$dir/*")) {
      next if $candidate =~ m{/(?:impl_bin|scn_tmp|run_dir)$} || !-f $candidate;
      open my $in,"<",$candidate or die $!;
      my $raw=<$in> // "";
      push @full, ($raw =~ /(?<![a-zA-Z0-9_])([0-9a-fA-F]{40})(?![a-zA-Z0-9_])/g);
    }
    sub token {
      my $sha=lc shift;
      my @matches=grep {index(lc($_),$sha)==0} @full;
      $sha=lc $matches[0] if @matches && !grep {lc($_) ne lc($matches[0])} @matches;
      my $i=0; $i++ while $i<@known && $known[$i] ne $sha;
      push @known,$sha if $i==@known;
      return "<SHA".($i+1).">";
    }
    $text =~ s/(?<![a-zA-Z0-9_])([0-9a-fA-F]{40})(?![a-zA-Z0-9_])|(?<=base_sha=)([0-9a-fA-F]{7,39})(?![a-zA-Z0-9_])/token(defined $1 ? $1 : $2)/ge;
    open my $save,">",$state or die $!;
    print {$save} join("\n",@known), "\n";
    print $text, "\n\x01\n";
  ' "$1" "$2" "$3" | sed -E -f "$here/normalise.sed" | perl -0777 -pe 's/\n\x01\n\z//'
}
for side in 1 2; do
  case "$side" in 1) tree=$1 ;; 2) tree=$2 ;; esac
  : > "$work/ids.$side"
  for dir in "$tree"/*; do
    [ -d "$dir" ] || continue
    printf '%s\n' "${dir##*/}" >> "$work/ids.$side"
    [ ! -e "$dir/harness-timeout" ] || { echo "${dir##*/}: harness-timeout"; exit 1; }
  done
done
[ -s "$work/ids.1" ] || { echo 'no scenarios to compare'; exit 1; }
cmp -s "$work/ids.1" "$work/ids.2" || { echo 'scenario id sets differ'; exit 1; }
while IFS= read -r id; do
  for side in 1 2; do
    case "$side" in 1) tree=$1 ;; 2) tree=$2 ;; esac
    {
      printf '%s\n' stdout stderr rc argv state
      for input in "$tree/$id"/stdin.* "$tree/$id"/call.*; do
        [ ! -f "$input" ] || printf '%s\n' "${input##*/}"
      done
    } > "$work/files.$side"
  done
  cmp -s "$work/files.1" "$work/files.2" || { echo "$id: observation sets differ"; exit 1; }
  if [ -f "$1/$id/retry.log" ] && [ -f "$2/$id/retry.log" ]; then
    printf '%s\n' retry.log >> "$work/files.1"
  elif [ -f "$1/$id/retry.log" ] || [ -f "$2/$id/retry.log" ]; then
    echo "warning: $id/retry.log present on only one side"
  fi
  : > "$work/shas.1"
  : > "$work/shas.2"
  while IFS= read -r file; do
    if [ ! -f "$1/$id/$file" ] || [ ! -f "$2/$id/$file" ]; then echo "$id/$file differs (missing)"; exit 1; fi
    normalise "$1/$id" "$file" "$work/shas.1" > "$work/a"
    normalise "$2/$id" "$file" "$work/shas.2" > "$work/b"
    if ! cmp -s "$work/a" "$work/b"; then echo "$id/$file differs"; exit 1; fi
  done < "$work/files.1"
done < "$work/ids.1"
