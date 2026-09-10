#!/usr/bin/env bash
#
# Make the deployed tree loadable on a GCC 13 host.
#
# THE FAILURE
#
#   ./DesktopEditors: symbol lookup error: libascdocumentscore.so:
#     undefined symbol: _ZNSt8ios_base4Init20_S_synced_with_stdioE
#
# — the whole application, from run 34421271035's installer. It links, it
# installs, and it dies before main().
#
# THE CAUSE
#
# The symbol is std::ios_base::Init::_S_synced_with_stdio, a PRIVATE static
# member of libstdc++. On GCC 13 it lives only in the static archive, and is
# not exported from the shared library at all:
#
#   nm -A /usr/lib/gcc/x86_64-linux-gnu/13/libstdc++.a | grep _S_synced
#     libstdc++.a:ios_init.o:                  U _ZNSt8ios_base4Init20_S_..E
#     libstdc++.a:ios.o:      0000000000000000 D _ZNSt8ios_base4Init20_S_..E
#   nm -D --defined-only /usr/lib/x86_64-linux-gnu/libstdc++.so.6.0.33 \
#     | grep -c _S_synced
#     0
#
# So the reference cannot come from any header — <bits/ios_base.h> only
# DECLARES it (line 653, identically on 12 and 13). It comes from libstdc++'s
# own ios_init.o being pulled out of the static archive into one of our shared
# libraries while ios.o, which carries the definition, was not. A shared link
# tolerates the dangling reference; the loader does not.
#
# Its sibling _S_refcount has exactly the same shape and is equally unexported,
# so both are handled here — otherwise fixing one just moves the error.
#
# THE REMEDY
#
# Supply the two data symbols from a shim library and make every affected
# object depend on it. The definitions are byte-faithful to what ios.o would
# have contributed, read off that object rather than guessed:
#
#   readelf -sW ios.o:  _S_refcount            4 bytes, .bss   (zero)
#                       _S_synced_with_stdio   1 byte,  .data
#   objdump -s -j .data._ZNSt8ios_base4Init20_S_synced_with_stdioE ios.o
#                       0000 01
#
# ios.o itself is not usable directly: it also defines ios_base's constructors,
# destructors, vtable and every ios_base flag constant, which would collide
# with the shared libstdc++ at load time. Only the two orphaned statics belong
# in the shim.
#
# This is a repair, not the root fix. The root fix is to stop pulling
# ios_init.o out of a static libstdc++ during the upstream link — see the
# "Trace the dangling libstdc++ statics" CI step, which reports which archive
# carries it. Once that lands this script finds nothing and does nothing.
#
# Usage: scripts/fix_stdcxx_statics.sh <deploy-tree>

set -euo pipefail

TREE="${1:-}"
[ -n "$TREE" ] && [ -d "$TREE" ] || { echo "usage: $0 <deploy-tree>" >&2; exit 2; }

SHIM_SONAME="libwpslite-stdcxx-compat.so.1"
SYMS=(_ZNSt8ios_base4Init11_S_refcountE _ZNSt8ios_base4Init20_S_synced_with_stdioE)

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*" >&2; }

# If the host's shared libstdc++ exports them, there is nothing dangling and
# nothing to repair. Keeps this a no-op on toolchains where the ABI differs.
exported=0
for s in "${SYMS[@]}"; do
  if nm -D --defined-only /usr/lib/x86_64-linux-gnu/libstdc++.so.6 2>/dev/null \
     | grep -q "$s"; then exported=1; fi
done
if [ "$exported" -eq 1 ]; then
  ok "this libstdc++ exports the ios_base::Init statics — nothing to repair"
  exit 0
fi

# --- find the affected objects ----------------------------------------------
# An ELF that leaves either symbol undefined will fail to load. Scan the whole
# tree rather than naming libascdocumentscore.so: the loader reports only the
# first failure, so the named library is rarely the only one.
mapfile -t AFFECTED < <(
  find "$TREE" -type f \( -name '*.so' -o -name '*.so.*' -o -perm -u+x \) -print0 \
  | xargs -0 -r -P "$(nproc)" -n 32 sh -c '
      for f; do
        head -c 4 "$f" 2>/dev/null | grep -q ELF || continue
        if nm -D --undefined-only "$f" 2>/dev/null \
           | grep -qE "_ZNSt8ios_base4Init(11_S_refcountE|20_S_synced_with_stdioE)"; then
          echo "$f"
        fi
      done' _
)

if [ "${#AFFECTED[@]}" -eq 0 ]; then
  ok "no object references the unexported ios_base::Init statics — nothing to repair"
  exit 0
fi

echo "objects with dangling ios_base::Init statics: ${#AFFECTED[@]}"
printf '    %s\n' "${AFFECTED[@]#"$TREE"/}"

command -v patchelf >/dev/null || { echo "patchelf is required" >&2; exit 1; }

# --- build the shim next to the objects that need it -------------------------
# One copy per directory: DT_NEEDED has no path, so the shim must be reachable
# from each affected object's own RUNPATH, and DT_RUNPATH is not inherited by
# a dependency's dependencies.
src="$(mktemp -d)/wpslite_stdcxx_compat.c"
cat > "$src" <<'EOF'
/* std::ios_base::Init statics that GCC 13 keeps out of libstdc++.so.6.
   Values and sizes taken from libstdc++.a(ios.o); see fix_stdcxx_statics.sh. */
int  _ZNSt8ios_base4Init11_S_refcountE = 0;          /* _Atomic_word, .bss  */
char _ZNSt8ios_base4Init20_S_synced_with_stdioE = 1; /* bool = true, .data  */
EOF

patched=0
for dir in $(printf '%s\n' "${AFFECTED[@]}" | xargs -r -n1 dirname | sort -u); do
  if [ ! -f "$dir/$SHIM_SONAME" ]; then
    gcc -shared -fPIC -O2 -Wl,-soname,"$SHIM_SONAME" -o "$dir/$SHIM_SONAME" "$src"
  fi
done

for f in "${AFFECTED[@]}"; do
  patchelf --print-needed "$f" | grep -qx "$SHIM_SONAME" || \
    patchelf --add-needed "$SHIM_SONAME" "$f"
  # The shim sits beside the object, but only an RUNPATH on the object itself
  # will find it — the executable's RUNPATH does not carry down to it.
  rp="$(patchelf --print-rpath "$f" 2>/dev/null || true)"
  case ":$rp:" in
    *:'$ORIGIN':*) ;;
    *) patchelf --set-rpath "${rp:+$rp:}\$ORIGIN" "$f" ;;
  esac
  patched=$((patched + 1))
done

ok "repaired $patched object(s) with $SHIM_SONAME"

# --- prove it -----------------------------------------------------------------
# ldd resolves the dependency graph the way the loader will. A remaining
# "not found" for the shim, or a still-undefined symbol, means the repair
# did not take, and it is better to know here than on a user's machine.
failed=0
for f in "${AFFECTED[@]}"; do
  if nm -D --undefined-only "$f" 2>/dev/null \
     | grep -qE "_ZNSt8ios_base4Init(11_S_refcountE|20_S_synced_with_stdioE)"; then
    if ! (cd "$(dirname "$f")" && ldd "$(basename "$f")" 2>/dev/null \
          | grep -q "$SHIM_SONAME => .*$SHIM_SONAME"); then
      warn "${f#"$TREE"/}: still cannot resolve $SHIM_SONAME"
      failed=$((failed + 1))
    fi
  fi
done
[ "$failed" -eq 0 ] || { echo "repair incomplete for $failed object(s)" >&2; exit 1; }
ok "every affected object now resolves the shim"
