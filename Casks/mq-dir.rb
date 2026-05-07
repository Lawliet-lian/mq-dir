cask "mq-dir" do
  version "0.1.0-beta.4"
  sha256 "a8763b7c83c72f90043ef7adbbe6a5067c6a71eae7c40dd0cdfc331ab2a584af"

  url "https://github.com/h5nam/mq-dir/releases/download/v#{version}/mq-dir-v#{version}.dmg"
  name "mq-dir"
  desc "Quad-pane native macOS file manager"
  homepage "https://github.com/h5nam/mq-dir"

  auto_updates false
  depends_on macos: ">= :sonoma"

  app "mq-dir.app"

  zap trash: [
    "~/Library/Application Support/com.mqdir.app",
    "~/Library/Preferences/com.mqdir.app.plist",
    "~/Library/Saved Application State/com.mqdir.app.savedState",
  ]
end
