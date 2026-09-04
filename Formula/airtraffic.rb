class Airtraffic < Formula
  desc "Track per-app network data usage on macOS"
  homepage "https://github.com/uvniche/airtraffic"
  url "https://github.com/uvniche/airtraffic/releases/download/rolling/airtraffic-macos-universal.tar.gz"
  version "1.0.0"
  sha256 "8363742830f67a6e26c66cb158776a4433aa9ff7d3b1dd2efd4a8096575e8a8a"
  license "MIT"
  revision 6

  depends_on macos: :ventura

  def install
    bin.install "airtraffic"
  end

  test do
    assert_match "AirTraffic", shell_output("#{bin}/airtraffic help")
  end
end
