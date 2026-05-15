cask "watchcat" do
  version "1.0.0"
  sha256 "4967c3d59c9a15105110bc789c856c55eea3f6b1a9bbc775e4d253e2de4bb036"

  url "https://github.com/hyunjoon0312/watchCat/releases/download/v#{version}/watchCat-#{version}.zip"
  name "watchCat"
  desc "Menu-bar app that tracks Mac usage time automatically"
  homepage "https://github.com/hyunjoon0312/watchCat"

  depends_on macos: ">= :sonoma"

  app "watchCat.app"

  zap trash: [
    "~/Library/Application Support/watchCat",
    "~/Library/Preferences/com.dayflow.watchCat.plist",
    "~/Library/Caches/com.dayflow.watchCat",
  ]
end
