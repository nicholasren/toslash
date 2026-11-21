cask "toslash" do
  version "0.1.1"
  sha256 "a7e4901589bc98107bbc52ba57bc64a1cced07c63b881d7dfb4d1400cf109fc0"

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
