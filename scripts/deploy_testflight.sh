#!/bin/zsh
set -euo pipefail

# Archives and uploads an iOS build while deliberately leaving MARKETING_VERSION unchanged.
repo_dir="${0:A:h:h}"
project="${repo_dir}/Stocked.xcodeproj"
scheme="Stocked"
pbx="${project}/project.pbxproj"
archive_root="${ARCHIVE_ROOT:-${HOME}/Library/Developer/Xcode/Archives/Stocked}"
developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"

[[ -d "${developer_dir}" ]] || { print -u2 "Xcode not found at ${developer_dir}"; exit 1; }
export DEVELOPER_DIR="${developer_dir}"
export SOWENS_BUILD_ROOT="${SOWENS_BUILD_ROOT:-${HOME}/Library/Developer/StockedBuilds}"
python3 "${repo_dir}/scripts/release.py" check
python3 "${repo_dir}/scripts/release.py" check-output
ARCHIVE_ROOT="${archive_root}" python3 -c 'import os, sys; sys.path.insert(0, os.path.join(sys.argv[1], "scripts")); from release import validate_output; validate_output(os.environ["ARCHIVE_ROOT"])' "${repo_dir}"
mkdir -p "${archive_root}"

marketing_before="$(sed -n 's/.*MARKETING_VERSION = \([^;]*\);.*/\1/p' "${pbx}" | sort -u)"
# The shared scheme reserves and stamps the build. Do not bump twice here.
next="auto"

stamp="$(date +%Y%m%d-%H%M%S)"
archive="${archive_root}/Stocked-b${next}-${stamp}.xcarchive"
export_options="$(mktemp)"
trap 'rm -f "${export_options}"' EXIT
{
  print '<?xml version="1.0" encoding="UTF-8"?>'
  print '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
  print '<plist version="1.0"><dict>'
  print '<key>method</key><string>app-store-connect</string>'
  print '<key>destination</key><string>upload</string>'
  print '<key>signingStyle</key><string>automatic</string>'
  print '<key>manageAppVersionAndBuildNumber</key><false/>'
  print '<key>uploadSymbols</key><true/>'
  print '</dict></plist>'
} > "${export_options}"

auth=()
if [[ -n "${ASC_KEY_ID:-}" || -n "${ASC_ISSUER_ID:-}" || -n "${ASC_KEY_PATH:-}" ]]; then
  [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" && -f "${ASC_KEY_PATH:-}" ]] || {
    print -u2 "Set ASC_KEY_ID, ASC_ISSUER_ID, and ASC_KEY_PATH together"; exit 1
  }
  auth=(-authenticationKeyID "${ASC_KEY_ID}" -authenticationKeyIssuerID "${ASC_ISSUER_ID}" -authenticationKeyPath "${ASC_KEY_PATH}")
fi

export DEVELOPER_DIR="${developer_dir}"
xcodebuild -project "${project}" -scheme "${scheme}" -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "${archive}" \
  -derivedDataPath "${SOWENS_BUILD_ROOT}/Stocked/Release" \
  -allowProvisioningUpdates "${auth[@]}" archive
next="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleVersion' "${archive}/Info.plist")"
marketing_after="$(sed -n 's/.*MARKETING_VERSION = \([^;]*\);.*/\1/p' "${pbx}" | sort -u)"
[[ "${marketing_before}" == "${marketing_after}" ]] || { print -u2 "Refusing upload: marketing version changed"; exit 1; }
python3 "${repo_dir}/scripts/release.py" validate-archive --archive "${archive}"
xcodebuild -exportArchive -archivePath "${archive}" -exportOptionsPlist "${export_options}" \
  -allowProvisioningUpdates "${auth[@]}"

print "Uploaded Stocked build ${next} to App Store Connect/TestFlight."
print "Marketing version remained: ${marketing_after}"
