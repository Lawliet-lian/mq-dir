cask "mq-dir" do
  version "0.1.0-beta.8"
  sha256 "5419c8b5c3859bfe3c5fb7673e472934ae2695d6622606cfc29ce137616022ae"

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
