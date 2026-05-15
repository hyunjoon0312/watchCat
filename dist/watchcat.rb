cask "watchcat" do
  version "1.0.1"
  sha256 "106d9dfd5b02b697b06313ec176c10f31b437302ed11e9a47baa1f55f95c5089"

  url "https://github.com/hyunjoon0312/watchCat/releases/download/v#{version}/watchCat-#{version}.zip"
  name "watchCat"
  desc "Menu-bar app that tracks Mac usage time automatically"
  homepage "https://github.com/hyunjoon0312/watchCat"

  depends_on macos: ">= :sonoma"

  app "watchCat.app"

  # Strip the quarantine xattr brew slaps onto downloaded apps. Without this,
  # Gatekeeper would block first launch because watchCat isn't notarized
  # under an Apple Developer ID. Users see no warning and the app just opens.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/watchCat.app"],
                   sudo: false
  end

  zap trash: [
    "~/Library/Application Support/watchCat",
    "~/Library/Preferences/com.dayflow.watchCat.plist",
    "~/Library/Caches/com.dayflow.watchCat",
  ]
end
