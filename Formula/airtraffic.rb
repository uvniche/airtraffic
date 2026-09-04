class Airtraffic < Formula
  desc "Track per-app network data usage on macOS"
  homepage "https://github.com/uvniche/airtraffic"
  url "https://github.com/uvniche/airtraffic/releases/download/rolling/airtraffic-macos-arm64.tar.gz"
  version "1.0.0"
  sha256 "f9ef62cd51c5183c34f297d767ef258570c8b1193a4a9556e3e63644304d800a"
  license "MIT"
  revision 5

  depends_on arch: :arm64
  depends_on macos: :ventura

  def install
    bin.install "airtraffic"
  end

  test do
    assert_match "AirTraffic", shell_output("#{bin}/airtraffic help")
  end
end
