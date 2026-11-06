{ writeText, python3Packages }:
(writeText "fake-app" "${python3Packages.fake-py}") // { version = "1.0"; }
