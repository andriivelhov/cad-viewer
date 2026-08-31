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
  version "1.2"
  sha256 "c6056b7b677c2291b5c1400749a580f7524dd2945f3c7a4c0ff0c8d62091b752"

  url "https://github.com/andriivelhov/cad-viewer/releases/download/v#{version}/CADViewer-#{version}.dmg"
  name "CAD Viewer"
  desc "Native viewer for STEP, IGES, STL, OBJ and glTF with exact measurement"
  homepage "https://github.com/andriivelhov/cad-viewer"

  depends_on macos: :ventura
  depends_on arch: :arm64

  app "CAD Viewer.app"

  # A fresh install otherwise shows generic document icons for every STEP file:
  # the Finder thumbnail and preview extensions stay dormant until the app has
  # been launched once. lsregister publishes the file types, and pluginkit
  # registers the two extensions directly - lsregister alone only sometimes
  # nudges them into being discovered, and can take a minute when it does.
  postflight do
    system_command "/System/Library/Frameworks/CoreServices.framework/" \
                   "Frameworks/LaunchServices.framework/Support/lsregister",
                   args: ["-f", "#{appdir}/CAD Viewer.app"], sudo: false
    ["CADThumbnail", "CADPreview"].each do |ext|
      system_command "/usr/bin/pluginkit",
                     args: ["-a", "#{appdir}/CAD Viewer.app/Contents/PlugIns/#{ext}.appex"],
                     sudo: false
    end
  end

  zap trash: [
    "~/Library/Preferences/dev.cadviewer.app.plist",
    "~/Library/Saved Application State/dev.cadviewer.app.savedState",
  ]
end
