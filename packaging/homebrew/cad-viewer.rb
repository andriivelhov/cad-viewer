# Homebrew cask. Publish by putting this file in a tap repository named
# homebrew-tap, at Casks/cad-viewer.rb:
#
#   brew install --cask andriivelhov/tap/cad-viewer
#
# Update `version` and `sha256` for each release; get the checksum with
#   shasum -a 256 packaging/CADViewer-<version>.dmg
cask "cad-viewer" do
  version "1.0"
  sha256 "d5ba323b7cb76b9778d9e1c19ea50dd99578edc84b5965bedde7a3d633f260b5"

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
