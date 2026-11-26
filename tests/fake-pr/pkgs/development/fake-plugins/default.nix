{ lib, newScope }:
lib.makeScope newScope (self: {
  one = self.callPackage (
    { writeTextDir }: (writeTextDir "share/one" "one") // { version = "1.0"; }
  ) { };
})
