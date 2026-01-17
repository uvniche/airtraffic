from setuptools import setup, find_packages

with open("README.md", "r", encoding="utf-8") as fh:
    long_description = fh.read()

setup(
    name="airtraffic",
    version="0.3.0",
    author="uvniche",
    description="A cross-platform network monitoring tool for macOS, Linux, and Windows",
    long_description=long_description,
    long_description_content_type="text/markdown",
    url="https://github.com/uvniche/airtraffic",
    packages=["airtraffic"],
    package_dir={"airtraffic": "src"},
    classifiers=[
        "Programming Language :: Python :: 3",
        "License :: OSI Approved :: MIT License",
        "Operating System :: MacOS",
        "Operating System :: POSIX :: Linux",
        "Operating System :: Microsoft :: Windows",
    ],
    python_requires=">=3.7",
    install_requires=[
        "psutil>=5.9.0",
    ],
    entry_points={
        "console_scripts": [
            "airtraffic=airtraffic.cli:main",
        ],
    },
)
