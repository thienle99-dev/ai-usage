cask "ai-usage-monitor" do
  version :latest
  sha256 :no_check

  url "https://github.com/thienle99-dev/ai-usage/releases/latest/download/AI-Usage-Monitor-macos-arm64.zip"
  name "AI Usage Monitor"
  desc "Menu bar app for checking AI coding provider usage"
  homepage "https://github.com/thienle99-dev/ai-usage"

  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  auto_updates true
  app "AI Usage Monitor.app"
end
