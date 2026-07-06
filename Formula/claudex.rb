# Homebrew formula for Claudex.
#
# This lives in the everlof/homebrew-tap repository (as Formula/claudex.rb). A copy is
# kept here for reference. To install:
#
#   brew install --no-quarantine everlof/tap/claudex
#
class Claudex < Formula
  desc "Menu-bar app showing Claude and Codex usage across multiple logins"
  homepage "https://github.com/everlof/claudex"
  url "https://github.com/everlof/claudex/archive/refs/tags/v1.0.0.tar.gz"
  # sha256 is filled in when the release tarball exists:
  #   curl -sL <url> | shasum -a 256
  sha256 :no_check
  license "MIT"
  head "https://github.com/everlof/claudex.git", branch: "main"

  depends_on xcode: ["16.0", :build]
  depends_on :macos
  depends_on macos: :sonoma # macOS 14+

  def install
    # Build the release binary and assemble the signed .app bundle.
    system "./build-app.sh", "release"

    # Install the assembled app into the Homebrew prefix, and expose the binary.
    prefix.install "Claudex.app"
    bin.write_exec_script "#{prefix}/Claudex.app/Contents/MacOS/Claudex"
  end

  def caveats
    <<~EOS
      Claudex is a menu-bar app (no Dock icon). Launch it with:

        open "#{opt_prefix}/Claudex.app"

      To start it at login, add that app to System Settings > General > Login Items,
      or symlink it into /Applications:

        ln -sf "#{opt_prefix}/Claudex.app" /Applications/Claudex.app

      On first run macOS will ask to allow reading the keychain (Claude logins) and,
      for the "frontmost account" feature, to control Terminal/iTerm. Click Allow.
    EOS
  end

  test do
    assert_path_exists prefix/"Claudex.app/Contents/MacOS/Claudex"
  end
end
