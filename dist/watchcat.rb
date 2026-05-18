cask "watchcat" do
  version "1.1.1"
  sha256 "ea33f0322843611805b09e0a259b93887575ddb83c2cc001d48d50ec6b36ea0c"

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
