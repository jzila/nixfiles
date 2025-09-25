{ pkgs, lib, ... }:

pkgs.stdenv.mkDerivation {
  pname = "fetch-ssh-ca-key";
  version = "1.0";
  src = ../../scripts;
  dontBuild = true;
  
  nativeBuildInputs = [ pkgs.makeWrapper ];
  buildInputs = [ pkgs.curl pkgs.step-cli pkgs.coreutils pkgs.findutils pkgs.gnugrep ];
  
  installPhase = ''
    mkdir -p $out/bin
    cp fetch-ssh-ca-key.sh $out/bin/
    chmod +x $out/bin/fetch-ssh-ca-key.sh
    
    # Wrap the script with required dependencies in PATH
    wrapProgram $out/bin/fetch-ssh-ca-key.sh \
      --prefix PATH : ${lib.makeBinPath [ pkgs.curl pkgs.step-cli pkgs.coreutils pkgs.findutils pkgs.gnugrep ]}
  '';
  
  meta = with lib; {
    description = "Script to fetch SSH CA public key from SmallStep CA";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}