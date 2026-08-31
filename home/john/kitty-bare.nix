# A second kitty launcher that skips tmux.
#
# programs.kitty sets `shell = tmux`, so every normal kitty window attaches
# tmux. kitty has no profiles feature and Spotlight cannot pass arguments to an
# app, so the way to get a tmux-less kitty is a separate launcher that overrides
# that one setting on the command line. `shell=.` is kitty's value for "use the
# login shell".
{ pkgs, lib, isDarwin, isLinux, ... }:

let
  kittyApp = "${pkgs.kitty}/Applications/kitty.app";

  kittyExe =
    if isDarwin
    then "${kittyApp}/Contents/MacOS/kitty"
    else "${pkgs.kitty}/bin/kitty";

  kitty-bare = pkgs.writeShellScriptBin "kitty-bare" ''
    exec ${kittyExe} -o shell=. "$@"
  '';

  # Minimal app bundle so Spotlight indexes "kitty-bare" as its own entry. The
  # heavy parts of kitty.app are not duplicated: the bundle executable is a
  # three-line script that hands off to the kitty-bare wrapper above, and the
  # icon is symlinked out of the real bundle. mac-app-util (wired into
  # home-manager.sharedModules in flake.nix) trampolines it into ~/Applications.
  kitty-bare-app = pkgs.runCommandLocal "kitty-bare-app" { } ''
    contents=$out/Applications/kitty-bare.app/Contents
    mkdir -p $contents/MacOS $contents/Resources
    ln -s ${kittyApp}/Contents/Resources/kitty.icns $contents/Resources/kitty.icns

    cat > $contents/Info.plist <<'PLIST'
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>CFBundleDevelopmentRegion</key><string>English</string>
      <key>CFBundleDisplayName</key><string>kitty-bare</string>
      <key>CFBundleName</key><string>kitty-bare</string>
      <key>CFBundleExecutable</key><string>kitty-bare</string>
      <key>CFBundleIconFile</key><string>kitty.icns</string>
      <key>CFBundleIdentifier</key><string>net.kovidgoyal.kitty.bare</string>
      <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
      <key>CFBundlePackageType</key><string>APPL</string>
      <key>CFBundleShortVersionString</key><string>${pkgs.kitty.version}</string>
      <key>CFBundleVersion</key><string>${pkgs.kitty.version}</string>
      <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
      <key>LSMinimumSystemVersion</key><string>10.12.0</string>
      <key>NSHighResolutionCapable</key><true/>
      <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    </dict>
    </plist>
    PLIST

    cat > $contents/MacOS/kitty-bare <<'LAUNCHER'
    #!${pkgs.runtimeShell}
    exec ${kitty-bare}/bin/kitty-bare "$@"
    LAUNCHER
    chmod +x $contents/MacOS/kitty-bare
  '';
in
{
  home.packages = [ kitty-bare ] ++ lib.optional isDarwin kitty-bare-app;
}
// lib.optionalAttrs isLinux {
  xdg.desktopEntries.kitty-bare = {
    name = "kitty-bare";
    genericName = "Terminal";
    comment = "kitty without tmux";
    exec = "kitty-bare";
    icon = "kitty";
    terminal = false;
    type = "Application";
    categories = [ "System" "TerminalEmulator" ];
  };
}
