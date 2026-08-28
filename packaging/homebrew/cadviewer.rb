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
  version "1.0"
  sha256 "536dc96b6cbc01d7ce6745f83af7045fcb1f55336b93abb1bff145dfc64919c8"

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
