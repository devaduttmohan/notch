# Homebrew cask for Notch. bin/release fills in the version and checksum and pushes this to
# the tap (github.com/devaduttmohan/homebrew-tap, Casks/notch.rb).
cask "notch" do
  version "VERSION"
  sha256 "SHA256"

  url "https://github.com/devaduttmohan/notch/releases/download/v#{version}/Notch-#{version}.zip"
  name "Notch"
  desc "Dynamic Island for the MacBook notch"
  homepage "https://github.com/devaduttmohan/notch"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Notch.app"
  binary "#{appdir}/Notch.app/Contents/MacOS/notchctl"

  # Signed locally (ad hoc) rather than notarised: without this, macOS won't open it.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/Notch.app"], must_succeed: false
  end

  # Notch's login item is an SMAppService one: macOS drops it with the app. (Homebrew's
  # login_item: only reaches the old System Events list, and would ask for Automation access.)
  uninstall quit: "dev.notch.Notch"

  zap trash: [
    "~/Library/Application Support/Notch",
    "~/Library/Caches/dev.notch.Notch",
    "~/Library/HTTPStorages/dev.notch.Notch",
    "~/Library/Logs/Notch.log",
    "~/Library/Preferences/dev.notch.Notch.plist",
  ]
end
