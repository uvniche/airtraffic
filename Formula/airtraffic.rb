class Airtraffic < Formula
  desc "Track per-app network data usage on macOS"
  homepage "https://github.com/uvniche/airtraffic"
  url "https://github.com/uvniche/airtraffic/releases/download/rolling/airtraffic-macos-arm64.tar.gz"
  version "1.0.0"
  sha256 "bc47acc8c9b9e796bd3dee755436c30209c125a0be3573b04b3f453600353fce"
  license "MIT"
  revision 3

  depends_on arch: :arm64
  depends_on macos: :ventura

  def install
    bin.install "airtraffic"
  end

  test do
    assert_match "AirTraffic", shell_output("#{bin}/airtraffic help")
  end
end
