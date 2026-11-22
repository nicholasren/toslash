cask "toslash" do
  version "0.1.2"
  sha256 "4132dc93982a4ea3489a38bbc3e1bd571621ea2a78665ede89173b3584ecf823"

  url "https://github.com/nicholasren/toslash/releases/download/v#{version}/ToSlash-#{version}.dmg"
  name "ToSlash"
  desc "Menu bar short links for local servers and saved pages"
  homepage "https://github.com/nicholasren/toslash"

  depends_on macos: :sonoma

  app "ToSlash.app"

  postflight_steps do
    run "/usr/bin/xattr",
        args:           ["-dr", "com.apple.quarantine", "{{appdir}}/ToSlash.app"],
        writable_paths: ["ToSlash.app"],
        writable_base:  :appdir
  end

  uninstall quit: "io.github.nicholasren.toslash"

  zap trash: [
    "~/Library/Application Support/ToSlash",
    "~/Library/Preferences/io.github.nicholasren.toslash.plist",
  ]
end
