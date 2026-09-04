class Airtraffic < Formula
  desc "Track per-app network data usage on macOS"
  homepage "https://github.com/uvniche/airtraffic"
  url "https://github.com/uvniche/airtraffic/releases/download/rolling/airtraffic-macos-universal.tar.gz"
  version "1.0.0"
  sha256 "29166d988fbb9f818c7376002c283745ecb60cf221eb5e87a1aaba3a82203ddf"
  license "MIT"
  revision 2

  depends_on macos: :ventura

  def install
    bin.install "airtraffic"
  end

  test do
    assert_match "AirTraffic", shell_output("#{bin}/airtraffic help")
  end
end
