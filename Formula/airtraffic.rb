class Airtraffic < Formula
  desc "Track per-app network data usage on macOS"
  homepage "https://github.com/uvniche/airtraffic"
  url "https://github.com/uvniche/airtraffic/releases/download/rolling/airtraffic-macos-arm64.tar.gz"
  version "1.0.0"
  sha256 "e3d783d3c8c3f2545dfb09b91e1f74cf764cc131f03e4da7106fc18be674771f"
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
