class Airtraffic < Formula
  desc "Track per-app network data usage on macOS"
  homepage "https://github.com/uvniche/airtraffic"
  url "https://github.com/uvniche/airtraffic.git",
      revision: "81ea8858da7a4841ea6401082495fa871e96d5f0"
  version "1.0.0"
  license "MIT"
  revision 1

  depends_on xcode: ["15.0", :build]
  depends_on macos: :ventura

  def install
    system "xcrun", "swift", "build", "--configuration", "release", "--disable-sandbox"
    bin.install ".build/release/airtraffic"
  end

  test do
    assert_match "AirTraffic", shell_output("#{bin}/airtraffic help")
  end
end
