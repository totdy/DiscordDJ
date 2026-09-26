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

codesign --force --deep --sign - "${app_dir}"
print "Built ${app_dir}"
