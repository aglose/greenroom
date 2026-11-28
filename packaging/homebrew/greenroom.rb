# Homebrew cask for Greenroom, in the aglose/homebrew-apksim tap: brew tap aglose/apksim, brew trust
# aglose/apksim (Homebrew 7 loads casks only from trusted taps), then brew install --cask greenroom.
# The `tap` job in .github/workflows/release.yml fills in the version and checksum when a release is published
# and pushes the result to the tap as Casks/greenroom.rb; this copy is the template.
cask "greenroom" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/aglose/greenroom/releases/download/v#{version}/Greenroom-#{version}.dmg"
  name "Greenroom"
  desc "Workbench where coding agents run and verify Android apps, with no emulator"
  homepage "https://github.com/aglose/greenroom"

  # The app updates itself (Sparkle, from the newest published release), so brew upgrade leaves it alone.
  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :sonoma

  # Signed and notarized, so no quarantine step: Gatekeeper opens it like any download.
  app "Greenroom.app"

  zap trash: [
    "~/Library/Application Support/Greenroom",
    "~/Library/Caches/io.github.aglose.greenroom",
    "~/Library/HTTPStorages/io.github.aglose.greenroom",
    "~/Library/HTTPStorages/io.github.aglose.greenroom.binarycookies",
    "~/Library/Preferences/io.github.aglose.greenroom.plist",
    "~/Library/Saved Application State/io.github.aglose.greenroom.savedState",
  ]
end
