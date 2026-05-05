cask "mq-dir" do
  version "0.1.0-beta.1"
  sha256 "87b0ca0c1a42e89982b593a48061f6c9ea8d6f922707d3394121d8d416b80f67"

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
