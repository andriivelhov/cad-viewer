# Homebrew cask. Publish by putting this file in a tap repository named
# homebrew-tap, at Casks/cad-viewer.rb:
#
#   brew install --cask andriivelhov/tap/cad-viewer
#
# Update `version` and `sha256` for each release; get the checksum with
#   shasum -a 256 packaging/CADViewer-<version>.dmg
cask "cad-viewer" do
  version "1.0"
  sha256 "eb78e1f400d78be6168e3d3abca48d9c88edcddb6880f869e176904f03d6cfcc"

  url "https://github.com/andriivelhov/cad-viewer/releases/download/v#{version}/CADViewer-#{version}.dmg"
  name "CAD Viewer"
  desc "Native viewer for STEP, IGES, STL, OBJ and glTF with exact measurement"
  homepage "https://github.com/andriivelhov/cad-viewer"

  depends_on macos: :ventura
  depends_on arch: :arm64

  app "CAD Viewer.app"

  zap trash: [
    "~/Library/Preferences/dev.cadviewer.app.plist",
    "~/Library/Saved Application State/dev.cadviewer.app.savedState",
  ]
end
