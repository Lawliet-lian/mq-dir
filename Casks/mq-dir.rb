cask "mq-dir" do
  version "0.1.0-beta.6"
  sha256 "c59a8fc698397972bc77d6435b33160e7842181ab5c1d469de39c4f392ab044e"

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
