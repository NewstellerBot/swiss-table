# Toolchain for building this project with the nix-built OxCaml compiler.
# Source this (sh/zsh/bash) before invoking dune.
#
# result/bin ships plain-named binaries (ocamlc, ocamlopt, ocamlrun, ...) with
# the correct stdlib prefix baked in, so no OCAMLLIB override is needed.
# PATH is pinned so no opam switch (vanilla OCaml 5.4.1) can leak in;
# /usr/bin:/bin still provides clang/ar/etc. for linking.
export PATH=/Users/krystian/code/ocaml-swiss-table/oxcaml/result/bin:/usr/bin:/bin
# Belt-and-suspenders: if an ocamlfind ever appears on PATH, make findlib
# report no packages instead of resolving the 5.4.1 switch libraries.
export OCAMLFIND_CONF=/dev/null
# Vanilla dune 3.22.2 from the default opam switch, by absolute path.
DUNE=/Users/krystian/.opam/default/bin/dune
