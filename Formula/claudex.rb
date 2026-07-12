# Homebrew formula for Claudex.
#
# This lives in the everlof/homebrew-tap repository (as Formula/claudex.rb). A copy is
# kept here for reference. To install:
#
#   brew install everlof/tap/claudex
#
class Claudex < Formula
  desc "Menu-bar app showing Claude and Codex usage across multiple logins"
  homepage "https://github.com/everlof/claudex"
  url "https://github.com/everlof/claudex/archive/refs/tags/v1.0.2.tar.gz"
  sha256 "4e253306737fc4d4d12f16fa96bc9f83ca90ac0ff66e662c1af3ffd540969ae9"
  license "MIT"
  head "https://github.com/everlof/claudex.git", branch: "main"

  depends_on xcode: ["16.0", :build]
  depends_on macos: :sonoma # macOS 14+

  def install
    # SwiftPM does its own sandboxing, which collides with Homebrew's build sandbox
    # ("sandbox_apply: Operation not permitted"). Disable SwiftPM's sandbox for the build.
    ENV["CLAUDEX_SWIFT_FLAGS"] = "--disable-sandbox"
    # Homebrew builds use an ad-hoc signature; the app does not read Claude's Keychain.
    ENV["CLAUDEX_ADHOC_SIGN"] = "1"

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

      Claude usage uses an explicit local-feed setup and never reads its Keychain token.
      For the "frontmost account" feature, macOS may ask to control Terminal/iTerm.
    EOS
  end

  test do
    assert_path_exists prefix/"Claudex.app/Contents/MacOS/Claudex"
    assert_path_exists prefix/"Claudex.app/Contents/Helpers/ClaudexStatusBridge"
  end
end
