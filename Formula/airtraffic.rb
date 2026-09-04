class Airtraffic < Formula
  desc "Track per-app network data usage on macOS"
  homepage "https://github.com/uvniche/airtraffic"
  license "MIT"
  head "https://github.com/uvniche/airtraffic.git", branch: "main"

  depends_on macos: :ventura

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"
    bin.install ".build/release/airtraffic"
  end

  test do
    assert_match "AirTraffic", shell_output("#{bin}/airtraffic help")
  end
end
