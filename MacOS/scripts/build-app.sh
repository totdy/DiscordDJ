#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
app_dir="${project_dir}/dist/DiscordDJ.app"
resources_dir="${app_dir}/Contents/Resources"
node_binary="${NODE_BINARY:-$(command -v node || true)}"
pnpm_binary="${PNPM_BINARY:-$(command -v pnpm || true)}"

if [[ -z "${node_binary}" || ! -x "${node_binary}" ]]; then
  print -u2 "Node.js 22+ is required only to build the app. Set NODE_BINARY if node is not on PATH."
  exit 1
fi
if [[ -z "${pnpm_binary}" || ! -x "${pnpm_binary}" ]]; then
  print -u2 "pnpm is required only to build the app. Set PNPM_BINARY if pnpm is not on PATH."
  exit 1
fi

cd "${project_dir}"
"${pnpm_binary}" install --prod --frozen-lockfile
swift build -c release

rm -rf "${app_dir}"
mkdir -p "${app_dir}/Contents/MacOS" "${resources_dir}/Bridge" "${resources_dir}/Runtime"
cp ".build/release/DiscordDJMac" "${app_dir}/Contents/MacOS/DiscordDJ"
cp "App/Info.plist" "${app_dir}/Contents/Info.plist"
cp "Bridge/index.js" "${resources_dir}/Bridge/index.js"
cp -R "node_modules" "${resources_dir}/Bridge/node_modules"
cp "${node_binary}" "${resources_dir}/Runtime/node"
chmod +x "${resources_dir}/Runtime/node"

# Some Node builds (e.g. Homebrew) are dynamically linked against a shared
# libnode dylib that lives via a symlink + rpath rather than next to `node`.
node_real_binary="$(readlink -f "${node_binary}")"
node_libnode_name="$(otool -L "${node_real_binary}" | awk '/libnode.*\.dylib/{n=$1; sub(/^@rpath\//,"",n); print n; exit}')"
if [[ -n "${node_libnode_name}" ]]; then
  node_bin_dir="$(dirname "${node_real_binary}")"
  found_libnode=""
  for candidate in "${node_bin_dir}/${node_libnode_name}" "${node_bin_dir}/../lib/${node_libnode_name}"; do
    if [[ -f "${candidate}" ]]; then
      found_libnode="${candidate}"
      break
    fi
  done
  if [[ -n "${found_libnode}" ]]; then
    cp "${found_libnode}" "${resources_dir}/Runtime/"
  else
    print -u2 "Warning: could not locate ${node_libnode_name} near ${node_bin_dir}."
  fi
fi
codesign --force --deep --sign - "${app_dir}"
print "Built ${app_dir}"
