# Homebrew cask. Publish by putting this file in a tap repository named
# homebrew-tap, at Casks/cad-viewer.rb:
#
#   brew tap andriivelhov/tap     # once
#   brew install --cask cadviewer
#
# Dropping the tap step entirely means getting into homebrew/cask itself, which
# requires the project to be notable and to follow their token conventions.
#
# Update `version` and `sha256` for each release; get the checksum with
#   shasum -a 256 packaging/CADViewer-<version>.dmg
cask "cadviewer" do
  version "1.1"
  sha256 "7b93af8078d4c1b48b6a8b0570f5a6b6b0c7bac6371b1e87d99ccbda615f88fe"

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
